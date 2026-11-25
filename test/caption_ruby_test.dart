import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_ruby.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_rollup.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_overlay.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_offline_dictionary.dart';

void main() {
  test('用户列出的口语字逐项支持自动语言、注音和离线查词', () {
    const expected = {
      '佢': 'keoi5',
      '嘅': 'ge3',
      '咗': 'zo2',
      '喺': 'hai2',
      '乜嘢': 'mat1 je5',
      '嚟': 'lei4',
      '嗰': 'go2',
      '咁': 'gam2',
      '唔': 'm4',
    };
    for (final entry in expected.entries) {
      expect(solveQueryLanguage(sentence: entry.key, query: entry.key), 'yue');
      for (final language in ['auto', 'zh-CN', 'yue']) {
        final units =
            buildCaptionRubyUnits(entry.key, sourceLanguage: language);
        expect(units.map((unit) => unit.text).join(), entry.key);
        expect(units.map((unit) => unit.pronunciation).join(' '), entry.value,
            reason: '${entry.key} / $language');
      }
      final result = CaptionOfflineDictionary.shared.lookup(entry.key);
      expect(result, isNotNull, reason: entry.key);
      expect(result!.phonetic, entry.value);
      expect(result.sourceLanguage, 'yue');
      expect(
          result.definitions.first.meanings.first, isNot(contains('粤语发音词条')));
    }
    // Combined lookup must use the same updated reading table as the overlay.
    expect(
        CaptionOfflineDictionary.shared
            .lookup('佢喺嗰度嘅', isCantonese: true)!
            .phonetic,
        'keoi5 hai2 go2 dou6 ge3');
  });

  test('常见粤语口语字完整注音，噶、㗎、嘅不混作同一个字', () {
    final units = buildCaptionRubyUnits('噶㗎嘅嘢咩啲喺咗噉啩', sourceLanguage: 'yue');
    expect(units.map((unit) => unit.pronunciation), [
      'gaa1',
      'gaa3',
      'ge3',
      'je5',
      'me1',
      'di1',
      'hai2',
      'zo2',
      'gam2',
      'gwaa3'
    ]);
    expect(units.map((unit) => unit.text).join(), '噶㗎嘅嘢咩啲喺咗噉啩');
  });

  test('无粤语轨标记的口语行也不把嘢咩送进普通话注音表', () {
    for (final language in ['auto', 'zh', 'zh-CN', 'yue']) {
      expect(
          buildCaptionRubyUnits('咩嘢', sourceLanguage: language)
              .map((unit) => unit.pronunciation),
          ['me1', 'je5']);
    }
    expect(solveQueryLanguage(sentence: '咩嘢', query: '嘢'), 'yue');
    expect(solveQueryLanguage(sentence: '普通中文句子', query: '中文'), 'zh-CN');
    expect(solveQueryLanguage(sentence: 'これは日本語です', query: '日本語'), 'ja');
  });

  test('粤语生僻字留空，不能把后续读音向前挪', () {
    final units = buildCaptionRubyUnits('你蠥好，眼球。', sourceLanguage: 'yue');
    expect(units.map((unit) => unit.text).join(), '你蠥好，眼球。');
    expect(units[0].pronunciation, isNotEmpty);
    expect(units[1].pronunciation, isEmpty);
    expect(units[2].pronunciation,
        buildCaptionRubyUnits('好', sourceLanguage: 'yue').single.pronunciation);
    for (final unit in units) {
      expect(
          '你蠥好，眼球。'
              .substring(unit.startOffset, unit.startOffset + unit.text.length),
          unit.text);
    }
  });

  test('英文按词组合，标点空格与emoji不丢失', () {
    const text = "Hello, world! 👋🏽 Don't stop.\n你好。";
    final units = buildCaptionRubyUnits(text, sourceLanguage: 'en');
    expect(units.map((unit) => unit.text).join(), text);
    expect(units.where((unit) => unit.text == "Don't"), hasLength(1));
    expect(units.first.pronunciation, isNotEmpty);
    expect(units.firstWhere((unit) => unit.text == ',').pronunciation, isEmpty);
  });

  testWidgets('单元一起换行、上下居中，点击注音仍查对应原文', (tester) async {
    const text = '你蠥好眼球病';
    const style = TextStyle(fontSize: 22, height: 1.25);
    const entry = CaptionRollupEntry(text: text, contextSentence: text);
    final units = buildCaptionRubyUnits(text, sourceLanguage: 'yue');
    List<CaptionRollupLine> layout(double fontSize) => layoutCaptionRubyRows([
          CaptionRollupLine(text, entry, 0,
              pronunciationEnabled: true, rubyUnits: units),
        ],
            width: 110,
            style: style,
            pronunciationStyle: TextStyle(fontSize: fontSize, height: 1.1),
            textScaler: TextScaler.noScaling,
            direction: TextDirection.ltr);
    final rows = layout(8);
    expect(rows.map((line) => line.text).join(), text);
    expect(rows.length, greaterThan(1));
    expect(layout(16).length, greaterThanOrEqualTo(rows.length));
    for (final row in rows) {
      expect(row.rubyUnits.fold<double>(0, (sum, unit) => sum + unit.width),
          lessThanOrEqualTo(110));
    }
    String? tapped;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in rows)
          CaptionRubyRow(
              line: row,
              style: style,
              pronunciationStyle: const TextStyle(fontSize: 8, height: 1.1),
              pronunciationHeight: 12,
              originalHeight: 28,
              onWordTap: (word, entry) {
                tapped = word;
                expect(entry.contextSentence, text);
              })
      ],
    )))));
    for (final row in rows) {
      for (final unit
          in row.rubyUnits.where((unit) => unit.pronunciation.isNotEmpty)) {
        final parent = find.byKey(ValueKey(
            'caption-ruby-unit-${row.startOffset + unit.startOffset}'));
        final original =
            find.descendant(of: parent, matching: find.text(unit.text));
        final reading = find.descendant(
            of: parent, matching: find.text(unit.pronunciation));
        expect(tester.getCenter(original).dx,
            closeTo(tester.getCenter(reading).dx, 0.01));
        expect(tester.getCenter(reading).dy,
            lessThan(tester.getCenter(original).dy));
      }
    }
    await tester.tap(find.text(units.first.pronunciation).first);
    expect(tapped, '你');
    expect(tester.takeException(), isNull);
  });
}
