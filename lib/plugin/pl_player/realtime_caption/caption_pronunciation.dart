import 'dart:convert';
import 'package:dio/dio.dart';
import 'caption_offline_phonetics.dart';
import 'japanese_reading.dart';

/// 字幕发音注音服务
/// 支持：
/// - 中文：普通话拼音（带声调）
/// - 粤语：粤语拼音（Jyutping）
/// - 日语：假名（平假名）或 罗马音（Romaji）
/// - 韩语：韩语发音（罗马注音 Romaja）
/// - 英语：国际音标（IPA）
class CaptionPronunciation {
  static final shared = CaptionPronunciation._();
  CaptionPronunciation._();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 3),
    receiveTimeout: const Duration(seconds: 3),
    followRedirects: true,
    headers: {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      'Accept': '*/*',
    },
  ));

  final Map<String, String> _cache = {};

  /// 本地极速离线获取发音注音（0ms 同步秒出，彻底消除网络请求时延与丢字）
  String? getOfflinePronunciation(
    String text, {
    String japaneseMode = 'kana',
    String chineseMode = 'auto',
    bool isCantoneseContext = false,
    String? sourceLang,
  }) {
    return CaptionOfflinePhonetics.shared.tryConvert(
      text,
      japaneseMode: japaneseMode,
      chineseMode: chineseMode,
      isCantoneseContext: isCantoneseContext,
      sourceLang: sourceLang,
    );
  }

  /// 获取发音注音（优先 0ms 纯本地秒出，未命中再走缓存或网络）
  Future<String?> getPronunciation(
    String text, {
    String japaneseMode = 'kana', // 'kana' 或 'romaji'
    String chineseMode = 'auto', // 'auto', 'cantonese', 'mandarin'
    bool isCantoneseContext = false,
    String? sourceLang,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;

    final effectiveLang = sourceLang ?? detectLanguage(trimmed);
    if (effectiveLang == 'ja') {
      await JapaneseReadingService.shared.analyze(trimmed);
      return CaptionOfflinePhonetics.getJapanesePhonetic(trimmed, mode: japaneseMode);
    }
    final cacheKey = '$effectiveLang:$chineseMode:$japaneseMode:$isCantoneseContext:$trimmed';
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey];
    }

    // 1. 优先 0ms 本地离线解析（中、日、韩、粤、英高频秒出）
    final offline = getOfflinePronunciation(
      trimmed,
      japaneseMode: japaneseMode,
      chineseMode: chineseMode,
      isCantoneseContext: isCantoneseContext,
      sourceLang: effectiveLang,
    );
    if (offline != null && offline.isNotEmpty) {
      _cache[cacheKey] = offline;
      return offline;
    }

    // 2. 离线未命中的生僻词或其它语种，才异步走网络兜底
    try {
      var lang = effectiveLang;
      if (lang == 'zh-CN' || lang == 'yue') {
        if (chineseMode == 'cantonese' || isCantoneseContext || effectiveLang == 'yue') {
          lang = 'yue';
        } else if (chineseMode == 'mandarin') {
          lang = 'zh-CN';
        }
      }

      String? result;

      if (lang == 'en') {
        result = await _getEnglishIpa(trimmed);
      } else {
        result = await _getGoogleRomanization(trimmed, lang: lang);
        if (lang == 'ja') {
          if (japaneseMode == 'kana' && result != null) {
            result = romajiToHiragana(result);
          }
          // 无论是假名还是罗马音，日文发音绝对不能包含任何汉字！
          if (result != null && RegExp(r'[\u4E00-\u9FFF]').hasMatch(result)) {
            result = result.replaceAll(RegExp(r'[\u4E00-\u9FFF]'), '').trim();
            if (result.isEmpty) result = null;
          }
        } else if (lang == 'yue' && result != null) {
          result = formatJyutping(result);
          if (RegExp(r'[\u4E00-\u9FFF]').hasMatch(result)) {
            result = null;
          }
        }
      }

      if (result != null && result.isNotEmpty) {
        _cache[cacheKey] = result;
        return result;
      }
    } catch (_) {}

    return null;
  }

  /// 格式化粤语拼音（Jyutping），在声调数字与下一音节间添加空格便于阅读
  static String formatJyutping(String text) {
    var formatted = text.replaceAllMapped(
      RegExp(r'(\d)([a-zA-Z])'),
      (m) => '${m[1]} ${m[2]}',
    );
    return formatted.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// 语言检测
  static String detectLanguage(String text, {String? defaultOrContext}) {
    // 优先采用已有语境语言（若已明确为日语、粤语、韩语等，绝不按汉字误判为中文普通话）
    if (defaultOrContext != null && defaultOrContext != 'auto' && defaultOrContext.isNotEmpty) {
      return defaultOrContext;
    }
    // 包含韩文字符
    if (RegExp(r'[\uAC00-\uD7AF\u1100-\u11FF]').hasMatch(text)) {
      return 'ko';
    }
    // 包含日文平假名/片假名
    if (RegExp(r'[\u3040-\u309F\u30A0-\u30FF]').hasMatch(text)) {
      return 'ja';
    }
    // 包含典型粤语字词或习惯搭配
    if (isCantoneseText(text)) {
      return 'yue';
    }
    // 包含汉字，默认为中文
    if (RegExp(r'[\u4E00-\u9FFF]').hasMatch(text)) {
      return 'zh-CN';
    }
    // 西里尔字母 (俄语、乌克兰语等)
    if (RegExp(r'[\u0400-\u04FF]').hasMatch(text)) {
      return 'ru';
    }
    // 阿拉伯字母
    if (RegExp(r'[\u0600-\u06FF]').hasMatch(text)) {
      return 'ar';
    }
    // 泰文字符
    if (RegExp(r'[\u0E00-\u0E7F]').hasMatch(text)) {
      return 'th';
    }
    // 土耳其语特有字母 (ğ, ş, ı, ö, ü, ç, Ğ, Ş, İ, Ö, Ü, Ç)
    if (RegExp(r'[ğşıöüçĞŞİÖÜÇ]').hasMatch(text)) {
      return 'tr';
    }
    // 法语特有字母 (à, â, æ, é, è, ê, ë, î, ï, ô, œ, ù, û, ÿ)
    if (RegExp(r'[àâæéèêëîïôœùûÿÀÂÆÉÈÊËÎÏÔŒÙÛŸ]').hasMatch(text)) {
      return 'fr';
    }
    // 德语特有字母 (ä, ö, ü, ß)
    if (RegExp(r'[äöüßÄÖÜ]').hasMatch(text)) {
      return 'de';
    }
    // 西班牙语特有字母 (á, é, í, ó, ú, ñ, ¿, ¡)
    if (RegExp(r'[áíóúñ¿¡ÁÍÓÚÑ]').hasMatch(text)) {
      return 'es';
    }
    // 纯拉丁英文字符
    if (RegExp(r'^[a-zA-Z0-9\s\p{P}]+$', unicode: true).hasMatch(text)) {
      return 'en';
    }
    return 'auto';
  }

  /// 识别是否包含粤语特征字词与语法句式
  static bool isCantoneseText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;

    // 1. 粤语专有字集
    const cantoneseChars =
        '唔喺哋咗嘅乜冇睇諗搵嘢㗎啫嘞咁係咪佢瞓返落講食玩靚靓咧呐呢嗰啱卒攰慳撩嘈噏嗌喐掟氹掹抌拗黐抦扯畀俾冧嘥埗邨鎅揸攞踎';
    for (var i = 0; i < trimmed.length; i++) {
      if (cantoneseChars.contains(trimmed[i])) {
        return true;
      }
    }

    // 2. 粤语特征句末语法：“...先”（如“食饭先”、“签协议钱先”、“行先”、“走先”）
    if (RegExp(r'(先[。？！?!~…\s]*$|先啦|先至|先係|先系|先讲|先食|先走|钱先)').hasMatch(trimmed)) {
      return true;
    }

    // 3. 粤语常见词组/习惯搭配（避免单字普通话混淆）
    const cantonesePhrases = [
      '但系', '但係', '真系', '真係', '我系', '我係', '你系', '你係',
      '点解', '點解', '点样', '點樣', '点算', '點算', '几时', '幾時', '几多', '幾多',
      '屋企', '好彩', '拍拖', '埋单', '埋單', '执笠', '執笠',
      '宜家', '而家', '依家', '琴日', '尋日', '听日', '聽日',
      '好睇', '难睇', '睇见', '搵到', '搵唔到', '食饭', '饮茶',
      '收工', '放工', '返工', '返屋企', '番去', '返去', '好靓', '正嘢', '正野',
      '冇事', '冇野', '冇嘢', '冇问题', '唔好', '好唔好', '差唔多',
      '系咪', '係咪', '系唔系', '係唔係', '边度', '邊度', '边个', '邊個',
      '乜嘢', '乜野', '呢度', '嗰度', '点知', '點知', '好耐', '一齐', '一起',
      '唔知', '唔明', '唔紧要', '唔緊要', '唔该', '唔該', '多谢', '多謝',
      '婚切', '倾计', '倾偈', '睇下', '试下', '等阵', '等陣', '搞掂', '搞定'
    ];
    for (final phrase in cantonesePhrases) {
      if (trimmed.contains(phrase)) {
        return true;
      }
    }
    return false;
  }

  static const _googleEndpoints = [
    'https://translate.googleapis.com/translate_a/single',
    'https://translate.google.com/translate_a/single',
    'https://google.qianche.dpdns.org/translate_a/single',
  ];

  /// 通过 Google 转换服务获取罗马字/拼音注音
  Future<String?> _getGoogleRomanization(String text, {String lang = 'auto'}) async {
    for (final endpoint in _googleEndpoints) {
      try {
        final response = await _dio.get<String>(
          endpoint,
          queryParameters: {
            'client': 'dict-chrome-ex',
            'sl': lang, // 保持 yue，避免 zh-HK 导致返回普通话拼音
            'tl': 'en',
            'dt': ['t', 'rm'],
            'q': text,
          },
          options: Options(
            responseType: ResponseType.plain,
            sendTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 3),
          ),
        );

        final dynamic data = jsonDecode(response.data ?? '');
        if (data is! List || data.isEmpty) continue;
        final dynamic sentences = data[0];
        if (sentences is! List || sentences.isEmpty) continue;

        final dynamic lastElement = sentences.last;
        if (lastElement is List) {
          for (final item in lastElement.reversed) {
            if (item is String && item.trim().isNotEmpty && item != text) {
              return item.trim();
            }
          }
        }
      } catch (_) {
        // Try fallback endpoint
      }
    }
    return null;
  }

  /// 英语文本转音标 (IPA)
  Future<String> _getEnglishIpa(String text) async {
    final words = text.split(RegExp(r'(\s+|[.,!?;:"])')).where((w) => w.isNotEmpty);
    final ipaParts = <String>[];

    for (final word in words) {
      final clean = word.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
      if (clean.isEmpty) continue;

      if (_commonEnglishIpa.containsKey(clean)) {
        ipaParts.add(_commonEnglishIpa[clean]!);
      } else {
        final onlineIpa = await _lookupDictionaryIpa(clean);
        ipaParts.add(onlineIpa ?? clean);
      }
    }

    if (ipaParts.isEmpty) return text;
    return '/${ipaParts.join(' ')}/';
  }

  /// 在线查询英文单词音标
  Future<String?> _lookupDictionaryIpa(String word) async {
    try {
      final res = await _dio.get<List<dynamic>>(
        'https://api.dictionaryapi.dev/api/v2/entries/en/$word',
      );
      final list = res.data;
      if (list != null && list.isNotEmpty && list.first is Map) {
        final phonetics = list.first['phonetics'] as List?;
        if (phonetics != null) {
          for (final p in phonetics) {
            if (p is Map && p['text'] is String && (p['text'] as String).isNotEmpty) {
              return (p['text'] as String).replaceAll('/', '');
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// 罗马音转换为平假名 (Hepburn Romaji to Hiragana)
  static String romajiToHiragana(String romaji) {
    var text = romaji.toLowerCase();

    // 常见长音与问候语助词替换
    text = text
        .replaceAll('konnichiwa', 'konnichiha')
        .replaceAll('konbanwa', 'konbanha')
        .replaceAll('ō', 'ou')
        .replaceAll('ū', 'uu')
        .replaceAll('ī', 'ii')
        .replaceAll('ā', 'aa')
        .replaceAll('ē', 'ee');

    final sb = StringBuffer();
    var i = 0;
    while (i < text.length) {
      // 检查双辅音促音 (如 kk, tt, pp, ss)
      if (i + 1 < text.length &&
          text[i] == text[i + 1] &&
          'bcdfghjklmpqrstvwxyz'.contains(text[i]) &&
          text[i] != 'n') {
        sb.write('っ');
        i++;
        continue;
      }

      // 匹配 3 字母映射 (kya, sho, etc.)
      if (i + 3 <= text.length) {
        final sub3 = text.substring(i, i + 3);
        if (_kanaMap.containsKey(sub3)) {
          sb.write(_kanaMap[sub3]);
          i += 3;
          continue;
        }
      }

      // 匹配 2 字母映射 (ka, ki, etc.)
      if (i + 2 <= text.length) {
        final sub2 = text.substring(i, i + 2);
        if (_kanaMap.containsKey(sub2)) {
          sb.write(_kanaMap[sub2]);
          i += 2;
          continue;
        }
      }

      // 匹配 1 字母映射 (a, i, u, e, o, n)
      final sub1 = text.substring(i, i + 1);
      if (_kanaMap.containsKey(sub1)) {
        sb.write(_kanaMap[sub1]);
      } else {
        sb.write(text[i]);
      }
      i++;
    }

    return sb.toString();
  }

  static const Map<String, String> _kanaMap = {
    'kya': 'きゃ', 'kyu': 'きゅ', 'kyo': 'きょ',
    'sha': 'しゃ', 'shu': 'しゅ', 'sho': 'しょ',
    'cha': 'ちゃ', 'chu': 'ちゅ', 'cho': 'ちょ',
    'nya': 'にゃ', 'nyu': 'にゅ', 'nyo': 'にょ',
    'hya': 'ひゃ', 'hyu': 'ひゅ', 'hyo': 'ひょ',
    'mya': 'みゃ', 'myu': 'みゅ', 'myo': 'みょ',
    'rya': 'りゃ', 'ryu': 'りゅ', 'ryo': 'りょ',
    'gya': 'ぎゃ', 'gyu': 'ぎゅ', 'gyo': 'ぎょ',
    'ja': 'じゃ', 'ju': 'じゅ', 'jo': 'じょ',
    'bya': 'びゃ', 'byu': 'びゅ', 'byo': 'びょ',
    'pya': 'ぴゃ', 'pyu': 'ぴゅ', 'pyo': 'ぴょ',
    'ka': 'か', 'ki': 'き', 'ku': 'く', 'ke': 'け', 'ko': 'こ',
    'sa': 'さ', 'shi': 'し', 'su': 'す', 'se': 'せ', 'so': 'そ',
    'ta': 'た', 'chi': 'ち', 'tsu': 'つ', 'te': 'て', 'to': 'と',
    'na': 'な', 'ni': 'に', 'nu': 'ぬ', 'ne': 'ね', 'no': 'の',
    'ha': 'は', 'hi': 'ひ', 'fu': 'ふ', 'he': 'へ', 'ho': 'ほ',
    'ma': 'ま', 'mi': 'み', 'mu': 'む', 'me': 'め', 'mo': 'も',
    'ya': 'や', 'yu': 'ゆ', 'yo': 'よ',
    'ra': 'ら', 'ri': 'り', 'ru': 'る', 're': 'れ', 'ro': 'ろ',
    'wa': 'わ', 'wo': 'を', 'n': 'ん',
    'ga': 'が', 'gi': 'ぎ', 'gu': 'ぐ', 'ge': 'げ', 'go': 'ご',
    'za': 'ざ', 'ji': 'じ', 'zu': 'ず', 'ze': 'ぜ', 'zo': 'ぞ',
    'da': 'だ', 'di': 'ぢ', 'du': 'づ', 'de': 'で', 'do': 'ど',
    'ba': 'ば', 'bi': 'び', 'bu': 'ぶ', 'be': 'べ', 'bo': 'ぼ',
    'pa': 'ぱ', 'pi': 'ぴ', 'pu': 'ぷ', 'pe': 'ぺ', 'po': 'ぽ',
    'a': 'あ', 'i': 'い', 'u': 'う', 'e': 'え', 'o': 'お',
  };

  static const Map<String, String> _commonEnglishIpa = {
    'the': 'ðə', 'be': 'biː', 'to': 'tuː', 'of': 'ɒv', 'and': 'ænd',
    'a': 'ə', 'in': 'ɪn', 'that': 'ðæt', 'have': 'hæv', 'i': 'aɪ',
    'it': 'ɪt', 'for': 'fɔːr', 'not': 'nɒt', 'on': 'ɒn', 'with': 'wɪð',
    'he': 'hiː', 'as': 'æz', 'you': 'juː', 'do': 'duː', 'at': 'æt',
    'this': 'ðɪs', 'but': 'bʌt', 'his': 'hɪz', 'by': 'baɪ', 'from': 'frɒm',
    'they': 'ðeɪ', 'we': 'wiː', 'say': 'seɪ', 'her': 'hɜːr', 'she': 'ʃiː',
    'or': 'ɔːr', 'an': 'æn', 'will': 'wɪl', 'my': 'maɪ', 'one': 'wʌn',
    'all': 'ɔːl', 'would': 'wʊd', 'there': 'ðeər', 'their': 'ðeər', 'what': 'wɒt',
    'so': 'səʊ', 'up': 'ʌp', 'out': 'aʊt', 'if': 'ɪf', 'about': 'əˈbaʊt',
    'who': 'huː', 'get': 'ɡɛt', 'which': 'wɪtʃ', 'go': 'ɡəʊ', 'me': 'miː',
    'when': 'wɛn', 'make': 'meɪk', 'can': 'kæn', 'like': 'laɪk', 'time': 'taɪm',
    'no': 'nəʊ', 'just': 'dʒʌst', 'him': 'hɪm', 'know': 'nəʊ', 'take': 'teɪk',
    'people': 'ˈpiːpəl', 'into': 'ˈɪntuː', 'year': 'jɪər', 'your': 'jɔːr', 'good': 'ɡʊd',
    'some': 'sʌm', 'could': 'kʊd', 'them': 'ðɛm', 'see': 'siː', 'other': 'ˈʌðər',
    'than': 'ðæn', 'then': 'ðɛn', 'now': 'naʊ', 'look': 'lʊk', 'only': 'ˈəʊnli',
    'come': 'kʌm', 'its': 'ɪts', 'over': 'ˈəʊvər', 'think': 'θɪŋk', 'also': 'ˈɔːlsəʊ',
    'back': 'bæk', 'after': 'ˈɑːftər', 'use': 'juːz', 'two': 'tuː', 'how': 'haʊ',
    'our': 'aʊər', 'work': 'wɜːk', 'first': 'fɜːst', 'well': 'wɛl', 'way': 'weɪ',
    'even': 'ˈiːvən', 'new': 'njuː', 'want': 'wɒnt', 'because': 'bɪˈkɒz', 'any': 'ˈɛni',
    'these': 'ðiːz', 'give': 'ɡɪv', 'day': 'deɪ', 'most': 'məʊst', 'us': 'ʌs',
    'hello': 'həˈloʊ', 'world': 'wɜːrld', 'welcome': 'ˈwɛlkəm', 'video': 'ˈvɪdioʊ',
    'play': 'pleɪ', 'player': 'ˈpleɪər', 'music': 'ˈmjuːzɪk', 'love': 'lʌv',
    'thank': 'θæŋk', 'thanks': 'θæŋks', 'please': 'pliːz', 'yes': 'jɛs',
  };
}
