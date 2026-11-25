import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:pilipala/utils/storage.dart';

typedef CaptionAppearance = ({
  double fontSize,
  double pronunciationFontSize,
  double backgroundOpacity,
  int backgroundColor,
  double bottom,
  int captionColor,
  int pronunciationColor,
  double? alignX,
  double? alignY,
});

class CaptionPreferences {
  CaptionPreferences([this._storage]) {
    _init();
  }

  void _init() {
    double fontSize = 16.0;
    double pronunciationFontSize = 8.0;
    double backgroundOpacity = 0.7;
    int backgroundColor = backgroundColors.keys.first;
    double bottom = 30.0;
    int captionColor = captionColors.keys.first;
    int pronColor = pronunciationColors.keys.first;
    double? alignX;
    double? alignY;

    bool orig = false;
    bool trans = false;
    bool pron = false;
    bool sheetPron = true;
    String zhPhonetic = 'auto';
    String jaPhonetic = 'kana';
    String targetLang = 'zh-CN';
    bool localAsr = false;
    String asrModel = 'sense_voice';
    String prefSource = 'official';
    bool wordLookup = true;
    int delayMs = 0;
    String transEngine = 'microsoft';
    int viewModeVal = 1;
    int sentenceMaxLinesVal = 2;
    String landscapeLayoutVal = 'center';
    String onlineEngine = 'azure';
    String onlineLang = 'auto';
    String doubaoAuth = 'api_key';
    String doubaoKey = '';
    String doubaoApp = '';
    String doubaoToken = '';
    String deepgramKey = '';
    double? initCustomWidth;
    double? initCustomHeight;

    try {
      final storage = _storage;
      if (storage != null && storage.isOpen) {
        final saved = storage.get(VideoBoxKey.captionAppearance);
        if (saved is Map) {
          // 必须与设置面板滑块范围(8~24)一致，否则调到 12 以下会被夹回 12，表现为“没保存”
          fontSize = _number(saved['fontSize'], 16, 8, 24);
          pronunciationFontSize = _number(saved['pronunciationFontSize'], 8, 6, 16);
          backgroundOpacity = _number(saved['backgroundOpacity'], 0.7, 0, 1);
          backgroundColor = _parseColor(
              saved['backgroundColor'], backgroundColors, backgroundColors.keys.first);
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

        orig = _parseBool(storage.get('captionShowOriginal'), false);
        trans = _parseBool(storage.get('captionShowTranslation'), false);
        pron = _parseBool(storage.get('captionShowPronunciation'), false);
        sheetPron = _parseBool(storage.get('captionSheetShowPronunciation'), true);
        zhPhonetic = _parseString(storage.get('captionChinesePhonetic'), 'auto');
        jaPhonetic = _parseString(storage.get('captionJapanesePhonetic'), 'kana');
        targetLang = _parseString(storage.get('captionTargetLanguage'), 'zh-CN');
        localAsr = _parseBool(storage.get('captionUseLocalAsr'), false);
        asrModel = _parseString(storage.get('captionLocalAsrModel'), 'sense_voice');
        prefSource = _parseString(storage.get('captionPreferredSubtitleSource'), 'official');
        wordLookup = _parseBool(storage.get('captionEnableWordLookup'), true);
        delayMs = _parseInt(storage.get('captionDelayMs'), 0).clamp(-5000, 5000);
        transEngine = _parseString(storage.get('captionTranslationEngine'), 'microsoft');
        // 首次采用两行滚动样式时迁移旧的 3/4/6 行设置；之后尊重手动选择。
        if (storage.get('captionRollupStyleVersion') == 1) {
          sentenceMaxLinesVal = _parseInt(storage.get('captionSentenceMaxLines'), 2).clamp(2, 6);
          viewModeVal = sentenceMaxLinesVal <= 2 ? 1 : (sentenceMaxLinesVal <= 4 ? 2 : 3);
        }
        landscapeLayoutVal = _parseString(storage.get('captionLandscapeLayout'), 'center');
        onlineEngine = _parseString(storage.get('captionOnlineAsrEngine'), 'azure');
        onlineLang = _parseString(storage.get('captionOnlineAsrLanguage'), 'auto');
        doubaoAuth = _parseString(storage.get('captionDoubaoAuthMode'), 'api_key');
        doubaoKey = _parseString(storage.get('captionDoubaoApiKey'), '');
        doubaoApp = _parseString(storage.get('captionDoubaoAppId'), '');
        doubaoToken = _parseString(storage.get('captionDoubaoAccessToken'), '');
        deepgramKey = _parseString(storage.get('captionDeepgramApiKey'), '');
        final savedW = storage.get('captionCustomWidth');
        if (savedW is num && savedW > 50) initCustomWidth = savedW.toDouble();
        final savedH = storage.get('captionCustomHeight');
        if (savedH is num && savedH > 30) initCustomHeight = savedH.toDouble();
      }
    } catch (e) {
      // 容错兜底：即使磁盘数据损坏，使用安全默认值，绝不导致 App 启动崩溃
    }

    appearance = Rx<CaptionAppearance>((
      fontSize: fontSize,
      pronunciationFontSize: pronunciationFontSize,
      backgroundOpacity: backgroundOpacity,
      backgroundColor: backgroundColor,
      bottom: bottom,
      captionColor: captionColor,
      pronunciationColor: pronColor,
      alignX: alignX,
      alignY: alignY,
    ));

    showOriginal = orig.obs;
    showTranslation = trans.obs;
    showPronunciation = pron.obs;
    sheetShowPronunciation = sheetPron.obs;
    chinesePhonetic = zhPhonetic.obs;
    japanesePhonetic = jaPhonetic.obs;
    targetLanguage = targetLang.obs;
    translationEngine = transEngine.obs;
    useLocalAsr = localAsr.obs;
    localAsrModel = asrModel.obs;
    preferredSubtitleSource = prefSource.obs;
    enableWordLookup = wordLookup.obs;
    captionDelayMs = delayMs.obs;
    viewMode = viewModeVal.obs;
    sentenceMaxLines = sentenceMaxLinesVal.obs;
    landscapeLayout = landscapeLayoutVal.obs;
    onlineAsrEngine = onlineEngine.obs;
    onlineAsrLanguage = onlineLang.obs;
    doubaoAuthMode = doubaoAuth.obs;
    doubaoApiKey = doubaoKey.obs;
    doubaoAppId = doubaoApp.obs;
    doubaoAccessToken = doubaoToken.obs;
    deepgramApiKey = deepgramKey.obs;
    customWidth = Rxn<double>(initCustomWidth);
    customHeight = Rxn<double>(initCustomHeight);
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

  /// 字幕背景色板（暗色为主，保证白字可读）。第一项为默认。
  static const backgroundColors = {
    0xff212121: '深灰',
    0xff000000: '纯黑',
    0xff263238: '蓝灰',
    0xff3e2723: '深棕',
    0xff311b1b: '酒红',
    0xff1b3a2f: '墨绿',
    0xff1a237e: '藏蓝',
    0xff4a148c: '深紫',
    0xffffffff: '纯白',
  };

  static const captionColors = {
    0xffffffff: '纯白',
    0xffffd54f: '金黄',
    0xff80deea: '青蓝',
    0xffa5d6a7: '浅绿',
    0xfff48fb1: '粉红',
    0xffffb74d: '亮橙',
    0xff212121: '深灰',
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

  final Box<dynamic>? _storage;
  late final Rx<CaptionAppearance> appearance;
  late final RxBool showOriginal;
  late final RxBool showTranslation;
  late final RxBool showPronunciation;
  late final RxString chinesePhonetic;
  late final RxString japanesePhonetic;
  late final RxString targetLanguage;
  late final RxString translationEngine;
  late final RxBool useLocalAsr;
  late final RxString localAsrModel;
  late final RxString preferredSubtitleSource;
  late final RxBool enableWordLookup;
  late final RxInt captionDelayMs;
  /// 字幕框显示模式：1=紧凑 2=标准 3=全景（与缓存句子数量无关）
  late final RxInt viewMode;
  /// 单个字幕框内最多显示的行数（2-6），超出时在该框内滚动，实现框内滚动效果
  late final RxInt sentenceMaxLines;
  late final RxString landscapeLayout;
  late final RxString onlineAsrEngine;
  late final RxString onlineAsrLanguage;
  late final RxBool sheetShowPronunciation;
  late final RxString doubaoAuthMode;
  late final RxString doubaoApiKey;
  late final RxString doubaoAppId;
  late final RxString doubaoAccessToken;
  late final RxString deepgramApiKey;
  late final Rxn<double> customWidth;
  late final Rxn<double> customHeight;

  static double _number(
      Object? value, double fallback, double min, double max) {
    if (value is! num || !value.isFinite) return fallback;
    return value.clamp(min, max).toDouble();
  }

  void update({
    double? fontSize,
    double? pronunciationFontSize,
    double? backgroundOpacity,
    int? backgroundColor,
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
      pronunciationFontSize: pronunciationFontSize == null
          ? previous.pronunciationFontSize : _number(pronunciationFontSize, 8, 6, 16),
      backgroundOpacity: backgroundOpacity ?? previous.backgroundOpacity,
      backgroundColor: backgroundColor ?? previous.backgroundColor,
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

  /// 设置字幕滚动窗口显示的行数（2-6），并同步三态按钮高亮档位，保持两个入口一致。
  void setSentenceMaxLines(int lines) {
    sentenceMaxLines.value = lines.clamp(2, 6);
    viewMode.value = sentenceMaxLines.value <= 2
        ? 1
        : (sentenceMaxLines.value <= 4 ? 2 : 3);
    save();
  }

  /// 切换字幕框显示模式（紧凑 / 标准 / 全景），1-3 循环。
  /// 与「字幕框显示行数」统一到同一变量：紧凑=2行，标准=4行，全景=6行。
  void cycleViewMode() {
    viewMode.value = viewMode.value % 3 + 1;
    sentenceMaxLines.value = viewMode.value == 1
        ? 2
        : (viewMode.value == 2 ? 4 : 6);
    save();
  }

  void setLandscapeLayout(String layout) {
    if (layout == 'center' || layout == 'left') {
      landscapeLayout.value = layout;
      save();
    }
  }

  void setCustomSize(double? width, double? height) {
    customWidth.value = width;
    customHeight.value = height;
    save();
  }

  void toggleTranslation() {
    showTranslation.value = !showTranslation.value;
    save();
  }

  void togglePronunciation() {
    showPronunciation.value = !showPronunciation.value;
    save();
  }

  void setSheetPronunciation(bool value) {
    sheetShowPronunciation.value = value;
    save();
  }

  void setOnlineAsrEngine(String engine) {
    onlineAsrEngine.value = engine;
    save();
  }

  void setOnlineAsrLanguage(String lang) {
    onlineAsrLanguage.value = lang;
    save();
  }

  void setDoubaoAuthMode(String mode) {
    doubaoAuthMode.value = mode;
    save();
  }

  void setDoubaoApiKey(String key) {
    doubaoApiKey.value = key;
    save();
  }

  void setDoubaoAppId(String id) {
    doubaoAppId.value = id;
    save();
  }

  void setDoubaoAccessToken(String token) {
    doubaoAccessToken.value = token;
    save();
  }

  void setDeepgramApiKey(String key) {
    deepgramApiKey.value = key;
    save();
  }

  Future<void> save() async {
    try {
      final storage = _storage;
      if (storage == null || !storage.isOpen) return;
      final value = appearance.value;
      await storage.put(VideoBoxKey.captionAppearance, {
        'fontSize': value.fontSize,
        'pronunciationFontSize': value.pronunciationFontSize,
        'backgroundOpacity': value.backgroundOpacity,
        'backgroundColor': value.backgroundColor,
        'bottom': value.bottom,
        'captionColor': value.captionColor,
        'pronunciationColor': value.pronunciationColor,
        'alignX': value.alignX,
        'alignY': value.alignY,
      });
      await storage.put('captionShowOriginal', showOriginal.value);
      await storage.put('captionShowTranslation', showTranslation.value);
      await storage.put('captionShowPronunciation', showPronunciation.value);
      await storage.put('captionSheetShowPronunciation', sheetShowPronunciation.value);
      await storage.put('captionChinesePhonetic', chinesePhonetic.value);
      await storage.put('captionJapanesePhonetic', japanesePhonetic.value);
      await storage.put('captionTargetLanguage', targetLanguage.value);
      await storage.put('captionTranslationEngine', translationEngine.value);
      await storage.put('captionUseLocalAsr', useLocalAsr.value);
      await storage.put('captionLocalAsrModel', localAsrModel.value);
      await storage.put('captionPreferredSubtitleSource', preferredSubtitleSource.value);
      await storage.put('captionEnableWordLookup', enableWordLookup.value);
      await storage.put('captionDelayMs', captionDelayMs.value);
      await storage.put('captionViewMode', viewMode.value);
      await storage.put('captionSentenceMaxLines', sentenceMaxLines.value);
      await storage.put('captionRollupStyleVersion', 1);
      await storage.put('captionLandscapeLayout', landscapeLayout.value);
      await storage.put('captionOnlineAsrEngine', onlineAsrEngine.value);
      await storage.put('captionOnlineAsrLanguage', onlineAsrLanguage.value);
      await storage.put('captionDoubaoAuthMode', doubaoAuthMode.value);
      await storage.put('captionDoubaoApiKey', doubaoApiKey.value);
      await storage.put('captionDoubaoAppId', doubaoAppId.value);
      await storage.put('captionDoubaoAccessToken', doubaoAccessToken.value);
      await storage.put('captionDeepgramApiKey', deepgramApiKey.value);
      await storage.put('captionCustomWidth', customWidth.value);
      await storage.put('captionCustomHeight', customHeight.value);
    } catch (_) {
      // 容错处理：避免磁盘写入异常造成上层抛错
    }
  }
}
