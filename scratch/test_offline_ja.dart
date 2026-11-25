import 'package:pilipala/plugin/pl_player/realtime_caption/caption_offline_phonetics.dart';

void main() {
  final t1 = '啊，本当かい，待たせてすまないね。';
  final t2 = '本日休業';
  final t3 = '超電磁砲';
  final t4 = '映画館';

  print('=== t1: $t1 ===');
  print('Kana:   ${CaptionOfflinePhonetics.shared.tryConvert(t1, japaneseMode: "kana", sourceLang: "ja")}');
  print('Romaji: ${CaptionOfflinePhonetics.shared.tryConvert(t1, japaneseMode: "romaji", sourceLang: "ja")}');

  print('=== t2: $t2 ===');
  print('Kana:   ${CaptionOfflinePhonetics.shared.tryConvert(t2, japaneseMode: "kana", sourceLang: "ja")}');
  print('Romaji: ${CaptionOfflinePhonetics.shared.tryConvert(t2, japaneseMode: "romaji", sourceLang: "ja")}');

  print('=== t3: $t3 ===');
  print('Kana:   ${CaptionOfflinePhonetics.shared.tryConvert(t3, japaneseMode: "kana", sourceLang: "ja")}');
  print('Romaji: ${CaptionOfflinePhonetics.shared.tryConvert(t3, japaneseMode: "romaji", sourceLang: "ja")}');

  print('=== t4: $t4 ===');
  print('Kana:   ${CaptionOfflinePhonetics.shared.tryConvert(t4, japaneseMode: "kana", sourceLang: "ja")}');
  print('Romaji: ${CaptionOfflinePhonetics.shared.tryConvert(t4, japaneseMode: "romaji", sourceLang: "ja")}');
}
