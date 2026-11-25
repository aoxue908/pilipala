import 'package:flutter_test/flutter_test.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_timeline.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/realtime_captions.dart';

CaptionCue cue(String text, int start, {int? end}) => CaptionCue(
    text: text,
    startMs: start,
    endMs: end ?? start + 500,
    canTranslate: true,
    highlights: const []);

void main() {
  test('超过45秒后仍在时间轴里的旧片段不能重新入队', () {
    final delivery = CaptionCueDelivery();
    final timeline = CaptionTimeline([
      cue('旧字幕', 0, end: 1000),
      cue('当前字幕', 44000),
    ]);
    delivery.take(timeline, positionMs: 0, nowMs: 0);
    expect(delivery.take(timeline, positionMs: 44000, nowMs: 44000)!.text,
        '当前字幕');
    for (final now in [45001, 46000, 47000, 60000]) {
      expect(delivery.take(timeline, positionMs: now, nowMs: now)!.text,
          '当前字幕');
    }
    final updated = CaptionTimeline([
      cue('旧字幕', 0, end: 120000),
      cue('旧分段重新校准时间', 100),
      cue('当前字幕', 44000),
      cue('新的字幕', 61000),
    ]);
    expect(delivery.take(updated, positionMs: 61000, nowMs: 61000)!.text,
        '新的字幕');
  });

  test('连续三分钟播放，过期清理和旧预览保留都不会阻塞新字幕', () {
    final delivery = CaptionCueDelivery();
    final history = <CaptionCue>[];
    for (var position = 0; position <= 180000; position += 1000) {
      history.removeWhere((item) => item.endMs < position - 45000);
      history.add(cue('字幕$position', position));
      final timeline = CaptionTimeline([
        // 模拟服务器一直保留、更新的旧预览。
        if (position > 0) cue('旧预览', 0, end: position + 500),
        ...history,
      ]);
      expect(delivery.take(timeline, positionMs: position, nowMs: position)!.text,
          '字幕$position', reason: '播放到 $position 毫秒时不能回放旧字幕');
    }
  });

  test('ASR 一次返回多个过期片段，每段都按顺序展示且不会提前显示未来片段', () {
    final delivery = CaptionCueDelivery();
    final timeline = CaptionTimeline([
      cue('开头不能漏', 0),
      cue('中间不能漏', 600),
      cue('结尾也保留', 1200),
      cue('还没说到', 10000),
    ]);
    final seen = <String>[];
    for (final now in [0, 650, 1300]) {
      seen.add(delivery.take(timeline, positionMs: 4000, nowMs: now)!.text);
    }
    expect(seen, ['开头不能漏', '中间不能漏', '结尾也保留']);
    expect(
        delivery.take(timeline, positionMs: 4000, nowMs: 3000)!.text, '结尾也保留');
  });

  test('当前片段修订即时生效，暂停不滚走，清空后不串入上次播放', () {
    final delivery = CaptionCueDelivery();
    delivery.take(CaptionTimeline([cue('旧预览', 0)]), positionMs: 1000, nowMs: 0);
    final timeline = CaptionTimeline([cue('修订后的句子', 0), cue('下一句', 600)]);
    expect(
        delivery.take(timeline, positionMs: 1000, nowMs: 30)!.text, '修订后的句子');
    expect(
        delivery
            .take(timeline, positionMs: 1000, nowMs: 900, paused: true)!
            .text,
        '修订后的句子');
    expect(delivery.take(timeline, positionMs: 1000, nowMs: 1000)!.text, '下一句');
    delivery.clear();
    expect(
        delivery.take(CaptionTimeline([cue('未来', 2000)]),
            positionMs: 1000, nowMs: 2000),
        isNull);
  });

  test('不同音频片段中的重复词、相似句均保留，多次渲染不追加重复', () {
    final captions = RealtimeCaptions();
    for (final next in [cue('I think', 0), cue('I think this works', 600)]) {
      for (var frame = 0; frame < 3; frame++) {
        captions.updateSentenceQueue(next, isUsingAsr: true);
      }
    }
    expect(
        captions.sentenceQueue.single.original, 'I think I think this works');
    captions.clearSentenceQueue();
    captions.updateSentenceQueue(cue('我们今天一起去图书馆看书。', 0), isUsingAsr: true);
    captions.updateSentenceQueue(cue('我们今天一起去图书馆借书。', 2000), isUsingAsr: true);
    expect(captions.sentenceQueue.map((item) => item.original),
        ['我们今天一起去图书馆看书。', '我们今天一起去图书馆借书。']);
  });

  test('当前片段定稿只修订自己的文本，不删前面已显示的片段', () {
    final captions = RealtimeCaptions();
    captions.updateSentenceQueue(cue('前面的字', 0), isUsingAsr: true);
    captions.updateSentenceQueue(cue('这一段是比较长的预览文本', 600), isUsingAsr: true);
    captions.updateSentenceQueue(cue('这一段是定稿', 600, end: 2000),
        isUsingAsr: true);
    expect(captions.sentenceQueue.single.original, '前面的字这一段是定稿');
    expect(captions.sentenceQueue.single.contextRanges,
        [(start: 0, end: 4), (start: 4, end: 10)]);
  });

  test('同一批结果连续刷新不能瞬间跳过前面的词', () {
    final delivery = CaptionCueDelivery();
    final timeline = CaptionTimeline([cue('第一段', 0), cue('第二段', 600)]);
    for (final now in [0, 1, 33, 200, 500]) {
      expect(
          delivery.take(timeline, positionMs: 2000, nowMs: now)!.text, '第一段');
    }
    expect(delivery.take(timeline, positionMs: 2000, nowMs: 650)!.text, '第二段');
  });

  test('跳转清空后可以从较早位置重新播放，旧游标不会阻挡新视频', () {
    final delivery = CaptionCueDelivery();
    delivery.take(CaptionTimeline([cue('后面的字幕', 90000)]),
        positionMs: 90000, nowMs: 90000);
    delivery.clear();
    final timeline = CaptionTimeline([cue('跳转后的第一句', 1000), cue('下一句', 2000)]);
    expect(delivery.take(timeline, positionMs: 1000, nowMs: 90100)!.text,
        '跳转后的第一句');
    expect(delivery.take(timeline, positionMs: 2000, nowMs: 91100)!.text, '下一句');
  });
}
