import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/japanese_reading.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/japanese_calendar_readings.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_offline_phonetics.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_pronunciation.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_ruby.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_rollup.dart';

Map<String, dynamic> token(String text, String reading, int offset,
        {bool known = true}) =>
    {'surface': text, 'reading': reading, 'start': offset, 'known': known};
final nationalSecurity = [
  token('国家', 'コッカ', 0),
  token('安全', 'アンゼン', 2),
  token('保障', 'ホショウ', 4)
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('未取得整句分析时不使用单字训读猜测，也不删除原文', () {
    const text = '国家安全保障𠮷';
    expect(CaptionOfflinePhonetics.getJapanesePhonetic(text), isNull);
    final units = buildCaptionRubyUnits(text, sourceLanguage: 'ja');
    expect(units.map((u) => u.text).join(), text);
    expect(units.every((u) => u.pronunciation.isEmpty), isTrue);
  });

  test('原生词语读音转换成配对单元，保留未知词和UTF16偏移', () {
    final tokens = JapaneseReadingService.parse('😀 国家安全保障 𠮷', [
      token('国家', 'コッカ', 3),
      token('安全', 'アンゼン', 5),
      token('保障', 'ホショウ', 7),
      token('𠮷', 'ヨシ', 10, known: false),
    ]);
    final units = buildCaptionRubyUnits('😀 国家安全保障 𠮷',
        sourceLanguage: 'ja', japaneseTokens: tokens);
    expect(units.map((u) => u.text).join(), '😀 国家安全保障 𠮷');
    expect(
        units
            .where((u) => u.pronunciation.isNotEmpty)
            .map((u) => u.pronunciation),
        ['こっか', 'あんぜん', 'ほしょう']);
    expect(units.last.startOffset, 10);
    expect(units.last.pronunciation, isEmpty);
    expect(() => JapaneseReadingService.parse('国家', [token('国', 'コク', 1)]),
        throwsFormatException);
  });

  test('缓存以整句为键，合并并发请求，不会将同一个字的读音复用到别的词', () async {
    var calls = 0;
    final pending = Completer<List<dynamic>>();
    final service = JapaneseReadingService(analyze: (text) {
      calls++;
      return pending.future;
    });
    final first = service.analyze('国家安全保障');
    final second = service.analyze('国家安全保障');
    expect(calls, 1);
    pending.complete(nationalSecurity);
    expect(identical(await first, await second), isTrue);
    await service.analyze('国家安全保障');
    expect(calls, 1);
    expect(service.cached('国'), isNull);
    service.dispose();
  });

  test('月份、日期、经过天数和时间数量分开选读音', () {
    const examples = {
      '1月': 'いちがつ',
      '2月': 'にがつ',
      '3月': 'さんがつ',
      '4月': 'しがつ',
      '5月': 'ごがつ',
      '6月': 'ろくがつ',
      '7月': 'しちがつ',
      '8月': 'はちがつ',
      '9月': 'くがつ',
      '10月': 'じゅうがつ',
      '11月': 'じゅういちがつ',
      '12月': 'じゅうにがつ',
      '四か月': 'よんかげつ',
      '八カ月': 'はっかげつ',
      '六ヶ月': 'ろっかげつ',
      '一週間': 'いっしゅうかん',
      '8週間': 'はっしゅうかん',
      '20週間': 'にじゅっしゅうかん',
      '4日': 'よっか',
      '7日': 'なのか',
      '9日': 'ここのか',
      '14日': 'じゅうよっか',
      '20日': 'はつか',
      '24日': 'にじゅうよっか',
      '4時': 'よじ',
      '7時': 'しちじ',
      '9時': 'くじ',
    };
    for (final example in examples.entries) {
      expect(
          japaneseCalendarReadings(example.key).single.reading, example.value,
          reason: example.key);
    }
    expect(japaneseCalendarReadings('４月１日').map((r) => r.reading),
        ['しがつ', 'ついたち']);
    expect(japaneseCalendarReadings('1日休む').single.reading, 'いちにち');
    expect(japaneseCalendarReadings('1日').single.reading, isEmpty);
    expect(japaneseCalendarReadings('2024月'), isEmpty);
    expect(japaneseCalendarReadings('13月'), isEmpty);
  });

  test('旧的整句注音入口也必须等待词法分析，不再走逐字替换', () async {
    const channel = MethodChannel('pilipala/japanese_reading');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.arguments['text'], '国家安全保障');
      return nationalSecurity;
    });
    final reading = await CaptionPronunciation.shared
        .getPronunciation('国家安全保障', sourceLang: 'ja');
    expect(reading, 'こっかあんぜんほしょう');
    expect(
        buildCaptionRubyUnits('国家安全保障', sourceLanguage: 'ja')
            .map((u) => u.text),
        ['国家', '安全', '保障']);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('先按整句分词再换行，窄字幕不会拆开国家或错配假名，点击按词查', (tester) async {
    final tokens = JapaneseReadingService.parse('国家安全保障', nationalSecurity);
    String? clicked;
    const entry = CaptionRollupEntry(
        text: '国家安全保障', contextSentence: '国家安全保障', identity: 'news');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child: SizedBox(
      width: 100,
      child: CaptionRollup(
        entries: const [entry],
        width: 100,
        maxLines: 4,
        style: const TextStyle(fontSize: 20),
        backgroundColor: Colors.black,
        showPronunciation: true,
        pronunciationFontSize: 8,
        rubyForEntry: (e) => buildCaptionRubyUnits(e.text,
            sourceLanguage: 'ja', japaneseTokens: tokens),
        onWordTap: (word, context) {
          clicked = word;
          expect(context.contextSentence, entry.text);
        },
      ),
    )))));
    await tester.pumpAndSettle();
    expect(find.text('国家'), findsOneWidget);
    expect(find.text('こっか'), findsOneWidget);
    expect(find.text('国'), findsNothing);
    await tester.tap(find.text('こっか'));
    expect(clicked, '国家');
    expect(tester.takeException(), isNull);
  });

  testWidgets('开启日语注音不改已显示的行，新句采用整词注音', (tester) async {
    const old = CaptionRollupEntry(text: '国家', contextSentence: '国家', identity: 'old');
    const next = CaptionRollupEntry(text: '生物', contextSentence: '生物', identity: 'new');
    Widget scene(bool show, List<CaptionRollupEntry> entries) => MaterialApp(
      home: Scaffold(body: CaptionRollup(entries: entries, width: 300,
        style: const TextStyle(fontSize: 20), backgroundColor: Colors.black,
        showPronunciation: show, onWordTap: (_, __) {},
        rubyForEntry: (entry) => [CaptionRubyUnit(entry.text, entry.identity == 'old' ? 'こっか' : 'せいぶつ', 0)],
      )));
    await tester.pumpWidget(scene(false, [old]));
    await tester.pumpWidget(scene(true, [old]));
    await tester.pumpAndSettle();
    expect(find.text('こっか'), findsNothing);
    await tester.pumpWidget(scene(true, [old, next]));
    await tester.pumpAndSettle();
    expect(find.text('こっか'), findsNothing);
    expect(find.text('せいぶつ'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  if (const bool.fromEnvironment('JAPANESE_NATIVE_FIXTURE')) {
    test('真实JVM词法分析输出经Dart处理后仍正确：包括日历、星期和音训变化', () {
      final fixtures = jsonDecode(
          File('scratch/offline_check/japanese_native_tokens.json')
              .readAsStringSync()) as List;
      const expected = {
        '国家安全保障': 'こっかあんぜんほしょう',
        '生物と生き物': 'せいぶつといきもの',
        '四月と四か月': 'しがつとよんかげつ',
        '7月と9月': 'しちがつとくがつ',
        '４月１日': 'しがつついたち',
        '1日休む': 'いちにちやすむ',
        '1日': '',
        '4日と14日と20日と24日': 'よっかとじゅうよっかとはつかとにじゅうよっか',
        '1週間と8週間': 'いっしゅうかんとはっしゅうかん',
        '4時と7時と9時': 'よじとしちじとくじ',
        '月曜日火曜日水曜日木曜日金曜日土曜日日曜日': 'げつようびかようびすいようびもくようびきんようびどようびにちようび',
      };
      for (final fixture in fixtures) {
        final text = fixture['text'] as String;
        final tokens =
            JapaneseReadingService.parse(text, fixture['tokens'] as List);
        expect(tokens.map((t) => t.text).join(), text);
        expect(tokens.map((t) => t.reading).join(), expected[text],
            reason: text);
      }
    });
  }
}
