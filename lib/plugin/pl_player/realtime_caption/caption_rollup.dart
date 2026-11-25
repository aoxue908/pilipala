import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'caption_dictionary_sheet.dart' show CaptionWordSegmenter;
import 'caption_context.dart';
import 'caption_ruby.dart';

class CaptionRollupEntry {
  const CaptionRollupEntry({
    required this.text,
    required this.contextSentence,
    this.translation = '',
    this.contextRanges = const [],
    this.identity,
    this.pronunciation = '',
  });

  final String text;
  final String contextSentence;
  final String translation;
  final List<CaptionContextRange> contextRanges;
  final Object? identity;
  final String pronunciation;

  CaptionRollupEntry forLookup(String word, int offset) {
    final selected = captionContainingSentence(
      text: text,
      word: word,
      wordOffset: offset,
      sourceRanges: text == contextSentence ? contextRanges : const [],
    );
    if (selected == contextSentence) return this;
    return CaptionRollupEntry(text: selected, contextSentence: selected);
  }
}

class CaptionRollupLine {
  const CaptionRollupLine(this.text, this.entry, this.startOffset,
      {this.pronunciationEnabled = false,
      this.pronunciation = '',
      this.rubyUnits = const []});
  final String text;
  final CaptionRollupEntry entry;
  final int startOffset;
  final bool pronunciationEnabled;
  final String pronunciation;
  final List<CaptionRubyUnit> rubyUnits;
}

/// Measure text and reading as one unit, then wrap only between units.
List<CaptionRollupLine> layoutCaptionRubyRows(
  List<CaptionRollupLine> lines, {
  required double width,
  required TextStyle style,
  required TextStyle pronunciationStyle,
  required TextScaler textScaler,
  required TextDirection direction,
}) {
  final measuredWidths = <(String, TextStyle), double>{};
  double measure(String text, TextStyle textStyle) {
    final cached = measuredWidths[(text, textStyle)];
    if (cached != null) return cached;
    final painter = TextPainter(
        text: TextSpan(text: text, style: textStyle),
        textDirection: direction,
        textScaler: textScaler)
      ..layout();
    final result = painter.width;
    painter.dispose();
    measuredWidths[(text, textStyle)] = result;
    return result;
  }

  final result = <CaptionRollupLine>[];
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    if (line.rubyUnits.isEmpty) {
      result.add(line);
      continue;
    }
    final entry = line.entry;
    final units = <CaptionRubyUnit>[];
    void append(CaptionRollupLine next) {
      units.addAll(next.rubyUnits.map((unit) => CaptionRubyUnit(
          unit.text, unit.pronunciation, next.startOffset + unit.startOffset)));
    }

    append(line);
    // TextPainter's plain-text wraps need not become hard breaks in ruby mode.
    while (index + 1 < lines.length &&
        identical(lines[index + 1].entry, entry) &&
        lines[index + 1].rubyUnits.isNotEmpty) {
      final next = lines[index + 1];
      final end = units.last.startOffset + units.last.text.length;
      final gap = entry.text.substring(end, next.startOffset);
      if (gap.contains('\n') || gap.contains('\r')) break;
      if (gap.isNotEmpty) units.add(CaptionRubyUnit(gap, '', end));
      append(next);
      index++;
    }
    var row = <CaptionRubyUnit>[];
    var used = 0.0;
    void flush() {
      if (row.isEmpty) return;
      final start = row.first.startOffset;
      final end = row.last.startOffset + row.last.text.length;
      result.add(CaptionRollupLine(
          entry.text.substring(start, end), entry, start,
          pronunciationEnabled: true,
          rubyUnits: [
            for (final unit in row)
              CaptionRubyUnit(
                  unit.text, unit.pronunciation, unit.startOffset - start,
                  width: unit.width)
          ]));
      row = [];
      used = 0;
    }

    for (final unit in units) {
      if (unit.text == '\n' || unit.text == '\r' || unit.text == '\r\n') {
        flush();
        continue;
      }
      final measured = math.max(measure(unit.text, style),
              measure(unit.pronunciation, pronunciationStyle)) +
          (unit.pronunciation.isEmpty ? 0 : 2);
      final unitWidth = math.min(math.max(1.0, width), measured);
      if (row.isNotEmpty && used + unitWidth > width) flush();
      row.add(CaptionRubyUnit(unit.text, unit.pronunciation, unit.startOffset,
          width: unitWidth));
      used += unitWidth;
    }
    flush();
  }
  return result;
}

/// 使用 Flutter 实际字体排版得到完整行，避免按字符估宽裁掉英文词头。
List<CaptionRollupLine> layoutCaptionRollupLines({
  required List<CaptionRollupEntry> entries,
  required double width,
  required TextStyle style,
  required TextScaler textScaler,
  required TextDirection direction,
}) {
  final lines = <CaptionRollupLine>[];
  for (final entry in entries) {
    if (entry.text.trim().isEmpty) continue;
    final painter = TextPainter(
      text: TextSpan(text: entry.text, style: style),
      textDirection: direction,
      textScaler: textScaler,
      strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: true),
    )..layout(maxWidth: math.max(1, width));
    for (final metric in painter.computeLineMetrics()) {
      final position = painter.getPositionForOffset(
        Offset(metric.left + 0.1, metric.baseline),
      );
      final range = painter.getLineBoundary(position);
      final raw = entry.text.substring(range.start, range.end);
      final text = raw.trim();
      if (text.isNotEmpty) {
        lines.add(CaptionRollupLine(
            text, entry, range.start + raw.length - raw.trimLeft().length));
      }
    }
    painter.dispose();
  }
  return lines;
}

/// 固定行数的向上滚动窗口。行内增量直接更新，新行进入时才滚动。
class CaptionRollup extends StatefulWidget {
  const CaptionRollup({
    super.key,
    required this.entries,
    required this.width,
    required this.style,
    required this.backgroundColor,
    required this.onWordTap,
    this.maxLines = 2,
    this.showPronunciation = false,
    this.pronunciationForLine,
    this.pronunciationColor,
    this.rubyForLine,
    this.rubyForEntry,
    this.pronunciationFontSize = 8,
  });

  final List<CaptionRollupEntry> entries;
  final double width;
  final TextStyle style;
  final Color backgroundColor;
  final int maxLines;
  final bool showPronunciation;
  final String Function(CaptionRollupLine)? pronunciationForLine;
  final Color? pronunciationColor;
  final double pronunciationFontSize;
  final List<CaptionRubyUnit> Function(CaptionRollupLine)? rubyForLine;

  /// Contextual languages are tokenized before visual wrapping, once per entry.
  final List<CaptionRubyUnit>? Function(CaptionRollupEntry)? rubyForEntry;
  final void Function(String word, CaptionRollupEntry entry) onWordTap;

  @override
  State<CaptionRollup> createState() => _CaptionRollupState();
}

class _CaptionRollupState extends State<CaptionRollup>
    with SingleTickerProviderStateMixin {
  static const horizontalPadding = 6.0;
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: 1,
  );
  List<CaptionRollupLine?> _rows = [];
  List<CaptionRollupLine?> _outgoing = [];
  int _shift = 0;
  double _lineHeight = 0;
  double _pronunciationHeight = 0;
  double _previousHeight = 0;
  double? _lastWidth;
  TextScaler? _lastScaler;

  TextStyle get _pronunciationStyle => widget.style.copyWith(
      fontSize: widget.pronunciationFontSize,
      height: 1.1,
      color: widget.pronunciationColor ?? widget.style.color);

  double _height(CaptionRollupLine? line) =>
      _lineHeight +
      (line?.pronunciationEnabled == true ? _pronunciationHeight : 0);

  bool _sameLine(CaptionRollupLine a, CaptionRollupLine b) {
    if (a.startOffset != b.startOffset) return false;
    if (a.entry.identity != null || b.entry.identity != null) {
      return a.entry.identity == b.entry.identity;
    }
    return a.entry.text.startsWith(b.entry.text) ||
        b.entry.text.startsWith(a.entry.text);
  }

  CaptionRollupLine _present(CaptionRollupLine line) {
    CaptionRollupLine? previous;
    for (final row in [..._rows, ..._outgoing]) {
      if (row != null && _sameLine(row, line)) {
        previous = row;
        break;
      }
    }
    // Eligibility is latched when a row first enters the visible window.
    // Enabling pronunciation must not retrofit already displayed rows.
    final enabled =
        widget.showPronunciation && (previous?.pronunciationEnabled ?? true);
    final pronunciation = !enabled
        ? ''
        : previous != null &&
                previous.text == line.text &&
                previous.entry.pronunciation == line.entry.pronunciation
            ? previous.pronunciation
            : widget.pronunciationForLine?.call(line) ?? '';
    return CaptionRollupLine(line.text, line.entry, line.startOffset,
        pronunciationEnabled: enabled,
        pronunciation: pronunciation,
        rubyUnits: enabled
            ? line.rubyUnits.isNotEmpty
                ? line.rubyUnits
                : widget.rubyForLine?.call(line) ?? const []
            : const []);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reflow(animate: false);
  }

  @override
  void didUpdateWidget(CaptionRollup oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reflow(
        animate: oldWidget.style == widget.style &&
            oldWidget.pronunciationFontSize == widget.pronunciationFontSize &&
            oldWidget.maxLines == widget.maxLines);
  }

  void _reflow({required bool animate}) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    animate = animate && _lastWidth == widget.width && _lastScaler == scaler;
    _lastWidth = widget.width;
    _lastScaler = scaler;
    final probe = TextPainter(
      text: TextSpan(text: '国Ag', style: widget.style),
      textDirection: direction,
      textScaler: scaler,
      strutStyle:
          StrutStyle.fromTextStyle(widget.style, forceStrutHeight: true),
    )..layout();
    _lineHeight = probe.height + 4;
    probe.dispose();
    final pronunciationProbe = TextPainter(
      text: TextSpan(text: 'Ag', style: _pronunciationStyle),
      textDirection: direction,
      textScaler: scaler,
      strutStyle:
          StrutStyle.fromTextStyle(_pronunciationStyle, forceStrutHeight: true),
    )..layout();
    _pronunciationHeight = pronunciationProbe.height + 2;
    pronunciationProbe.dispose();
    final plainLines = <CaptionRollupLine>[];
    for (final entry in widget.entries) {
      final existingWithoutRuby = [..._rows, ..._outgoing].any((row) =>
          row != null &&
          !row.pronunciationEnabled &&
          (entry.identity != null
              ? row.entry.identity == entry.identity
              : row.entry.text == entry.text));
      final entryUnits = widget.showPronunciation && !existingWithoutRuby
          ? widget.rubyForEntry?.call(entry)
          : null;
      if (entryUnits != null && entryUnits.isNotEmpty) {
        plainLines.addAll(layoutCaptionRubyRows([
          CaptionRollupLine(entry.text, entry, 0,
              pronunciationEnabled: true, rubyUnits: entryUnits),
        ],
            width: widget.width - 2 * horizontalPadding,
            style: widget.style,
            pronunciationStyle: _pronunciationStyle,
            textScaler: scaler,
            direction: direction));
        continue;
      }
      plainLines.addAll(layoutCaptionRollupLines(
        entries: [entry],
        width: widget.width - 2 * horizontalPadding,
        style: widget.style,
        textScaler: scaler,
        direction: direction,
      ));
    }
    final lines = layoutCaptionRubyRows(plainLines.map(_present).toList(),
        width: widget.width - 2 * horizontalPadding,
        style: widget.style,
        pronunciationStyle: _pronunciationStyle,
        textScaler: scaler,
        direction: direction);
    final count = widget.maxLines.clamp(2, 6);
    final next = <CaptionRollupLine?>[
      ...List<CaptionRollupLine?>.filled(
          math.max(0, count - lines.length), null),
      ...lines.skip(math.max(0, lines.length - count)),
    ];
    bool same(CaptionRollupLine? a, CaptionRollupLine? b) => a?.text == b?.text;
    final unchanged = _rows.length == count &&
        List.generate(count, (i) => i).every((i) => same(_rows[i], next[i]));
    if (unchanged) {
      _rows = next;
      return;
    }
    _controller.stop();
    _previousHeight = _rows.fold(0, (sum, row) => sum + _height(row));
    _controller.value = 1;
    _shift = 0;
    _outgoing = [];
    if (animate && _rows.length == count) {
      // 上面各行未变时只是最末行继续识别，不重新播放整框动画。
      final lastLineOnly = List.generate(count - 1, (i) => i)
          .every((i) => same(_rows[i], next[i]));
      if (!lastLineOnly) {
        var overlap = 0;
        for (var size = count - 1; size > 0; size--) {
          if (List.generate(size, (i) => i)
              .every((i) => same(_rows[count - size + i], next[i]))) {
            overlap = size;
            break;
          }
        }
        _shift = count - overlap;
        _outgoing = _rows.take(_shift).toList();
      }
    }
    _rows = next;
    if (_shift > 0 && !MediaQuery.disableAnimationsOf(context)) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final moving = _controller.value < 1 && _shift > 0;
          final progress = Curves.easeOutCubic.transform(_controller.value);
          final rows = moving ? [..._outgoing, ..._rows] : _rows;
          final height =
              _rows.fold<double>(0, (sum, row) => sum + _height(row));
          final outgoingHeight =
              _outgoing.fold<double>(0, (sum, row) => sum + _height(row));
          var top = moving ? -outgoingHeight * progress : 0.0;
          final children = <Widget>[];
          for (final row in rows) {
            final rowHeight = _height(row);
            if (row != null) {
              children.add(Positioned(
                left: 0,
                right: 0,
                top: top,
                height: rowHeight,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: _CaptionRollupLineView(
                    line: row,
                    style: widget.style,
                    pronunciationStyle: _pronunciationStyle,
                    pronunciationHeight: _pronunciationHeight,
                    originalHeight: _lineHeight - 4,
                    backgroundColor: widget.backgroundColor,
                    onWordTap: widget.onWordTap,
                  ),
                ),
              ));
            }
            top += rowHeight;
          }
          return SizedBox(
            key: const ValueKey('caption-rollup-window'),
            width: widget.width,
            height: moving
                ? _previousHeight + (height - _previousHeight) * progress
                : height,
            child: ClipRect(
                child: Stack(clipBehavior: Clip.none, children: children)),
          );
        },
      );
}

class _CaptionRollupLineView extends StatefulWidget {
  const _CaptionRollupLineView(
      {required this.line,
      required this.style,
      required this.pronunciationStyle,
      required this.pronunciationHeight,
      required this.originalHeight,
      required this.backgroundColor,
      required this.onWordTap});
  final CaptionRollupLine line;
  final TextStyle style;
  final TextStyle pronunciationStyle;
  final double pronunciationHeight;
  final double originalHeight;
  final Color backgroundColor;
  final void Function(String, CaptionRollupEntry) onWordTap;

  @override
  State<_CaptionRollupLineView> createState() => _CaptionRollupLineViewState();
}

class _CaptionRollupLineViewState extends State<_CaptionRollupLineView> {
  final _recognizers = <TapGestureRecognizer>[];
  List<InlineSpan> _spans = [];

  void _updateSpans() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
    _spans = [];
    var offset = 0;
    for (final token
        in CaptionWordSegmenter.segmentWithDelimiters(widget.line.text)) {
      _spans.add(TextSpan(
          text: token.text,
          recognizer: token.isWord ? _recognizer(token.text, offset) : null));
      offset += token.text.length;
    }
    if (_spans.isEmpty) _spans = [TextSpan(text: widget.line.text)];
  }

  TapGestureRecognizer _recognizer(String word, int offset) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () => widget.onWordTap(word,
          widget.line.entry.forLookup(word, widget.line.startOffset + offset));
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  void initState() {
    super.initState();
    _updateSpans();
  }

  @override
  void didUpdateWidget(_CaptionRollupLineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.line.text != widget.line.text) _updateSpans();
  }

  @override
  void dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onLongPress: () {
          final entry = widget.line.entry
              .forLookup(widget.line.text, widget.line.startOffset);
          widget.onWordTap(entry.contextSentence, entry);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
              color: widget.backgroundColor,
              borderRadius: BorderRadius.circular(4)),
          child: widget.line.rubyUnits.isNotEmpty
              ? CaptionRubyRow(
                  line: widget.line,
                  style: widget.style,
                  pronunciationStyle: widget.pronunciationStyle,
                  pronunciationHeight: widget.pronunciationHeight,
                  originalHeight: widget.originalHeight,
                  onWordTap: widget.onWordTap,
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.line.pronunciationEnabled)
                      SizedBox(
                        height: widget.pronunciationHeight,
                        child: widget.line.pronunciation.isEmpty
                            ? null
                            : FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: AlignmentDirectional.centerStart,
                                child: Text(widget.line.pronunciation,
                                    key: const ValueKey(
                                        'caption-line-pronunciation'),
                                    style: widget.pronunciationStyle,
                                    strutStyle: StrutStyle.fromTextStyle(
                                        widget.pronunciationStyle,
                                        forceStrutHeight: true),
                                    maxLines: 1,
                                    softWrap: false),
                              ),
                      ),
                    Text.rich(
                      TextSpan(children: _spans),
                      key: const ValueKey('caption-original-line'),
                      style: widget.style,
                      strutStyle: StrutStyle.fromTextStyle(widget.style,
                          forceStrutHeight: true),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                    ),
                  ],
                ),
        ),
      );
}

class CaptionRubyRow extends StatelessWidget {
  const CaptionRubyRow(
      {super.key,
      required this.line,
      required this.style,
      required this.pronunciationStyle,
      required this.pronunciationHeight,
      required this.originalHeight,
      required this.onWordTap});
  final CaptionRollupLine line;
  final TextStyle style;
  final TextStyle pronunciationStyle;
  final double pronunciationHeight;
  final double originalHeight;
  final void Function(String, CaptionRollupEntry) onWordTap;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final unit in line.rubyUnits)
            GestureDetector(
              key: ValueKey(
                  'caption-ruby-unit-${line.startOffset + unit.startOffset}'),
              behavior: HitTestBehavior.opaque,
              onTap: RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(unit.text)
                  ? () => onWordTap(
                      unit.text,
                      line.entry.forLookup(
                          unit.text, line.startOffset + unit.startOffset))
                  : null,
              child: SizedBox(
                width: unit.width,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(
                      height: pronunciationHeight,
                      child: unit.pronunciation.isEmpty
                          ? null
                          : FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(unit.pronunciation,
                                  key: const ValueKey(
                                      'caption-line-pronunciation'),
                                  style: pronunciationStyle,
                                  maxLines: 1,
                                  softWrap: false,
                                  strutStyle: StrutStyle.fromTextStyle(
                                      pronunciationStyle,
                                      forceStrutHeight: true)),
                            )),
                  SizedBox(
                      height: originalHeight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(unit.text,
                            style: style,
                            maxLines: 1,
                            softWrap: false,
                            strutStyle: StrutStyle.fromTextStyle(style,
                                forceStrutHeight: true)),
                      )),
                ]),
              ),
            ),
        ],
      );
}
