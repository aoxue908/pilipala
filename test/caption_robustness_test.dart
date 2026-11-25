// 字幕文本处理鲁棒性自测：聚焦"漏词"与"断句"两类回归。
// 全部直接调用生产代码里的静态函数，确保测试的是真实逻辑。
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/asr_stream.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_overlay.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_timeline.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/public_cloud_asr_stream.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/realtime_captions.dart';

void main() {
  group('划词查词语言判定：当前句特征优先于全局语境（英文误判韩语回归）', () {
    test('英文句 + 全局语境被锁成 ko → 判 en，不再误标韩语 KO', () {
      final lang = solveQueryLanguage(
        sentence: "All right, we're finally in the train and I realized",
        query: 'train',
        langContext: 'ko',
      );
      expect(lang, 'en');
    });

    test('英文句 + 全局语境 ja → 仍判 en', () {
      expect(
        solveQueryLanguage(sentence: 'finally in the train', query: 'train', langContext: 'ja'),
        'en',
      );
    });

    test('当前句真有韩文 → 判 ko（不被英文语境带偏）', () {
      expect(
        solveQueryLanguage(sentence: '기차에 있어요', query: '기차', langContext: 'en'),
        'ko',
      );
    });

    test('当前句真有假名 → 判 ja', () {
      expect(
        solveQueryLanguage(sentence: 'これは電車です', query: '電車', langContext: 'ko'),
        'ja',
      );
    });

    test('汉字句：粤语标记优先，否则跟随语境的 ja/ko', () {
      expect(
        solveQueryLanguage(sentence: '我们在火车上', query: '火车', langContext: 'ja'),
        'ja',
      );
      expect(
        solveQueryLanguage(sentence: '我们在火车上', query: '火车', isYue: true),
        'yue',
      );
      expect(
        solveQueryLanguage(sentence: '我们在火车上', query: '火车'),
        'zh-CN',
      );
    });

    test('纯数字/无特征句：回退全局语境', () {
      expect(
        solveQueryLanguage(sentence: '2025', query: '2025', langContext: 'en'),
        'en',
      );
    });
  });

  group('字幕条宽度：横屏限制为屏幕 3/5，左右各留 1/5', () {
    test('横屏 1200 宽 → 720（3/5），左右各留 240（1/5）', () {
      final w = captionBarWidth(screenWidth: 1200, isLandscape: true);
      expect(w, 720.0);
      expect((1200 - w) / 2, 240.0);
    });

    test('横屏典型分辨率 1920 → 1152（3/5）', () {
      expect(captionBarWidth(screenWidth: 1920, isLandscape: true), 1152.0);
    });

    test('竖屏仍全宽（仅留 16px 安全边距）', () {
      expect(captionBarWidth(screenWidth: 400, isLandscape: false), 384.0);
    });

    test('极窄窗口不低于 140px 下限', () {
      expect(captionBarWidth(screenWidth: 100, isLandscape: true), 140.0);
      expect(captionBarWidth(screenWidth: 100, isLandscape: false), 140.0);
    });
  });

  group('字幕窗口高度 = 行数 × 行高（行数设置真正生效）', () {
    test('4 行窗口：字号 16 → 16×1.45×4 + 8', () {
      expect(
        captionWindowHeight(fontSize: 16, lines: 4),
        closeTo(16 * 1.45 * 4 + 8, 0.001),
      );
    });

    test('2 行窗口比 6 行窗口矮，行数直接决定高度', () {
      final two = captionWindowHeight(fontSize: 16, lines: 2);
      const six = 16 * 1.45 * 6 + 8;
      expect(two, lessThan(six));
      expect(captionWindowHeight(fontSize: 16, lines: 6), closeTo(six, 0.001));
    });

    test('行数超范围被夹到 2-6', () {
      expect(
        captionWindowHeight(fontSize: 16, lines: 1),
        captionWindowHeight(fontSize: 16, lines: 2),
      );
      expect(
        captionWindowHeight(fontSize: 16, lines: 99),
        captionWindowHeight(fontSize: 16, lines: 6),
      );
    });
  });

  group('字幕框拖动定位：默认居中、位置可持久化且始终在屏内', () {
    test('默认居中位置换算成 align = (0, 0)', () {
      final a = captionPositionToAlignment(
        left: (1200 - 720) / 2,
        top: (800 - 100) / 2,
        screenWidth: 1200,
        screenHeight: 800,
        cardWidth: 720,
        cardHeight: 100,
      );
      expect(a.dx, closeTo(0, 1e-9));
      expect(a.dy, closeTo(0, 1e-9));
    });

    test('拖到右下角 → align 接近 (1, 1)，往返换算不丢位置', () {
      const screenW = 1200.0;
      const screenH = 800.0;
      const cardW = 720.0;
      const cardH = 100.0;
      const left = screenW - cardW;
      const top = screenH - cardH;
      final align = captionPositionToAlignment(
        left: left,
        top: top,
        screenWidth: screenW,
        screenHeight: screenH,
        cardWidth: cardW,
        cardHeight: cardH,
      );
      expect(align.dx, closeTo(1, 1e-9));
      expect(align.dy, closeTo(1, 1e-9));
      final back = captionAlignmentToPosition(
        alignX: align.dx,
        alignY: align.dy,
        screenWidth: screenW,
        screenHeight: screenH,
        cardWidth: cardW,
        cardHeight: cardH,
      );
      expect(back.dx, closeTo(left, 1e-9));
      expect(back.dy, closeTo(top, 1e-9));
    });

    test('越界对齐值被夹在屏幕内（不会拖丢字幕框）', () {
      final pos = captionAlignmentToPosition(
        alignX: 5,
        alignY: -9,
        screenWidth: 1000,
        screenHeight: 600,
        cardWidth: 600,
        cardHeight: 80,
      );
      expect(pos.dx, 400.0);
      expect(pos.dy, 0.0);
    });

    test('卡满整屏时位置恒为原点，不产生除零/NaN', () {
      expect(
        captionPositionToAlignment(
          left: 0,
          top: 0,
          screenWidth: 400,
          screenHeight: 400,
          cardWidth: 400,
          cardHeight: 400,
        ),
        Offset.zero,
      );
    });
  });

  group('竖屏全屏字幕跟在视频画面下方（不叠画面）', () {
    test('横屏视频在竖屏 contain 居中：字幕顶边落在画面下沿 + 12px，整块不压画面', () {
      const screenW = 1102.0;
      const screenH = 1920.0;
      const aspect = 16.0 / 9.0;
      // 用真实窗口高度（4行≈100px），而不是屏幕百分比
      const cardH = 100.0;

      final top = portraitCaptionTopY(
        screenW: screenW,
        screenH: screenH,
        videoAspect: aspect,
        cardHeight: cardH,
      );
      expect(top, isNotNull);

      // 画面几何：videoH = 1102/(16/9) ≈ 620，垂直居中 → 下沿 1270
      final videoH = screenW / aspect;
      final videoBottom = (screenH + videoH) / 2;
      expect(top, closeTo(videoBottom + 12, 1.0));
      // 顶边必须在画面下沿之下 —— 字幕整块落在画面下方的黑边里，不叠画面
      expect(top, greaterThan(videoBottom));
      expect(top! + cardH, lessThan(screenH));
    });

    test('回归：2-6 行的真实窗口高度下，顶边始终在画面下沿之下（不再压画面）', () {
      // 上一轮 bug：用 0.7×屏高反推，顶边被钉在屏幕 30%（≈576px），
      // 而画面下沿在 ≈1270px，字幕整块压进画面。这里对真实窗口高度逐一验证。
      const screenW = 1102.0;
      const screenH = 1920.0;
      const aspect = 16.0 / 9.0;
      final videoBottom = (screenH + screenW / aspect) / 2; // ≈1270

      for (final lines in [2, 3, 4, 5, 6]) {
        final cardH = captionWindowHeight(fontSize: 16, lines: lines);
        final top = portraitCaptionTopY(
          screenW: screenW,
          screenH: screenH,
          videoAspect: aspect,
          cardHeight: cardH,
        );
        expect(top, isNotNull);
        // 顶边在画面下沿之下（跟在播放器后面），且整块不越出屏幕
        expect(top, greaterThan(videoBottom), reason: '$lines 行时字幕压画面');
        expect(top! + cardH, lessThan(screenH), reason: '$lines 行时字幕越界');
      }
    });

    test('竖屏视频画面铺满屏幕时不上移（返回 null 保持沉底）', () {
      expect(
        portraitCaptionTopY(
          screenW: 1102,
          screenH: 1920,
          videoAspect: 9.0 / 16.0, // 竖屏视频
          cardHeight: 100,
        ),
        isNull,
      );
    });

    test('非法宽高比返回 null', () {
      expect(
        portraitCaptionTopY(
          screenW: 1102,
          screenH: 1920,
          videoAspect: 0,
          cardHeight: 100,
        ),
        isNull,
      );
    });
  });

  group('单一字幕框：行数预算 + 新句重起行 + 向上滚动', () {
    // 统一测试参数：框内文字可用宽度 300px、字号 16。
    // 全角字符按 16px 宽 → 每行约 18 个汉字；半角按 8.8px。
    List<CaptionWindowSegment> window(
      List<String> texts, {
      int maxLines = 4,
    }) {
      return captionWindowSegments(
        texts: texts,
        maxLines: maxLines,
        availableWidth: 300,
        fontSize: 16,
      );
    }

    test('短句场景：旧句用剩余行预算从新到旧装填，最新句永远显示', () {
      final segments = window(['一', '二', '三', '四'], maxLines: 4);
      expect(segments, hasLength(4));
      expect(segments.first.text, '一');
      expect(segments.last.isLatest, isTrue);
      expect(segments.last.text, '四');
    });

    test('预算装不下时旧句被挤出：可见片段数严格受行数约束', () {
      // 每句占 1 行，maxLines=2 → 只显示最近 2 句
      final segments = window(['一', '二', '三', '四', '五'], maxLines: 2);
      expect(segments.map((s) => s.text).toList(), ['四', '五']);
    });

    test('新句重起行：每个片段独立成段，不与前后句拼接', () {
      final segments = window(['你好。', '世界。'], maxLines: 4);
      expect(segments, hasLength(2));
      expect(segments[0].text, '你好。');
      expect(segments[1].text, '世界。');
    });

    test('空句被跳过时，片段 sourceIndex 仍精确对应队列条目（不串位）', () {
      final segments = window(['一', '', '三', '四'], maxLines: 4);
      expect(segments, hasLength(3));
      expect(segments.map((s) => s.sourceIndex).toList(), [0, 2, 3]);
      expect(segments.map((s) => s.text).toList(), ['一', '三', '四']);
    });

    test('超长句超过行数预算：只显示尾部 N 行，头部视为滚出框顶', () {
      // 60 个汉字 ≈ 4 行（每行 18 字），maxLines=3 → 头部约 1 行被截掉
      final longSentence = '测' * 60;
      final segments = window([longSentence], maxLines: 3);
      expect(segments, hasLength(1));
      expect(segments.first.isLatest, isTrue);
      expect(segments.first.headTruncated, isTrue);
      expect(segments.first.text.length, lessThan(60));
      expect(segments.first.text.length, greaterThan(40),
          reason: '应保留约 (3-1) 行 ≈ 36 字以上的尾部');
    });

    test('中文行数估算：全角字符按 1 字宽', () {
      expect(
        estimateCaptionLineCount('测' * 18,
            availableWidth: 300, fontSize: 16),
        1,
      );
      expect(
        estimateCaptionLineCount('测' * 19,
            availableWidth: 300, fontSize: 16),
        2,
      );
    });

    test('英文行数估算：半角字符约 0.55 字宽', () {
      // 每行约 300/8.8 ≈ 34 个半角字符
      expect(
        estimateCaptionLineCount('a' * 34, availableWidth: 300, fontSize: 16),
        1,
      );
      expect(
        estimateCaptionLineCount('a' * 35, availableWidth: 300, fontSize: 16),
        2,
      );
    });

    test('空队列与非法参数不越界', () {
      expect(window([]), isEmpty);
      // maxLines 钳到 [1, 20]，宽/字号非法时按 1 行兜底
      expect(
        estimateCaptionLineCount('测试', availableWidth: 0, fontSize: 16),
        1,
      );
      expect(
        estimateCaptionLineCount('测试', availableWidth: 300, fontSize: 0),
        1,
      );
    });
  });

  group('字幕位置：默认停靠，手动位置覆盖默认且始终在屏内', () {
    test('未拖动时保持底部留白', () {
      expect(captionTopPosition(screenHeight: 800, captionHeight: 100,
        bottomInset: 30), 670);
    });

    test('竖屏全屏默认跟随画面下沿，拖动后可放到画面上方', () {
      expect(captionTopPosition(screenHeight: 800, captionHeight: 100,
        bottomInset: 30, defaultTop: 500), 500);
      expect(captionTopPosition(screenHeight: 800, captionHeight: 100,
        bottomInset: 30, defaultTop: 500, topFraction: 0.1), 80);
    });

    test('可移动整个屏幕，只限制上下边界', () {
      expect(captionTopPosition(screenHeight: 800, captionHeight: 100,
        bottomInset: 30, topFraction: -1), 0);
      expect(captionTopPosition(screenHeight: 800, captionHeight: 100,
        bottomInset: 30, topFraction: 2), 700);
      expect(captionTopPosition(screenHeight: 800, captionHeight: 100,
        bottomInset: 30, topFraction: 0.5), 400);
    });

    test('旋转屏幕或字幕增高后按真实尺寸保护位置', () {
      expect(captionTopPosition(screenHeight: 400, captionHeight: 150,
        bottomInset: 30, topFraction: 0.8), 250);
      expect(captionTopPosition(screenHeight: 100, captionHeight: 150,
        bottomInset: 30, topFraction: 0.8), 0);
    });
  });

  group('重复抑制器：不得删除正常口语重复（漏词回归）', () {
    const oralCases = [
      '我不知道我不知道他在哪里',
      '你是不是是不是搞错了',
      '谢谢你谢谢你帮我',
      '他说好不好好啊',
      '对对对你说的对',
      '走走走我们快点走',
    ];
    for (final text in oralCases) {
      test('保留口语重复: $text', () {
        expect(RealtimeCaptions.removeRepeatingPhrases(text), text);
      });
    }

    test('仍然清理长段幻觉循环（>=10字整段重复）', () {
      const loop = '你哋两个一齐去台湾见姑你哋两个一齐去台湾见姑';
      final result = RealtimeCaptions.removeRepeatingPhrases(loop);
      expect(result.length, lessThan(loop.length));
      expect(result, '你哋两个一齐去台湾见姑');
    });

    test('西文短重复 no no 不被删，长循环仍被清理', () {
      expect(RealtimeCaptions.removeRepeatingPhrases('no no'), 'no no');
      const spam = 'the quick brown fox the quick brown fox';
      expect(
          RealtimeCaptions.removeRepeatingPhrases(spam), 'the quick brown fox');
    });
  });

  group('文本合并：句子中间出现的相同片段不得被吞（漏词回归）', () {
    test('新片段是旧句中段子串时不再丢弃', () {
      // 旧实现 ex.contains(inc) 会把 '公园' 整段吞掉 → 漏词。
      expect(
        RealtimeCaptions.mergeCaptionTexts('我今天去公园玩了', '公园'),
        '我今天去公园玩了公园',
      );
    });

    test('真正的尾部增量回退仍然去重', () {
      expect(
        RealtimeCaptions.mergeCaptionTexts('我今天去公园', '去公园'),
        '我今天去公园',
      );
    });

    test('正常增量拼接保留全部内容', () {
      expect(
        RealtimeCaptions.mergeCaptionTexts('我昨天去了', '超市买东西'),
        '我昨天去了超市买东西',
      );
    });

    test('短重合(3字)不再误当重叠切头', () {
      // ex 尾 "这个" == inc 头 "这个"，旧门槛 3 会切掉真实内容。
      final merged =
          RealtimeCaptions.mergeCaptionTexts('我研究这个', '这个很重要');
      expect(merged.contains('这个很重要'), isTrue,
          reason: '新片段必须完整保留, 实际=$merged');
    });

    test('长重合(>=5字)仍正确合并', () {
      expect(
        RealtimeCaptions.mergeCaptionTexts('我昨天去了图书馆', '去了图书馆看书'),
        '我昨天去了图书馆看书',
      );
    });
  });

  group('官方字幕汉字追加空格（阅读性）', () {
    test('cjkSpace 开启时，汉字片段之间插入一个空格', () {
      expect(
        RealtimeCaptions.mergeCaptionTexts('十一七天乐今天是第六天了', '然后我们还有三个学校没逛',
            cjkSpace: true),
        '十一七天乐今天是第六天了 然后我们还有三个学校没逛',
      );
    });

    test('cjkSpace 关闭时（ASR 默认）汉字保持黏连，不影响原有行为', () {
      expect(
        RealtimeCaptions.mergeCaptionTexts('十一七天乐今天是第六天了', '然后我们还有三个学校没逛'),
        '十一七天乐今天是第六天了然后我们还有三个学校没逛',
      );
    });

    test('汉字后面接标点时不插空格（标点本身已有停顿）', () {
      expect(
        RealtimeCaptions.mergeCaptionTexts('我今天去公园了，', '然后回家了', cjkSpace: true),
        '我今天去公园了，然后回家了',
      );
    });

    test('重叠续写不插空格，避免把一个词劈开', () {
      // "图书馆看书" 是 5 字首尾重合，走重叠续写分支而非新分段，
      // 即使 cjkSpace 开启也不能变成 "图书馆看书 学习"。
      expect(
        RealtimeCaptions.mergeCaptionTexts('我们一起去图书馆看书', '图书馆看书学习',
            cjkSpace: true),
        '我们一起去图书馆看书学习',
      );
    });
  });

  group('AsrTranscript 断句：按句末标点成完整句', () {
    test('逗号不切断句子，继续追加到句号才成句', () {
      final t = AsrTranscript(sentenceOnly: true, emitPreview: false);
      // 结果在累积到句号的那一刻就 emit（不等 done）
      final finals = t
          .accept({
            'utterance': 0,
            'delta': '今天天气不错，',
            'done': false,
            'audio_ms': 1000,
          })
          .where((c) => c.isFinal)
          .toList()
        ..addAll(t
            .accept({
              'utterance': 0,
              'delta': '我们去公园吧。',
              'done': false,
              'audio_ms': 2000,
            })
            .where((c) => c.isFinal));
      // 期望：一句完整的话，而不是在逗号处切成两句
      expect(finals.length, 1, reason: '应成 1 个完整句, 实际=${finals.map((c) => c.text)}');
      expect(finals.single.text, contains('今天天气不错，我们去公园吧'));
    });

    // 队列层：display cue 被 _captionBreak 在逗号/词中间切开后，
    // 必须靠"只看句末标点"的判定重新拼回完整句（不受 28 字上限阻断）。
    bool lastIsComplete(String t) => RealtimeCaptions.isCompleteSentence(t);

    test('长句被切成多个cue后仍拼回1条完整缓存句（不在中间切开）', () {
      const long =
          '我现在要跟大家讲一个非常重要的事情，这件事情关系到我们每一个人的切身利益，所以希望大家能够认真地听我说完。';
      final cues = buildCaptionCues(long,
          startMs: 0, spokenEndMs: 9000, isFinal: true);
      expect(cues.length, greaterThan(1), reason: '前置条件：确实被切成多段');

      var acc = '';
      var cacheCount = 0;
      for (final c in cues) {
        final ct = c.text.trim();
        if (acc.isEmpty) {
          acc = ct;
          cacheCount++;
          continue;
        }
        if (lastIsComplete(acc)) {
          // 上一句已完结，另起一行
          cacheCount++;
          acc = ct;
        } else {
          // 未到句末标点：继续追加（新逻辑，无长度上限）
          acc = RealtimeCaptions.mergeCaptionTexts(acc, ct);
        }
      }
      expect(cacheCount, 1, reason: '应拼回 1 条完整句, 实际=$cacheCount');
      expect(acc, long, reason: '拼接内容必须与原句完全一致（无漏词）');
    });

    test('目录里那种词中间切开的句子也能完整拼回', () {
      const line =
          '这个防化的401你看它给我城里面这个防化的401他跟我说房东的钥匙放在这里果然可以但是没有把它放回去。';
      final cues =
          buildCaptionCues(line, startMs: 0, spokenEndMs: 9000, isFinal: true);
      var acc = '';
      var cacheCount = 0;
      for (final c in cues) {
        final ct = c.text.trim();
        if (acc.isEmpty) {
          acc = ct;
          cacheCount++;
        } else if (lastIsComplete(acc)) {
          cacheCount++;
          acc = ct;
        } else {
          acc = RealtimeCaptions.mergeCaptionTexts(acc, ct);
        }
      }
      expect(cacheCount, 1, reason: '应拼回 1 条, 实际=$cacheCount 段=$cues');
      expect(acc, line, reason: '不能漏词, 实际=$acc');
    });

    test('多个句末标点分别成句', () {
      final t = AsrTranscript(sentenceOnly: true, emitPreview: false);
      final finals = t
          .accept({
            'utterance': 0,
            'delta': '第一句话。第二句话！第三句话？',
            'done': false,
            'audio_ms': 3000,
          })
          .where((c) => c.isFinal)
          .toList();
      expect(finals.length, 3);
      expect(finals.map((c) => c.text).toList(),
          ['第一句话。', '第二句话！', '第三句话？']);
    });
  });

  group('句末标点判定：中英文全覆盖（漏判会导致句子一直不缓存）', () {
    const complete = [
      '今天天气不错。',
      '真的吗？',
      '太好了！',
      '就这样～',
      '省略……',
      'Hello world.',
      'How are you?',
      'Great!',
      // 引号/括号在句末标点之后，必须剥掉装饰再判定
      '他说“今天天气不错。”',
      'He said "really?"',
      '就是这个（真的。）',
    ];
    for (final text in complete) {
      test('认作完整句: $text', () {
        expect(RealtimeCaptions.isCompleteSentence(text), isTrue,
            reason: '句末标点必须被识别, 实际=$text');
      });
    }

    const incomplete = [
      '今天天气不错，',
      '我们明天再说',
      'Hello world,',
      'wait a moment',
      '',
    ];
    for (final text in incomplete) {
      test('不认作完整句: "$text"', () {
        expect(RealtimeCaptions.isCompleteSentence(text), isFalse);
      });
    }
  });

  group('缓存队列 FIFO：已入队完整句不得被尾部碎片覆盖（漏词回归）', () {
    const full =
        '今天天气不错我们决定去公园玩一会儿然后在附近的咖啡店坐坐聊聊天。';
    const tail = '去公园玩一会儿然后在附近的咖啡店坐坐聊聊天。';

    test('更短的尾部定稿不能替换已入队完整句', () {
      expect(
        RealtimeCaptions.shouldReplaceByMoreComplete(full, true, tail, true),
        isFalse,
        reason: '尾部碎片覆盖完整句会让缓存只剩最后几个字',
      );
    });

    test('真实案例：37字句子丢14字的路径被堵住', () {
      const long =
          '这个防化的401你看它给我城里面这个防化的401他跟我说房东的钥匙放在这里。';
      const fragment = '里面这个防化的401他跟我说房东的钥匙放在这里。';
      expect(
        RealtimeCaptions.shouldReplaceByMoreComplete(long, true, fragment, true),
        isFalse,
      );
    });

    test('更完整的版本仍可升级队尾', () {
      expect(
        RealtimeCaptions.shouldReplaceByMoreComplete(
            '今天天气不错', false, '今天天气不错我们去公园吧。', true),
        isTrue,
      );
    });

    test('等长时只有新版成句、旧版预览才升级', () {
      expect(
        RealtimeCaptions.shouldReplaceByMoreComplete(
            '今天天气不错呀', false, '今天天气不错呀', true),
        isTrue,
      );
      expect(
        RealtimeCaptions.shouldReplaceByMoreComplete(
            '今天天气不错呀', true, '今天天气不错呀', true),
        isFalse,
      );
    });
  });

  group('Deepgram 无标点文本：按词间真实停顿插空格（阅读性）', () {
    Map<String, dynamic> w(String word, double start, double end) =>
        {'word': word, 'start': start, 'end': end};

    test('长停顿处插入空格', () {
      final words = [
        w('今天天气不错', 1.0, 1.8),
        w('我们', 2.4, 2.7), // 间隔 600ms > 250ms
        w('去公园', 2.8, 3.4), // 间隔 100ms，不加
      ];
      expect(
        DeepgramAsrStream.transcriptWithBreathPauses('今天天气不错我们去公园', words),
        '今天天气不错 我们去公园',
      );
    });

    test('无停顿时保持原样，不插多余空格', () {
      final words = [
        w('你好', 0.0, 0.3),
        w('世界', 0.35, 0.7), // 间隔 50ms
      ];
      expect(
        DeepgramAsrStream.transcriptWithBreathPauses('你好世界', words),
        '你好世界',
      );
    });

    test('英文 word 自带空格时不重复插入', () {
      final words = [
        w('hello', 0.0, 0.4),
        w(' world', 1.0, 1.3), // 长停顿 + word 自带前导空格
      ];
      expect(
        DeepgramAsrStream.transcriptWithBreathPauses('hello world', words),
        'hello world',
      );
    });

    test('words 缺失时原样回退，绝不丢字', () {
      const text = '今天天气不错我们去公园';
      expect(DeepgramAsrStream.transcriptWithBreathPauses(text, null), text);
      expect(DeepgramAsrStream.transcriptWithBreathPauses(text, []), text);
    });

    test('优先使用 punctuated_word，不丢已给出的标点', () {
      final words = [
        {'word': '你好', 'punctuated_word': '你好，', 'start': 0.0, 'end': 0.4},
        {'word': '世界', 'punctuated_word': '世界。', 'start': 1.0, 'end': 1.4},
      ];
      expect(
        DeepgramAsrStream.transcriptWithBreathPauses('你好，世界。', words),
        '你好， 世界。',
      );
    });
  });

  group('ASR 结果晚到：时间轴过期兜底（音文同步）', () {
    CaptionCue cue(String text, int start, int end) => CaptionCue(
          text: text,
          startMs: start,
          endMs: end,
          canTranslate: true,
          highlights: const [],
        );

    test('所有 cue 已过期时返回最后一个 cue（结果晚到仍出字幕）', () {
      final tl = CaptionTimeline([
        cue('第一句。', 1000, 2000),
        cue('第二句。', 3000, 4000),
      ]);
      expect(tl.at(5000), isNull, reason: '前置条件：严格匹配确实拿不到');
      expect(tl.atOrLatest(5000)?.text, '第二句。');
    });

    test('cue 尚未开始时返回 null，字幕不提前于声音', () {
      final tl = CaptionTimeline([
        cue('第一句。', 5000, 6000),
        cue('第二句。', 7000, 8000),
      ]);
      expect(tl.atOrLatest(1000), isNull);
    });

    test('有活跃 cue 时正常返回当前 cue', () {
      final tl = CaptionTimeline([
        cue('第一句。', 1000, 2000),
        cue('第二句。', 3000, 6000),
      ]);
      expect(tl.atOrLatest(4000)?.text, '第二句。');
    });

    test('空时间轴返回 null', () {
      expect(CaptionTimeline(const []).atOrLatest(1000), isNull);
    });
  });

  group('音文同步：预读位置差让字幕提前就绪（而非滞后）', () {
    test('读取上限 = 播放进度 + 预读位置差', () {
      // 会话从视频 10s 起，画面播到 20s，预读 6s → 应读到音频流 16s 处
      expect(
        RealtimeCaptions.asrReadThroughMs(
          playbackMs: 20000,
          originMs: 10000,
          readAheadMs: 6000,
        ),
        16000,
      );
    });

    test('画面还没到会话起点时仍可提前读取（预读的意义）', () {
      // 会话 10s 起，画面才 9s，但预读 6s 允许先把音频读到起点后 5s
      expect(
        RealtimeCaptions.asrReadThroughMs(
          playbackMs: 9000,
          originMs: 10000,
          readAheadMs: 6000,
        ),
        5000,
      );
    });

    test('读取上限不为负', () {
      expect(
        RealtimeCaptions.asrReadThroughMs(
          playbackMs: 1000,
          originMs: 10000,
          readAheadMs: 2000,
        ),
        0,
      );
    });

    test('引擎处理领先播放 → 就绪领先量为正（同步）', () {
      // 会话起点 10s，引擎已处理音频 12s（映射到视频 22s），画面在 20s
      expect(
        RealtimeCaptions.captionReadyLeadMs(
          originMs: 10000,
          engineProcessedMs: 12000,
          playbackMs: 20000,
        ),
        2000,
        reason: '引擎跑在画面前 2 秒，字幕就绪，会准时上屏',
      );
    });

    test('引擎落后播放 → 就绪领先量为负（滞后）', () {
      expect(
        RealtimeCaptions.captionReadyLeadMs(
          originMs: 10000,
          engineProcessedMs: 8000,
          playbackMs: 20000,
        ),
        -2000,
      );
    });

    test('预读缓冲吃掉引擎延迟后仍保持正的就绪领先', () {
      // 预读 6s：画面播到 20s 时引擎已处理到 18s（扣掉 2s 引擎自身延迟）
      const engineProcessed = 20000 - 10000 + 6000 - 2000;
      expect(
        RealtimeCaptions.captionReadyLeadMs(
          originMs: 10000,
          engineProcessedMs: engineProcessed,
          playbackMs: 20000,
        ),
        4000,
        reason: '6s 预读 - 2s 引擎延迟 = 领先 4s，字幕不会滞后',
      );
    });
  });

  group('音文同步：背压闭环防止渐渐延迟', () {
    test('积压与领先都健康时维持基础速率', () {
      final rate = RealtimeCaptions.cloudAdaptiveSendRate(
        baseRate: 1.15,
        pendingMs: 1000,
        readyLeadMs: 3000,
      );
      expect(rate, closeTo(1.15, 0.001));
    });

    test('积压过大时降速到暂停，让引擎消化（防延迟累积）', () {
      final rate = RealtimeCaptions.cloudAdaptiveSendRate(
        baseRate: 1.15,
        pendingMs: 8000,
        readyLeadMs: 3000,
      );
      expect(rate, 0.0, reason: '积压>6s 必须停推，否则结果越出越晚');
    });

    test('积压中等时按比例降速', () {
      final rateMid = RealtimeCaptions.cloudAdaptiveSendRate(
        baseRate: 1.15,
        pendingMs: 3200,
        readyLeadMs: 3000,
      );
      expect(rateMid, closeTo(1.15 * 0.7, 0.001));
      final rateHigh = RealtimeCaptions.cloudAdaptiveSendRate(
        baseRate: 1.15,
        pendingMs: 5000,
        readyLeadMs: 3000,
      );
      expect(rateHigh, closeTo(1.15 * 0.35, 0.001));
    });

    test('领先不足且积压小时加速追赶，但不无限加速', () {
      final rate = RealtimeCaptions.cloudAdaptiveSendRate(
        baseRate: 1.15,
        pendingMs: 800,
        readyLeadMs: 200,
      );
      expect(rate, closeTo(1.15 * 1.3, 0.001), reason: '欠速加速到 1.3 倍系数');
      // 即使 baseRate 很大，也钳制在 2.0 上限
      final capped = RealtimeCaptions.cloudAdaptiveSendRate(
        baseRate: 2.0,
        pendingMs: 800,
        readyLeadMs: 200,
      );
      expect(capped, 2.0);
    });

    test('领先不足但积压已高时优先降速，不加速', () {
      final rate = RealtimeCaptions.cloudAdaptiveSendRate(
        baseRate: 1.15,
        pendingMs: 5000,
        readyLeadMs: 200,
      );
      expect(rate, closeTo(1.15 * 0.35, 0.001),
          reason: '积压才是主要矛盾，领先不足也不能加速灌入');
    });

    test('模拟长时间播放：固定速率积压发散，闭环速率积压收敛', () {
      // 引擎吞吐固定 1.0×，基础推流 1.15×。
      // 开环：积压每秒 +0.15× → 单调发散（渐渐延迟）。
      // 闭环：积压到阈值即降速，围绕阈值上下收敛。
      int openPending = 0; // 毫秒
      int closedPending = 0;
      const throughputPerSec = 1000; // 引擎每秒处理 1000ms 音频
      const stepMs = 1000;
      for (int i = 0; i < 60; i++) {
        // 开环：每秒推 1150ms
        openPending += 1150 - throughputPerSec;
        // 闭环：按当前积压调速
        final rate = RealtimeCaptions.cloudAdaptiveSendRate(
          baseRate: 1.15,
          pendingMs: closedPending,
          readyLeadMs: 3000 - closedPending,
        );
        final pushed = (rate * stepMs).round();
        closedPending = math.max(0, closedPending + pushed - throughputPerSec);
      }
      expect(openPending, 9000, reason: '开环 60 秒积压 9 秒，结果越出越晚');
      expect(closedPending, lessThan(7000),
          reason: '闭环积压被钳在小范围，不会随时间发散');
    });
  });
}
