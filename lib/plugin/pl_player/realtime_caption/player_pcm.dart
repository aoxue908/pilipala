import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

class PlayerPcmReadException implements Exception {
  const PlayerPcmReadException();
}

class PlayerPcm {
  PlayerPcm({
    required String source,
    required Map<String, String>? headers,
    required Duration start,
    required Duration end,
  }) {
    _opening = _open(source, headers, start, end);
  }

  static const bytesPerSecond = 16000 * 2;
  static const frameSize = bytesPerSecond * 160 ~/ 1000;

  late final Future<void> _opening;
  Directory? _directory;
  File? _output;
  RandomAccessFile? _reader;
  Player? _decoder;
  StreamSubscription<String>? _errors;
  int? _dataOffset;
  int _offset = 0;
  bool _closed = false;
  bool _paused = false;
  bool _failed = false;
  bool _drained = false;
  int? _finalFileSize;
  int _fileLength = 0;

  int get bytesRead => _offset;
  int get bytesWritten =>
      (_fileLength - (_dataOffset ?? 68)).clamp(0, _fileLength);
  bool get paused => _paused;
  bool get buffering => _decoder?.state.buffering ?? false;
  bool get drained => _drained;
  bool get atEnd {
    final size = _finalFileSize;
    if (size == null) return false;
    return size <= (_dataOffset ?? 44) + _offset + 1;
  }

  Future<void> _open(
    String source,
    Map<String, String>? headers,
    Duration start,
    Duration end,
  ) async {
    final cache = await getTemporaryDirectory();
    if (_closed) return;
    final directory = _directory = await cache.createTemp('pilipala-asr-');
    if (_closed) return;
    final output = _output = File('${directory.path}/audio.wav');
    final decoder = _decoder = Player(
      configuration: const PlayerConfiguration(bufferSize: 1024 * 1024),
    );
    _errors = decoder.stream.error.listen((_) => _failed = true);
    final native = decoder.platform as NativePlayer;
    // A second, audio-only mpv instance writes PCM without changing the
    // selected output, volume, or filters of the visible player.
    final options = {
      'vid': 'no',
      'sid': 'no',
      'aid': 'auto',
      'audio-file-auto': 'no',
      'options/ao': 'pcm',
      'options/ao-pcm-file': output.absolute.path,
      'audio-channels': 'mono',
      'audio-format': 's16',
      'audio-samplerate': '16000',
      'audio-pitch-correction': 'no',
      'hr-seek': 'always',
      'ytdl': 'no',
    };
    for (final option in options.entries) {
      if (_closed) return;
      await native.setProperty(option.key, option.value);
    }
    if (_closed) return;
    if (await native.getProperty('options/ao') != 'pcm' ||
        await native.getProperty('options/ao-pcm-file') !=
            output.absolute.path) {
      throw const FormatException('当前播放器无法导出视频音轨');
    }
    if (_closed) return;
    try {
      await decoder.open(
        Media(source, httpHeaders: headers, start: start, end: end),
        play: false,
      ).timeout(const Duration(seconds: 10));
    } catch (e) {
      _failed = true;
      rethrow;
    }
    if (!_closed) _paused = true;
  }

  Future<void> prepare() => _opening;

  Future<void> setReading(int limit) async {
    await _opening;
    if (_closed || _drained) return;
    if (_failed) throw const PlayerPcmReadException();
    final decoder = _decoder!;
    if (decoder.state.completed) {
      // Closing the PCM output flushes the last buffered samples to disk.
      await decoder.stop();
      final output = _output!;
      _finalFileSize =
          _fileLength = await output.exists() ? await output.length() : 0;
      _drained = true;
      return;
    }

    // 卡顿优化：第二个 mpv 解码器每次 play/pause 切换都可能让主播放器掉帧。
    // 把水位滞回区间从 15~60s 扩大到 12~90s，显著减少切换次数；
    // 90s 的充足缓冲仍能覆盖网络抖动，且发送速率由 sendBudget 独立限速，
    // 不会因多解码而拥塞云端识别队列。
    const lowWaterSeconds = 12;
    const highWaterSeconds = 90;
    final output = _output!;
    final length = await output.exists() ? await output.length() : 0;
    if (_closed) return;
    _fileLength = length;
    final ahead = length - (_dataOffset ?? 0) - limit;
    if (_paused) {
      if (ahead < lowWaterSeconds * bytesPerSecond) {
        _paused = false;
        await decoder.play();
      }
    } else if (ahead > highWaterSeconds * bytesPerSecond) {
      _paused = true;
      await decoder.pause();
    }
  }

  Future<Uint8List?> readFrame(int limit, {bool finalFrame = false}) async {
    await _opening;
    if (_closed) return null;
    final available = limit - _offset;
    final size =
        finalFrame && available < frameSize ? available & ~1 : frameSize;
    if (size <= 0 || available < size) return null;

    final output = _output!;
    if (_reader == null) {
      // mpv can use the 68-byte WAVE_FORMAT_EXTENSIBLE header.
      if (!await output.exists() ||
          await output.length() < (_drained ? 44 : 68) ||
          _closed) {
        return null;
      }
      final reader = await output.open();
      if (_closed) {
        await reader.close();
        return null;
      }
      _reader = reader;
      _dataOffset = readAsrWaveHeader(await reader.read(4096));
    }
    if (_closed) return null;
    final reader = _reader!;
    final position = _dataOffset! + _offset;
    final remaining = await reader.length() - position;
    final count = finalFrame && remaining < size ? remaining & ~1 : size;
    if (count <= 0 || remaining < count || _closed) return null;

    await reader.setPosition(position);
    if (_closed) return null;
    final bytes = await reader.read(count);
    if (_closed || bytes.length != count) return null;
    _offset += count;
    return bytes;
  }

  Future<void>? _closeFuture;

  Future<void> close() {
    // 幂等保护：close 可能被 _resetAsr 和 _run 的 finally 并发调用两次，
    // 若不缓存，_decoder.dispose() 会双 dispose 第二个 mpv 实例导致原生崩溃。
    return _closeFuture ??= _close();
  }

  Future<void> _close() async {
    _closed = true;
    try {
      // 必须等 _open 完全结束再 dispose：_open 里 decoder.open 有 10s 超时，
      // 若这里只等 2s 就 dispose，可能撞上一个正在 open 的 mpv 实例导致原生崩溃。
      await _opening.timeout(const Duration(seconds: 15), onTimeout: () {});
    } catch (_) {
      // Initialization errors are handled by the caption session.
    }
    await _errors?.cancel();
    final decoder = _decoder;
    try {
      if (decoder != null) {
        // 先 stop 让 mpv 退出解码/播放状态、事件循环自然收敛，再 dispose。
        // 直接 dispose 一个仍在运行事件循环的 mpv，会与 media_kit 内部的
        // mpv_terminate_destroy 延迟销毁交错，触发 mpv_wait_event 里对已销毁
        // mutex 加锁 → SIGABRT（native 崩溃，无法被 Dart try/catch 捕获）。
        try {
          await decoder.stop().timeout(const Duration(seconds: 3), onTimeout: () {});
        } catch (_) {
        }
        // 关键：不要给 dispose 加 2s 短超时。超时后继续删临时文件、上层立刻
        // 新建第二个 mpv 实例，正是崩溃竞态的根源。给足时间让其同步释放完。
        try {
          await decoder.dispose().timeout(const Duration(seconds: 10));
        } on TimeoutException {
          // 极端情况下仍超时：放弃等待，但不要再触碰该 decoder 的资源。
        }
      }
    } catch (_) {
    } finally {
      try {
        await _reader?.close();
      } catch (_) {
      } finally {
        try {
          final output = _output;
          if (output != null && await output.exists()) await output.delete();
          await _directory?.delete(recursive: true);
        } catch (_) {}
      }
    }
  }
}

// mpv can emit WAVE_FORMAT_EXTENSIBLE. Its data size is a placeholder until
// the writer closes, so the data offset and the current file length are used.
int readAsrWaveHeader(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var pcm16Mono = false;
  if (bytes.length >= 12 &&
      data.getUint32(0) == 0x52494646 && // RIFF
      data.getUint32(8) == 0x57415645) {
    for (var offset = 12; offset + 8 <= bytes.length;) {
      final chunk = data.getUint32(offset);
      final size = data.getUint32(offset + 4, Endian.little);
      final start = offset + 8;
      if (chunk == 0x64617461 && pcm16Mono) return start; // data
      if (size > bytes.length - start) break;
      if (chunk == 0x666d7420 && size >= 16) {
        // fmt
        final format = data.getUint16(start, Endian.little);
        final isPcm = format == 1 ||
            (format == 0xfffe &&
                size >= 40 &&
                data.getUint32(start + 24, Endian.little) == 1);
        pcm16Mono = isPcm &&
            data.getUint16(start + 2, Endian.little) == 1 &&
            data.getUint32(start + 4, Endian.little) == 16000 &&
            data.getUint16(start + 14, Endian.little) == 16;
      }
      offset = start + size + (size.isOdd ? 1 : 0);
    }
  }
  throw const FormatException('视频音轨无法转换为 ASR 所需的音频格式');
}
