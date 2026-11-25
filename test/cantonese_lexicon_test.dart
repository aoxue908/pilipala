import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/cantonese_lexicon.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_offline_phonetics.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_offline_dictionary.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_ruby.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_dictionary_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(CantoneseLexicon.initialize);

  test('bundled data loads once, includes full pinned upstream and aliases',
      () async {
    final loaded = CantoneseLexicon.shared;
    expect(loaded.entries.length, 197601);
    await CantoneseLexicon.initialize();
    expect(identical(CantoneseLexicon.shared, loaded), isTrue);
    final data =
        jsonDecode(File('assets/cantonese/lexicon.json').readAsStringSync());
    expect(data['stats']['skippedRows'], 0);
    expect(data['stats']['characters'], 29640);
  });

  test(
      'all reported colloquial characters and screenshot traditional text have readings',
      () {
    for (final text in [
      '佢嘅咗喺乜嘢嚟嗰咁唔㗎噶咩啲',
      '外一啲專家認為陰陽眼其實係一種眼球疾病',
      '我唔知佢同我破案咩關係但我肯定你識我婆'
    ]) {
      final units = buildCaptionRubyUnits(text, sourceLanguage: 'yue');
      expect(units.map((u) => u.text).join(), text);
      for (final unit in units) {
        expect(unit.pronunciation, isNotEmpty, reason: unit.text);
      }
    }
  });

  test('phrases select context readings, simplified and traditional match', () {
    expect(CaptionOfflinePhonetics.getCantoneseJyutping('銀行'), 'ngan4 hong4');
    expect(CaptionOfflinePhonetics.getCantoneseJyutping('银行'), 'ngan4 hong4');
    expect(CaptionOfflinePhonetics.getCantoneseJyutping('行街'), 'haang4 gaai1');
    expect(CantoneseLexicon.shared.readings('行').length, greaterThan(1));
    for (final entry in {'嚟': 'lei4', '㗎': 'gaa3', '噶': 'gaa1'}.entries) {
      expect(
          CaptionOfflinePhonetics.getCantoneseJyutping(entry.key), entry.value);
      expect(
          CaptionOfflineDictionary.shared
              .lookup(entry.key, isCantonese: true)!
              .phonetic,
          startsWith(entry.value));
    }
  });

  test('supplementary Han uses UTF16 offsets and unknown holes stay aligned',
      () {
    const text = '𠮩\u{3134A}我';
    final readings =
        CaptionOfflinePhonetics.alignedChineseReadings(text, cantonese: true);
    expect(readings[0], isNotNull);
    expect(readings.containsKey(1), isFalse);
    expect(readings.containsKey(2), isFalse);
    expect(readings[4], 'ngo5');
    final units = buildCaptionRubyUnits(text, sourceLanguage: 'yue');
    expect(units.map((u) => u.text).join(), text);
    expect(units.last.startOffset, 4);
    expect(units.last.pronunciation, 'ngo5');
    final tokens = CaptionWordSegmenter.segmentWithDelimiters('㗎，𠮩我');
    expect(tokens.map((t) => t.text).join(), '㗎，𠮩我');
    expect(tokens.first.isWord, isTrue);
    expect(tokens.where((t) => t.isWord).map((t) => t.text), contains('𠮩'));
  });

  test(
      'offline lookup uses the same expanded data, including supplementary Han',
      () {
    for (final text in ['銀行', '银行', '𠮩', '陰陽眼']) {
      final result =
          CaptionOfflineDictionary.shared.lookup(text, isCantonese: true);
      expect(result, isNotNull, reason: text);
      expect(result!.phonetic,
          contains(CaptionOfflinePhonetics.getCantoneseJyutping(text)!));
    }
  });

  test('malformed lexicon is rejected, original phrases precede aliases', () {
    expect(
        () => CantoneseLexicon.parse('{"version":99}'), throwsFormatException);
    expect(CantoneseLexicon.shared.readings('髮'), contains('faat3'));
    expect(CantoneseLexicon.shared.readings('發'), contains('faat3'));
  });
}
