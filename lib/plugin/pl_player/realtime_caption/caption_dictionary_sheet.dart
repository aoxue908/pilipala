import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:pilipala/plugin/pl_player/controller.dart';
import 'caption_dictionary.dart';
import 'caption_context.dart';
import 'caption_offline_dictionary.dart';
import 'cantonese_lexicon.dart';
import 'japanese_reading.dart';
import 'caption_ruby.dart';
import 'caption_pronunciation.dart';
import 'caption_tts_dialog.dart';
import 'caption_tts_service.dart';

/// 弹出智能查词字典底栏
Future<void> showCaptionDictionarySheet({
  required BuildContext context,
  required String word,
  String? contextSentence,
  int? contextWordOffset,
  List<CaptionContextRange> contextRanges = const [],
  String? contextTranslation,
  String? sourceLanguage,
  PlPlayerController? playerController,
}) async {
  // 1. 自动暂停视频播放
  if (playerController != null && playerController.playerStatus.playing) {
    playerController.pause();
  }

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.55),
    builder: (modalContext) {
      return CaptionDictionarySheet(
        initialWord: word,
        contextSentence: contextSentence,
        contextWordOffset: contextWordOffset,
        contextRanges: contextRanges,
        contextTranslation: contextTranslation,
        sourceLanguage: sourceLanguage,
        playerController: playerController,
      );
    },
  );
}

class CaptionDictionarySheet extends StatefulWidget {
  const CaptionDictionarySheet({
    required this.initialWord,
    this.contextSentence,
    this.contextWordOffset,
    this.contextRanges = const [],
    this.contextTranslation,
    this.sourceLanguage,
    this.playerController,
    super.key,
  });

  final String initialWord;
  final String? contextSentence;
  final int? contextWordOffset;
  final List<CaptionContextRange> contextRanges;
  final String? contextTranslation;
  final String? sourceLanguage;
  final PlPlayerController? playerController;

  static String getLanguageDisplayName(String langCode) {
    final l = langCode.trim().toLowerCase();
    if (l == 'zh-cn' || l == 'zh' || l == 'zh-hans') return '中文';
    if (l == 'yue' || l == 'zh-hk' || l == 'zh-tw' || l == 'zh-hant') return '粤语 YUE';
    if (l.startsWith('en')) return '英语 EN';
    if (l == 'ja') return '日语 JA';
    if (l == 'ko') return '韩语 KO';
    if (l == 'tr') return '土耳其语 TR';
    if (l == 'fr') return '法语 FR';
    if (l == 'de') return '德语 DE';
    if (l == 'es') return '西班牙语 ES';
    if (l == 'ru') return '俄语 RU';
    if (l == 'it') return '意大利语 IT';
    if (l == 'pt') return '葡萄牙语 PT';
    if (l == 'vi') return '越南语 VI';
    if (l == 'th') return '泰语 TH';
    if (l == 'ar') return '阿拉伯语 AR';
    if (l == 'id') return '印尼语 ID';
    if (l == 'hi') return '印地语 HI';
    if (l.isEmpty || l == 'auto') return '';
    return langCode.toUpperCase();
  }

  @override
  State<CaptionDictionarySheet> createState() => _CaptionDictionarySheetState();
}

class _CaptionDictionarySheetState extends State<CaptionDictionarySheet> {
  late final TextEditingController _textController;
  late String _currentWord;
  Future<WordLookupResult>? _lookupFuture;
  List<String> _sentenceTokens = [];
  String? _playingAudioUrl;
  String? _forcedLanguage;
  bool _showPronunciation = false;
  late final String _contextSentence;
  late final String? _contextTranslation;

  @override
  void initState() {
    super.initState();
    _currentWord = widget.initialWord.trim();
    _contextSentence = captionContainingSentence(
      text: widget.contextSentence ?? '',
      word: _currentWord,
      wordOffset: widget.contextWordOffset,
      sourceRanges: widget.contextRanges,
    );
    // 截取原句后不能继续展示整个段落的翻译，避免错配并再次撑长面板。
    _contextTranslation = _contextSentence == widget.contextSentence?.trim()
        ? widget.contextTranslation : null;
    _textController = TextEditingController(text: _currentWord);
    _showPronunciation = widget.playerController?.realtimeCaptions.sheetShowPronunciation.value ??
        widget.playerController?.realtimeCaptions.preferences?.sheetShowPronunciation.value ??
        true;
    final initialHasChinese = RegExp(r'\p{Script=Han}', unicode: true).hasMatch(_currentWord);
    _forcedLanguage = (widget.sourceLanguage != null &&
            (!widget.sourceLanguage!.startsWith('zh') || initialHasChinese))
        ? widget.sourceLanguage
        : null;
    _parseSentenceTokens();
    _startLookup(_currentWord, forcedLang: _forcedLanguage);
  }

  void _togglePronunciation() {
    final next = !_showPronunciation;
    setState(() {
      _showPronunciation = next;
    });
    if (widget.playerController != null) {
      widget.playerController!.realtimeCaptions.setSheetPronunciation(next);
    } else {
      widget.playerController?.realtimeCaptions.preferences?.setSheetPronunciation(next);
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    WordAudioPlayer.shared.stop();
    super.dispose();
  }

  void _parseSentenceTokens() {
    final s = _contextSentence;
    if (s.trim().isEmpty) {
      _sentenceTokens = [];
      return;
    }
    // 智能中文/粤语/英文分词，精准切出词组，彻底告别机械双字切割
    _sentenceTokens = CaptionWordSegmenter.segment(s);
  }

  void _startLookup(String word, {String? forcedLang}) {
    final cleaned = CaptionDictionary.cleanWord(word);
    if (cleaned.isEmpty) return;
    if (forcedLang != null) {
      _forcedLanguage = forcedLang;
    }
    if ((_forcedLanguage ?? widget.sourceLanguage) == 'ja' ||
        RegExp(r'[\u3040-\u30FF]').hasMatch(_contextSentence)) {
      final sentence = _contextSentence.isNotEmpty ? _contextSentence : cleaned;
      JapaneseReadingService.shared.analyze(sentence).then((tokens) {
        if (!mounted) return;
        setState(() {
          if (tokens.isNotEmpty && sentence == _contextSentence) {
            _sentenceTokens = tokens.where((token) =>
                RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(token.text))
                .map((token) => token.text).toList();
          }
        });
      });
    }
    setState(() {
      _currentWord = cleaned;
      _textController.text = cleaned;
      _lookupFuture = CaptionDictionary.shared.lookup(
        cleaned,
        contextSentence: _contextSentence,
        contextTranslation: _contextTranslation,
        isCantonese: _forcedLanguage == 'yue' ||
            widget.playerController?.realtimeCaptions.isCantoneseTrack == true,
        forcedLanguage: _forcedLanguage,
      );
    });
  }

  Future<void> _playAudio(
    String? url, {
    String? fallbackUrl,
    String? speakText,
    String? speakLang,
  }) async {
    final effectiveKey = (url != null && url.isNotEmpty)
        ? url
        : (speakText != null && speakText.isNotEmpty ? speakText : _currentWord);
    setState(() => _playingAudioUrl = effectiveKey);

    final textLen = (speakText ?? _currentWord).length;
    final animDurationMs = math.max(1600, math.min(textLen * 300, 4500));

    try {
      final playFuture = WordAudioPlayer.shared.play(
        url ?? '',
        fallbackUrl: fallbackUrl,
        speakText: speakText ?? _currentWord,
        speakLang: speakLang,
      );
      await Future.wait([
        playFuture,
        Future.delayed(Duration(milliseconds: animDurationMs)),
      ]);
    } catch (_) {}

    if (mounted) {
      setState(() => _playingAudioUrl = null);
    }
  }

  // 适合视频播放器沉浸遮罩的赛博科技感配色
  static const Color _kCyberCyan = Color(0xFF00E5FF);
  static const Color _kCyberBlue = Color(0xFF0072FF);
  static const Color _kCyberCardBg = Color(0x38101E33);
  static const Color _kCyberBorder = Color(0x3800E5FF);
  static const Color _kCyberTextPrimary = Color(0xFFF1F5F9);
  static const Color _kCyberTextSecondary = Color(0xFF94A3B8);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    final borderRadius = isLandscape
        ? BorderRadius.circular(20)
        : const BorderRadius.vertical(top: Radius.circular(24));

    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          constraints: BoxConstraints(
            maxHeight: isLandscape
                ? MediaQuery.of(context).size.height * 0.92
                : MediaQuery.of(context).size.height * 0.78,
            maxWidth: isLandscape ? 680 : double.infinity,
          ),
          margin: isLandscape ? const EdgeInsets.symmetric(horizontal: 40, vertical: 12) : null,
          decoration: BoxDecoration(
            color: const Color(0xEE0B101D),
            borderRadius: borderRadius,
            border: Border.all(
              color: const Color(0x3800E5FF),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.65),
                blurRadius: 28,
                offset: const Offset(0, -4),
              ),
              BoxShadow(
                color: _kCyberCyan.withOpacity(0.12),
                blurRadius: 18,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部拖拽把手与赛博标题栏
              _buildHeader(theme),
              Divider(height: 1, thickness: 0.8, color: _kCyberBorder.withOpacity(0.3)),

              // 内容滚动区
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  children: [
                    // 1. 原句上下文与切词导航
                    if (_contextSentence.isNotEmpty)
                      _buildContextSentenceCard(theme),

                    // 2. 搜索框
                    _buildSearchInput(theme),
                    const SizedBox(height: 12),

                    // 3. 查词主内容（发音、释义、例句）
                    FutureBuilder<WordLookupResult>(
                      future: _lookupFuture,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.waiting) {
                          return _buildLoading();
                        }
                        if (snapshot.hasError) {
                          return _buildError(snapshot.error.toString());
                        }
                        final data = snapshot.data;
                        if (data == null) {
                          return const SizedBox.shrink();
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 单词与发音栏
                            _buildWordTitleAndPhonetic(data, theme),
                            const SizedBox(height: 14),

                            // 词义解释
                            _buildDefinitionsCard(data, theme),
                            const SizedBox(height: 14),

                            // 双语权威例句
                            if (data.hasExamples)
                              _buildExamplesCard(data, theme),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),

              // 底部操作栏
              _buildBottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  /// 顶部栏（科技感把手、HUD状态标识）
  Widget _buildHeader(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 顶部赛博科技微光把手
        Container(
          margin: const EdgeInsets.only(top: 8, bottom: 4),
          width: 36,
          height: 3.5,
          decoration: BoxDecoration(
            color: _kCyberCyan.withOpacity(0.35),
            borderRadius: BorderRadius.circular(2),
            boxShadow: [
              BoxShadow(
                color: _kCyberCyan.withOpacity(0.3),
                blurRadius: 4,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0x3300E5FF), Color(0x220072FF)],
                  ),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _kCyberCyan.withOpacity(0.4)),
                ),
                child: const Icon(
                  Icons.auto_stories_rounded,
                  size: 16,
                  color: _kCyberCyan,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                '智能查词 · 字幕助手',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: _kCyberTextPrimary,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _kCyberCyan.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: _kCyberCyan.withOpacity(0.3)),
                ),
                child: const Text(
                  'AI HUD',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: _kCyberCyan,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              const Spacer(),
              // 顶部 “あ” 注音开关按钮 (与图1一致，指示并切换是否打开注音)
              Tooltip(
                message: _showPronunciation ? '点击关闭发音注音' : '点击开启发音注音',
                child: InkWell(
                  onTap: _togglePronunciation,
                  borderRadius: BorderRadius.circular(16),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _showPronunciation
                          ? const Color(0xff00897b).withOpacity(0.92)
                          : Colors.white.withOpacity(0.08),
                      border: Border.all(
                        color: _showPronunciation
                            ? Colors.tealAccent.withOpacity(0.7)
                            : Colors.white.withOpacity(0.18),
                        width: _showPronunciation ? 1.0 : 0.6,
                      ),
                      boxShadow: _showPronunciation
                          ? [
                              BoxShadow(
                                color: const Color(0xff00897b).withOpacity(0.5),
                                blurRadius: 6,
                              ),
                            ]
                          : null,
                    ),
                    child: Center(
                      child: Text(
                        'あ',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: _showPronunciation ? Colors.white : Colors.white38,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: () => Navigator.of(context).pop(),
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.06),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close_rounded, size: 18, color: _kCyberTextSecondary),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 原句上下文卡片
  Widget _buildContextSentenceCard(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _kCyberCardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kCyberBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.format_quote_rounded, size: 15, color: _kCyberCyan),
              SizedBox(width: 4),
              Text(
                '所在句子（点击单词切换查词）',
                style: TextStyle(
                  color: Color(0xFF38BDF8),
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 句子切词按钮
          if (_sentenceTokens.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _sentenceTokens.map((token) {
                final isSelected = token.toLowerCase() == _currentWord.toLowerCase();
                return InkWell(
                  onTap: () => _startLookup(token),
                  borderRadius: BorderRadius.circular(8),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width - 64,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      gradient: isSelected
                          ? const LinearGradient(
                              colors: [_kCyberCyan, Color(0xFF0091FF)],
                            )
                          : null,
                      color: isSelected ? null : const Color(0x331E293B),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected
                            ? _kCyberCyan
                            : const Color(0x4064748B),
                        width: isSelected ? 1.2 : 0.8,
                      ),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: _kCyberCyan.withOpacity(0.4),
                                blurRadius: 8,
                                spreadRadius: 0,
                              ),
                            ]
                          : null,
                    ),
                    child: Text(
                      token,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                        color: isSelected ? const Color(0xFF070B14) : _kCyberTextPrimary,
                      ),
                      softWrap: true,
                    ),
                  ),
                );
              }).toList(),
            )
          else
            Text(
              _contextSentence,
              style: const TextStyle(fontSize: 14, color: _kCyberTextPrimary),
            ),
          if (_contextTranslation != null && _contextTranslation!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Colors.white.withOpacity(0.06))),
              ),
              child: Text(
                _contextTranslation!,
                style: const TextStyle(fontSize: 12, color: _kCyberTextSecondary),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 搜索输入框
  Widget _buildSearchInput(ThemeData theme) {
    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: const Color(0x331E293B),
        borderRadius: BorderRadius.circular(21),
        border: Border.all(color: _kCyberBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 6,
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          const Icon(Icons.search_rounded, size: 18, color: _kCyberCyan),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _textController,
              style: const TextStyle(fontSize: 14, color: _kCyberTextPrimary),
              cursorColor: _kCyberCyan,
              decoration: const InputDecoration(
                hintText: '输入或粘贴想要查询的单词/词组…',
                hintStyle: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
              onSubmitted: (val) => _startLookup(val),
            ),
          ),
          if (_textController.text.isNotEmpty)
            GestureDetector(
              onTap: () {
                _textController.clear();
                setState(() {});
              },
              child: const Icon(Icons.cancel_rounded, size: 16, color: Color(0xFF64748B)),
            ),
          const SizedBox(width: 6),
          InkWell(
            onTap: () => _startLookup(_textController.text),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [_kCyberCyan, _kCyberBlue],
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: _kCyberCyan.withOpacity(0.35),
                    blurRadius: 6,
                  ),
                ],
              ),
              child: const Text(
                '查询',
                style: TextStyle(
                  fontSize: 12,
                  color: Color(0xFF070B14),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 单词标题与发音栏 (支持 Ruby 头顶注音、末尾发音小喇叭、清爽布局)
  Widget _buildWordTitleAndPhonetic(WordLookupResult data, ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kCyberCardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kCyberBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 8,
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxPillWidth = constraints.maxWidth;
          final effectivePhonetic = data.phonetic ??
              CaptionPronunciation.shared.getOfflinePronunciation(
                data.query,
                chineseMode: (data.sourceLanguage == 'yue' || _forcedLanguage == 'yue')
                    ? 'cantonese'
                    : 'mandarin',
                isCantoneseContext: (data.sourceLanguage == 'yue' || _forcedLanguage == 'yue'),
                sourceLang: data.sourceLanguage,
              );

          final showRuby = _showPronunciation &&
              ((data.sourceLanguage == 'ja' &&
                  JapaneseReadingService.shared.cached(_contextSentence.isEmpty ? data.query : _contextSentence) != null) ||
               (effectivePhonetic != null && effectivePhonetic.trim().isNotEmpty));

          final audioUrl = (data.sourceLanguage == 'yue' &&
                  data.audioUrl != null &&
                  !data.audioUrl!.contains('google') &&
                  !data.audioUrl!.contains('youdao'))
              ? data.audioUrl!
              : data.audioUrl;
          final speakLang = (data.sourceLanguage == 'yue' || _forcedLanguage == 'yue')
              ? 'zh-HK'
              : (data.sourceLanguage.isNotEmpty && data.sourceLanguage != 'auto'
                  ? data.sourceLanguage
                  : 'zh-CN');

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. 原文区：开启注音时字头顶标注音；结尾紧跟发音小喇叭；右侧语言切换
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: showRuby
                        ? Wrap(
                            spacing: 0,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.end,
                            children: [
                              ..._pairRubyText(data.query, effectivePhonetic, data.sourceLanguage)
                                  .map((item) {
                                final isSpace = item.text.trim().isEmpty;
                                if (isSpace) {
                                  return const SizedBox(width: 5);
                                }
                                final isPunct = RegExp(r'^[.,!?:;，。！？；：、~…]+$').hasMatch(item.text);
                                if (isPunct) {
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 1.0),
                                    child: Text(
                                      item.text,
                                      style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold,
                                        color: _kCyberCyan,
                                        height: 1.2,
                                      ),
                                    ),
                                  );
                                }
                                return Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 1.0),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.center,
                                    children: [
                                      if (item.ruby != null && item.ruby!.isNotEmpty)
                                        Text(
                                          item.ruby!,
                                          style: const TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w500,
                                            color: Color(0xFF38BDF8),
                                            height: 1.1,
                                          ),
                                        )
                                      else
                                        const SizedBox(height: 11.5),
                                      const SizedBox(height: 2),
                                      Text(
                                        item.text,
                                        style: const TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.bold,
                                          color: _kCyberCyan,
                                          letterSpacing: 0.3,
                                          height: 1.2,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }),
                              // 发音小喇叭：直接紧跟在句子或单词末尾！
                              _buildInlineSpeakerIcon(
                                audioUrl: audioUrl,
                                fallbackUrl: data.audioUrl,
                                speakText: data.query,
                                speakLang: speakLang,
                              ),
                            ],
                          )
                        : Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: data.query,
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: _kCyberCyan,
                                    letterSpacing: 0.3,
                                    height: 1.25,
                                  ),
                                ),
                                WidgetSpan(
                                  alignment: PlaceholderAlignment.middle,
                                  child: _buildInlineSpeakerIcon(
                                    audioUrl: audioUrl,
                                    fallbackUrl: data.audioUrl,
                                    speakText: data.query,
                                    speakLang: speakLang,
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
                ],
              ),

              // 2. 音色设置与英文音标补充
              if (data.sourceLanguage == 'en' || data.sourceLanguage.startsWith('en-')) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    _buildLanguageTag(data),
                    _buildPhoneticPill(
                      label: '英',
                      phonetic: data.ukPhonetic ?? data.phonetic ?? '',
                      audioUrl: data.ukAudioUrl ??
                          'https://dict.youdao.com/dictvoice?audio=${Uri.encodeComponent(data.query)}&type=1',
                      fallbackUrl:
                          'https://google.qianche.dpdns.org/translate_tts?ie=UTF-8&client=tw-ob&tl=en-gb&q=${Uri.encodeComponent(data.query)}',
                      speakText: data.query,
                      speakLang: 'en-GB',
                      maxWidth: maxPillWidth,
                    ),
                    _buildPhoneticPill(
                      label: '美',
                      phonetic: data.usPhonetic ?? data.phonetic ?? '',
                      audioUrl: data.usAudioUrl ??
                          'https://dict.youdao.com/dictvoice?audio=${Uri.encodeComponent(data.query)}&type=2',
                      fallbackUrl:
                          'https://google.qianche.dpdns.org/translate_tts?ie=UTF-8&client=tw-ob&tl=en-us&q=${Uri.encodeComponent(data.query)}',
                      speakText: data.query,
                      speakLang: 'en-US',
                      maxWidth: maxPillWidth,
                    ),
                  ],
                ),
              ] else ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    // 语言切换标签（粤语 YUE ⇄ / 中文 ⇄）
                    _buildLanguageTag(data),
                    if (data.sourceLanguage == 'yue' ||
                        data.sourceLanguage == 'zh-CN' ||
                        data.sourceLanguage == 'zh' ||
                        _forcedLanguage == 'yue' ||
                        _forcedLanguage == 'zh-CN' ||
                        RegExp(r'\p{Script=Han}', unicode: true).hasMatch(data.query) ||
                        widget.playerController?.realtimeCaptions.isCantoneseTrack == true)
                      Builder(
                        builder: (context) {
                          final isCantonese = data.sourceLanguage == 'yue' ||
                              _forcedLanguage == 'yue' ||
                              (data.sourceLanguage != 'zh-CN' &&
                                  _forcedLanguage != 'zh-CN' &&
                                  (widget.playerController?.realtimeCaptions.isCantoneseTrack == true ||
                                      CaptionOfflineDictionary.isCantoneseWord(data.query) ||
                                      CaptionPronunciation.isCantoneseText(_contextSentence)));
                          final config = CaptionTtsService.shared.config;
                          final voiceName = config.engine == 'mimo'
                              ? 'MiMo: ${config.mimoVoice}'
                              : (isCantonese
                                  ? '发音人: ${CaptionTtsService.edgeCantoneseVoices[config.edgeCantoneseVoice]?.split(' ').first ?? '晓曼'}'
                                  : '发音人: ${CaptionTtsService.edgeMandarinVoices[config.edgeMandarinVoice]?.split(' ').first ?? '晓晓'}');

                          return InkWell(
                            onTap: () async {
                              await showTtsVoiceSettingsDialog(
                                context,
                                testWord: data.query,
                                language: isCantonese ? 'zh-HK' : 'zh-CN',
                              );
                              setState(() {});
                            },
                            borderRadius: BorderRadius.circular(16),
                            child: Container(
                              constraints: BoxConstraints(maxWidth: maxPillWidth),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
                              decoration: BoxDecoration(
                                color: const Color(0x331E293B),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: _kCyberBorder),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.tune_rounded, size: 13, color: _kCyberCyan),
                                  const SizedBox(width: 5),
                                  Flexible(
                                    child: Text(
                                      voiceName,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                        color: _kCyberTextSecondary,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  /// 紧随在句子或单词末尾的发音小喇叭图标 (100%还原用户截图)
  Widget _buildInlineSpeakerIcon({
    required String? audioUrl,
    String? fallbackUrl,
    required String speakText,
    required String speakLang,
  }) {
    final isPlaying = (_playingAudioUrl != null && _playingAudioUrl!.isNotEmpty) &&
        ((audioUrl != null && audioUrl.isNotEmpty && _playingAudioUrl == audioUrl) ||
            (_playingAudioUrl == speakText) ||
            (_playingAudioUrl == _currentWord));

    return Tooltip(
      message: '朗读发音',
      child: InkWell(
        onTap: () => _playAudio(
          audioUrl,
          fallbackUrl: fallbackUrl,
          speakText: speakText,
          speakLang: speakLang,
        ),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          margin: const EdgeInsets.only(left: 6),
          padding: const EdgeInsets.all(4.5),
          decoration: BoxDecoration(
            color: isPlaying
                ? _kCyberCyan.withOpacity(0.25)
                : Colors.white.withOpacity(0.06),
            shape: BoxShape.circle,
            border: Border.all(
              color: isPlaying ? _kCyberCyan : _kCyberCyan.withOpacity(0.35),
              width: isPlaying ? 1.4 : 0.8,
            ),
            boxShadow: isPlaying
                ? [
                    BoxShadow(
                      color: _kCyberCyan.withOpacity(0.4),
                      blurRadius: 8,
                    ),
                  ]
                : null,
          ),
          child: isPlaying
              ? const _SoundWaveAnimation(color: _kCyberCyan, size: 16)
              : const Icon(
                  Icons.volume_up_rounded,
                  size: 19,
                  color: _kCyberCyan,
                ),
        ),
      ),
    );
  }

  /// 可手动切换的语言列表（检测出错时用户可自行纠正）。
  /// value 为内部语言码，'auto' 表示"自动检测"（不强制）。
  static const List<MapEntry<String, String>> _kLanguageChoices = [
    MapEntry('auto', '自动检测'),
    MapEntry('zh-CN', '中文'),
    MapEntry('yue', '粤语'),
    MapEntry('en', '英语'),
    MapEntry('ja', '日语'),
    MapEntry('ko', '韩语'),
    MapEntry('fr', '法语'),
    MapEntry('de', '德语'),
    MapEntry('es', '西班牙语'),
    MapEntry('ru', '俄语'),
    MapEntry('tr', '土耳其语'),
  ];

  /// 语言切换胶囊按钮：点击弹出语言菜单，手动选择后重新查词。
  /// 检测可能出错（如英文被误判为韩语），所以这里必须可点、可切换。
  Widget _buildLanguageTag(WordLookupResult data) {
    // 当前生效的语言码：优先用本次强制语言，其次用查词结果。
    final activeCode = (_forcedLanguage != null && _forcedLanguage!.isNotEmpty)
        ? _forcedLanguage
        : (data.sourceLanguage.isEmpty || data.sourceLanguage == 'auto'
            ? null
            : data.sourceLanguage);
    final label = activeCode == null
        ? '自动检测'
        : CaptionDictionarySheet.getLanguageDisplayName(activeCode);

    return InkWell(
      onTap: () => _showLanguageMenu(activeCode),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
        decoration: BoxDecoration(
          color: _kCyberCyan.withOpacity(0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: _kCyberCyan.withOpacity(0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 10.5,
                color: _kCyberCyan,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 3),
            const Icon(Icons.arrow_drop_down_rounded,
                size: 14, color: _kCyberCyan),
          ],
        ),
      ),
    );
  }

  /// 弹出语言选择菜单，选中后用该语言重新查词（自动检测则清除强制语言）。
  void _showLanguageMenu(String? activeCode) async {
    final RenderBox? button = context.findRenderObject() as RenderBox?;
    final relativeRect = button == null
        ? RelativeRect.fill
        : RelativeRect.fromRect(
            button.localToGlobal(Offset.zero) & button.size,
            Offset.zero & MediaQuery.of(context).size,
          );

    final selected = await showMenu<String>(
      context: context,
      position: relativeRect,
      color: const Color(0xFF1E293B),
      items: [
        for (final choice in _kLanguageChoices)
          PopupMenuItem<String>(
            value: choice.key,
            height: 40,
            child: Row(
              children: [
                Icon(
                  choice.key == (activeCode ?? 'auto')
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 16,
                  color: _kCyberCyan,
                ),
                const SizedBox(width: 10),
                Text(
                  choice.value,
                  style: TextStyle(
                    fontSize: 13,
                    color: choice.key == (activeCode ?? 'auto')
                        ? _kCyberCyan
                        : const Color(0xFFE2E8F0),
                    fontWeight: choice.key == (activeCode ?? 'auto')
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
      ],
    );

    // 返回 null = 点了菜单外取消，不处理。
    if (selected == null || !mounted) return;
    if (selected == 'auto') {
      // 自动检测：清除强制语言，重新查词走 detectLanguage。
      setState(() => _forcedLanguage = null);
      _startLookup(_currentWord);
    } else {
      // 手动指定语言：强制重新查词。
      _startLookup(_currentWord, forcedLang: selected);
    }
  }

  /// 将原文与发音切分成对应字词（实现头顶注音 Ruby 对齐）
  List<_SheetRubyItem> _pairRubyText(String text, String? phonetic, String lang) {
    if (lang == 'ja' || RegExp(r'[\u3040-\u30FF]').hasMatch(text)) {
      final context = _contextSentence.isEmpty ? text : _contextSentence;
      final start = context.indexOf(text);
      final analyzed = JapaneseReadingService.shared.cached(context);
      if (analyzed == null || start < 0 || context.lastIndexOf(text) != start) {
        return [_SheetRubyItem(text, null)];
      }
      final selected = analyzed.where((token) => token.start >= start &&
          token.end <= start + text.length).map((token) =>
          JapaneseReadingToken(token.text, token.reading, token.start - start)).toList();
      if (selected.map((token) => token.text).join() != text) {
        return [_SheetRubyItem(text, null)];
      }
      return buildCaptionRubyUnits(text, sourceLanguage: 'ja', japaneseTokens: selected)
          .map((unit) => _SheetRubyItem(unit.text,
              unit.pronunciation.isEmpty ? null : unit.pronunciation)).toList();
    }
    if (phonetic == null || phonetic.trim().isEmpty) {
      return [_SheetRubyItem(text, null)];
    }
    final cleanText = text.trim();
    final cleanPhonetic = phonetic.replaceAll('/', '').trim();
    if (cleanText.isEmpty) return [];

    // 2. 提取音节列表 (过滤标点符号，如逗号句号)
    final syllables = cleanPhonetic
        .split(RegExp(r'\s+'))
        .map((s) => s.replaceAll(RegExp(r'^[.,!?:;，。！？；：、]+|[.,!?:;，。！？；：、]+$'), '').trim())
        .where((s) => s.isNotEmpty)
        .toList();

    // 3. 将原文拆分为 Token：汉字单字、英文/数字单词、标点、空白
    final tokenRegex = RegExp(
      r"([\u4E00-\u9FFF\u3400-\u4DBF]|[a-zA-Z0-9'-]+|[\u3040-\u309F\u30A0-\u30FF]+|[\uAC00-\uD7AF]+|[^\s\w]|[\s]+)",
      unicode: true,
    );
    final matches = tokenRegex.allMatches(cleanText);
    final tokens = matches.map((m) => m.group(0)!).toList();

    bool isPronounceable(String u) =>
        RegExp(r'[\u4E00-\u9FFF\u3400-\u4DBF\u3040-\u30FF\uAC00-\uD7AFa-zA-Z0-9]').hasMatch(u);

    final pronounceableUnits = tokens.where(isPronounceable).toList();

    // 如果只有一个独立短单词（如单个英语单词），整词头顶标注
    if (pronounceableUnits.length == 1 && cleanText.length <= 15 && !cleanText.contains(' ')) {
      return [_SheetRubyItem(cleanText, cleanPhonetic)];
    }

    // 句子或多字模式：逐字/词一一对齐头顶注音
    if (pronounceableUnits.isNotEmpty && syllables.isNotEmpty) {
      final result = <_SheetRubyItem>[];
      var sIdx = 0;
      for (final t in tokens) {
        if (isPronounceable(t)) {
          if (sIdx < syllables.length) {
            final syl = syllables[sIdx++];
            // 若该 token 本身就是英文单词且与音节一致，不需要在头顶重复显示自身
            if (t.toLowerCase() == syl.toLowerCase()) {
              result.add(_SheetRubyItem(t, null));
            } else {
              result.add(_SheetRubyItem(t, syl));
            }
          } else {
            result.add(_SheetRubyItem(t, null));
          }
        } else {
          result.add(_SheetRubyItem(t, null));
        }
      }
      return result;
    }

    // 兜底返回
    return [_SheetRubyItem(cleanText, null)];
  }

  /// 发音小标签（赛博科技风胶囊与发音声波）
  Widget _buildPhoneticPill({
    required String label,
    required String phonetic,
    required String? audioUrl,
    String? fallbackUrl,
    String? speakText,
    String? speakLang,
    double? maxWidth,
  }) {
    final isPlaying = (_playingAudioUrl != null && _playingAudioUrl!.isNotEmpty) &&
        ((audioUrl != null && audioUrl.isNotEmpty && _playingAudioUrl == audioUrl) ||
            (speakText != null && speakText.isNotEmpty && _playingAudioUrl == speakText) ||
            (_playingAudioUrl == _currentWord));
    final hasPhonetic = phonetic.trim().isNotEmpty;
    final displayText = hasPhonetic ? '/${phonetic.replaceAll('/', '')}/' : '发音';

    return InkWell(
      onTap: (audioUrl != null || (speakText != null && speakText.isNotEmpty))
          ? () => _playAudio(
                audioUrl,
                fallbackUrl: fallbackUrl,
                speakText: speakText,
                speakLang: speakLang,
              )
          : null,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        constraints: BoxConstraints(
          maxWidth: maxWidth ?? (MediaQuery.of(context).size.width - 56),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isPlaying
              ? _kCyberCyan.withOpacity(0.18)
              : const Color(0x331E293B),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isPlaying
                ? _kCyberCyan
                : _kCyberBorder,
            width: isPlaying ? 1.4 : 1.0,
          ),
          boxShadow: isPlaying
              ? [
                  BoxShadow(
                    color: _kCyberCyan.withOpacity(0.35),
                    blurRadius: 8,
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [_kCyberCyan, _kCyberBlue],
                ),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF070B14),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                displayText,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _kCyberTextPrimary,
                  fontFamily: 'sans-serif',
                ),
                softWrap: true,
              ),
            ),
            if (audioUrl != null || (speakText != null && speakText.isNotEmpty)) ...[
              const SizedBox(width: 6),
              isPlaying
                  ? const _SoundWaveAnimation(color: _kCyberCyan, size: 16)
                  : const Icon(
                      Icons.volume_up_rounded,
                      size: 16,
                      color: _kCyberCyan,
                    ),
            ],
          ],
        ),
      ),
    );
  }



  /// 释义卡片
  Widget _buildDefinitionsCard(WordLookupResult data, ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kCyberCardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kCyberBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 8,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.menu_book_rounded, size: 16, color: _kCyberCyan),
              SizedBox(width: 6),
              Text(
                '基本释义',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: _kCyberCyan,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (data.definitions.isNotEmpty)
            ...data.definitions.map((def) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (def.partOfSpeech.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(right: 8, top: 1),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _kCyberCyan.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: _kCyberCyan.withOpacity(0.3)),
                        ),
                        child: Text(
                          def.partOfSpeech,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF38BDF8),
                          ),
                        ),
                      ),
                    Expanded(
                      child: Text(
                        def.meanings.join('； '),
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.45,
                          color: _kCyberTextPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            })
          else if (data.rawTranslation != null && data.rawTranslation!.isNotEmpty)
            Text(
              data.rawTranslation!,
              style: const TextStyle(fontSize: 14.5, height: 1.45, color: _kCyberTextPrimary),
            )
          else
            const Text(
              '暂无释义',
              style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
            ),
        ],
      ),
    );
  }

  /// 双语例句卡片
  Widget _buildExamplesCard(WordLookupResult data, ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kCyberCardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kCyberBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 8,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.chat_bubble_outline_rounded, size: 16, color: _kCyberCyan),
              SizedBox(width: 6),
              Text(
                '权威双语例句',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: _kCyberCyan,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...data.examples.asMap().entries.map((entry) {
            final idx = entry.key + 1;
            final ex = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$idx. ',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: _kCyberCyan,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          ex.sentence,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                            height: 1.35,
                            color: _kCyberTextPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (ex.translation.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 18, top: 3),
                      child: Text(
                        ex.translation,
                        style: const TextStyle(
                          fontSize: 12.5,
                          height: 1.35,
                          color: _kCyberTextSecondary,
                        ),
                      ),
                    ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Column(
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: _kCyberCyan,
              ),
            ),
            SizedBox(height: 12),
            Text(
              '正在获取智能释义与例句…',
              style: TextStyle(fontSize: 13, color: _kCyberTextSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError(String error) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Column(
          children: [
            const Icon(Icons.error_outline_rounded, size: 36, color: Color(0xFFFF5252)),
            const SizedBox(height: 8),
            const Text('查词失败，请检查网络设置', style: TextStyle(color: Color(0xFFFF5252))),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: () => _startLookup(_currentWord),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0x3300E5FF),
                foregroundColor: _kCyberCyan,
                side: const BorderSide(color: _kCyberBorder),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  /// 底部操作栏
  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xF50A0E1A),
        border: Border(
          top: BorderSide(color: _kCyberBorder.withOpacity(0.25)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                side: const BorderSide(color: Color(0x4064748B)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                backgroundColor: const Color(0x18FFFFFF),
              ),
              child: const Text(
                '关闭',
                style: TextStyle(
                  color: _kCyberTextSecondary,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: InkWell(
              onTap: () {
                Navigator.of(context).pop();
                widget.playerController?.play();
              },
              borderRadius: BorderRadius.circular(22),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [_kCyberCyan, _kCyberBlue],
                  ),
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    BoxShadow(
                      color: _kCyberCyan.withOpacity(0.4),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.play_arrow_rounded, size: 20, color: Color(0xFF070B14)),
                    SizedBox(width: 6),
                    Text(
                      '继续播放',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF070B14),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 发音跳动声波动画组件
class _SoundWaveAnimation extends StatefulWidget {
  const _SoundWaveAnimation({
    required this.color,
    this.size = 18.0,
  });

  final Color color;
  final double size;

  @override
  State<_SoundWaveAnimation> createState() => _SoundWaveAnimationState();
}

class _SoundWaveAnimationState extends State<_SoundWaveAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value * 2 * math.pi;
        final h1 = 0.35 + 0.65 * math.sin(t).abs();
        final h2 = 0.35 + 0.65 * math.sin(t + 1.2).abs();
        final h3 = 0.35 + 0.65 * math.sin(t + 2.4).abs();

        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildBar(h1),
              const SizedBox(width: 2.2),
              _buildBar(h2),
              const SizedBox(width: 2.2),
              _buildBar(h3),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBar(double fraction) {
    return Container(
      width: 2.4,
      height: widget.size * fraction.clamp(0.25, 1.0),
      decoration: BoxDecoration(
        color: widget.color,
        borderRadius: BorderRadius.circular(1.5),
        boxShadow: [
          BoxShadow(
            color: widget.color.withOpacity(0.5),
            blurRadius: 4,
          ),
        ],
      ),
    );
  }
}

/// 中文/粤语/英文智能分词器
/// 采用正向最大匹配算法 (FMM) 与精细化词典，告别机械两字切割，精准拆解真实词组
class CaptionWordSegmenter {
  static const Set<String> _customDict = {
    // 粤语常用代词、语气词、动词及成语
    '我嘅', '你嘅', '佢嘅', '我哋', '你哋', '佢哋', '呢个', '呢個', '嗰个', '嗰個',
    '边个', '邊個', '点样', '點樣', '点解', '點解', '做咩', '乜嘢', '咩事', '好似',
    '唔好', '唔系', '唔係', '但系', '但係', '真系', '真係', '定系', '定係', '点算',
    '唔知', '唔得', '唔想', '唔识', '唔識', '唔见', '唔見', '得闲', '得閒', '冇事',
    '冇问题', '冇所謂', '冇所谓', '紧要', '緊要', '犀利', '多谢', '多謝', '唔该',
    '唔該', '对唔住', '對唔住', '借过', '借過', '返工', '放工', '收工', '返学',
    '返學', '放学', '放學', '睇波', '睇戏', '睇戲', '睇书', '睇書', '食饭',
    '吃飯', '食飯', '饮茶', '飲茶', '饮水', '飲水', '倾偈', '傾偈', '讲嘢',
    '講嘢', '买嘢', '買嘢', '拍拖', '结婚', '結婚', '生仔', '生女', '搵钱',
    '搵錢', '使钱', '使錢', '储钱', '儲錢', '借钱', '借錢', '还钱', '還錢',
    '大镬', '大鑊', '搞掂', '收皮', '埋单', '埋單', '开饭', '開飯', '出粮',
    '出糧', '炒鱿', '炒魷', '炒鱿鱼', '炒魷魚', '执生', '執生', '吹水', '劈友',
    '走鸡', '走雞', '顶住', '頂住', '揽住', '攬住', '撑住', '撐住', '行街',
    '行路', '搭车', '搭車', '搭船', '搭飞机', '搭飛機', '坐车', '坐車', '开车',
    '開車', '泊车', '泊車', '洗车', '洗車', '整车', '整車', '坏车', '壞車',
    '塞车', '塞車', '撞车', '撞車', '一齐', '一齊', '一齐去',
    // 法律与正式用语
    '当事人', '當事人', '原告人', '被告人', '发件人', '收件人', '发言人', '負責人',
    '负责人', '合伙人', '合夥人', '投资人', '投資人', '委托人', '委託人', '代理人',
    '监护人', '監護人', '继承人', '繼承人', '主持人', '制作人', '製作人', '策划人',
    '策劃人', '经纪人', '經紀人', '所有人', '每个人', '每個人', '普通人', '年轻人',
    '年輕人', '老年人', '机器人', '機器人', '正常人', '局外人', '同路人', '明白人',
    '陌生人', '本地人', '外地人', '中国人', '中國人', '香港人', '广东人', '廣東人',
    '当事', '當事', '原告', '被告', '达成', '達成', '和解', '律师', '律師',
    '法官', '法院', '裁判', '警察', '案件', '案情', '证据', '證據', '证人',
    '證人', '判决', '判決', '起诉', '起訴', '上诉', '上訴', '申诉', '申訴',
    '辩护', '辯護', '认罪', '認罪', '保释', '保釋', '调查', '調查', '拘留',
    '逮捕', '立案', '开庭', '開庭', '宣判', '审理', '審理', '审判', '審判',
    '裁定', '执行', '執行', '维权', '維權', '侵权', '侵權', '赔偿', '賠償',
    '补偿', '補償', '罚款', '罰款', '协议', '協議', '合同', '签约', '簽約',
    '签署', '簽署', '生效', '终止', '終止', '解除', '违约', '違約', '履约',
    '履約', '纠纷', '糾紛', '争议', '爭議', '矛盾', '谈判', '談判', '调解',
    '調解', '协商', '協商', '沟通', '溝通', '取得', '获得', '獲得', '争取',
    '爭取', '确认', '確認', '核实', '核實', '澄清', '说明', '說明', '解释',
    '解釋', '承认', '承認', '否认', '否認', '坦白', '交代', '指控', '反驳',
    '反駁', '辩解', '辯解', '质疑', '質疑', '赞同', '贊同', '支持', '反对',
    '反對', '抵制', '方案', '条件', '條件', '不同意',
    // 语法副词、代词、介词、连词
    '已经', '已經', '曾经', '曾經', '正在', '将要', '將要', '快要', '刚刚',
    '剛剛', '刚才', '剛才', '现在', '現在', '目前', '如今', '将来', '將來',
    '未来', '未來', '过去', '過去', '以前', '以后', '以後', '之前', '之后',
    '之後', '今天', '明天', '昨天', '后天', '後天', '前天', '今年', '明年',
    '去年', '每日', '每天', '常常', '经常', '經常', '时常', '時常', '往往',
    '总是', '總是', '一直', '从来', '從來', '偶尔', '偶爾', '随时', '隨時',
    '平时', '平時', '有时', '有時', '如果', '要是', '假如', '虽然', '雖然',
    '尽管', '儘管', '即使', '只要', '只有', '除非', '因为', '因為', '由于',
    '所以', '因此', '因而', '从而', '從而', '但是', '可是', '不过', '不過',
    '然而', '只是', '而且', '并且', '並且', '甚至', '不仅', '不僅', '不但',
    '或者', '还是', '還是', '以及', '对于', '對於', '关于', '關於', '按照',
    '依照', '根据', '根據', '基于', '基於', '为了', '為了', '非常', '特别',
    '特別', '十分', '极其', '極其', '格外', '相当', '相當', '稍微', '略微',
    '更加', '越来越', '越來越',
    '这个', '這個', '那个', '那個', '这些', '這些', '那些', '这里', '這裡',
    '那里', '那裡', '这么', '這麼', '那么', '那麼',
    // 日常动作与事物
    '工作', '生活', '学习', '學習', '发现', '發現', '决定', '決定', '准备',
    '準備', '开始', '開始', '结束', '結束', '继续', '繼續', '完成', '出现',
    '出現', '发生', '發生', '存在', '表示', '指出', '强调', '強調', '要求',
    '希望', '同意', '参加', '參加', '组织', '組織', '建立', '发展', '發展',
    '提高', '加强', '加強', '推动', '推動', '实现', '實現', '解决', '解決',
    '保护', '保護', '服务', '服務', '管理', '生产', '生產', '销售', '銷售',
    '投资', '投資', '市场', '市場', '经济', '經濟', '社会', '社會', '文化',
    '教育', '科技', '环境', '環境', '安全', '关系', '關係', '合作', '讨论',
    '討論', '商量', '考虑', '考慮', '建议', '建議', '申请', '申請', '批准',
    '健康', '快乐', '快樂', '幸福', '成功', '顺利', '順利', '满意', '滿意',
    '喜欢', '喜歡', '感谢', '感謝', '欢迎', '歡迎', '期待', '照顾', '照顧',
    '清楚', '明白', '准确', '準確', '正确', '正確', '真实', '真實', '有效',
    '重要', '主要', '关键', '關鍵', '核心', '基本', '根本',
  };

  static List<String> segment(String text) {
    final cleaned = text.trim();
    if (cleaned.isEmpty) return [];

    final result = <String>[];
    // 匹配连续汉字块、英文及数字块、日文假名块、韩文音节块
    final blockRegex = RegExp(
      r"([a-zA-Z0-9'-]+|[\u3040-\u309f\u30a0-\u30ff]+|[\uac00-\ud7af]+|\p{Script=Han}+)",
      unicode: true,
    );
    final blocks = blockRegex.allMatches(cleaned);

    for (final blockMatch in blocks) {
      final block = blockMatch.group(0) ?? '';
      if (block.isEmpty) continue;

      // 1. 非汉字块（英文、数字、日韩文等）保持原有词形
      if (!RegExp(r'\p{Script=Han}', unicode: true).hasMatch(block)) {
        if (!result.contains(block)) {
          result.add(block);
        }
        continue;
      }

      // 2. 连续汉字块：正向最大匹配算法 (FMM)
      int i = 0;
      while (i < block.length) {
        int matchLen = String.fromCharCode(block.substring(i).runes.first).length;
        final phrase = CantoneseLexicon.shared.phraseAt(block, i);
        if (phrase != null) {
          if (!result.contains(phrase.text)) result.add(phrase.text);
          i += phrase.text.length;
          continue;
        }
        // 优先从 4 字向 2 字贪婪匹配词库
        for (int len = math.min(4, block.length - i); len >= 2; len--) {
          final sub = block.substring(i, i + len);
          if (_customDict.contains(sub) ||
              CaptionOfflineDictionary.hasExactCantoneseEntry(sub)) {
            matchLen = len;
            break;
          }
          // 启发式后缀规则：名词 + "人" / "者" / "员"（如 "原告" + "人" = "原告人"）
          if (len == 3 && (sub.endsWith('人') || sub.endsWith('者') || sub.endsWith('员'))) {
            final prefix2 = sub.substring(0, 2);
            if (_customDict.contains(prefix2) ||
                CaptionOfflineDictionary.hasExactCantoneseEntry(prefix2)) {
              matchLen = 3;
              break;
            }
          }
        }

        final token = block.substring(i, i + matchLen);
        if (!result.contains(token)) {
          result.add(token);
        }
        i += matchLen;
      }
    }

    return result;
  }

  /// 适用于字幕渲染展示的精准切词：
  /// 严格 100% 保持原始文本的字符与相对顺序（包含空格、标点符号、换行及重复词），绝不吃掉空格！
  static List<WordToken> segmentWithDelimiters(String text) {
    if (text.isEmpty) return const [];

    final tokens = <WordToken>[];
    int cursor = 0;

    final wordRegex = RegExp(
      r"[a-zA-Z0-9'-]+|[\u3040-\u309f\u30a0-\u30ff]+|[\uac00-\ud7af]+|\p{Script=Han}+",
      unicode: true,
    );

    for (final match in wordRegex.allMatches(text)) {
      // 1. 如果匹配前存在非词内容（空格、标点符号、换行等），完全按原样保留
      if (match.start > cursor) {
        final nonWord = text.substring(cursor, match.start);
        tokens.add(WordToken(
          text: nonWord,
          isWord: false,
          isWhitespace: nonWord.trim().isEmpty,
        ));
      }

      final matchedText = match.group(0)!;

      // 2. 如果是非汉字块（英文、数字、假名、谚文），作为一个完整可点击单词
      if (!RegExp(r'\p{Script=Han}', unicode: true).hasMatch(matchedText)) {
        tokens.add(WordToken(text: matchedText, isWord: true));
      } else {
        // 3. 连续汉字块：应用 FMM 最大正向匹配算法切分成词组
        int i = 0;
        while (i < matchedText.length) {
          int matchLen = String.fromCharCode(matchedText.substring(i).runes.first).length;
          final phrase = CantoneseLexicon.shared.phraseAt(matchedText, i);
          if (phrase != null) {
            tokens.add(WordToken(text: phrase.text, isWord: true));
            i += phrase.text.length;
            continue;
          }
          for (int len = math.min(4, matchedText.length - i); len >= 2; len--) {
            final sub = matchedText.substring(i, i + len);
            if (_customDict.contains(sub) ||
                CaptionOfflineDictionary.hasExactCantoneseEntry(sub)) {
              matchLen = len;
              break;
            }
            if (len == 3 && (sub.endsWith('人') || sub.endsWith('者') || sub.endsWith('员'))) {
              final prefix2 = sub.substring(0, 2);
              if (_customDict.contains(prefix2) ||
                  CaptionOfflineDictionary.hasExactCantoneseEntry(prefix2)) {
                matchLen = 3;
                break;
              }
            }
          }
          final token = matchedText.substring(i, i + matchLen);
          tokens.add(WordToken(text: token, isWord: true));
          i += matchLen;
        }
      }

      cursor = match.end;
    }

    // 4. 末尾剩余的标点或空白
    if (cursor < text.length) {
      final trailing = text.substring(cursor);
      tokens.add(WordToken(
        text: trailing,
        isWord: false,
        isWhitespace: trailing.trim().isEmpty,
      ));
    }

    return tokens;
  }
}

class WordToken {
  final String text;
  final bool isWord;
  final bool isWhitespace;

  const WordToken({
    required this.text,
    required this.isWord,
    this.isWhitespace = false,
  });
}

class _SheetRubyItem {
  final String text;
  final String? ruby;

  const _SheetRubyItem(this.text, this.ruby);
}
