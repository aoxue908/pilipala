import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:pilipala/utils/storage.dart';

typedef CaptionAppearance = ({
  double fontSize,
  double backgroundOpacity,
  double bottom,
  int captionColor,
  int pronunciationColor,
  double? alignX,
  double? alignY,
});

class CaptionPreferences {
  CaptionPreferences(this._storage) {
    _init();
  }

  void _init() {
    double fontSize = 16.0;
    double backgroundOpacity = 0.7;
    double bottom = 30.0;
    int captionColor = captionColors.keys.first;
    int pronColor = pronunciationColors.keys.first;
    double? alignX;
    double? alignY;

    bool orig = false;
    bool trans = false;
    bool pron = false;
    String zhPhonetic = 'auto';
    String jaPhonetic = 'kana';
    String targetLang = 'zh-CN';
    bool localAsr = false;
    String asrModel = 'sense_voice';
    bool wordLookup = true;
    int delayMs = 0;

    try {
      if (_storage.isOpen) {
        final saved = _storage.get(VideoBoxKey.captionAppearance);
        if (saved is Map) {
          fontSize = _number(saved['fontSize'], 16, 12, 32);
          backgroundOpacity = _number(saved['backgroundOpacity'], 0.7, 0, 1);
          bottom = _number(saved['bottom'], 30, 0, 96);
          final rawColor = saved['captionColor'] ?? saved['highlightColor'];
          captionColor = _parseColor(rawColor, captionColors, captionColors.keys.first);
          final rawPronColor = saved['pronunciationColor'];
          pronColor = _parseColor(rawPronColor, pronunciationColors, pronunciationColors.keys.first);
          if (saved['alignX'] != null && saved['alignX'] is num) {
            alignX = (saved['alignX'] as num).toDouble().clamp(-1.0, 1.0);
          }
          if (saved['alignY'] != null && saved['alignY'] is num) {
            alignY = (saved['alignY'] as num).toDouble().clamp(-1.0, 1.0);
          }
        }

        orig = _parseBool(_storage.get('captionShowOriginal'), false);
        trans = _parseBool(_storage.get('captionShowTranslation'), false);
        pron = _parseBool(_storage.get('captionShowPronunciation'), false);
        zhPhonetic = _parseString(_storage.get('captionChinesePhonetic'), 'auto');
        jaPhonetic = _parseString(_storage.get('captionJapanesePhonetic'), 'kana');
        targetLang = _parseString(_storage.get('captionTargetLanguage'), 'zh-CN');
        localAsr = _parseBool(_storage.get('captionUseLocalAsr'), false);
        asrModel = _parseString(_storage.get('captionLocalAsrModel'), 'sense_voice');
        wordLookup = _parseBool(_storage.get('captionEnableWordLookup'), true);
        delayMs = _parseInt(_storage.get('captionDelayMs'), 0);
      }
    } catch (e) {
      // 容错兜底：即使磁盘数据损坏，使用安全默认值，绝不导致 App 启动崩溃
    }

    appearance = Rx<CaptionAppearance>((
      fontSize: fontSize,
      backgroundOpacity: backgroundOpacity,
      bottom: bottom,
      captionColor: captionColor,
      pronunciationColor: pronColor,
      alignX: alignX,
      alignY: alignY,
    ));

    showOriginal = orig.obs;
    showTranslation = trans.obs;
    showPronunciation = pron.obs;
    chinesePhonetic = zhPhonetic.obs;
    japanesePhonetic = jaPhonetic.obs;
    targetLanguage = targetLang.obs;
    useLocalAsr = localAsr.obs;
    localAsrModel = asrModel.obs;
    enableWordLookup = wordLookup.obs;
    captionDelayMs = delayMs.obs;
  }

  static int _parseInt(Object? val, int fallback) {
    if (val is int) return val;
    if (val is num) return val.toInt();
    if (val is String) {
      final parsed = int.tryParse(val);
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  static bool _parseBool(Object? val, bool fallback) {
    if (val is bool) return val;
    if (val is num) return val != 0;
    if (val is String) {
      final s = val.trim().toLowerCase();
      if (s == 'true' || s == '1') return true;
      if (s == 'false' || s == '0') return false;
    }
    return fallback;
  }

  static String _parseString(Object? val, String fallback) {
    if (val is String && val.trim().isNotEmpty) return val.trim();
    return fallback;
  }

  static int _parseColor(Object? val, Map<int, String> allowed, int fallback) {
    if (val == null) return fallback;
    if (val is int) {
      if (allowed.containsKey(val)) return val;
      if (val != 0) return val;
    }
    if (val is num) {
      final intVal = val.toInt();
      if (allowed.containsKey(intVal)) return intVal;
      if (intVal != 0) return intVal;
    }
    if (val is String) {
      final intVal = int.tryParse(val);
      if (intVal != null) {
        if (allowed.containsKey(intVal)) return intVal;
        if (intVal != 0) return intVal;
      }
    }
    return fallback;
  }

  static const captionColors = {
    0xffffffff: '纯白',
    0xffffd54f: '金黄',
    0xff80deea: '青蓝',
    0xffa5d6a7: '浅绿',
    0xfff48fb1: '粉红',
    0xffffb74d: '亮橙',
  };

  static const pronunciationColors = {
    0xff80deea: '青蓝 (推荐)',
    0xffffd54f: '金黄',
    0xffffb74d: '亮橙',
    0xffa5d6a7: '浅绿',
    0xfff48fb1: '粉红',
    0xffffffff: '纯白',
    0xffb0bec5: '蓝灰',
  };

  final Box<dynamic> _storage;
  late final Rx<CaptionAppearance> appearance;
  late final RxBool showOriginal;
  late final RxBool showTranslation;
  late final RxBool showPronunciation;
  late final RxString chinesePhonetic;
  late final RxString japanesePhonetic;
  late final RxString targetLanguage;
  late final RxBool useLocalAsr;
  late final RxString localAsrModel;
  late final RxBool enableWordLookup;
  late final RxInt captionDelayMs;

  static double _number(
      Object? value, double fallback, double min, double max) {
    if (value is! num || !value.isFinite) return fallback;
    return value.clamp(min, max).toDouble();
  }

  void update({
    double? fontSize,
    double? backgroundOpacity,
    double? bottom,
    int? captionColor,
    int? pronunciationColor,
    double? alignX,
    double? alignY,
    bool clearCustomPosition = false,
  }) {
    final previous = appearance.value;
    appearance.value = (
      fontSize: fontSize ?? previous.fontSize,
      backgroundOpacity: backgroundOpacity ?? previous.backgroundOpacity,
      bottom: bottom ?? previous.bottom,
      captionColor: captionColor ?? previous.captionColor,
      pronunciationColor: pronunciationColor ?? previous.pronunciationColor,
      alignX: clearCustomPosition ? null : (alignX ?? previous.alignX),
      alignY: clearCustomPosition ? null : (alignY ?? previous.alignY),
    );
  }

  void setPosition(double alignX, double alignY) {
    update(
      alignX: alignX.clamp(-1.0, 1.0),
      alignY: alignY.clamp(-1.0, 1.0),
    );
    save();
  }

  void resetPosition() {
    update(clearCustomPosition: true);
    save();
  }

  void setCaptionDelay(int delayMs) {
    captionDelayMs.value = delayMs.clamp(-5000, 5000);
    save();
  }

  Future<void> save() async {
    try {
      if (!_storage.isOpen) return;
      final value = appearance.value;
      await _storage.put(VideoBoxKey.captionAppearance, {
        'fontSize': value.fontSize,
        'backgroundOpacity': value.backgroundOpacity,
        'bottom': value.bottom,
        'captionColor': value.captionColor,
        'pronunciationColor': value.pronunciationColor,
        'alignX': value.alignX,
        'alignY': value.alignY,
      });
      await _storage.put('captionShowOriginal', showOriginal.value);
      await _storage.put('captionShowTranslation', showTranslation.value);
      await _storage.put('captionShowPronunciation', showPronunciation.value);
      await _storage.put('captionChinesePhonetic', chinesePhonetic.value);
      await _storage.put('captionJapanesePhonetic', japanesePhonetic.value);
      await _storage.put('captionTargetLanguage', targetLanguage.value);
      await _storage.put('captionUseLocalAsr', useLocalAsr.value);
      await _storage.put('captionLocalAsrModel', localAsrModel.value);
      await _storage.put('captionEnableWordLookup', enableWordLookup.value);
      await _storage.put('captionDelayMs', captionDelayMs.value);
    } catch (_) {
      // 容错处理：避免磁盘写入异常造成上层抛错
    }
  }
}
