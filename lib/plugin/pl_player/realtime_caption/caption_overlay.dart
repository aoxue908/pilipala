import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:pilipala/plugin/pl_player/controller.dart';

import 'caption_dictionary_sheet.dart';
import 'caption_context.dart';
import 'caption_preferences.dart';
import 'caption_pronunciation.dart';
import 'caption_rollup.dart';
import 'caption_ruby.dart';
import 'caption_offline_phonetics.dart';
import 'japanese_reading.dart';
import 'realtime_captions.dart';

/// 字幕条宽度：横屏限制为屏幕宽的 3/5（左右各留约 1/5），集中注意力；
/// 竖屏保持全宽，仅留出左右安全边距。
///
/// [screenWidth] 为播放器可见宽度，[isLandscape] 标识横屏。
/// 结果至少 140px，避免极窄窗口下不可用。
double captionBarWidth({
  required double screenWidth,
  required bool isLandscape,
}) {
  const double minWidth = 140.0;
  if (isLandscape) {
    return math.max(minWidth, screenWidth * 3 / 5);
  }
  return math.max(minWidth, screenWidth - 16.0);
}

/// 划词查词时，判定查询词所属语言。
///
/// 核心原则：【当前句/词自身的字符特征优先于全局语境】。
/// 全局语境 langContext 可能因历史上某一句识别幻觉（偶尔蹦出一个韩文/假名）
/// 被永久锁死成 ko/ja；若直接沿用，会把眼前这句纯英文「All right...」也判成韩语。
/// 因此这里先按当前句的字符特征判定，只有特征不明确时才回退到全局语境。
///
/// [sentence] 当前字幕整句（用于特征判定），[query] 实际查询的词。
/// [langContext] 全局语境语言（currentLanguageContext），可为 null。
String solveQueryLanguage({
  required String sentence,
  required String query,
  String? langContext,
  bool isYue = false,
}) {
  // 判定用的样本：整句优先，整句为空时用查询词。
  final sample = sentence.trim().isNotEmpty ? sentence : query;
  final hasKana = RegExp(r'[\u3040-\u309F\u30A0-\u30FF]').hasMatch(sample);
  final hasHangul = RegExp(r'[\uAC00-\uD7AF\u1100-\u11FF]').hasMatch(sample);
  final hasHan = RegExp(r'[\u4E00-\u9FFF]').hasMatch(sample);
  final hasLatin = RegExp(r'[A-Za-z]').hasMatch(sample);

  // 1. 当前句有明确的表音文字特征：直接采信，不受全局语境影响。
  if (hasKana) return 'ja';
  if (hasHangul) return 'ko';
  // 2. 纯拉丁英文句（含字母、无汉字/假名/韩文）→ 判英文，这是误判为韩语的关键修正。
  if (hasLatin && !hasHan) return 'en';
  // 3. 含汉字的句子：粤语标记优先，否则用全局语境（中文轨里的日语/韩语汉字词）。
  if (hasHan) {
    if (isYue || langContext == 'yue' ||
        CaptionOfflinePhonetics.hasCantoneseParticles(sample)) return 'yue';
    if (langContext == 'ja') return 'ja';
    if (langContext == 'ko') return 'ko';
    return 'zh-CN';
  }
  // 4. 其它语言（西里尔/阿拉伯/泰文等）或纯数字：用 detectLanguage 兜底。
  final detected = CaptionPronunciation.detectLanguage(sample);
  if (detected.isNotEmpty && detected != 'auto') return detected;
  // 5. 最后才回退全局语境。
  if (langContext != null && langContext.isNotEmpty) return langContext;
  return 'auto';
}

/// 字幕窗口高度 = 「字幕框显示行数」× 单行视觉高度 + 内边距。
///
/// 字幕条是一个【固定高度的滚动窗口】：行数由设置面板的 sentenceMaxLines(2-6) 决定，
/// 队列在这个窗口内滚动（新句从下方进入、旧句向上推）。窗口必须固定，
/// 内容超出才有滚动空间——这正是"滚动逻辑"与"行数设置生效"的关键。
double captionWindowHeight({
  required double fontSize,
  required int lines,
}) {
  const double lineFactor = 1.45; // 每行视觉高度 ≈ 字号 × 1.45（含行距）
  const double padding = 8.0; // 上下各 4 的余量
  final int safeLines = lines.clamp(2, 6);
  return fontSize * lineFactor * safeLines + padding;
}

/// 字幕顶边位置。手动位置按屏高记录，窗口变化后按实际字幕高度保护边界。
double captionTopPosition({
  required double screenHeight,
  required double captionHeight,
  required double bottomInset,
  double? defaultTop,
  double? topFraction,
}) {
  final top = topFraction != null
      ? topFraction * screenHeight
      : defaultTop ?? screenHeight - bottomInset - captionHeight;
  return top.clamp(0.0, math.max(0.0, screenHeight - captionHeight));
}

class _CaptionPositionDelegate extends SingleChildLayoutDelegate {
  _CaptionPositionDelegate({this.topFraction, this.defaultTop, required this.bottomInset});

  final double? topFraction;
  final double? defaultTop;
  final double bottomInset;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest);

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
        (size.width - childSize.width) / 2,
        captionTopPosition(
          screenHeight: size.height,
          captionHeight: childSize.height,
          bottomInset: bottomInset,
          defaultTop: defaultTop,
          topFraction: topFraction,
        ),
      );

  @override
  bool shouldRelayout(_CaptionPositionDelegate oldDelegate) =>
      topFraction != oldDelegate.topFraction ||
      defaultTop != oldDelegate.defaultTop ||
      bottomInset != oldDelegate.bottomInset;
}

/// 估算一段文字在 [availableWidth] 宽度内占用的换行行数（中英文混排）。
///
/// 全角字符（汉字/假名/谚文/全角标点）按 1 个字宽估算，半角（拉丁/数字/空格）
/// 按 0.55 字宽估算。这是【显示层】的预算估算：估算偏差只影响一次多显示/少
/// 显示一行旧句，不会裁切任何文字——字幕框高度始终由真实内容撑开。
int estimateCaptionLineCount(
  String text, {
  required double availableWidth,
  required double fontSize,
}) {
  if (text.isEmpty) return 1;
  if (availableWidth <= 0 || fontSize <= 0) return 1;

  int lines = 1;
  double lineWidth = 0;
  for (final int rune in text.runes) {
    final double w = _captionCharWidth(rune, fontSize);
    if (lineWidth + w > availableWidth && lineWidth > 0) {
      lines++;
      lineWidth = w;
    } else {
      lineWidth += w;
    }
  }
  return lines;
}

double _captionCharWidth(int rune, double fontSize) {
  final bool fullwidth = (rune >= 0x2E80 && rune <= 0x9FFF) || // CJK 部首/汉字/假名/谚文
      (rune >= 0x3000 && rune <= 0x303F) || // CJK 标点
      (rune >= 0xF900 && rune <= 0xFAFF) || // 兼容汉字
      (rune >= 0xFF00 && rune <= 0xFFEF) || // 全角形式
      (rune >= 0xAC00 && rune <= 0xD7AF); // 谚文音节
  return fullwidth ? fontSize : fontSize * 0.55;
}

/// 把一段文字的头部按估算行数截掉，返回剩余子串（用于超长句只显示尾部 N 行）。
/// 显示层的滚动窗口效果：被截掉的头部相当于已向上滚出字幕框的内容。
String truncateCaptionHeadByLines(
  String text,
  int linesToRemove, {
  required double availableWidth,
  required double fontSize,
}) {
  if (text.isEmpty || linesToRemove <= 0) return text;
  if (availableWidth <= 0 || fontSize <= 0) return text;

  final double budget = linesToRemove * availableWidth;
  double width = 0;
  int cutIndex = 0;
  for (final int rune in text.runes) {
    final double w = _captionCharWidth(rune, fontSize);
    if (width + w > budget) break;
    width += w;
    cutIndex += String.fromCharCode(rune).length;
  }
  if (cutIndex <= 0) return text;
  if (cutIndex >= text.length) return '';
  return text.substring(cutIndex);
}

/// 字幕框可见内容片段：新句重起行、总行数受「显示行数」预算约束、向上滚动。
class CaptionWindowSegment {
  const CaptionWindowSegment({
    required this.text,
    required this.isLatest,
    required this.sourceIndex,
    this.headTruncated = false,
  });

  final String text;
  final bool isLatest;
  /// 对应入参 texts 中的下标，供渲染层精确回查该句的翻译/注音等附加信息。
  final int sourceIndex;
  /// 头部是否被滚动出窗口（仅最新句超长时为 true）
  final bool headTruncated;
}

/// 计算字幕框应显示的内容片段。
///
/// 设计（用户定稿）：
/// - 只有一个字幕框；每句【新句重起行】；
/// - 「显示行数」(2-6) 是框内最多可见行数；
/// - 内容从下往上滚动：先装满最新句，再用剩余行预算装更旧的句子，装不下为止；
/// - 最新一句永远完整可见：若它自身超过预算行数，只显示它的尾部 N 行（头部
///   视为已滚出框外），其余句子不受影响——绝不删除队列内容，仅显示窗口。
List<CaptionWindowSegment> captionWindowSegments({
  required List<String> texts,
  required int maxLines,
  required double availableWidth,
  required double fontSize,
}) {
  final int safeLines = maxLines.clamp(1, 20);
  final int latestIndex = texts.length - 1;
  if (latestIndex < 0) return const [];

  final segments = <CaptionWindowSegment>[];
  int usedLines = 0;
  for (int i = latestIndex; i >= 0; i--) {
    final text = texts[i];
    if (i == latestIndex) {
      final int lineCount = estimateCaptionLineCount(
        text,
        availableWidth: availableWidth,
        fontSize: fontSize,
      );
      if (lineCount > safeLines) {
        final tail = truncateCaptionHeadByLines(
          text,
          lineCount - safeLines,
          availableWidth: availableWidth,
          fontSize: fontSize,
        );
        segments.add(CaptionWindowSegment(
          text: tail,
          isLatest: true,
          sourceIndex: i,
          headTruncated: true,
        ));
        usedLines = safeLines;
      } else {
        segments.add(CaptionWindowSegment(
          text: text,
          isLatest: true,
          sourceIndex: i,
        ));
        usedLines = lineCount;
      }
    } else {
      if (text.isEmpty) continue;
      final int lineCount = estimateCaptionLineCount(
        text,
        availableWidth: availableWidth,
        fontSize: fontSize,
      );
      if (usedLines + lineCount > safeLines) break;
      usedLines += lineCount;
      segments.add(CaptionWindowSegment(
        text: text,
        isLatest: false,
        sourceIndex: i,
      ));
    }
  }
  return segments.reversed.toList(growable: false);
}

/// 竖屏全屏下字幕条【顶边】应处的绝对屏幕 Y 坐标（像素），让字幕跟在画面下方、不压画面。
///
/// 竖屏全屏时横屏视频用 BoxFit.contain 居中，上下留黑边。字幕必须落在画面
/// 下方的黑边里（跟在播放器后面），而不是叠在画面上。此函数按视频显示宽高比
/// 算出画面下沿，返回「画面下沿 + [gap]」作为字幕顶边的绝对位置。
///
/// [cardHeight] 必须传字幕窗口的【实际高度】（行数×行高），不能传屏幕百分比：
/// 用大值反推会把顶边 clamp 到屏幕上方，导致字幕压在画面上。
///
/// [screenW]/[screenH] 为整个播放器可视尺寸（用于换算视频画面几何）。
/// 返回 null 表示无需上移（视频几乎铺满屏幕、参数无效等），调用方保持沉底。
double? portraitCaptionTopY({
  required double screenW,
  required double screenH,
  required double videoAspect,
  required double cardHeight,
  double gap = 12.0,
  double minBottomMargin = 12.0,
}) {
  if (!videoAspect.isFinite || videoAspect <= 0) return null;
  if (screenW <= 0 || screenH <= 0 || cardHeight <= 0) return null;

  // contain：视频宽铺满，高 = 宽 / 显示宽高比；但不超过屏幕高度。
  final double videoH = math.min(screenH, screenW / videoAspect);
  // 视频几乎铺满整屏（竖屏视频），画面下沿就在屏幕底，无需上移。
  if (videoH >= screenH - 1) return null;

  final double videoBottomY = (screenH + videoH) / 2;
  // 目标：字幕条【顶边】= 画面下沿 + gap，整块落在画面下方的黑边里。
  final double targetTop = videoBottomY + gap;
  // 保护：字幕底边不要超出屏幕，至少留 minBottomMargin。
  // 用实际窗口高度反推，避免用屏幕百分比把它顶到画面上方。
  final double maxTop = screenH - cardHeight - minBottomMargin;
  if (targetTop > maxTop) return maxTop;
  return targetTop;
}

/// 拖动后的像素左上角 → 归一化对齐坐标（-1..1），用于持久化。
/// -1=左/上，0=居中，1=右/下；与 Alignment 的语义一致。
Offset captionPositionToAlignment({
  required double left,
  required double top,
  required double screenWidth,
  required double screenHeight,
  required double cardWidth,
  required double cardHeight,
}) {
  final double maxX = math.max(0.0, screenWidth - cardWidth);
  final double maxY = math.max(0.0, screenHeight - cardHeight);
  if (maxX <= 0 || maxY <= 0) return Offset.zero;
  return Offset(
    (left / maxX * 2 - 1).clamp(-1.0, 1.0),
    (top / maxY * 2 - 1).clamp(-1.0, 1.0),
  );
}

/// 归一化对齐坐标（-1..1）→ 像素左上角，钳制在屏幕内。
Offset captionAlignmentToPosition({
  required double alignX,
  required double alignY,
  required double screenWidth,
  required double screenHeight,
  required double cardWidth,
  required double cardHeight,
}) {
  final double maxX = math.max(0.0, screenWidth - cardWidth);
  final double maxY = math.max(0.0, screenHeight - cardHeight);
  final double ax = alignX.clamp(-1.0, 1.0);
  final double ay = alignY.clamp(-1.0, 1.0);
  return Offset(
    ((ax + 1) / 2 * maxX).clamp(0.0, maxX),
    ((ay + 1) / 2 * maxY).clamp(0.0, maxY),
  );
}

/// 三态展开/收起图标矢量绘制器 (100%还原用户截帧)
/// mode 1: 收起 ⌞ ⌝ (向内折角，单行模式)
/// mode 2: 展开 ⌜ ⌟ (向外扩展，双行模式)
/// mode 3: 全景 [ ▢ ] (四角 + 中间方块，3-4行大提词器模式)
class CaptionStateIconPainter extends CustomPainter {
  final int mode;
  final Color color;

  CaptionStateIconPainter({required this.mode, this.color = Colors.white});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.miter
      ..style = PaintingStyle.stroke;

    final w = size.width;
    final h = size.height;
    final pad = w * 0.20;
    final arm = w * 0.22;

    if (mode == 1) {
      // 状态1: 收起 / 紧凑单行 (对角向内折角，舒展开放，两臂向外展开，中间保留呼吸感)
      // 左上内折角：角顶点在内侧 (0.42, 0.42)，两臂分别向左、向上延伸至外侧边缘
      final p1 = Path()
        ..moveTo(pad, h * 0.42)
        ..lineTo(w * 0.42, h * 0.42)
        ..lineTo(w * 0.42, pad);
      // 右下内折角：角顶点在内侧 (0.58, 0.58)，两臂分别向右、向下延伸至外侧边缘
      final p2 = Path()
        ..moveTo(w - pad, h * 0.58)
        ..lineTo(w * 0.58, h * 0.58)
        ..lineTo(w * 0.58, h - pad);
      canvas.drawPath(p1, paint);
      canvas.drawPath(p2, paint);
    } else if (mode == 2) {
      // 状态2: 展开 / 双行模式 (向外扩展，两角在最外侧)
      final p1 = Path()
        ..moveTo(pad, pad + arm)
        ..lineTo(pad, pad)
        ..lineTo(pad + arm, pad);
      final p2 = Path()
        ..moveTo(w - pad, h - pad - arm)
        ..lineTo(w - pad, h - pad)
        ..lineTo(w - pad - arm, h - pad);
      canvas.drawPath(p1, paint);
      canvas.drawPath(p2, paint);
    } else {
      // 状态3: 全景多行模式 [ ▢ ] (四角 + 中间小方块)
      final cArm = arm * 0.75;
      // 左上
      canvas.drawPath(
          Path()
            ..moveTo(pad, pad + cArm)
            ..lineTo(pad, pad)
            ..lineTo(pad + cArm, pad),
          paint);
      // 右上
      canvas.drawPath(
          Path()
            ..moveTo(w - pad, pad + cArm)
            ..lineTo(w - pad, pad)
            ..lineTo(w - pad - cArm, pad),
          paint);
      // 左下
      canvas.drawPath(
          Path()
            ..moveTo(pad, h - pad - cArm)
            ..lineTo(pad, h - pad)
            ..lineTo(pad + cArm, h - pad),
          paint);
      // 右下
      canvas.drawPath(
          Path()
            ..moveTo(w - pad, h - pad - cArm)
            ..lineTo(w - pad, h - pad)
            ..lineTo(w - pad - cArm, h - pad),
          paint);
      // 中间小矩形
      final centerPaint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;
      final centerRect = RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(w / 2, h / 2), width: w * 0.36, height: h * 0.26),
        const Radius.circular(1.5),
      );
      canvas.drawRRect(centerRect, centerPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CaptionStateIconPainter oldDelegate) =>
      oldDelegate.mode != mode || oldDelegate.color != color;
}

class CaptionOverlay extends StatefulWidget {
  const CaptionOverlay({
    required this.captions,
    required this.preferences,
    this.playerController,
    this.isInline = false,
    this.controlsOnly = false,
    super.key,
  });

  final RealtimeCaptions captions;
  final CaptionPreferences preferences;
  final PlPlayerController? playerController;
  final bool isInline; // 是否为外置在播放器下方的嵌入模式
  /// 仅渲染左右边缘控制层（不含字幕条）：嵌入模式下叠加到视频画面上，
  /// 字幕条仍由画面下方的另一个 CaptionOverlay 实例渲染。
  final bool controlsOnly;

  @override
  State<CaptionOverlay> createState() => _CaptionOverlayState();
}

class _CaptionOverlayState extends State<CaptionOverlay> {
  @override
  void initState() {
    super.initState();
    JapaneseReadingService.shared.addListener(_japaneseReadingsChanged);
  }

  void _japaneseReadingsChanged() {
    if (mounted) setState(() {});
  }
  final GlobalKey _bubbleKey = GlobalKey();
  final GlobalKey _positionKey = GlobalKey();
  static const double _dragHandleHeight = 48;

  /// 本次播放器会话的手动位置，松手保留；null 使用默认停靠位置。
  double? _captionTopFraction;
  bool _isDraggingCaption = false;

  /// 左右边缘侧栏是否召唤显示（触碰边缘出现，停留数秒后自动缩回屏幕外）
  bool _leftRailVisible = false;
  bool _rightRailVisible = false;
  Timer? _leftRailTimer;
  Timer? _rightRailTimer;
  /// 边缘触碰后侧栏停留时长
  static const Duration _railStayDuration = Duration(seconds: 4);

  /// 触碰边缘召唤对应侧栏，并重新开始停留计时
  void _summonRail(bool left) {
    setState(() {
      if (left) {
        _leftRailVisible = true;
      } else {
        _rightRailVisible = true;
      }
    });
    final existing = left ? _leftRailTimer : _rightRailTimer;
    existing?.cancel();
    final timer = Timer(_railStayDuration, () {
      if (!mounted) return;
      setState(() {
        if (left) {
          _leftRailVisible = false;
        } else {
          _rightRailVisible = false;
        }
      });
    });
    if (left) {
      _leftRailTimer = timer;
    } else {
      _rightRailTimer = timer;
    }
  }

  /// 在侧栏内操作按钮时顺延停留时间，避免正要点却被收起
  void _keepRailVisible(bool left) {
    if (!(left ? _leftRailVisible : _rightRailVisible)) return;
    _summonRail(left);
  }

  RealtimeCaptions get captions => widget.captions;
  CaptionPreferences get preferences => widget.preferences;
  PlPlayerController? get playerController => widget.playerController;

  void _resetPosition() {
    // 恢复默认停靠：横屏水平居中、贴底；竖屏跟在画面下沿。
    // 清除本会话手动位置；同时清掉历史持久化的旧 alignX/alignY 残留，
    // 避免它们在未来被误读（当前默认定位已完全不依赖这两个值）。
    setState(() {
      _captionTopFraction = null;
      _isDraggingCaption = false;
    });
    widget.preferences.resetPosition();
    SmartDialog.showToast('字幕已恢复默认位置');
  }

  void _toggleStateMode() {
    // 三态按钮只切换字幕框显示模式（紧凑/标准/全景），
    // 与"缓存句子数量"完全无关——后者仅决定队列保留多少句供滑动查看。
    preferences.cycleViewMode();
  }

  @override
  void dispose() {
    JapaneseReadingService.shared.removeListener(_japaneseReadingsChanged);
    _leftRailTimer?.cancel();
    _rightRailTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // 只要未开启字幕，彻底隐藏
      if (!captions.enabled) return const SizedBox.shrink();

      // 仅控制层模式：嵌入（竖屏视频详情页）时叠加在视频画面上，
      // 只渲染左右边缘触控带与侧栏，字幕条由画面下方的另一实例渲染。
      if (widget.controlsOnly) {
        return LayoutBuilder(builder: (context, constraints) {
          final int btnMode = preferences.viewMode.value.clamp(1, 3);
          return Stack(
            fit: StackFit.expand,
            children: _buildRailLayer(
              screenW: constraints.maxWidth,
              screenH: constraints.maxHeight,
              btnMode: btnMode,
            ),
          );
        });
      }

      final queue = captions.sentenceQueue;
      final frame = captions.frame.value;
      final hasQueue = queue.isNotEmpty;
      final original =
          captions.showOriginal.value ? frame?.cue.text ?? '' : '';
      final translation =
          captions.showTranslation.value ? frame?.translation ?? '' : '';
      final pronunciation =
          captions.showPronunciation.value ? frame?.pronunciation ?? '' : '';

      final status = !hasQueue &&
              original.isEmpty &&
              translation.isEmpty &&
              pronunciation.isEmpty
          ? [
              captions.asrError.value,
              captions.translationError.value,
              captions.status.value,
            ].firstWhere((message) => message.isNotEmpty, orElse: () => '')
          : '';

      // 字幕框高度由真实文字内容撑开（见 _buildCaptionLines），
      // 只显示最近 N 句，顶边天然是完整一句——不再用固定窗口 + 贴底滚动裁切，
      // 那正是中英文行高不一致时"顶部文字被拦腰斩断"的根因。
      final appearance = preferences.appearance.value;
      final textColor = Color(appearance.captionColor);
      final rubyColor = Color(appearance.pronunciationColor);

      return LayoutBuilder(builder: (context, constraints) {
        final bool isLandscape = constraints.maxWidth > constraints.maxHeight;
        final double screenW = constraints.maxWidth;
        final double screenH = constraints.maxHeight;

        // 横屏字幕条限制为屏幕宽的 3/5（左右各留约 1/5），避免过宽分散注意力；
        // 竖屏仍全宽，仅留左右安全边距。
        final double baseWidth = captionBarWidth(
          screenWidth: screenW,
          isLandscape: isLandscape,
        );

        // 字幕条 = 【一个字幕框】：框内可见行数由「字幕框显示行数」(2-6) 决定，
        // 新句重起行、内容从下往上滚动（旧句滚出框顶），框高度由真实文字撑开。
        // 三态按钮(紧凑/标准/全景)与设置面板的行数滑块统一到同一个值：2 / 4 / 6。
        final int viewMode = preferences.viewMode.value.clamp(1, 3);
        final int sentenceMaxLines = preferences.sentenceMaxLines.value.clamp(2, 6);
        final double fixedWidth = baseWidth;

        // 距底距离沿用设置面板的 bottom（仅默认停靠时使用）。
        final double bottomInset = math.min(
          appearance.bottom,
          math.max(0.0, screenH - 50),
        );

        // 竖屏全屏：横屏视频 contain 居中、上下留黑。字幕跟在画面下方的黑边里，
        // 【顶边】离画面下沿一个小间距，不叠在画面上。用真实窗口高度反推，避免压画面。
        final double? videoAspect =
            playerController?.videoPlayerController?.state.videoParams.aspect;

        // 竖屏全屏：横屏视频 contain 居中，下方有一条黑边。字幕贴这条黑边的底，
        // 高度由内容向上生长，并用 maxHeight 限制不超过黑边高度——既不压画面，也不溢出屏幕。
        // 这样无需预知字幕真实高度，中英文行高不同也能精确贴合。
        final double belowVideoH = (videoAspect != null && videoAspect > 0)
            ? (screenH - screenW / videoAspect).clamp(
                0.0,
                screenH.toDouble(),
              ) /
                2
            : 0.0;
        // 黑边须同时容纳把手、至少一行字幕和边距，否则退化成普通贴底。
        final bool useVideoBottomZone = !isLandscape &&
            !widget.isInline &&
            belowVideoH >= _dragHandleHeight + 40 + 18;

        // 水平方向始终居中，由布局代理保证，
        // 字幕条固定 3/5 宽、左右各留 1/5，绝不再读取持久化的 alignX
        // ——历史上拖动写入的水平偏移正是"又不是居中"的根源。

        // 三态按钮图标直接显示当前显示模式（1=紧凑 2=标准 3=全景）
        final int btnMode = viewMode;

        // 核心字幕条：单一字幕框，高度由真实文字撑开（Column mainAxisSize.min）。
        Widget buildMainCard({double? width}) {
          return AnimatedContainer(
            key: _bubbleKey,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeInOutCubic,
            width: width,
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 文字为空时的常驻占位或状态提示（开=常驻，绝不闪退）
                if (!hasQueue && original.isEmpty && status.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Center(
                      child: _captionText(status, 12, Colors.white70),
                    ),
                  )
                else if (!hasQueue && original.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Center(
                      child: Text(
                        '正在聆听并识别字幕…',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.55),
                          fontSize: 12,
                          shadows: const [
                            Shadow(color: Colors.black, blurRadius: 4),
                          ],
                        ),
                      ),
                    ),
                  )
                else
                  // 单一字幕框：新句重起行、按「显示行数」预算从下往上滚动。
                  _buildCaptionLines(
                    context: context,
                    queue: hasQueue
                        ? queue
                        : [
                            CaptionSentenceItem(
                              id: 'single_frame',
                              original: original,
                              translation: translation,
                              pronunciation: pronunciation,
                              isLatest: true,
                              isFinal: false,
                            )
                          ],
                    maxLines: sentenceMaxLines,
                    // 框内水平 padding 8×2，文字实际可用宽度要扣掉。
                    availableWidth: math.max(40.0, fixedWidth - 16),
                    textColor: textColor,
                    rubyColor: rubyColor,
                    fontSize: appearance.fontSize,
                    backgroundColor: Color(appearance.backgroundColor),
                    backgroundOpacity: appearance.backgroundOpacity,
                  ),
              ],
            ),
          );
        }

        final subtitleBar = buildMainCard(
          width: widget.isInline ? null : fixedWidth,
        );

        // 嵌入模式（播放器下方窄条）：六颗控制钮已移到画面左右边缘的召唤侧栏，
        // 这里只保留纯净的字幕条，不再显示水平胶囊。
        if (widget.isInline) {
          return Center(child: subtitleBar);
        }

        // 全屏模式：字幕条贴底，高度由内容向上生长；左右边缘召唤侧栏。
        // 横屏直接贴底（bottomInset）。
        // 竖屏全屏：字幕【顶边】锚定在画面下沿 + 小间距（紧跟播放器、紧凑），
        // 整体限高在黑边内——既不压画面也不溢出；不再贴屏幕底部留大空隙。
        // 手动拖动后保留位置；只按屏幕边界限制，不限制拖动距离。
        final double restInset = bottomInset;
        // 竖屏：字幕顶边 = 画面下沿 + 10px 间距；整体最大高度 = 黑边高度 - 余量，
        // 确保底边不溢出屏幕、顶边不进入画面。极长句超出上限时内部反向滚动兜底。
        final double? portraitTopAnchor = useVideoBottomZone
            ? math.max(0.0, screenH - belowVideoH + 10)
            : null;
        final double maxCaptionH = math.max(
          0.0,
          useVideoBottomZone ? belowVideoH - 18 : screenH - restInset,
        );

        // 把手独立于文字滚动区，避免滚出视野或被滚动手势抢走。
        final handleHeight = math.min(_dragHandleHeight, maxCaptionH);
        final captionColumn = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: fixedWidth,
              height: handleHeight,
              child: _buildDragHandle((delta) {
                final box = _positionKey.currentContext?.findRenderObject();
                if (box is! RenderBox || !box.hasSize || screenH <= 0) return;
                final top = captionTopPosition(
                  screenHeight: screenH,
                  captionHeight: box.size.height,
                  bottomInset: restInset,
                  defaultTop: portraitTopAnchor,
                  topFraction: _captionTopFraction,
                );
                // 直接钳制累计值，拖到边界后反向滑动立即响应。
                setState(() {
                  _captionTopFraction = (top + delta)
                      .clamp(0.0, math.max(0.0, screenH - box.size.height)) / screenH;
                });
              }),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: math.max(0.0, maxCaptionH - handleHeight),
              ),
              child: SingleChildScrollView(
                reverse: true,
                physics: const ClampingScrollPhysics(),
                child: subtitleBar,
              ),
            ),
          ],
        );
        final captionWithHandle = CustomSingleChildLayout(
          delegate: _CaptionPositionDelegate(
            topFraction: _captionTopFraction,
            defaultTop: portraitTopAnchor,
            bottomInset: restInset,
          ),
          child: SizedBox(
            key: _positionKey,
            width: fixedWidth,
            child: captionColumn,
          ),
        );

        return Stack(
          fit: StackFit.expand,
          children: [
            // 布局和触摸坐标一起移动，拖出原停靠区后仍能再次按中。
            captionWithHandle,

            // 左右边缘触控带 + 滑入式侧栏（与嵌入仅控制层模式共用）
            ..._buildRailLayer(
              screenW: screenW,
              screenH: screenH,
              btnMode: btnMode,
            ),
          ],
        );
      });
    });
  }

  /// 整宽触摸区域始终可用，指示条仅拖动时显示。长按恢复默认停靠。
  Widget _buildDragHandle(ValueChanged<double> onDrag) {
    return Semantics(
      label: '上下拖动字幕框，松手保留位置，长按恢复默认',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onVerticalDragStart: (_) => setState(() => _isDraggingCaption = true),
        onVerticalDragUpdate: (details) => onDrag(details.delta.dy),
        onVerticalDragEnd: (_) {
          setState(() => _isDraggingCaption = false);
        },
        onVerticalDragCancel: () {
          setState(() => _isDraggingCaption = false);
        },
        onLongPress: _resetPosition,
        child: MouseRegion(
          cursor: _isDraggingCaption ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
          child: Center(
            child: Opacity(
              key: const ValueKey('caption-drag-indicator'),
              opacity: _isDraggingCaption ? 1 : 0,
              child: Container(
                width: 64,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 左右边缘触控带 + 两组滑入式侧栏。
  /// 全屏模式（字幕条同层）与嵌入仅控制层模式（叠加在画面上）共用此层。
  List<Widget> _buildRailLayer({
    required double screenW,
    required double screenH,
    required int btnMode,
  }) {
    return [
      // 左右边缘触控带：手指触碰边缘对应位置即召唤侧栏。
      // vertical 只覆盖中段，避开播放器头部返回/底部进度条，减少误触。
      Positioned(
        left: 0,
        top: screenH * 0.18,
        bottom: screenH * 0.18,
        width: 28,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapDown: (_) => _summonRail(true),
          onPanDown: (_) => _summonRail(true),
          child: const SizedBox.expand(),
        ),
      ),
      Positioned(
        right: 0,
        top: screenH * 0.18,
        bottom: screenH * 0.18,
        width: 28,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapDown: (_) => _summonRail(false),
          onPanDown: (_) => _summonRail(false),
          child: const SizedBox.expand(),
        ),
      ),

      // 左侧栏：识别源三选一（B站官方 / 云端 / Sherpa）
      _buildEdgeRail(
        left: true,
        visible: _leftRailVisible,
        screenW: screenW,
        screenH: screenH,
        child: _buildSourceToggleGroup(context, vertical: true),
      ),
      // 右侧栏：折叠 / 翻译 / 注音
      _buildEdgeRail(
        left: false,
        visible: _rightRailVisible,
        screenW: screenW,
        screenH: screenH,
        child: _buildRightControlColumn(context, btnMode, vertical: true),
      ),
    ];
  }

  /// 边缘滑入式侧栏：从屏幕外滑入/滑出（AnimatedPositioned 实现动画），
  /// 竖向排列按钮组，触碰边缘召唤、停留在屏幕边缘、超时自动缩回。
  Widget _buildEdgeRail({
    required bool left,
    required bool visible,
    required double screenW,
    required double screenH,
    required Widget child,
  }) {
    // 侧栏宽度约 44（按钮 28 + 内边距），隐藏时整体移出屏幕外。
    const double railW = 44.0;
    const double margin = 6.0;
    final double shownLeft =
        left ? margin : screenW - railW - margin;
    final double hiddenLeft =
        left ? -railW - 8 : screenW + 8;

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      left: visible ? shownLeft : hiddenLeft,
      top: screenH * 0.32,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 260),
        opacity: visible ? 1.0 : 0.0,
        child: IgnorePointer(
          ignoring: !visible,
          child: GestureDetector(
            // 侧栏内交互顺延停留时间
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => _keepRailVisible(left),
            child: Container(
              width: railW,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.42),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: Colors.white.withOpacity(0.12),
                  width: 0.5,
                ),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  /// 左侧识别方式 3 选 1 Toggle Group (单选切换组)
  /// 📺 B站官方 | ☁️ Qwen 在线 | ⚡ Sherpa 本地离线
  Widget _buildSourceToggleGroup(BuildContext context, {bool vertical = false}) {
    final activeSource = captions.activeSourceType;

    Widget buildToggleItem({
      required String type,
      required IconData icon,
      required String label,
      required Color activeBg,
      required Color activeBorder,
      required Color activeIconColor,
    }) {
      final bool isSelected = activeSource == type;

      return Tooltip(
        message: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            captions.switchSubtitleSource(type);
            SmartDialog.showToast('已切换为: $label');
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isSelected ? activeBg : Colors.black.withOpacity(0.4),
              border: Border.all(
                color: isSelected
                    ? activeBorder
                    : Colors.white.withOpacity(0.16),
                width: isSelected ? 0.9 : 0.5,
              ),
            ),
            child: Icon(
              icon,
              size: 11,
              color: isSelected ? activeIconColor : Colors.white60,
            ),
          ),
        ),
      );
    }

    final gap = vertical
        ? const SizedBox(height: 6)
        : const SizedBox(width: 4);

    final children = [
      // 1. B站官方字幕
      buildToggleItem(
        type: 'official',
        icon: Icons.live_tv_rounded,
        label: 'B站官方字幕',
        activeBg: const Color(0xff3a8fb8),
        activeBorder: const Color(0xff7fc4e0),
        activeIconColor: Colors.white,
      ),
      gap,
      // 2. 云端在线识别
      buildToggleItem(
        type: 'qwen',
        icon: Icons.cloud_outlined,
        label: '云端在线识别',
        activeBg: const Color(0xff4a7fc4),
        activeBorder: const Color(0xff93b8e8),
        activeIconColor: Colors.white,
      ),
      gap,
      // 3. Sherpa 本地离线识别
      buildToggleItem(
        type: 'sherpa',
        icon: Icons.bolt_rounded,
        label: 'Sherpa 本地离线识别',
        activeBg: const Color(0xff7a6bb5),
        activeBorder: const Color(0xffb6a9d9),
        activeIconColor: Colors.white,
      ),
    ];

    if (vertical) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: children,
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: children,
    );
  }

  /// 右侧垂直功能开关列 (折叠/展开 + 文A翻译 + あ注音)
  /// 与左侧识别组统一为 22px 圆钮、无发光、同色系选中态，去掉 Beta 徽标。
  Widget _buildRightControlColumn(BuildContext context, int btnMode,
      {bool vertical = false}) {
    final bool isTransOn = captions.showTranslation.value;
    final bool isPronOn = captions.showPronunciation.value;

    // 未选中态统一底色，选中态统一柔和色系，六颗按钮观感一致
    const idleBg = Color(0x66000000); // black 40%
    const idleBorder = Color(0x29ffffff); // white 16%
    const activeBorder = Color(0x99ffffff); // white 60%

    final gap = vertical
        ? const SizedBox(height: 6)
        : const SizedBox(width: 4);

    return Flex(
      direction: vertical ? Axis.vertical : Axis.horizontal,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 1. 折叠/展开三态切换按钮
        Tooltip(
          message: btnMode == 1 ? '紧凑单行' : (btnMode == 2 ? '标准双行' : '全景多行'),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleStateMode,
            onLongPress: _resetPosition,
            child: Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xff7a6bb5),
                  border: Border.all(
                    color: activeBorder,
                    width: 0.9,
                  ),
                ),
                child: CustomPaint(
                  painter: CaptionStateIconPainter(
                    mode: btnMode,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
        gap,

        // 2. 文A 翻译开关
        Tooltip(
          message: isTransOn ? '点击关闭翻译' : '点击开启翻译',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              final next = !captions.showTranslation.value;
              captions.setTranslation(next);
              preferences.showTranslation.value = next;
              preferences.save();
              SmartDialog.showToast(next ? '已开启实时翻译' : '已关闭实时翻译');
              setState(() {});
            },
            child: Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isTransOn ? const Color(0xff7a6bb5) : idleBg,
                  border: Border.all(
                    color: isTransOn ? activeBorder : idleBorder,
                    width: isTransOn ? 0.9 : 0.5,
                  ),
                ),
                child: Center(
                  child: Text(
                    '文A',
                    style: TextStyle(
                      fontSize: 8.0,
                      fontWeight: FontWeight.bold,
                      color: isTransOn ? Colors.white : Colors.white60,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        gap,

        // 3. あ/拼 注音开关
        Tooltip(
          message: isPronOn ? '点击关闭注音' : '点击开启注音',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              final next = !captions.showPronunciation.value;
              captions.setPronunciation(next);
              preferences.showPronunciation.value = next;
              preferences.save();
              SmartDialog.showToast(next ? '已开启发音注音' : '已关闭发音注音');
              setState(() {});
            },
            child: Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isPronOn ? const Color(0xff4f9a8c) : idleBg,
                  border: Border.all(
                    color: isPronOn ? activeBorder : idleBorder,
                    width: isPronOn ? 0.9 : 0.5,
                  ),
                ),
                child: Center(
                  child: Text(
                    'あ',
                    style: TextStyle(
                      fontSize: 9.0,
                      fontWeight: FontWeight.bold,
                      color: isPronOn ? Colors.white : Colors.white60,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 字幕框渲染（用户定稿设计）：
  /// - 【只有一个字幕框】：整条共用一个背景底块，不再每句各一个框；
  /// - 新句重起行：每个片段独立成段，历史句淡化；
  /// - 「显示行数」= 框内最多可见行数，内容从下往上滚动：
  ///   最新句永远完整（超长时只显示尾部 N 行），旧句用剩余行预算从新到旧装填；
  /// - 框高度由真实文字撑开，不估算整体高度、不裁切任何一行的中部，
  ///   中英文行高不一致也不会出现"顶部半行"。
  Widget _buildCaptionLines({
    required BuildContext context,
    required List<CaptionSentenceItem> queue,
    required int maxLines,
    required double availableWidth,
    required Color textColor,
    required Color rubyColor,
    required double fontSize,
    required Color backgroundColor,
    required double backgroundOpacity,
  }) {
    if (maxLines >= 2) {
      final showOriginal = captions.showOriginal.value;
      final latest = queue.isEmpty ? null : queue.last;
      final entries = [
        for (final item in queue)
          CaptionRollupEntry(
            text: showOriginal ? item.original : item.translation,
            contextSentence: item.original,
            translation: item.translation,
            contextRanges: item.contextRanges,
            identity: item.createdAt,
            pronunciation: item.pronunciation,
          ),
      ];
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(builder: (context, constraints) => CaptionRollup(
            entries: entries,
            maxLines: maxLines,
            showPronunciation: showOriginal && captions.showPronunciation.value,
            rubyForLine: _rollupRubyUnits,
            rubyForEntry: _contextualRubyUnits,
            pronunciationColor: rubyColor,
            pronunciationFontSize: preferences.appearance.value.pronunciationFontSize,
            width: constraints.maxWidth,
            style: TextStyle(
              color: textColor,
              fontSize: fontSize,
              height: 1.25,
              fontWeight: FontWeight.w400,
            ),
            backgroundColor: backgroundColor.withOpacity(backgroundOpacity),
            onWordTap: (word, entry) {
              showCaptionDictionarySheet(
                context: context,
                word: word,
                contextSentence: entry.contextSentence,
                contextTranslation: entry.translation,
                sourceLanguage: solveQueryLanguage(
                  sentence: entry.contextSentence,
                  query: word,
                  langContext: captions.currentLanguageContext,
                  isYue: captions.isCantoneseTrack,
                ),
                playerController: playerController,
              );
            },
          )),
          if (showOriginal && captions.showTranslation.value &&
              latest != null && latest.translation.isNotEmpty &&
              latest.translation != latest.original)
            Padding(
              padding: const EdgeInsets.only(top: 3, left: 6),
              child: _captionText(latest.translation, fontSize * 0.88,
                  const Color(0xffffe082)),
            ),
        ],
      );
    }
    final segments = captionWindowSegments(
      texts: queue.map((item) => item.original).toList(),
      maxLines: maxLines,
      availableWidth: availableWidth,
      fontSize: fontSize,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: backgroundColor.withOpacity(backgroundOpacity),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final segment in segments)
            _buildCaptionSegment(
              context: context,
              item: queue[segment.sourceIndex],
              segment: segment,
              textColor: textColor,
              rubyColor: rubyColor,
              fontSize: fontSize,
            ),
        ],
      ),
    );
  }

  List<CaptionRubyUnit>? _contextualRubyUnits(CaptionRollupEntry entry) {
    final lang = solveQueryLanguage(sentence: entry.contextSentence, query: entry.text,
        langContext: captions.currentLanguageContext, isYue: captions.isCantoneseTrack);
    if (lang != 'ja') return null;
    if (JapaneseReadingService.shared.cached(entry.text) == null) {
      unawaited(JapaneseReadingService.shared.analyze(entry.text));
    }
    return buildCaptionRubyUnits(entry.text, sourceLanguage: 'ja',
        japaneseMode: captions.japanesePhonetic.value);
  }

  List<CaptionRubyUnit> _rollupRubyUnits(CaptionRollupLine line) {
    final lang = solveQueryLanguage(
      sentence: line.entry.contextSentence, query: line.text,
      langContext: captions.currentLanguageContext, isYue: captions.isCantoneseTrack,
    );
    if (lang == 'ja') {
      // Frozen rows keep their original layout when pronunciation is enabled.
      // Newly entering rows still read from the whole sentence; a clipped part
      // of a word remains unannotated instead of inventing a partial reading.
      final all = _contextualRubyUnits(line.entry) ?? const <CaptionRubyUnit>[];
      final end = line.startOffset + line.text.length;
      return [for (final unit in all)
        if (unit.startOffset < end && unit.startOffset + unit.text.length > line.startOffset)
          CaptionRubyUnit(
            line.entry.text.substring(math.max(line.startOffset, unit.startOffset),
                math.min(end, unit.startOffset + unit.text.length)),
            unit.startOffset >= line.startOffset && unit.startOffset + unit.text.length <= end
                ? unit.pronunciation : '',
            math.max(0, unit.startOffset - line.startOffset)),
      ];
    }
    return buildCaptionRubyUnits(line.text,
      sourceLanguage: lang,
      japaneseMode: captions.japanesePhonetic.value,
      chineseMode: captions.chinesePhonetic.value,
      isCantonese: captions.isCantoneseTrack,
    );
  }

  /// 单个片段（一句话或超长句的尾部）：新句重起行，历史句淡化。
  Widget _buildCaptionSegment({
    required BuildContext context,
    required CaptionSentenceItem item,
    required CaptionWindowSegment segment,
    required Color textColor,
    required Color rubyColor,
    required double fontSize,
  }) {
    final bool isLatest = segment.isLatest;
    final lineTextColor =
        isLatest ? textColor : textColor.withOpacity(0.62);
    final lineRubyColor = isLatest ? rubyColor : rubyColor.withOpacity(0.62);

    // 片段文本可能是完整句，也可能是超长句滚出头部后的尾部。
    // 查词上下文（fullSentence）仍用显示文本；被截头时注音随头部一起滚出。
    final displayItem = segment.headTruncated || segment.text != item.original
        ? CaptionSentenceItem(
            id: item.id,
            original: segment.text,
            translation: item.translation,
            pronunciation: segment.headTruncated ? '' : item.pronunciation,
            isLatest: item.isLatest,
            isFinal: item.isFinal,
          )
        : item;

    return Padding(
      padding: const EdgeInsets.only(top: 1.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildSentenceContent(
            context: context,
            item: displayItem,
            fontSize: fontSize,
            color: lineTextColor,
            rubyColor: lineRubyColor,
          ),
          if (captions.showTranslation.value &&
              item.translation.isNotEmpty &&
              item.translation != item.original)
            Padding(
              padding: const EdgeInsets.only(top: 2.0, left: 2.0),
              child: Text(
                item.translation,
                style: TextStyle(
                  color: isLatest
                      ? const Color(0xffffe082)
                      : const Color(0xffffe082).withOpacity(0.62),
                  fontSize: fontSize * 0.88,
                  height: 1.18,
                  fontWeight: FontWeight.w400,
                  shadows: const [
                    Shadow(
                      color: Colors.black,
                      blurRadius: 3,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 单句内容渲染（支持 Ruby 注音及点击单词查词）
  Widget _buildSentenceContent({
    required BuildContext context,
    required CaptionSentenceItem item,
    required double fontSize,
    required Color color,
    required Color rubyColor,
  }) {
    final original = item.original;
    final pronunciation =
        captions.showPronunciation.value ? item.pronunciation : '';

    final rubyPairs = (original.isNotEmpty && pronunciation.isNotEmpty)
        ? _pairRuby(original, pronunciation)
        : null;

    final bool isJapaneseContext = captions.currentLanguageContext == 'ja' ||
        captions.isJapaneseTrack ||
        RegExp(r'[\u3040-\u309F\u30A0-\u30FF]').hasMatch(original);
    final bool isDuplicateOrKanji = pronunciation.trim() == original.trim() ||
        (isJapaneseContext &&
            RegExp(r'[\u4E00-\u9FFF]').hasMatch(pronunciation));

    if (pronunciation.isNotEmpty && !isDuplicateOrKanji && rubyPairs == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _captionText(
            pronunciation,
            preferences.appearance.value.pronunciationFontSize,
            rubyColor,
            letterSpacing: 0.5,
          ),
          _buildInteractiveCaption(
            context: context,
            text: original,
            rubyPairs: null,
            size: fontSize,
            color: color,
            rubyColor: rubyColor,
            fullSentence: original,
            translation: item.translation,
            contextRanges: item.contextRanges,
          ),
        ],
      );
    }

    return _buildInteractiveCaption(
      context: context,
      text: original,
      rubyPairs: rubyPairs,
      size: fontSize,
      color: color,
      rubyColor: rubyColor,
      fullSentence: original,
      translation: item.translation,
      contextRanges: item.contextRanges,
    );
  }

  /// 交互式字幕文本，支持点击单词查词（查词常驻）与字头顶注音对齐（Ruby Text）
  Widget _buildInteractiveCaption({
    required BuildContext context,
    required String text,
    List<_RubyPair>? rubyPairs,
    required double size,
    required Color color,
    Color? rubyColor,
    String? fullSentence,
    String? translation,
    double letterSpacing = 0,
    List<CaptionContextRange> contextRanges = const [],
  }) {
    final contextLang = captions.currentLanguageContext;
    final sentence = fullSentence ?? text;
    final bool isYue = captions.isCantoneseTrack ||
        captions.chinesePhonetic.value == 'cantonese' ||
        contextLang == 'yue' ||
        CaptionPronunciation.isCantoneseText(sentence) ||
        CaptionPronunciation.isCantoneseText(text);

    // 划词查词的语言：以当前句自身字符特征为准，纯英文句不会被全局 ko/ja 语境带偏。
    final sourceLang = solveQueryLanguage(
      sentence: fullSentence ?? text,
      query: text,
      langContext: contextLang,
      isYue: isYue,
    );

    // 1. 若成功按字词对齐发音，以 Ruby 振假名样式展示
    if (rubyPairs != null && rubyPairs.isNotEmpty) {
      final spans = <Widget>[];

      var rubyOffset = 0;
      for (final pair in rubyPairs) {
        final wordOffset = rubyOffset;
        rubyOffset += pair.text.length;
        if (!pair.isWord || pair.text.trim().isEmpty) {
          spans.add(
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(height: preferences.appearance.value.pronunciationFontSize + 1.5),
                Text(
                  pair.text,
                  style: TextStyle(
                    color: color,
                    fontSize: size,
                    height: 1.15,
                    letterSpacing: letterSpacing,
                    fontWeight: FontWeight.w500,
                    shadows: const [
                      Shadow(
                        color: Colors.black,
                        blurRadius: 4,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
          continue;
        }

        final column = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              pair.ruby ?? '',
              style: TextStyle(
                color: rubyColor ?? color.withOpacity(0.9),
                fontSize: preferences.appearance.value.pronunciationFontSize,
                height: 1.0,
                fontWeight: FontWeight.w400,
                shadows: const [
                  Shadow(
                    color: Colors.black,
                    blurRadius: 3,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 1.5),
            Text(
              pair.text,
              style: TextStyle(
                color: color,
                fontSize: size,
                height: 1.15,
                letterSpacing: letterSpacing,
                fontWeight: FontWeight.w500,
                shadows: const [
                  Shadow(
                    color: Colors.black,
                    blurRadius: 4,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
            ),
          ],
        );

        // 查词常驻：随时可点击单词查词
        spans.add(
          InkWell(
            onTap: () {
              showCaptionDictionarySheet(
                context: context,
                word: pair.text,
                contextSentence: fullSentence ?? text,
                  contextWordOffset: wordOffset,
                  contextRanges: contextRanges,
                contextTranslation: translation,
                sourceLanguage: sourceLang,
                playerController: playerController,
              );
            },
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.0),
              child: column,
            ),
          ),
        );
      }

      return Wrap(
        alignment: WrapAlignment.start,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 1.5,
        runSpacing: 3,
        children: spans,
      );
    }

    // 智能切词拆分（查词常驻）
    final items = CaptionWordSegmenter.segmentWithDelimiters(text);
    if (items.isEmpty) {
      return _captionText(text, size, color, letterSpacing: letterSpacing);
    }

    final spans = <InlineSpan>[];

    var tokenOffset = 0;
    for (final item in items) {
      final wordOffset = tokenOffset;
      tokenOffset += item.text.length;
      if (item.isWord) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: InkWell(
              onTap: () {
                showCaptionDictionarySheet(
                  context: context,
                  word: item.text,
                  contextSentence: fullSentence ?? text,
                  contextWordOffset: wordOffset,
                  contextRanges: contextRanges,
                  contextTranslation: translation,
                  sourceLanguage: sourceLang,
                  playerController: playerController,
                );
              },
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 0.5),
                child: Text(
                  item.text,
                  style: TextStyle(
                    color: color,
                    fontSize: size,
                    height: 1.25,
                    letterSpacing: letterSpacing,
                    fontWeight: FontWeight.w500,
                    shadows: const [
                      Shadow(
                        color: Colors.black,
                        blurRadius: 4,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: item.text,
            style: TextStyle(
              color: color,
              fontSize: size,
              height: 1.25,
              letterSpacing: letterSpacing,
              fontWeight: FontWeight.w500,
              shadows: const [
                Shadow(
                  color: Colors.black,
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
        );
      }
    }

    return Text.rich(
      TextSpan(children: spans),
      textAlign: TextAlign.start,
      overflow: TextOverflow.clip,
    );
  }

  Widget _captionText(
    String text,
    double size,
    Color color, {
    double letterSpacing = 0,
  }) {
    return Text(
      text,
      textAlign: TextAlign.start,
      style: TextStyle(
        color: color,
        fontSize: size,
        height: 1.25,
        letterSpacing: letterSpacing,
        fontWeight: FontWeight.w500,
        shadows: const [
          Shadow(color: Colors.black, blurRadius: 4, offset: Offset(0, 1)),
        ],
      ),
    );
  }

  /// 将原文与发音注音进行字词对齐（Ruby Text / 振假名）
  static List<_RubyPair>? _pairRuby(String original, String pronunciation) {
    final orig = original.trim();
    final pron = pronunciation.trim();
    if (orig.isEmpty || pron.isEmpty) return null;

    final hasJapaneseKana =
        RegExp(r'[\u3040-\u309F\u30A0-\u30FF]').hasMatch(orig);
    if (hasJapaneseKana) {
      final jpPairs = _pairJapaneseFurigana(orig, pron);
      if (jpPairs != null && jpPairs.isNotEmpty) {
        return jpPairs;
      }
    }

    final rawPronTokens =
        pron.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (rawPronTokens.isEmpty) return null;

    final pronSyllables = <String>[];
    for (final raw in rawPronTokens) {
      var clean = raw.replaceAll(RegExp(r'^/+|/+$'), '');
      final punctMatch = RegExp(r'[.,!?:;，。！？；：、]+$').firstMatch(clean);
      if (punctMatch != null) {
        final syl = clean.substring(0, punctMatch.start).trim();
        if (syl.isNotEmpty) pronSyllables.add(syl);
      } else {
        if (clean.isNotEmpty) pronSyllables.add(clean);
      }
    }

    if (pronSyllables.isEmpty) return null;

    final tokenRegex = RegExp(
      r"([\u4e00-\u9fa5]|[a-zA-Z0-9'-]+|[\u3040-\u309f\u30a0-\u30ff]+|[\uac00-\ud7af]+|[^\s\w]|[\s]+)",
      unicode: true,
    );

    final matches = tokenRegex.allMatches(orig);
    final units = <String>[];
    for (final m in matches) {
      units.add(m.group(0)!);
    }

    bool isPronounceable(String u) =>
        RegExp(r'[\u4e00-\u9fa5a-zA-Z0-9\u3040-\u30ff\uac00-\ud7af]').hasMatch(u);

    final pronounceableUnits = units.where(isPronounceable).toList();

    if (pronounceableUnits.length == pronSyllables.length) {
      final result = <_RubyPair>[];
      var sylIdx = 0;
      for (final u in units) {
        if (isPronounceable(u)) {
          result.add(_RubyPair(u, pronSyllables[sylIdx++], isWord: true));
        } else {
          result.add(_RubyPair(u, null, isWord: false));
        }
      }
      return result;
    }

    final origWords =
        orig.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (origWords.length == pronSyllables.length && origWords.length > 1) {
      final result = <_RubyPair>[];
      for (var i = 0; i < origWords.length; i++) {
        if (i > 0) result.add(const _RubyPair(' ', null, isWord: false));
        final w = origWords[i];
        final m = RegExp(r'[.,!?:;，。！？；：、]+$').firstMatch(w);
        if (m != null && m.start > 0) {
          final pureWord = w.substring(0, m.start);
          final punct = w.substring(m.start);
          result.add(_RubyPair(pureWord, pronSyllables[i], isWord: true));
          result.add(_RubyPair(punct, null, isWord: false));
        } else {
          result.add(_RubyPair(w, pronSyllables[i], isWord: true));
        }
      }
      return result;
    }

    if (pronounceableUnits.isNotEmpty && pronSyllables.isNotEmpty) {
      final minCount = pronounceableUnits.length < pronSyllables.length
          ? pronounceableUnits.length
          : pronSyllables.length;
      final maxCount = pronounceableUnits.length > pronSyllables.length
          ? pronounceableUnits.length
          : pronSyllables.length;

      if (maxCount - minCount <= 2 && minCount >= 3) {
        final result = <_RubyPair>[];
        var sylIdx = 0;
        for (final u in units) {
          if (isPronounceable(u)) {
            if (sylIdx < pronSyllables.length) {
              result.add(_RubyPair(u, pronSyllables[sylIdx++], isWord: true));
            } else {
              result.add(_RubyPair(u, null, isWord: true));
            }
          } else {
            result.add(_RubyPair(u, null, isWord: false));
          }
        }
        return result;
      }
    }

    return null;
  }

  static List<_RubyPair>? _pairJapaneseFurigana(String orig, String pron) {
    if (orig.isEmpty || pron.isEmpty) return null;
    if (RegExp(r'[\u4E00-\u9FFF]').hasMatch(pron)) return null;

    final chunks = <({String text, bool isKanji})>[];
    var curr = '';
    bool? currIsKanji;
    for (final char in orig.runes) {
      final s = String.fromCharCode(char);
      final isKanji = RegExp(r'[\u4E00-\u9FFF]').hasMatch(s);
      if (currIsKanji == null || isKanji == currIsKanji) {
        curr += s;
        currIsKanji = isKanji;
      } else {
        chunks.add((text: curr, isKanji: currIsKanji));
        curr = s;
        currIsKanji = isKanji;
      }
    }
    if (curr.isNotEmpty && currIsKanji != null) {
      chunks.add((text: curr, isKanji: currIsKanji));
    }

    if (chunks.isEmpty) return null;

    final hasAnyKanji = chunks.any((c) => c.isKanji);
    if (!hasAnyKanji) {
      return chunks.map((c) => _RubyPair(c.text, null, isWord: true)).toList();
    }

    final result = <_RubyPair>[];
    var pIdx = 0;
    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      if (!chunk.isKanji) {
        if (pIdx + chunk.text.length <= pron.length &&
            pron.substring(pIdx, pIdx + chunk.text.length) == chunk.text) {
          result.add(_RubyPair(chunk.text, null, isWord: false));
          pIdx += chunk.text.length;
        } else {
          final idx = pron.indexOf(chunk.text, pIdx);
          if (idx != -1 && idx - pIdx <= 20) {
            result.add(_RubyPair(chunk.text, null, isWord: false));
            pIdx = idx + chunk.text.length;
          } else {
            return null;
          }
        }
      } else {
        if (i + 1 < chunks.length) {
          final nextAnchor = chunks[i + 1].text;
          final idx = pron.indexOf(nextAnchor, pIdx);
          if (idx != -1 && idx >= pIdx) {
            final ruby = pron.substring(pIdx, idx).trim();
            result.add(_RubyPair(
                chunk.text, ruby.isNotEmpty ? ruby : null, isWord: true));
            pIdx = idx;
          } else {
            return null;
          }
        } else {
          final ruby = pron.substring(pIdx).trim();
          result.add(_RubyPair(
              chunk.text, ruby.isNotEmpty ? ruby : null, isWord: true));
          pIdx = pron.length;
        }
      }
    }

    return result;
  }
}

class _RubyPair {
  final String text;
  final String? ruby;
  final bool isWord;

  const _RubyPair(this.text, this.ruby, {this.isWord = true});
}
