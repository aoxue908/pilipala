// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:ns_danmaku/ns_danmaku.dart';
import 'package:pilipala/http/video.dart';
import 'package:pilipala/models/video/play/ao_output.dart';
import 'package:pilipala/plugin/pl_player/index.dart';
import 'package:pilipala/plugin/pl_player/models/play_repeat.dart';
import 'package:pilipala/services/service_locator.dart';
import 'package:pilipala/utils/feed_back.dart';
import 'package:pilipala/utils/global_data_cache.dart';
import 'package:pilipala/utils/storage.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:status_bar_control/status_bar_control.dart';
import 'package:universal_platform/universal_platform.dart';
import 'realtime_caption/caption_preferences.dart';
import 'realtime_caption/realtime_captions.dart';
// import 'package:wakelock_plus/wakelock_plus.dart';

Box videoStorage = GStrorage.video;
Box setting = GStrorage.setting;
Box localCache = GStrorage.localCache;

class PlPlayerController {
  Player? _videoPlayerController;
  VideoController? _videoController;

  // 添加一个私有静态变量来保存实例
  static PlPlayerController? _instance;

  // 流事件  监听播放状态变化
  StreamSubscription? _playerEventSubs;

  // 本地文件（离线缓存）播放诊断：跟踪 mpv 解码/视频输出，定位「只有声音没画面」。
  StreamSubscription<PlayerLog>? _localLogSub;
  StreamSubscription<Tracks>? _localTracksSub;
  StreamSubscription<VideoParams>? _localVideoParamsSub;

  /// [playerStatus] has a [status] observable
  final PlPlayerStatus playerStatus = PlPlayerStatus();

  ///
  final PlPlayerDataStatus dataStatus = PlPlayerDataStatus();

  // bool controlsEnabled = false;

  /// 响应数据
  /// 带有Seconds的变量只在秒数更新时更新，以避免频繁触发重绘
  // 播放位置
  final Rx<Duration> _position = Rx(Duration.zero);
  final RxInt positionSeconds = 0.obs;
  final Rx<Duration> _sliderPosition = Rx(Duration.zero);
  final RxInt sliderPositionSeconds = 0.obs;
  // 展示使用
  final Rx<Duration> _sliderTempPosition = Rx(Duration.zero);
  final Rx<Duration> _duration = Rx(Duration.zero);
  final RxInt durationSeconds = 0.obs;
  final Rx<Duration> _buffered = Rx(Duration.zero);
  final RxInt bufferedSeconds = 0.obs;

  final Rx<int> _playerCount = Rx(0);

  final Rx<double> _playbackSpeed = 1.0.obs;
  final Rx<double> _longPressSpeed = 2.0.obs;
  final Rx<double> _currentVolume = 1.0.obs;
  final Rx<double> _currentBrightness = 0.0.obs;

  final Rx<bool> _mute = false.obs;
  final Rx<bool> _showControls = false.obs;
  final Rx<bool> _showVolumeStatus = false.obs;
  final Rx<bool> _showBrightnessStatus = false.obs;
  final Rx<bool> _doubleSpeedStatus = false.obs;
  final Rx<bool> _controlsLock = false.obs;
  final Rx<bool> _isFullScreen = false.obs;
  final Rx<bool> _isNativeFullScreen = false.obs;
  // 当前全屏是否保持竖屏方向（用于右下角双按钮的图标切换）
  final Rx<bool> _isVerticalFullScreen = false.obs;
  // 默认投稿视频格式
  static Rx<String> _videoType = 'archive'.obs;

  final Rx<String> _direction = 'horizontal'.obs;

  Rx<bool> videoFitChanged = false.obs;
  final Rx<BoxFit> _videoFit = Rx(BoxFit.contain);
  final Rx<String> _videoFitDesc = Rx('包含');

  ///
  // ignore: prefer_final_fields
  Rx<bool> _isSliderMoving = false.obs;
  PlaylistMode _looping = PlaylistMode.none;
  bool _autoPlay = false;
  final bool _listenersInitialized = false;
  int _captionSourceRevision = 0;

  // 记录历史记录
  String _bvid = '';
  int _cid = 0;
  int _heartDuration = 0;
  bool _enableHeart = true;
  bool _isFirstTime = true;

  Timer? _timer;
  Timer? _timerForSeek;
  Timer? _timerForVolume;
  Timer? _timerForShowingVolume;
  Timer? _timerForGettingVolume;
  Timer? timerForTrackingMouse;
  Timer? videoFitChangedTimer;

  // final Durations durations;

  List<Map<String, dynamic>> videoFitType = [
    {'attr': BoxFit.contain, 'desc': '包含'},
    {'attr': BoxFit.cover, 'desc': '覆盖'},
    {'attr': BoxFit.fill, 'desc': '填充'},
    {'attr': BoxFit.fitHeight, 'desc': '高度适应'},
    {'attr': BoxFit.fitWidth, 'desc': '宽度适应'},
    {'attr': BoxFit.scaleDown, 'desc': '缩小适应'},
  ];

  PreferredSizeWidget? headerControl;
  PreferredSizeWidget? bottomControl;
  Widget? danmuWidget;
  String videoType = 'archive';

  /// 数据加载监听
  Stream<DataStatus> get onDataStatusChanged => dataStatus.status.stream;

  /// 播放状态监听
  Stream<PlayerStatus> get onPlayerStatusChanged => playerStatus.status.stream;

  /// 视频时长
  Rx<Duration> get duration => _duration;
  Stream<Duration> get onDurationChanged => _duration.stream;

  /// 视频当前播放位置
  Rx<Duration> get position => _position;
  Stream<Duration> get onPositionChanged => _position.stream;

  /// 视频播放速度
  double get playbackSpeed => _playbackSpeed.value;

  // 长按倍速
  double get longPressSpeed => _longPressSpeed.value;

  /// 视频缓冲
  Rx<Duration> get buffered => _buffered;
  Stream<Duration> get onBufferedChanged => _buffered.stream;

  // 视频静音
  Rx<bool> get mute => _mute;
  Stream<bool> get onMuteChanged => _mute.stream;

  /// 字幕开启状态

  /// [videoPlayerController] instace of Player
  Player? get videoPlayerController => _videoPlayerController;

  /// [videoController] instace of Player
  VideoController? get videoController => _videoController;

  Rx<bool> get isSliderMoving => _isSliderMoving;

  /// 进度条位置及监听
  Rx<Duration> get sliderPosition => _sliderPosition;
  Stream<Duration> get onSliderPositionChanged => _sliderPosition.stream;

  Rx<Duration> get sliderTempPosition => _sliderTempPosition;
  // Stream<Duration> get onSliderPositionChanged => _sliderPosition.stream;

  /// 是否展示控制条及监听
  Rx<bool> get showControls => _showControls;
  Stream<bool> get onShowControlsChanged => _showControls.stream;

  /// 音量控制条展示/隐藏
  Rx<bool> get showVolumeStatus => _showVolumeStatus;
  Stream<bool> get onShowVolumeStatusChanged => _showVolumeStatus.stream;

  /// 亮度控制条展示/隐藏
  Rx<bool> get showBrightnessStatus => _showBrightnessStatus;
  Stream<bool> get onShowBrightnessStatusChanged =>
      _showBrightnessStatus.stream;

  /// 音量控制条
  Rx<double> get volume => _currentVolume;
  Stream<double> get onVolumeChanged => _currentVolume.stream;

  /// 亮度控制条
  Rx<double> get brightness => _currentBrightness;
  Stream<double> get onBrightnessChanged => _currentBrightness.stream;

  /// 是否循环
  PlaylistMode get looping => _looping;

  /// 是否自动播放
  bool get autoplay => _autoPlay;

  /// 视频比例
  Rx<BoxFit> get videoFit => _videoFit;
  Rx<String> get videoFitDEsc => _videoFitDesc;

  /// 是否长按倍速
  Rx<bool> get doubleSpeedStatus => _doubleSpeedStatus;

  Rx<bool> isBuffering = true.obs;

  /// 屏幕锁 为true时，关闭控制栏
  Rx<bool> get controlsLock => _controlsLock;

  /// 全屏状态
  Rx<bool> get isFullScreen => _isFullScreen;
  Rx<bool> get isNativeFullScreen => _isNativeFullScreen;
  /// 当前全屏是否保持竖屏方向
  Rx<bool> get isVerticalFullScreen => _isVerticalFullScreen;

  /// 全屏方向
  Rx<String> get direction => _direction;

  Rx<int> get playerCount => _playerCount;

  ///
  // Rx<String> get videoType => _videoType;

  /// 弹幕开关
  Rx<bool> isOpenDanmu = false.obs;
  // 关联弹幕控制器
  DanmakuController? danmakuController;
  // 弹幕相关配置
  late List blockTypes;
  late double showArea;
  late double opacityVal;
  late double fontSizeVal;
  late double strokeWidth;
  late double danmakuDurationVal;
  late List<double> speedsList;
  // 缓存
  double? defaultDuration;
  late bool enableAutoLongPressSpeed = false;

  // 播放顺序相关
  PlayRepeat playRepeat = PlayRepeat.listOrder;

  late final captionPreferences = CaptionPreferences(videoStorage);
  late final realtimeCaptions =
      RealtimeCaptions(preferences: captionPreferences);

  void updateSliderPositionSecond() {
    int newSecond = _sliderPosition.value.inSeconds;
    if (sliderPositionSeconds.value != newSecond) {
      sliderPositionSeconds.value = newSecond;
    }
  }

  void updatePositionSecond() {
    int newSecond = _position.value.inSeconds;
    if (positionSeconds.value != newSecond) {
      positionSeconds.value = newSecond;
    }
  }

  void updateDurationSecond() {
    int newSecond = _duration.value.inSeconds;
    if (durationSeconds.value != newSecond) {
      durationSeconds.value = newSecond;
    }
  }

  void updateBufferedSecond() {
    int newSecond = _buffered.value.inSeconds;
    if (bufferedSeconds.value != newSecond) {
      bufferedSeconds.value = newSecond;
    }
  }

  // 添加一个私有构造函数
  PlPlayerController._internal(this.videoType) {
    final cache = GlobalDataCache();
    isOpenDanmu.value = cache.isOpenDanmu;
    blockTypes = cache.blockTypes;
    showArea = cache.showArea;
    opacityVal = cache.opacityVal;
    fontSizeVal = cache.fontSizeVal;
    danmakuDurationVal = cache.danmakuDurationVal;
    strokeWidth = cache.strokeWidth;
    playRepeat = cache.playRepeat;
    _playbackSpeed.value = cache.playbackSpeed;
    enableAutoLongPressSpeed = cache.enableAutoLongPressSpeed;
    _longPressSpeed.value = cache.longPressSpeed;
    speedsList = cache.speedsList;
    // _playerEventSubs = onPlayerStatusChanged.listen((PlayerStatus status) {
    //   if (status == PlayerStatus.playing) {
    //     WakelockPlus.enable();
    //   } else {
    //     WakelockPlus.disable();
    //   }
    // });
  }

  // 获取实例 传参
  factory PlPlayerController({
    String videoType = 'archive',
  }) {
    // 如果实例尚未创建，则创建一个新实例
    _instance ??= PlPlayerController._internal(videoType);
    if (videoType != 'none') {
      _instance!._playerCount.value += 1;
      _videoType.value = videoType;
    }
    return _instance!;
  }

  // 初始化资源
  Future<void> setDataSource(
    DataSource dataSource, {
    bool autoplay = true,
    // 默认不循环
    PlaylistMode looping = PlaylistMode.none,
    // 初始化播放位置
    Duration seekTo = Duration.zero,
    // 初始化播放速度
    double speed = 1.0,
    // 硬件加速
    bool enableHA = false,
    double? width,
    double? height,
    Duration? duration,
    // 方向
    String? direction,
    // 记录历史记录
    String bvid = '',
    int cid = 0,
    // 历史记录开关
    bool enableHeart = true,
    // 是否首次加载
    bool isFirstTime = true,
    //  是否开启字幕
    bool enableSubTitle = false,
  }) async {
    final captionSourceRevision = ++_captionSourceRevision;
    debugPrint('[local-play] setDataSource type=${dataSource.type} video=${dataSource.videoSource} audio=${dataSource.audioSource} bvid=$bvid cid=$cid');
    try {
      realtimeCaptions.detach();
      if (bvid.isNotEmpty) realtimeCaptions.prepareTracks(bvid, cid);
      _autoPlay = autoplay;
      _looping = looping;
      // 初始化视频倍速
      // _playbackSpeed.value = speed;
      // 初始化数据加载状态
      dataStatus.status.value = DataStatus.loading;
      // 初始化全屏方向
      _direction.value = direction ?? 'horizontal';
      _bvid = bvid;
      _cid = cid;
      _enableHeart = enableHeart;
      _isFirstTime = isFirstTime;
      if (enableSubTitle) realtimeCaptions.setOriginal(true);
      if (_videoPlayerController != null &&
          _videoPlayerController!.state.playing) {
        await pause(notify: false);
      }

      if (_playerCount.value == 0) {
        return;
      }
      // 配置Player 音轨、字幕等等
      _videoPlayerController = await _createVideoController(
          dataSource, _looping, enableHA, width, height, seekTo);
      // 获取视频时长 00:00
      _duration.value = duration ?? _videoPlayerController!.state.duration;
      updateDurationSecond();
      // 数据加载完成
      dataStatus.status.value = DataStatus.loaded;

      // listen the video player events
      if (!_listenersInitialized) {
        startListeners();
      }
      if (captionSourceRevision == _captionSourceRevision &&
          bvid.isNotEmpty && _videoPlayerController != null) {
        realtimeCaptions.attach(_videoPlayerController!, dataSource,
            start: seekTo);
      }
      await _initializePlayer(duration: _duration.value);
      bool autoEnterFullcreen =
          setting.get(SettingBoxKey.enableAutoEnter, defaultValue: false);
      if (autoEnterFullcreen && _isFirstTime) {
        await Future.delayed(const Duration(milliseconds: 100));
        triggerFullScreen();
      }
    } catch (err) {
      dataStatus.status.value = DataStatus.error;
      debugPrint('plPlayer err:  $err\n${StackTrace.current}');
    }
  }

  // 配置播放器
  Future<Player> _createVideoController(    DataSource dataSource,
    PlaylistMode looping,
    bool enableHA,
    double? width,
    double? height,
    Duration seekTo,
  ) async {
    // 每次配置时先移除监听
    removeListeners();
    isBuffering.value = false;
    buffered.value = Duration.zero;
    _heartDuration = 0;
    _position.value = Duration.zero;
    // 初始化时清空弹幕，防止上次重叠
    if (danmakuController != null) {
      danmakuController!.clear();
    }
    Player player = _videoPlayerController ??
        Player(
          configuration: PlayerConfiguration(
            // 默认缓存 5M 大小
            bufferSize:
                videoType == 'live' ? 32 * 1024 * 1024 : 5 * 1024 * 1024,
          ),
        );

    var pp = player.platform as NativePlayer;
    // 解除倍速限制
    await pp.setProperty("af", "scaletempo2=max-speed=8");

    // 本地文件（离线缓存）播放诊断：上一轮订阅先取消；file 类型时挂上
    // mpv 关键日志 + 轨道/视频参数监听，出问题时可用 adb logcat -s flutter 直接定位。
    await _cancelLocalDiagnostics();
    if (dataSource.type == DataSourceType.file) {
      _localTracksSub = player.stream.tracks.listen((t) {
        final selected = player.state.tracks.video;
        final selectedAudio = player.state.tracks.audio;
        debugPrint(
            '[local-play] tracks: video=${t.video.length} audio=${t.audio.length} '
            'selectedVideo=${selected.isNotEmpty ? selected.first.id : '-'} '
            'selectedAudio=${selectedAudio.isNotEmpty ? '${selectedAudio.first.id}:${selectedAudio.first.title}' : '-'}');
      });
      _localVideoParamsSub = player.stream.videoParams.listen((p) {
        debugPrint('[local-play] videoParams: ${p.dw}x${p.dh} '
            'rotate=${p.rotate} pixfmt=${p.pixelformat} '
            'hw=${p.hwPixelformat}');
      });
      _localLogSub = player.stream.log.listen((e) {
        final String level = e.level;
        final String prefix = e.prefix;
        if (level == 'error' ||
            level == 'warn' ||
            prefix == 'vo' ||
            prefix == 'vd' ||
            prefix == 'cplayer' ||
            prefix == 'lavd') {
          debugPrint('[local-play][$level/$prefix] ${e.text}');
        }
      });
    }

    //  音量不一致
    if (Platform.isAndroid) {
      await pp.setProperty("volume-max", "100");
      String defaultAoOutput =
          setting.get(SettingBoxKey.defaultAoOutput, defaultValue: '0');
      await pp.setProperty(
          "ao",
          aoOutputList
              .where((e) => e['value'] == defaultAoOutput)
              .first['title']);
    }

    // 切换数据源前停止旧媒体，再重置外置音轨。否则从网络 DASH 切到
    // 本地一体 MP4 时，旧的 audio-files 会继续作为外置音轨播放，出现
    // “画面是新视频、声音却是上一条”的串音。
    await player.stop();
    final String? externalAudio = dataSource.audioSource;
    await pp.setProperty(
      'audio-files',
      externalAudio == null || externalAudio.isEmpty
          ? ''
          : UniversalPlatform.isWindows
              ? externalAudio.replaceAll(';', '\\;')
              : externalAudio.replaceAll(':', '\\:'),
    );
    await player.setAudioTrack(AudioTrack.auto());

    // 字幕
    // if (dataSource.subFiles != '' && dataSource.subFiles != null) {
    //   await pp.setProperty(
    //     'sub-files',
    //     UniversalPlatform.isWindows
    //         ? dataSource.subFiles!.replaceAll(';', '\\;')
    //         : dataSource.subFiles!.replaceAll(':', '\\:'),
    //   );
    //   await pp.setProperty("subs-with-matching-audio", "no");
    //   await pp.setProperty("sub-forced-only", "yes");
    //   await pp.setProperty("blend-subtitles", "video");
    // }

    // Surface 绑定路径：统一走「先绑 Surface、后出画面」的默认时序（attach=false）。
    // 该路径已被网络播放长期验证可正常出画面；此前本地文件曾单独走「视频参数确定后
    // 再绑 Surface」(attach=true) 的路径，真机实测只有声音、没有画面，故不再区分。
    const bool attachSurfaceAfterVideoParams = false;

    _videoController = _videoController ??
        VideoController(
          player,
          configuration: VideoControllerConfiguration(
            enableHardwareAcceleration: enableHA,
            androidAttachSurfaceAfterVideoParameters:
                attachSurfaceAfterVideoParams,
          ),
        );

    player.setPlaylistMode(looping);

    if (dataSource.type == DataSourceType.asset) {
      final assetUrl = dataSource.videoSource!.startsWith("asset://")
          ? dataSource.videoSource!
          : "asset://${dataSource.videoSource!}";
      player.open(
        Media(assetUrl, httpHeaders: dataSource.httpHeaders),
        play: false,
      );
    }
    await player.open(
      Media(dataSource.videoSource!,
          httpHeaders: dataSource.httpHeaders, start: seekTo),
      play: false,
    );
    // 离线缓存的 DASH 视频轨（m4s）与音频轨（m4a）是两个独立文件：
    // 视频轨没有内嵌声音，必须把音频文件作为【外部音轨】挂上，否则只有画面没声音。
    // 反之若用户误把音频文件当视频打开，也在这里纠正为无画面提示。
    if (dataSource.type == DataSourceType.file &&
        dataSource.audioSource != null &&
        dataSource.audioSource!.isNotEmpty) {
      try {
        await player.setAudioTrack(
          AudioTrack.uri(
            dataSource.audioSource!,
            title: '离线音频',
          ),
        );
      } catch (e) {
        print('挂载外部音轨失败: $e');
      }
    } else if (dataSource.type == DataSourceType.file) {
      // 一体 MP4 只允许使用内嵌音轨，不能沿用上一数据源的外部音频。
      await player.setAudioTrack(AudioTrack.auto());
    }

    return player;
  }

  /// 取消本地播放诊断订阅。
  Future<void> _cancelLocalDiagnostics() async {
    await _localLogSub?.cancel();
    await _localTracksSub?.cancel();
    await _localVideoParamsSub?.cancel();
    _localLogSub = null;
    _localTracksSub = null;
    _localVideoParamsSub = null;
  }

  // 开始播放
  Future _initializePlayer({
    Duration? duration,
  }) async {
    getVideoFit();
    // if (_looping) {
    //   await setLooping(_looping);
    // }

    /// 跳转播放
    // if (seekTo != Duration.zero) {
    //   await this.seekTo(seekTo);
    // }

    /// 自动播放
    if (_autoPlay) {
      await play(duration: duration);
    }

    /// 设置倍速
    if (videoType == 'live') {
      await setPlaybackSpeed(1.0);
    } else {
      if (_playbackSpeed.value != 1.0) {
        await setPlaybackSpeed(_playbackSpeed.value);
      } else {
        await setPlaybackSpeed(1.0);
      }
    }
  }

  List<StreamSubscription> subscriptions = [];
  final List<Function(Duration position)> _positionListeners = [];
  final List<Function(PlayerStatus status)> _statusListeners = [];

  /// 播放事件监听
  void startListeners() {
    subscriptions.addAll(
      [
        videoPlayerController!.stream.playing.listen((event) {
          if (event) {
            playerStatus.status.value = PlayerStatus.playing;
          } else {
            playerStatus.status.value = PlayerStatus.paused;
          }
          videoPlayerServiceHandler.onStatusChange(
              playerStatus.status.value, isBuffering.value);
          realtimeCaptions.updatePlayback();

          /// 触发回调事件
          for (var element in _statusListeners) {
            element(event ? PlayerStatus.playing : PlayerStatus.paused);
          }
          if (videoPlayerController!.state.position.inSeconds != 0) {
            makeHeartBeat(positionSeconds.value, type: 'status');
          }
        }),
        videoPlayerController!.stream.completed.listen((event) {
          realtimeCaptions.updatePlayback();
          if (event) {
            playerStatus.status.value = PlayerStatus.completed;

            /// 触发回调事件
            for (var element in _statusListeners) {
              element(PlayerStatus.completed);
            }
          } else {
            // playerStatus.status.value = PlayerStatus.playing;
          }
          makeHeartBeat(positionSeconds.value, type: 'status');
        }),
        videoPlayerController!.stream.position.listen((event) {
          _position.value = event;
          updatePositionSecond();
          if (!isSliderMoving.value) {
            _sliderPosition.value = event;
            updateSliderPositionSecond();
          }
          realtimeCaptions.updatePlayback(position: event);

          /// 触发回调事件
          for (var element in _positionListeners) {
            element(event);
          }
          makeHeartBeat(event.inSeconds);
        }),
        videoPlayerController!.stream.duration.listen((event) {
          if (event > Duration.zero) {
            duration.value = event;
          }
        }),
        videoPlayerController!.stream.buffer.listen((event) {
          _buffered.value = event;
          updateBufferedSecond();
        }),
        videoPlayerController!.stream.buffering.listen((event) {
          isBuffering.value = event;
          realtimeCaptions.updatePlayback();
          videoPlayerServiceHandler.onStatusChange(
              playerStatus.status.value, event);
        }),
        videoPlayerController!.stream.rate.listen((_) {
          realtimeCaptions.updatePlayback();
        }),
        // videoPlayerController!.stream.volume.listen((event) {
        //   if (!mute.value && _volumeBeforeMute != event) {
        //     _volumeBeforeMute = event / 100;
        //   }
        // }),
        // 媒体通知监听
        onPlayerStatusChanged.listen((event) {
          videoPlayerServiceHandler.onStatusChange(event, isBuffering.value);
        }),
        onPositionChanged.listen((event) {
          EasyThrottle.throttle(
              'mediaServicePositon',
              const Duration(seconds: 1),
              () => videoPlayerServiceHandler.onPositionChange(event));
        }),
      ],
    );
  }

  /// 移除事件监听
  void removeListeners() {
    for (final s in subscriptions) {
      s.cancel();
    }
    subscriptions.clear();
  }

  /// 跳转至指定位置
  Future<void> seekTo(Duration position, {type = 'seek'}) async {
    try {
      if (position < Duration.zero) {
        position = Duration.zero;
      }
      _position.value = position;
      updatePositionSecond();
      _heartDuration = position.inSeconds;
      if (duration.value.inSeconds != 0) {
        if (type != 'slider') {
          await _videoPlayerController?.stream.buffer.first;
        }
        await _seekPlayer(position);
      } else {
        _timerForSeek?.cancel();
        _timerForSeek ??= _startSeekTimer(position);
      }
    } catch (err) {
      print('Error while seeking: $err');
    }
  }

  Timer? _startSeekTimer(Duration position) {
    return Timer.periodic(const Duration(milliseconds: 200), (Timer t) async {
      if (duration.value.inSeconds != 0) {
        await _videoPlayerController!.stream.buffer.first;
        await _seekPlayer(position);
        t.cancel();
        _timerForSeek = null;
      }
    });
  }

  Future<void> _seekPlayer(Duration position) async {
    final attachment = realtimeCaptions.beginSeek();
    Duration? actualTarget;
    try {
      await _videoPlayerController?.seek(position);
      actualTarget = position;
    } finally {
      realtimeCaptions.endSeek(attachment, actualTarget);
    }
  }

  /// 设置倍速
  Future<void> setPlaybackSpeed(double speed) async {
    /// TODO  _duration.value丢失
    await _videoPlayerController?.setRate(speed);
    try {
      DanmakuOption currentOption = danmakuController!.option;
      defaultDuration ??= currentOption.duration;
      DanmakuOption updatedOption = currentOption.copyWith(
          duration: (defaultDuration! / speed) * playbackSpeed);
      danmakuController!.updateOption(updatedOption);
    } catch (_) {}
    // fix 长按倍速后放开不恢复
    if (!doubleSpeedStatus.value) {
      _playbackSpeed.value = speed;
    }
  }

  // 还原默认速度
  Future<void> setDefaultSpeed() async {
    double speed =
        videoStorage.get(VideoBoxKey.playSpeedDefault, defaultValue: 1.0);
    await _videoPlayerController?.setRate(speed);
    _playbackSpeed.value = speed;
  }

  /// 播放视频
  /// TODO  _duration.value丢失
  Future<void> play(
      {bool repeat = false, bool hideControls = true, dynamic duration}) async {
    // 播放时自动隐藏控制条
    controls = !hideControls;
    // repeat为true，将从头播放
    if (repeat) {
      await seekTo(Duration.zero);
    }
    await _videoPlayerController?.play();
    playerStatus.status.value = PlayerStatus.playing;
    await getCurrentVolume();
    await getCurrentBrightness();

    // screenManager.setOverlays(false);

    /// 临时fix _duration.value丢失
    if (duration != null) {
      _duration.value = duration;
      updateDurationSecond();
    }
    audioSessionHandler.setActive(true);
  }

  /// 暂停播放
  Future<void> pause({bool notify = true, bool isInterrupt = false}) async {
    await _videoPlayerController?.pause();
    playerStatus.status.value = PlayerStatus.paused;

    // 主动暂停时让出音频焦点
    if (!isInterrupt) {
      audioSessionHandler.setActive(false);
    }
  }

  /// 更改播放状态
  Future<void> togglePlay() async {
    feedBack();
    if (playerStatus.playing) {
      pause();
    } else {
      play();
    }
  }

  /// 隐藏控制条
  void _hideTaskControls() {
    if (_timer != null) {
      _timer!.cancel();
    }
    _timer = Timer(const Duration(milliseconds: 3000), () {
      if (!isSliderMoving.value) {
        controls = false;
      }
      _timer = null;
    });
  }

  /// 调整播放时间
  onChangedSlider(double v) {
    _sliderPosition.value = Duration(seconds: v.floor());
    updateSliderPositionSecond();
  }

  void onChangedSliderStart() {
    _isSliderMoving.value = true;
  }

  void onUpdatedSliderProgress(Duration value) {
    _sliderTempPosition.value = value;
    _sliderPosition.value = value;
    updateSliderPositionSecond();
  }

  void onChangedSliderEnd() {
    feedBack();
    _isSliderMoving.value = false;
    _hideTaskControls();
  }

  /// 音量
  Future<void> getCurrentVolume() async {
    // mac try...catch
    try {
      _currentVolume.value = (await FlutterVolumeController.getVolume())!;
    } catch (_) {}
  }

  Future<void> setVolume(double volumeNew,
      {bool videoPlayerVolume = false}) async {
    if (volumeNew < 0.0) {
      volumeNew = 0.0;
    } else if (volumeNew > 1.0) {
      volumeNew = 1.0;
    }
    if (volume.value == volumeNew) {
      return;
    }
    volume.value = volumeNew;

    try {
      FlutterVolumeController.updateShowSystemUI(false);
      await FlutterVolumeController.setVolume(volumeNew);
    } catch (err) {
      print(err);
    }
  }

  void volumeUpdated() {
    showVolumeStatus.value = true;
    _timerForShowingVolume?.cancel();
    _timerForShowingVolume = Timer(const Duration(seconds: 1), () {
      showVolumeStatus.value = false;
    });
  }

  /// 亮度
  Future<void> getCurrentBrightness() async {
    try {
      _currentBrightness.value = await ScreenBrightness().current;
    } catch (e) {
      throw 'Failed to get current brightness';
      //return 0;
    }
  }

  Future<void> setBrightness(double brightnes) async {
    try {
      brightness.value = brightnes;
      ScreenBrightness().setScreenBrightness(brightnes);
      // setVideoBrightness();
    } catch (e) {
      throw 'Failed to set brightness';
    }
  }

  Future<void> resetBrightness() async {
    try {
      await ScreenBrightness().resetScreenBrightness();
    } catch (e) {
      throw 'Failed to reset brightness';
    }
  }

  /// Toggle Change the videofit accordingly
  void toggleVideoFit() {
    showDialog(
      context: Get.context!,
      builder: (context) {
        return AlertDialog(
          title: const Text('画面比例'),
          content: StatefulBuilder(builder: (context, StateSetter setState) {
            return Wrap(
              alignment: WrapAlignment.start,
              spacing: 8,
              runSpacing: 2,
              children: [
                for (var i in videoFitType) ...[
                  if (_videoFit.value == i['attr']) ...[
                    FilledButton(
                      onPressed: () async {
                        _videoFit.value = i['attr'];
                        _videoFitDesc.value = i['desc'];
                        setVideoFit();
                        Get.back();
                      },
                      child: Text(i['desc']),
                    ),
                  ] else ...[
                    FilledButton.tonal(
                      onPressed: () async {
                        _videoFit.value = i['attr'];
                        _videoFitDesc.value = i['desc'];
                        setVideoFit();
                        Get.back();
                      },
                      child: Text(i['desc']),
                    ),
                  ]
                ]
              ],
            );
          }),
        );
      },
    );
  }

  /// 缓存fit
  Future<void> setVideoFit() async {
    List attrs = videoFitType.map((e) => e['attr']).toList();
    int index = attrs.indexOf(_videoFit.value);
    videoStorage.put(VideoBoxKey.cacheVideoFit, index);
  }

  /// 读取fit
  Future<void> getVideoFit() async {
    int fitValue = videoStorage.get(VideoBoxKey.cacheVideoFit, defaultValue: 0);
    _videoFit.value = videoFitType[fitValue]['attr'];
    _videoFitDesc.value = videoFitType[fitValue]['desc'];
  }

  /// 读取亮度
  // Future<void> getVideoBrightness() async {
  //   double brightnessValue =
  //       videoStorage.get(VideoBoxKey.videoBrightness, defaultValue: 0.5);
  //   setBrightness(brightnessValue);
  // }

  set controls(bool visible) {
    _showControls.value = visible;
    _timer?.cancel();
    if (visible) {
      _hideTaskControls();
    }
  }

  void hiddenControls(bool val) {
    showControls.value = val;
  }

  /// 设置长按倍速状态 live模式下禁用
  void setDoubleSpeedStatus(bool val) {
    if (videoType == 'live') {
      return;
    }
    if (controlsLock.value) {
      return;
    }
    _doubleSpeedStatus.value = val;
    if (val) {
      setPlaybackSpeed(
          enableAutoLongPressSpeed ? playbackSpeed * 2 : longPressSpeed);
    } else {
      print(playbackSpeed);
      setPlaybackSpeed(playbackSpeed);
    }
  }

  /// 关闭控制栏
  void onLockControl(bool val) {
    feedBack();
    _controlsLock.value = val;
    showControls.value = !val;
  }

  void toggleFullScreen(bool val) {
    _isFullScreen.value = val;
  }

  // 全屏
  /// [forceMode] 用于右下角双按钮：竖屏全屏传 vertical、横屏全屏传 horizontal，
  /// 不传则沿用用户在设置里的全屏模式（保持向后兼容，所有旧调用点无需改动）。
  Future<void> triggerFullScreen({
    bool? status,
    FullScreenMode? forceMode,
  }) async {
    final bool targetStatus = status ?? !isFullScreen.value;

    FullScreenMode mode = forceMode ??
        FullScreenModeCode.fromCode(
            setting.get(SettingBoxKey.fullScreenMode, defaultValue: 0))!;

    // 已在全屏、但按钮要求切换到另一种方向（竖屏 ↔ 横屏）：
    // 不退出全屏，只切换屏幕方向，实现两个按钮间平滑互切。
    if (targetStatus && isFullScreen.value && forceMode != null) {
      final bool wantVertical = mode == FullScreenMode.vertical ||
          (mode == FullScreenMode.auto && direction.value == 'vertical');
      if (wantVertical != _isVerticalFullScreen.value) {
        await _applyFullScreenDirection(wantVertical);
        return;
      }
    }

    if (targetStatus == isFullScreen.value) {
      return;
    }
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        await StatusBarControl.setHidden(targetStatus,
            animation: StatusBarAnimation.FADE);
      }
    } catch (_) {}

    if (targetStatus) {
      /// 按照视频宽高比（或按钮指定方向）决定全屏方向
      toggleFullScreen(true);

      /// 进入全屏
      final bool wantVertical = mode == FullScreenMode.vertical ||
          (mode == FullScreenMode.auto && direction.value == 'vertical');
      if (Platform.isAndroid || Platform.isIOS) {
        await enterFullScreen();
      }
      await _applyFullScreenDirection(wantVertical);
      // 桌面端（Windows / macOS / Linux）：
      // 铺满窗口（网页全屏/窗口全屏），保持画面宽高比，避免将整个系统窗口强行置为系统独占全屏
    } else {
      try {
        if (Platform.isAndroid || Platform.isIOS) {
          StatusBarControl.setHidden(false, animation: StatusBarAnimation.FADE);
        }
      } catch (_) {}
      if (Platform.isAndroid || Platform.isIOS) {
        await exitFullScreen();
        await verticalScreen();
      } else {
        if (_isNativeFullScreen.value) {
          await exitFullScreen();
          _isNativeFullScreen.value = false;
        }
      }
      toggleFullScreen(false);
      _isVerticalFullScreen.value = false;
    }
  }

  /// 应用全屏方向：竖屏全屏保持竖屏，横屏全屏旋转到横屏。
  /// 桌面端不旋转屏幕，仅记录方向状态用于按钮图标切换。
  Future<void> _applyFullScreenDirection(bool wantVertical) async {
    _isVerticalFullScreen.value = wantVertical;
    if (Platform.isAndroid || Platform.isIOS) {
      if (wantVertical) {
        await verticalScreen();
      } else {
        await landScape();
      }
    }
  }

  /// 桌面端切换系统级全屏 (如 F11)
  Future<void> toggleNativeFullScreen() async {
    if (Platform.isAndroid || Platform.isIOS) return;
    if (_isNativeFullScreen.value) {
      await exitFullScreen();
      _isNativeFullScreen.value = false;
    } else {
      await landScape();
      _isNativeFullScreen.value = true;
    }
  }

  void addPositionListener(Function(Duration position) listener) =>
      _positionListeners.add(listener);
  void removePositionListener(Function(Duration position) listener) =>
      _positionListeners.remove(listener);
  void addStatusLister(Function(PlayerStatus status) listener) =>
      _statusListeners.add(listener);
  void removeStatusLister(Function(PlayerStatus status) listener) =>
      _statusListeners.remove(listener);

  /// 截屏
  Future screenshot() async {
    final Uint8List? screenshot =
        await _videoPlayerController!.screenshot(format: 'image/png');
    return screenshot;
  }

  Future<void> videoPlayerClosed() async {
    _timer?.cancel();
    _timerForVolume?.cancel();
    _timerForGettingVolume?.cancel();
    timerForTrackingMouse?.cancel();
    _timerForSeek?.cancel();
    videoFitChangedTimer?.cancel();
  }

  // 记录播放记录
  Future makeHeartBeat(int progress, {type = 'playing'}) async {
    if (!_enableHeart) {
      return false;
    }
    if (videoType == 'live') {
      return;
    }
    // 播放状态变化时，更新
    if (type == 'status') {
      await VideoHttp.heartBeat(
        bvid: _bvid,
        cid: _cid,
        progress:
            playerStatus.status.value == PlayerStatus.completed ? -1 : progress,
      );
    } else
    // 正常播放时，间隔5秒更新一次
    if (progress - _heartDuration >= 5) {
      _heartDuration = progress;
      await VideoHttp.heartBeat(
        bvid: _bvid,
        cid: _cid,
        progress: progress,
      );
    }
  }

  setPlayRepeat(PlayRepeat type) {
    playRepeat = type;
    videoStorage.put(VideoBoxKey.playRepeat, type.value);
  }

  /// 缓存本次弹幕选项
  cacheDanmakuOption() {
    localCache.put(LocalCacheKey.danmakuBlockType, blockTypes);
    localCache.put(LocalCacheKey.danmakuShowArea, showArea);
    localCache.put(LocalCacheKey.danmakuOpacity, opacityVal);
    localCache.put(LocalCacheKey.danmakuFontScale, fontSizeVal);
    localCache.put(LocalCacheKey.danmakuDuration, danmakuDurationVal);
    localCache.put(LocalCacheKey.strokeWidth, strokeWidth);
  }

  Future<void> dispose({String type = 'single'}) async {
    _captionSourceRevision++;
    // 每次减1，最后销毁
    if (type == 'single' && playerCount.value > 1) {
      realtimeCaptions.detach();
      _playerCount.value -= 1;
      _heartDuration = 0;
      pause();
      return;
    }
    realtimeCaptions.dispose();
    _playerCount.value = 0;
    try {
      _timer?.cancel();
      _timerForVolume?.cancel();
      _timerForGettingVolume?.cancel();
      timerForTrackingMouse?.cancel();
      _timerForSeek?.cancel();
      videoFitChangedTimer?.cancel();
      await _cancelLocalDiagnostics();
      // _position.close();
      _playerEventSubs?.cancel();
      // _sliderPosition.close();
      // _sliderTempPosition.close();
      // _isSliderMoving.close();
      // _duration.close();
      // _buffered.close();
      // _showControls.close();
      // _controlsLock.close();
      // playerStatus.status.close();
      // dataStatus.status.close();

      /// 缓存本次弹幕选项
      cacheDanmakuOption();
      if (_videoPlayerController != null) {
        var pp = _videoPlayerController!.platform as NativePlayer;
        await pp.setProperty('audio-files', '');
        removeListeners();
        await _videoPlayerController?.dispose();
        _videoPlayerController = null;
      }
      // VideoController 与 Player 绑定，销毁 Player 后必须释放，
      // 否则下次播放本地文件时会复用旧配置，导致黑屏。
      _videoController = null;
      _instance = null;
      if (_isNativeFullScreen.value) {
        await exitFullScreen();
        _isNativeFullScreen.value = false;
      }
      // 关闭所有视频页面恢复亮度
      resetBrightness();
      videoPlayerServiceHandler.clear();
    } catch (err) {
      print(err);
    }
  }
}
