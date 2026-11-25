/// Conservative guard for ASR degeneration such as "我，我，我，...".
/// Eight consecutive copies are needed; ordinary stutters/emphasis survive.
/// Keep two copies and untouched surrounding text. Operate on source ranges
/// so punctuation differences, spaces and supplementary Han do not bypass it.
String suppressAsrShortLoops(String text) {
  final tokens = RegExp(r'\p{Script=Han}|[\p{L}\p{N}]+', unicode: true)
      .allMatches(text)
      .toList();
  if (tokens.length < 8) return text;
  final values = tokens.map((m) => m[0]!.toLowerCase()).toList();
  final removed = <({int start, int end})>[];
  var i = 0;
  while (i < tokens.length) {
    var end = i;
    for (var size = 1; size <= 4 && i + size * 8 <= tokens.length; size++) {
      var cursor = i + size;
      while (cursor < tokens.length &&
          values[cursor] == values[i + (cursor - i) % size]) {
        cursor++;
      }
      final repeats = (cursor - i) ~/ size;
      if (repeats < 8) continue;
      end = i + repeats * size;
      removed
          .add((start: tokens[i + size * 2 - 1].end, end: tokens[end - 1].end));
      break;
    }
    i = end > i ? end : i + 1;
  }
  if (removed.isEmpty) return text;
  final output = StringBuffer();
  var offset = 0;
  for (final range in removed) {
    output.write(text.substring(offset, range.start));
    offset = range.end;
  }
  output.write(text.substring(offset));
  return output.toString();
}

/// Carries a single-token run across finalized results. Previews do not advance
/// the counter, so revisions of the same hypothesis cannot trigger the guard.
/// A timestamp gap, a different token, or a new transcript resets the run.
class AsrRepetitionGuard {
  String? _last;
  int _count = 0;
  int? _endMs;

  String accept(String text, {required bool isFinal, int? audioMs}) {
    var last = _last;
    var count = _count;
    if (_endMs != null &&
        audioMs != null &&
        (audioMs < _endMs! || audioMs - _endMs! > 4000)) {
      last = null;
      count = 0;
    }
    final tokens = RegExp(r'\p{Script=Han}|[\p{L}\p{N}]+', unicode: true)
        .allMatches(text)
        .toList();
    final output = StringBuffer();
    var offset = 0;
    var kept = false;
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      final value = token[0]!.toLowerCase();
      count = last == value ? count + 1 : 1;
      last = value;
      // If fresh speech begins with the repeated word ("我，我返嚟喇"),
      // retain its last occurrence rather than deleting the new subject.
      final beginsFreshContent =
          i + 1 < tokens.length && tokens[i + 1][0]!.toLowerCase() != value;
      if (count < 8 || beginsFreshContent) {
        output.write(text.substring(offset, token.end));
        kept = true;
      }
      offset = token.end;
    }
    if (kept) output.write(text.substring(offset));
    if (isFinal) {
      _last = last;
      _count = count;
      _endMs = audioMs;
    }
    return tokens.isEmpty ? text : output.toString();
  }
}
