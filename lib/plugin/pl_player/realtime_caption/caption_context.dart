import 'dart:math' as math;

typedef CaptionContextRange = ({int start, int end});

/// 记录每个原始字幕片段在合并文本中的位置，查词时不把历史片段带进来。
List<CaptionContextRange> mergeCaptionContextRanges({
  required String previous,
  required List<CaptionContextRange> ranges,
  required String incoming,
  required String merged,
}) {
  if (merged == previous) return ranges;
  if (merged == incoming) return [(start: 0, end: merged.length)];
  if (merged.startsWith(previous) && merged.endsWith(incoming)) {
    final start = merged.length - incoming.length;
    return [
      for (final range in ranges)
        if (range.start < start)
          (start: range.start, end: math.min(range.end, start)),
      (start: start, end: merged.length),
    ];
  }
  return [(start: 0, end: merged.length)];
}

String captionContainingSentence({
  required String text,
  required String word,
  int? wordOffset,
  List<CaptionContextRange> sourceRanges = const [],
}) {
  if (text.trim().isEmpty) return '';
  final found = text.toLowerCase().indexOf(word.trim().toLowerCase());
  final offset =
      (wordOffset ?? (found < 0 ? 0 : found)).clamp(0, text.length - 1).toInt();
  final boundaries = RegExp(r'''[。！？!?；;\r\n]+[”’"'」』）)]*|\.(?=\s|$)''');
  final abbreviations = RegExp(
      r'\b(?:Mr|Mrs|Ms|Dr|Prof|Sr|Jr|St|vs|etc|e\.g|i\.e)\.$',
      caseSensitive: false);
  var start = 0;
  var end = text.length;
  var hasBoundary = false;
  for (final match in boundaries.allMatches(text)) {
    if (match.group(0) == '.' &&
        abbreviations.hasMatch(text.substring(0, match.end))) continue;
    hasBoundary = true;
    if (match.end <= offset) {
      start = match.end;
    } else {
      end = match.end;
      break;
    }
  }
  if (hasBoundary) return text.substring(start, end).trim();

  // 无标点的 ASR 累积文本使用被点词对应的原始 cue，而不是整段队列。
  for (final range in sourceRanges) {
    if (range.start <= offset &&
        offset < range.end &&
        range.start >= 0 &&
        range.end <= text.length &&
        range.end - range.start < text.length) {
      return text.substring(range.start, range.end).trim();
    }
  }
  if (text.length <= 100) return text.trim();
  // 兼容没有片段信息的旧数据：仅保留选中词附近的一小段，尽量沿空格断开。
  start = math.max(0, offset - 32);
  end = math.min(text.length, offset + math.max<int>(word.length, 1) + 32);
  if (start > 0) {
    final space = text.indexOf(RegExp(r'[\s，,、]'), start);
    if (space >= start && space < offset) start = space + 1;
    if (text.codeUnitAt(start) >= 0xDC00 && text.codeUnitAt(start) <= 0xDFFF) {
      start--;
    }
  }
  if (end < text.length) {
    final space = text.lastIndexOf(RegExp(r'[\s，,、]'), end);
    if (space >= offset + word.length) end = space;
    if (text.codeUnitAt(end) >= 0xDC00 && text.codeUnitAt(end) <= 0xDFFF) end++;
  }
  return text.substring(start, end).trim();
}
