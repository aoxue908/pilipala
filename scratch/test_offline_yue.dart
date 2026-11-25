import 'package:pilipala/plugin/pl_player/realtime_caption/caption_offline_phonetics.dart';

void main() {
  final s1 = '今日天氣好好，我哋一齊去飲茶啦。';
  final s2 = '今天天气真好，我们一起去喝茶吧。';
  print('s1 (yue context): ${CaptionOfflinePhonetics.shared.tryConvert(s1, sourceLang: "yue")}');
  print('s1 (auto): ${CaptionOfflinePhonetics.shared.tryConvert(s1)}');
  print('s2 (yue context): ${CaptionOfflinePhonetics.shared.tryConvert(s2, sourceLang: "yue")}');
  print('s2 (auto): ${CaptionOfflinePhonetics.shared.tryConvert(s2)}');
}
