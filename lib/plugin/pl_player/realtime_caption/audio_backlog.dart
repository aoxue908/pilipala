import 'dart:math' as math;
import 'dart:typed_data';

/// 零丢失断网重连 PCM 回放环形缓冲区 (Bounded PCM Replay Ring Buffer)
/// 借鉴自 D:\app\realtime-asr 高性能网络容灾架构：
/// - 基于绝对字节位移编址，支持最多保留 30 秒 (960,000 字节) 的音频回溯
/// - 仅在云端服务器确认确认句 (isFinal) 时通过 [acknowledge] 释放已确认音频
/// - 网络突发抖动、Token 刷新或短时断开重连时，可无缝回放未确认尾部音频，确保一字不漏
class AudioBacklog {
  static const int bytesPerMs = 32; // 16kHz 16-bit 单声道 = 32000 字节/秒 = 32 字节/毫秒

  final Uint8List _ring;
  int _start = 0;
  int _end = 0;

  AudioBacklog({int milliseconds = 30000})
      : _ring = Uint8List(milliseconds * bytesPerMs);

  int get start => _start;
  int get end => _end;
  int get length => _end - _start;
  bool get isEmpty => _start >= _end;

  /// 追加新录制或新解码的 PCM 字节数据，若超出容量则自动淘汰最旧数据
  /// 返回被挤出淘汰的字节数
  int append(Uint8List data) {
    final int oldStart = _start;
    final int ringLen = _ring.length;
    for (int i = 0; i < data.length; i++) {
      _ring[_end % ringLen] = data[i];
      _end++;
    }
    if (_end - _start > ringLen) {
      _start = _end - ringLen;
    }
    return _start - oldStart;
  }

  /// 从绝对字节位置 [from] 读取最多 [maxBytes] 字节的音频切片
  Uint8List read(int from, int maxBytes) {
    if (from < _start || from > _end || maxBytes <= 0) {
      return Uint8List(0);
    }
    final int count = math.min(maxBytes, _end - from);
    final Uint8List out = Uint8List(count);
    final int ringLen = _ring.length;
    for (int i = 0; i < count; i++) {
      out[i] = _ring[(from + i) % ringLen];
    }
    return out;
  }

  /// 确认服务已处理完毕的绝对字节位置，释放已确认音频的历史存储
  void acknowledge(int position) {
    _start = math.max(_start, math.min(position, _end));
  }

  /// 清空重置缓冲区
  void clear() {
    _start = 0;
    _end = 0;
  }
}
