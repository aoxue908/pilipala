import 'dart:math' as math;
import 'dart:typed_data';

import 'package:characters/characters.dart';

import 'asr_stream.dart';

typedef CaptionAnchor = ({int offset, int audioMs});
typedef _SpeechRange = ({int startMs, int endMs});

class CaptionCue {
  const CaptionCue({
    required this.text,
    required this.startMs,
    required this.endMs,
    required this.canTranslate,
    required this.highlights,
  });

  final String text;
  final int startMs;
  final int endMs;
  final bool canTranslate;
  final List<CaptionAnchor> highlights;

  int highlightAt(int positionMs) {
    var offset = 0;
    for (final mark in highlights) {
      if (positionMs < mark.audioMs) break;
      offset = mark.offset;
    }
    return offset;
  }
}

class CaptionTimeline {
  CaptionTimeline(Iterable<CaptionCue> cues)
      : _cues = cues.toList()..sort((a, b) => a.startMs.compareTo(b.startMs)) {
    var lastEnd = 0;
    for (final cue in _cues) {
      lastEnd = math.max(lastEnd, cue.endMs);
      _endThrough.add(lastEnd);
    }
  }

  final List<CaptionCue> _cues;
  final _endThrough = <int>[];

  bool get isEmpty => _cues.isEmpty;
  int? get endMs => _endThrough.isEmpty ? null : _endThrough.last;

  int _firstAfter(int positionMs) {
    var low = 0;
    var high = _endThrough.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_endThrough[mid] <= positionMs) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  CaptionCue? at(int positionMs) {
    CaptionCue? active;
    for (var i = _firstAfter(positionMs); i < _cues.length; i++) {
      final cue = _cues[i];
      if (cue.startMs > positionMs) break;
      if (cue.endMs > positionMs) active = cue;
    }
    return active;
  }

  Iterable<CaptionCue> upcoming(int positionMs, int throughMs) sync* {
    for (var i = _firstAfter(positionMs); i < _cues.length; i++) {
      final cue = _cues[i];
      if (cue.startMs >= throughMs) break;
      if (cue.endMs > positionMs && cue.canTranslate) yield cue;
    }
  }

  factory CaptionTimeline.fromVideo(List<dynamic> body) {
    final cues = <CaptionCue>[];
    for (final item in body) {
      if (item is! Map) continue;
      final from = item['from'];
      final to = item['to'];
      final text = item['content'];
      if (from is! num ||
          to is! num ||
          !from.isFinite ||
          !to.isFinite ||
          from < 0 ||
          to <= from ||
          text is! String) {
        continue;
      }
      final trimmed = text.trim();
      if (trimmed.isEmpty) continue;
      // 超长单句（>50字符）保留拆分能力，常规长度字幕保持原始精确时间戳，避免因标点分句导致后半句人为推迟
      if (trimmed.length > 50) {
        cues.addAll(buildCaptionCues(
          trimmed,
          startMs: (from * 1000).round(),
          spokenEndMs: (to * 1000).round(),
          isFinal: true,
          lingerMs: 0,
        ));
      } else {
        final startMs = (from * 1000).round();
        final endMs = (to * 1000).round();
        cues.add(CaptionCue(
          text: trimmed,
          startMs: startMs,
          endMs: math.max(startMs + 1, endMs),
          canTranslate: true,
          highlights: const [],
        ));
      }
    }
    return CaptionTimeline(cues);
  }
}

class AsrCaptionTiming {
  AsrCaptionTiming(this._originMs)
      : speech = CaptionSpeech(_originMs),
        _previousEndMs = _originMs;

  AsrCaptionTiming.fromPlayback(int positionMs, {int? resumeFromMs})
      : this(math.max(
            0, math.max(positionMs - 250, resumeFromMs ?? positionMs)));

  final int _originMs;
  final CaptionSpeech speech;
  final _anchors = <CaptionAnchor>[];
  int _previousEndMs;
  int? _utterance;
  int _startMs = 0;
  int _endMs = 0;
  int _lastOffset = 0;

  int get originMs => _originMs;
  int get confirmedEndMs => _previousEndMs;

  List<CaptionCue> update(
    AsrCaption caption, {
    required int sentMs,
    required int chunkMs,
  }) {
    final processedMs =
        _originMs + math.min<int>(caption.audioMs ?? sentMs, sentMs);
    if (_utterance != caption.utterance) {
      if (caption.startAudioMs != null) {
        _startMs = _originMs + caption.startAudioMs!;
      } else {
        final earliest = math.max(_previousEndMs, processedMs - 3 * chunkMs);
        _startMs = speech.firstSpeech(earliest, processedMs) ?? earliest;
      }
      _endMs = math.max(processedMs, _startMs + 1);
      _utterance = caption.utterance;
      _lastOffset = caption.text.length;
      _anchors.clear();
    }
    if (caption.text.length > _lastOffset) {
      final endMs = speech.lastSpeech(_endMs, processedMs) ?? processedMs;
      _endMs = math.max(_endMs, math.max(endMs, _startMs + 1));
      _lastOffset = caption.text.length;
      _anchors.add((offset: _lastOffset, audioMs: _endMs));
    }
    if (caption.isFinal) {
      _previousEndMs = _endMs;
    }
    return buildCaptionCues(
      caption.text,
      startMs: _startMs,
      spokenEndMs: _endMs,
      isFinal: caption.isFinal,
      anchors: _anchors,
      speech: speech,
      lingerMs: 1100,
    );
  }
}

// The ASR protocol reports processed audio but has no word timestamps.
// Sample energy locates pauses in that same timeline without dropping audio.
class CaptionSpeech {
  CaptionSpeech(this._originMs);

  final int _originMs;
  final _ranges = <_SpeechRange>[];
  int _samples = 0;
  int _samplesInWindow = 0;
  double _power = 0;
  double? _peakWindowPower;
  int _activeMs = 0;

  int get activeMs => _activeMs;

  int? takePeakRmsDbfs() {
    final power = _peakWindowPower;
    _peakWindowPower = null;
    if (power == null) return null;
    final rms = math.max(1, math.sqrt(power / 320));
    return (20 * math.log(rms / 32768) / math.ln10).round();
  }

  void add(Uint8List pcm) {
    final data = ByteData.sublistView(pcm);
    for (var index = 0; index + 1 < pcm.length; index += 2) {
      final sample = data.getInt16(index, Endian.little);
      _power += sample * sample;
      _samples++;
      _samplesInWindow++;
      if (_samplesInWindow < 320) continue;
      _peakWindowPower = math.max(_peakWindowPower ?? 0, _power);
      if (_power >= 320 * 131 * 131) {
        _activeMs += 20;
        final end = _originMs + _samples ~/ 16;
        final start = end - 20;
        if (_ranges.isNotEmpty && _ranges.last.endMs == start) {
          _ranges.last = (startMs: _ranges.last.startMs, endMs: end);
        } else {
          _ranges.add((startMs: start, endMs: end));
        }
      }
      _power = 0;
      _samplesInWindow = 0;
    }
  }

  Iterable<_SpeechRange> _within(int startMs, int endMs) sync* {
    for (final range in _ranges) {
      if (range.endMs <= startMs) continue;
      if (range.startMs >= endMs) break;
      yield (
        startMs: math.max(range.startMs, startMs),
        endMs: math.min(range.endMs, endMs),
      );
    }
  }

  int? firstSpeech(int startMs, int endMs) {
    for (final range in _within(startMs, endMs)) {
      return range.startMs;
    }
    return null;
  }

  int? lastSpeech(int startMs, int endMs) {
    if (endMs <= startMs) return null;
    for (final range in _ranges.reversed) {
      if (range.startMs >= endMs) continue;
      if (range.endMs <= startMs) break;
      return math.min(range.endMs, endMs);
    }
    return null;
  }

  int Function(double) _interpolator(int startMs, int endMs) {
    final ranges = _within(startMs, endMs).toList(growable: false);
    final length =
        ranges.fold(0, (sum, range) => sum + range.endMs - range.startMs);
    if (length == 0) {
      return (fraction) => startMs + ((endMs - startMs) * fraction).round();
    }
    return (fraction) {
      var remaining = (length * fraction).round();
      for (final range in ranges) {
        final duration = range.endMs - range.startMs;
        if (remaining < duration) return range.startMs + remaining;
        remaining -= duration;
      }
      return ranges.last.endMs;
    };
  }
}

final _word = RegExp(r'[\p{L}\p{N}\p{M}]', unicode: true);
final _unspaced = RegExp(
  r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}'
  r'\p{Script=Thai}\p{Script=Lao}\p{Script=Khmer}\p{Script=Myanmar}]',
  unicode: true,
);
final _sentenceEnd = RegExp(r'[.!?。！？…]');
final _clauseEnd = RegExp(r'[,;:，；：、]');
final _apostrophe = RegExp(r"['’\-]");
final _closingQuote = RegExp(r'''^["'”’」』》）)\]]+$''');

class _Glyph {
  _Glyph(this.text, this.start)
      : spaced = text.trim().isEmpty,
        spoken = _word.hasMatch(text),
        unspaced = _unspaced.hasMatch(text);

  final String text;
  final int start;
  final bool spaced;
  final bool spoken;
  final bool unspaced;

  int get end => start + text.length;
  int get width => unspaced || text.runes.first >= 0x2e80 ? 2 : 1;
  int get weight => spoken ? (unspaced ? 3 : 1) : 0;
}

List<CaptionCue> buildCaptionCues(
  String text, {
  required int startMs,
  required int spokenEndMs,
  required bool isFinal,
  List<CaptionAnchor> anchors = const [],
  CaptionSpeech? speech,
  int lingerMs = 500,
}) {
  if (text.trim().isEmpty || spokenEndMs <= startMs) return const [];
  final glyphs = <_Glyph>[];
  final weights = List<int>.filled(text.length + 1, 0);
  var offset = 0;
  var weight = 0;
  for (final grapheme in text.characters) {
    final glyph = _Glyph(grapheme, offset);
    glyphs.add(glyph);
    weights.fillRange(offset, glyph.end, weight);
    weight += glyph.weight;
    offset = glyph.end;
  }
  weights.last = weight;
  final timed = weight > 0;
  if (!timed) {
    for (var i = 0; i <= text.length; i++) {
      weights[i] = i;
    }
    weight = text.length;
  }
  final timing = <({int weight, int audioMs})>[(weight: 0, audioMs: startMs)];
  for (final anchor in anchors) {
    final point = weights[anchor.offset.clamp(0, text.length)];
    if (point > timing.last.weight &&
        point < weight &&
        anchor.audioMs > timing.last.audioMs &&
        anchor.audioMs < spokenEndMs) {
      timing.add((weight: point, audioMs: anchor.audioMs));
    }
  }
  timing.add((weight: weight, audioMs: spokenEndMs));
  final interpolate = [
    for (var i = 0; i + 1 < timing.length; i++)
      speech?._interpolator(timing[i].audioMs, timing[i + 1].audioMs),
  ];

  int timeAt(double point, {bool afterPause = true}) {
    var low = 0;
    var high = timing.length - 1;
    while (low + 1 < high) {
      final mid = (low + high) ~/ 2;
      if (timing[mid].weight < point ||
          (afterPause && timing[mid].weight == point)) {
        low = mid;
      } else {
        high = mid;
      }
    }
    if (point <= 0) return startMs;
    if (point >= weight) return spokenEndMs;
    final left = timing[low];
    final right = timing[high];
    final fraction =
        ((point - left.weight) / (right.weight - left.weight)).clamp(0.0, 1.0);
    return interpolate[low]?.call(fraction) ??
        left.audioMs + ((right.audioMs - left.audioMs) * fraction).round();
  }

  final cues = <CaptionCue>[];
  final textEnd = text.trimRight().length;
  for (var first = 0; first < glyphs.length;) {
    if (glyphs[first].spaced) {
      first++;
      continue;
    }
    final part = _captionBreak(glyphs, first);
    var last = part.end;
    while (last > first + 1 && glyphs[last - 1].spaced) {
      last--;
    }
    final start = glyphs[first].start;
    final end = glyphs[last - 1].end;
    final line = text.substring(start, end);
    final lineStart = timeAt(weights[start].toDouble());
    final lineEnd = timeAt(weights[end].toDouble(), afterPause: false);
    final marks = <CaptionAnchor>[];
    for (var i = first; i < last; i++) {
      final glyph = glyphs[i];
      if (!glyph.spoken) continue;
      // Start coloring a grapheme near its estimated spoken onset.
      final audioMs = timeAt(weights[glyph.start] + glyph.weight * 0.3);
      marks.add((offset: glyph.end - start, audioMs: audioMs));
    }
    if (timed) marks.add((offset: line.length, audioMs: lineEnd));
    cues.add(CaptionCue(
      text: line,
      startMs: lineStart,
      endMs: math.max(lineStart + 1, lineEnd + (end < textEnd ? 0 : lingerMs)),
      canTranslate: isFinal || part.closed,
      highlights: marks,
    ));
    first = part.end;
  }
  return cues;
}

({int end, bool closed}) _captionBreak(List<_Glyph> glyphs, int start) {
  const maxWidth = 38;
  var width = 0;
  int? wordEnd;
  int? clauseEnd;
  for (var i = start; i < glyphs.length; i++) {
    final glyph = glyphs[i];
    final next = i + 1 < glyphs.length ? glyphs[i + 1] : null;
    width += glyph.width;
    if (width > maxWidth) {
      return (end: clauseEnd ?? wordEnd ?? i, closed: true);
    }
    if (glyph.text.contains('\n') && i > start) {
      return (end: i + 1, closed: true);
    }
    final boundary = next == null ||
        next.spaced ||
        glyph.unspaced ||
        next.unspaced ||
        (!glyph.spoken && !_apostrophe.hasMatch(glyph.text)) ||
        _sentenceEnd.hasMatch(glyph.text);
    if (!boundary) continue;
    if (_sentenceEnd.hasMatch(glyph.text) && width >= 12) {
      // Keep the closing quote with the sentence.
      var end = i + 1;
      while (end < glyphs.length && _closingQuote.hasMatch(glyphs[end].text)) {
        end++;
      }
      return (end: end, closed: true);
    }
    if (_clauseEnd.hasMatch(glyph.text) && width >= maxWidth ~/ 2) {
      clauseEnd = i + 1;
    }
    if (width >= maxWidth ~/ 2) wordEnd = i + 1;
  }
  return (end: glyphs.length, closed: false);
}

// Interpolate between position samples only while playback is advancing.
class CaptionPlaybackClock {
  int _positionMs = 0;
  int _sampleMs = 0;
  double _rate = 1;
  bool _moving = false;

  void update(int positionMs, int nowMs,
      {required bool moving, required double rate}) {
    _positionMs = positionMs;
    _sampleMs = nowMs;
    _moving = moving;
    _rate = rate;
  }

  int at(int nowMs) {
    if (!_moving) return _positionMs;
    // 允许在播放期间平滑外推至多 2000ms（避免 media_kit 250~500ms 采样间隔内时钟提前冻结导致字幕慢一拍）
    final delta = (nowMs - _sampleMs).clamp(0, 2000);
    return _positionMs + (delta * _rate).round();
  }
}
