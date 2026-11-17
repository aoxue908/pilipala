import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:pilipala/plugin/pl_player/controller.dart';

import 'caption_dictionary_sheet.dart';
import 'caption_preferences.dart';
import 'caption_pronunciation.dart';
import 'realtime_captions.dart';

class CaptionOverlay extends StatefulWidget {
  const CaptionOverlay({
    required this.captions,
    required this.preferences,
    this.playerController,
    super.key,
  });

  final RealtimeCaptions captions;
  final CaptionPreferences preferences;
  final PlPlayerController? playerController;

  @override
  State<CaptionOverlay> createState() => _CaptionOverlayState();
}

class _CaptionOverlayState extends State<CaptionOverlay> {
  final GlobalKey _bubbleKey = GlobalKey();
  double? _dragAlignX;
  double? _dragAlignY;
  bool _isDragging = false;
  double _bubbleWidth = 200;
  double _bubbleHeight = 50;

  RealtimeCaptions get captions => widget.captions;
  CaptionPreferences get preferences => widget.preferences;
  PlPlayerController? get playerController => widget.playerController;

  void _resetPosition() {
    setState(() {
      _dragAlignX = null;
      _dragAlignY = null;
    });
    widget.preferences.resetPosition();
    SmartDialog.showToast('已恢复默认字幕位置');
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (!captions.enabled) return const SizedBox.shrink();
      final frame = captions.frame.value;
      final original =
          captions.showOriginal.value ? frame?.cue.text ?? '' : '';
      final translation =
          captions.showTranslation.value ? frame?.translation ?? '' : '';
      final pronunciation =
          captions.showPronunciation.value ? frame?.pronunciation ?? '' : '';

      final status = original.isEmpty && translation.isEmpty && pronunciation.isEmpty
          ? [
              captions.asrError.value,
              captions.translationError.value,
              captions.status.value,
            ].firstWhere((message) => message.isNotEmpty, orElse: () => '')
          : '';
      if (original.isEmpty &&
          translation.isEmpty &&
          pronunciation.isEmpty &&
          status.isEmpty) {
        return const SizedBox.shrink();
      }
      final appearance = preferences.appearance.value;
      final textColor = Color(appearance.captionColor);
      final rubyColor = Color(appearance.pronunciationColor);

      // 如果外部重置了自定义位置且当前不在拖拽中，同步重置临时状态
      if (!_isDragging && appearance.alignX == null && appearance.alignY == null) {
        _dragAlignX = null;
        _dragAlignY = null;
      }

      final hasCustomPosition = appearance.alignX != null ||
          appearance.alignY != null ||
          _dragAlignX != null ||
          _dragAlignY != null;

      return LayoutBuilder(builder: (context, constraints) {
        final maxWidth = constraints.maxWidth - 32;
        if (maxWidth <= 0) return const SizedBox.shrink();
        final rubyPairs = (original.isNotEmpty && pronunciation.isNotEmpty)
            ? _pairRuby(original, pronunciation)
            : null;

        final availW = math.max(1.0, constraints.maxWidth - 32);
        final availH = math.max(1.0, constraints.maxHeight - 24);

        final currentAlignX = _dragAlignX ?? appearance.alignX ?? 0.0;
        final currentAlignY = _dragAlignY ?? appearance.alignY;

        final Alignment bubbleAlignment = hasCustomPosition && currentAlignY != null
            ? Alignment(currentAlignX, currentAlignY)
            : Alignment.bottomCenter;

        final EdgeInsets bubblePadding = hasCustomPosition && currentAlignY != null
            ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12)
            : EdgeInsets.fromLTRB(
                16,
                12,
                16,
                math.min(
                  appearance.bottom,
                  math.max(0.0, constraints.maxHeight - 40),
                ),
              );

        final tagColor = captions.isNativeSubtitle
            ? Colors.greenAccent
            : (captions.isUsingLocalAsr
                ? const Color(0xffce93d8)
                : Colors.lightBlueAccent);
        final tagBgColor = captions.isNativeSubtitle
            ? Colors.green.withOpacity(0.25)
            : (captions.isUsingLocalAsr
                ? Colors.purple.withOpacity(0.25)
                : Colors.blue.withOpacity(0.25));
        final tagBorderColor = captions.isNativeSubtitle
            ? Colors.green.withOpacity(0.6)
            : (captions.isUsingLocalAsr
                ? Colors.purple.withOpacity(0.6)
                : Colors.blue.withOpacity(0.6));

        return Padding(
          padding: bubblePadding,
          child: Align(
            alignment: bubbleAlignment,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: bubbleAlignment,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (details) {
                  _isDragging = true;
                  final renderBox = _bubbleKey.currentContext?.findRenderObject() as RenderBox?;
                  if (renderBox != null && renderBox.hasSize) {
                    _bubbleWidth = renderBox.size.width;
                    _bubbleHeight = renderBox.size.height;
                  }

                  final freeH = availH - _bubbleHeight;

                  double initAlignX = appearance.alignX ?? 0.0;
                  double initAlignY;
                  if (appearance.alignY != null) {
                    initAlignY = appearance.alignY!;
                  } else {
                    final bottom = math.min(
                      appearance.bottom,
                      math.max(0.0, constraints.maxHeight - 40),
                    );
                    if (freeH > 0) {
                      final bottomInside = math.max(0.0, bottom - 12.0);
                      initAlignY = (1.0 - (2.0 * bottomInside / freeH)).clamp(-1.0, 1.0);
                    } else {
                      initAlignY = 0.8;
                    }
                  }

                  _dragAlignX = initAlignX;
                  _dragAlignY = initAlignY;
                  setState(() {});
                },
                onPanUpdate: (details) {
                  final freeW = availW - _bubbleWidth;
                  final freeH = availH - _bubbleHeight;

                  double deltaAlignX = 0;
                  if (freeW > 4) {
                    deltaAlignX = (2.0 * details.delta.dx) / freeW;
                  }
                  double deltaAlignY = 0;
                  if (freeH > 4) {
                    deltaAlignY = (2.0 * details.delta.dy) / freeH;
                  }

                  setState(() {
                    _dragAlignX = ((_dragAlignX ?? 0.0) + deltaAlignX).clamp(-1.0, 1.0);
                    _dragAlignY = ((_dragAlignY ?? 0.8) + deltaAlignY).clamp(-1.0, 1.0);
                  });
                },
                onPanEnd: (details) {
                  _isDragging = false;
                  if (_dragAlignX != null && _dragAlignY != null) {
                    widget.preferences.setPosition(_dragAlignX!, _dragAlignY!);
                  }
                  setState(() {});
                },
                onPanCancel: () {
                  _isDragging = false;
                  setState(() {});
                },
                child: Container(
                  key: _bubbleKey,
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    color: Colors.black.withOpacity(appearance.backgroundOpacity),
                    border: _isDragging
                        ? Border.all(
                            color: Theme.of(context).colorScheme.primary,
                            width: 1.5,
                          )
                        : (hasCustomPosition
                            ? Border.all(
                                color: Colors.white.withOpacity(0.18),
                                width: 0.5,
                              )
                            : null),
                    boxShadow: _isDragging
                        ? [
                            BoxShadow(
                              color: Theme.of(context).colorScheme.primary.withOpacity(0.35),
                              blurRadius: 8,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (original.isNotEmpty || translation.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: InkWell(
                            onLongPress: hasCustomPosition ? _resetPosition : null,
                            borderRadius: BorderRadius.circular(3),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: tagBgColor,
                                borderRadius: BorderRadius.circular(3),
                                border: Border.all(
                                  color: tagBorderColor,
                                  width: 0.5,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.drag_indicator,
                                    size: 10,
                                    color: tagColor.withOpacity(0.85),
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    captions.activeSourceTag,
                                    style: TextStyle(
                                      color: tagColor,
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  if (hasCustomPosition) ...[
                                    const SizedBox(width: 4),
                                    GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: _resetPosition,
                                      child: Tooltip(
                                        message: '恢复默认居中',
                                        child: Icon(
                                          Icons.close_rounded,
                                          size: 11,
                                          color: tagColor.withOpacity(0.9),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      // 若注音未能与字词一对一对齐，才作为独立全行显示在顶部
                      if (pronunciation.isNotEmpty && rubyPairs == null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: _captionText(
                            pronunciation,
                            appearance.fontSize * 0.72,
                            rubyColor,
                            letterSpacing: 0.5,
                          ),
                        ),
                      if (original.isNotEmpty)
                        _buildInteractiveCaption(
                          context: context,
                          text: original,
                          rubyPairs: rubyPairs,
                          size: appearance.fontSize,
                          color: textColor,
                          rubyColor: rubyColor,
                          fullSentence: original,
                          translation: translation,
                        ),
                      if (translation.isNotEmpty && translation != original)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: _buildInteractiveCaption(
                            context: context,
                            text: translation,
                            size: appearance.fontSize * 0.95,
                            color: const Color(0xffffe082), // 柔和的金黄译文色
                            fullSentence: original.isNotEmpty ? original : translation,
                            translation: translation,
                          ),
                        ),
                      if (status.isNotEmpty)
                        _captionText(status, 12, Colors.white70),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      });
    });
  }

  /// 交互式字幕文本，支持点击单词查词与字头顶注音对齐（Ruby Text）
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
  }) {
    // 识别当前字幕轨或原句语言（粤语 / 普通话）
    final isYue = captions.isCantoneseTrack ||
        captions.chinesePhonetic.value == 'cantonese' ||
        CaptionPronunciation.isCantoneseText(fullSentence ?? text) ||
        CaptionPronunciation.isCantoneseText(text);
    final sourceLang = isYue
        ? 'yue'
        : (captions.chinesePhonetic.value == 'mandarin' ? 'zh-CN' : null);

    // 1. 若成功按字词对齐发音，以 Ruby/振假名（字顶注音）样式垂直排列展示
    if (rubyPairs != null && rubyPairs.isNotEmpty) {
      final spans = <Widget>[];
      for (final pair in rubyPairs) {
        if (!pair.isWord || pair.text.trim().isEmpty) {
          spans.add(
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(height: math.max(9.0, size * 0.58) + 1.5),
                Text(
                  pair.text,
                  style: TextStyle(
                    color: color,
                    fontSize: size,
                    height: 1.15,
                    letterSpacing: letterSpacing,
                    fontWeight: FontWeight.w500,
                    shadows: const [
                      Shadow(color: Colors.black, blurRadius: 4, offset: Offset(0, 1)),
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
                fontSize: math.max(9.0, size * 0.58),
                height: 1.0,
                fontWeight: FontWeight.w400,
                shadows: const [
                  Shadow(color: Colors.black, blurRadius: 3, offset: Offset(0, 1)),
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
                  Shadow(color: Colors.black, blurRadius: 4, offset: Offset(0, 1)),
                ],
              ),
            ),
          ],
        );

        if (preferences.enableWordLookup.value) {
          spans.add(
            InkWell(
              onTap: () {
                showCaptionDictionarySheet(
                  context: context,
                  word: pair.text,
                  contextSentence: fullSentence ?? text,
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
        } else {
          spans.add(
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.0),
              child: column,
            ),
          );
        }
      }

      if (preferences.enableWordLookup.value) {
        spans.add(
          InkWell(
            onTap: () {
              showCaptionDictionarySheet(
                context: context,
                word: text,
                contextSentence: fullSentence ?? text,
                contextTranslation: translation,
                sourceLanguage: sourceLang,
                playerController: playerController,
              );
            },
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.only(left: 4, top: 4),
              child: Icon(
                Icons.menu_book_outlined,
                size: math.max(12.0, size * 0.7),
                color: Colors.white60,
              ),
            ),
          ),
        );
      }

      return Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 1.5,
        runSpacing: 4,
        children: spans,
      );
    }

    if (!preferences.enableWordLookup.value) {
      return _captionText(text, size, color, letterSpacing: letterSpacing);
    }

    // 智能切词拆分（100%保留所有空格、标点符号与单词完整性）
    final items = CaptionWordSegmenter.segmentWithDelimiters(text);
    if (items.isEmpty) {
      return _captionText(text, size, color, letterSpacing: letterSpacing);
    }

    final spans = <InlineSpan>[];
    for (final item in items) {
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
                    height: 1.3,
                    letterSpacing: letterSpacing,
                    fontWeight: FontWeight.w500,
                    shadows: const [
                      Shadow(color: Colors.black, blurRadius: 4, offset: Offset(0, 1)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      } else {
        // 空格、标点符号、换行：直接以 TextSpan 渲染，保留天然空格与排版字距！
        spans.add(
          TextSpan(
            text: item.text,
            style: TextStyle(
              color: color,
              fontSize: size,
              height: 1.3,
              letterSpacing: letterSpacing,
              fontWeight: FontWeight.w500,
              shadows: const [
                Shadow(color: Colors.black, blurRadius: 4, offset: Offset(0, 1)),
              ],
            ),
          ),
        );
      }
    }

    // 在右侧加一个小小的查词助手图标，方便点击整句
    spans.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: InkWell(
          onTap: () {
            showCaptionDictionarySheet(
              context: context,
              word: text,
              contextSentence: fullSentence ?? text,
              contextTranslation: translation,
              sourceLanguage: sourceLang,
              playerController: playerController,
            );
          },
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Icon(
              Icons.menu_book_outlined,
              size: math.max(12.0, size * 0.7),
              color: Colors.white60,
            ),
          ),
        ),
      ),
    );

    return Text.rich(
      TextSpan(children: spans),
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
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
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: color,
        fontSize: size,
        height: 1.3,
        letterSpacing: letterSpacing,
        fontWeight: FontWeight.w500,
        shadows: const [
          Shadow(color: Colors.black, blurRadius: 4, offset: Offset(0, 1)),
        ],
      ),
    );
  }

  /// 将原文与发音注音进行字词对齐（Ruby Text / 振假名）
  /// 支持中文拼音、粤语拼音（字字对应）、英文音标/单词对应
  static List<_RubyPair>? _pairRuby(String original, String pronunciation) {
    final orig = original.trim();
    final pron = pronunciation.trim();
    if (orig.isEmpty || pron.isEmpty) return null;

    // 1. 提取发音音标/音节列表（以空白字符分割，并清理纯标点音节）
    final rawPronTokens =
        pron.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (rawPronTokens.isEmpty) return null;

    final pronSyllables = <String>[];
    for (final raw in rawPronTokens) {
      // 去除音标常见的前后斜杠 /ipa/
      var clean = raw.replaceAll(RegExp(r'^/+|/+$'), '');
      // 检查末尾标点 (如 "ngo5," -> 音节 "ngo5", 标点 ",")
      final punctMatch = RegExp(r'[.,!?:;，。！？；：、]+$').firstMatch(clean);
      if (punctMatch != null) {
        final syl = clean.substring(0, punctMatch.start).trim();
        if (syl.isNotEmpty) pronSyllables.add(syl);
      } else {
        if (clean.isNotEmpty) pronSyllables.add(clean);
      }
    }

    if (pronSyllables.isEmpty) return null;

    // 2. 原文分词/字符化
    // 汉字单字匹配、英文单词、日文假名段、韩文段、标点、空白
    final tokenRegex = RegExp(
      r"([\u4e00-\u9fa5]|[a-zA-Z0-9'-]+|[\u3040-\u309f\u30a0-\u30ff]+|[\uac00-\ud7af]+|[^\s\w]|[\s]+)",
      unicode: true,
    );

    final matches = tokenRegex.allMatches(orig);
    final units = <String>[];
    for (final m in matches) {
      units.add(m.group(0)!);
    }

    // 统计其中需要发音注音的词/字（非纯标点、非纯空格）
    bool isPronounceable(String u) =>
        RegExp(r'[\u4e00-\u9fa5a-zA-Z0-9\u3040-\u30ff\uac00-\ud7af]').hasMatch(u);

    final pronounceableUnits = units.where(isPronounceable).toList();

    // 策略 A：发音音节数量与原文可注音单元数完全一致 (最常见：中文拼音、粤拼、单字注音)
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

    // 策略 B：若原文按空格分词（如英文句子或已分词文本），且词数与发音词数一致
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

    // 策略 C：轻微不匹配容错对齐 (差异 <= 2)
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

    // 无法对齐时返回 null，降级为顶部整行显示
    return null;
  }
}

class _RubyPair {
  final String text;
  final String? ruby;
  final bool isWord;
  const _RubyPair(this.text, this.ruby, {this.isWord = true});
}
