/// ASR 文本排版与格式化工具
/// 解决多语言 ASR 模型 (如 SenseVoice, Zipformer, Whisper 等) 输出时：
/// 1. 英语单词之间缺失空格 (如 "becauseonceyou'rethere" -> "because once you're there")
/// 2. 中英文混排标点与空格规范化 (如 "买个iPhone好用" -> "买个 iPhone 好用")
/// 3. SentencePiece 词元 (U+2581) 与连续 Latin Token 拼接规范化
/// 4. Zipformer 等全大写模型英语单词转小写 (如 "HELLO WORLD" -> "hello world")
class CaptionTextFormatter {
  const CaptionTextFormatter._();

  /// 常见英文连词、代词、系动词、介词、助动词及常用高频词典（用于无空格粘连长词拆分）
  static const Set<String> _commonEnglishWords = {
    'a', 'about', 'above', 'across', 'after', 'again', 'against', 'all', 'almost',
    'alone', 'along', 'already', 'also', 'although', 'always', 'among', 'an', 'and',
    'another', 'any', 'anybody', 'anyone', 'anything', 'anyway', 'are', 'aren',
    'around', 'as', 'ask', 'at', 'away', 'back', 'bad', 'be', 'because', 'become',
    'been', 'before', 'began', 'begin', 'behind', 'being', 'believe', 'best',
    'better', 'between', 'big', 'both', 'boy', 'bring', 'brought', 'business',
    'but', 'by', 'call', 'came', 'can', 'cannot', 'car', 'case', 'certain',
    'change', 'child', 'children', 'city', 'clear', 'come', 'could', 'couldn',
    'country', 'course', 'day', 'days', 'did', 'didn', 'different', 'do', 'does',
    'doesn', 'doing', 'done', 'don', 'door', 'down', 'during', 'each', 'early',
    'either', 'end', 'enough', 'even', 'ever', 'every', 'everybody', 'everyone',
    'everything', 'face', 'fact', 'family', 'far', 'feel', 'few', 'find', 'first',
    'for', 'form', 'found', 'four', 'from', 'general', 'get', 'give', 'given',
    'go', 'going', 'good', 'got', 'great', 'group', 'had', 'hand', 'has', 'hasn',
    'have', 'haven', 'having', 'he', 'head', 'hear', 'heard', 'help', 'her',
    'here', 'hers', 'herself', 'high', 'him', 'himself', 'his', 'home', 'house',
    'how', 'however', 'i', 'idea', 'if', 'important', 'in', 'into', 'is', 'isn',
    'it', 'its', 'itself', 'job', 'just', 'keep', 'kind', 'knew', 'know', 'known',
    'land', 'large', 'last', 'late', 'later', 'learn', 'least', 'leave', 'left',
    'less', 'let', 'life', 'light', 'like', 'line', 'little', 'live', 'long',
    'look', 'looked', 'looking', 'made', 'make', 'making', 'man', 'many', 'may',
    'maybe', 'me', 'mean', 'might', 'more', 'morning', 'most', 'mother', 'move',
    'much', 'must', 'my', 'myself', 'name', 'near', 'need', 'never', 'new',
    'next', 'night', 'no', 'nobody', 'none', 'noone', 'nor', 'not', 'nothing',
    'now', 'number', 'of', 'off', 'often', 'old', 'on', 'once', 'one', 'only',
    'open', 'or', 'order', 'other', 'others', 'our', 'out', 'over', 'own', 'part',
    'people', 'per', 'place', 'play', 'point', 'possible', 'problem', 'put',
    'quite', 'rather', 'read', 'real', 'really', 'right', 'room', 'run', 'said',
    'same', 'saw', 'say', 'saying', 'says', 'school', 'see', 'seem', 'seemed',
    'seen', 'several', 'shall', 'she', 'should', 'shouldn', 'show', 'side',
    'since', 'small', 'so', 'some', 'somebody', 'someone', 'something', 'state',
    'still', 'such', 'sure', 'system', 'take', 'taken', 'taking', 'than', 'that',
    'the', 'their', 'them', 'themselves', 'then', 'there', 'these', 'they',
    'thing', 'things', 'think', 'thinking', 'this', 'those', 'though', 'thought',
    'three', 'through', 'time', 'to', 'together', 'told', 'too', 'took', 'toward',
    'turn', 'turned', 'two', 'under', 'understand', 'until', 'up', 'upon', 'us',
    'use', 'used', 'very', 'view', 'voice', 'want', 'wanted', 'was', 'wasn',
    'water', 'way', 'ways', 'we', 'well', 'went', 'were', 'weren', 'what',
    'when', 'where', 'whether', 'which', 'while', 'white', 'who', 'whole',
    'whom', 'whose', 'why', 'will', 'with', 'within', 'without', 'won', 'word',
    'words', 'work', 'world', 'would', 'wouldn', 'year', 'years', 'yes', 'yet',
    'you', 'young', 'your', 'yours', 'yourself',
    // 常见名词与日常词汇
    'video', 'audio', 'music', 'player', 'movie', 'game', 'love',
    'friend', 'friends', 'phone', 'computer', 'apple', 'google', 'model',
    'today', 'tomorrow', 'yesterday', 'sorry', 'thank', 'thanks', 'please',
    'welcome', 'listen', 'talk', 'speak', 'tell',
    'start', 'stop', 'pause', 'wait', 'watch', 'check', 'try',
  };

  /// 常见英文缩写形式
  static const Set<String> _contractions = {
    "'re", "'s", "'ve", "'d", "'ll", "'m", "n't", "'t",
  };

  /// 将文本中的所有英文字母转为小写（适用于 Zipformer 等仅输出全大写英文字元的 ASR 模型）
  static String lowerCaseEnglish(String text) => lowerCaseEnglishWords(text);

  static String lowerCaseEnglishWords(String text) {
    if (text.isEmpty) return text;
    return text.replaceAllMapped(RegExp(r'[A-Za-z]+'), (match) {
      return match.group(0)!.toLowerCase();
    });
  }

  /// 格式化 ASR 输出文本：
  /// 1. 优先基于模型原始输出的词元列表 ([tokens]) 重建英文单词空格
  /// 2. 若指定 [lowerCaseEnglish]（如 Zipformer 英文大写模型），统一将英文字母转为小写
  /// 3. 若 token 缺失或粘连严重，自动进行英文复合词与长词智能拆分
  /// 4. 规范化中英文与数字、标点符号之间的排版空格
  static String format({
    required List<String>? tokens,
    required String rawText,
    bool lowerCaseEnglish = false,
  }) {
    String text;
    if (tokens != null && tokens.isNotEmpty) {
      text = _reconstructFromTokens(tokens);
    } else {
      text = rawText.trim();
    }

    if (text.isEmpty) return '';

    // 若指定了转小写（如 Zipformer 英文模型），在切词和排版前先统一转小写
    if (lowerCaseEnglish) {
      text = lowerCaseEnglishWords(text);
    }

    // 对文本中出现的长英文粘连词进行深度分词检测
    text = segmentGluedEnglish(text);

    // 中英文混排与标点符号规范化排版
    text = formatSpacingAndPunctuation(text);

    return text;
  }

  /// 核心：从 ASR 输出的原始 Token 列表重建正确空格
  static String _reconstructFromTokens(List<String> tokens) {
    final sb = StringBuffer();
    String? prevToken;

    // 检查 Token 列表中是否包含 SentencePiece 词首空格/下划线标记 ( 如 ' ' 或 '\u2581' )
    final hasSpiMarkers =
        tokens.any((t) => t.startsWith(' ') || t.startsWith('\u2581'));

    for (int i = 0; i < tokens.length; i++) {
      var token = tokens[i];
      if (token.isEmpty) continue;

      // 1. SentencePiece / BPE 前导下划线或空格标记 (\u2581)
      bool hasLeadingSpiSpace = false;
      if (token.startsWith(' ') || token.startsWith('\u2581')) {
        hasLeadingSpiSpace = true;
        token = token.substring(1);
        if (token.isEmpty) {
          if (sb.isNotEmpty && !sb.toString().endsWith(' ')) {
            sb.write(' ');
          }
          prevToken = ' ';
          continue;
        }
      }

      if (sb.isEmpty) {
        sb.write(token);
        prevToken = token;
        continue;
      }

      final prev = prevToken ?? '';
      final lastChar = prev.isNotEmpty ? prev[prev.length - 1] : '';
      final firstChar = token[0];

      final isPrevAscii = RegExp(r'[a-zA-Z0-9]').hasMatch(lastChar);
      final isCurrAscii = RegExp(r'[a-zA-Z0-9]').hasMatch(firstChar);
      final isPrevCjk = RegExp(r'[\u4e00-\u9fa5\u3040-\u30ff\uac00-\ud7af]').hasMatch(lastChar);
      final isCurrCjk = RegExp(r'[\u4e00-\u9fa5\u3040-\u30ff\uac00-\ud7af]').hasMatch(firstChar);

      final isCurrPunct = RegExp(r"^[,\.!\?;:，。！？；：、）】」』]").hasMatch(token);
      final isPrevPunct = RegExp(r"[,\.!\?;:，。！？；：、]").hasMatch(lastChar);

      // 缩写检测：如 you + 're -> you're
      final isContraction = token.startsWith("'") || _contractions.contains(token.toLowerCase());

      if (hasLeadingSpiSpace) {
        if (!sb.toString().endsWith(' ') && !isCurrPunct) {
          sb.write(' ');
        }
      } else if (isContraction) {
        // 缩写不加空格
      } else if (isCurrPunct) {
        // 标点符号前不加空格
      } else if (isPrevPunct && (isCurrAscii || isCurrCjk)) {
        // 英文标点后加空格
        if (RegExp(r'[,\.!\?;:]').hasMatch(lastChar) && !sb.toString().endsWith(' ')) {
          sb.write(' ');
        }
      } else if (isPrevAscii && isCurrAscii) {
        // 若模型未带有 SentencePiece 词首空格标记（如 SenseVoice），连续的英文字词之间补空格
        // 若模型使用了 SentencePiece 标记（如 Zipformer / Whisper），未带前导空格的 token 属于同词子词切片，严禁补空格
        if (!hasSpiMarkers && !sb.toString().endsWith(' ')) {
          sb.write(' ');
        }
      } else if ((isPrevAscii && isCurrCjk) || (isPrevCjk && isCurrAscii)) {
        // 中英文交界处添加空格，符合现代排版规范
        if (!sb.toString().endsWith(' ')) {
          sb.write(' ');
        }
      }

      sb.write(token);
      prevToken = token;
    }

    return sb.toString();
  }

  /// 智能拆分被连成一整串的英文句子（例如 "becauseonceyou'rethere" -> "because once you're there"）
  static String segmentGluedEnglish(String text) {
    if (text.isEmpty) return text;

    // 匹配连续的英文字符串（包含单引号如 you're）
    final wordRegex = RegExp(r"[a-zA-Z]+(?:'[a-zA-Z]+)?");

    return text.replaceAllMapped(wordRegex, (match) {
      final token = match.group(0)!;
      // 正常短词无需拆解
      if (token.length < 11 && !token.contains("'")) {
        return token;
      }

      // 如果整个词本身就在词典中，无需拆解
      final lower = token.toLowerCase();
      if (_commonEnglishWords.contains(lower)) {
        return token;
      }

      // 尝试使用正向贪婪匹配切词
      final segmented = _trySegmentEnglishCompound(token);
      return segmented ?? token;
    });
  }

  /// 正向最大匹配与动态规划拆分英文字符串
  static String? _trySegmentEnglishCompound(String text) {
    final lower = text.toLowerCase();
    final n = lower.length;
    if (n < 3) return null;

    // 1. 如果包含单引号缩写（如 you'rethere），以缩写为天然分割锚点
    if (lower.contains("'")) {
      final apostropheIdx = lower.indexOf("'");
      if (apostropheIdx > 0 && apostropheIdx < n - 1) {
        for (final c in _contractions) {
          if (lower.substring(apostropheIdx).startsWith(c)) {
            final contractionEnd = apostropheIdx + c.length;
            final baseWord = text.substring(0, apostropheIdx);
            final right = text.substring(contractionEnd);

            final segBase = _trySegmentEnglishCompound(baseWord) ?? baseWord;
            final leftPart = '$segBase$c';

            if (right.isEmpty) {
              return segBase != baseWord ? leftPart : null;
            }
            final segRight = _trySegmentEnglishCompound(right) ?? right;
            return '$leftPart $segRight'.trim();
          }
        }
      }
    }

    // 2. 纯字母无标点串的动态规划切分
    final dp = List<int?>.filled(n + 1, null);
    dp[0] = 0;

    for (int i = 0; i < n; i++) {
      if (dp[i] == null) continue;
      // 从长到短匹配 (最多 16 个字符，最少 1 个字符)
      for (int len = 1; len <= 16 && i + len <= n; len++) {
        final sub = lower.substring(i, i + len);
        if (_commonEnglishWords.contains(sub) || sub.length == 1) {
          // 单字母只允许 'a' 或 'i'
          if (sub.length == 1 && sub != 'a' && sub != 'i') continue;
          dp[i + len] = i;
        }
      }
    }

    if (dp[n] == null) return null;

    final parts = <String>[];
    int curr = n;
    while (curr > 0) {
      final prev = dp[curr]!;
      parts.add(text.substring(prev, curr));
      curr = prev;
    }

    final reversed = parts.reversed.toList();
    if (reversed.length >= 2) {
      return reversed.join(' ');
    }
    return null;
  }

  /// 中英文混排与标点符号排版规范化
  static String formatSpacingAndPunctuation(String text) {
    var s = text;

    // 1. 中文与英文/数字之间增加空格
    s = s.replaceAllMapped(
      RegExp(r'([\u4e00-\u9fa5\u3040-\u30ff\uac00-\ud7af])([a-zA-Z0-9])'),
      (m) => '${m[1]} ${m[2]}',
    );
    s = s.replaceAllMapped(
      RegExp(r'([a-zA-Z0-9])([\u4e00-\u9fa5\u3040-\u30ff\uac00-\ud7af])'),
      (m) => '${m[1]} ${m[2]}',
    );

    // 2. 消除多余空格
    s = s.replaceAll(RegExp(r'[ \t]+'), ' ');

    // 3. 标点符号前不留空格
    s = s.replaceAll(RegExp(r'\s+([,\.!\?;:，。！？；：、])'), r'$1');

    // 4. 英文标点后保持单空格
    s = s.replaceAllMapped(
      RegExp(r'([,\.!\?;:])([a-zA-Z0-9])'),
      (m) => '${m[1]} ${m[2]}',
    );

    return s.trim();
  }

  /// 标点与文本恢复校验守卫算法 (借鉴自 D:\app\realtime-asr PunctuationText.restore)
  /// 核心原则：标点增强模型或格式化算法无论怎么处理，都绝对不能篡改、删除或虚构原有的识别文字！
  /// - 提取原文与结果中的所有核心词素字符 (忽略纯标点与多余空格)
  /// - 若文字内容完全一致：应用规范化英文/中文标点排版
  /// - 若文字内容发生增删或篡改 (words(orig) != words(result))：严格拒绝篡改，安全回退保留原文
  static String restoreWithPunctuation(String original, String? result, {String language = 'auto'}) {
    if (result == null || result.trim().isEmpty) return original;
    final origWords = extractWordTokens(original);
    final resultWords = extractWordTokens(result);
    if (origWords != resultWords) {
      // 词素不匹配，说明标点模型存在幻觉或丢字，安全保留原文
      return original;
    }

    var value = result.trim();
    if (language.startsWith('en')) {
      value = value
          .replaceAll('，', ', ')
          .replaceAll('。', '. ')
          .replaceAll('？', '? ')
          .replaceAll('！', '! ')
          .replaceAll('：', ': ')
          .replaceAll('；', '; ');
      value = value.replaceAllMapped(RegExp(r'([,!?;:])(?=[a-zA-Z0-9])'), (m) => '${m[1]} ');
      value = value.replaceAll(RegExp(r' +'), ' ').trim();
    }
    return formatSpacingAndPunctuation(value);
  }

  /// 提取用于完整性校验的词元序列 (去除标点与格式符号，仅保留文字核心)
  static String extractWordTokens(String text) {
    final sb = StringBuffer();
    for (final char in text.runes) {
      final s = String.fromCharCode(char);
      // 保留汉字、假名、韩文、英文字母与数字
      if (RegExp(r'[\u4e00-\u9fa5\u3040-\u30ff\uac00-\ud7af0-9a-zA-Z]').hasMatch(s)) {
        sb.write(s.toLowerCase());
      }
    }
    return sb.toString();
  }
}
