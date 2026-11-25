import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_preferences.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_overlay.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_rollup.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_ruby.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/realtime_captions.dart';

class _MemoryBox extends Fake implements Box<dynamic> {
  final data = <dynamic, dynamic>{};
  @override
  bool get isOpen => true;
  @override
  dynamic get(dynamic key, {dynamic defaultValue}) => data[key] ?? defaultValue;
  @override
  Future<void> put(dynamic key, dynamic value) async {
    data[key] = value;
  }
}

void main() {
  const style = TextStyle(
      fontSize: 20,
      height: 1.25,
      color: Colors.white,
      fontWeight: FontWeight.w400);
  CaptionRollupEntry entry(String text) => CaptionRollupEntry(
      text: text, contextSentence: text, translation: '完整翻译');

  Widget scene(
    List<CaptionRollupEntry> entries, {
    double scale = 1,
    void Function(String, CaptionRollupEntry)? onWordTap,
    GlobalKey? captureKey,
    TextStyle textStyle = style,
    bool showPronunciation = false,
    String Function(CaptionRollupLine)? pronunciationForLine,
    List<CaptionRubyUnit> Function(CaptionRollupLine)? rubyForLine,
    double pronunciationFontSize = 8,
  }) =>
      MaterialApp(
          home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          backgroundColor: const Color(0xff003329),
          body: Center(
              child: RepaintBoundary(
            key: captureKey,
            child: Container(
              color: const Color(0xff003329),
              width: 600,
              height: 160,
              child: Center(
                  child: CaptionRollup(
                      entries: entries,
                      width: 500,
                      style: textStyle,
                      showPronunciation: showPronunciation,
                      pronunciationForLine: pronunciationForLine,
                      rubyForLine: rubyForLine,
                      pronunciationFontSize: pronunciationFontSize,
                      backgroundColor: Colors.black.withOpacity(0.75),
                      onWordTap: onWordTap ?? (_, __) {})),
            ),
          )),
        ),
      ));

  List<String> textLines(WidgetTester tester) => tester
      .widgetList(find.descendant(
          of: find.byType(CaptionRollup),
          matching: find.byWidgetPredicate((widget) =>
              widget is CaptionRubyRow ||
              (widget is Text &&
                  widget.key == const ValueKey('caption-original-line')))))
      .map((widget) => widget is CaptionRubyRow
          ? widget.line.text
          : (widget as Text).textSpan?.toPlainText() ?? widget.data ?? '')
      .toList();

  test('按真实宽度换行，保留中英文、标点、换行和 emoji', () {
    const text =
        'Protein and fiber. Okay, David is giving us a health lesson now.\n'
        '你好，世界！测试字幕滚动👋🏽 不丢字。';
    final lines = layoutCaptionRollupLines(
        entries: [entry(text)],
        width: 180,
        style: style,
        textScaler: TextScaler.noScaling,
        direction: TextDirection.ltr);
    expect(lines.length, greaterThan(2));
    expect(lines.map((line) => line.text).join().replaceAll(RegExp(r'\s'), ''),
        text.replaceAll(RegExp(r'\s'), ''));
    for (final line in lines) {
      expect(line.entry.contextSentence, text);
    }
  });

  test('新用户与旧设置首次迁移均默认两行，之后尊重主动调整', () async {
    expect(CaptionPreferences().sentenceMaxLines.value, 2);
    final box = _MemoryBox()..data['captionSentenceMaxLines'] = 6;
    final preferences = CaptionPreferences(box);
    expect(preferences.sentenceMaxLines.value, 2);
    expect(preferences.viewMode.value, 1);
    await preferences.save();
    expect(box.data['captionRollupStyleVersion'], 1);
    box.data['captionSentenceMaxLines'] = 4;
    expect(CaptionPreferences(box).sentenceMaxLines.value, 4);
  });

  test('注音字号独立保存，旧设置默认使用小字号', () async {
    final box = _MemoryBox();
    final preferences = CaptionPreferences(box);
    expect(preferences.appearance.value.pronunciationFontSize, 8);
    preferences.update(pronunciationFontSize: 7, fontSize: 22);
    await preferences.save();
    final restored = CaptionPreferences(box).appearance.value;
    expect(restored.pronunciationFontSize, 7);
    expect(restored.fontSize, 22);
  });

  testWidgets('始终两行，新行将旧行向上推出且高度固定', (tester) async {
    await tester.pumpWidget(scene([entry('First line'), entry('Second line')]));
    final window = find.byKey(const ValueKey('caption-rollup-window'));
    final rect = tester.getRect(window);
    expect(textLines(tester), ['First line', 'Second line']);
    await tester.pumpWidget(scene([
      entry('First line'),
      entry('Second line'),
      entry('Third line'),
    ]));
    expect(textLines(tester), ['First line', 'Second line', 'Third line']);
    final before =
        tester.getTopLeft(find.text('Second line', findRichText: true)).dy;
    await tester.pump(const Duration(milliseconds: 90));
    expect(tester.getTopLeft(find.text('Second line', findRichText: true)).dy,
        lessThan(before));
    await tester.pumpAndSettle();
    expect(textLines(tester), ['Second line', 'Third line']);
    expect(tester.getRect(window), rect);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同一行继续识别不重播滚动，快速连续更新不残留旧行', (tester) async {
    await tester.pumpWidget(scene([entry('Previous'), entry('Hello')]));
    await tester.pumpWidget(scene([entry('Previous'), entry('Hello world')]));
    expect(textLines(tester), ['Previous', 'Hello world']);
    await tester.pumpWidget(scene([entry('Hello world'), entry('Next')]));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpWidget(scene([entry('Next'), entry('Last')]));
    await tester.pumpAndSettle();
    expect(textLines(tester), ['Next', 'Last']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单词仍可点击查词并携带完整原句上下文', (tester) async {
    String? tappedWord;
    CaptionRollupEntry? tappedEntry;
    final original = entry('Hello world');
    await tester.pumpWidget(scene([original], onWordTap: (word, entry) {
      tappedWord = word;
      tappedEntry = entry;
    }));
    final rect = tester.getRect(find.text('Hello world', findRichText: true));
    await tester.tapAt(Offset(rect.left + 5, rect.center.dy));
    expect(tappedWord, 'Hello');
    expect(tappedEntry, same(original));
    expect(tappedEntry!.translation, '完整翻译');
  });

  testWidgets('点第二次出现的词，只传入第二句，不传整段历史', (tester) async {
    CaptionRollupEntry? tappedEntry;
    await tester.pumpWidget(scene([entry('First target.\nSecond target.')],
        onWordTap: (_, entry) => tappedEntry = entry));
    final rich = find.byWidgetPredicate((widget) =>
        widget is RichText && widget.text.toPlainText() == 'Second target.');
    final paragraph = tester.renderObject<RenderParagraph>(rich);
    final box = paragraph
        .getBoxesForSelection(
            const TextSelection(baseOffset: 7, extentOffset: 13))
        .first;
    await tester.tapAt(paragraph.localToGlobal(box.toRect().center));
    expect(tappedEntry!.contextSentence, 'Second target.');
    expect(tappedEntry!.translation, isEmpty);
  });

  testWidgets('放大字号后重新排版，仍只有两条完整行', (tester) async {
    final entries = [
      entry('Protein and fiber. Okay, David is giving us a health lesson now.')
    ];
    await tester.pumpWidget(scene(entries));
    final window = find.byKey(const ValueKey('caption-rollup-window'));
    final normal = tester.getSize(window).height;
    await tester.pumpWidget(scene(entries, scale: 2));
    await tester.pumpAndSettle();
    expect(tester.getSize(window).height, greaterThan(normal));
    expect(textLines(tester).length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('打开注音不改变旧行，新行注音与原文位于同一底框', (tester) async {
    final original = [entry('First line'), entry('Second line')];
    final converted = <String>[];
    String pronunciation(CaptionRollupLine line) {
      converted.add(line.text);
      return 'pronunciation: ${line.text}';
    }

    await tester.pumpWidget(scene(original));
    final window = find.byKey(const ValueKey('caption-rollup-window'));
    final before = tester.getRect(window);
    await tester.pumpWidget(scene(original,
        showPronunciation: true, pronunciationForLine: pronunciation));
    expect(tester.getRect(window), before);
    expect(converted, isEmpty);
    expect(
        find.byKey(const ValueKey('caption-line-pronunciation')), findsNothing);
    await tester.pumpWidget(scene([...original, entry('Third line')],
        showPronunciation: true, pronunciationForLine: pronunciation));
    await tester.pumpAndSettle();
    expect(textLines(tester), ['Second line', 'Third line']);
    expect(converted, ['Third line']);
    final phonetic = find.text('pronunciation: Third line');
    expect(phonetic, findsOneWidget);
    final backgrounds = find.ancestor(
        of: phonetic,
        matching: find.byWidgetPredicate((widget) =>
            widget is Container &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).color ==
                Colors.black.withOpacity(0.75)));
    expect(backgrounds, findsOneWidget);
    expect(
        find.descendant(
            of: backgrounds,
            matching: find.text('Third line', findRichText: true)),
        findsOneWidget);
    expect(tester.getRect(backgrounds).contains(tester.getCenter(phonetic)),
        isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('开关注音后同一行续字仍不补加，换行才带注音', (tester) async {
    CaptionRollupEntry live(String text) =>
        CaptionRollupEntry(identity: 'live', text: text, contextSentence: text);
    await tester.pumpWidget(scene([live('Old')]));
    await tester.pumpWidget(scene([live('Old growing')],
        showPronunciation: true,
        pronunciationForLine: (line) => 'pron: ${line.text}'));
    expect(
        find.byKey(const ValueKey('caption-line-pronunciation')), findsNothing);
    await tester.pumpWidget(scene([live('Old growing\nNew row')],
        showPronunciation: true,
        pronunciationForLine: (line) => 'pron: ${line.text}'));
    await tester.pumpAndSettle();
    expect(find.text('pron: Old growing'), findsNothing);
    expect(find.text('pron: New row'), findsOneWidget);
    expect(textLines(tester), ['Old growing', 'New row']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('新行预留注音空间，晚到结果和放大字号不裁切文本', (tester) async {
    CaptionRollupEntry annotated(String pronunciation) => CaptionRollupEntry(
        identity: 'a',
        text: 'Hello',
        contextSentence: 'Hello',
        pronunciation: pronunciation);
    String convert(CaptionRollupLine line) => line.entry.pronunciation;
    await tester.pumpWidget(scene([annotated('')],
        scale: 2, showPronunciation: true, pronunciationForLine: convert));
    final window = find.byKey(const ValueKey('caption-rollup-window'));
    final before = tester.getRect(window);
    await tester.pumpWidget(scene([annotated('həˈləʊ')],
        scale: 2, showPronunciation: true, pronunciationForLine: convert));
    expect(tester.getRect(window), before);
    expect(find.text('həˈləʊ'), findsOneWidget);
    expect(textLines(tester), ['Hello']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('播放器默认使用两行滚动，更新后仍保留拖动位置', (tester) async {
    final captions = RealtimeCaptions()..showOriginal.value = true;
    captions.sentenceQueue.addAll([
      CaptionSentenceItem(id: '1', original: 'First line.'),
      CaptionSentenceItem(id: '2', original: 'Second line.'),
    ]);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CaptionOverlay(
      captions: captions,
      preferences: CaptionPreferences(),
    ))));
    expect(find.byType(CaptionRollup), findsOneWidget);
    expect(textLines(tester), ['First line.', 'Second line.']);
    final handle = find.byWidgetPredicate((widget) =>
        widget is GestureDetector && widget.onVerticalDragUpdate != null);
    await tester.drag(handle, const Offset(0, -180));
    await tester.pumpAndSettle();
    final position = tester.getTopLeft(handle);
    captions.sentenceQueue
        .add(CaptionSentenceItem(id: '3', original: 'Third line.'));
    await tester.pumpAndSettle();
    expect(textLines(tester), ['Second line.', 'Third line.']);
    expect(tester.getTopLeft(handle), position);
    expect(
        tester
            .widget<Opacity>(
                find.byKey(const ValueKey('caption-drag-indicator')))
            .opacity,
        0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('播放器开启注音仅给新进入的行生成对应注音', (tester) async {
    final captions = RealtimeCaptions()..showOriginal.value = true;
    captions.sentenceQueue.addAll([
      CaptionSentenceItem(id: '1', original: '旧的一行。'),
      CaptionSentenceItem(id: '2', original: '已经显示。'),
    ]);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CaptionOverlay(
                captions: captions, preferences: CaptionPreferences()))));
    final window = find.byKey(const ValueKey('caption-rollup-window'));
    final before = tester.getRect(window);
    captions.showPronunciation.value = true;
    await tester.pump();
    expect(tester.getRect(window), before);
    expect(
        find.byKey(const ValueKey('caption-line-pronunciation')), findsNothing);
    captions.sentenceQueue.add(CaptionSentenceItem(id: '3', original: '你好。'));
    await tester.pumpAndSettle();
    final pronunciation =
        find.byKey(const ValueKey('caption-line-pronunciation'));
    expect(pronunciation, findsWidgets);
    expect(
        tester
            .widgetList<Text>(pronunciation)
            .every((item) => item.data!.isNotEmpty),
        isTrue);
    expect(textLines(tester), ['已经显示。', '你好。']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单元布局中调小注音字号会缩小间距，增量更新始终保持配对', (tester) async {
    CaptionRollupEntry live(String text) =>
        CaptionRollupEntry(text: text, contextSentence: text, identity: 'eyes');
    List<CaptionRubyUnit> ruby(CaptionRollupLine line) =>
        buildCaptionRubyUnits(line.text, sourceLanguage: 'yue');
    await tester.pumpWidget(scene([live('眼眼')],
        showPronunciation: true, rubyForLine: ruby, pronunciationFontSize: 16));
    final unit = find.byKey(const ValueKey('caption-ruby-unit-0'));
    final largeWidth = tester.getSize(unit).width;
    await tester.pumpWidget(scene([live('眼眼')],
        showPronunciation: true, rubyForLine: ruby, pronunciationFontSize: 6));
    expect(tester.getSize(unit).width, lessThan(largeWidth));
    expect(
        tester
            .widgetList<Text>(
                find.byKey(const ValueKey('caption-line-pronunciation')))
            .every((text) => text.style!.fontSize == 6),
        isTrue);
    await tester.pumpWidget(scene([live('眼球')],
        showPronunciation: true, rubyForLine: ruby, pronunciationFontSize: 6));
    final current = tester.widget<CaptionRubyRow>(find.byType(CaptionRubyRow));
    expect(current.line.rubyUnits.map((unit) => unit.text).join(), '眼球');
    expect(current.line.rubyUnits.last.pronunciation,
        buildCaptionRubyUnits('球', sourceLanguage: 'yue').single.pronunciation);
    expect(tester.takeException(), isNull);
  });

  if (const bool.fromEnvironment('CAPTION_PREVIEW')) {
    testWidgets('导出两行滚动样式预览', (tester) async {
      await tester.runAsync(() async {
        final loader = FontLoader('PreviewCJK')
          ..addFont(File('C:/Windows/Fonts/msyh.ttc')
              .readAsBytes()
              .then((bytes) => ByteData.sublistView(bytes)));
        await loader.load();
      });
      final key = GlobalKey();
      await tester.pumpWidget(scene([
        entry('外一啲專家認為，'),
        entry('陰陽眼其實係一種眼球疾病。'),
      ],
          captureKey: key,
          showPronunciation: true,
          rubyForLine: (line) =>
              buildCaptionRubyUnits(line.text, sourceLanguage: 'yue'),
          textStyle: style.copyWith(fontFamily: 'PreviewCJK', fontSize: 25)));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('scratch/caption_reference/rollup_ruby_preview.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    });
  }
}
