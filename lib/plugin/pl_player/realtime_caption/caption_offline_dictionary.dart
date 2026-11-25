import 'caption_dictionary.dart';
import 'caption_pronunciation.dart';
import 'caption_offline_phonetics.dart';
import 'cantonese_lexicon.dart';

/// 本地离线词典库（内置离线高频粤语词条与常用英文词汇）
/// 保证无网络或弱网环境下 0ms 秒出注音、释义与例句
class CaptionOfflineDictionary {
  static final CaptionOfflineDictionary shared = CaptionOfflineDictionary._();
  CaptionOfflineDictionary._();

  /// 判断词条是否为粤语词条（包含高频粤语词表与粤语特征字符）
  static bool isCantoneseWord(String rawQuery) {
    final query = CaptionDictionary.cleanWord(rawQuery);
    if (query.isEmpty) return false;
    if (_cantoneseDict.containsKey(query)) return true;
    if (CaptionPronunciation.isCantoneseText(query)) return true;
    return false;
  }

  /// 精确判断词条是否在离线粤语词典中存在
  static bool hasExactCantoneseEntry(String rawQuery) {
    final query = CaptionDictionary.cleanWord(rawQuery);
    return _cantoneseDict.containsKey(query);
  }

  /// 尝试在本地离线词典库中查询
  WordLookupResult? lookup(
    String rawQuery, {
    String? contextSentence,
    String? contextTranslation,
    bool? isCantonese,
  }) {
    final query = CaptionDictionary.cleanWord(rawQuery);
    if (query.isEmpty) return null;

    final lower = query.toLowerCase();

    // 1. 优先查离线粤语词库（全匹配）
    if (_cantoneseDict.containsKey(query)) {
      final entry = _cantoneseDict[query]!;
      final readings = CantoneseLexicon.shared.readings(query);
      return WordLookupResult(
        query: query,
        phonetic: readings.isNotEmpty ? readings.first : entry.jyutping,
        audioUrl:
            'https://google.qianche.dpdns.org/translate_tts?ie=UTF-8&client=tw-ob&tl=zh-HK&q=${Uri.encodeComponent(query)}',
        definitions: [
          WordDefinition(partOfSpeech: '粤语', meanings: [entry.definition]),
        ],
        examples: entry.example != null && entry.exampleTranslation != null
            ? [
                WordExample(
                  sentence: entry.example!,
                  translation: entry.exampleTranslation!,
                )
              ]
            : const [],
        contextSentence: contextSentence,
        contextTranslation: contextTranslation,
        sourceLanguage: 'yue',
        rawTranslation: entry.definition,
      );
    }

    // 2. 查离线常用英语词库
    if (_englishDict.containsKey(lower)) {
      final entry = _englishDict[lower]!;
      return WordLookupResult(
        query: query,
        phonetic: entry.usPhonetic,
        ukPhonetic: entry.ukPhonetic,
        usPhonetic: entry.usPhonetic,
        ukAudioUrl:
            'https://dict.youdao.com/dictvoice?audio=${Uri.encodeComponent(query)}&type=1',
        usAudioUrl:
            'https://dict.youdao.com/dictvoice?audio=${Uri.encodeComponent(query)}&type=2',
        audioUrl:
            'https://dict.youdao.com/dictvoice?audio=${Uri.encodeComponent(query)}&type=2',
        definitions: entry.definitions,
        examples: entry.examples,
        contextSentence: contextSentence,
        contextTranslation: contextTranslation,
        sourceLanguage: 'en',
        rawTranslation: entry.definitions.isNotEmpty &&
                entry.definitions.first.meanings.isNotEmpty
            ? entry.definitions.first.meanings.first
            : null,
      );
    }

    // 3. 粤语环境下，若未直接匹配多字词条，使用本地内置离线粤拼字典逐字解析生成纯正粤拼
    if (isCantonese == true ||
        (contextSentence != null &&
            CaptionPronunciation.isCantoneseText(contextSentence)) ||
        CaptionPronunciation.isCantoneseText(query)) {
      final chars = query.runes.map(String.fromCharCode).toList();
      final readings = CaptionOfflinePhonetics.alignedChineseReadings(query, cantonese: true);
      final jyutpingList = <String>[];
      var allFound = true;
      var index = 0;
      for (final c in chars) {
        if (readings.containsKey(index)) {
          jyutpingList.add(readings[index]!);
        } else if (_cantoneseCharJyutping.containsKey(c)) {
          jyutpingList.add(_cantoneseCharJyutping[c]!);
        } else if (_cantoneseDict.containsKey(c)) {
          jyutpingList.add(_cantoneseDict[c]!.jyutping);
        } else {
          allFound = false;
          break;
        }
        index += c.length;
      }
      final variants = CantoneseLexicon.shared.readings(query);
      if (variants.isNotEmpty || (allFound && jyutpingList.isNotEmpty)) {
        final jyutping = variants.isNotEmpty ? variants.join(' / ') : jyutpingList.join(' ');
        return WordLookupResult(
          query: query,
          phonetic: jyutping,
          audioUrl:
              'https://google.qianche.dpdns.org/translate_tts?ie=UTF-8&client=tw-ob&tl=zh-HK&q=${Uri.encodeComponent(query)}',
          definitions: [
            WordDefinition(partOfSpeech: '粤语', meanings: ['粤语发音词条（粤拼: $jyutping）']),
          ],
          contextSentence: contextSentence,
          contextTranslation: contextTranslation,
          sourceLanguage: 'yue',
          rawTranslation: '粤语词条',
        );
      }
    }

    return null;
  }

  /// 本地高频粤语字注音表（支持多字离线组合拆解，0ms 极速响应）
  static final Map<String, String> _cantoneseCharJyutping = {
    '我': 'ngo5', '你': 'nei5', '佢': 'keoi5', '哋': 'dei6', '地': 'dei6',
    '唔': 'm4', '係': 'hai6', '系': 'hai6', '咁': 'gam2', '樣': 'joeng2',
    '样': 'joeng2', '點': 'dim2', '点': 'dim2', '解': 'gaai2', '乜': 'mat1',
    '嘢': 'je5', '野': 'je5', '呢': 'ni1', '嗰': 'go2', '度': 'dou6',
    '睇': 'tai2', '諗': 'nam2', '搵': 'wan2', '㗎': 'gaa3', '啫': 'ze1',
    '嘞': 'laak3', '咪': 'mai6', '瞓': 'fan3', '返': 'faan1', '落': 'lok6',
    '講': 'gong2', '讲': 'gong2', '食': 'sik6', '飯': 'faan6', '饭': 'faan6',
    '飲': 'jam2', '饮': 'jam2', '茶': 'caa4', '玩': 'waan2', '靚': 'leng3',
    '靓': 'leng3', '咧': 'le1', '啱': 'ngaam1', '攰': 'gui6', '畀': 'bei2',
    '俾': 'bei2', '揸': 'zaa1', '攞': 'lo2', '冇': 'mou5', '邊': 'bin1',
    '边': 'bin1', '個': 'go3', '个': 'go3', '車': 'ce1', '车': 'ce1',
    '到': 'dou3', '屋': 'uk1', '企': 'kei2', '好': 'hou2', '彩': 'coi2',
    '拍': 'paak3', '拖': 'to1', '埋': 'maai4', '單': 'daan1', '单': 'daan1',
    '執': 'zap1', '执': 'zap1', '笠': 'lap1', '搞': 'gaau2', '掂': 'dim6',
    '該': 'goi1', '该': 'goi1', '多': 'do1', '謝': 'ze6', '谢': 'ze6',
    '走': 'zau2', '先': 'sin1', '行': 'haang4', '街': 'gaai1', '傾': 'king1',
    '倾': 'king1', '偈': 'gai2', '工': 'gung1', '收': 'sau1', '放': 'fong3',
    '早': 'zou2', '晨': 'san4', '抖': 'tau2', '問': 'man6', '问': 'man6',
    '題': 'tai4', '题': 'tai4', '正': 'zeng3', '大': 'daai6', '鑊': 'wok6',
    '镬': 'wok6', '得': 'dak1', '閒': 'haan4', '闲': 'haan4', '緊': 'gan2',
    '紧': 'gan2', '要': 'jiu3', '耐': 'noi6', '仔': 'zai2', '女': 'neoi2',
    '真': 'zan1', '但': 'daan6', '算': 'syun3', '幾': 'gei2', '几': 'gei2',
    '時': 'si4', '时': 'si4', '戲': 'hei3', '戏': 'hei3', '聽': 'ting1',
    '听': 'ting1', '琴': 'kam4', '尋': 'cam4', '日': 'jat6', '年': 'nin4',
    '月': 'jyut6', '人': 'jan4', '一': 'jat1', '二': 'ji6', '三': 'saam1',
    '四': 'sei3', '五': 'ng5', '六': 'luk6', '七': 'cat1', '八': 'baat3',
    '九': 'gau2', '十': 'sap6', '百': 'baak3', '千': 'cin1', '萬': 'maan6',
    '万': 'maan6', '有': 'jau5', '會': 'wui5', '会': 'wui5', '想': 'soeng2',
    '去': 'heoi3', '嚟': 'lei4', '来': 'loi4', '叫': 'giu3', '买': 'maai5',
    '買': 'maai5', '卖': 'maai6', '賣': 'maai6', '钱': 'cin2', '錢': 'cin2',
    '快': 'faai3', '慢': 'maan6', '高': 'gou1', '低': 'dai1', '新': 'san1',
    '旧': 'gau6', '舊': 'gau6', '明': 'ming4', '知': 'zi1', '识': 'sik1',
    '識': 'sik1', '帮': 'bong1', '幫': 'bong1', '手': 'sau2', '信': 'seon3',
    '情': 'cing4', '事': 'si6', '话': 'waa6', '話': 'waa6', '同': 'tung4',
  };

  /// 本地高频粤语词条数据库
  static final Map<String, _CantoneseEntry> _cantoneseDict = {
    '車到': _CantoneseEntry(
      jyutping: 'ce1 dou3',
      definition: '车辆到达；乘车抵达。',
      example: '車到喇，快啲落樓搭車。',
      exampleTranslation: '车到了，快点下楼坐车。',
    ),
    '车到': _CantoneseEntry(
      jyutping: 'ce1 dou3',
      definition: '车辆到达；乘车抵达。',
      example: '车到喇，快啲落楼搭车。',
      exampleTranslation: '车到了，快点下楼坐车。',
    ),
    '咁樣': _CantoneseEntry(
      jyutping: 'gam2 joeng2',
      definition: '这样，如此。',
      example: '唔好咁樣啦，大家都係朋友。',
      exampleTranslation: '不要这样啦，大家都是朋友。',
    ),
    '咁样': _CantoneseEntry(
      jyutping: 'gam2 joeng2',
      definition: '这样，如此。',
      example: '点解会搞成咁样？',
      exampleTranslation: '为什么会搞成这样？',
    ),
    '唔係': _CantoneseEntry(
      jyutping: 'm4 hai6',
      definition: '不是；不对。',
      example: '呢個唔係我嘅手袋。',
      exampleTranslation: '这个不是我的手提包。',
    ),
    '唔系': _CantoneseEntry(
      jyutping: 'm4 hai6',
      definition: '不是；不对。',
      example: '真系唔系我做㗎。',
      exampleTranslation: '真的不是我做的。',
    ),
    '但系': _CantoneseEntry(
      jyutping: 'daan6 hai6',
      definition: '但是，不过。',
      example: '好想去，但系今日冇时间。',
      exampleTranslation: '很想去，但是今天没有时间。',
    ),
    '但係': _CantoneseEntry(
      jyutping: 'daan6 hai6',
      definition: '但是，不过。',
      example: '但係我真系唔知喎。',
      exampleTranslation: '但是我是真的不知道呀。',
    ),
    '真系': _CantoneseEntry(
      jyutping: 'zan1 hai6',
      definition: '真的是，确实是。',
      example: '天气真系好热。',
      exampleTranslation: '天气真的是好热。',
    ),
    '真係': _CantoneseEntry(
      jyutping: 'zan1 hai6',
      definition: '真的是，确实是。',
      example: '呢齣戏真係好好睇。',
      exampleTranslation: '这部戏真的是很好看。',
    ),
    '点解': _CantoneseEntry(
      jyutping: 'dim2 gaai2',
      definition: '为什么。',
      example: '点解你今日咁迟先到？',
      exampleTranslation: '为什么你今天这么晚才到？',
    ),
    '點解': _CantoneseEntry(
      jyutping: 'dim2 gaai2',
      definition: '为什么。',
      example: '點解會咁嘅？',
      exampleTranslation: '为什么会这样的？',
    ),
    '点样': _CantoneseEntry(
      jyutping: 'dim2 joeng2',
      definition: '怎样，如何。',
      example: '呢个字点样读啊？',
      exampleTranslation: '这个字怎么读啊？',
    ),
    '點樣': _CantoneseEntry(
      jyutping: 'dim2 joeng2',
      definition: '怎样，如何。',
      example: '點樣先可以去到？',
      exampleTranslation: '怎样才可以到达？',
    ),
    '点算': _CantoneseEntry(
      jyutping: 'dim2 syun3',
      definition: '怎么办。',
      example: '唔见咗锁匙，而家点算？',
      exampleTranslation: '钥匙不见了，现在怎么办？',
    ),
    '點算': _CantoneseEntry(
      jyutping: 'dim2 syun3',
      definition: '怎么办。',
      example: '唔見咗匙羹，點算？',
      exampleTranslation: '勺子不见了，怎么办？',
    ),
    '幾時': _CantoneseEntry(
      jyutping: 'gei2 si4',
      definition: '什么时候。',
      example: '你幾時返香港啊？',
      exampleTranslation: '你什么时候回香港啊？',
    ),
    '几时': _CantoneseEntry(
      jyutping: 'gei2 si4',
      definition: '什么时候。',
      example: '几时得闲一齐食饭？',
      exampleTranslation: '什么时候有空一起吃饭？',
    ),
    '食饭': _CantoneseEntry(
      jyutping: 'sik6 faan6',
      definition: '吃饭，用餐。',
      example: '够钟去食饭喇！',
      exampleTranslation: '到时间去吃饭啦！',
    ),
    '食飯': _CantoneseEntry(
      jyutping: 'sik6 faan6',
      definition: '吃饭，用餐。',
      example: '今日一齊食飯啦。',
      exampleTranslation: '今天一起吃饭吧。',
    ),
    '饮茶': _CantoneseEntry(
      jyutping: 'jam2 caa4',
      definition: '喝茶，去茶楼吃点心。',
      example: '礼拜日去茶楼饮茶。',
      exampleTranslation: '周日去茶楼喝茶吃点心。',
    ),
    '飲茶': _CantoneseEntry(
      jyutping: 'jam2 caa4',
      definition: '喝茶，去茶楼吃点心。',
      example: '禮拜日去飲茶。',
      exampleTranslation: '周日去喝茶吃点心。',
    ),
    '睇戏': _CantoneseEntry(
      jyutping: 'tai2 hei3',
      definition: '看电影，看戏。',
      example: '今晚去戏院睇戏好唔好？',
      exampleTranslation: '今晚去电影院看电影好不好？',
    ),
    '睇戲': _CantoneseEntry(
      jyutping: 'tai2 hei3',
      definition: '看电影，看戏。',
      example: '今晚一齊睇戲啦。',
      exampleTranslation: '今晚一起看电影吧。',
    ),
    '屋企': _CantoneseEntry(
      jyutping: 'uk1 kei2',
      definition: '家，家里。',
      example: '我今晚喺屋企煮饭食。',
      exampleTranslation: '我今晚在家里煮饭吃。',
    ),
    '好彩': _CantoneseEntry(
      jyutping: 'hou2 coi2',
      definition: '幸好，幸运。',
      example: '好彩赶得切最后一班地铁。',
      exampleTranslation: '幸好赶得及最后一班地铁。',
    ),
    '拍拖': _CantoneseEntry(
      jyutping: 'paak3 to1',
      definition: '谈恋爱。',
      example: '佢两个拍咗好多年拖喇。',
      exampleTranslation: '他们两个人谈恋爱很多年了。',
    ),
    '埋单': _CantoneseEntry(
      jyutping: 'maai4 daan1',
      definition: '买单，结账。',
      example: '服务员，唔该埋单！',
      exampleTranslation: '服务员，麻烦买单！',
    ),
    '埋單': _CantoneseEntry(
      jyutping: 'maai4 daan1',
      definition: '买单，结账。',
      example: '唔該埋單！',
      exampleTranslation: '麻烦结账买单！',
    ),
    '执笠': _CantoneseEntry(
      jyutping: 'zap1 lap1',
      definition: '倒闭，关门停业。',
      example: '间餐厅上个月执咗笠。',
      exampleTranslation: '那间餐厅上个月倒闭了。',
    ),
    '執笠': _CantoneseEntry(
      jyutping: 'zap1 lap1',
      definition: '倒闭，关门停业。',
      example: '間鋪頭執咗笠。',
      exampleTranslation: '那家店倒闭了。',
    ),
    '搞掂': _CantoneseEntry(
      jyutping: 'gaau2 dim6',
      definition: '办妥，搞定。',
      example: '放心啦，全部帮您搞掂晒！',
      exampleTranslation: '放心吧，全部帮您搞定了！',
    ),
    '唔该': _CantoneseEntry(
      jyutping: 'm4 goi1',
      definition: '谢谢（劳驾/提供帮助）；劳驾，麻烦你。',
      example: '唔该借借，借过一下。',
      exampleTranslation: '劳驾借过一下。',
    ),
    '唔該': _CantoneseEntry(
      jyutping: 'm4 goi1',
      definition: '谢谢（劳驾/提供帮助）；劳驾，麻烦你。',
      example: '唔該幫我攞個杯。',
      exampleTranslation: '劳驾帮我拿个杯子。',
    ),
    '多谢': _CantoneseEntry(
      jyutping: 'do1 ze6',
      definition: '多谢，感谢（收受礼物或心意）。',
      example: '多谢你嘅礼物！',
      exampleTranslation: '多谢你的礼物！',
    ),
    '多謝': _CantoneseEntry(
      jyutping: 'do1 ze6',
      definition: '多谢，感谢（收受礼物或心意）。',
      example: '多謝大家嘅支持！',
      exampleTranslation: '多谢大家的支持！',
    ),
    '走先': _CantoneseEntry(
      jyutping: 'zau2 sin1',
      definition: '先走了，告辞。',
      example: '大家慢慢倾，我走先喇。',
      exampleTranslation: '大家慢慢聊，我先走了。',
    ),
    '行街': _CantoneseEntry(
      jyutping: 'haang4 gaai1',
      definition: '逛街。',
      example: '放假同朋友去铜锣湾行街。',
      exampleTranslation: '放假和朋友去铜锣湾逛街。',
    ),
    '倾偈': _CantoneseEntry(
      jyutping: 'king1 gai2',
      definition: '聊天，谈话。',
      example: '得闲出嚟饮杯嘢倾偈。',
      exampleTranslation: '有空出来喝杯东西聊天。',
    ),
    '傾偈': _CantoneseEntry(
      jyutping: 'king1 gai2',
      definition: '聊天，谈话。',
      example: '我哋好耐冇傾偈喇。',
      exampleTranslation: '我们很久没聊天了。',
    ),
    '返工': _CantoneseEntry(
      jyutping: 'faan1 gung1',
      definition: '上班。',
      example: '听朝八点钟要返工。',
      exampleTranslation: '明早八点钟要上班。',
    ),
    '放工': _CantoneseEntry(
      jyutping: 'fong3 gung1',
      definition: '下班。',
      example: '放工一齐去打边炉啦。',
      exampleTranslation: '下班一起去吃火锅吧。',
    ),
    '收工': _CantoneseEntry(
      jyutping: 'sau1 gung1',
      definition: '收工，结束工作。',
      example: '搞掂手头嘅嘢就可以收工。',
      exampleTranslation: '搞定手头上的事情就可以收工了。',
    ),
    '瞓觉': _CantoneseEntry(
      jyutping: 'fan3 gaau3',
      definition: '睡觉。',
      example: '好攰喇，想早啲瞓觉。',
      exampleTranslation: '好累了，想早点睡觉。',
    ),
    '瞓覺': _CantoneseEntry(
      jyutping: 'fan3 gaau3',
      definition: '睡觉。',
      example: '快啲去瞓覺啦。',
      exampleTranslation: '快点去睡觉吧。',
    ),
    '早晨': _CantoneseEntry(
      jyutping: 'zou2 san4',
      definition: '早上好。',
      example: '陈先生，早晨啊！',
      exampleTranslation: '陈先生，早上好啊！',
    ),
    '早抖': _CantoneseEntry(
      jyutping: 'zou2 tau2',
      definition: '晚安。',
      example: '好夜喇，大家早抖啦。',
      exampleTranslation: '很晚了，大家晚安啦。',
    ),
    '乜嘢': _CantoneseEntry(
      jyutping: 'mat1 je5',
      definition: '什么东西，什么。',
      example: '你想买乜嘢啊？',
      exampleTranslation: '你想买什么啊？',
    ),
    '乜野': _CantoneseEntry(
      jyutping: 'mat1 je5',
      definition: '什么东西，什么。',
      example: '有乜野可以帮到你？',
      exampleTranslation: '有什么可以帮到你？',
    ),
    '边个': _CantoneseEntry(
      jyutping: 'bin1 go3',
      definition: '谁；哪一个。',
      example: '你知唔知嗰个系边个？',
      exampleTranslation: '你知不知道那个是谁？',
    ),
    '邊個': _CantoneseEntry(
      jyutping: 'bin1 go3',
      definition: '谁；哪一个。',
      example: '邊個打電話嚟？',
      exampleTranslation: '谁打电话来？',
    ),
    '边度': _CantoneseEntry(
      jyutping: 'bin1 dou6',
      definition: '哪里。',
      example: '请问洗手间喺边度？',
      exampleTranslation: '请问洗手间在哪里？',
    ),
    '邊度': _CantoneseEntry(
      jyutping: 'bin1 dou6',
      definition: '哪里。',
      example: '去邊度玩好呢？',
      exampleTranslation: '去哪里玩好呢？',
    ),
    '呢度': _CantoneseEntry(
      jyutping: 'ni1 dou6',
      definition: '这里。',
      example: '你喺呢度坐阵等我。',
      exampleTranslation: '你在这里坐一会儿等我。',
    ),
    '嗰度': _CantoneseEntry(
      jyutping: 'go2 dou6',
      definition: '那里。',
      example: '嗰度好多人排队。',
      exampleTranslation: '那里很多人在排队。',
    ),
    '啱啱': _CantoneseEntry(
      jyutping: 'ngaam1 ngaam1',
      definition: '刚刚，刚才。',
      example: '我啱啱先到咋。',
      exampleTranslation: '我刚刚才到达呢。',
    ),
    '冇问题': _CantoneseEntry(
      jyutping: 'mou5 man6 tai4',
      definition: '没问题。',
      example: '交畀我，冇问题！',
      exampleTranslation: '交给我，没问题！',
    ),
    '冇問題': _CantoneseEntry(
      jyutping: 'mou5 man6 tai4',
      definition: '没问题。',
      example: '件事包喺我身上，冇問題！',
      exampleTranslation: '事情包在我身上，没问题！',
    ),
    '好靓': _CantoneseEntry(
      jyutping: 'hou2 leng3',
      definition: '很漂亮，很美。',
      example: '今日天气好靓，好舒服。',
      exampleTranslation: '今天天气很好，很舒服。',
    ),
    '好靚': _CantoneseEntry(
      jyutping: 'hou2 leng3',
      definition: '很漂亮，很美。',
      example: '呢件衫好靚啊。',
      exampleTranslation: '这件衣服好漂亮啊。',
    ),
    '正嘢': _CantoneseEntry(
      jyutping: 'zeng3 je5',
      definition: '好东西，极品。',
      example: '呢件古董真系正嘢！',
      exampleTranslation: '这件古董真的是好东西！',
    ),
    '正野': _CantoneseEntry(
      jyutping: 'zeng3 je5',
      definition: '好东西，极品。',
      example: '真系正野嚟㗎。',
      exampleTranslation: '真的是好东西来的。',
    ),
    '大镬': _CantoneseEntry(
      jyutping: 'daai6 wok6',
      definition: '严重，大事不妙，糟糕。',
      example: '大镬！唔记得带通行证。',
      exampleTranslation: '糟糕！忘记带通行证了。',
    ),
    '大鑊': _CantoneseEntry(
      jyutping: 'daai6 wok6',
      definition: '严重，大事不妙，糟糕。',
      example: '今次大鑊喇！',
      exampleTranslation: '这次大事不妙了！',
    ),
    '得闲': _CantoneseEntry(
      jyutping: 'dak1 haan4',
      definition: '有空，闲暇。',
      example: '得闲上嚟坐啦。',
      exampleTranslation: '有空上来坐坐吧。',
    ),
    '得閒': _CantoneseEntry(
      jyutping: 'dak1 haan4',
      definition: '有空，闲暇。',
      example: '得閒打電話畀我。',
      exampleTranslation: '有空打电话给我。',
    ),
    '唔紧要': _CantoneseEntry(
      jyutping: 'm4 gan2 jiu3',
      definition: '没关系，不要紧。',
      example: '唔紧要，下次再试过。',
      exampleTranslation: '没关系，下次再试试。',
    ),
    '唔緊要': _CantoneseEntry(
      jyutping: 'm4 gan2 jiu3',
      definition: '没关系，不要紧。',
      example: '唔緊要，慢慢嚟。',
      exampleTranslation: '没关系，慢慢来。',
    ),
    '好耐': _CantoneseEntry(
      jyutping: 'hou2 noi6',
      definition: '很久。',
      example: '好耐冇见啦，最近点啊？',
      exampleTranslation: '很久没见啦，最近怎么样？',
    ),
    '攰': _CantoneseEntry(
      jyutping: 'gui6',
      definition: '累，疲倦。',
      example: '行咗成日，好攰啊。',
      exampleTranslation: '走了一整天，好累啊。',
    ),
    '靓仔': _CantoneseEntry(
      jyutping: 'leng3 zai2',
      definition: '帅哥；年轻人；（茶餐厅指白米饭）。',
      example: '靓仔，今日想食啲乜？',
      exampleTranslation: '帅哥，今天想吃点什么？',
    ),
    '靚仔': _CantoneseEntry(
      jyutping: 'leng3 zai2',
      definition: '帅哥；年轻人；（茶餐厅指白米饭）。',
      example: '靚仔，唔該嗌嘢食。',
      exampleTranslation: '帅哥，劳驾点餐。',
    ),
    '靓女': _CantoneseEntry(
      jyutping: 'leng3 neoi2',
      definition: '美女；年轻女子。',
      example: '靓女，请问呢度点去地铁站？',
      exampleTranslation: '美女，请问这里怎么去地铁站？',
    ),
    '靚女': _CantoneseEntry(
      jyutping: 'leng3 neoi2',
      definition: '美女；年轻女子。',
      example: '嗰位靚女好有氣質。',
      exampleTranslation: '那位美女很有气质。',
    ),
    '佢': const _CantoneseEntry(
      jyutping: 'keoi5', definition: '他、她、它；粤语第三人称代词，不区分性别。',
      example: '佢喺屋企。', exampleTranslation: '他／她在家。',
    ),
    '嘅': const _CantoneseEntry(
      jyutping: 'ge3', definition: '表示所属或修饰关系，相当于“的”；也可作句末语气词，读音随用法变化。',
      example: '呢個係我嘅。', exampleTranslation: '这个是我的。',
    ),
    '咗': const _CantoneseEntry(
      jyutping: 'zo2', definition: '表示动作完成或状态发生变化，常相当于“了”；并非所有过去的事情都要加“咗”。',
      example: '佢食咗飯。', exampleTranslation: '他／她吃了饭。',
    ),
    '喺': const _CantoneseEntry(
      jyutping: 'hai2', definition: '在、位于，表示时间或地点；与表示“是”的“係 hai6”不同。',
      example: '我喺呢度。', exampleTranslation: '我在这里。',
    ),
    '嚟': const _CantoneseEntry(
      jyutping: 'lei4', definition: '来；常用口语字，有 lai4、lei4 两种读法，也用于“返嚟”等趋向表达。',
      example: '佢返嚟喇。', exampleTranslation: '他／她回来了。',
    ),
    '嗰': const _CantoneseEntry(
      jyutping: 'go2', definition: '那，指示较远或前面提到的人、事物，常用于“嗰個、嗰度”。',
      example: '嗰個係佢。', exampleTranslation: '那个人是他／她。',
    ),
    '嘢': const _CantoneseEntry(
      jyutping: 'je5', definition: '东西、事情；常用于“乜嘢（什么）、食嘢（吃东西）”。',
      example: '你食咩嘢？', exampleTranslation: '你吃什么东西？',
    ),
    '唔': _CantoneseEntry(
      jyutping: 'm4',
      definition: '不，不是，没有。',
      example: '唔好（不要），唔系（不是）。',
      exampleTranslation: '不要，不是。',
    ),
    '係': _CantoneseEntry(
      jyutping: 'hai6',
      definition: '是。',
      example: '佢係我朋友。',
      exampleTranslation: '他是我的朋友。',
    ),
    '系': _CantoneseEntry(
      jyutping: 'hai6',
      definition: '是。',
      example: '我系學生。',
      exampleTranslation: '我是学生。',
    ),
    '咁': _CantoneseEntry(
      jyutping: 'gam2',
      definition: '这么，这样，如此。',
      example: '咁好嘅？',
      exampleTranslation: '这么好呀？',
    ),
    '睇': _CantoneseEntry(
      jyutping: 'tai2',
      definition: '看，瞧。',
      example: '睇下啦。',
      exampleTranslation: '看一下吧。',
    ),
    '冇': _CantoneseEntry(
      jyutping: 'mou5',
      definition: '没有，无。',
      example: '冇事冇事。',
      exampleTranslation: '没事没事。',
    ),
    '车': _CantoneseEntry(
      jyutping: 'ce1',
      definition: '车，汽车。',
      example: '搭车。',
      exampleTranslation: '坐车。',
    ),
    '車': _CantoneseEntry(
      jyutping: 'ce1',
      definition: '车，汽车。',
      example: '搭車。',
      exampleTranslation: '坐车。',
    ),
    '到': _CantoneseEntry(
      jyutping: 'dou3',
      definition: '到，到达。',
      example: '到咗未啊？',
      exampleTranslation: '到了没有啊？',
    ),
  };

  /// 本地高频常用英文词汇库（离线瞬间秒出）
  static final Map<String, _EnglishEntry> _englishDict = {
    'hello': _EnglishEntry(
      ukPhonetic: 'həˈləʊ',
      usPhonetic: 'həˈloʊ',
      definitions: [
        WordDefinition(partOfSpeech: 'int.', meanings: ['喂，你好（用于问候或引起注意）']),
        WordDefinition(partOfSpeech: 'n.', meanings: ['问候，打招呼']),
      ],
      examples: [
        WordExample(sentence: 'Hello, how are you today?', translation: '你好，今天怎么样？'),
      ],
    ),
    'world': _EnglishEntry(
      ukPhonetic: 'wɜːld',
      usPhonetic: 'wɜːrld',
      definitions: [
        WordDefinition(partOfSpeech: 'n.', meanings: ['世界，地球；天下，世人']),
      ],
      examples: [
        WordExample(sentence: 'Welcome to our beautiful world.', translation: '欢迎来到我们美丽的世界。'),
      ],
    ),
    'apple': _EnglishEntry(
      ukPhonetic: 'ˈæpl',
      usPhonetic: 'ˈæpl',
      definitions: [
        WordDefinition(partOfSpeech: 'n.', meanings: ['苹果；苹果树']),
      ],
      examples: [
        WordExample(sentence: 'An apple a day keeps the doctor away.', translation: '一天一苹果，医生远离我。'),
      ],
    ),
    'video': _EnglishEntry(
      ukPhonetic: 'ˈvɪdiəʊ',
      usPhonetic: 'ˈvɪdioʊ',
      definitions: [
        WordDefinition(partOfSpeech: 'n.', meanings: ['视频，录像']),
        WordDefinition(partOfSpeech: 'v.', meanings: ['录制视频']),
      ],
      examples: [
        WordExample(sentence: 'I watched an interesting video online.', translation: '我在网上看了一个有趣的视频。'),
      ],
    ),
    'player': _EnglishEntry(
      ukPhonetic: 'ˈpleɪə(r)',
      usPhonetic: 'ˈpleɪər',
      definitions: [
        WordDefinition(partOfSpeech: 'n.', meanings: ['播放器；选手，玩家，演员']),
      ],
      examples: [
        WordExample(sentence: 'He is the best player on our team.', translation: '他是我们队里最出色的选手。'),
      ],
    ),
    'music': _EnglishEntry(
      ukPhonetic: 'ˈmjuːzɪk',
      usPhonetic: 'ˈmjuːzɪk',
      definitions: [
        WordDefinition(partOfSpeech: 'n.', meanings: ['音乐，乐曲']),
      ],
      examples: [
        WordExample(sentence: 'Listening to music helps me relax.', translation: '听音乐能帮助我放松。'),
      ],
    ),
    'time': _EnglishEntry(
      ukPhonetic: 'taɪm',
      usPhonetic: 'taɪm',
      definitions: [
        WordDefinition(partOfSpeech: 'n.', meanings: ['时间；时刻；次，回']),
        WordDefinition(partOfSpeech: 'v.', meanings: ['为…计时']),
      ],
      examples: [
        WordExample(sentence: 'Time flies when you are having fun.', translation: '快乐时时光飞逝。'),
      ],
    ),
    'good': _EnglishEntry(
      ukPhonetic: 'ɡʊd',
      usPhonetic: 'ɡʊd',
      definitions: [
        WordDefinition(partOfSpeech: 'adj.', meanings: ['好的，优秀的；善良的']),
      ],
      examples: [
        WordExample(sentence: 'Have a good day!', translation: '祝你有美好的一天！'),
      ],
    ),
    'morning': _EnglishEntry(
      ukPhonetic: 'ˈmɔːnɪŋ',
      usPhonetic: 'ˈmɔːrnɪŋ',
      definitions: [
        WordDefinition(partOfSpeech: 'n.', meanings: ['早晨，上午']),
      ],
      examples: [
        WordExample(sentence: 'Good morning, everyone!', translation: '大家早上好！'),
      ],
    ),
    'night': _EnglishEntry(
      ukPhonetic: 'naɪt',
      usPhonetic: 'naɪt',
      definitions: [
        WordDefinition(partOfSpeech: 'n.', meanings: ['夜间，夜晚，晚上']),
      ],
      examples: [
        WordExample(sentence: 'Good night and sweet dreams.', translation: '晚安，做个好梦。'),
      ],
    ),
    'thank': _EnglishEntry(
      ukPhonetic: 'θæŋk',
      usPhonetic: 'θæŋk',
      definitions: [
        WordDefinition(partOfSpeech: 'v.', meanings: ['感谢，致谢']),
      ],
      examples: [
        WordExample(sentence: 'Thank you very much for your help.', translation: '非常感谢你的帮助。'),
      ],
    ),
    'thanks': _EnglishEntry(
      ukPhonetic: 'θæŋks',
      usPhonetic: 'θæŋks',
      definitions: [
        WordDefinition(partOfSpeech: 'int.', meanings: ['谢谢']),
        WordDefinition(partOfSpeech: 'n.', meanings: ['感谢，谢意']),
      ],
      examples: [
        WordExample(sentence: 'Thanks a lot!', translation: '多谢！'),
      ],
    ),
    'subtitle': _EnglishEntry(
      ukPhonetic: 'ˈsʌbtaɪtl',
      usPhonetic: 'ˈsʌbtaɪtl',
      definitions: [
        WordDefinition(partOfSpeech: 'n.', meanings: ['字幕；副标题']),
        WordDefinition(partOfSpeech: 'v.', meanings: ['给…加字幕']),
      ],
      examples: [
        WordExample(sentence: 'Turn on English subtitles.', translation: '打开英文字幕。'),
      ],
    ),
    'caption': _EnglishEntry(
      ukPhonetic: 'ˈkæpʃn',
      usPhonetic: 'ˈkæpʃn',
      definitions: [
        WordDefinition(partOfSpeech: 'n.', meanings: ['字幕；说明文字；标题']),
      ],
      examples: [
        WordExample(sentence: 'Real-time captions are very helpful.', translation: '实时字幕非常有帮助。'),
      ],
    ),
  };
}

class _CantoneseEntry {
  const _CantoneseEntry({
    required this.jyutping,
    required this.definition,
    this.example,
    this.exampleTranslation,
  });

  final String jyutping;
  final String definition;
  final String? example;
  final String? exampleTranslation;
}

class _EnglishEntry {
  const _EnglishEntry({
    required this.ukPhonetic,
    required this.usPhonetic,
    required this.definitions,
    required this.examples,
  });

  final String ukPhonetic;
  final String usPhonetic;
  final List<WordDefinition> definitions;
  final List<WordExample> examples;
}
