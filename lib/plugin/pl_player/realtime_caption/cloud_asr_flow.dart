/// 云端在超过积压上限且持续没有处理进展时重新连接。
/// 必须在发送循环之外轮询，否则停发后再也不会触发恢复。
class CloudAsrFlow {
  static const maxPendingSpeechMs = 6000;
  static const stalledTimeoutMs = 15000;

  int _processedMs = 0;
  int? _blockedSinceMs;

  bool needsReconnect({
    required int nowMs,
    required int processedMs,
    required int pendingSpeechMs,
  }) {
    if (processedMs > _processedMs || pendingSpeechMs <= maxPendingSpeechMs) {
      _blockedSinceMs = null;
    }
    if (processedMs > _processedMs) _processedMs = processedMs;
    if (pendingSpeechMs <= maxPendingSpeechMs) return false;
    _blockedSinceMs ??= nowMs;
    return nowMs - _blockedSinceMs! >= stalledTimeoutMs;
  }
}
