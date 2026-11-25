import 'dart:io';

import 'package:floating/floating.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:ns_danmaku/ns_danmaku.dart';
import 'package:pilipala/http/user.dart';
import 'package:pilipala/models/video/play/quality.dart';
import 'package:pilipala/models/video/play/url.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pilipala/pages/dlna/index.dart';
import 'package:pilipala/pages/video/detail/index.dart';
import 'package:pilipala/pages/video/detail/introduction/widgets/menu_row.dart';
import 'package:pilipala/plugin/pl_player/index.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_preferences.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_tts_dialog.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/ieeio_login.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/local_asr_model.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/offline_translation_manager.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/realtime_captions.dart';
import 'package:pilipala/utils/storage.dart';
import 'package:pilipala/services/shutdown_timer_service.dart';
import '../../../../http/danmaku.dart';
import '../../../../models/common/search_type.dart';
import '../../../../models/video_detail_res.dart';
import '../introduction/index.dart';

class HeaderControl extends StatefulWidget implements PreferredSizeWidget {
  const HeaderControl({
    this.controller,
    this.videoDetailCtr,
    this.floating,
    this.bvid,
    this.videoType,
    this.showSubtitleBtn,
    super.key,
  });
  final PlPlayerController? controller;
  final VideoDetailController? videoDetailCtr;
  final Floating? floating;
  final String? bvid;
  final SearchType? videoType;
  final bool? showSubtitleBtn;

  @override
  State<HeaderControl> createState() => _HeaderControlState();

  @override
  Size get preferredSize => throw UnimplementedError();
}

class _HeaderControlState extends State<HeaderControl> {
  late PlayUrlModel videoInfo;
  static const TextStyle subTitleStyle = TextStyle(fontSize: 12);
  static const TextStyle titleStyle = TextStyle(fontSize: 14);
  Size get preferredSize => const Size(double.infinity, kToolbarHeight);
  final Box<dynamic> localCache = GStrorage.localCache;
  final Box<dynamic> videoStorage = GStrorage.video;
  late List<double> speedsList;
  double buttonSpace = 8;
  RxBool isFullScreen = false.obs;
  late String heroTag;
  late VideoIntroController videoIntroController;
  late VideoDetailData videoDetail;

  @override
  void initState() {
    super.initState();
    videoInfo = widget.videoDetailCtr!.data;
    speedsList = widget.controller!.speedsList;
    fullScreenStatusListener();
    heroTag = Get.arguments['heroTag'];
    videoIntroController =
        Get.put(VideoIntroController(bvid: widget.bvid!), tag: heroTag);
  }

  void fullScreenStatusListener() {
    widget.videoDetailCtr!.plPlayerController.isFullScreen.listen((bool val) {
      isFullScreen.value = val;

      /// TODO setState() called after dispose()
      if (mounted) {
        setState(() {});
      }
    });
  }

  /// 设置面板
  void showSettingSheet() {
    showModalBottomSheet(
      elevation: 0,
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return Container(
          width: double.infinity,
          height: 460,
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
          ),
          margin: const EdgeInsets.all(12),
          child: Column(
            children: <Widget>[
              SizedBox(
                height: 35,
                child: Center(
                  child: Container(
                    width: 32,
                    height: 3,
                    decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .onSecondaryContainer
                            .withOpacity(0.5),
                        borderRadius:
                            const BorderRadius.all(Radius.circular(3))),
                  ),
                ),
              ),
              Expanded(
                  child: Material(
                child: ListView(
                  children: [
                    // ListTile(
                    //   onTap: () {},
                    //   dense: true,
                    //   enabled: false,
                    //   leading:
                    //       const Icon(Icons.network_cell_outlined, size: 20),
                    //   title: Text('省流模式', style: titleStyle),
                    //   subtitle: Text('低画质 ｜ 减少视频缓存', style: subTitleStyle),
                    //   trailing: Transform.scale(
                    //     scale: 0.75,
                    //     child: Switch(
                    //       thumbIcon: MaterialStateProperty.resolveWith<Icon?>(
                    //           (Set<MaterialState> states) {
                    //         if (states.isNotEmpty &&
                    //             states.first == MaterialState.selected) {
                    //           return const Icon(Icons.done);
                    //         }
                    //         return null; // All other states will use the default thumbIcon.
                    //       }),
                    //       value: false,
                    //       onChanged: (value) => {},
                    //     ),
                    //   ),
                    // ),
                    ListTile(
                      onTap: () async {
                        final res = await UserHttp.toViewLater(
                            bvid: widget.videoDetailCtr!.bvid);
                        SmartDialog.showToast(res['msg']);
                        Get.back();
                      },
                      dense: true,
                      leading: const Icon(Icons.watch_later_outlined, size: 20),
                      title: const Text('添加至「稍后再看」', style: titleStyle),
                    ),
                    ListTile(
                      onTap: () => {Get.back(), scheduleExit()},
                      dense: true,
                      leading:
                          const Icon(Icons.hourglass_top_outlined, size: 20),
                      title: const Text('定时关闭', style: titleStyle),
                    ),
                    ListTile(
                      onTap: () => {Get.back(), showSetVideoQa()},
                      dense: true,
                      leading: const Icon(Icons.play_circle_outline, size: 20),
                      title: const Text('选择画质', style: titleStyle),
                      subtitle: Text(
                          '当前画质 ${widget.videoDetailCtr!.currentVideoQa.description}',
                          style: subTitleStyle),
                    ),
                    if (widget.videoDetailCtr!.currentAudioQa != null)
                      ListTile(
                        onTap: () => {Get.back(), showSetAudioQa()},
                        dense: true,
                        leading: const Icon(Icons.album_outlined, size: 20),
                        title: const Text('选择音质', style: titleStyle),
                        subtitle: Text(
                            '当前音质 ${widget.videoDetailCtr!.currentAudioQa!.description}',
                            style: subTitleStyle),
                      ),
                    ListTile(
                      onTap: () {
                        Get.back();
                        showSubtitleSettingSheet();
                      },
                      dense: true,
                      leading:
                          const Icon(Icons.closed_caption_outlined, size: 20),
                      title: const Text('字幕与语音识别设置', style: titleStyle),
                      subtitle: Text(
                        widget.controller?.realtimeCaptions.enabled == true
                            ? '已开启'
                            : '已关闭',
                        style: subTitleStyle,
                      ),
                    ),
                    if (widget.videoDetailCtr!.currentDecodeFormats != null)
                      ListTile(
                        onTap: () => {Get.back(), showSetDecodeFormats()},
                        dense: true,
                        leading: const Icon(Icons.av_timer_outlined, size: 20),
                        title: const Text('解码格式', style: titleStyle),
                        subtitle: Text(
                            '当前解码格式 ${widget.videoDetailCtr!.currentDecodeFormats!.description}',
                            style: subTitleStyle),
                      ),
                    ListTile(
                      onTap: () => {Get.back(), showSetRepeat()},
                      dense: true,
                      leading: const Icon(Icons.repeat, size: 20),
                      title: const Text('播放顺序', style: titleStyle),
                      subtitle: Text(widget.controller!.playRepeat.description,
                          style: subTitleStyle),
                    ),
                    ListTile(
                      onTap: () => {Get.back(), showSetDanmaku()},
                      dense: true,
                      leading: const Icon(Icons.subtitles_outlined, size: 20),
                      title: const Text('弹幕设置', style: titleStyle),
                    ),
                  ],
                ),
              ))
            ],
          ),
        );
      },
      clipBehavior: Clip.hardEdge,
      isScrollControlled: true,
    );
  }

  /// 发送弹幕
  void showShootDanmakuSheet() {
    final TextEditingController textController = TextEditingController();
    bool isSending = false; // 追踪是否正在发送
    showDialog(
      context: Get.context!,
      builder: (BuildContext context) {
        // TODO: 支持更多类型和颜色的弹幕
        return AlertDialog(
          title: const Text('发送弹幕（测试）'),
          content: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
            return TextField(
              controller: textController,
            );
          }),
          actions: [
            TextButton(
              onPressed: () => Get.back(),
              child: Text(
                '取消',
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            ),
            StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) {
              return TextButton(
                onPressed: isSending
                    ? null
                    : () async {
                        final String msg = textController.text;
                        if (msg.isEmpty) {
                          SmartDialog.showToast('弹幕内容不能为空');
                          return;
                        } else if (msg.length > 100) {
                          SmartDialog.showToast('弹幕内容不能超过100个字符');
                          return;
                        }
                        setState(() {
                          isSending = true; // 开始发送，更新状态
                        });
                        //修改按钮文字
                        final dynamic res = await DanmakaHttp.shootDanmaku(
                          oid: widget.videoDetailCtr!.cid.value,
                          msg: textController.text,
                          bvid: widget.videoDetailCtr!.bvid,
                          progress:
                              widget.controller!.position.value.inMilliseconds,
                          type: 1,
                        );
                        setState(() {
                          isSending = false; // 发送结束，更新状态
                        });
                        if (res['status']) {
                          SmartDialog.showToast('发送成功');
                          // 发送成功，自动预览该弹幕，避免重新请求
                          // TODO: 暂停状态下预览弹幕仍会移动与计时，可考虑添加到dmSegList或其他方式实现
                          widget.controller!.danmakuController!.addItems([
                            DanmakuItem(
                              msg,
                              color: Colors.white,
                              time: widget
                                  .controller!.position.value.inMilliseconds,
                              type: DanmakuItemType.scroll,
                              isSend: true,
                            )
                          ]);
                          Get.back();
                        } else {
                          SmartDialog.showToast('发送失败，错误信息为${res['msg']}');
                        }
                      },
                child: Text(isSending ? '发送中...' : '发送'),
              );
            })
          ],
        );
      },
    );
  }

  /// 定时关闭
  void scheduleExit() async {
    const List<int> scheduleTimeChoices = [
      -1,
      15,
      30,
      60,
    ];
    showModalBottomSheet(
      context: context,
      elevation: 0,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
          return Container(
            width: double.infinity,
            height: 500,
            clipBehavior: Clip.hardEdge,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.all(Radius.circular(12)),
            ),
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.only(left: 14, right: 14),
            child: SingleChildScrollView(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 0, horizontal: 20),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const SizedBox(height: 30),
                      const Center(child: Text('定时关闭', style: titleStyle)),
                      const SizedBox(height: 10),
                      for (final int choice in scheduleTimeChoices) ...<Widget>[
                        ListTile(
                          onTap: () {
                            shutdownTimerService.scheduledExitInMinutes =
                                choice;
                            shutdownTimerService.startShutdownTimer();
                            Get.back();
                          },
                          contentPadding: const EdgeInsets.only(),
                          dense: true,
                          title: Text(choice == -1 ? "禁用" : "$choice分钟后"),
                          trailing: shutdownTimerService
                                      .scheduledExitInMinutes ==
                                  choice
                              ? Icon(
                                  Icons.done,
                                  color: Theme.of(context).colorScheme.primary,
                                )
                              : const SizedBox(),
                        )
                      ],
                      const SizedBox(height: 6),
                      const Center(
                          child: SizedBox(
                        width: 100,
                        child: Divider(height: 1),
                      )),
                      const SizedBox(height: 10),
                      ListTile(
                        onTap: () {
                          shutdownTimerService.waitForPlayingCompleted =
                              !shutdownTimerService.waitForPlayingCompleted;
                          setState(() {});
                        },
                        dense: true,
                        contentPadding: const EdgeInsets.only(),
                        title: const Text("额外等待视频播放完毕", style: titleStyle),
                        trailing: Switch(
                          // thumb color (round icon)
                          activeColor: Theme.of(context).colorScheme.primary,
                          activeTrackColor:
                              Theme.of(context).colorScheme.primaryContainer,
                          inactiveThumbColor:
                              Theme.of(context).colorScheme.primaryContainer,
                          inactiveTrackColor:
                              Theme.of(context).colorScheme.surface,
                          splashRadius: 10.0,
                          // boolean variable value
                          value: shutdownTimerService.waitForPlayingCompleted,
                          // changes the state of the switch
                          onChanged: (value) => setState(() =>
                              shutdownTimerService.waitForPlayingCompleted =
                                  value),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: <Widget>[
                          const Text('倒计时结束:', style: titleStyle),
                          const Spacer(),
                          ActionRowLineItem(
                            onTap: () {
                              shutdownTimerService.exitApp = false;
                              setState(() {});
                              // Get.back();
                            },
                            text: " 暂停视频 ",
                            selectStatus: !shutdownTimerService.exitApp,
                          ),
                          const Spacer(),
                          // const SizedBox(width: 10),
                          ActionRowLineItem(
                            onTap: () {
                              shutdownTimerService.exitApp = true;
                              setState(() {});
                              // Get.back();
                            },
                            text: " 退出APP ",
                            selectStatus: shutdownTimerService.exitApp,
                          )
                        ],
                      ),
                    ]),
              ),
            ),
          );
        });
      },
    );
  }

  /// 图3与图4: 顶栏 CC 开关图标矢量绘制
  /// 开 (图3): 白色实心填充圆角矩形，黑色加粗 CC
  /// 关 (图4): 透明底白色边框圆角矩形，白色加粗 CC
  Widget _buildCcSwitchIcon(bool isEnabled) {
    if (isEnabled) {
      // 图3: 白底黑字 CC (开)
      return Container(
        width: 25,
        height: 19,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(3.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: const Text(
          'CC',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w900,
            fontSize: 11,
            height: 1.0,
            letterSpacing: -0.5,
          ),
        ),
      );
    } else {
      // 图4: 透明底白框白字 CC (关)
      return Container(
        width: 25,
        height: 19,
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(3.5),
          border: Border.all(
            color: Colors.white.withOpacity(0.9),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Text(
          'CC',
          style: TextStyle(
            color: Colors.white.withOpacity(0.95),
            fontWeight: FontWeight.w900,
            fontSize: 10.5,
            height: 1.0,
            letterSpacing: -0.5,
          ),
        ),
      );
    }
  }

  /// 字幕颜色选择色块：圆形色卡 + 选中勾 + 名称标签
  Widget _colorSwatch({
    required Color color,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.white.withOpacity(0.35),
                width: selected ? 2.5 : 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 3,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: selected
                ? Icon(
                    Icons.check,
                    size: 18,
                    color: color.computeLuminance() > 0.5
                        ? Colors.black87
                        : Colors.white,
                  )
                : null,
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
        ],
      ),
    );
  }

  void showSubtitleDialog() => showSubtitleSettingSheet();

  /// 字幕与语音识别设置 (二级底部面板，设计风格 100% 对齐弹幕设置 图2)
  void showSubtitleSettingSheet() async {
    final player = widget.controller!;
    final captions = player.realtimeCaptions;
    final preferences = player.captionPreferences;

    await showModalBottomSheet(
      context: context,
      elevation: 0,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            return Obx(() {
              final activeSource = captions.activeSourceType;
              final targetLang = captions.targetLanguage.value;
              final transEngine = captions.translationEngine.value;
              final chinesePhonetic = captions.chinesePhonetic.value;
              final japanesePhonetic = captions.japanesePhonetic.value;
              final appearance = preferences.appearance.value;
              final delayMs = captions.captionDelayMs.value;

              return Container(
                width: double.infinity,
                height: 590,
                clipBehavior: Clip.hardEdge,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: const BorderRadius.all(Radius.circular(12)),
                ),
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.only(left: 14, right: 14),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(
                        height: 45,
                        child: Center(
                          child: Text('字幕与语音识别设置', style: titleStyle),
                        ),
                      ),
                      const SizedBox(height: 10),

                      // 1. 识别与字幕源 (3 选 1)
                      const Text('识别与字幕源'),
                      Padding(
                        padding: const EdgeInsets.only(top: 10, bottom: 16),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              ActionRowLineItem(
                                text: 'B站官方',
                                selectStatus: activeSource == 'official',
                                onTap: () {
                                  captions.switchSubtitleSource('official');
                                  setState(() {});
                                },
                              ),
                              const SizedBox(width: 10),
                              ActionRowLineItem(
                                text: 'Sherpa 本地离线',
                                selectStatus: activeSource == 'sherpa',
                                onTap: () {
                                  captions.switchSubtitleSource('sherpa');
                                  setState(() {});
                                },
                              ),
                              const SizedBox(width: 10),
                              ActionRowLineItem(
                                text: '云端在线',
                                selectStatus: activeSource == 'qwen',
                                onTap: () {
                                  captions.switchSubtitleSource('qwen');
                                  setState(() {});
                                },
                              ),
                            ],
                          ),
                        ),
                      ),

                      // 若选择 Sherpa 本地离线识别，展示离线模型配置
                      if (activeSource == 'sherpa') ...[
                        _asrEngineSettings(captions),
                        const SizedBox(height: 12),
                      ],

                      // 若选择云端在线识别，展示在线引擎配置（微软免Key/豆包2.0/Deepgram/Qwen）
                      if (activeSource == 'qwen') ...[
                        _OnlineAsrSettingsWidget(captions: captions),
                        const SizedBox(height: 12),
                      ],

                      // 字幕框显示行数 Slider (2 - 6 行，决定字幕滚动窗口高度)
                      Text(preferences.sentenceMaxLines.value == 2
                          ? '字幕显示：两行滚动'
                          : '字幕框显示行数 ${preferences.sentenceMaxLines.value} 行'),
                      Padding(
                        padding: const EdgeInsets.only(
                            top: 0, bottom: 6, left: 10, right: 10),
                        child: SliderTheme(
                          data: SliderThemeData(
                            trackShape: MSliderTrackShape(),
                            thumbColor: Theme.of(context).colorScheme.primary,
                            activeTrackColor:
                                Theme.of(context).colorScheme.primary,
                            trackHeight: 10,
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6.0),
                          ),
                          child: Slider(
                            min: 2.0,
                            max: 6.0,
                            value: preferences.sentenceMaxLines.value
                                .toDouble()
                                .clamp(2.0, 6.0),
                            divisions: 4,
                            label: '${preferences.sentenceMaxLines.value} 行',
                            onChanged: (double val) {
                              preferences.setSentenceMaxLines(val.round());
                              setState(() {});
                            },
                          ),
                        ),
                      ),

                      // 3. 目标翻译语言
                      const Text('目标翻译语言'),
                      Padding(
                        padding: const EdgeInsets.only(top: 10, bottom: 16),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final lang in [
                                {'code': 'zh-CN', 'label': '简体中文'},
                                {'code': 'en', 'label': 'English'},
                                {'code': 'ja', 'label': '日本語'},
                                {'code': 'zh-TW', 'label': '繁體中文'},
                                {'code': 'yue', 'label': '粤语'},
                              ]) ...[
                                ActionRowLineItem(
                                  text: lang['label'],
                                  selectStatus: targetLang == lang['code'],
                                  onTap: () {
                                    captions.setTargetLanguage(lang['code']!);
                                    setState(() {});
                                  },
                                ),
                                const SizedBox(width: 10),
                              ],
                            ],
                          ),
                        ),
                      ),

                      // 4. 翻译引擎
                      const Text('翻译引擎'),
                      Padding(
                        padding: const EdgeInsets.only(top: 10, bottom: 16),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final eng in [
                                {'code': 'microsoft', 'label': '微软 Edge'},
                                {'code': 'google', 'label': 'Google 翻译'},
                                {'code': 'local', 'label': '本地离线翻译'},
                              ]) ...[
                                ActionRowLineItem(
                                  text: eng['label'],
                                  selectStatus: transEngine == eng['code'],
                                  onTap: () {
                                    captions.setTranslationEngine(eng['code']!);
                                    setState(() {});
                                  },
                                ),
                                const SizedBox(width: 10),
                              ],
                            ],
                          ),
                        ),
                      ),

                      // 若选择本地离线翻译，展示离线词库包管理
                      if (transEngine == 'local') ...[
                        _translationOfflinePackageSettings(captions),
                        const SizedBox(height: 12),
                      ],

                      // 5. 中文/粤语发音注音
                      const Text('中文/粤语注音'),
                      Padding(
                        padding: const EdgeInsets.only(top: 10, bottom: 16),
                        child: Row(
                          children: [
                            for (final ph in [
                              {'code': 'auto', 'label': '智能识别'},
                              {'code': 'mandarin', 'label': '普通话拼音'},
                              {'code': 'cantonese', 'label': '粤拼'},
                            ]) ...[
                              ActionRowLineItem(
                                text: ph['label'],
                                selectStatus: chinesePhonetic == ph['code'],
                                onTap: () {
                                  captions.setChinesePhonetic(ph['code']!);
                                  setState(() {});
                                },
                              ),
                              const SizedBox(width: 10),
                            ],
                          ],
                        ),
                      ),

                      // 6. 日语注音类型
                      const Text('日语注音类型'),
                      Padding(
                        padding: const EdgeInsets.only(top: 10, bottom: 16),
                        child: Row(
                          children: [
                            for (final jp in [
                              {'code': 'kana', 'label': '振假名 (Kana)'},
                              {'code': 'romaji', 'label': '罗马音 (Romaji)'},
                            ]) ...[
                              ActionRowLineItem(
                                text: jp['label'],
                                selectStatus: japanesePhonetic == jp['code'],
                                onTap: () {
                                  captions.setJapanesePhonetic(jp['code']!);
                                  setState(() {});
                                },
                              ),
                              const SizedBox(width: 10),
                            ],
                          ],
                        ),
                      ),

                      // 7. 字体大小 Slider (图2 弹幕设置样式)
                      Text('字体大小 ${appearance.fontSize.toStringAsFixed(1)}'),
                      Padding(
                        padding: const EdgeInsets.only(
                            top: 0, bottom: 6, left: 10, right: 10),
                        child: SliderTheme(
                          data: SliderThemeData(
                            trackShape: MSliderTrackShape(),
                            thumbColor: Theme.of(context).colorScheme.primary,
                            activeTrackColor:
                                Theme.of(context).colorScheme.primary,
                            trackHeight: 10,
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6.0),
                          ),
                          child: Slider(
                            min: 8.0,
                            max: 24.0,
                            value: appearance.fontSize.clamp(8.0, 24.0),
                            divisions: 16,
                            label: appearance.fontSize.toStringAsFixed(0),
                            onChanged: (double val) {
                              preferences.update(fontSize: val);
                              preferences.save();
                              setState(() {});
                            },
                          ),
                        ),
                      ),

                      Text('注音字号 ${appearance.pronunciationFontSize.toStringAsFixed(0)}'),
                      Slider(
                        min: 6, max: 16, divisions: 10,
                        value: appearance.pronunciationFontSize.clamp(6.0, 16.0),
                        label: appearance.pronunciationFontSize.toStringAsFixed(0),
                        onChanged: (value) {
                          preferences.update(pronunciationFontSize: value);
                          preferences.save();
                          setState(() {});
                        },
                      ),

                      // 8. 背景颜色
                      const Text('背景颜色'),
                      Padding(
                        padding: const EdgeInsets.only(top: 10, bottom: 12),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final entry
                                  in CaptionPreferences.backgroundColors.entries) ...[
                                _colorSwatch(
                                  color: Color(entry.key),
                                  label: entry.value,
                                  selected:
                                      appearance.backgroundColor == entry.key,
                                  onTap: () {
                                    preferences.update(
                                        backgroundColor: entry.key);
                                    preferences.save();
                                    setState(() {});
                                  },
                                ),
                                const SizedBox(width: 10),
                              ],
                            ],
                          ),
                        ),
                      ),

                      // 9. 字体颜色
                      const Text('字体颜色'),
                      Padding(
                        padding: const EdgeInsets.only(top: 10, bottom: 12),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final entry
                                  in CaptionPreferences.captionColors.entries) ...[
                                _colorSwatch(
                                  color: Color(entry.key),
                                  label: entry.value,
                                  selected: appearance.captionColor == entry.key,
                                  onTap: () {
                                    preferences.update(captionColor: entry.key);
                                    preferences.save();
                                    setState(() {});
                                  },
                                ),
                                const SizedBox(width: 10),
                              ],
                            ],
                          ),
                        ),
                      ),

                      // 10. 背景不透明度 Slider (图2 弹幕设置样式)
                      Text(
                          '背景不透明度 ${(appearance.backgroundOpacity * 100).toInt()}%'),
                      Padding(
                        padding: const EdgeInsets.only(
                            top: 0, bottom: 6, left: 10, right: 10),
                        child: SliderTheme(
                          data: SliderThemeData(
                            trackShape: MSliderTrackShape(),
                            thumbColor: Theme.of(context).colorScheme.primary,
                            activeTrackColor:
                                Theme.of(context).colorScheme.primary,
                            trackHeight: 10,
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6.0),
                          ),
                          child: Slider(
                            min: 0.0,
                            max: 1.0,
                            value: appearance.backgroundOpacity.clamp(0.0, 1.0),
                            divisions: 10,
                            label:
                                '${(appearance.backgroundOpacity * 100).toInt()}%',
                            onChanged: (double val) {
                              preferences.update(backgroundOpacity: val);
                              preferences.save();
                              setState(() {});
                            },
                          ),
                        ),
                      ),

                      // 9. 时间轴同步微调
                      Text(
                          '时间轴同步校准 (${delayMs == 0 ? "正常 0ms" : "${delayMs > 0 ? "+" : ""}${delayMs}ms"})'),
                      Padding(
                        padding: const EdgeInsets.only(top: 10, bottom: 16),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final d in [
                                {'ms': -1000, 'label': '-1.0s'},
                                {'ms': -500, 'label': '-0.5s'},
                                {'ms': 0, 'label': '正常 (0s)'},
                                {'ms': 500, 'label': '+0.5s'},
                                {'ms': 1000, 'label': '+1.0s'},
                              ]) ...[
                                ActionRowLineItem(
                                  text: d['label'] as String,
                                  selectStatus: delayMs == d['ms'],
                                  onTap: () {
                                    captions.setCaptionDelay(d['ms'] as int);
                                    setState(() {});
                                  },
                                ),
                                const SizedBox(width: 10),
                              ],
                            ],
                          ),
                        ),
                      ),

                      // 11. 高级与诊断工具
                      const Text('高级工具与诊断'),
                      Padding(
                        padding: const EdgeInsets.only(top: 10, bottom: 24),
                        child: Row(
                          children: [
                            ActionRowLineItem(
                              text: '查词发音人',
                              selectStatus: false,
                              onTap: () => showTtsVoiceSettingsDialog(context),
                            ),
                            const SizedBox(width: 10),
                            ActionRowLineItem(
                              text: '复制诊断信息',
                              selectStatus: false,
                              onTap: () async {
                                await Clipboard.setData(
                                  ClipboardData(text: captions.asrDiagnostics),
                                );
                                SmartDialog.showToast('已复制字幕诊断信息');
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            });
          },
        );
      },
    );
  }

  Widget _translationOfflinePackageSettings(RealtimeCaptions captions) {
    final transMgr = OfflineTranslationManager.shared;
    final selectedPkgId = transMgr.currentPackageId.value;
    final pkg = OfflineTranslationManager.availablePackages[selectedPkgId] ??
        OfflineTranslationManager.availablePackages['en_zh_subtitles']!;
    final isDownloading = transMgr.isDownloading.value;
    final progress = transMgr.downloadProgress.value;
    final status = transMgr.downloadStatus.value;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('离线语言包: ', style: TextStyle(fontSize: 13)),
              const Spacer(),
              DropdownButton<String>(
                value: selectedPkgId,
                isDense: true,
                items: OfflineTranslationManager.availablePackages.values
                    .map((p) => DropdownMenuItem(
                          value: p.id,
                          child: Text(p.name,
                              style: const TextStyle(fontSize: 12)),
                        ))
                    .toList(),
                onChanged: (id) async {
                  if (id != null) {
                    transMgr.setCurrentPackage(id);
                    await transMgr.isPackageReady(id);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  pkg.tag,
                  style: const TextStyle(
                      fontSize: 10,
                      color: Colors.green,
                      fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  pkg.languagesDesc,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FutureBuilder<bool>(
            future: transMgr.isPackageReady(selectedPkgId),
            builder: (ctx, snapshot) {
              final isReady = snapshot.data ?? true;
              return Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isReady
                      ? Colors.green.withOpacity(0.08)
                      : Colors.orange.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isReady
                        ? Colors.green.withOpacity(0.25)
                        : Colors.orange.withOpacity(0.25),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      isReady
                          ? Icons.check_circle_rounded
                          : Icons.info_outline_rounded,
                      size: 16,
                      color: isReady ? Colors.green : Colors.orange,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        isReady
                            ? '已就绪 (内置基础与高频词句库 · 0延迟)'
                            : '未装载离线包 (使用内置基础语料)',
                        style: TextStyle(
                          fontSize: 11,
                          color: isReady ? Colors.green : Colors.orange,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (isDownloading)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.refresh_rounded, size: 14),
                        label:
                            const Text('重新校验', style: TextStyle(fontSize: 11)),
                        onPressed: () async {
                          await transMgr.downloadPackage(
                              packageId: selectedPkgId);
                          SmartDialog.showToast('${pkg.name} 已重新装载就绪');
                        },
                      ),
                  ],
                ),
              );
            },
          ),
          if (isDownloading) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                  value: progress > 0 ? progress : null),
            ),
            if (status.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                status,
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _asrEngineSettings(RealtimeCaptions captions) {
    final modelMgr = LocalAsrModelManager.shared;
    return Obx(() {
      final selectedModelId = captions.localAsrModel.value;
      final selectedModel =
          LocalAsrModelManager.availableModels[selectedModelId] ??
              LocalAsrModelManager.availableModels['sense_voice']!;

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                const Text('离线模型: ', style: TextStyle(fontSize: 13)),
                const Spacer(),
                DropdownButton<String>(
                  value: selectedModelId,
                  isDense: true,
                  items: LocalAsrModelManager.availableModels.values
                      .map((cfg) => DropdownMenuItem(
                            value: cfg.id,
                            child: Text(
                              '${cfg.name} (${cfg.sizeDesc})',
                              style: const TextStyle(fontSize: 13),
                            ),
                          ))
                      .toList(),
                  onChanged: (id) {
                    if (id != null) {
                      captions.setLocalAsrModel(id);
                    }
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    selectedModel.engineTag,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    selectedModel.languagesDesc,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
          FutureBuilder<bool>(
            key: ValueKey(selectedModelId),
            future: modelMgr.isModelReady(selectedModelId),
            builder: (context, snapshot) {
              final isReady = snapshot.data ?? false;
              return Obx(() {
                final isDownloading = modelMgr.isDownloading.value;
                final progress = modelMgr.downloadProgress.value;
                final status = modelMgr.downloadStatus.value;
                return Container(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceVariant
                        .withOpacity(0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isReady ? Icons.check_circle : Icons.info_outline,
                            color: isReady ? Colors.green : Colors.orange,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              isReady
                                  ? '${selectedModel.name} 已就绪 (可离线运行)'
                                  : '${selectedModel.name} 未就绪 (${selectedModel.sizeDesc})',
                              style: const TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.w500),
                            ),
                          ),
                          if (isDownloading)
                            TextButton(
                              onPressed: modelMgr.cancelDownload,
                              child: const Text('取消'),
                            )
                          else ...[
                            if (isReady)
                              IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    size: 18, color: Colors.grey),
                                tooltip: '删除模型以释放空间',
                                onPressed: () async {
                                  await modelMgr.deleteModel(selectedModelId);
                                  SmartDialog.showToast(
                                      '已删除 ${selectedModel.name} 本地文件');
                                  captions.retry();
                                },
                              ),
                            FilledButton.tonal(
                              style: FilledButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 10),
                              ),
                              onPressed: () async {
                                try {
                                  await modelMgr.downloadModel(
                                      modelId: selectedModelId);
                                  SmartDialog.showToast(
                                      '${selectedModel.name} 下载完成');
                                  captions.retry();
                                } catch (e) {
                                  SmartDialog.showToast('下载失败: $e');
                                }
                              },
                              child: Text(isReady ? '重新下载' : '立即下载',
                                  style: const TextStyle(fontSize: 12)),
                            ),
                          ],
                        ],
                      ),
                      if (isDownloading) ...[
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(value: progress),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          status,
                          style:
                              const TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                      ],
                    ],
                  ),
                );
              });
            },
          ),
        ],
      );
    });
  }

  Widget _onlineAsrSettings(RealtimeCaptions captions) {
    return _OnlineAsrSettingsWidget(captions: captions);
  }

  /// 选择倍速
  void showSetSpeedSheet() {
    final double currentSpeed = widget.controller!.playbackSpeed;
    showDialog(
      context: Get.context!,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('播放速度'),
          content: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
            return Wrap(
              spacing: 8,
              runSpacing: 2,
              children: [
                for (final double i in speedsList) ...<Widget>[
                  if (i == currentSpeed) ...<Widget>[
                    FilledButton(
                      onPressed: () async {
                        // setState(() => currentSpeed = i),
                        await widget.controller!.setPlaybackSpeed(i);
                        Get.back();
                      },
                      child: Text(i.toString()),
                    ),
                  ] else ...[
                    FilledButton.tonal(
                      onPressed: () async {
                        // setState(() => currentSpeed = i),
                        await widget.controller!.setPlaybackSpeed(i);
                        Get.back();
                      },
                      child: Text(i.toString()),
                    ),
                  ]
                ]
              ],
            );
          }),
          actions: <Widget>[
            TextButton(
              onPressed: () => Get.back(),
              child: Text(
                '取消',
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            ),
            TextButton(
              onPressed: () async {
                await widget.controller!.setDefaultSpeed();
                Get.back();
              },
              child: const Text('默认速度'),
            ),
          ],
        );
      },
    );
  }

  /// 选择画质
  void showSetVideoQa() {
    final List<FormatItem> videoFormat = videoInfo.supportFormats!;
    final VideoQuality currentVideoQa = widget.videoDetailCtr!.currentVideoQa;

    /// 总质量分类
    final int totalQaSam = videoFormat.length;

    /// 可用的质量分类
    int userfulQaSam = 0;
    if (videoInfo.dash != null) {
      // dash格式视频一次请求会返回所有可播放的清晰度video
      final List<VideoItem> video = videoInfo.dash!.video!;
      final Set<int> idSet = {};
      for (final VideoItem item in video) {
        final int id = item.id!;
        if (!idSet.contains(id)) {
          idSet.add(id);
          userfulQaSam++;
        }
      }
    }

    if (videoInfo.durl != null) {
      // durl格式视频一次请求返回对应清晰度video
      userfulQaSam = videoFormat.length - 1;
    }

    showModalBottomSheet(
      context: context,
      elevation: 0,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Container(
          width: double.infinity,
          height: 310,
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
          ),
          margin: const EdgeInsets.all(12),
          child: Column(
            children: <Widget>[
              SizedBox(
                height: 45,
                child: GestureDetector(
                  onTap: () {
                    SmartDialog.showToast('标灰画质可能需要bilibili会员');
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('选择画质', style: titleStyle),
                      SizedBox(width: buttonSpace),
                      Icon(
                        Icons.info_outline,
                        size: 16,
                        color: Theme.of(context).colorScheme.outline,
                      )
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Material(
                  child: Scrollbar(
                    child: ListView(
                      children: [
                        for (int i = 0; i < totalQaSam; i++) ...[
                          ListTile(
                            onTap: () {
                              if (currentVideoQa.code ==
                                  videoFormat[i].quality) {
                                return;
                              }
                              final int quality = videoFormat[i].quality!;
                              widget.videoDetailCtr!.currentVideoQa =
                                  VideoQualityCode.fromCode(quality)!;
                              widget.videoDetailCtr!.updatePlayer();
                              Get.back();
                            },
                            dense: true,
                            // 可能包含会员解锁画质
                            enabled: i >= totalQaSam - userfulQaSam,
                            contentPadding:
                                const EdgeInsets.only(left: 20, right: 20),
                            title: Text(videoFormat[i].newDesc!),
                            subtitle: Text(
                              videoFormat[i].format!,
                              style: subTitleStyle,
                            ),
                            trailing: currentVideoQa.code ==
                                    videoFormat[i].quality
                                ? Icon(
                                    Icons.done,
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                  )
                                : const SizedBox(),
                          ),
                        ]
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 选择音质
  void showSetAudioQa() {
    final AudioQuality currentAudioQa = widget.videoDetailCtr!.currentAudioQa!;
    final List<AudioItem> audio = videoInfo.dash!.audio!;
    showModalBottomSheet(
      context: context,
      elevation: 0,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Container(
          width: double.infinity,
          height: 250,
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
          ),
          margin: const EdgeInsets.all(12),
          child: Column(
            children: <Widget>[
              const SizedBox(
                  height: 45,
                  child: Center(child: Text('选择音质', style: titleStyle))),
              Expanded(
                child: Material(
                  child: ListView(
                    children: <Widget>[
                      for (final AudioItem i in audio) ...<Widget>[
                        ListTile(
                          onTap: () {
                            if (currentAudioQa.code == i.id) {
                              return;
                            }
                            final int quality = i.id!;
                            widget.videoDetailCtr!.currentAudioQa =
                                AudioQualityCode.fromCode(quality)!;
                            widget.videoDetailCtr!.updatePlayer();
                            Get.back();
                          },
                          dense: true,
                          contentPadding:
                              const EdgeInsets.only(left: 20, right: 20),
                          title: Text(i.quality!),
                          subtitle: Text(
                            i.codecs!,
                            style: subTitleStyle,
                          ),
                          trailing: currentAudioQa.code == i.id
                              ? Icon(
                                  Icons.done,
                                  color: Theme.of(context).colorScheme.primary,
                                )
                              : const SizedBox(),
                        ),
                      ]
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // 选择解码格式
  void showSetDecodeFormats() {
    // 当前选中的解码格式
    final VideoDecodeFormats currentDecodeFormats =
        widget.videoDetailCtr!.currentDecodeFormats!;
    final VideoItem firstVideo = widget.videoDetailCtr!.firstVideo;
    // 当前视频可用的解码格式
    final List<FormatItem> videoFormat = videoInfo.supportFormats!;
    final List list = videoFormat
        .firstWhere((FormatItem e) => e.quality == firstVideo.quality!.code)
        .codecs!;

    showModalBottomSheet(
      context: context,
      elevation: 0,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Container(
          width: double.infinity,
          height: 250,
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
          ),
          margin: const EdgeInsets.all(12),
          child: Column(
            children: [
              const SizedBox(
                height: 45,
                child: Center(
                  child: Text('选择解码格式', style: titleStyle),
                ),
              ),
              Expanded(
                child: Material(
                  child: ListView(
                    children: [
                      for (var i in list) ...[
                        ListTile(
                          onTap: () {
                            if (i.startsWith(currentDecodeFormats.code)) return;
                            widget.videoDetailCtr!.currentDecodeFormats =
                                VideoDecodeFormatsCode.fromString(i)!;
                            widget.videoDetailCtr!.updatePlayer();
                            Get.back();
                          },
                          dense: true,
                          contentPadding:
                              const EdgeInsets.only(left: 20, right: 20),
                          title: Text(VideoDecodeFormatsCode.fromString(i)!
                              .description!),
                          subtitle: Text(
                            i!,
                            style: subTitleStyle,
                          ),
                          trailing: i.startsWith(currentDecodeFormats.code)
                              ? Icon(
                                  Icons.done,
                                  color: Theme.of(context).colorScheme.primary,
                                )
                              : const SizedBox(),
                        ),
                      ]
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 弹幕功能
  void showSetDanmaku() async {
    // 屏蔽类型
    final List<Map<String, dynamic>> blockTypesList = [
      {'value': 5, 'label': '顶部'},
      {'value': 2, 'label': '滚动'},
      {'value': 4, 'label': '底部'},
      {'value': 6, 'label': '彩色'},
    ];
    final List blockTypes = widget.controller!.blockTypes;
    // 显示区域
    final List<Map<String, dynamic>> showAreas = [
      {'value': 0.25, 'label': '1/4屏'},
      {'value': 0.5, 'label': '半屏'},
      {'value': 0.75, 'label': '3/4屏'},
      {'value': 1.0, 'label': '满屏'},
    ];
    double showArea = widget.controller!.showArea;
    // 不透明度
    double opacityVal = widget.controller!.opacityVal;
    // 字体大小
    double fontSizeVal = widget.controller!.fontSizeVal;
    // 弹幕速度
    double danmakuDurationVal = widget.controller!.danmakuDurationVal;
    // 弹幕描边
    double strokeWidth = widget.controller!.strokeWidth;

    final DanmakuController danmakuController =
        widget.controller!.danmakuController!;
    await showModalBottomSheet(
      context: context,
      elevation: 0,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
          return Container(
            width: double.infinity,
            height: 580,
            clipBehavior: Clip.hardEdge,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.all(Radius.circular(12)),
            ),
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.only(left: 14, right: 14),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(
                    height: 45,
                    child: Center(child: Text('弹幕设置', style: titleStyle)),
                  ),
                  const SizedBox(height: 10),
                  const Text('按类型屏蔽'),
                  Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 18),
                    child: Row(
                      children: <Widget>[
                        for (final Map<String, dynamic> i
                            in blockTypesList) ...<Widget>[
                          ActionRowLineItem(
                            onTap: () async {
                              final bool isChoose =
                                  blockTypes.contains(i['value']);
                              if (isChoose) {
                                blockTypes.remove(i['value']);
                              } else {
                                blockTypes.add(i['value']);
                              }
                              widget.controller!.blockTypes = blockTypes;
                              setState(() {});
                              try {
                                final DanmakuOption currentOption =
                                    danmakuController.option;
                                final DanmakuOption updatedOption =
                                    currentOption.copyWith(
                                  hideTop: blockTypes.contains(5),
                                  hideBottom: blockTypes.contains(4),
                                  hideScroll: blockTypes.contains(2),
                                  // 添加或修改其他需要修改的选项属性
                                );
                                danmakuController.updateOption(updatedOption);
                              } catch (_) {}
                            },
                            text: i['label'],
                            selectStatus: blockTypes.contains(i['value']),
                          ),
                          const SizedBox(width: 10),
                        ]
                      ],
                    ),
                  ),
                  const Text('显示区域'),
                  Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 18),
                    child: Row(
                      children: [
                        for (final Map<String, dynamic> i in showAreas) ...[
                          ActionRowLineItem(
                            onTap: () {
                              showArea = i['value'];
                              widget.controller!.showArea = showArea;
                              setState(() {});
                              try {
                                final DanmakuOption currentOption =
                                    danmakuController.option;
                                final DanmakuOption updatedOption =
                                    currentOption.copyWith(area: i['value']);
                                danmakuController.updateOption(updatedOption);
                              } catch (_) {}
                            },
                            text: i['label'],
                            selectStatus: showArea == i['value'],
                          ),
                          const SizedBox(width: 10),
                        ]
                      ],
                    ),
                  ),
                  Text('不透明度 ${opacityVal * 100}%'),
                  Padding(
                    padding: const EdgeInsets.only(
                      top: 0,
                      bottom: 6,
                      left: 10,
                      right: 10,
                    ),
                    child: SliderTheme(
                      data: SliderThemeData(
                        trackShape: MSliderTrackShape(),
                        thumbColor: Theme.of(context).colorScheme.primary,
                        activeTrackColor: Theme.of(context).colorScheme.primary,
                        trackHeight: 10,
                        thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6.0),
                      ),
                      child: Slider(
                        min: 0,
                        max: 1,
                        value: opacityVal,
                        divisions: 10,
                        label: '${opacityVal * 100}%',
                        onChanged: (double val) {
                          opacityVal = val;
                          widget.controller!.opacityVal = opacityVal;
                          setState(() {});
                          try {
                            final DanmakuOption currentOption =
                                danmakuController.option;
                            final DanmakuOption updatedOption =
                                currentOption.copyWith(opacity: val);
                            danmakuController.updateOption(updatedOption);
                          } catch (_) {}
                        },
                      ),
                    ),
                  ),
                  Text('描边粗细 $strokeWidth'),
                  Padding(
                    padding: const EdgeInsets.only(
                      top: 0,
                      bottom: 6,
                      left: 10,
                      right: 10,
                    ),
                    child: SliderTheme(
                      data: SliderThemeData(
                        trackShape: MSliderTrackShape(),
                        thumbColor: Theme.of(context).colorScheme.primary,
                        activeTrackColor: Theme.of(context).colorScheme.primary,
                        trackHeight: 10,
                        thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6.0),
                      ),
                      child: Slider(
                        min: 0,
                        max: 3,
                        value: strokeWidth,
                        divisions: 6,
                        label: '$strokeWidth',
                        onChanged: (double val) {
                          strokeWidth = val;
                          widget.controller!.strokeWidth = val;
                          setState(() {});
                          try {
                            final DanmakuOption currentOption =
                                danmakuController.option;
                            final DanmakuOption updatedOption =
                                currentOption.copyWith(strokeWidth: val);
                            danmakuController.updateOption(updatedOption);
                          } catch (_) {}
                        },
                      ),
                    ),
                  ),
                  Text('字体大小 ${(fontSizeVal * 100).toStringAsFixed(1)}%'),
                  Padding(
                    padding: const EdgeInsets.only(
                      top: 0,
                      bottom: 6,
                      left: 10,
                      right: 10,
                    ),
                    child: SliderTheme(
                      data: SliderThemeData(
                        trackShape: MSliderTrackShape(),
                        thumbColor: Theme.of(context).colorScheme.primary,
                        activeTrackColor: Theme.of(context).colorScheme.primary,
                        trackHeight: 10,
                        thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6.0),
                      ),
                      child: Slider(
                        min: 0.5,
                        max: 2.5,
                        value: fontSizeVal,
                        divisions: 20,
                        label: '${(fontSizeVal * 100).toStringAsFixed(1)}%',
                        onChanged: (double val) {
                          fontSizeVal = val;
                          widget.controller!.fontSizeVal = fontSizeVal;
                          setState(() {});
                          try {
                            final DanmakuOption currentOption =
                                danmakuController.option;
                            final DanmakuOption updatedOption =
                                currentOption.copyWith(
                              fontSize: (15 * fontSizeVal).toDouble(),
                            );
                            danmakuController.updateOption(updatedOption);
                          } catch (_) {}
                        },
                      ),
                    ),
                  ),
                  Text('弹幕时长 ${danmakuDurationVal.toString()} 秒'),
                  Padding(
                    padding: const EdgeInsets.only(
                      top: 0,
                      bottom: 6,
                      left: 10,
                      right: 10,
                    ),
                    child: SliderTheme(
                      data: SliderThemeData(
                        trackShape: MSliderTrackShape(),
                        thumbColor: Theme.of(context).colorScheme.primary,
                        activeTrackColor: Theme.of(context).colorScheme.primary,
                        trackHeight: 10,
                        thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6.0),
                      ),
                      child: Slider(
                        min: 2,
                        max: 16,
                        value: danmakuDurationVal,
                        divisions: 28,
                        label: danmakuDurationVal.toString(),
                        onChanged: (double val) {
                          danmakuDurationVal = val;
                          widget.controller!.danmakuDurationVal =
                              danmakuDurationVal;
                          setState(() {});
                          try {
                            final DanmakuOption updatedOption =
                                danmakuController.option.copyWith(
                                    duration:
                                        val / widget.controller!.playbackSpeed);
                            danmakuController.updateOption(updatedOption);
                          } catch (_) {}
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        });
      },
    ).then((value) {
      widget.controller!.cacheDanmakuOption();
    });
  }

  /// 播放顺序
  void showSetRepeat() async {
    showModalBottomSheet(
      context: context,
      elevation: 0,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Container(
          width: double.infinity,
          height: 250,
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
          ),
          margin: const EdgeInsets.all(12),
          child: Column(
            children: [
              const SizedBox(
                height: 45,
                child: Center(
                  child: Text('选择播放顺序', style: titleStyle),
                ),
              ),
              Expanded(
                child: Material(
                  child: ListView(
                    children: <Widget>[
                      for (final PlayRepeat i in PlayRepeat.values) ...[
                        ListTile(
                          onTap: () {
                            widget.controller!.setPlayRepeat(i);
                            Get.back();
                          },
                          dense: true,
                          contentPadding:
                              const EdgeInsets.only(left: 20, right: 20),
                          title: Text(i.description),
                          trailing: widget.controller!.playRepeat == i
                              ? Icon(
                                  Icons.done,
                                  color: Theme.of(context).colorScheme.primary,
                                )
                              : const SizedBox(),
                        )
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final _ = widget.controller!;
    const TextStyle textStyle = TextStyle(
      color: Colors.white,
      fontSize: 12,
    );
    final bool isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    return AppBar(
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      primary: false,
      centerTitle: false,
      automaticallyImplyLeading: false,
      titleSpacing: 14,
      title: Row(
        children: [
          ComBtn(
            icon: const Icon(
              FontAwesomeIcons.arrowLeft,
              size: 15,
              color: Colors.white,
            ),
            fuc: () => <Set<void>>{
              if (widget.controller!.isFullScreen.value)
                <void>{widget.controller!.triggerFullScreen(status: false)}
              else
                <void>{
                  if (MediaQuery.of(context).orientation ==
                      Orientation.landscape)
                    {
                      SystemChrome.setPreferredOrientations([
                        DeviceOrientation.portraitUp,
                      ])
                    },
                  Get.back()
                }
            },
          ),
          SizedBox(width: buttonSpace),
          if (isFullScreen.value &&
              isLandscape &&
              widget.videoType == SearchType.video) ...[
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Obx(
                    () => Text(
                      videoIntroController.videoDetail.value.title ?? '',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
                if (videoIntroController.isShowOnlineTotal)
                  Text(
                    '${videoIntroController.total.value}人正在看',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                    ),
                  )
              ],
            )
          ] else ...[
            ComBtn(
              icon: const Icon(
                FontAwesomeIcons.house,
                size: 15,
                color: Colors.white,
              ),
              fuc: () async {
                // 销毁播放器实例
                await widget.controller!.dispose(type: 'all');
                if (mounted) {
                  Navigator.popUntil(
                      context, (Route<dynamic> route) => route.isFirst);
                }
              },
            ),
          ],
          const Spacer(),

          /// 更多设置：放在右侧按钮组最前面，避免竖屏全屏时右侧按钮过多被挤出屏幕。
          /// 这样竖屏全屏下也能直接看到三个点，无需退出全屏才能进设置。
          ComBtn(
            icon: const Icon(
              Icons.more_vert_outlined,
              size: 18,
              color: Colors.white,
            ),
            fuc: () => showSettingSheet(),
          ),
          SizedBox(width: buttonSpace),
          // ComBtn(
          //   icon: const Icon(
          //     FontAwesomeIcons.cropSimple,
          //     size: 15,
          //     color: Colors.white,
          //   ),
          //   fuc: () => _.screenshot(),
          // ),
          ComBtn(
            icon: const Icon(
              Icons.cast,
              size: 19,
              color: Colors.white,
            ),
            fuc: () async {
              showDialog<void>(
                context: context,
                builder: (BuildContext context) {
                  return LiveDlnaPage(
                      datasource: widget.videoDetailCtr!.videoUrl);
                },
              );
            },
          ),
          SizedBox(width: buttonSpace),
          if (isFullScreen.value) ...[
            SizedBox(
              width: 56,
              height: 34,
              child: TextButton(
                style: ButtonStyle(
                  padding: MaterialStateProperty.all(EdgeInsets.zero),
                ),
                onPressed: () => showShootDanmakuSheet(),
                child: const Text(
                  '发弹幕',
                  style: textStyle,
                ),
              ),
            ),
            SizedBox(
              width: 34,
              height: 34,
              child: Obx(
                () => IconButton(
                  style: ButtonStyle(
                    padding: MaterialStateProperty.all(EdgeInsets.zero),
                  ),
                  onPressed: () {
                    _.isOpenDanmu.value = !_.isOpenDanmu.value;
                  },
                  icon: Icon(
                    _.isOpenDanmu.value
                        ? Icons.subtitles_outlined
                        : Icons.subtitles_off_outlined,
                    size: 19,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            SizedBox(width: buttonSpace),
            if (Platform.isAndroid) ...<Widget>[
              SizedBox(
                width: 34,
                height: 34,
                child: IconButton(
                  style: ButtonStyle(
                    padding: MaterialStateProperty.all(EdgeInsets.zero),
                  ),
                  onPressed: () async {
                    bool canUsePiP = false;
                    widget.controller!.hiddenControls(false);
                    try {
                      canUsePiP = await widget.floating!.isPipAvailable;
                    } on PlatformException catch (_) {
                      canUsePiP = false;
                    }
                    if (canUsePiP) {
                      final Rational aspectRatio = Rational(
                        widget.videoDetailCtr!.data.dash!.video!.first.width!,
                        widget.videoDetailCtr!.data.dash!.video!.first.height!,
                      );
                      await widget.floating!.enable(aspectRatio: aspectRatio);
                    } else {}
                  },
                  icon: const Icon(
                    Icons.picture_in_picture_outlined,
                    size: 19,
                    color: Colors.white,
                  ),
                ),
              ),
              SizedBox(width: buttonSpace),
            ],
            Obx(
              () => SizedBox(
                width: 45,
                height: 34,
                child: TextButton(
                  style: ButtonStyle(
                    padding: MaterialStateProperty.all(EdgeInsets.zero),
                  ),
                  onPressed: () => showSetSpeedSheet(),
                  child: Text(
                    '${_.playbackSpeed}X',
                    style: textStyle,
                  ),
                ),
              ),
            ),
            SizedBox(width: buttonSpace),
          ],

          /// 字幕按钮 (直接控制打开和关闭字幕，样式为图3和图4的 CC 开关)
          if (widget.showSubtitleBtn ?? true) ...[
            Obx(
              () => ComBtn(
                icon: _buildCcSwitchIcon(_.realtimeCaptions.enabled),
                fuc: () {
                  final next = !_.realtimeCaptions.enabled;
                  _.realtimeCaptions.setOriginal(next);
                  if (!next) {
                    _.realtimeCaptions.setTranslation(false);
                    _.realtimeCaptions.setPronunciation(false);
                  }
                  SmartDialog.showToast(next ? '已开启字幕' : '已关闭字幕');
                },
              ),
            ),
            SizedBox(width: buttonSpace),
          ],
        ],
      ),
    );
  }
}

class MSliderTrackShape extends RoundedRectSliderTrackShape {
  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    SliderThemeData? sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    const double trackHeight = 3;
    final double trackLeft = offset.dx;
    final double trackTop =
        offset.dy + (parentBox.size.height - trackHeight) / 2 + 4;
    final double trackWidth = parentBox.size.width;
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }
}

class _OnlineAsrSettingsWidget extends StatefulWidget {
  const _OnlineAsrSettingsWidget({
    Key? key,
    required this.captions,
  }) : super(key: key);

  final RealtimeCaptions captions;

  @override
  State<_OnlineAsrSettingsWidget> createState() => _OnlineAsrSettingsWidgetState();
}

class _OnlineAsrSettingsWidgetState extends State<_OnlineAsrSettingsWidget> {
  late final TextEditingController _doubaoApiKeyCtrl;
  late final TextEditingController _doubaoAppIdCtrl;
  late final TextEditingController _doubaoAccessTokenCtrl;
  late final TextEditingController _deepgramApiKeyCtrl;

  bool _obscureDoubaoApiKey = true;
  bool _obscureDoubaoToken = true;
  bool _obscureDeepgramKey = true;

  @override
  void initState() {
    super.initState();
    _doubaoApiKeyCtrl = TextEditingController(text: widget.captions.doubaoApiKey.value);
    _doubaoAppIdCtrl = TextEditingController(text: widget.captions.doubaoAppId.value);
    _doubaoAccessTokenCtrl = TextEditingController(text: widget.captions.doubaoAccessToken.value);
    _deepgramApiKeyCtrl = TextEditingController(text: widget.captions.deepgramApiKey.value);
  }

  @override
  void dispose() {
    _doubaoApiKeyCtrl.dispose();
    _doubaoAppIdCtrl.dispose();
    _doubaoAccessTokenCtrl.dispose();
    _deepgramApiKeyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final captions = widget.captions;
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Obx(() {
      final selectedEngine = captions.onlineAsrEngine.value;
      final doubaoAuth = captions.doubaoAuthMode.value;

      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.35),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. 识别方式
            Text(
              '识别方式',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: primaryColor.withOpacity(0.9),
              ),
            ),
            const SizedBox(height: 2),
            DropdownButton<String>(
              value: selectedEngine,
              isExpanded: true,
              underline: Container(
                height: 1,
                color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5),
              ),
              items: const [
                DropdownMenuItem(
                  value: 'azure',
                  child: Text('微软流式在线识别（免 Key）', style: TextStyle(fontSize: 14)),
                ),
                DropdownMenuItem(
                  value: 'doubao',
                  child: Text('豆包流式语音识别 2.0', style: TextStyle(fontSize: 14)),
                ),
                DropdownMenuItem(
                  value: 'deepgram',
                  child: Text('Deepgram Nova-3', style: TextStyle(fontSize: 14)),
                ),
                DropdownMenuItem(
                  value: 'qwen',
                  child: Text('QwenASR 网站实时识别', style: TextStyle(fontSize: 14)),
                ),
              ],
              onChanged: (val) {
                if (val != null) {
                  captions.setOnlineAsrEngine(val);
                }
              },
            ),

            // 识别语言（视频原声）
            const SizedBox(height: 10),
            Text(
              '识别语言（视频原声）',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: primaryColor.withOpacity(0.9),
              ),
            ),
            const SizedBox(height: 2),
            DropdownButton<String>(
              value: captions.onlineAsrLanguage.value,
              isExpanded: true,
              underline: Container(
                height: 1,
                color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5),
              ),
              items: const [
                DropdownMenuItem(
                  value: 'auto',
                  child: Text('自动感知（全语种自适应）', style: TextStyle(fontSize: 14)),
                ),
                DropdownMenuItem(
                  value: 'en-US',
                  child: Text('英语 (English)', style: TextStyle(fontSize: 14)),
                ),
                DropdownMenuItem(
                  value: 'zh-CN',
                  child: Text('中文普通话', style: TextStyle(fontSize: 14)),
                ),
                DropdownMenuItem(
                  value: 'zh-HK',
                  child: Text('粤语 (Cantonese)', style: TextStyle(fontSize: 14)),
                ),
                DropdownMenuItem(
                  value: 'ja-JP',
                  child: Text('日语 (日本語)', style: TextStyle(fontSize: 14)),
                ),
                DropdownMenuItem(
                  value: 'ko-KR',
                  child: Text('韩语 (한국어)', style: TextStyle(fontSize: 14)),
                ),
              ],
              onChanged: (val) {
                if (val != null) {
                  captions.setOnlineAsrLanguage(val);
                }
              },
            ),

            // 2. 微软免 Key 模式提示
            if (selectedEngine == 'azure') ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.check_circle_outline, size: 15, color: Colors.green),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '免 Key 直连，基于微软 Edge 语音服务网关，低延迟即开即用。',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                    ),
                  ),
                ],
              ),
            ],

            // 3. 豆包 2.0 配置
            if (selectedEngine == 'doubao') ...[
              const SizedBox(height: 10),
              Text(
                '豆包鉴权方式',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: primaryColor.withOpacity(0.9),
                ),
              ),
              const SizedBox(height: 2),
              DropdownButton<String>(
                value: doubaoAuth,
                isExpanded: true,
                underline: Container(
                  height: 1,
                  color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'api_key',
                    child: Text('API Key（新版控制台）', style: TextStyle(fontSize: 14)),
                  ),
                  DropdownMenuItem(
                    value: 'token',
                    child: Text('APP ID + Access Token', style: TextStyle(fontSize: 14)),
                  ),
                ],
                onChanged: (val) {
                  if (val != null) {
                    captions.setDoubaoAuthMode(val);
                  }
                },
              ),
              const SizedBox(height: 8),
              if (doubaoAuth == 'api_key') ...[
                Text(
                  '豆包语音 API Key',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: primaryColor.withOpacity(0.9),
                  ),
                ),
                TextField(
                  controller: _doubaoApiKeyCtrl,
                  obscureText: _obscureDoubaoApiKey,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: '请输入火山引擎 API Key',
                    hintStyle: const TextStyle(fontSize: 12, color: Colors.grey),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5),
                      ),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: primaryColor),
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureDoubaoApiKey ? Icons.visibility_off : Icons.visibility,
                        size: 18,
                        color: Colors.grey,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscureDoubaoApiKey = !_obscureDoubaoApiKey;
                        });
                      },
                    ),
                  ),
                  onChanged: (val) {
                    captions.setDoubaoApiKey(val.trim());
                  },
                ),
              ] else ...[
                Text(
                  '豆包 APP ID',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: primaryColor.withOpacity(0.9),
                  ),
                ),
                TextField(
                  controller: _doubaoAppIdCtrl,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: '请输入火山引擎 APP ID',
                    hintStyle: const TextStyle(fontSize: 12, color: Colors.grey),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5),
                      ),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: primaryColor),
                    ),
                  ),
                  onChanged: (val) {
                    captions.setDoubaoAppId(val.trim());
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  '豆包 Access Token',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: primaryColor.withOpacity(0.9),
                  ),
                ),
                TextField(
                  controller: _doubaoAccessTokenCtrl,
                  obscureText: _obscureDoubaoToken,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: '请输入 Access Token',
                    hintStyle: const TextStyle(fontSize: 12, color: Colors.grey),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5),
                      ),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: primaryColor),
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureDoubaoToken ? Icons.visibility_off : Icons.visibility,
                        size: 18,
                        color: Colors.grey,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscureDoubaoToken = !_obscureDoubaoToken;
                        });
                      },
                    ),
                  ),
                  onChanged: (val) {
                    captions.setDoubaoAccessToken(val.trim());
                  },
                ),
              ],
            ],

            // 4. Deepgram Nova-3 配置
            if (selectedEngine == 'deepgram') ...[
              const SizedBox(height: 10),
              Text(
                'Deepgram API Key',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: primaryColor.withOpacity(0.9),
                ),
              ),
              TextField(
                controller: _deepgramApiKeyCtrl,
                obscureText: _obscureDeepgramKey,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: '请输入 Deepgram API Key',
                  hintStyle: const TextStyle(fontSize: 12, color: Colors.grey),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5),
                    ),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: primaryColor),
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureDeepgramKey ? Icons.visibility_off : Icons.visibility,
                      size: 18,
                      color: Colors.grey,
                    ),
                    onPressed: () {
                      setState(() {
                        _obscureDeepgramKey = !_obscureDeepgramKey;
                      });
                    },
                  ),
                ),
                onChanged: (val) {
                  captions.setDeepgramApiKey(val.trim());
                },
              ),
            ],

            // 5. Qwen 模式提示与登录入口
            if (selectedEngine == 'qwen') ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.info_outline, size: 15, color: Colors.lightBlue),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '连接 Qwen-ASR 实时流式识别服务，支持自动免密登录与账号绑定。',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              InkWell(
                onTap: () async {
                  if (Platform.isAndroid || Platform.isIOS) {
                    await Get.toNamed(
                      '/webview',
                      parameters: {
                        'url': 'https://asr.ieeio.com/login',
                        'type': 'asr_login',
                        'pageTitle': 'Qwen ASR 登录',
                      },
                    );
                  } else {
                    try {
                      await launchUrl(
                        Uri.parse('https://asr.ieeio.com/login'),
                        mode: LaunchMode.externalApplication,
                      );
                    } catch (_) {}
                  }
                  // 从登录页面返回后立即清空内存中的老旧 Demo Token，无缝读取新会话
                  IeeioLogin.shared.clearCachedToken();
                },
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary.withOpacity(0.4),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.open_in_new,
                        size: 14,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '登录 Qwen ASR 网站 (https://asr.ieeio.com)',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    });
  }
}
