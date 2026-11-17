import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'caption_offline_dictionary.dart';
import 'caption_pronunciation.dart';
import 'caption_tts_service.dart';

/// 查词释义模型
class WordDefinition {
  const WordDefinition({
    required this.partOfSpeech,
    required this.meanings,
  });

  /// 词性，如 "n.", "v.", "adj."，若无则为空
  final String partOfSpeech;

  /// 该词性下的所有释义
  final List<String> meanings;
}

/// 双语例句模型
class WordExample {
  const WordExample({
    required this.sentence,
    required this.translation,
  });

  /// 原文例句（可能包含高亮词）
  final String sentence;

  /// 例句译文
  final String translation;
}

/// 查词完整结果模型
class WordLookupResult {
  const WordLookupResult({
    required this.query,
    this.phonetic,
    this.ukPhonetic,
    this.usPhonetic,
    this.audioUrl,
    this.ukAudioUrl,
    this.usAudioUrl,
    this.definitions = const [],
    this.examples = const [],
    this.contextSentence,
    this.contextTranslation,
    this.sourceLanguage = 'en',
    this.rawTranslation,
  });

  final String query;
  final String? phonetic;
  final String? ukPhonetic;
  final String? usPhonetic;
  final String? audioUrl;
  final String? ukAudioUrl;
  final String? usAudioUrl;
  final List<WordDefinition> definitions;
  final List<WordExample> examples;
  final String? contextSentence;
  final String? contextTranslation;
  final String sourceLanguage;
  final String? rawTranslation;

  bool get hasDefinitions => definitions.isNotEmpty || (rawTranslation != null && rawTranslation!.isNotEmpty);
  bool get hasExamples => examples.isNotEmpty;
  bool get hasPhonetic => (phonetic != null && phonetic!.isNotEmpty) ||
      (ukPhonetic != null && ukPhonetic!.isNotEmpty) ||
      (usPhonetic != null && usPhonetic!.isNotEmpty);
}

/// 发音音频播放器（基于 media_kit 与本地音频缓存）
class WordAudioPlayer {
  static final WordAudioPlayer shared = WordAudioPlayer._();
  WordAudioPlayer._();

  Player? _player;
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 10),
  ));

  Player get _safePlayer {
    _player ??= Player(
      configuration: const PlayerConfiguration(
        bufferSize: 1024 * 1024,
      ),
    );
    return _player!;
  }

  static const MethodChannel _ttsChannel = MethodChannel('pilipala/native_tts');
  final Map<String, Future<File?>> _downloading = {};

  /// 后台自动预缓存音频文件，让用户点击发音时达到 0ms 瞬间秒播
  void preload(List<String?> urls) {
    for (final url in urls) {
      if (url != null && url.isNotEmpty) {
        _getAudioFile(url);
      }
    }
  }

  Future<File?> _getCachedFile(String url) async {
    try {
      final hash = md5.convert(utf8.encode(url)).toString();
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/dict_audio_$hash.mp3');
      if (await file.exists() && await file.length() > 200) {
        return file;
      }
    } catch (_) {}
    return null;
  }

  Future<void> play(
    String audioUrl, {
    String? fallbackUrl,
    String? speakText,
    String? speakLang,
  }) async {
    if (audioUrl.isEmpty && (speakText == null || speakText.isEmpty)) return;

    final isYue = speakLang == 'zh-HK' ||
        speakLang == 'yue' ||
        (speakText != null && CaptionPronunciation.isCantoneseText(speakText));

    // 0. 粤语发音：核心优先走神经网络 TTS (Microsoft Edge-TTS / 小米 MiMo-V2.5-TTS)，彻底告别 Android 系统 TTS 读成普通话！
    if (isYue && speakText != null && speakText.isNotEmpty) {
      try {
        final ttsFile = await CaptionTtsService.shared.synthesize(
          text: speakText,
          lang: 'yue',
        );
        if (ttsFile != null && await ttsFile.exists()) {
          final p = _safePlayer;
          await p.open(Media(ttsFile.path), play: true);
          return;
        }
      } catch (_) {}
    }

    // 1. 本地已缓存音频瞬间秒播（0ms）
    if (audioUrl.isNotEmpty) {
      final cached = await _getCachedFile(audioUrl);
      if (cached != null) {
        final p = _safePlayer;
        await p.open(Media(cached.path), play: true);
        return;
      }
    }

    // 2. 未预缓存时，尝试快速网络拉取（设置 1.2 秒超快超时，避免长时间转圈卡顿）
    if (audioUrl.isNotEmpty) {
      try {
        final file = await _getAudioFile(audioUrl, timeoutMs: 1200) ??
            (fallbackUrl != null && fallbackUrl.isNotEmpty
                ? await _getAudioFile(fallbackUrl, timeoutMs: 1200)
                : null);
        if (file != null && await file.exists()) {
          final p = _safePlayer;
          await p.open(Media(file.path), play: true);
          return;
        }
      } catch (_) {}
    }

    // 3. 在线词典音频无可用时，尝试通过高品质 Edge-TTS / MiMo 语音合成
    if (speakText != null && speakText.isNotEmpty) {
      try {
        final ttsFile = await CaptionTtsService.shared.synthesize(
          text: speakText,
          lang: speakLang ?? 'auto',
        );
        if (ttsFile != null && await ttsFile.exists()) {
          final p = _safePlayer;
          await p.open(Media(ttsFile.path), play: true);
          return;
        }
      } catch (_) {}
    }

    // 4. 网络缓慢或完全断网时，使用系统底层离线原生 TextToSpeech（响应时间 < 30ms，兜底保障）
    if (speakText != null && speakText.isNotEmpty) {
      try {
        final success = await _ttsChannel.invokeMethod<bool>('speak', {
          'text': speakText,
          'lang': speakLang ?? 'zh-HK',
        });
        if (success == true) return;
      } catch (_) {}
    }
  }

  Future<File?> _getAudioFile(String url, {int timeoutMs = 4000}) async {
    final cached = await _getCachedFile(url);
    if (cached != null) return cached;

    if (_downloading.containsKey(url)) {
      return _downloading[url];
    }

    final future = _fetchAudioFile(url, timeoutMs: timeoutMs);
    _downloading[url] = future;
    try {
      return await future;
    } finally {
      _downloading.remove(url);
    }
  }

  Future<File?> _fetchAudioFile(String url, {required int timeoutMs}) async {
    try {
      final hash = md5.convert(utf8.encode(url)).toString();
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/dict_audio_$hash.mp3');
      if (await file.exists() && await file.length() > 200) {
        return file;
      }
      final res = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          sendTimeout: Duration(milliseconds: timeoutMs),
          receiveTimeout: Duration(milliseconds: timeoutMs),
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Referer': url.contains('youdao')
                ? 'https://dict.youdao.com/'
                : 'https://translate.googleapis.com/',
          },
        ),
      );
      if (res.data != null && res.data!.isNotEmpty) {
        await file.writeAsBytes(res.data!);
        return file;
      }
    } catch (_) {}
    return null;
  }

  void stop() {
    try {
      _player?.stop();
    } catch (_) {}
  }

  void dispose() {
    _player?.dispose();
    _player = null;
  }
}

/// 字典与查词核心服务
class CaptionDictionary {
  static final shared = CaptionDictionary._();
  CaptionDictionary._();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 5),
    followRedirects: true,
  ));

  final Map<String, WordLookupResult> _cache = {};

  /// 查词主入口
  Future<WordLookupResult> lookup(
    String rawWord, {
    String? contextSentence,
    String? contextTranslation,
    bool? isCantonese,
    String? forcedLanguage,
  }) async {
    final query = cleanWord(rawWord);
    if (query.isEmpty) {
      return WordLookupResult(
        query: rawWord,
        contextSentence: contextSentence,
        contextTranslation: contextTranslation,
      );
    }

    var lang = forcedLanguage ?? CaptionPronunciation.detectLanguage(query);
    // 若单词为中文，但上下文句子为粤语，或外部标记为粤语，或属于离线粤语词库，则识别为粤语
    if (forcedLanguage == null && (lang == 'zh-CN' || lang == 'auto')) {
      if (isCantonese == true ||
          CaptionOfflineDictionary.isCantoneseWord(query) ||
          (contextSentence != null &&
              CaptionPronunciation.isCantoneseText(contextSentence))) {
        lang = 'yue';
      }
    } else if (forcedLanguage != null) {
      lang = forcedLanguage;
    }

    final cacheKey = '$lang:${query.toLowerCase()}';
    if (_cache.containsKey(cacheKey)) {
      final cached = _cache[cacheKey]!;
      WordAudioPlayer.shared.preload([
        cached.audioUrl,
        cached.ukAudioUrl,
        cached.usAudioUrl,
      ]);
      return WordLookupResult(
        query: cached.query,
        phonetic: cached.phonetic,
        ukPhonetic: cached.ukPhonetic,
        usPhonetic: cached.usPhonetic,
        audioUrl: cached.audioUrl,
        ukAudioUrl: cached.ukAudioUrl,
        usAudioUrl: cached.usAudioUrl,
        definitions: cached.definitions,
        examples: cached.examples,
        contextSentence: contextSentence ?? cached.contextSentence,
        contextTranslation: contextTranslation ?? cached.contextTranslation,
        sourceLanguage: cached.sourceLanguage,
        rawTranslation: cached.rawTranslation,
      );
    }

    // 0. 优先匹配本地离线词典库（0ms 极速响应，无需等待网络）
    final offlineResult = CaptionOfflineDictionary.shared.lookup(
      query,
      contextSentence: contextSentence,
      contextTranslation: contextTranslation,
      isCantonese: lang == 'yue' || isCantonese == true,
    );
    if (offlineResult != null) {
      WordAudioPlayer.shared.preload([
        offlineResult.audioUrl,
        offlineResult.ukAudioUrl,
        offlineResult.usAudioUrl,
      ]);
      _cache[cacheKey] = offlineResult;
      return offlineResult;
    }

    // 优先尝试有道词典 API
    WordLookupResult? result;
    try {
      result = await _lookupYoudao(
        query,
        lang: lang,
        contextSentence: contextSentence,
        contextTranslation: contextTranslation,
      );
    } catch (e) {
      // ignore
    }

    // 若有道未查到释义或网络异常，使用 Google 词典/翻译作为兜底或补充
    if (result == null || !result.hasDefinitions || (lang == 'yue' && result.phonetic == null)) {
      try {
        final googleResult = await _lookupGoogle(
          query,
          lang: lang,
          contextSentence: contextSentence,
          contextTranslation: contextTranslation,
        );
        if (googleResult != null) {
          result = _mergeResults(result, googleResult);
        }
      } catch (e) {
        // ignore
      }
    }

    final finalResult = result ??
        WordLookupResult(
          query: query,
          sourceLanguage: lang,
          contextSentence: contextSentence,
          contextTranslation: contextTranslation,
        );

    WordAudioPlayer.shared.preload([
      finalResult.audioUrl,
      finalResult.ukAudioUrl,
      finalResult.usAudioUrl,
    ]);
    CaptionTtsService.shared.preload(text: query, lang: lang);

    _cache[cacheKey] = finalResult;
    return finalResult;
  }

  /// 清洗单词，去掉首尾标点符号
  static String cleanWord(String text) {
    return text.replaceAll(RegExp(r"^[\s\p{P}]+|[\s\p{P}]+$", unicode: true), '').trim();
  }

  /// 有道词典公开接口
  Future<WordLookupResult?> _lookupYoudao(
    String query, {
    required String lang,
    String? contextSentence,
    String? contextTranslation,
  }) async {
    final response = await _dio.get<String>(
      'https://dict.youdao.com/jsonapi',
      queryParameters: {
        'jsonversion': '2',
        'client': 'mobile',
        'q': query,
      },
      options: Options(responseType: ResponseType.plain),
    );

    final dynamic data = jsonDecode(response.data ?? '');
    if (data is! Map) return null;

    String? phonetic;
    String? ukPhonetic;
    String? usPhonetic;
    String? ukAudioUrl;
    String? usAudioUrl;
    String? audioUrl;
    final definitions = <WordDefinition>[];
    final examples = <WordExample>[];

    // 1. 英汉模块 (ec)
    if (data['ec'] is Map && data['ec']['word'] is List && (data['ec']['word'] as List).isNotEmpty) {
      final wordObj = data['ec']['word'][0];
      if (wordObj is Map) {
        phonetic = wordObj['phonetic']?.toString();
        ukPhonetic = wordObj['ukphone']?.toString();
        usPhonetic = wordObj['usphone']?.toString();
        if (usPhonetic != null && phonetic == null) phonetic = usPhonetic;

        ukAudioUrl = 'https://dict.youdao.com/dictvoice?audio=${Uri.encodeComponent(query)}&type=1';
        usAudioUrl = 'https://dict.youdao.com/dictvoice?audio=${Uri.encodeComponent(query)}&type=2';
        audioUrl = usAudioUrl;

        // 解析释义 trs
        if (wordObj['trs'] is List) {
          for (final trGroup in wordObj['trs']) {
            if (trGroup is Map && trGroup['tr'] is List && (trGroup['tr'] as List).isNotEmpty) {
              final trFirst = trGroup['tr'][0];
              if (trFirst is Map && trFirst['l'] is Map && trFirst['l']['i'] is List) {
                final meaningList = (trFirst['l']['i'] as List)
                    .map((e) => e.toString().trim())
                    .where((e) => e.isNotEmpty)
                    .toList();
                for (final item in meaningList) {
                  final parsedDef = _parsePosAndMeaning(item);
                  definitions.add(parsedDef);
                }
              }
            }
          }
        }
      }
    }

    // 2. 汉英模块 (ce)
    if (data['ce'] is Map && data['ce']['word'] is List && (data['ce']['word'] as List).isNotEmpty) {
      final wordObj = data['ce']['word'][0];
      if (wordObj is Map) {
        if (phonetic == null && wordObj['phone'] != null) {
          phonetic = wordObj['phone'].toString();
        }
        if (lang != 'yue') {
          audioUrl ??= 'https://dict.youdao.com/dictvoice?audio=${Uri.encodeComponent(query)}&le=zh';
        }

        if (wordObj['trs'] is List) {
          final ceMeanings = <String>[];
          for (final tr in wordObj['trs']) {
            if (tr is Map && tr['#text'] != null) {
              ceMeanings.add(tr['#text'].toString());
            }
          }
          if (ceMeanings.isNotEmpty) {
            definitions.add(WordDefinition(partOfSpeech: '', meanings: ceMeanings));
          }
        }
      }
    }

    // 3. 简明释义 (simple)
    if (definitions.isEmpty && data['simple'] is Map && data['simple']['word'] is List) {
      final list = data['simple']['word'] as List;
      if (list.isNotEmpty && list[0] is Map) {
        final simpleObj = list[0];
        if (phonetic == null && simpleObj['phone'] != null) {
          phonetic = simpleObj['phone'].toString();
        }
      }
    }

    // 4. 双语例句 (blng_sents_part)
    if (data['blng_sents_part'] is Map &&
        data['blng_sents_part']['sentence-pair'] is List) {
      final pairs = data['blng_sents_part']['sentence-pair'] as List;
      for (final pair in pairs.take(4)) {
        if (pair is Map) {
          final orig = pair['sentence']?.toString() ?? '';
          final trans = pair['sentence-translation']?.toString() ?? '';
          if (orig.isNotEmpty && trans.isNotEmpty) {
            examples.add(WordExample(
              sentence: _cleanHtml(orig),
              translation: trans,
            ));
          }
        }
      }
    }

    // 5. 翻译兜底 (fanyi)
    String? rawTrans;
    if (data['fanyi'] is Map && data['fanyi']['tran'] != null) {
      rawTrans = data['fanyi']['tran'].toString();
    }

    if (lang == 'ja') {
      audioUrl = 'https://translate.googleapis.com/translate_tts?ie=UTF-8&client=tw-ob&tl=ja&q=${Uri.encodeComponent(query)}';
    } else if (lang == 'ko') {
      audioUrl = 'https://translate.googleapis.com/translate_tts?ie=UTF-8&client=tw-ob&tl=ko&q=${Uri.encodeComponent(query)}';
    } else if (lang == 'yue') {
      audioUrl = 'https://translate.googleapis.com/translate_tts?ie=UTF-8&client=tw-ob&tl=zh-HK&q=${Uri.encodeComponent(query)}';
      if (data['baike'] is Map && data['baike']['summarys'] is List) {
        for (final item in (data['baike']['summarys'] as List)) {
          if (item is Map && item['summary'] != null) {
            definitions.add(WordDefinition(
              partOfSpeech: '粤语',
              meanings: [item['summary'].toString().trim()],
            ));
          }
        }
      }
    } else if (lang == 'en') {
      ukPhonetic ??= usPhonetic ?? phonetic;
      usPhonetic ??= ukPhonetic ?? phonetic;
      phonetic ??= usPhonetic ?? ukPhonetic;
      ukAudioUrl ??= 'https://dict.youdao.com/dictvoice?audio=${Uri.encodeComponent(query)}&type=1';
      usAudioUrl ??= 'https://dict.youdao.com/dictvoice?audio=${Uri.encodeComponent(query)}&type=2';
      audioUrl = usAudioUrl;
    }

    return WordLookupResult(
      query: query,
      phonetic: phonetic,
      ukPhonetic: ukPhonetic,
      usPhonetic: usPhonetic,
      audioUrl: audioUrl,
      ukAudioUrl: ukAudioUrl,
      usAudioUrl: usAudioUrl,
      definitions: definitions,
      examples: examples,
      contextSentence: contextSentence,
      contextTranslation: contextTranslation,
      sourceLanguage: lang,
      rawTranslation: rawTrans,
    );
  }

  /// Google 词典 / 翻译兜底
  Future<WordLookupResult?> _lookupGoogle(
    String query, {
    required String lang,
    String? contextSentence,
    String? contextTranslation,
  }) async {
    final isYue = lang == 'yue';
    final response = await _dio.get<String>(
      'https://translate.googleapis.com/translate_a/single',
      queryParameters: {
        'client': 'gtx',
        'sl': isYue ? 'yue' : 'auto',
        'tl': 'zh-CN',
        'dt': ['t', 'bd', 'rm', 'ex', 'md', 'ss'],
        'q': query,
      },
      options: Options(
        responseType: ResponseType.plain,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        },
      ),
    );

    final dynamic data = jsonDecode(response.data ?? '');
    if (data is! List || data.isEmpty) return null;

    final detectedLang = (data.length > 2 && data[2] is String && (data[2] as String).isNotEmpty)
        ? data[2].toString().toLowerCase()
        : lang;
    final effectiveLang = (isYue || lang == 'yue' || CaptionPronunciation.isCantoneseText(query))
        ? 'yue'
        : detectedLang;

    String? transliteration;
    String? rawTranslation;

    // 解析翻译与注音
    if (data[0] is List && (data[0] as List).isNotEmpty) {
      final sentences = data[0] as List;
      final transBuf = StringBuffer();
      for (final s in sentences) {
        if (s is List && s.isNotEmpty && s[0] != null) {
          transBuf.write(s[0].toString());
        }
      }
      rawTranslation = transBuf.toString().trim();

      // 最后一条包含拼音/罗马字/粤拼
      final lastSentence = sentences.last;
      if (lastSentence is List) {
        // Google Translate API 规则：
        // sentences.last: [null, null, 译文拼音(如中文拼音), 原文罗马字/音标/拼音(如日文Romaji/韩文/粤拼)]
        // 当查询语言不是普通话（如日/韩/粤/外语）时，必须优先取 index 3 (原文注音)！
        // 绝不能取 index 2（译文中文的拼音，例如“基于中东局势”的 Jīyú zhōngdōng júshì）
        if (lastSentence.length > 3 && lastSentence[3] != null) {
          final origPhonetic = lastSentence[3].toString().trim();
          if (origPhonetic.isNotEmpty) {
            if (effectiveLang == 'yue') {
              transliteration = CaptionPronunciation.formatJyutping(origPhonetic);
            } else {
              transliteration = origPhonetic;
            }
          }
        }

        // 仅当 index 3 为空，且源语言本身就是中文普通话/自动时，才从 index 2 取拼音
        if (transliteration == null && lastSentence.length > 2 && lastSentence[2] != null) {
          final pinyin = lastSentence[2].toString().trim();
          if (effectiveLang == 'zh-CN' || effectiveLang == 'auto' || effectiveLang == 'yue') {
            transliteration = effectiveLang == 'yue'
                ? CaptionPronunciation.formatJyutping(pinyin)
                : pinyin;
          }
        }
      }
    }

    // 解析词典分组释义 (data[1])
    final definitions = <WordDefinition>[];
    if (data.length > 1 && data[1] is List) {
      for (final dictItem in data[1]) {
        if (dictItem is List && dictItem.isNotEmpty) {
          final pos = dictItem[0]?.toString() ?? '';
          final meanings = <String>[];
          if (dictItem.length > 1 && dictItem[1] is List) {
            for (final m in dictItem[1]) {
              if (m != null) meanings.add(m.toString());
            }
          }
          if (meanings.isNotEmpty) {
            definitions.add(WordDefinition(
              partOfSpeech: _formatPos(pos),
              meanings: meanings,
            ));
          }
        }
      }
    }

    // 解析例句 (data[13])
    final examples = <WordExample>[];
    if (data.length > 13 && data[13] is List && (data[13] as List).isNotEmpty) {
      final exList = data[13][0];
      if (exList is List) {
        for (final item in exList.take(3)) {
          if (item is List && item.isNotEmpty && item[0] != null) {
            examples.add(WordExample(
              sentence: _cleanHtml(item[0].toString()),
              translation: '',
            ));
          }
        }
      }
    }

    final String? ukAudioUrl = effectiveLang == 'en'
        ? 'https://dict.youdao.com/dictvoice?audio=${Uri.encodeComponent(query)}&type=1'
        : null;
    final String? usAudioUrl = effectiveLang == 'en'
        ? 'https://dict.youdao.com/dictvoice?audio=${Uri.encodeComponent(query)}&type=2'
        : null;
    final String audioUrl;
    if (effectiveLang == 'yue') {
      audioUrl = 'https://translate.googleapis.com/translate_tts?ie=UTF-8&client=tw-ob&tl=zh-HK&q=${Uri.encodeComponent(query)}';
    } else if (effectiveLang == 'en') {
      audioUrl = usAudioUrl!;
    } else if (effectiveLang == 'ja') {
      audioUrl = 'https://translate.googleapis.com/translate_tts?ie=UTF-8&client=tw-ob&tl=ja&q=${Uri.encodeComponent(query)}';
    } else if (effectiveLang == 'ko') {
      audioUrl = 'https://translate.googleapis.com/translate_tts?ie=UTF-8&client=tw-ob&tl=ko&q=${Uri.encodeComponent(query)}';
    } else if (effectiveLang == 'zh-CN') {
      audioUrl = 'https://translate.googleapis.com/translate_tts?ie=UTF-8&client=tw-ob&tl=zh-CN&q=${Uri.encodeComponent(query)}';
    } else {
      audioUrl = 'https://translate.googleapis.com/translate_tts?ie=UTF-8&client=tw-ob&tl=${Uri.encodeComponent(effectiveLang)}&q=${Uri.encodeComponent(query)}';
    }

    return WordLookupResult(
      query: query,
      phonetic: transliteration,
      ukPhonetic: effectiveLang == 'en' ? transliteration : null,
      usPhonetic: effectiveLang == 'en' ? transliteration : null,
      audioUrl: audioUrl,
      ukAudioUrl: ukAudioUrl,
      usAudioUrl: usAudioUrl,
      definitions: definitions,
      examples: examples,
      contextSentence: contextSentence,
      contextTranslation: contextTranslation,
      sourceLanguage: effectiveLang,
      rawTranslation: rawTranslation,
    );
  }

  /// 合并有道与 Google 的结果
  WordLookupResult _mergeResults(WordLookupResult? a, WordLookupResult b) {
    if (a == null) return b;
    final isYue = (a.sourceLanguage == 'yue' || b.sourceLanguage == 'yue');
    final effectiveLang = isYue
        ? 'yue'
        : ((a.sourceLanguage != 'zh-CN' && a.sourceLanguage != 'auto')
            ? a.sourceLanguage
            : b.sourceLanguage);
    final mergedAudioUrl = isYue
        ? 'https://translate.googleapis.com/translate_tts?ie=UTF-8&client=tw-ob&tl=zh-HK&q=${Uri.encodeComponent(a.query)}'
        : (a.audioUrl ?? b.audioUrl);

    return WordLookupResult(
      query: a.query,
      phonetic: a.phonetic ?? b.phonetic,
      ukPhonetic: a.ukPhonetic ?? b.ukPhonetic ?? a.phonetic ?? b.phonetic,
      usPhonetic: a.usPhonetic ?? b.usPhonetic ?? a.phonetic ?? b.phonetic,
      audioUrl: mergedAudioUrl,
      ukAudioUrl: a.ukAudioUrl ?? b.ukAudioUrl,
      usAudioUrl: a.usAudioUrl ?? b.usAudioUrl,
      definitions: a.definitions.isNotEmpty ? a.definitions : b.definitions,
      examples: a.examples.isNotEmpty ? a.examples : b.examples,
      contextSentence: a.contextSentence ?? b.contextSentence,
      contextTranslation: a.contextTranslation ?? b.contextTranslation,
      sourceLanguage: effectiveLang,
      rawTranslation: a.rawTranslation ?? b.rawTranslation,
    );
  }

  /// 分离词性与释义，例如 "n. 苹果；苹果树" -> pos="n.", meaning="苹果；苹果树"
  static WordDefinition _parsePosAndMeaning(String text) {
    final match = RegExp(r"^([a-zA-Z]+\.)\s*(.*)$").firstMatch(text);
    if (match != null) {
      return WordDefinition(
        partOfSpeech: match.group(1)!,
        meanings: [match.group(2)!],
      );
    }
    return WordDefinition(
      partOfSpeech: '',
      meanings: [text],
    );
  }

  static String _formatPos(String pos) {
    switch (pos.toLowerCase()) {
      case 'noun':
        return 'n.';
      case 'verb':
        return 'v.';
      case 'adjective':
        return 'adj.';
      case 'adverb':
        return 'adv.';
      case 'pronoun':
        return 'pron.';
      case 'preposition':
        return 'prep.';
      case 'conjunction':
        return 'conj.';
      case 'interjection':
        return 'int.';
      default:
        return pos.isNotEmpty ? '$pos.' : '';
    }
  }

  static String _cleanHtml(String html) {
    return html.replaceAll(RegExp(r'<[^>]*>'), '');
  }
}

