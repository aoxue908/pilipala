/// 各引擎统一成会话音频毫秒；文字偏移在匹配到字幕后才生成。
class AsrWord {
  const AsrWord(this.text, this.startMs, this.endMs);

  final String text;
  final int startMs;
  final int endMs;

  Map<String, dynamic> toJson() => {
        'word': text,
        'start_ms': startMs,
        'end_ms': endMs,
      };
}

class AsrWordTiming extends AsrWord {
  const AsrWordTiming(
      super.text, super.startMs, super.endMs, this.startOffset, this.endOffset);

  final int startOffset;
  final int endOffset;

  int timeAt(double offset) =>
      startMs +
      ((endMs - startMs) *
              ((offset - startOffset) / (endOffset - startOffset)).clamp(0, 1))
          .round();
}

final _spokenRune = RegExp(r'[\p{L}\p{N}\p{M}]', unicode: true);

String _normalize(String text) => text.runes
    .map(String.fromCharCode)
    .where(_spokenRune.hasMatch)
    .join()
    .toLowerCase();

/// 完整验证，遇到无效/乱序时间戳时让调用方回退估算，不能因此丢字幕。
List<AsrWord> readAsrWords(dynamic raw) {
  if (raw is! List) return const [];
  final words = <AsrWord>[];
  for (final item in raw) {
    if (item is! Map) return const [];
    final text = item['word'];
    final start = item['start_ms'];
    final end = item['end_ms'];
    if (text is! String ||
        start is! num ||
        end is! num ||
        !start.isFinite ||
        !end.isFinite ||
        start < 0 ||
        end <= start ||
        end > 3600000) return const [];
    if (_normalize(text).isEmpty) continue;
    final word = AsrWord(text, start.round(), end.round());
    if (word.endMs <= word.startMs ||
        (words.isNotEmpty &&
            (word.startMs < words.last.startMs ||
                word.endMs < words.last.endMs))) return const [];
    words.add(word);
  }
  return words;
}

/// 顺序匹配整段发音文字，忽略大小写、空格和标点，保留原文 UTF-16 偏移。
/// 不做模糊匹配：漏词、改写或 token 不匹配时回退，避免把另一个词的时间硬套过来。
List<AsrWordTiming> alignAsrWords(String text, List<AsrWord> words) {
  final normalized = StringBuffer();
  final starts = <int>[];
  final ends = <int>[];
  var offset = 0;
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    if (_spokenRune.hasMatch(char)) {
      final lower = char.toLowerCase();
      normalized.write(lower);
      for (var i = 0; i < lower.length; i++) {
        starts.add(offset);
        ends.add(offset + char.length);
      }
    }
    offset += char.length;
  }
  final target = normalized.toString();
  if (target.isEmpty) return const [];
  for (var first = 0; first < words.length; first++) {
    var cursor = 0;
    final aligned = <AsrWordTiming>[];
    for (var i = first; i < words.length; i++) {
      final word = words[i];
      final value = _normalize(word.text);
      if (value.isEmpty) continue;
      if (!target.startsWith(value, cursor)) break;
      final next = cursor + value.length;
      aligned.add(AsrWordTiming(
          word.text, word.startMs, word.endMs, starts[cursor], ends[next - 1]));
      cursor = next;
      if (cursor == target.length) return aligned;
    }
  }
  return const [];
}
