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
    await decoder.open(
      Media(source, httpHeaders: headers, start: start, end: end),
      play: false,
    );
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

    // The decoder runs ahead of playback and keeps a generous buffer
    // to avoid frequent pause/play cycles that cause mpv to freeze or drop HTTP connections.
    final output = _output!;
    final length = await output.exists() ? await output.length() : 0;
    if (_closed) return;
    _fileLength = length;
    final ahead = length - (_dataOffset ?? 0) - limit;
    if (_paused) {
      if (ahead < 15 * bytesPerSecond) {
        _paused = false;
        await decoder.play();
      }
    } else if (ahead > 60 * bytesPerSecond) {
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

  Future<void> close() async {
    _closed = true;
    try {
      await _opening;
    } catch (_) {
      // Initialization errors are handled by the caption session.
    }
    await _errors?.cancel();
    try {
      await _decoder?.dispose();
    } finally {
      try {
        await _reader?.close();
      } finally {
        final output = _output;
        if (output != null && await output.exists()) await output.delete();
        await _directory?.delete();
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
