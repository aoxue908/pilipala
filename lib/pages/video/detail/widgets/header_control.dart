import 'dart:io';

import 'package:floating/floating.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:ns_danmaku/ns_danmaku.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pilipala/http/user.dart';
import 'package:pilipala/models/video/play/quality.dart';
import 'package:pilipala/models/video/play/url.dart';
import 'package:pilipala/pages/dlna/index.dart';
import 'package:pilipala/pages/video/detail/index.dart';
import 'package:pilipala/pages/video/detail/introduction/widgets/menu_row.dart';
import 'package:pilipala/plugin/pl_player/index.dart';
import 'package:pilipala/plugin/pl_player/models/play_repeat.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_preferences.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_translator.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_tts_dialog.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_tts_service.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/ieeio_login.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/local_asr_model.dart';
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
                        showSubtitleDialog();
                      },
                      dense: true,
                      leading:
                          const Icon(Icons.closed_caption_outlined, size: 20),
                      title: const Text('字幕与语音识别', style: titleStyle),
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

  void showSubtitleDialog() {
    final player = widget.controller!;
    final captions = player.realtimeCaptions;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('字幕与语音识别'),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: captions.asrDiagnostics),
              );
              SmartDialog.showToast('已复制字幕诊断');
            },
            child: const Text('复制诊断'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('完成'),
          ),
        ],
        contentPadding: const EdgeInsets.only(top: 8, bottom: 12),
        content: SizedBox(
          width: 380,
          child: Obx(() {
            final tracks = captions.tracks.toList();
            final selected = captions.selectedTrack.value;
            final asrError = captions.asrError.value;
            final translationError = captions.translationError.value;
            final status = captions.status.value;
            final currentLang = captions.targetLanguage.value;
            final currentLangName =
                CaptionTranslator.supportedLanguages[currentLang] ?? '简体中文';
            final currentSelected = selected == RealtimeCaptions.automaticTrack
                ? (captions.isNativeSubtitle
                    ? (tracks.firstOrNull?.id ??
                        (captions.useLocalAsr.value
                            ? RealtimeCaptions.realtimeLocalTrack
                            : RealtimeCaptions.realtimeCloudTrack))
                    : (captions.useLocalAsr.value
                        ? RealtimeCaptions.realtimeLocalTrack
                        : RealtimeCaptions.realtimeCloudTrack))
                : selected;

            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 顶部字幕来源状态卡片
                  Container(
                    margin: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: captions.isNativeSubtitle
                          ? Colors.blue.withOpacity(0.08)
                          : (captions.isUsingLocalAsr
                              ? Colors.green.withOpacity(0.08)
                              : Colors.purple.withOpacity(0.08)),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: captions.isNativeSubtitle
                            ? Colors.blue.withOpacity(0.3)
                            : (captions.isUsingLocalAsr
                                ? Colors.green.withOpacity(0.3)
                                : Colors.purple.withOpacity(0.3)),
                        width: 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: captions.isNativeSubtitle
                                    ? Colors.blue
                                    : (captions.isUsingLocalAsr ? Colors.green : Colors.purple),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                captions.activeSourceTag.isNotEmpty
                                    ? captions.activeSourceTag
                                    : (captions.isNativeSubtitle
                                        ? '[B站官方]'
                                        : (captions.isUsingLocalAsr ? '[本地离线]' : '[云端在线]')),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                captions.activeSourceDescription.isNotEmpty
                                    ? captions.activeSourceDescription
                                    : (captions.isNativeSubtitle
                                        ? 'B 站自带官方字幕轨'
                                        : (captions.isUsingLocalAsr
                                            ? 'Sherpa-ONNX 本地离线识别'
                                            : 'Qwen ASR 云端实时识别')),
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        if (tracks.isEmpty) ...[
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Icon(Icons.info_outline_rounded,
                                  size: 14, color: Theme.of(context).colorScheme.outline),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  captions.needLoginForSubtitles.value
                                      ? '该视频官方字幕需登录后查看，登录后即可显示官方自带字幕'
                                      : '当前视频无 B 站官方自带字幕轨，已自动启用实时语音识别',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Theme.of(context).colorScheme.outline,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (captions.needLoginForSubtitles.value) ...[
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                                icon: const Icon(Icons.login_rounded, size: 16),
                                label: const Text('前往登录获取官方字幕', style: TextStyle(fontSize: 12)),
                                onPressed: () {
                                  Navigator.of(context).pop();
                                  Get.toNamed('/login');
                                },
                              ),
                            ),
                          ],
                        ],
                        if (captions.cloudLagWarning.value &&
                            !captions.isUsingLocalAsr &&
                            !captions.isNativeSubtitle) ...[
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.amber.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.amber.withOpacity(0.4)),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.warning_amber_rounded, size: 14, color: Colors.amber),
                                SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    '云端网络转写延迟过大，建议下方切换为「Sherpa-ONNX 本地离线识别」',
                                    style: TextStyle(fontSize: 11, color: Colors.orange),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('显示原文'),
                    subtitle: Text(IeeioLogin.supported
                        ? '优先使用 B 站字幕，缺少时识别音轨原语言'
                        : '使用视频自带字幕'),
                    value: captions.showOriginal.value,
                    onChanged: captions.setOriginal,
                  ),
                  if (tracks.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Row(
                        children: [
                          const Text('官方字幕语言: ',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                          const Spacer(),
                          DropdownButton<int>(
                            value: tracks.any((t) => t.id == currentSelected)
                                ? currentSelected
                                : (tracks.firstOrNull?.id),
                            isDense: true,
                            items: tracks
                                .map((t) => DropdownMenuItem(
                                      value: t.id!,
                                      child: Text(
                                        t.lanDoc ?? t.title ?? t.lan ?? '默认',
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                    ))
                                .toList(),
                            onChanged: (trackId) {
                              if (trackId != null) {
                                captions.selectTrack(trackId);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  SwitchListTile(
                    title: const Text('显示译文'),
                    subtitle: Text('翻译为: $currentLangName'),
                    value: captions.showTranslation.value,
                    onChanged: captions.setTranslation,
                  ),
                  if (captions.showTranslation.value)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Row(
                        children: [
                          const Text('译文目标语言: ', style: TextStyle(fontSize: 13)),
                          const Spacer(),
                          DropdownButton<String>(
                            value: currentLang,
                            isDense: true,
                            items: CaptionTranslator.supportedLanguages.entries
                                .map((e) => DropdownMenuItem(
                                      value: e.key,
                                      child: Text(e.value,
                                          style: const TextStyle(fontSize: 13)),
                                    ))
                                .toList(),
                            onChanged: (lang) {
                              if (lang != null) {
                                captions.setTargetLanguage(lang);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  SwitchListTile(
                    title: const Text('显示发音注音'),
                    subtitle: const Text('中文拼音、粤拼、日语假名/罗马音、韩语发音、英语音标'),
                    value: captions.showPronunciation.value,
                    onChanged: captions.setPronunciation,
                  ),
                  if (captions.showPronunciation.value) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Row(
                        children: [
                          const Text('中文/粤语注音: ', style: TextStyle(fontSize: 13)),
                          const Spacer(),
                          DropdownButton<String>(
                            value: captions.chinesePhonetic.value,
                            isDense: true,
                            items: const [
                              DropdownMenuItem(
                                value: 'auto',
                                child: Text('智能识别 (粤拼/普通话)',
                                    style: TextStyle(fontSize: 13)),
                              ),
                              DropdownMenuItem(
                                value: 'cantonese',
                                child: Text('粤语拼音 (Jyutping)',
                                    style: TextStyle(fontSize: 13)),
                              ),
                              DropdownMenuItem(
                                value: 'mandarin',
                                child: Text('普通话拼音 (Pinyin)',
                                    style: TextStyle(fontSize: 13)),
                              ),
                            ],
                            onChanged: (mode) {
                              if (mode != null) {
                                captions.setChinesePhonetic(mode);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Row(
                        children: [
                          const Text('日语注音类型: ', style: TextStyle(fontSize: 13)),
                          const Spacer(),
                          DropdownButton<String>(
                            value: captions.japanesePhonetic.value,
                            isDense: true,
                            items: const [
                              DropdownMenuItem(
                                value: 'kana',
                                child: Text('假名 (Kana)',
                                    style: TextStyle(fontSize: 13)),
                              ),
                              DropdownMenuItem(
                                value: 'romaji',
                                child: Text('罗马音 (Romaji)',
                                    style: TextStyle(fontSize: 13)),
                              ),
                            ],
                            onChanged: (mode) {
                              if (mode != null) {
                                captions.setJapanesePhonetic(mode);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Row(
                        children: [
                          const Text('注音颜色: ', style: TextStyle(fontSize: 13)),
                          const Spacer(),
                          DropdownButton<int>(
                            value: player.captionPreferences.appearance.value.pronunciationColor,
                            isDense: true,
                            items: [
                              for (final color in CaptionPreferences.pronunciationColors.entries)
                                DropdownMenuItem(
                                  value: color.key,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.circle, size: 14, color: Color(color.key)),
                                      const SizedBox(width: 6),
                                      Text(color.value, style: const TextStyle(fontSize: 13)),
                                    ],
                                  ),
                                ),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                player.captionPreferences.update(pronunciationColor: value);
                                player.captionPreferences.save();
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                  SwitchListTile(
                    title: const Text('点击字幕查词（智能查词）'),
                    subtitle: const Text('点击字幕单词自动暂停播放，查看音标发音、详细释义与例句'),
                    value: player.captionPreferences.enableWordLookup.value,
                    onChanged: (val) {
                      player.captionPreferences.enableWordLookup.value = val;
                      player.captionPreferences.save();
                    },
                  ),
                  ListTile(
                    title: const Text('查词与注音发音人设置'),
                    subtitle: Text(
                      CaptionTtsService.shared.config.engine == 'mimo'
                          ? '当前: 小米 MiMo-V2.5-TTS (${CaptionTtsService.shared.config.mimoVoice}) · 限时免费'
                          : (CaptionTtsService.shared.config.engine == 'system'
                              ? '当前: 设备系统原生离线 TTS'
                              : '当前: Microsoft Edge-TTS (${CaptionTtsService.edgeCantoneseVoices[CaptionTtsService.shared.config.edgeCantoneseVoice]?.split(' ').first ?? '晓曼'})'),
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded, size: 20),
                    onTap: () async {
                      await showTtsVoiceSettingsDialog(context);
                    },
                  ),
                  if (asrError.isNotEmpty || translationError.isNotEmpty)
                    ListTile(
                      dense: true,
                      title: Text(
                        [asrError, translationError]
                            .where((message) => message.isNotEmpty)
                            .join('\n'),
                        style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                      ),
                      trailing: TextButton(
                        onPressed: captions.retry,
                        child: const Text('重试'),
                      ),
                    )
                  else if (status.isNotEmpty)
                    ListTile(
                      dense: true,
                      title: Text(status,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontSize: 12)),
                    ),
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Text(
                      '选择字幕源 / 识别方式',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                  if (tracks.isNotEmpty)
                    for (final track in tracks)
                      RadioListTile<int>(
                        dense: true,
                        value: track.id!,
                        title: Text(
                          'B站官方字幕 · ${track.lanDoc ?? track.title ?? track.lan ?? "默认"}',
                        ),
                        subtitle: Text(
                          track.isAi
                              ? 'B 站官方 AI 自动听写/翻译字幕'
                              : '视频自带官方字幕轨，内容准确',
                          style: const TextStyle(fontSize: 11),
                        ),
                        groupValue: currentSelected,
                        onChanged: (value) => captions.selectTrack(value!),
                      ),
                  if (IeeioLogin.supported)
                    RadioListTile<int>(
                      dense: true,
                      value: RealtimeCaptions.realtimeCloudTrack,
                      title: Row(
                        children: [
                          const Flexible(
                            child: Text(
                              '实时语音识别 (云端在线 · Qwen ASR)',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
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
                            borderRadius: BorderRadius.circular(4),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.6),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.open_in_browser_rounded, size: 12, color: Theme.of(context).colorScheme.primary),
                                  const SizedBox(width: 3),
                                  Text(
                                    '登录网页',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: Theme.of(context).colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      subtitle: const Text('通义千问在线流式识别，需网络',
                          style: TextStyle(fontSize: 11)),
                      groupValue: currentSelected,
                      onChanged: (value) {
                        captions.setLocalAsr(false);
                        SmartDialog.showToast('已切换至 Qwen 云端在线识别');
                      },
                    ),
                  RadioListTile<int>(
                    dense: true,
                    value: RealtimeCaptions.realtimeLocalTrack,
                    title: const Text('实时语音识别 (本地离线 · Sherpa-ONNX)'),
                    subtitle: const Text('设备本地离线模型，隐私安全，无网络开销',
                        style: TextStyle(fontSize: 11)),
                    groupValue: currentSelected,
                    onChanged: (value) {
                      captions.setLocalAsr(true);
                      SmartDialog.showToast('已切换至 Sherpa 本地离线识别');
                    },
                  ),
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Text(
                      '离线语音识别模型配置',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                  _asrEngineSettings(captions),
                  const Divider(),
                  _captionSyncSettings(captions),
                  const Divider(),
                  _captionStyleSettings(player.captionPreferences),
                ],
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _asrEngineSettings(RealtimeCaptions captions) {
    final modelMgr = LocalAsrModelManager.shared;
    return Obx(() {
      final selectedModelId = captions.localAsrModel.value;
      final selectedModel = LocalAsrModelManager.availableModels[selectedModelId] ??
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
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
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
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
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
                                icon: const Icon(Icons.delete_outline, size: 18, color: Colors.grey),
                                tooltip: '删除模型以释放空间',
                                onPressed: () async {
                                  await modelMgr.deleteModel(selectedModelId);
                                  SmartDialog.showToast('已删除 ${selectedModel.name} 本地文件');
                                  captions.retry();
                                },
                              ),
                            FilledButton.tonal(
                              style: FilledButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                              ),
                              onPressed: () async {
                                try {
                                  await modelMgr.downloadModel(modelId: selectedModelId);
                                  SmartDialog.showToast('${selectedModel.name} 下载完成');
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
                          style: const TextStyle(fontSize: 11, color: Colors.grey),
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

  Widget _captionSyncSettings(RealtimeCaptions captions) {
    return Obx(() {
      final delayMs = captions.captionDelayMs.value;
      final String delayDesc;
      if (delayMs == 0) {
        delayDesc = '正常 (0 ms)';
      } else if (delayMs < 0) {
        delayDesc = '提前 ${-delayMs} ms (${(-delayMs / 1000).toStringAsFixed(2)}s)';
      } else {
        delayDesc = '延后 $delayMs ms (${(delayMs / 1000).toStringAsFixed(2)}s)';
      }

      return ExpansionTile(
        key: const PageStorageKey('video-caption-sync'),
        initiallyExpanded: delayMs != 0,
        title: const Text('字幕时间轴 / 同步校准'),
        subtitle: Text(
          delayMs == 0 ? '字幕慢一拍或快一拍时可在此微调' : delayDesc,
          style: TextStyle(
            fontSize: 12,
            color: delayMs != 0
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outline,
          ),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '当前校准: $delayDesc',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                if (delayMs != 0)
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () => captions.setCaptionDelay(0),
                    child: const Text('重置为 0'),
                  ),
              ],
            ),
          ),
          // 快捷预设
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    minimumSize: const Size(64, 28),
                  ),
                  onPressed: () => captions.setCaptionDelay(-200),
                  child: const Text('慢一拍(-0.2s)', style: TextStyle(fontSize: 10)),
                ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    minimumSize: const Size(64, 28),
                  ),
                  onPressed: () => captions.setCaptionDelay(-500),
                  child: const Text('慢半拍(-0.5s)', style: TextStyle(fontSize: 10)),
                ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    minimumSize: const Size(40, 28),
                  ),
                  onPressed: () => captions.setCaptionDelay(0),
                  child: const Text('重置', style: TextStyle(fontSize: 10)),
                ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    minimumSize: const Size(64, 28),
                  ),
                  onPressed: () => captions.setCaptionDelay(200),
                  child: const Text('快一拍(+0.2s)', style: TextStyle(fontSize: 10)),
                ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    minimumSize: const Size(64, 28),
                  ),
                  onPressed: () => captions.setCaptionDelay(500),
                  child: const Text('快半拍(+0.5s)', style: TextStyle(fontSize: 10)),
                ),
              ],
            ),
          ),
          // 50ms / 100ms / 500ms 精细步进微调
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    minimumSize: const Size(44, 28),
                  ),
                  onPressed: () => captions.setCaptionDelay(delayMs - 500),
                  child: const Text('-500', style: TextStyle(fontSize: 10)),
                ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    minimumSize: const Size(44, 28),
                  ),
                  onPressed: () => captions.setCaptionDelay(delayMs - 100),
                  child: const Text('-100', style: TextStyle(fontSize: 10)),
                ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    minimumSize: const Size(44, 28),
                  ),
                  onPressed: () => captions.setCaptionDelay(delayMs - 50),
                  child: const Text('-50ms', style: TextStyle(fontSize: 10)),
                ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    minimumSize: const Size(44, 28),
                  ),
                  onPressed: () => captions.setCaptionDelay(delayMs + 50),
                  child: const Text('+50ms', style: TextStyle(fontSize: 10)),
                ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    minimumSize: const Size(44, 28),
                  ),
                  onPressed: () => captions.setCaptionDelay(delayMs + 100),
                  child: const Text('+100', style: TextStyle(fontSize: 10)),
                ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    minimumSize: const Size(44, 28),
                  ),
                  onPressed: () => captions.setCaptionDelay(delayMs + 500),
                  child: const Text('+500', style: TextStyle(fontSize: 10)),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Slider(
              min: -3000.0,
              max: 3000.0,
              divisions: 120, // 50ms 逐级精准微调
              value: delayMs.toDouble().clamp(-3000.0, 3000.0),
              label: delayDesc,
              onChanged: (val) => captions.setCaptionDelay(val.round()),
            ),
          ),
          const SizedBox(height: 6),
        ],
      );
    });
  }

  Widget _captionStyleSettings(CaptionPreferences preferences) {
    return Obx(() {
      final appearance = preferences.appearance.value;
      final hasCustomPos = appearance.alignX != null || appearance.alignY != null;
      return ExpansionTile(
        key: const PageStorageKey('video-caption-style'),
        title: const Text('字幕样式与外观'),
        children: [
          ListTile(
            title: const Text('字幕颜色'),
            trailing: DropdownButton<int>(
              value: appearance.captionColor,
              items: [
                for (final color in CaptionPreferences.captionColors.entries)
                  DropdownMenuItem(
                    value: color.key,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.circle, size: 16, color: Color(color.key)),
                        const SizedBox(width: 8),
                        Text(color.value),
                      ],
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  preferences.update(captionColor: value);
                  preferences.save();
                }
              },
            ),
          ),
          ListTile(
            title: const Text('注音发音颜色'),
            trailing: DropdownButton<int>(
              value: appearance.pronunciationColor,
              items: [
                for (final color in CaptionPreferences.pronunciationColors.entries)
                  DropdownMenuItem(
                    value: color.key,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.circle, size: 16, color: Color(color.key)),
                        const SizedBox(width: 8),
                        Text(color.value),
                      ],
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  preferences.update(pronunciationColor: value);
                  preferences.save();
                }
              },
            ),
          ),
          _captionSlider(
            '字体大小',
            appearance.fontSize,
            min: 12,
            max: 32,
            divisions: 20,
            label: '${appearance.fontSize.round()}',
            onChanged: (value) => preferences.update(fontSize: value),
            onSaved: preferences.save,
          ),
          _captionSlider(
            '背景不透明度',
            appearance.backgroundOpacity,
            min: 0,
            max: 1,
            divisions: 20,
            label: '${(appearance.backgroundOpacity * 100).round()}%',
            onChanged: (value) => preferences.update(backgroundOpacity: value),
            onSaved: preferences.save,
          ),
          _captionSlider(
            '距离底边',
            appearance.bottom,
            min: 0,
            max: 96,
            divisions: 48,
            label: '${appearance.bottom.round()}',
            onChanged: (value) => preferences.update(bottom: value, clearCustomPosition: true),
            onSaved: preferences.save,
          ),
          ListTile(
            dense: true,
            title: const Text('拖动字幕位置', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              hasCustomPos ? '已自定义拖动位置（可直接在画面中按住字幕拖动）' : '默认居中（可直接在画面中按住字幕拖动）',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            trailing: hasCustomPos
                ? TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.restart_alt, size: 16),
                    label: const Text('恢复默认', style: TextStyle(fontSize: 12)),
                    onPressed: () {
                      preferences.resetPosition();
                      SmartDialog.showToast('已恢复默认字幕位置');
                    },
                  )
                : null,
          ),
        ],
      );
    });
  }

  Widget _captionSlider(
    String title,
    double value, {
    required double min,
    required double max,
    required int divisions,
    required String label,
    required ValueChanged<double> onChanged,
    required VoidCallback onSaved,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$title  $label'),
          Slider(
            min: min,
            max: max,
            divisions: divisions,
            value: value,
            semanticFormatterCallback: (_) => '$title $label',
            onChanged: onChanged,
            onChangeEnd: (_) => onSaved(),
          ),
        ],
      ),
    );
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

          /// 字幕按钮 (竖屏与全屏均常驻显示，方便快速开启/设置字幕)
          if (widget.showSubtitleBtn ?? true) ...[
            Obx(
              () => ComBtn(
                icon: Icon(
                  _.realtimeCaptions.enabled
                      ? Icons.closed_caption
                      : Icons.closed_caption_off,
                  size: 22,
                  color: Colors.white,
                  semanticLabel: '字幕与翻译',
                ),
                fuc: showSubtitleDialog,
              ),
            ),
            SizedBox(width: buttonSpace),
          ],

          /// 更多设置 (竖屏与全屏均常驻显示)
          ComBtn(
            icon: const Icon(
              Icons.more_vert_outlined,
              size: 18,
              color: Colors.white,
            ),
            fuc: () => showSettingSheet(),
          ),
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
