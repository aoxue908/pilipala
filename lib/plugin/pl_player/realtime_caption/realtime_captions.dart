import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:get/get.dart' hide Response;
import 'package:media_kit/media_kit.dart';
import 'package:pilipala/http/video.dart';
import 'package:pilipala/models/video/subTitile/result.dart';

import '../models/data_source.dart';
import 'asr_stream.dart';
import 'asr_repetition.dart';
import 'caption_preferences.dart';
import 'caption_context.dart';
import 'caption_pronunciation.dart';
import 'caption_timeline.dart';
import 'caption_translator.dart';
import 'cloud_asr_flow.dart';
import 'ieeio_login.dart';
import 'local_asr_model.dart';
import 'local_asr_stream.dart';
import 'pcm_leveler.dart';
import 'player_pcm.dart';
import 'public_cloud_asr_stream.dart';

typedef CaptionFrame = ({
  CaptionCue cue,
  String translation,
  String pronunciation,
});

class CaptionSentenceItem {
  final String id;
  final String original;
  final String translation;
  final String pronunciation;
  final bool isLatest;
  final bool isFinal;
  final DateTime createdAt;
  final List<CaptionContextRange> contextRanges;

  CaptionSentenceItem({
    required this.id,
    required this.original,
    this.translation = '',
    this.pronunciation = '',
    this.isLatest = true,
    this.isFinal = false,
    DateTime? createdAt,
    List<CaptionContextRange>? contextRanges,
  }) : createdAt = createdAt ?? DateTime.now(),
       contextRanges = contextRanges ?? [(start: 0, end: original.length)];

  CaptionSentenceItem copyWith({
    String? id,
    String? original,
    String? translation,
    String? pronunciation,
    bool? isLatest,
    bool? isFinal,
    List<CaptionContextRange>? contextRanges,
  }) {
    return CaptionSentenceItem(
      id: id ?? this.id,
      original: original ?? this.original,
      translation: translation ?? this.translation,
      pronunciation: pronunciation ?? this.pronunciation,
      isLatest: isLatest ?? this.isLatest,
      isFinal: isFinal ?? this.isFinal,
      createdAt: createdAt,
      contextRanges: contextRanges ??
          (original == null || original == this.original ? this.contextRanges : null),
    );
  }

  /// 内容是否一致（忽略 createdAt）。用于 RxList 替换前去重，
  /// 避免每 33ms 用内容相同的对象替换末句、触发 UI 无意义重建。
  bool sameContentAs(CaptionSentenceItem other) =>
      id == other.id &&
      original == other.original &&
      translation == other.translation &&
      pronunciation == other.pronunciation &&
      isLatest == other.isLatest &&
      isFinal == other.isFinal && listEquals(contextRanges, other.contextRanges);

  @override
  bool operator ==(Object other) =>
      other is CaptionSentenceItem && sameContentAs(other);

  @override
  int get hashCode => Object.hash(
        id,
        original,
        translation,
        pronunciation,
        isLatest,
        isFinal,
        Object.hashAll(contextRanges),
      );
}

class RealtimeCaptions {
  RealtimeCaptions({CaptionPreferences? preferences}) {
    if (preferences != null) {
      bindPreferences(preferences);
    }
  }

  static const automaticTrack = -1;
  static const realtimeTrack = -2;
  static const realtimeLocalTrack = -2;
  static const realtimeCloudTrack = -3;
  static const _leadMs = 15000;
  /// 云端 ASR 预读领先量（毫秒）。
  /// 视频音轨不是实时麦克风，可以提前从文件解码并送入引擎。这个"位置差"让
  /// 引擎处理进度领先播放位置：引擎返回某句话时，该句时间戳落在"未来的播放
  /// 时刻"，等播放推进到那里字幕早已就绪，从而消除引擎固有延迟造成的滞后。
  /// 本地离线识别用 15s + 8x（效果好），云端取 6s 折中——足以覆盖引擎延迟，
  /// 又不至于一次性灌太多导致云端队列拥塞。
  static const cloudReadAheadMs = 6000;
  static const _translationLeadMs = 15000;
  static const _endToleranceMs = 1500;
  static const _trackWait = Duration(seconds: 5);
  static const _emptyCues = <CaptionCue>[];

  /// 预读读取上限（相对会话音频流起点，毫秒）= 播放进度 + 预读位置差。
  /// 视频音轨从 [originMs] 开始解码，与画面共用同一条时间轴：
  /// 允许读到"播放位置 + readAheadMs"，发送预算才喂得饱，引擎处理进度
  /// 才能真正领先画面，字幕时间戳才落在未来的播放时刻（同步而非滞后）。
  static int asrReadThroughMs({
    required int playbackMs,
    required int originMs,
    required int readAheadMs,
  }) => math.max(0, playbackMs + readAheadMs - originMs);

  /// 字幕就绪领先量（毫秒）= 引擎已处理音频映射回的视频时刻 - 当前播放时刻。
  /// >0：引擎已处理到画面还没播到的地方，字幕就绪、将准时上屏（同步）；
  /// =0：勉强跟上；<0：引擎落后，字幕迟到。
  static int captionReadyLeadMs({
    required int originMs,
    required int engineProcessedMs,
    required int playbackMs,
  }) => originMs + engineProcessedMs - playbackMs;

  /// 云端流式识别的自适应推流速率（背压 backpressure）。
  ///
  /// "一开始同步、越看越延迟"的根因：推流固定 1.15×，若持续快于引擎吞吐，
  /// 引擎待处理积压 (sentMs - processedMs) 会不断累积，每句结果的返回时刻
  /// 越来越晚，字幕时间戳随之越来越落后于播放位置。
  ///
  /// 用积压量做反馈：积压越大越减速、让引擎消化，避免延迟累积；
  /// 就绪领先不足且积压不大时适度加速追赶。积压稳定在小范围 → 结果延迟
  /// 不再随时间增长，字幕长期保持同步。
  static double cloudAdaptiveSendRate({
    required double baseRate,
    required int pendingMs,
    required int readyLeadMs,
  }) {
    var factor = 1.0;
    if (pendingMs > 6000) {
      factor = 0.0; // 积压过大：暂停推送，引擎全力消化
    } else if (pendingMs > 4000) {
      factor = 0.35;
    } else if (pendingMs > 2500) {
      factor = 0.7;
    }
    // 就绪领先不足（字幕偏晚）且积压不大 → 适度加速追赶
    if (readyLeadMs < 1200 && factor > 0.5) {
      factor = math.min(1.3, factor + 0.3);
    }
    return (baseRate * factor).clamp(0.0, 2.0);
  }

  static const _loadingTracks = '正在读取视频自带字幕…';
  static const _readingAudio = '识别服务已连接，正在读取视频音轨…';

  CaptionPreferences? _preferences;
  CaptionPreferences? get preferences => _preferences;

  final showOriginal = false.obs;
  final showTranslation = false.obs;
  final showPronunciation = false.obs; // 是否显示发音注音 (视频字幕 HUD 专用)
  final sheetShowPronunciation = true.obs; // 是否显示词典弹窗发音注音 (词典弹窗独立开关)
  final chinesePhonetic = 'auto'.obs; // 中文/粤语发音类型：'auto' (自动检测), 'cantonese' (粤拼), 'mandarin' (拼音)
  final japanesePhonetic = 'kana'.obs; // 日语发音类型：'kana' (假名) 或 'romaji' (罗马音)
  final frame = Rxn<CaptionFrame>();
  final sentenceQueue = <CaptionSentenceItem>[].obs;
  Timer? _retentionTimer;
  final tracks = <SubTitlteItemModel>[].obs;
  final selectedTrack = automaticTrack.obs;
  final preferredSubtitleSource = 'official'.obs; // 'official' (官方字幕优先), 'sherpa' (本地离线优先), 'qwen' (云端在线优先)
  final useLocalAsr = false.obs; // 是否使用 Sherpa-ONNX 离线本地识别
  final localAsrModel = 'sense_voice'.obs; // 离线识别模型：'sense_voice', 'whisper_tiny', 'whisper_base', 'whisper_small'
  final onlineAsrEngine = 'azure'.obs; // 云端在线引擎：'azure', 'doubao', 'deepgram', 'qwen'
  final doubaoAuthMode = 'api_key'.obs; // 豆包鉴权方式：'api_key', 'token'
  final doubaoApiKey = ''.obs;
  final doubaoAppId = ''.obs;
  final doubaoAccessToken = ''.obs;
  final deepgramApiKey = ''.obs;
  final onlineAsrLanguage = 'auto'.obs; // 识别语言（视频原声）：'auto', 'zh-CN', 'en-US', 'zh-HK', 'ja-JP', 'ko-KR'
  final targetLanguage = 'zh-CN'.obs; // 目标翻译语言
  final translationEngine = 'microsoft'.obs; // 翻译服务：'microsoft' (微软翻译 · 免翻墙直连), 'google' (谷歌翻译)
  final captionDelayMs = 0.obs; // 字幕时间轴偏移（毫秒，负数为提前/防慢一拍，正数为延后）
  final status = ''.obs;
  final asrError = ''.obs;
  final translationError = ''.obs;
  final cloudLagWarning = false.obs;
  final needLoginForSubtitles = false.obs;

  CaptionTimeline? _translatedTimeline;
  int? _translatedTimelineTrackId;
  SubTitlteItemModel? _translatedTrack;
  SubTitlteItemModel? get activeTranslatedTrack => _translatedTrack;

  final _translator = CaptionTranslator();
  final _clock = CaptionPlaybackClock();
  final _elapsed = Stopwatch()..start();
  final _asrLog = ListQueue<String>();
  final _translations = <String, String>{};
  final _translationRequests = <String, CancelToken>{};
  final _translationFailures = <String>{};
  final _pronunciations = <String, String>{};
  final _pronunciationRequests = <String, bool>{};

  Player? _player;
  DataSource? _source;
  int _attachment = 0;
  int _seeksInProgress = 0;
  int? _loadingPositionMs;
  int? _lastPositionMs;
  int _lastPositionSampleMs = 0;
  Timer? _ticker;
  bool _seekBufferingPaused = false;
  Timer? _seekBufferingTimer;

  void _resumeSeekBufferingPlayback() {
    _seekBufferingTimer?.cancel();
    _seekBufferingTimer = null;
    if (_seekBufferingPaused) {
      _seekBufferingPaused = false;
      if (status.value == '正在预缓冲识别字幕…') {
        status.value = '';
      }
      final player = _player;
      if (player != null && !player.state.playing && !player.state.completed) {
        player.play();
      }
    }
  }

  ({String bvid, int cid})? _video;
  Object? _trackRequest;
  Object? _trackSelection;
  int _trackWaitUntilMs = 0;
  CaptionTimeline? _videoTimeline;
  SubTitlteItemModel? _activeTrack;
  String? videoTitle;

  bool get isCantoneseTrack {
    if (chinesePhonetic.value == 'cantonese') return true;
    final t = _activeTrack;
    if (t != null) {
      final doc = (t.lanDoc ?? t.title ?? '').toLowerCase();
      final lan = (t.lan ?? '').toLowerCase();
      if (doc.contains('粤') ||
          doc.contains('粵') ||
          doc.contains('广东') ||
          doc.contains('廣東') ||
          doc.contains('cantonese') ||
          lan.contains('zhhk') ||
          lan.contains('zh-hk') ||
          lan.contains('yue')) {
        return true;
      }
    }
    final vTitle = videoTitle?.toLowerCase() ?? '';
    if (vTitle.contains('粤语') ||
        vTitle.contains('粵語') ||
        vTitle.contains('广东话') ||
        vTitle.contains('廣東话') ||
        vTitle.contains('廣東話') ||
        vTitle.contains('cantonese')) {
      return true;
    }
    return false;
  }

  bool get isJapaneseTrack {
    final t = _activeTrack;
    if (t != null) {
      final doc = (t.lanDoc ?? t.title ?? '').toLowerCase();
      final lan = (t.lan ?? '').toLowerCase();
      if (doc.contains('日') ||
          doc.contains('日本') ||
          doc.contains('japan') ||
          lan.startsWith('ja')) {
        return true;
      }
    }
    final vTitle = videoTitle?.toLowerCase() ?? '';
    if (RegExp(r'[\u3040-\u309F\u30A0-\u30FF]').hasMatch(vTitle) ||
        vTitle.contains('日语') ||
        vTitle.contains('日文') ||
        vTitle.contains('日漫') ||
        vTitle.contains('日剧') ||
        vTitle.contains('动漫') ||
        vTitle.contains('番剧') ||
        vTitle.contains('生肉') ||
        vTitle.contains('熟肉') ||
        vTitle.contains('japanese') ||
        vTitle.contains('アニメ') ||
        vTitle.contains('ova')) {
      return true;
    }
    return false;
  }

  String? _sessionDetectedLanguage;

  String? get activeTrackLan => _activeTrack?.lan;

  String? get detectedTrackLanguage {
    if (isCantoneseTrack) return 'yue';
    final lan = _activeTrack?.lan?.toLowerCase();
    final doc = (_activeTrack?.lanDoc ?? _activeTrack?.title)?.toLowerCase();
    if (lan != null && lan.isNotEmpty) {
      if (lan.contains('zh-cn') || lan.contains('zh-hans') || lan == 'zh') return 'zh-CN';
      if (lan.contains('zh-hk') || lan.contains('zh-tw') || lan.contains('zh-hant') || lan == 'yue') return 'yue';
      if (lan.startsWith('en')) return 'en';
      if (lan.startsWith('ja')) return 'ja';
      if (lan.startsWith('ko')) return 'ko';
      if (lan.startsWith('tr')) return 'tr';
      if (lan.startsWith('fr')) return 'fr';
      if (lan.startsWith('de')) return 'de';
      if (lan.startsWith('es')) return 'es';
      if (lan.startsWith('ru')) return 'ru';
    }
    if (doc != null && doc.isNotEmpty) {
      if (doc.contains('粤') || doc.contains('粵') || doc.contains('广东') || doc.contains('cantonese')) return 'yue';
      if (doc.contains('土耳其')) return 'tr';
      if (doc.contains('英')) return 'en';
      if (doc.contains('日')) return 'ja';
      if (doc.contains('韩')) return 'ko';
      if (doc.contains('法')) return 'fr';
      if (doc.contains('德')) return 'de';
      if (doc.contains('西')) return 'es';
      if (doc.contains('俄')) return 'ru';
      if (doc.contains('中') || doc.contains('华')) return 'zh-CN';
    }
    return null;
  }

  /// 获取当前整篇字幕的全局语境语言（综合官方轨元数据与时间线全量内容感知）
  String? get currentLanguageContext {
    if (isCantoneseTrack || chinesePhonetic.value == 'cantonese') return 'yue';
    if (isJapaneseTrack) return 'ja';
    if (_sessionDetectedLanguage != null) return _sessionDetectedLanguage;
    final trackLang = detectedTrackLanguage;
    if (trackLang != null && trackLang != 'zh-CN') return trackLang;
    final cues = _timeline.cues;
    if (cues.isNotEmpty) {
      int jaCount = 0;
      int koCount = 0;
      int yueCount = 0;
      int trCount = 0;
      final sample = cues.length > 80 ? cues.take(80) : cues;
      for (final c in sample) {
        if (RegExp(r'[\u3040-\u309F\u30A0-\u30FF]').hasMatch(c.text)) jaCount++;
        if (RegExp(r'[\uAC00-\uD7AF]').hasMatch(c.text)) koCount++;
        if (CaptionPronunciation.isCantoneseText(c.text)) yueCount++;
        if (RegExp(r'[ğşıöüçĞŞİÖÜÇ]').hasMatch(c.text)) trCount++;
      }
      if (jaCount > 0) return 'ja';
      if (yueCount > 0) return 'yue';
      if (koCount > 0) return 'ko';
      if (trCount > 0) return 'tr';
    }
    if (trackLang != null) return trackLang;
    return null;
  }

  String get asrLanguage =>
      (isCantoneseTrack || chinesePhonetic.value == 'cantonese') ? 'yue' : 'auto';

  String get effectiveOnlineAsrLanguage {
    final prefLang = onlineAsrLanguage.value;
    if (prefLang != 'auto' && prefLang.isNotEmpty) {
      return prefLang;
    }
    final trackLang = detectedTrackLanguage;
    if (trackLang != null && trackLang.isNotEmpty) {
      switch (trackLang) {
        case 'en':
          return 'en-US';
        case 'ja':
          return 'ja-JP';
        case 'ko':
          return 'ko-KR';
        case 'yue':
          return 'zh-HK';
        case 'zh-CN':
          return 'zh-CN';
      }
    }
    final title = (videoTitle ?? '').trim();
    if (title.isNotEmpty) {
      if (RegExp(r'[\u3040-\u309F\u30A0-\u30FF]').hasMatch(title)) return 'ja-JP';
      if (RegExp(r'[\uAC00-\uD7AF]').hasMatch(title)) return 'ko-KR';
      if (isCantoneseTrack ||
          title.contains('粤语') ||
          title.contains('粵語') ||
          title.contains('广东话')) {
        return 'zh-HK';
      }
      final hasChinese = RegExp(r'[\u4E00-\u9FA5]').hasMatch(title);
      final hasEnglishWords = RegExp(r'\b[a-zA-Z]{3,}\b').hasMatch(title);
      if (hasEnglishWords && !hasChinese) {
        return 'en-US';
      }
    }
    if (onlineAsrEngine.value == 'deepgram') {
      return 'multi';
    }
    return 'zh-CN';
  }

  _CaptionSession? _session;
  int _sessionSequence = 0;
  Future<void> _previousSession = Future.value();
  final _asrCues = <CaptionCue>[];
  final _asrDelivery = CaptionCueDelivery();
  CaptionCue? _lastQueuedCue;
  CaptionTimeline _asrTimeline = CaptionTimeline(_emptyCues);
  int? _nextAsrStartMs;
  Timer? _asrRetryTimer;
  int _asrRetryCount = 0;
  bool _reachedEnd = false;

  bool get enabled => showOriginal.value || showTranslation.value;
  CaptionTimeline get _timeline {
    if (selectedTrack.value == realtimeLocalTrack ||
        selectedTrack.value == realtimeCloudTrack ||
        selectedTrack.value == realtimeTrack) {
      return _asrTimeline;
    }
    return _videoTimeline ?? _asrTimeline;
  }

  bool get isNativeSubtitle => _videoTimeline != null;
  bool get isUsingLocalAsr =>
      _session != null ? _session!.isLocal : (useLocalAsr.value && LocalAsrModelManager.isSupported);
  String? get activeTrackDoc => _activeTrack?.lanDoc ?? _activeTrack?.title;

  String get activeSourceType {
    if (_videoTimeline != null || selectedTrack.value > 0) {
      return 'official';
    }
    if (_session != null) {
      return _session!.isLocal ? 'sherpa' : 'qwen';
    }
    if (selectedTrack.value == realtimeLocalTrack || (useLocalAsr.value && LocalAsrModelManager.isSupported)) {
      return 'sherpa';
    }
    return 'qwen';
  }

  void switchSubtitleSource(String source) {
    if (source == 'sherpa') {
      selectTrack(realtimeLocalTrack);
    } else if (source == 'qwen') {
      selectTrack(realtimeCloudTrack);
    } else if (source == 'official') {
      final officialId = tracks.isNotEmpty ? (tracks.first.id ?? automaticTrack) : automaticTrack;
      selectTrack(officialId);
    }
  }

  String get activeSourceTag => activeSourceLabel;

  String get onlineEngineName {
    switch (onlineAsrEngine.value) {
      case 'azure':
        return '微软流式 (免Key)';
      case 'doubao':
        return '豆包流式 2.0';
      case 'deepgram':
        return 'Deepgram Nova-3';
      case 'qwen':
        return 'Qwen ASR';
      default:
        return '云端在线';
    }
  }

  String get activeSourceLabel {
    if (!showOriginal.value) {
      return '已关闭';
    }
    if (selectedTrack.value == 0) {
      return '无字幕';
    }
    if (_videoTimeline != null) {
      final doc = _activeTrack?.lanDoc ?? _activeTrack?.title;
      return (doc != null && doc.isNotEmpty) ? 'B站官方 · $doc' : 'B站官方';
    }
    if (_session != null) {
      return _session!.isLocal ? '本地离线' : onlineEngineName;
    }
    if (useLocalAsr.value && LocalAsrModelManager.isSupported) return '本地离线';
    return onlineEngineName;
  }

  String get activeSourceDescription {
    if (!showOriginal.value) {
      return '字幕与语音识别已关闭';
    }
    if (selectedTrack.value == 0) {
      return '当前视频已关闭字幕';
    }
    if (_videoTimeline != null) {
      final doc = _activeTrack?.lanDoc ?? _activeTrack?.title;
      return doc != null && doc.isNotEmpty ? 'B站官方字幕 · $doc' : 'B站官方字幕';
    }
    if (_session != null) {
      if (_session!.isLocal) {
        final cfg = LocalAsrModelManager.availableModels[localAsrModel.value];
        return '本地离线识别 · ${cfg?.name ?? "Sherpa-ONNX"}';
      }
      return '云端在线识别 · $onlineEngineName';
    }
    if (useLocalAsr.value && LocalAsrModelManager.isSupported) {
      final cfg = LocalAsrModelManager.availableModels[localAsrModel.value];
      return '本地离线识别 · ${cfg?.name ?? "Sherpa-ONNX"}';
    }
    return '云端在线识别 · $onlineEngineName';
  }

  void bindPreferences(CaptionPreferences preferences) {
    _preferences = preferences;
    showOriginal.value = preferences.showOriginal.value;
    showTranslation.value = preferences.showTranslation.value;
    showPronunciation.value = preferences.showPronunciation.value;
    sheetShowPronunciation.value = preferences.sheetShowPronunciation.value;
    chinesePhonetic.value = preferences.chinesePhonetic.value;
    japanesePhonetic.value = preferences.japanesePhonetic.value;
    preferredSubtitleSource.value = preferences.preferredSubtitleSource.value;
    useLocalAsr.value = preferences.useLocalAsr.value;
    localAsrModel.value = preferences.localAsrModel.value;
    onlineAsrEngine.value = preferences.onlineAsrEngine.value;
    doubaoAuthMode.value = preferences.doubaoAuthMode.value;
    doubaoApiKey.value = preferences.doubaoApiKey.value;
    doubaoAppId.value = preferences.doubaoAppId.value;
    doubaoAccessToken.value = preferences.doubaoAccessToken.value;
    deepgramApiKey.value = preferences.deepgramApiKey.value;
    onlineAsrLanguage.value = preferences.onlineAsrLanguage.value;
    targetLanguage.value = preferences.targetLanguage.value;
    translationEngine.value = preferences.translationEngine.value;
    captionDelayMs.value = preferences.captionDelayMs.value;
    preferences.showTranslation.listen((val) {
      if (showTranslation.value != val) {
        setTranslation(val);
      }
    });
    preferences.showPronunciation.listen((val) {
      if (showPronunciation.value != val) {
        setPronunciation(val);
      }
    });
    preferences.sheetShowPronunciation.listen((val) {
      if (sheetShowPronunciation.value != val) {
        setSheetPronunciation(val);
      }
    });
    LocalAsrModelManager.shared.currentModelId.value =
        preferences.localAsrModel.value;
  }

  /// 句末标点：中英文全覆盖。
  /// 中文：。！？｡（半角句号）…‼⁉～（全角波浪）
  /// 英文：. ! ?
  /// 逗号、顿号、分号、冒号是句内停顿，不算句末。
  static final RegExp _sentenceEndOnly = RegExp(r'[。！？｡…‼⁉～~.!?]');

  /// 句末标点后常跟右引号/右括号（ASR 输出或标点后处理会产生），
  /// 例：他说"今天天气不错。"  /  What did he say?   />
  /// 判定前先把这些"装饰"剥掉，否则最后一个字符是引号会被误判为未完成。
  static final RegExp _trailingDecorations =
      RegExp(r'[\s"“”‘’）)】》」』］\]]+$');

  /// 缓存队列的"完整句"判定：只认真正的句末标点（中英文均可）。
  ///
  /// 用户要的简单逻辑：没到句末标点就一直往后追加，
  /// 遇到句末标点才认为一句完整、缓存并另起一行。逗号/顿号不算完结。
  static bool isCompleteSentence(String text) {
    if (text.endsWith('\n')) return true;
    final trimmed = text.replaceAll(_trailingDecorations, '');
    if (trimmed.isEmpty) return false;
    return _sentenceEndOnly.hasMatch(trimmed.substring(trimmed.length - 1));
  }

  /// 其他地方（如 cueIsFinal）的句末判定与队列必须完全一致，
  /// 否则会出现"队列认为完整、cue 认为不完整"的错配。
  static bool _isSentenceTerminated(String text) => isCompleteSentence(text);

  /// 识别“掐头校正”：后到的定稿句 = 先到的预览句掐掉开头若干字。
  /// 豆包 enable_nonstream 二遍识别里，一遍预览常把上一句尾部（如“紫一块的”）
  /// 错误粘到本句开头，二遍精校会把这些前缀去掉，得到“痕迹，就连…”这样的定稿。
  /// 这种情况必须用定稿原地替换预览，否则会显示成上下两行近似重复的字幕。
  static bool _isTrimCorrection(String previous, String incoming) {
    final prev =
        previous.replaceAll(RegExp(r'[，。！？,.!?、；;\s]'), '').toLowerCase();
    final inc =
        incoming.replaceAll(RegExp(r'[，。！？,.!?、；;\s]'), '').toLowerCase();
    // 定稿必须明显更短（被掐头），且仍是一句有内容的文本，避免误判正常增量。
    if (inc.length < 4 || inc.length >= prev.length) return false;
    // 预览句以定稿句结尾 → 定稿是预览去掉开头后的结果；占比够高才认作校正。
    return prev.endsWith(inc) && inc.length / prev.length >= 0.7;
  }

  /// 近似重复句判定（ASR 在静音/噪音段会把同一段话反复识别成略有差异的几版，
  /// 例如“城中村里面…你看它给我城” / “中村里面…你看他跟我说房城中”）。
  /// 这类句子不是预览→定稿的掐头关系，也不是正常增量，
  /// 旧逻辑会把每一版都当作新句入队 → 屏幕上出现多行近乎一样的字幕。
  ///
  /// 判定标准（归一化后比对）：
  /// 1. 完全相等，或一句包含另一句；
  /// 2. 最长公共连续子串 >= 8 字且占较短句的一半以上。
  /// 8 个连续汉字相同基本只可能是同一段话的重复识别，
  /// 正常相邻两句顶多共用“的/了/时候”等 2~3 字，不会误伤。
  static String _normalizeCaptionText(String text) => text
      .replaceAll(RegExp(r'[，。！？,.!?、；;：:\s…~"“”‘’()（）]'), '')
      .toLowerCase();

  static int _longestCommonSubstringLength(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final prev = List<int>.filled(b.length + 1, 0);
    final curr = List<int>.filled(b.length + 1, 0);
    var best = 0;
    for (var i = 1; i <= a.length; i++) {
      for (var j = 1; j <= b.length; j++) {
        if (a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1)) {
          curr[j] = prev[j - 1] + 1;
          if (curr[j] > best) best = curr[j];
        } else {
          curr[j] = 0;
        }
      }
      prev.setAll(0, curr);
    }
    return best;
  }

  static bool _isNearDuplicateCaption(String previous, String incoming) {
    final a = _normalizeCaptionText(previous);
    final b = _normalizeCaptionText(incoming);
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;
    final short = math.min(a.length, b.length);
    final long = math.max(a.length, b.length);
    if (short < 8) return false;
    // 长度差距过大时“包含”只是普通短句恰好出现在长句里，不能算同一句。
    if (short / long >= 0.6 && (a.contains(b) || b.contains(a))) return true;
    final common = _longestCommonSubstringLength(a, b);
    return common >= 8 && common / short >= 0.5;
  }

  /// 近重复/掐头校正时，是否允许用后到版本替换队尾已入队的句子。
  ///
  /// 铁律：缓存是队列（FIFO），已入队的句子只能被"更完整"的版本升级，
  /// 绝不能被更短的尾部版本覆盖——那正是"缓存只剩最后几个字"的根源。
  /// 后到的短版本带不带句号都不行：它可能只是 ASR 对同一段话的二次识别。
  static bool shouldReplaceByMoreComplete(
    String queuedOriginal,
    bool queuedFinal,
    String incoming,
    bool incomingFinal,
  ) {
    final queuedLen = _normalizeCaptionText(queuedOriginal).length;
    final incomingLen = _normalizeCaptionText(incoming).length;
    if (incomingLen > queuedLen) return true; // 更完整 → 升级
    if (incomingLen < queuedLen) return false; // 只剩尾部 → 绝不覆盖
    // 等长：只在新版确认成句、旧版还是预览时升级
    return incomingFinal && !queuedFinal;
  }

  /// 汉字字符（含常用扩展区）。用于判断拼接边界是否需要插入空格。
  static final RegExp _cjkIdeograph =
      RegExp(r'[\u4E00-\u9FFF\u3400-\u4DBF]');

  /// 判断两段文字拼接时是否需要在边界插入一个空格。
  /// - 西文/数字相邻：始终需要（原有逻辑）；
  /// - cjkSpace=true 时，汉字与汉字相邻也需要（官方字幕逐条追加，避免汉字黏在一起）；
  /// - 已有空白、或任一侧是标点：不再插入。
  static bool _needsJoinSpace(String left, String right,
      {required bool cjkSpace}) {
    if (left.isEmpty || right.isEmpty) return false;
    if (RegExp(r'\s$').hasMatch(left) || RegExp(r'^\s').hasMatch(right)) {
      return false;
    }
    // 西文/数字边界（兼容原有行为）
    if (RegExp(r'[a-zA-Z0-9]$').hasMatch(left) &&
        RegExp(r'^[a-zA-Z0-9]').hasMatch(right)) {
      return true;
    }
    // 官方字幕：汉字↔汉字之间插空格提升阅读感
    if (cjkSpace &&
        _cjkIdeograph.hasMatch(left.substring(left.length - 1)) &&
        _cjkIdeograph.hasMatch(right.substring(0, 1))) {
      return true;
    }
    return false;
  }

  /// 智能长句合并器：消除前后缀重叠、子串包含与模型幻觉重复
  /// [cjkSpace] 为 true 时，汉字片段之间追加会插入一个空格（官方字幕用）。
  static String mergeCaptionTexts(String existing, String incoming,
      {bool cjkSpace = false, bool deduplicate = true}) {
    final ex = existing.trim();
    final inc = incoming.trim();
    if (inc.isEmpty) return ex;
    if (ex.isEmpty) return inc;
    // Distinct audio segments may repeat real words or whole phrases.
    // Only revisions of the same segment are eligible for text deduplication.
    if (!deduplicate) {
      return _needsJoinSpace(ex, inc, cjkSpace: cjkSpace)
          ? '$ex $inc' : '$ex$inc';
    }
    if (ex == inc) return ex;

    // 1. 仅"尾部重合"才去重：旧代码用 ex.contains(inc)，新片段出现在句中任意位置
    // 都会被整段丢弃 → 缓存句子漏词。只有 inc 是 ex 的结尾（增量回退修正）才安全。
    if (ex.endsWith(inc) || ex.endsWith(' $inc')) {
      return ex;
    }

    // 2. 若新片段完全包含已有句子（增量识别结果）
    if (inc.startsWith(ex)) {
      return inc;
    }
    if (ex.startsWith(inc)) {
      return ex;
    }

    // 2.1 标点容错前缀重合判断（例如 ex="你哋两个一齐去台湾见姑，", inc="你哋两个一齐去台湾见姑正阳喺即系大家都"）
    final cleanEx = ex.replaceAll(RegExp(r'[，。！？,.!?、；;\s]'), '');
    final cleanInc = inc.replaceAll(RegExp(r'[，。！？,.!?、；;\s]'), '');
    if (cleanInc.startsWith(cleanEx) && cleanEx.length >= 2) {
      return inc;
    }
    if (cleanEx.startsWith(cleanInc) && cleanInc.length >= 2) {
      return ex;
    }

    // 3. 最大前后缀重叠匹配 (Suffix-to-Prefix Overlap)
    // 例如 existing: "factory you're stuff in", incoming: "stuff in Shanghai"
    // 重叠部分: "stuff in", 仅追加: " Shanghai"
    // 门槛 3→5：中文相邻片段 3 字首尾重合很常见，低门槛会切掉真实字造成漏词。
    final maxCheck = math.min(ex.length, inc.length);
    for (int len = maxCheck; len >= 5; len--) {
      final exSuffix = ex.substring(ex.length - len);
      final incPrefix = inc.substring(0, len);
      if (exSuffix.toLowerCase() == incPrefix.toLowerCase()) {
        final remainder = inc.substring(len).trim();
        if (remainder.isEmpty) return ex;
        // 这里是同一句的"重叠续写"（如 公园→公园玩了），不是新分段，
        // 插空格会把一个词劈开，因此仍按原 ASCII 规则处理。
        final bool needSpace = RegExp(r'[a-zA-Z0-9]$').hasMatch(ex) &&
            RegExp(r'^[a-zA-Z0-9]').hasMatch(remainder);
        return needSpace ? '$ex $remainder' : '$ex$remainder';
      }
    }

    // 4. 单词级重叠匹配（针对带空格的西文）
    final exWords = ex.split(RegExp(r'\s+'));
    final incWords = inc.split(RegExp(r'\s+'));
    if (exWords.isNotEmpty && incWords.isNotEmpty) {
      final maxWordCheck = math.min(exWords.length, incWords.length);
      for (int wLen = maxWordCheck; wLen >= 1; wLen--) {
        final exTail =
            exWords.sublist(exWords.length - wLen).join(' ').toLowerCase();
        final incHead = incWords.sublist(0, wLen).join(' ').toLowerCase();
        if (exTail == incHead) {
          final remainderWords = incWords.sublist(wLen);
          if (remainderWords.isEmpty) return ex;
          return '$ex ${remainderWords.join(' ')}';
        }
      }
    }

    // 5. 跨分段安全拼接（带标点与空格适配）
    final bool needSpace = _needsJoinSpace(ex, inc, cjkSpace: cjkSpace);
    final merged = needSpace ? '$ex $inc' : '$ex$inc';

    // 6. 最终通过连续短语抑制器过滤
    return removeRepeatingPhrases(merged);
  }

  /// 连续重复短语/单词抑制器 (消除模型在静音/噪音下的循环刷屏，如 "P P P P")
  static String removeRepeatingPhrases(String text) {
    final guarded = suppressAsrShortLoops(text);
    if (guarded != text) return guarded;
    if (text.isEmpty) return text;

    // A. 西文词级 N-gram 连续重复抑制
    // 漏词教训：k>=2 会把 "no no"、"the the" 这类口误/强调当成幻觉删掉一个词。
    // 提高到 k>=3，只清理 3 词以上的整段循环，保住正常口语。
    final words =
        text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.length >= 6) {
      final maxK = (words.length / 2).floor().clamp(3, 15);
      for (int k = maxK; k >= 3; k--) {
        for (int i = 0; i + 2 * k <= words.length; i++) {
          final phrase1 = words.sublist(i, i + k).join(' ').toLowerCase();
          final phrase2 =
              words.sublist(i + k, i + 2 * k).join(' ').toLowerCase();
          if (phrase1 == phrase2) {
            // 发现连续重复词串！裁切消除重复部分
            final cleanWords = [
              ...words.sublist(0, i + k),
              ...words.sublist(i + 2 * k),
            ];
            return removeRepeatingPhrases(cleanWords.join(' '));
          }
        }
      }
    }

    // B. 中文/字符级短语连续重复抑制（忽略标点比对）
    // 漏词教训：旧门槛 >=3 字会误删正常口语强调，例如
    //   “我不知道我不知道他在哪里” → “我不知道他在哪里”
    //   “你是不是是不是搞错了” → “你是不是搞错了”
    // 正常口语重复多为 2~5 字，只有整段幻觉循环才会精确重复 10 字以上。
    // 门槛提高到 10 字：宁可留下重复（用户可接受），也绝不删掉说过的字。
    for (int len = (text.length / 2).floor().clamp(1, 24); len >= 10; len--) {
      for (int i = 0; i + 2 * len <= text.length; i++) {
        final p1 = text.substring(i, i + len).trim();
        final p2 = text.substring(i + len, i + 2 * len).trim();
        if (p1.isNotEmpty && p2.isNotEmpty) {
          final c1 = p1.replaceAll(RegExp(r'[，。！？,.!?、；;\s]'), '');
          final c2 = p2.replaceAll(RegExp(r'[，。！？,.!?、；;\s]'), '');
          if (c1.isNotEmpty && c1 == c2) {
            final collapsed =
                text.substring(0, i + len) + text.substring(i + 2 * len);
            return removeRepeatingPhrases(collapsed);
          }
        }
      }
    }

    return text;
  }

  /// 队列内部保留的句子数上限：仅防内存无限增长（供词典回看历史等），
  /// 与界面显示无关——字幕框可见行数由「字幕框显示行数」设置决定。
  static const int _maxQueueSentences = 12;

  void _pruneSentenceQueue() {
    while (sentenceQueue.length > _maxQueueSentences) {
      sentenceQueue.removeAt(0);
    }
  }

  void clearSentenceQueue() {
    sentenceQueue.clear();
    _asrDelivery.clear();
    _lastQueuedCue = null;
    _retentionTimer?.cancel();
    _retentionTimer = null;
  }

  void setCaptionDelay(int ms) {
    captionDelayMs.value = ms.clamp(-5000, 5000);
    _preferences?.setCaptionDelay(captionDelayMs.value);
    final now = _clock.at(_elapsed.elapsedMilliseconds);
    _render(now);
  }

  String get asrDiagnostics {
    final position = _clock.at(_elapsed.elapsedMilliseconds);
    final state = _player?.state;
    final session = _session;
    return [
      'Lynxi 字幕诊断 v1',
      'position_ms=$position delay_ms=${captionDelayMs.value} native=${_videoTimeline != null} '
          'native_end_ms=${_videoTimeline?.endMs} '
          'tracks=${tracks.length} original=${showOriginal.value} '
          'translated=${showTranslation.value} '
          'pronunciation=${showPronunciation.value} '
          'visible=${frame.value != null}',
      if (state != null)
        'playing=${state.playing} buffering=${state.buffering} '
            'completed=${state.completed} rate=${state.rate}',
      ..._asrLog,
      if (session != null) 'now s=${session.id} ${_sample(session, position)}',
    ].join('\n');
  }

  void _record(String event, [_CaptionSession? session]) {
    if (_asrLog.length == 48) _asrLog.removeFirst();
    final id = session == null ? '' : ' s=${session.id}';
    _asrLog.addLast('${_elapsed.elapsedMilliseconds}ms$id $event');
  }

  String _sample(_CaptionSession session, int position) {
    final pcm = session.pcm;
    final timing = session.timing;
    final cue = session.lastCue;
    const bytesPerMs = PlayerPcm.bytesPerSecond ~/ 1000;
    return 'pos_ms=$position pcm_ms=${(pcm?.bytesRead ?? 0) ~/ bytesPerMs} '
        'written_ms=${(pcm?.bytesWritten ?? 0) ~/ bytesPerMs} '
        'decoder_paused=${pcm?.paused} decoder_buffering=${pcm?.buffering} '
        'active_ms=${timing?.speech.activeMs} '
        'peak_dbfs=${timing?.speech.takePeakRmsDbfs()} '
        'sent_ms=${session.stream.sentMilliseconds} '
        'ack_ms=${session.stream.processedMilliseconds} '
        'ready_lead_ms=${timing == null ? null : captionReadyLeadMs(originMs: timing.originMs, engineProcessedMs: session.stream.processedMilliseconds ?? 0, playbackMs: position)} '
        'rx=${session.results} deltas=${session.deltas} updates=${session.updates} '
        'empty_updates=${session.emptyUpdates} '
        'last_cue_ms=${cue?.startMs}..${cue?.endMs} visible=${frame.value != null}';
  }

  void prepareTracks(String bvid, int cid, {String? title}) {
    if (title != null && title.isNotEmpty) videoTitle = title;
    if (_video?.bvid == bvid && _video?.cid == cid) return;
    _video = (bvid: bvid, cid: cid);
    _asrLog.clear();
    _record('loading native tracks');
    needLoginForSubtitles.value = false;
    // 立即清空上一视频的字幕帧、时间轴与翻译状态，防止串台或残留显示上一个视频的字幕
    frame.value = null;
    clearSentenceQueue();
    _activeTrack = null;
    _videoTimeline = null;
    _translatedTimeline = null;
    _translatedTrack = null;
    _translatedTimelineTrackId = null;
    _translations.clear();
    _translationFailures.clear();
    _resetAsr('switching video to $bvid');
    _cancelTranslations();
    _pronunciations.clear();
    _trackSelection = null;
    selectedTrack.value = automaticTrack;
    tracks.clear();
    final request = _trackRequest = Object();
    _trackWaitUntilMs =
        _elapsed.elapsedMilliseconds + _trackWait.inMilliseconds;
    unawaited(_loadTracks(request, bvid, cid));
    unawaited(Future<void>.delayed(_trackWait, () {
      if (_video == (bvid: bvid, cid: cid)) updatePlayback();
    }));
  }

  Future<void> _loadTracks(Object request, String bvid, int cid) async {
    try {
      final result = await VideoHttp.getSubtitleTracks(bvid: bvid, cid: cid);
      if (_trackRequest != request) return;
      _trackRequest = null;
      // 校验视频仍是当前请求的视频，防止切视频后异步回调污染新视频
      if (_video?.bvid != bvid || _video?.cid != cid) return;

      needLoginForSubtitles.value = VideoHttp.lastSubtitleNeedLogin;

      // 保留所有有效的 B站官方字幕轨（包括人工精校与官方 AI 生成字幕）
      // 优先将人工精校字幕排在前面供自动选用，AI 生成字幕紧随其后供用户自由切换
      final validTracks = result.where((track) {
        if (track.id == null || track.subtitleUrl?.isNotEmpty != true) return false;
        return true;
      }).toList();

      // 优先排序规则：
      // 1. 中文字幕轨（zh / 中文）优先排在前面
      // 2. 人工精校字幕排在 AI 自动听写/生成前面
      // 3. 其他多语言（English、日本語、Español等）依次排列供用户自主选择
      validTracks.sort((a, b) {
        final aDoc = (a.lanDoc ?? a.title ?? '').toLowerCase();
        final aLan = (a.lan ?? '').toLowerCase();
        final bDoc = (b.lanDoc ?? b.title ?? '').toLowerCase();
        final bLan = (b.lan ?? '').toLowerCase();

        final aIsZh = aDoc.contains('中') || aLan.contains('zh') ? 1 : 0;
        final bIsZh = bDoc.contains('中') || bLan.contains('zh') ? 1 : 0;
        if (aIsZh != bIsZh) return bIsZh.compareTo(aIsZh);

        final aAi = a.isAi ? 1 : 0;
        final bAi = b.isAi ? 1 : 0;
        return aAi.compareTo(bAi);
      });

      tracks.assignAll(validTracks);
      _record('native tracks=${tracks.length}');
      unawaited(_updateTranslatedTimeline());

      final pref = preferredSubtitleSource.value;
      if (pref == 'sherpa') {
        // 保持用户偏好的 Sherpa 本地离线识别
        selectedTrack.value = realtimeLocalTrack;
        useLocalAsr.value = true;
        _videoTimeline = null;
        _activeTrack = null;
        _resetAsr('keep preferred sherpa');
        _updateAfterTrackLoad();
      } else if (pref == 'qwen') {
        // 保持用户偏好的 Qwen ASR 云端在线识别
        selectedTrack.value = realtimeCloudTrack;
        useLocalAsr.value = false;
        _videoTimeline = null;
        _activeTrack = null;
        _resetAsr('keep preferred qwen');
        _updateAfterTrackLoad();
      } else {
        // 用户偏好官方字幕优先
        if (tracks.isNotEmpty) {
          selectedTrack.value = tracks.first.id!;
          _resetAsr('found native tracks');
          unawaited(_selectTimeline(userSelected: false));
        } else {
          // 当前视频无官方字幕：自动无缝回退到实时语音识别（离线或云端）
          selectedTrack.value =
              useLocalAsr.value ? realtimeLocalTrack : realtimeCloudTrack;
          _videoTimeline = null;
          _activeTrack = null;
          _resetAsr('no native tracks, fallback to realtime asr');
          _updateAfterTrackLoad();
        }
      }
    } catch (e) {
      if (_trackRequest == request) {
        _trackRequest = null;
        if (tracks.isEmpty) {
          selectedTrack.value =
              useLocalAsr.value ? realtimeLocalTrack : realtimeCloudTrack;
          _resetAsr('failed loading native tracks, fallback to realtime asr');
          _updateAfterTrackLoad();
        }
      }
    }
  }

  void selectTrack(int id) {
    selectedTrack.value = id;
    _cancelTranslations();
    _translations.clear();
    _translationFailures.clear();
    _translatedTimeline = null;
    _translatedTrack = null;
    _translatedTimelineTrackId = null;

    if (id == realtimeTrack || id == realtimeLocalTrack) {
      preferredSubtitleSource.value = 'sherpa';
      useLocalAsr.value = true;
      _preferences?.preferredSubtitleSource.value = 'sherpa';
      _preferences?.useLocalAsr.value = true;
      _preferences?.save();
      _trackSelection = null;
      _videoTimeline = null;
      _record('selected realtime local');
      _resetAsr('selected realtime local track');
      _nextAsrStartMs = null;
      asrError.value = '';
      updatePlayback();
    } else if (id == realtimeCloudTrack) {
      preferredSubtitleSource.value = 'qwen';
      useLocalAsr.value = false;
      _preferences?.preferredSubtitleSource.value = 'qwen';
      _preferences?.useLocalAsr.value = false;
      _preferences?.save();
      _trackSelection = null;
      _videoTimeline = null;
      _record('selected realtime cloud');
      _resetAsr('selected realtime cloud track');
      _nextAsrStartMs = null;
      asrError.value = '';
      updatePlayback();
    } else {
      preferredSubtitleSource.value = 'official';
      _preferences?.preferredSubtitleSource.value = 'official';
      _preferences?.save();
      _resetAsr('selected native track');
      _trackWaitUntilMs =
          _elapsed.elapsedMilliseconds + _trackWait.inMilliseconds;
      if (id > 0) {
        unawaited(_selectTimeline(userSelected: true));
      } else {
        _videoTimeline = null;
        _activeTrack = null;
        status.value = '当前视频无官方自带字幕轨';
      }
    }
    unawaited(_updateTranslatedTimeline());
    setOriginal(true);
  }

  Future<void> _selectTimeline({required bool userSelected}) async {
    final request = _trackSelection = Object();
    final currentBvid = _video?.bvid;
    final currentCid = _video?.cid;
    final selected = selectedTrack.value;
    final available = tracks
        .where((track) => selected == automaticTrack || track.id == selected);
    final manual = available.where((track) => !track.isAi);
    final ai = available.where((track) => track.isAi);
    CaptionTimeline? timeline;
    for (final track in [...manual, ...ai]) {
      final body = await VideoHttp.getSubtitleBody(track);
      if (_trackSelection != request) return;
      if (_video?.bvid != currentBvid || _video?.cid != currentCid) return;
      if (body == null) continue;
      final candidate = CaptionTimeline.fromVideo(body);
      if (candidate.isEmpty) continue;
      timeline = candidate;
      _activeTrack = track;
      break;
    }
    if (_trackSelection != request) return;
    if (_video?.bvid != currentBvid || _video?.cid != currentCid) return;
    _trackSelection = null;
    if (timeline != null) {
      _videoTimeline = timeline;
      _resetAsr('native track ready');
      asrError.value = '';
      _record('native track active');
      _cancelTranslations();
      _translations.clear();
      _translationFailures.clear();
      _pronunciations.clear();
      unawaited(_updateTranslatedTimeline());
      _render(_clock.at(_elapsed.elapsedMilliseconds));
    } else {
      // 无论用户自选还是自动模式，只要没有找到有效字幕，必须清空，绝不残留老视频的字幕！
      _videoTimeline = null;
      _activeTrack = null;
      _translatedTimeline = null;
      _translatedTrack = null;
      _translatedTimelineTrackId = null;
      _translations.clear();
      _translationFailures.clear();
      selectedTrack.value = 0;
      _record('native track unavailable');
      _resetAsr('native track unavailable');
      _cancelTranslations();
      _pronunciations.clear();
      status.value = '当前视频无官方自带字幕轨';
    }
    _updateAfterTrackLoad();
  }

  void _updateAfterTrackLoad() {
    if (_trackRequest == null &&
        _trackSelection == null &&
        status.value == _loadingTracks) {
      status.value = '';
    }
    updatePlayback();
  }

  SubTitlteItemModel? _findMatchingOfficialTrack(String targetLang) {
    final currentId = selectedTrack.value;
    for (final track in tracks) {
      if (track.id == currentId) continue;
      if (_matchesTargetLanguage(track, targetLang)) {
        return track;
      }
    }
    return null;
  }

  bool _matchesTargetLanguage(SubTitlteItemModel track, String targetLang) {
    final lan = (track.lan ?? '').toLowerCase();
    final doc = (track.lanDoc ?? track.title ?? '').toLowerCase();
    final target = targetLang.toLowerCase().replaceAll('-', '');

    if (lan.isNotEmpty) {
      if (lan == target) return true;
      if (target.length >= 2 && lan.startsWith(target.substring(0, 2))) return true;
      if (lan.length >= 2 && target.startsWith(lan.substring(0, 2))) return true;
    }

    if (target.startsWith('zhcn') || target == 'zh') {
      if (doc.contains('简') || doc.contains('大陆') || doc.contains('中文')) return true;
    } else if (target.startsWith('zhtw') || target.startsWith('zhhk')) {
      if (doc.contains('繁') || doc.contains('港') || doc.contains('台')) return true;
    } else if (target.startsWith('en')) {
      if (doc.contains('英') || doc.contains('english')) return true;
    } else if (target.startsWith('ja')) {
      if (doc.contains('日') || doc.contains('japan') || doc.contains('日本')) return true;
    } else if (target.startsWith('ko')) {
      if (doc.contains('韩') || doc.contains('korean') || doc.contains('朝鲜')) return true;
    } else if (target.startsWith('fr')) {
      if (doc.contains('法') || doc.contains('french')) return true;
    } else if (target.startsWith('de')) {
      if (doc.contains('德') || doc.contains('german')) return true;
    } else if (target.startsWith('es')) {
      if (doc.contains('西') || doc.contains('spanish')) return true;
    } else if (target.startsWith('ru')) {
      if (doc.contains('俄') || doc.contains('russian')) return true;
    } else if (target.startsWith('vi')) {
      if (doc.contains('越') || doc.contains('vietnamese')) return true;
    } else if (target.startsWith('th')) {
      if (doc.contains('泰') || doc.contains('thai')) return true;
    }
    return false;
  }

  Future<void> _updateTranslatedTimeline() async {
    final bool isUsingAsr = selectedTrack.value == realtimeLocalTrack ||
        selectedTrack.value == realtimeCloudTrack ||
        selectedTrack.value == realtimeTrack ||
        selectedTrack.value <= 0;
    if (!showTranslation.value || isUsingAsr) {
      _translatedTimeline = null;
      _translatedTrack = null;
      _translatedTimelineTrackId = null;
      return;
    }
    final lang = targetLanguage.value;
    final matchedTrack = _findMatchingOfficialTrack(lang);
    if (matchedTrack == null) {
      _translatedTimeline = null;
      _translatedTrack = null;
      _translatedTimelineTrackId = null;
      return;
    }
    _translatedTrack = matchedTrack;
    if (_translatedTimeline != null && _translatedTimelineTrackId == matchedTrack.id) {
      return;
    }
    if (_videoTimeline == null) return;
    final currentBvid = _video?.bvid;
    final currentCid = _video?.cid;
    try {
      final body = await VideoHttp.getSubtitleBody(matchedTrack);
      if (_video?.bvid != currentBvid || _video?.cid != currentCid) return;
      if (body != null) {
        final timeline = CaptionTimeline.fromVideo(body);
        if (timeline.isNotEmpty) {
          _translatedTimeline = timeline;
          _translatedTimelineTrackId = matchedTrack.id;
          _record('official translated track active: ${matchedTrack.lanDoc ?? matchedTrack.title}');
          _render(_clock.at(_elapsed.elapsedMilliseconds));
        }
      }
    } catch (_) {}
  }

  void attach(Player player, DataSource source, {required Duration start, String? title}) {
    if (title != null && title.isNotEmpty) videoTitle = title;
    _player = player;
    _source = source;
    if (player.state.position == Duration.zero) {
      _loadingPositionMs = start.inMilliseconds;
    }
    updatePlayback();
  }

  void detach() {
    _resumeSeekBufferingPlayback();
    _attachment++;
    _player = null;
    _source = null;
    _seeksInProgress = 0;
    _loadingPositionMs = null;
    _lastPositionMs = null;
    _stopTicker();
    _resetAsr('player detached');
    _cancelTranslations();
    _translations.clear();
    _pronunciations.clear();
    _pronunciationRequests.clear();
    // 彻底重置官方字幕轨与视频信息，严防切视频后串入上一个视频的官方字幕！
    _videoTimeline = null;
    _activeTrack = null;
    _translatedTimeline = null;
    _translatedTrack = null;
    _video = null;
    _trackRequest = null;
    _trackSelection = null;
    tracks.clear();
    selectedTrack.value = automaticTrack;
    _asrCues.clear();
    _asrTimeline = CaptionTimeline(_emptyCues);
    frame.value = null;
    asrError.value = '';
    status.value = '';
  }

  void setOriginal(bool value) {
    showOriginal.value = value;
    _preferences?.showOriginal.value = value;
    _preferences?.save();
    if (!value) {
      _cancelTranslations();
      _pronunciations.clear();
      _pronunciationRequests.clear();
    } else {
      // 用户主动开启字幕时，重置所有错误与阻塞标记，确保能立即恢复
      asrError.value = '';
      _reachedEnd = false;
      _seeksInProgress = 0;
    }
    _updateSwitches();
  }

  void setTranslation(bool value) {
    if (value && !enabled) showOriginal.value = true;
    showTranslation.value = value;
    _preferences?.showTranslation.value = value;
    _preferences?.save();
    if (!value) {
      _cancelTranslations();
      _translatedTimeline = null;
      _translatedTrack = null;
    } else {
      unawaited(_updateTranslatedTimeline());
    }
    _updateSwitches();
  }

  void setPronunciation(bool value) {
    if (value && !enabled) showOriginal.value = true;
    showPronunciation.value = value;
    _preferences?.showPronunciation.value = value;
    _preferences?.save();
    if (!value) {
      _pronunciations.clear();
      _pronunciationRequests.clear();
    }
    _updateSwitches();
  }

  void setSheetPronunciation(bool value) {
    sheetShowPronunciation.value = value;
    _preferences?.setSheetPronunciation(value);
  }

  void setChinesePhonetic(String mode) {
    chinesePhonetic.value = mode;
    _preferences?.chinesePhonetic.value = mode;
    _preferences?.save();
    _pronunciations.clear();
    updatePlayback();
  }

  void setJapanesePhonetic(String mode) {
    japanesePhonetic.value = mode;
    _preferences?.japanesePhonetic.value = mode;
    _preferences?.save();
    _pronunciations.clear();
    updatePlayback();
  }

  void setLocalAsr(bool value) {
    useLocalAsr.value = value;
    final mode = value ? 'sherpa' : 'qwen';
    preferredSubtitleSource.value = mode;
    _preferences?.useLocalAsr.value = value;
    _preferences?.preferredSubtitleSource.value = mode;
    _preferences?.save();
    // 立即终止旧的识别会话，清除时钟和队列
    _resetAsr('switch asr engine to ${value ? "local" : "cloud"}');
    _cancelTranslations();
    _nextAsrStartMs = null;
    asrError.value = '';
    // 如果当前选中的是原生字幕轨，切换引擎时自动激活实时识别轨
    _videoTimeline = null;
    selectedTrack.value = value ? realtimeLocalTrack : realtimeCloudTrack;
    setOriginal(true);
    updatePlayback();
  }

  void setLocalAsrModel(String modelId) {
    localAsrModel.value = modelId;
    _preferences?.localAsrModel.value = modelId;
    _preferences?.save();
    LocalAsrModelManager.shared.currentModelId.value = modelId;
    if (useLocalAsr.value) {
      _resetAsr('switch local asr model to $modelId');
      _cancelTranslations();
      _nextAsrStartMs = null;
      asrError.value = '';
      updatePlayback();
    }
  }

  void setOnlineAsrEngine(String engine) {
    onlineAsrEngine.value = engine;
    _preferences?.setOnlineAsrEngine(engine);
    if (!useLocalAsr.value) {
      _resetAsr('switch online asr engine to $engine');
      _cancelTranslations();
      _nextAsrStartMs = null;
      asrError.value = '';
      updatePlayback();
    }
  }

  void setOnlineAsrLanguage(String lang) {
    onlineAsrLanguage.value = lang;
    _preferences?.setOnlineAsrLanguage(lang);
    if (!useLocalAsr.value) {
      _resetAsr('switch online asr language to $lang');
      _cancelTranslations();
      _nextAsrStartMs = null;
      asrError.value = '';
      updatePlayback();
    }
  }

  void setDoubaoAuthMode(String mode) {
    doubaoAuthMode.value = mode;
    _preferences?.setDoubaoAuthMode(mode);
    if (!useLocalAsr.value && onlineAsrEngine.value == 'doubao') {
      _resetAsr('switch doubao auth mode to $mode');
      asrError.value = '';
      updatePlayback();
    }
  }

  void setDoubaoApiKey(String key) {
    doubaoApiKey.value = key;
    _preferences?.setDoubaoApiKey(key);
    if (!useLocalAsr.value && onlineAsrEngine.value == 'doubao') {
      _resetAsr('update doubao api key');
      asrError.value = '';
      updatePlayback();
    }
  }

  void setDoubaoAppId(String id) {
    doubaoAppId.value = id;
    _preferences?.setDoubaoAppId(id);
    if (!useLocalAsr.value && onlineAsrEngine.value == 'doubao') {
      _resetAsr('update doubao app id');
      asrError.value = '';
      updatePlayback();
    }
  }

  void setDoubaoAccessToken(String token) {
    doubaoAccessToken.value = token;
    _preferences?.setDoubaoAccessToken(token);
    if (!useLocalAsr.value && onlineAsrEngine.value == 'doubao') {
      _resetAsr('update doubao access token');
      asrError.value = '';
      updatePlayback();
    }
  }

  void setDeepgramApiKey(String key) {
    deepgramApiKey.value = key;
    _preferences?.setDeepgramApiKey(key);
    if (!useLocalAsr.value && onlineAsrEngine.value == 'deepgram') {
      _resetAsr('update deepgram api key');
      asrError.value = '';
      updatePlayback();
    }
  }

  void setTargetLanguage(String lang) {
    targetLanguage.value = lang;
    _preferences?.targetLanguage.value = lang;
    _preferences?.save();
    _translations.clear();
    _translationFailures.clear();
    _cancelTranslations();
    translationError.value = '';
    unawaited(_updateTranslatedTimeline());
    updatePlayback();
  }

  void setTranslationEngine(String engine) {
    translationEngine.value = engine;
    _preferences?.translationEngine.value = engine;
    _preferences?.save();
    _translations.clear();
    _translationFailures.clear();
    _cancelTranslations();
    translationError.value = '';
    updatePlayback();
  }

  void retry() {
    _cancelAsrRetry();
    _resetAsr('retry requested');
    _reachedEnd = false;
    _seeksInProgress = 0;
    asrError.value = '';
    translationError.value = '';
    _translationFailures.clear();
    _nextAsrStartMs = null;
    unawaited(_updateTranslatedTimeline());
    updatePlayback();
  }

  void _updateSwitches() {
    if (!enabled) {
      _stopTicker();
      _resetAsr('subtitles disabled');
      _cancelTranslations();
      _pronunciations.clear();
      _pronunciationRequests.clear();
      _translatedTimeline = null;
      _translatedTrack = null;
      frame.value = null;
      asrError.value = '';
      status.value = '';
    } else {
      updatePlayback();
    }
  }

  int beginSeek() {
    _seeksInProgress++;
    _stopTicker();
    _resumeSeekBufferingPlayback();
    _resetAsr('seek');
    _cancelTranslations();
    asrError.value = '';
    frame.value = null;
    clearSentenceQueue();
    return _attachment;
  }

  void endSeek(int attachment, Duration? position) {
    _seeksInProgress = math.max(0, _seeksInProgress - 1);
    if (attachment != _attachment || _seeksInProgress > 0) return;
    _reachedEnd = false; // 用户拖拽进度，重置播放结束状态
    _nextAsrStartMs = null; // 重置下一段识别起始，允许立即重新对齐当前播放进度
    final targetMs =
        position?.inMilliseconds ?? _player?.state.position.inMilliseconds ?? 0;
    _loadingPositionMs = targetMs;
    _lastPositionMs = null;

    // 拖动到未识别的部分也是先缓冲暂停一下
    if (_videoTimeline == null && enabled) {
      final hasCaptions = _asrTimeline.at(targetMs) != null ||
          _asrTimeline.upcoming(targetMs, targetMs + 4000).isNotEmpty;
      final player = _player;
      if (!hasCaptions && player != null && player.state.playing) {
        _seekBufferingPaused = true;
        player.pause();
        status.value = '正在预缓冲识别字幕…';
        _seekBufferingTimer?.cancel();
        _seekBufferingTimer = Timer(const Duration(milliseconds: 1500), () {
          _seekBufferingTimer = null;
          _resumeSeekBufferingPlayback();
        });
      }
    }

    updatePlayback();
  }

  void updatePlayback({Duration? position}) {
    final player = _player;
    if (!enabled || _seeksInProgress > 0 || player == null) return;
    final state = player.state;
    final nowMs = _elapsed.elapsedMilliseconds;
    if (position != null) _loadingPositionMs = null;
    final positionMs = _loadingPositionMs ?? state.position.inMilliseconds;
    final lastPositionMs = _lastPositionMs;
    if (lastPositionMs != null) {
      final jump = positionMs - lastPositionMs;
      // 容忍轻微的时钟回退或采样抖动（>= 1500ms 判定为真实 seek），避免频繁误触发 resetAsr
      if (jump < -1500 ||
          jump > (nowMs - _lastPositionSampleMs) * state.rate + 3000) {
        _resetAsr('position sample jumped from $lastPositionMs to $positionMs');
        _cancelTranslations();
      }
    }
    _lastPositionMs = positionMs;
    _lastPositionSampleMs = nowMs;

    final moving = state.playing && !state.buffering && !state.completed;
    _clock.update(positionMs, nowMs, moving: moving, rate: state.rate);
    if (moving) {
      _ticker ??= Timer.periodic(
        const Duration(milliseconds: 33),
        (_) => _render(_clock.at(_elapsed.elapsedMilliseconds)),
      );
    } else {
      _stopTicker();
    }
    _render(positionMs);
    if (!state.completed) _startAsrIfNeeded(player, positionMs);
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _render(int positionMs) {
    final player = _player;
    if (!enabled || player == null || _seeksInProgress > 0) return;
    final int delay = captionDelayMs.value.toInt();
    final int effectiveMs = positionMs - delay < 0 ? 0 : positionMs - delay;

    // 当使用 ASR 语音识别时，字幕源是动态音频识别流，绝不能混入官方字幕轨的时间轴；
    // 只有当且仅当使用官方字幕轨，且存在匹配语言的官方双语轨时才使用 officialTranslation
    final bool isUsingAsr = selectedTrack.value == realtimeLocalTrack ||
        selectedTrack.value == realtimeCloudTrack ||
        selectedTrack.value == realtimeTrack ||
        _videoTimeline == null;
    // ASR 批量结果即使已经晚到，也要逐段展示，不能直接跳到最后一段。
    // 官方字幕轨必须严格按时间轴，不能提前/滞留。
    final cue = isUsingAsr
        ? _asrDelivery.take(_timeline, positionMs: effectiveMs,
            nowMs: _elapsed.elapsedMilliseconds, paused: !player.state.playing)
        : _timeline.at(effectiveMs);
    final lang = targetLanguage.value;

    final officialTranslation = (!isUsingAsr && _translatedTimeline != null)
        ? _translatedTimeline!.at(effectiveMs)?.text
        : null;
    final translated = showTranslation.value
        ? (officialTranslation ?? _translations['$lang:${cue?.text}'])
        : null;
    final jpMode = japanesePhonetic.value;
    final cnMode = chinesePhonetic.value;
    final contextLang = currentLanguageContext;
    final cueText = cue?.text ?? '';
    final bool cueHasKana = RegExp(r'[\u3040-\u309F\u30A0-\u30FF]').hasMatch(cueText);
    final bool cueHasHangul = RegExp(r'[\uAC00-\uD7AF]').hasMatch(cueText);
    final bool cueIsYue = isCantoneseTrack ||
        cnMode == 'cantonese' ||
        contextLang == 'yue' ||
        CaptionPronunciation.isCantoneseText(cueText);

    String? cueLang;
    if (contextLang == 'ja' || cueHasKana || isJapaneseTrack) {
      cueLang = 'ja';
    } else if (contextLang == 'ko' || cueHasHangul) {
      cueLang = 'ko';
    } else if (cueIsYue) {
      cueLang = 'yue';
    } else if (contextLang != null) {
      cueLang = contextLang;
    }

    final pronunciationKey = '$cueLang:$cnMode:$jpMode:$cueIsYue:$cueText';
    var pronunciation = showPronunciation.value
        ? _pronunciations[pronunciationKey]
        : null;

    // 关键优化：若当前帧注音不在缓存中且开启了注音，立即进行 0ms 纯本地同步解析，同帧直接上屏！
    if (showPronunciation.value &&
        (pronunciation == null || pronunciation.isEmpty) &&
        cue != null &&
        cue.text.trim().isNotEmpty) {
      final offline = CaptionPronunciation.shared.getOfflinePronunciation(
        cue.text,
        japaneseMode: jpMode,
        chineseMode: cnMode,
        isCantoneseContext: cueIsYue,
        sourceLang: cueLang,
      );
      if (offline != null && offline.isNotEmpty) {
        _pronunciations[pronunciationKey] = offline;
        if (_pronunciations.length > 512) _pronunciations.remove(_pronunciations.keys.first);
        pronunciation = offline;
      }
    }

    // 关键优化：若当前帧翻译尚未就绪且开启了翻译，仅在已成句/确认分段 (canTranslate) 时发起同帧翻译
    // 绝不对正在说话中的不稳定未完结预览 (preview) 频繁触发 HTTP 翻译，杜绝每秒十几次请求导致的拥堵与字幕回跳闪烁！
    if (showTranslation.value &&
        translated == null &&
        cue != null &&
        cue.canTranslate &&
        cue.text.trim().isNotEmpty) {
      final cacheKey = '$lang:${cue.text}';
      if (_translationRequests.length < 2 &&
          !_translationRequests.containsKey(cacheKey) &&
          !_translationFailures.contains(cacheKey)) {
        final token = _translationRequests[cacheKey] = CancelToken();
        unawaited(_translate(cue.text, token, sourceLang: cueLang));
      }
    }

    // 卡顿优化：CaptionFrame 是 record，GetX 按值比较是否通知。
    // 原 highlighted 字段逐帧随播放位置变化，但 UI 从未消费（全工程无引用），
    // 导致每 33ms 都被判定为"值变了"→ 整个字幕 Obx 重建。移除后，
    // 字幕文本/翻译/注音不变时 frame 值相等，不会触发无意义的 rebuild。
    final nextFrame = cue == null
        ? null
        : (
            cue: cue,
            translation: translated ?? '',
            pronunciation: pronunciation ?? '',
          );
    if (nextFrame != frame.value) {
      frame.value = nextFrame;
    }

    if (cue != null) {
      updateSentenceQueue(cue, isUsingAsr: isUsingAsr,
          translated: translated, pronunciation: pronunciation);
    }
    // 注意：静音停顿期间，sentenceQueue 永久保留最后一句话常驻在屏幕上，绝不清空闪退！

    _prefetchTranslations(effectiveMs);
    _prefetchPronunciations(effectiveMs);

    // 会话结束后自动续跑：当 _session 结束且未到视频结尾时，在播放推进到续读阈值时立刻自动唤醒新会话
    if (_session == null && !_reachedEnd && !player.state.completed) {
      _startAsrIfNeeded(player, positionMs);
    }
  }

  @visibleForTesting
  void updateSentenceQueue(CaptionCue cue, {required bool isUsingAsr,
      String? translated, String? pronunciation}) {
    // 维护多行字幕队列（智能长句聚合 + 逗号不分行 + 常驻显示）
    if (cue.text.trim().isNotEmpty) {
      final cueText = cue.text.trim();
      final cueId = '${cue.startMs}_${cue.endMs}';
      final sameAudioSegment = _lastQueuedCue?.startMs == cue.startMs;
      final canRevise = !isUsingAsr;

      if (sentenceQueue.isEmpty) {
        sentenceQueue.add(CaptionSentenceItem(
          id: cueId,
          original: cueText,
          translation: translated ?? '',
          pronunciation: pronunciation ?? '',
          isLatest: true,
          isFinal: isCompleteSentence(cueText),
        ));
      } else {
        final last = sentenceQueue.last;

        // 二遍识别掐头校正：定稿是预览掐掉开头的结果，必须原地替换而非新增一行。
        // 但队尾已经是"完整句"时禁止掐头——后到的更短版本只可能是 ASR 二次识别
        // 的尾部碎片，拿它覆盖会把已缓存句子的开头删掉（用户反馈的漏词）。
        final bool isTrimCorrection =
            canRevise && !last.isFinal && _isTrimCorrection(last.original, cueText);
        // ASR 幻觉近重复：同一段话被反复识别成略有差异的几版（截图中三行灰字）。
        // 必须先于普通合并处理，否则 mergeCaptionTexts 会把两版首尾拼成更长的重复串。
        final bool isNearDuplicate = canRevise && !isTrimCorrection &&
            _isNearDuplicateCaption(last.original, cueText);

        if (isNearDuplicate) {
          // 同一段话只保留最完整/最确定的一版：既不删掉已确认句的字，
          // 也不再把重复版本当作新句入队。若新版本更短只是预览，直接忽略。
          final bool cueIsFinal = _isSentenceTerminated(cueText);
          // 只有"更完整"的版本才能升级队尾，尾部碎片一律拒绝覆盖。
          final bool incomingBetter = shouldReplaceByMoreComplete(
            last.original,
            last.isFinal,
            cueText,
            cueIsFinal,
          );
          if (incomingBetter) {
            final candidate = last.copyWith(
              id: cueId,
              original: cueText,
              translation: (translated != null && translated.isNotEmpty)
                  ? translated
                  : last.translation,
              pronunciation: (pronunciation != null && pronunciation.isNotEmpty)
                  ? pronunciation
                  : last.pronunciation,
              isLatest: true,
              isFinal: isCompleteSentence(cueText),
            );
            if (!candidate.sameContentAs(last)) {
              sentenceQueue[sentenceQueue.length - 1] = candidate;
            }
          }
        } else {
          // 缓存队列按"完整句"聚合：只看句末标点，不受 display cue 的逗号切分/长度上限影响。
          // 上一句没到句末标点 → 当前 cue 一定是它的续段，直接追加合并；
          // 上一句已到句末标点 → 当前 cue 是新句，另起一行。
          final bool lastComplete = isCompleteSentence(last.original);
          final bool shouldKeep = !lastComplete;

          final cleanLast = last.original.replaceAll(RegExp(r'[，。！？,.!?、；;\s]'), '');
          final cleanCue = cueText.replaceAll(RegExp(r'[，。！？,.!?、；;\s]'), '');
          final bool isOverlap = canRevise && cleanLast.isNotEmpty &&
              cleanCue.isNotEmpty &&
              (cleanCue.startsWith(cleanLast) || cleanLast.startsWith(cleanCue));

          // 同一句判定：
          // 1. 同一 cueId 增量；
          // 2. 文本前缀包含关系；
          // 3. 上一句未到句末标点（逗号只是句内停顿，必须继续拼回完整句）；
          // 4. 新旧文本存在无标点前缀重合 (消除云端分段修正导致的重复入队)
          // 5. 二遍识别的掐头校正（定稿替换预览，不另起一行）
          final bool isSameSentence = isTrimCorrection ||
              (isUsingAsr && sameAudioSegment) ||
              last.id == cueId ||
              (canRevise && !lastComplete &&
                  (cueText.startsWith(last.original) ||
                      last.original.startsWith(cueText))) ||
              isOverlap ||
              shouldKeep;

          if (isSameSentence) {
            // 掐头校正时直接用定稿文本替换，不能再走 mergeCaptionTexts：
            // 后者遇到 “预览以定稿结尾” 会保留更长的预览，导致定稿无法覆盖、两行重复。
            final mergedOriginal = isUsingAsr && sameAudioSegment
                ? '${last.original.substring(0, last.contextRanges.last.start)}$cueText'
                : isTrimCorrection
                ? cueText
                : mergeCaptionTexts(
                    last.original,
                    cueText,
                    // 官方字幕逐条追加时，在汉字之间插空格，避免黏在一起难读；
                    // ASR 流保持原样（其空格由停顿/英文逻辑处理，避免多余空格）。
                    cjkSpace: !isUsingAsr,
                    deduplicate: canRevise,
                  );

            final candidate = last.copyWith(
              id: cueId, // 必须更新 ID，杜绝旧 ID 永远触发差异追加
              original: mergedOriginal,
              contextRanges: isUsingAsr && sameAudioSegment
                  ? [
                      ...last.contextRanges.take(last.contextRanges.length - 1),
                      (start: last.contextRanges.last.start, end: mergedOriginal.length),
                    ]
                  : mergeCaptionContextRanges(
                previous: last.original,
                ranges: last.contextRanges,
                incoming: cueText,
                merged: mergedOriginal,
              ),
              translation: (translated != null && translated.isNotEmpty)
                  ? translated
                  : last.translation,
              pronunciation: (pronunciation != null && pronunciation.isNotEmpty)
                  ? pronunciation
                  : last.pronunciation,
              isLatest: true,
              isFinal: isCompleteSentence(mergedOriginal),
            );
            // 卡顿优化：同一句在逐帧推进时内容往往完全没变。
            // 若内容相同就跳过替换，避免 RxList 每 33ms 通知导致字幕区重建。
            if (!candidate.sameContentAs(last)) {
              sentenceQueue[sentenceQueue.length - 1] = candidate;
            }
          } else {
            // 上一句已真正完结（遇到句号/问号/感叹号或已达到单句长度）：开启下一句入队！
            // 不再对下一句做“掐头剥离”：用户明确宁可少量重复也不要删字、破坏上下文连贯。
            sentenceQueue[sentenceQueue.length - 1] = last.copyWith(
              isLatest: false,
              isFinal: true,
            );
            sentenceQueue.add(CaptionSentenceItem(
              id: cueId,
              original: cueText,
              translation: translated ?? '',
              pronunciation: pronunciation ?? '',
            isLatest: true,
            isFinal: isCompleteSentence(cueText),
          ));
          _pruneSentenceQueue();
          }
        }
      }
    }
    _lastQueuedCue = cue;
  }

  void _startAsrIfNeeded(Player player, int positionMs) {
    if (!enabled) return;
    // 如果当前正在播放官方字幕（selectedTrack > 0 且 _videoTimeline != null），或用户主动关闭了字幕(0)，不需要 ASR
    // 关键防御：若存在 asrError 且没有在重试，必须等待用户主动重试或切换，严禁在每帧 33ms 疯狂死循环重试打崩应用！
    if ((selectedTrack.value > 0 && _videoTimeline != null) ||
        selectedTrack.value == 0 ||
        _session != null ||
        _asrRetryTimer != null ||
        _reachedEnd ||
        asrError.value.isNotEmpty) {
      return;
    }
    if (_asrRetryCount > 0 && !player.state.playing) {
      status.value = '恢复播放后自动重连 ASR';
      return;
    }
    // 只有在准备选用官方字幕时才需要等待 _trackWaitUntilMs，若当前已定位到 ASR 轨则立即启动
    if (selectedTrack.value > 0 &&
        (_trackRequest != null || _trackSelection != null) &&
        _elapsed.elapsedMilliseconds < _trackWaitUntilMs) {
      status.value = _loadingTracks;
      return;
    }
    if (!useLocalAsr.value && !IeeioLogin.supported) {
      status.value = '没有可用的视频自带字幕';
      return;
    }
    final next = _nextAsrStartMs;
    if (next != null) {
      // 若用户倒退了播放进度，旧的 nextAsrStartMs 已超前失效，重置它以立即在当前位置启动
      if (positionMs < next - 2000) {
        _nextAsrStartMs = null;
      } else if (next - positionMs > _leadMs ~/ 2) {
        status.value = '';
        return;
      }
    }
    final source = _source;
    if (source == null) return;
    final audio = source.audioSource;
    final uri = audio != null && audio.isNotEmpty
        ? audio
        : source.videoSource ?? source.file?.path;
    if (uri == null || uri.isEmpty) {
      asrError.value = '当前视频没有可识别的音轨';
      return;
    }
    final useLocal = useLocalAsr.value && LocalAsrModelManager.isSupported;
    final engine = onlineAsrEngine.value;
    final stream = useLocal
        ? LocalAsrStream()
        : OnlineAsrStreamFactory.createStream(
            engine: engine,
            doubaoAuthMode: doubaoAuthMode.value,
            doubaoApiKey: doubaoApiKey.value,
            doubaoAppId: doubaoAppId.value,
            doubaoAccessToken: doubaoAccessToken.value,
            deepgramApiKey: deepgramApiKey.value,
            language: effectiveOnlineAsrLanguage,
          );
    final session = _session = _CaptionSession(
      ++_sessionSequence,
      stream: stream,
      isLocal: useLocal,
    );
    _record(
        'connect pos_ms=$positionMs source=${uri == audio ? 'audio' : 'media'} local=$useLocal',
        session);
    final previous = _previousSession;
    _previousSession = _run(session, previous, player, uri, source.httpHeaders);
  }

  Future<void> _run(
    _CaptionSession session,
    Future<void> previous,
    Player player,
    String source,
    Map<String, String>? headers,
  ) async {
    PlayerPcm? pcm;
    try {
      try {
        await previous.timeout(const Duration(seconds: 2), onTimeout: () {});
      } catch (_) {}
      if (_session != session) return;
      final connectLang = session.isLocal
          ? asrLanguage
          : ((session.stream is AsrStream)
              ? asrLanguage
              : effectiveOnlineAsrLanguage);
      await session.stream.connect(
        ieeioAsrEndpoint,
        language: connectLang,
        ieeioLoginToken: ({rejectedToken}) async {
          if (_session == session) {
            status.value = session.stream is AsrStream
                ? '正在后台登录 QwenASR…'
                : '正在连接云端识别服务…';
            _record('login refresh=${rejectedToken != null}', session);
          }
          final token =
              await IeeioLogin.shared.loadToken(rejectedToken: rejectedToken);
          if (_session == session) status.value = '正在连接识别服务…';
          return token;
        },
        onResult: (result) => _receive(session, result),
        onError: (error) => _fail(session, error),
      );
      if (_session != session) return;
      final state = player.state;
      if (state.completed) {
        status.value = '';
        return;
      }
      final timing = session.timing = AsrCaptionTiming.fromPlayback(
        _clock.at(_elapsed.elapsedMilliseconds),
        resumeFromMs: _nextAsrStartMs,
      );
      final startMs = timing.originMs;
      final durationMs = state.duration.inMilliseconds;
      if (durationMs > 0 && startMs >= durationMs) {
        _reachedEnd = true;
        status.value = '';
        return;
      }
      status.value = _readingAudio;
      final endMs = durationMs > startMs
          ? math.min(
              durationMs, startMs + const Duration(minutes: 15).inMilliseconds)
          : startMs + const Duration(minutes: 15).inMilliseconds;
      pcm = session.pcm = PlayerPcm(
        source: source,
        headers: headers,
        start: Duration(milliseconds: startMs),
        end: Duration(milliseconds: endMs),
      );
      _record(
          'ready start_ms=$startMs end_ms=$endMs '
          'chunk_ms=${session.stream.decodeChunkMs}',
          session);
      await pcm.prepare().timeout(const Duration(seconds: 15));
      if (_session != session) return;

      const bytesPerMs = PlayerPcm.bytesPerSecond ~/ 1000;
      // 预先缓冲音频流 = 建立"播放位置 vs 预读位置"的位置差。
      // 视频音轨可提前从文件解码：本地冲 16 秒；云端冲 6 秒（足以覆盖引擎延迟，
      // 又不至于像灌 12 秒那样让云端队列严重拥塞）。这个提前量让引擎处理的音频
      // 跑在画面前面，返回字幕的时间戳落在未来的播放时刻 → 音文同步。
      final burstBytes = math.max(
        PlayerPcm.frameSize,
        session.isLocal ? 16000 * bytesPerMs : cloudReadAheadMs * bytesPerMs,
      );
      var lastRead = _elapsed.elapsedMilliseconds;
      var lastBudgetUpdate = lastRead;
      var sendBudget = burstBytes;
      var nextSample = lastRead;
      int? missingFrameSince;

      while (_session == session) {
        final now = _elapsed.elapsedMilliseconds;
        final positionMs = _clock.at(now);
        if (now >= nextSample) {
          _record(_sample(session, positionMs), session);
          nextSample = now + 1500;
        }
        // 读取上限跟随"播放位置 + 预读位置差"，与初始 burst 保持一致：
        // 只有允许读到那么远，发送预算才喂得饱，预读提前量才真正建立得起来。
        final leadMs = session.isLocal ? _leadMs : cloudReadAheadMs;
        final readThrough = asrReadThroughMs(
          playbackMs: positionMs,
          originMs: startMs,
          readAheadMs: leadMs,
        );
        final limit =
            math.min(readThrough * bytesPerMs, session.stream.maxAudioBytes);
        // 本地识别全速 (8.0)。云端改用背压闭环：根据引擎待处理积压与就绪领先量
        // 动态调速，杜绝固定速率下积压随时间累积导致的"越看越延迟"。
        final double sendRate;
        if (session.isLocal) {
          sendRate = 8.0;
        } else {
          final processed = session.stream.processedMilliseconds;
          // 部分服务只在有人声时回报进度，静音不属于待识别积压。
          final sentMs = session.stream.sentMilliseconds;
          final pendingMs = timing.speech.activeDuration(
            startMs + (processed ?? 0),
            startMs + sentMs,
          );
          if (session.cloudFlow.needsReconnect(
            nowMs: now,
            processedMs: processed ?? 0,
            pendingSpeechMs: pendingMs,
          )) {
            throw const AsrStreamException('云端识别长时间无进展，正在重新对齐',
                retryable: true);
          }
          final readyLead = captionReadyLeadMs(
            originMs: startMs,
            engineProcessedMs: processed ?? sentMs,
            playbackMs: positionMs,
          );
          sendRate = cloudAdaptiveSendRate(
            baseRate: player.state.rate * 1.15,
            pendingMs: pendingMs,
            readyLeadMs: readyLead,
          );
          // 停发时仍更新拥堵状态；静音之后刚开始说话不会因旧时间戳误报。
          final pendingPlayedSpeech = timing.speech.activeDuration(
            startMs + (processed ?? 0),
            math.min(positionMs, startMs + sentMs),
          );
          cloudLagWarning.value = pendingPlayedSpeech > 6000;
          if (cloudLagWarning.value) {
            final sec = (pendingPlayedSpeech / 1000).toStringAsFixed(0);
            status.value = '云端识别拥堵 (待识别语音 ${sec}s)…';
          } else if (status.value.startsWith('云端识别拥堵')) {
            status.value = '';
          }
        }
        final accrued =
            ((now - lastBudgetUpdate) * bytesPerMs * sendRate).round();
        sendBudget = math.min(burstBytes, sendBudget + accrued);
        lastBudgetUpdate = now;
        await pcm.setReading(limit).timeout(const Duration(seconds: 8));
        while (sendBudget >= PlayerPcm.frameSize &&
            _session == session &&
            !session.stream.done) {
          // 背压硬闸门：云端引擎积压超阈值时立即停发（不因 budget 存量继续灌入），
          // 否则积压会继续膨胀、结果越出越晚，正是"渐渐延迟"的成因。
          if (!session.isLocal) {
            final pendingSpeech = timing.speech.activeDuration(
              startMs + (session.stream.processedMilliseconds ?? 0),
              startMs + session.stream.sentMilliseconds,
            );
            if (pendingSpeech > CloudAsrFlow.maxPendingSpeechMs) break;
          }
          final audio = await pcm.readFrame(
            limit,
            finalFrame: pcm.drained || limit == session.stream.maxAudioBytes,
          );
          if (audio == null || _session != session) break;
          // 仅本地离线识别需要音量动态补偿；云端在线 Qwen-ASR 保持原汁原味原生音频，杜绝底噪放大8倍误判语音
          if (session.isLocal) {
            session.leveler.apply(audio);
          }
          timing.speech.add(audio);
          await session.stream.send(audio);
          if (_session != session) return;
          sendBudget -= audio.length;
          lastRead = _elapsed.elapsedMilliseconds;
          missingFrameSince = null;
          if (status.value == _readingAudio &&
              session.stream.sentMilliseconds > 0) {
            status.value = '已发送视频音轨，等待识别结果…';
          }

        }
        if (_session != session) return;
        if (session.stream.done) {
          throw const AsrStreamException('ASR 会话提前结束', retryable: true);
        }

        final exhausted = pcm.atEnd;
        if (exhausted || pcm.bytesRead >= session.stream.maxAudioBytes) {
          if (pcm.bytesRead == 0) {
            throw const FormatException('当前视频没有可识别的音轨');
          }
          _record(
              'drain eof=$exhausted ${_sample(session, positionMs)}',
              session);
          await session.stream.finish();
          if (_session != session) return;
          final last = session.transcript.finish();
          if (last != null) _addCaption(session, last);
          final nextStartMs = startMs + session.stream.sentMilliseconds;
          _nextAsrStartMs = nextStartMs;
          final videoDurationMs = player.state.duration.inMilliseconds;
          final expectedEndMs =
              videoDurationMs > 0 ? math.min(videoDurationMs, endMs) : endMs;
          final endedEarly = nextStartMs + _endToleranceMs < expectedEndMs;
          if (exhausted &&
              videoDurationMs > 0 &&
              endedEarly &&
              !player.state.completed) {
            throw const AsrStreamException('视频音轨提前结束，正在续读', retryable: true);
          }
          status.value = '';
          _reachedEnd = exhausted &&
              (player.state.completed ||
                  (videoDurationMs > 0
                      ? expectedEndMs == videoDurationMs
                      : endedEarly));
          break;
        }

        if (limit - pcm.bytesRead >= PlayerPcm.frameSize) {
          if (pcm.buffering || player.state.buffering || !player.state.playing) {
            missingFrameSince = null;
          } else {
            missingFrameSince ??= now;
            if (now - missingFrameSince >= 15000) {
              throw const AsrStreamException('视频音轨读取停滞', retryable: true);
            }
          }
        } else {
          missingFrameSince = null;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    } on AsrStreamException catch (error) {
      _fail(session, error);
    } on TimeoutException {
      _fail(session, const AsrStreamException('读取视频音轨超时', retryable: true));
    } on PlayerPcmReadException {
      _fail(session, const AsrStreamException('视频音轨解码中断', retryable: true));
    } on FormatException catch (error) {
      _fail(session, AsrStreamException(error.message),
          diagnostic: 'PCM invalid');
    } catch (error) {
      if (_session == session) {
        _record('exception ${error.runtimeType}', session);
      }
      _fail(session, const AsrStreamException('实时字幕启动失败，请重试'));
    } finally {
      session.stream.close();
      try {
        await pcm?.close().timeout(const Duration(seconds: 3));
      } catch (_) {
        // A temporary audio file must not interfere with playback cleanup.
      }
      if (_session == session) {
        _session = null;
        updatePlayback();
      }
    }
  }

  void _receive(_CaptionSession session, Map<String, dynamic> message) {
    if (_session != session || session.timing == null) return;
    session.results++;
    final delta = message['delta'] ?? message['text'];
    if (delta is String && delta.trim().isNotEmpty) session.deltas++;
    final processed = session.stream.processedMilliseconds ??
        (message['audio_ms'] is num ? (message['audio_ms'] as num).toInt() : 0);
    if (processed >= 2500) {
      _asrRetryCount = 0;
    }
    if (processed > session.lastProcessedMs) {
      session.lastProcessedMs = processed;
      if (!session.hasTranscript) status.value = '识别服务已接收音轨，等待语音…';
    }
    for (final caption in session.transcript.accept(message)) {
      session.hasTranscript = true;
      _resumeSeekBufferingPlayback();
      status.value = '';
      _addCaption(session, caption);
    }
  }

  void _addCaption(_CaptionSession session, AsrCaption caption) {
    final timing = session.timing;
    if (timing == null) return;
    final cues = timing.update(
      caption,
      sentMs: session.stream.sentMilliseconds,
      chunkMs: session.stream.decodeChunkMs,
    );
    session.updates++;
    for (final c in cues) {
      if (RegExp(r'[\u3040-\u309F\u30A0-\u30FF]').hasMatch(c.text)) {
        _sessionDetectedLanguage = 'ja';
      } else if (RegExp(r'[\uAC00-\uD7AF]').hasMatch(c.text)) {
        _sessionDetectedLanguage = 'ko';
      } else if (CaptionPronunciation.isCantoneseText(c.text)) {
        _sessionDetectedLanguage = 'yue';
      }
    }
    if (cues.isEmpty) {
      session.emptyUpdates++;
    } else {
      session.lastCue = (startMs: cues.first.startMs, endMs: cues.last.endMs);
    }
    if (caption.isFinal) {
      _asrCues.addAll(cues);
      session.partial = _emptyCues;
    } else {
      session.partial = cues;
    }
    final position = _clock.at(_elapsed.elapsedMilliseconds);
    _asrCues.removeWhere((cue) => cue.endMs < position - 45000);
    _asrTimeline = CaptionTimeline([..._asrCues, ...session.partial]);
    _render(position);
  }

  void _fail(_CaptionSession session, AsrStreamException error,
      {String? diagnostic}) {
    if (_session != session) return;
    _resumeSeekBufferingPlayback();
    final last = session.transcript.finish();
    if (last != null) _addCaption(session, last);
    final timing = session.timing;
    if (timing != null) {
      _nextAsrStartMs = math.max(
        _nextAsrStartMs ?? timing.originMs,
        math.max(
          timing.confirmedEndMs,
          timing.originMs + (session.stream.processedMilliseconds ?? 0),
        ),
      );
    }
    final position = _clock.at(_elapsed.elapsedMilliseconds);
    final detail = diagnostic ?? error.message;
    _record('failure retry=${error.retryable} $detail', session);
    _record(_sample(session, position), session);
    _session = null;
    session.stream.close();
    developer.log(detail, name: 'pilipala.caption');

    if (!error.retryable) {
      // 不可重试原因（如模型未下载、未填 API Key、鉴权失败等）时展示原因，不盲目重试
      status.value = '';
      asrError.value = error.message;
      return;
    }

    if (error.retryable) {
      final seconds = 1 << math.min(_asrRetryCount, 4);
      _asrRetryCount++;
      status.value = '${error.message}，$seconds 秒后重连…';
      _asrRetryTimer = Timer(Duration(seconds: seconds), () {
        _asrRetryTimer = null;
        if (_player?.state.completed == true) {
          status.value = '';
          return;
        }
        updatePlayback();
      });
      return;
    }
    asrError.value = error.message;
    status.value = '';
  }

  void _cancelAsrRetry() {
    _asrRetryTimer?.cancel();
    _asrRetryTimer = null;
    _asrRetryCount = 0;
  }

  void _resetAsr(String reason) {
    _resumeSeekBufferingPlayback();
    _cancelAsrRetry();
    status.value = '';
    asrError.value = '';
    cloudLagWarning.value = false;
    _reachedEnd = false;
    _seeksInProgress = 0; // 重置可能卡住的 seek 状态
    final session = _session;
    if (session != null) _record('reset $reason', session);
    _session = null;

    // 关键修复：把旧 PlayerPcm.close()（它内部 dispose 一个 Player 实例）
    // 串进 _previousSession 链里，而不是直接丢弃。合集切下一集时，
    // 旧 PlayerPcm 还在跑第二 mpv 实例，新 setDataSource 里主 Player 立刻
    // open(newMedia)，两个 Player 争底层 mpv 原生资源 → 崩溃。
    // _run() 开头已经有 `await previous.timeout(2s)` 等这条链走完，
    // 所以下一次启动的新 PlayerPcm 会严格等旧的 dispose 完毕。
    final pcmFuture = session?.pcm?.close() ?? Future.value();
    _previousSession = Future.wait([
      Future<void>(() { session?.stream.close(); }),
      pcmFuture.catchError((_) {}),
    ]).catchError((_) => <void>[]);

    _asrCues.clear();
    _asrTimeline = CaptionTimeline(_emptyCues);
    _nextAsrStartMs = null;
    frame.value = null;
    clearSentenceQueue();
  }

  void _prefetchTranslations(int positionMs) {
    if (!showOriginal.value || !showTranslation.value) return;
    final bool isUsingAsr = selectedTrack.value == realtimeLocalTrack ||
        selectedTrack.value == realtimeCloudTrack ||
        selectedTrack.value == realtimeTrack ||
        _videoTimeline == null;
    if (!isUsingAsr && _translatedTimeline != null) return;
    final lang = targetLanguage.value;
    for (final cue
        in _timeline.upcoming(positionMs, positionMs + _translationLeadMs)) {
      if (!cue.canTranslate) continue;
      if (_translationRequests.length >= 2) return;
      final text = cue.text;
      final cacheKey = '$lang:$text';
      if (_translations.containsKey(cacheKey) ||
          _translationRequests.containsKey(cacheKey) ||
          _translationFailures.contains(cacheKey)) {
        continue;
      }
      final bool cueIsYue = isCantoneseTrack ||
          chinesePhonetic.value == 'cantonese' ||
          currentLanguageContext == 'yue' ||
          CaptionPronunciation.isCantoneseText(text);
      final String? cueLang = cueIsYue ? 'yue' : currentLanguageContext;
      final token = _translationRequests[cacheKey] = CancelToken();
      unawaited(_translate(text, token, sourceLang: cueLang));
    }
  }

  void _prefetchPronunciations(int positionMs) {
    if (!showOriginal.value || !showPronunciation.value) return;
    final jpMode = japanesePhonetic.value;
    final cnMode = chinesePhonetic.value;
    final contextLang = currentLanguageContext;
    for (final cue
        in _timeline.upcoming(positionMs, positionMs + _translationLeadMs)) {
      final text = cue.text;
      final bool cueHasKana = RegExp(r'[\u3040-\u309F\u30A0-\u30FF]').hasMatch(text);
      final bool cueHasHangul = RegExp(r'[\uAC00-\uD7AF]').hasMatch(text);
      final bool cueIsYue = isCantoneseTrack ||
          cnMode == 'cantonese' ||
          contextLang == 'yue' ||
          CaptionPronunciation.isCantoneseText(text);

      String? cueLang;
      if (contextLang == 'ja' || cueHasKana || isJapaneseTrack) {
        cueLang = 'ja';
      } else if (contextLang == 'ko' || cueHasHangul) {
        cueLang = 'ko';
      } else if (cueIsYue) {
        cueLang = 'yue';
      } else if (contextLang != null) {
        cueLang = contextLang;
      }

      final cacheKey = '$cueLang:$cnMode:$jpMode:$cueIsYue:$text';
      if (_pronunciations.containsKey(cacheKey)) {
        continue;
      }

      // 1. 优先 0ms 本地离线秒出，直接写入缓存，0 延迟、不占并发槽！
      final offline = CaptionPronunciation.shared.getOfflinePronunciation(
        text,
        japaneseMode: jpMode,
        chineseMode: cnMode,
        isCantoneseContext: cueIsYue,
        sourceLang: cueLang,
      );
      if (offline != null && offline.isNotEmpty) {
        _pronunciations[cacheKey] = offline;
        if (_pronunciations.length > 512) _pronunciations.remove(_pronunciations.keys.first);
        continue;
      }

      // 2. 本地未命中的生僻词或其它语种，才异步走网络兜底
      if (_pronunciationRequests.length >= 3) return;
      if (_pronunciationRequests.containsKey(cacheKey)) {
        continue;
      }
      _pronunciationRequests[cacheKey] = true;
      CaptionPronunciation.shared
          .getPronunciation(
            text,
            japaneseMode: jpMode,
            chineseMode: cnMode,
            isCantoneseContext: cueIsYue,
            sourceLang: cueLang,
          )
          .then((result) {
        _pronunciationRequests.remove(cacheKey);
        if (result != null && result.isNotEmpty) {
          _pronunciations[cacheKey] = result;
          if (_pronunciations.length > 512) _pronunciations.remove(_pronunciations.keys.first);
          _render(_clock.at(_elapsed.elapsedMilliseconds));
        }
      }).catchError((_) {
        _pronunciationRequests.remove(cacheKey);
      });
    }
  }

  Future<void> _translate(String text, CancelToken token, {String? sourceLang}) async {
    final lang = targetLanguage.value;
    final cacheKey = '$lang:$text';
    try {
      final engine = translationEngine.value;
      final bool cueIsYue = sourceLang == 'yue' ||
          isCantoneseTrack ||
          chinesePhonetic.value == 'cantonese' ||
          currentLanguageContext == 'yue' ||
          CaptionPronunciation.isCantoneseText(text);
      final source = cueIsYue ? 'yue' : (sourceLang ?? currentLanguageContext ?? 'auto');
      final translated = await _translator.translate(
        text,
        token,
        sourceLang: source,
        targetLang: lang,
        engine: engine,
      );
      if (token.isCancelled) return;
      translationError.value = '';
      _translations[cacheKey] = translated;
      if (_translations.length > 512) _translations.remove(_translations.keys.first);
    } catch (_) {
      if (!token.isCancelled) {
        _translationFailures.add(cacheKey);
        translationError.value = '字幕翻译失败，请检查网络';
      }
    } finally {
      if (_translationRequests[cacheKey] == token) {
        _translationRequests.remove(cacheKey);
        _render(_clock.at(_elapsed.elapsedMilliseconds));
      }
    }
  }

  void _cancelTranslations() {
    for (final token in _translationRequests.values) {
      token.cancel();
    }
    _translationRequests.clear();
    _translationFailures.clear();
    translationError.value = '';
  }

  void dispose() {
    detach();
    _trackRequest = null;
    _trackSelection = null;
    _translator.close();
  }
}

class _CaptionSession {
  _CaptionSession(
    this.id, {
    CaptionAsrStream? stream,
    this.isLocal = false,
  }) : stream = stream ?? AsrStream();

  final int id;
  final bool isLocal;
  final leveler = PcmLeveler();
  final cloudFlow = CloudAsrFlow();
  AsrCaptionTiming? timing;
  PlayerPcm? pcm;
  final CaptionAsrStream stream;
  final transcript = AsrTranscript(sentenceOnly: true);
  int lastProcessedMs = 0;
  bool hasTranscript = false;
  int results = 0;
  int deltas = 0;
  int updates = 0;
  int emptyUpdates = 0;
  ({int startMs, int endMs})? lastCue;
  List<CaptionCue> partial = const [];
}
