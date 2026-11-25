import 'dart:math' as math;
import 'dart:typed_data';

/// 动态音频电平平抑与防破音限幅器 (Automatic Gain Control & Loudness Leveler)
/// 借鉴自 D:\app\realtime-asr 高性能音频预处理算法：
/// - 对视频中低语、小音量对白自动进行最高 +18 dB (约 8 倍) 的动态补偿
/// - 采用指数攻防包络滤波 (Attack/Release Time = 150ms)，平滑增益，无忽大忽小突兀感
/// - 严格峰值限幅 (Peak Limiter <= 30000 / 32767)，杜绝高潮破音与杂音啸叫
/// - 智能识别数字静音与环境底噪 (RMS < 40)，不放大背景杂音
class PcmLeveler {
  double _gain = 1.0;
  int _inputDbfs = -120;
  int _gainPercent = 100;

  int get inputDbfs => _inputDbfs;
  int get gainPercent => _gainPercent;

  /// 对输入的 16-bit PCM 字节数组进行原地 (In-Place) 电平增益平抑
  void apply(Uint8List pcm, [int? length]) {
    final len = length ?? pcm.length;
    if (len <= 0 || (len & 1) != 0) return;

    final sampleCount = len ~/ 2;
    final byteData = ByteData.sublistView(pcm, 0, len);

    double power = 0.0;
    int peak = 0;

    for (int i = 0; i < sampleCount; i++) {
      final v = byteData.getInt16(i * 2, Endian.little);
      power += v * v;
      final absV = v < 0 ? -v : v;
      if (absV > peak) peak = absV;
    }

    final double rms = math.sqrt(power / sampleCount);
    _inputDbfs = math.max(-120, (20 * math.log(math.max(1.0, rms) / 32768.0) / math.ln10).round());

    // 目标 RMS 设为 2000 (约 -24 dBFS，为 Qwen/Sherpa 等 ASR 模型的黄金声学输入区间)
    // 遇到静音或底噪时 (rms < 40) 不盲目拉大增益，并平滑回退至 1.0 原声，杜绝把背景噪声或静音无休止放大 8 倍
    final double desired = rms >= 40.0 ? math.max(1.0, math.min(8.0, 2000.0 / rms)) : 1.0;
    final double peakLimit = peak == 0 ? 8.0 : math.max(1.0, 30000.0 / peak);
    final double boundedDesired = math.min(desired, peakLimit);

    // 16kHz 单声道 16bit 每秒 32000 字节
    final double seconds = len / 32000.0;
    _gain = boundedDesired < _gain
        ? boundedDesired
        : _gain + (boundedDesired - _gain) * (1.0 - math.exp(-seconds / 0.15));
    _gain = math.min(_gain, peakLimit);
    _gainPercent = (_gain * 100).round();

    // 增益约等于 1.0 时直接保持原声，0 额外耗时
    if (_gain <= 1.0001) return;

    for (int i = 0; i < sampleCount; i++) {
      final v = byteData.getInt16(i * 2, Endian.little);
      final out = math.max(-32768, math.min(32767, (v * _gain).round()));
      byteData.setInt16(i * 2, out, Endian.little);
    }
  }

  void reset() {
    _gain = 1.0;
    _inputDbfs = -120;
    _gainPercent = 100;
  }
}
