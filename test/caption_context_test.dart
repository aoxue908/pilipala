import 'package:flutter_test/flutter_test.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_context.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_rollup.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/realtime_captions.dart';

void main() {
  test('只提取被点击单词所在的中英文句子', () {
    expect(captionContainingSentence(text: '前一句。只要不在学校去哪儿都行。后一句。', word: '学校'),
        '只要不在学校去哪儿都行。');
    expect(
        captionContainingSentence(
            text: 'First sentence. This is the target! Next sentence.',
            word: 'target'),
        'This is the target!');
  });

  test('相同词重复出现时按被点击的位置选句', () {
    const text = 'target comes first. Then target appears again.';
    expect(
        captionContainingSentence(
            text: text, word: 'target', wordOffset: text.lastIndexOf('target')),
        'Then target appears again.');
    const entry = CaptionRollupEntry(
        text: text, contextSentence: text, translation: '整段的旧翻译');
    final selected = entry.forLookup('target', text.lastIndexOf('target'));
    expect(selected.contextSentence, 'Then target appears again.');
    expect(selected.translation, isEmpty);
  });

  test('识别片段合并后仍能找回原片段，不显示无标点的前后文', () {
    const first = '只要不在学校去哪儿都行';
    const second = '那好今天就玩大的';
    const third = '每天起这么早真想成博士吗';
    var merged = first;
    var ranges = <CaptionContextRange>[(start: 0, end: first.length)];
    for (final incoming in [second, third]) {
      final next = RealtimeCaptions.mergeCaptionTexts(merged, incoming);
      ranges = mergeCaptionContextRanges(
          previous: merged, ranges: ranges, incoming: incoming, merged: next);
      merged = next;
    }
    expect(
        captionContainingSentence(
            text: merged, word: '学校', sourceRanges: ranges),
        first);
    expect(
        captionContainingSentence(
            text: merged, word: '今天', sourceRanges: ranges),
        second);
    expect(
        captionContainingSentence(
            text: merged, word: '博士', sourceRanges: ranges),
        third);
    final item =
        CaptionSentenceItem(id: '1', original: merged, contextRanges: ranges);
    expect(item.copyWith(translation: '翻译').contextRanges, ranges);
  });

  test('句子跨显示换行仍取完整句，缩写和小数不当句号拆分', () {
    expect(
        captionContainingSentence(
            text: 'Before. Dr. Smith has 3.14 dollars. After.',
            word: 'dollars'),
        'Dr. Smith has 3.14 dollars.');
    expect(captionContainingSentence(text: '他说：“你好！”接下来再聊。', word: '你好'),
        '他说：“你好！”');
  });

  test('旧的无片段长段落只显示选中词附近，不再撑满面板', () {
    final text = '${'前文' * 100}目标词${'后文' * 100}';
    final sentence = captionContainingSentence(text: text, word: '目标词');
    expect(sentence, contains('目标词'));
    expect(sentence.length, lessThan(100));
    expect(captionContainingSentence(text: '', word: '词'), isEmpty);
  });

  test('重复渲染不改变片段信息，识别纠正会重建片段范围', () {
    final ranges = <CaptionContextRange>[
      (start: 0, end: 3),
      (start: 3, end: 6)
    ];
    expect(
        mergeCaptionContextRanges(
            previous: '一二三四五六',
            ranges: ranges,
            incoming: '四五六',
            merged: '一二三四五六'),
        same(ranges));
    expect(
        mergeCaptionContextRanges(
            previous: '一二三四五六',
            ranges: ranges,
            incoming: '修正后的句子',
            merged: '修正后的句子'),
        [(start: 0, end: 6)]);
  });
}
