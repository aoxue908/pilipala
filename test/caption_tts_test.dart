import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_dictionary_sheet.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_preferences.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_pronunciation.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_text_formatter.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_tts_service.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/edge_tts_drm.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _RealHttpOverrides();

  group('EdgeTtsDrm Token Generation', () {
    test('matches test vector 1', () {
      final gec = EdgeTtsDrm.generateSecMsGec(1731744000.0);
      expect(gec, '903A768B1F3DB681-A943FFB1D55C708B441469C442F7DB0DC2C17FE63FF3F7EB2C76947290198E9D');
    });

    test('matches test vector 2', () {
      final gec = EdgeTtsDrm.generateSecMsGec(1731745678.0);
      expect(gec, '333B4FC9E53EB805-2E05422F0A967DE6C1638FAAE8CEFDA49037345025E96FC5BB454D0B68C73BD6');
    });
  });

  group('Cantonese Language and Pronunciation', () {
    test('identifies Cantonese characters and vocabulary', () {
      expect(CaptionPronunciation.isCantoneseText('唔该晒你'), isTrue);
      expect(CaptionPronunciation.isCantoneseText('点解咁搞笑'), isTrue);
      expect(CaptionPronunciation.isCantoneseText('你喺边度呀'), isTrue);
    });

    test('formats Jyutping pronunciation correctly for 知不', () {
      final formatted = CaptionPronunciation.formatJyutping('zi1bat1');
      expect(formatted, 'zi1 bat1');
    });
  });

  group('CaptionTtsService Configuration & Voices', () {
    test('provides Edge-TTS Cantonese voices', () {
      expect(CaptionTtsService.edgeCantoneseVoices.containsKey('zh-HK-HiuMaanNeural'), isTrue);
      expect(CaptionTtsService.edgeCantoneseVoices.containsKey('zh-HK-WanLungNeural'), isTrue);
      expect(CaptionTtsService.edgeCantoneseVoices.containsKey('zh-HK-HiuGaaiNeural'), isTrue);
    });

    test('provides MiMo-V2.5-TTS voices', () {
      expect(CaptionTtsService.mimoVoices.containsKey('default'), isTrue);
      expect(CaptionTtsService.mimoVoices.containsKey('冰糖'), isTrue);
      expect(CaptionTtsService.mimoVoices.containsKey('茉莉'), isTrue);
      expect(CaptionTtsService.mimoVoices.containsKey('苏打'), isTrue);
      expect(CaptionTtsService.mimoVoices.containsKey('白桦'), isTrue);
    });

    test('default configuration loads Edge-TTS and HiuMaan voice', () {
      const config = CaptionTtsConfig(
        engine: CaptionTtsConfig.defaultEngine,
        edgeCantoneseVoice: CaptionTtsConfig.defaultEdgeVoice,
        mimoVoice: CaptionTtsConfig.defaultMiMoVoice,
        mimoApiKey: '',
        mimoBaseUrl: CaptionTtsConfig.defaultMiMoBaseUrl,
      );
      expect(config.engine, 'edge');
      expect(config.edgeCantoneseVoice, 'zh-HK-HiuMaanNeural');
      expect(config.mimoVoice, 'default');
    });
  });

  group('Live Cantonese Speech Synthesis (Network)', () {
    test('synthesizes pure Cantonese audio for "知不"', () async {
      final service = CaptionTtsService.shared;
      final file = await service.synthesize(
        text: '知不',
        lang: 'yue',
      );

      expect(file, isNotNull);
      expect(await file!.exists(), isTrue);
      final length = await file.length();
      expect(length, greaterThan(1000));

      final bytes = await file.readAsBytes();
      // Valid MP3 file usually starts with ID3 header (0x49, 0x44, 0x33) or MPEG frame sync (0xFF, 0xFB/0xF3/0xE0)
      final isId3 = bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33;
      final isMpeg = bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0;
      expect(isId3 || isMpeg, isTrue);
    });
  });

  group('CaptionWordSegmenter', () {
    test('segments Cantonese and Chinese sentence into proper lexical tokens', () {
      final tokens = CaptionWordSegmenter.segment('我嘅当事人已经同原告人达成和解');
      expect(tokens, ['我嘅', '当事人', '已经', '同', '原告人', '达成', '和解']);
    });

    test('segments mixed language sentence properly', () {
      final tokens = CaptionWordSegmenter.segment('这个 iPhone 15 非常犀利');
      expect(tokens, ['这个', 'iPhone', '15', '非常', '犀利']);
    });

    test('segmentWithDelimiters strictly preserves 100% of spaces, punctuation and duplicate words', () {
      const english = "because once you are there";
      final enTokens = CaptionWordSegmenter.segmentWithDelimiters(english);
      expect(enTokens.map((t) => t.text).join(''), english);
      expect(enTokens.where((t) => t.isWhitespace).length, 4);
      expect(enTokens.where((t) => t.isWord).map((t) => t.text).toList(),
          ['because', 'once', 'you', 'are', 'there']);

      const duplicateText = "That that is is.";
      final dupTokens = CaptionWordSegmenter.segmentWithDelimiters(duplicateText);
      expect(dupTokens.map((t) => t.text).join(''), duplicateText);
      expect(dupTokens.where((t) => t.isWord).map((t) => t.text).toList(),
          ['That', 'that', 'is', 'is']);

      const mixedWithPunct = "我嘅当事人，已经同原告人达成和解！";
      final mixedTokens = CaptionWordSegmenter.segmentWithDelimiters(mixedWithPunct);
      expect(mixedTokens.map((t) => t.text).join(''), mixedWithPunct);
      expect(mixedTokens.where((t) => t.isWord).map((t) => t.text).toList(),
          ['我嘅', '当事人', '已经', '同', '原告人', '达成', '和解']);
    });
  });

  group('CaptionTextFormatter English Spacing & Formatting', () {
    test('reconstructs English spaces from tokens with contractions', () {
      final text = CaptionTextFormatter.format(
        tokens: ['because', 'once', 'you', "'re", 'there'],
        rawText: "becauseonceyou'rethere",
      );
      expect(text, "because once you're there");
    });

    test('reconstructs English spaces from full word tokens', () {
      final text = CaptionTextFormatter.format(
        tokens: ['because', 'once', "you're", 'there'],
        rawText: "becauseonceyou'rethere",
      );
      expect(text, "because once you're there");
    });

    test('reconstructs mixed Chinese and English text with proper spacing', () {
      final text = CaptionTextFormatter.format(
        tokens: ['我', '很', '喜欢', 'iPhone', '15', '手机'],
        rawText: '我很喜欢iPhone15手机',
      );
      expect(text, '我很喜欢 iPhone 15 手机');
    });

    test('splits glued compound English text when tokens are concatenated', () {
      final text = CaptionTextFormatter.segmentGluedEnglish("becauseonceyou'rethere");
      expect(text, "because once you're there");
    });

    test('handles SentencePiece space symbols correctly', () {
      final text = CaptionTextFormatter.format(
        tokens: ['\u2581because', '\u2581once', '\u2581you', "'re", '\u2581there'],
        rawText: "becauseonceyou'rethere",
      );
      expect(text, "because once you're there");
    });

    test('converts uppercase English words to lowercase for Zipformer model', () {
      final text = CaptionTextFormatter.format(
        tokens: [' HELLO', ' WORLD'],
        rawText: 'HELLO WORLD',
        lowerCaseEnglish: true,
      );
      expect(text, 'hello world');
    });

    test('reconstructs Zipformer SentencePiece subwords and converts to lowercase with Chinese', () {
      final text = CaptionTextFormatter.format(
        tokens: [' 你', '好', ' M', 'ON', 'D', 'AY', ' TO', 'DAY'],
        rawText: '你好 MONDAY TODAY',
        lowerCaseEnglish: true,
      );
      expect(text, '你好 monday today');
    });

    test('CaptionTextFormatter.lowerCaseEnglish converts uppercase and preserves non-English', () {
      expect(
        CaptionTextFormatter.lowerCaseEnglish("HELLO! IT'S 100% OKAY, ISN'T IT?"),
        "hello! it's 100% okay, isn't it?",
      );
      expect(
        CaptionTextFormatter.lowerCaseEnglish("深度学习 TRANSFORMER 模型"),
        "深度学习 transformer 模型",
      );
    });
  });

  group('CaptionPreferences Crash Resilience', () {
    test('safely loads corrupted, unexpected types, and double values without throwing', () {
      final mockData = <String, dynamic>{
        'captionAppearance': {
          'fontSize': 'not_a_number',
          'backgroundOpacity': 999.0,
          'bottom': -50.0,
          'captionColor': 4294967295.0, // double representation of 0xffffffff
          'pronunciationColor': '4286635754', // string representation of 0xff80deea
        },
        'captionShowOriginal': 1, // integer instead of bool
        'captionShowTranslation': 'true', // string instead of bool
        'captionShowPronunciation': 0, // integer instead of bool
        'captionChinesePhonetic': 12345, // integer instead of string
        'captionJapanesePhonetic': null,
        'captionTargetLanguage': 'en-US',
        'captionUseLocalAsr': 'false',
        'captionLocalAsrModel': null,
        'captionEnableWordLookup': 1,
      };

      final mockBox = _MockStorageBox(mockData);
      final prefs = CaptionPreferences(mockBox);

      expect(prefs.appearance.value.fontSize, 16.0); // clamped/fallback
      expect(prefs.appearance.value.backgroundOpacity, 1.0); // clamped to 1.0
      expect(prefs.appearance.value.bottom, 0.0); // clamped to 0.0
      expect(prefs.appearance.value.captionColor, 0xffffffff); // correctly parsed from double
      expect(prefs.appearance.value.pronunciationColor, 0xff80deea); // correctly parsed from string
      expect(prefs.showOriginal.value, isTrue); // 1 -> true
      expect(prefs.showTranslation.value, isTrue); // 'true' -> true
      expect(prefs.showPronunciation.value, isFalse); // 0 -> false
      expect(prefs.chinesePhonetic.value, 'auto'); // fallback
      expect(prefs.japanesePhonetic.value, 'kana'); // fallback
      expect(prefs.targetLanguage.value, 'en-US');
      expect(prefs.useLocalAsr.value, isFalse); // 'false' -> false
      expect(prefs.localAsrModel.value, 'sense_voice'); // fallback
      expect(prefs.enableWordLookup.value, isTrue); // 1 -> true
    });

    test('safely handles closed box or throwing storage', () {
      final closedBox = _MockStorageBox({}, isOpen: false);
      final prefs = CaptionPreferences(closedBox);
      expect(prefs.appearance.value.fontSize, 16.0);
      expect(prefs.enableWordLookup.value, isTrue);
    });
  });
}

class _MockStorageBox implements Box<dynamic> {
  final Map<String, dynamic> _data;
  final bool _open;

  _MockStorageBox(this._data, {bool isOpen = true}) : _open = isOpen;

  @override
  bool get isOpen => _open;

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) {
    if (!_open) throw StateError('Box closed');
    return _data.containsKey(key) ? _data[key] : defaultValue;
  }

  @override
  Future<void> put(dynamic key, dynamic value) async {
    if (!_open) throw StateError('Box closed');
    _data[key.toString()] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
