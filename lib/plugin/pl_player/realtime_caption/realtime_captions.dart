import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:get/get.dart' hide Response;
import 'package:media_kit/media_kit.dart';
import 'package:pilipala/http/video.dart';
import 'package:pilipala/models/video/subTitile/result.dart';

import '../models/data_source.dart';
import 'asr_stream.dart';
import 'caption_preferences.dart';
import 'caption_pronunciation.dart';
import 'caption_timeline.dart';
import 'caption_translator.dart';
import 'ieeio_login.dart';
import 'local_asr_model.dart';
import 'local_asr_stream.dart';
import 'player_pcm.dart';

typedef CaptionFrame = ({
  CaptionCue cue,
  int highlighted,
  String translation,
  String pronunciation,
});

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
  static const _translationLeadMs = 15000;
  static const _endToleranceMs = 1500;
  static const _trackWait = Duration(seconds: 5);
  static const _emptyCues = <CaptionCue>[];
  static const _loadingTracks = '正在读取视频自带字幕…';
  static const _readingAudio = '识别服务已连接，正在读取视频音轨…';

  CaptionPreferences? _preferences;

  final showOriginal = false.obs;
  final showTranslation = false.obs;
  final showPronunciation = false.obs; // 是否显示发音注音
  final chinesePhonetic = 'auto'.obs; // 中文/粤语发音类型：'auto' (自动检测), 'cantonese' (粤拼), 'mandarin' (拼音)
  final japanesePhonetic = 'kana'.obs; // 日语发音类型：'kana' (假名) 或 'romaji' (罗马音)
  final frame = Rxn<CaptionFrame>();
  final tracks = <SubTitlteItemModel>[].obs;
  final selectedTrack = automaticTrack.obs;
  final useLocalAsr = false.obs; // 是否使用 Sherpa-ONNX 离线本地识别
  final localAsrModel = 'sense_voice'.obs; // 离线识别模型：'sense_voice', 'whisper_tiny', 'whisper_base', 'whisper_small'
  final targetLanguage = 'zh-CN'.obs; // 目标翻译语言
  final captionDelayMs = 0.obs; // 字幕时间轴偏移（毫秒，负数为提前/防慢一拍，正数为延后）
  final status = ''.obs;
  final asrError = ''.obs;
  final translationError = ''.obs;
  final cloudLagWarning = false.obs;
  final needLoginForSubtitles = false.obs;

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

  bool get isCantoneseTrack {
    if (chinesePhonetic.value == 'cantonese') return true;
    final t = _activeTrack;
    if (t != null) {
      final doc = t.lanDoc?.toLowerCase() ?? '';
      final lan = t.lan?.toLowerCase() ?? '';
      if (doc.contains('粤') ||
          doc.contains('粵') ||
          doc.contains('cantonese') ||
          lan.contains('zhhk') ||
          lan.contains('yue')) {
        return true;
      }
    }
    return false;
  }

  String get asrLanguage =>
      (isCantoneseTrack || chinesePhonetic.value == 'cantonese') ? 'yue' : 'auto';

  _CaptionSession? _session;
  int _sessionSequence = 0;
  Future<void> _previousSession = Future.value();
  final _asrCues = <CaptionCue>[];
  CaptionTimeline _asrTimeline = CaptionTimeline(_emptyCues);
  int? _nextAsrStartMs;
  Timer? _asrRetryTimer;
  int _asrRetryCount = 0;
  bool _reachedEnd = false;

  bool get enabled =>
      showOriginal.value || showTranslation.value || showPronunciation.value;
  CaptionTimeline get _timeline => _videoTimeline ?? _asrTimeline;

  bool get isNativeSubtitle => _videoTimeline != null;
  bool get isUsingLocalAsr =>
      _session != null ? _session!.isLocal : (useLocalAsr.value && LocalAsrModelManager.isSupported);
  String? get activeTrackDoc => _activeTrack?.lanDoc ?? _activeTrack?.title;

  String get activeSourceTag {
    if (_videoTimeline != null) {
      final doc = _activeTrack?.lanDoc ?? _activeTrack?.title;
      return (doc != null && doc.isNotEmpty) ? 'B站官方 · $doc' : 'B站官方';
    }
    if (_session != null) {
      return _session!.isLocal ? '本地离线' : '云端在线';
    }
    if (useLocalAsr.value && LocalAsrModelManager.isSupported) return '本地离线';
    return '云端在线';
  }

  String get activeSourceDescription {
    if (_videoTimeline != null) {
      final doc = _activeTrack?.lanDoc ?? _activeTrack?.title;
      return doc != null && doc.isNotEmpty ? 'B站官方字幕 · $doc' : 'B站官方字幕';
    }
    if (_session != null) {
      if (_session!.isLocal) {
        final cfg = LocalAsrModelManager.availableModels[localAsrModel.value];
        return '本地离线识别 · ${cfg?.name ?? "Sherpa-ONNX"}';
      }
      return '云端在线识别 · Qwen ASR';
    }
    if (useLocalAsr.value && LocalAsrModelManager.isSupported) {
      final cfg = LocalAsrModelManager.availableModels[localAsrModel.value];
      return '本地离线识别 · ${cfg?.name ?? "Sherpa-ONNX"}';
    }
    return '云端在线识别 · Qwen ASR';
  }

  void bindPreferences(CaptionPreferences preferences) {
    _preferences = preferences;
    showOriginal.value = preferences.showOriginal.value;
    showTranslation.value = preferences.showTranslation.value;
    showPronunciation.value = preferences.showPronunciation.value;
    chinesePhonetic.value = preferences.chinesePhonetic.value;
    japanesePhonetic.value = preferences.japanesePhonetic.value;
    useLocalAsr.value = preferences.useLocalAsr.value;
    localAsrModel.value = preferences.localAsrModel.value;
    targetLanguage.value = preferences.targetLanguage.value;
    captionDelayMs.value = preferences.captionDelayMs.value;
    LocalAsrModelManager.shared.currentModelId.value =
        preferences.localAsrModel.value;
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
      'PiliPala 字幕诊断 v1',
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
        'rx=${session.results} deltas=${session.deltas} updates=${session.updates} '
        'empty_updates=${session.emptyUpdates} '
        'last_cue_ms=${cue?.startMs}..${cue?.endMs} visible=${frame.value != null}';
  }

  void prepareTracks(String bvid, int cid) {
    if (_video?.bvid == bvid && _video?.cid == cid) return;
    _video = (bvid: bvid, cid: cid);
    _asrLog.clear();
    _record('loading native tracks');
    needLoginForSubtitles.value = false;
    // 立即清空上一视频的字幕帧、时间轴与状态，防止串台或残留显示上一个视频的字幕
    frame.value = null;
    _activeTrack = null;
    _videoTimeline = null;
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
    if (tracks.isNotEmpty) {
      if (selectedTrack.value == automaticTrack || selectedTrack.value <= 0) {
        selectedTrack.value = tracks.first.id!;
      }
      _resetAsr('found native tracks');
      unawaited(_selectTimeline(userSelected: false));
    } else {
      // 官方无字幕，直接定位到当前的实时语音识别轨（云端或本地）
      if (selectedTrack.value > 0 || selectedTrack.value == automaticTrack) {
        selectedTrack.value =
            useLocalAsr.value ? realtimeLocalTrack : realtimeCloudTrack;
      }
      _videoTimeline = null;
      _activeTrack = null;
      _updateAfterTrackLoad();
    }
  }

  void selectTrack(int id) {
    selectedTrack.value = id;
    if (id == realtimeTrack || id == realtimeLocalTrack) {
      useLocalAsr.value = true;
      _preferences?.useLocalAsr.value = true;
      _preferences?.save();
      _trackSelection = null;
      _videoTimeline = null;
      _record('selected realtime local');
      _resetAsr('selected realtime local track');
      _cancelTranslations();
      _nextAsrStartMs = null;
      asrError.value = '';
      updatePlayback();
    } else if (id == realtimeCloudTrack) {
      useLocalAsr.value = false;
      _preferences?.useLocalAsr.value = false;
      _preferences?.save();
      _trackSelection = null;
      _videoTimeline = null;
      _record('selected realtime cloud');
      _resetAsr('selected realtime cloud track');
      _cancelTranslations();
      _nextAsrStartMs = null;
      asrError.value = '';
      updatePlayback();
    } else {
      _resetAsr('selected native track');
      _trackWaitUntilMs =
          _elapsed.elapsedMilliseconds + _trackWait.inMilliseconds;
      unawaited(_selectTimeline(userSelected: true));
    }
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
      _pronunciations.clear();
      _render(_clock.at(_elapsed.elapsedMilliseconds));
    } else {
      // 无论用户自选还是自动模式，只要没有找到有效字幕，必须清空，绝不残留老视频的字幕！
      _videoTimeline = null;
      _activeTrack = null;
      _record('native track unavailable');
      _cancelTranslations();
      _pronunciations.clear();
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

  void attach(Player player, DataSource source, {required Duration start}) {
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
    _updateSwitches();
  }

  void setTranslation(bool value) {
    if (value && !enabled) showOriginal.value = true;
    showTranslation.value = value;
    _preferences?.showTranslation.value = value;
    _preferences?.save();
    if (!value) _cancelTranslations();
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
    _preferences?.useLocalAsr.value = value;
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

  void setTargetLanguage(String lang) {
    targetLanguage.value = lang;
    _preferences?.targetLanguage.value = lang;
    _preferences?.save();
    _translations.clear();
    _cancelTranslations();
    updatePlayback();
  }

  void retry() {
    _cancelAsrRetry();
    _resetAsr('retry requested');
    asrError.value = '';
    translationError.value = '';
    _translationFailures.clear();
    _nextAsrStartMs = null;
    updatePlayback();
  }

  void _updateSwitches() {
    if (!enabled) {
      _stopTicker();
      _resetAsr('subtitles disabled');
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
    return _attachment;
  }

  void endSeek(int attachment, Duration? position) {
    if (attachment != _attachment || --_seeksInProgress > 0) return;
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
    final cue = _timeline.at(effectiveMs);
    final lang = targetLanguage.value;
    final translated = showTranslation.value
        ? _translations['$lang:${cue?.text}']
        : null;
    final jpMode = japanesePhonetic.value;
    final cnMode = chinesePhonetic.value;
    final isYue = isCantoneseTrack;
    final pronunciation = showPronunciation.value
        ? _pronunciations['$cnMode:$jpMode:$isYue:${cue?.text}']
        : null;

    frame.value = cue == null
        ? null
        : (
            cue: cue,
            highlighted: cue.highlightAt(effectiveMs),
            translation: translated ?? '',
            pronunciation: pronunciation ?? '',
          );
    _prefetchTranslations(effectiveMs);
    _prefetchPronunciations(effectiveMs);

    // 会话结束后自动续跑：当 _session 结束且未到视频结尾时，在播放推进到续读阈值时立刻自动唤醒新会话
    if (_session == null && !_reachedEnd && !player.state.completed) {
      _startAsrIfNeeded(player, positionMs);
    }
  }

  void _startAsrIfNeeded(Player player, int positionMs) {
    if (_videoTimeline != null ||
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
    if (selectedTrack.value != realtimeTrack &&
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
    if (next != null && next - positionMs > _leadMs ~/ 2) {
      status.value = '';
      return;
    }
    final source = _source!;
    final audio = source.audioSource;
    final uri = audio != null && audio.isNotEmpty
        ? audio
        : source.videoSource ?? source.file?.path;
    if (uri == null || uri.isEmpty) {
      asrError.value = '当前视频没有可识别的音轨';
      return;
    }
    final useLocal = useLocalAsr.value && LocalAsrModelManager.isSupported;
    final session = _session = _CaptionSession(
      ++_sessionSequence,
      stream: useLocal ? LocalAsrStream() : AsrStream(),
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
      await previous;
      if (_session != session) return;
      await session.stream.connect(
        ieeioAsrEndpoint,
        language: asrLanguage,
        ieeioLoginToken: ({rejectedToken}) async {
          if (_session == session) {
            status.value = '正在后台登录 QwenASR…';
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
      await pcm.prepare().timeout(const Duration(seconds: 8));
      if (_session != session) return;

      const bytesPerMs = PlayerPcm.bytesPerSecond ~/ 1000;
      // 预先缓冲 10~12 秒的音频流，避免识别时快时慢、断断续续
      final burstBytes = math.max(
        PlayerPcm.frameSize,
        session.isLocal ? 16000 * bytesPerMs : 12000 * bytesPerMs,
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
        final leadMs = session.isLocal ? _leadMs : 12000;
        final readThrough = math.max(0, positionMs + leadMs - startMs);
        final limit =
            math.min(readThrough * bytesPerMs, session.stream.maxAudioBytes);
        final sendRate = session.isLocal
            ? 8.0
            : (player.state.rate * 2.5).clamp(1.5, 3.0);
        final accrued =
            ((now - lastBudgetUpdate) * bytesPerMs * sendRate).round();
        sendBudget = math.min(burstBytes, sendBudget + accrued);
        lastBudgetUpdate = now;
        await pcm.setReading(limit).timeout(const Duration(seconds: 8));
        while (sendBudget >= PlayerPcm.frameSize &&
            _session == session &&
            !session.stream.done) {
          final audio = await pcm.readFrame(
            limit,
            finalFrame: pcm.drained || limit == session.stream.maxAudioBytes,
          );
          if (audio == null || _session != session) break;
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

          // 监控云端转写相对实际播放进度的真实延迟，仅在云端极度落后时提示并重连
          if (!session.isLocal && session.stream.processedMilliseconds != null) {
            final playedMs = math.max(0, positionMs - startMs);
            final processedMs = session.stream.processedMilliseconds ?? playedMs;
            final lagBehindPlaybackMs = playedMs - processedMs;
            if (lagBehindPlaybackMs > 5000) {
              cloudLagWarning.value = true;
              final sec = (lagBehindPlaybackMs / 1000).toStringAsFixed(0);
              status.value = '云端识别拥堵 (滞后 ${sec}s)…';
              if (lagBehindPlaybackMs > 25000 && !session.stream.done) {
                _record(
                    'cloud asr lagging $lagBehindPlaybackMs ms behind playback, reconnecting',
                    session);
                throw const AsrStreamException('云端识别滞后过高，正在重新对齐', retryable: true);
              }
            } else {
              cloudLagWarning.value = false;
            }
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
    final delta = message['delta'];
    if (delta is String && delta.trim().isNotEmpty) session.deltas++;
    final processed = session.stream.processedMilliseconds ?? 0;
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

    if (session.stream is LocalAsrStream) {
      // 本地离线识别不可用时，清晰展示具体原因（如模型未下载），绝不擅自强行切换用户设置
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
    final session = _session;
    if (session != null) _record('reset $reason', session);
    _session = null;
    session?.stream.close();
    try {
      session?.pcm?.close();
    } catch (_) {}
    _asrCues.clear();
    _asrTimeline = CaptionTimeline(_emptyCues);
    _nextAsrStartMs = null;
    frame.value = null;
  }

  void _prefetchTranslations(int positionMs) {
    if (!showTranslation.value) return;
    final lang = targetLanguage.value;
    for (final cue
        in _timeline.upcoming(positionMs, positionMs + _translationLeadMs)) {
      if (_translationRequests.length >= 2) return;
      final text = cue.text;
      final cacheKey = '$lang:$text';
      if (_translations.containsKey(cacheKey) ||
          _translationRequests.containsKey(cacheKey) ||
          _translationFailures.contains(cacheKey)) {
        continue;
      }
      final token = _translationRequests[cacheKey] = CancelToken();
      unawaited(_translate(text, token));
    }
  }

  void _prefetchPronunciations(int positionMs) {
    if (!showPronunciation.value) return;
    final jpMode = japanesePhonetic.value;
    final cnMode = chinesePhonetic.value;
    final isYue = isCantoneseTrack;
    for (final cue
        in _timeline.upcoming(positionMs, positionMs + _translationLeadMs)) {
      if (_pronunciationRequests.length >= 3) return;
      final text = cue.text;
      final cacheKey = '$cnMode:$jpMode:$isYue:$text';
      if (_pronunciations.containsKey(cacheKey) ||
          _pronunciationRequests.containsKey(cacheKey)) {
        continue;
      }
      _pronunciationRequests[cacheKey] = true;
      CaptionPronunciation.shared
          .getPronunciation(
            text,
            japaneseMode: jpMode,
            chineseMode: cnMode,
            isCantoneseContext: isYue,
          )
          .then((result) {
        _pronunciationRequests.remove(cacheKey);
        if (result != null && result.isNotEmpty) {
          _pronunciations[cacheKey] = result;
          _render(_clock.at(_elapsed.elapsedMilliseconds));
        }
      }).catchError((_) {
        _pronunciationRequests.remove(cacheKey);
      });
    }
  }

  Future<void> _translate(String text, CancelToken token) async {
    final lang = targetLanguage.value;
    final cacheKey = '$lang:$text';
    try {
      final translated =
          await _translator.translate(text, token, targetLang: lang);
      if (token.isCancelled) return;
      translationError.value = '';
      _translations[cacheKey] = translated;
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
