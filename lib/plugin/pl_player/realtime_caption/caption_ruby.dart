import 'package:characters/characters.dart';

import 'caption_offline_phonetics.dart';
import 'japanese_reading.dart';

/// One indivisible text/reading pair. Offsets always refer to the source text,
/// including punctuation and words for which no pronunciation is available.
class CaptionRubyUnit {
  const CaptionRubyUnit(this.text, this.pronunciation, this.startOffset,
      {this.width = 0});
  final String text;
  final String pronunciation;
  final int startOffset;
  final double width;
}

List<CaptionRubyUnit> buildCaptionRubyUnits(
  String text, {
  required String sourceLanguage,
  String chineseMode = 'auto',
  String japaneseMode = 'kana',
  bool isCantonese = false,
  List<JapaneseReadingToken>? japaneseTokens,
}) {
  if (sourceLanguage == 'ja') {
    final tokens = japaneseTokens ?? JapaneseReadingService.shared.cached(text);
    if (tokens == null || tokens.isEmpty) {
      // Keep original text visible until the whole sentence is analyzed.
      var offset = 0;
      return [
        for (final char in text.characters)
          CaptionRubyUnit(char, '', (offset += char.length) - char.length)
      ];
    }
    return [
      for (final token in tokens)
        CaptionRubyUnit(
            token.text,
            japaneseMode == 'romaji'
                ? CaptionOfflinePhonetics.kanaToRomaji(token.reading) ?? ''
                : RegExp(r'\p{Script=Han}', unicode: true).hasMatch(token.text)
                    ? token.reading
                    : '',
            token.start)
    ];
  }
  if ((sourceLanguage == 'auto' ||
          sourceLanguage == 'zh-CN' ||
          sourceLanguage == 'zh') &&
      chineseMode != 'mandarin' &&
      (isCantonese ||
          chineseMode == 'cantonese' ||
          CaptionOfflinePhonetics.hasCantoneseParticles(text))) {
    sourceLanguage = 'yue';
  }
  final chinese = sourceLanguage == 'zh-CN' ||
      sourceLanguage == 'zh' ||
      sourceLanguage == 'yue';
  final readings = chinese
      ? CaptionOfflinePhonetics.alignedChineseReadings(text,
          cantonese: sourceLanguage == 'yue' ||
              isCantonese ||
              chineseMode == 'cantonese')
      : <int, String>{};
  final units = <CaptionRubyUnit>[];
  // Chinese is aligned per character; Japanese kanji groups stay together.
  final tokenPattern = RegExp(
      (sourceLanguage == 'ja' ? r'\p{Script=Han}+' : r'\p{Script=Han}') +
          r"|(?:(?!\p{Script=Han})[\p{L}\p{M}\p{N}])+(?:['’\-](?:(?!\p{Script=Han})[\p{L}\p{M}\p{N}])+)*|[^\p{L}\p{M}\p{N}]+",
      unicode: true);
  for (final match in tokenPattern.allMatches(text)) {
    final token = match.group(0)!;
    final isWord = RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(token);
    var reading = readings[match.start] ?? '';
    if (isWord &&
        reading.isEmpty &&
        !(chinese &&
            RegExp(r'\p{Script=Han}', unicode: true).hasMatch(token))) {
      reading = CaptionOfflinePhonetics.shared.tryConvert(token,
              sourceLang: sourceLanguage,
              chineseMode: chineseMode,
              japaneseMode: japaneseMode,
              isCantoneseContext: isCantonese) ??
          '';
    }
    if (reading == token ||
        RegExp(r'\p{Script=Han}', unicode: true).hasMatch(reading)) {
      reading = '';
    }
    // Preserve grapheme clusters for punctuation/emoji as well.
    if (!isWord) {
      var offset = match.start;
      for (final char in token.characters) {
        units.add(CaptionRubyUnit(char, '', offset));
        offset += char.length;
      }
    } else {
      units.add(CaptionRubyUnit(token, reading, match.start));
    }
  }
  return units;
}
