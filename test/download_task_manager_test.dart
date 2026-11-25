// 全局下载任务状态管理器自测：面板关闭后状态保持、进度不倒退、多任务隔离。
import 'package:flutter_test/flutter_test.dart';
import 'package:pilipala/utils/download_task_manager.dart';

void main() {
  /// 每个测试用独立 key 前缀，避免单例状态在用例间串台。
  String key(String tag) => 'test_task_$tag';

  group('全局下载任务状态（面板关闭重开仍可见）', () {
    test('markDownloading 后处于下载中，携带展示元信息', () {
      final m = DownloadTaskManager.instance;
      final k = key('meta');
      m.markDownloading(
        k,
        title: '天龙八部',
        pic: 'https://example.com/p.jpg',
        qualityLabel: '1080p',
        formatTitle: 'AVC · 视频 + 音频',
        bvid: 'BV1',
        cid: 42,
      );
      expect(m.isDownloading(k), isTrue);
      expect(m.progressOf(k), 0.0);
      final snap = m.state.value[k]!;
      expect(snap.title, '天龙八部');
      expect(snap.qualityLabel, '1080p');
      expect(snap.bvid, 'BV1');
      expect(snap.cid, 42);
      m.markFailed(k);
    });

    test('进度只在增大时更新，DASH 双流回报不会让进度倒退', () {
      final m = DownloadTaskManager.instance;
      final k = key('progress');
      m.markDownloading(k, title: 't');
      m.updateProgress(k, 0.5);
      m.updateProgress(k, 0.3); // 音频流从 0 重新回报，不应回退
      expect(m.progressOf(k), closeTo(0.5, 0.001));
      m.updateProgress(k, 0.8);
      expect(m.progressOf(k), closeTo(0.8, 0.001));
      // 越界钳制
      m.updateProgress(k, 1.5);
      expect(m.progressOf(k), 1.0);
      m.markFailed(k);
    });

    test('markDone 后退出下载中但保留记录供面板显示已下载态', () {
      final m = DownloadTaskManager.instance;
      final k = key('done');
      m.markDownloading(k, title: 't');
      m.updateProgress(k, 0.9);
      m.markDone(k);
      expect(m.isDownloading(k), isFalse);
      expect(m.progressOf(k), 1.0);
      expect(m.state.value.containsKey(k), isTrue);
      m.markFailed(k);
    });

    test('activeTasks 只返回下载中的任务，成功后不再出现', () {
      final m = DownloadTaskManager.instance;
      final kActive = key('active');
      final kDone = key('done2');
      m.markDownloading(kActive, title: '进行中');
      m.markDownloading(kDone, title: '已完成');
      m.markDone(kDone);
      final active = m.activeTasks();
      expect(active.any((s) => s.title == '进行中'), isTrue);
      expect(active.any((s) => s.title == '已完成'), isFalse);
      m.markFailed(kActive);
    });

    test('不同视频的同名格式用不同 key 不串台', () {
      final m = DownloadTaskManager.instance;
      final k1 = '${key('same')}_a_dash_video_80';
      final k2 = '${key('same')}_b_dash_video_80';
      m.markDownloading(k1, title: '视频A', bvid: 'BV-A');
      m.markDownloading(k2, title: '视频B', bvid: 'BV-B');
      m.updateProgress(k1, 0.7);
      expect(m.progressOf(k1), closeTo(0.7, 0.001));
      expect(m.progressOf(k2), 0.0);
      expect(m.state.value[k1]!.bvid, 'BV-A');
      expect(m.state.value[k2]!.bvid, 'BV-B');
      m.markFailed(k1);
      m.markFailed(k2);
    });

    test('取消任务：令牌被取消、可区分取消与失败，状态随即移除', () {
      final m = DownloadTaskManager.instance;
      final k = key('cancel');
      m.markDownloading(k, title: '可取消任务');
      expect(m.isCancelled(k), isFalse);

      m.cancelTask(k);
      expect(m.isCancelled(k), isTrue, reason: '取消后令牌应标记为已取消');

      // 上层捕获取消异常后调用 markFailed，任务从列表移除
      m.markFailed(k);
      expect(m.isDownloading(k), isFalse);
      expect(m.isCancelled(k), isFalse, reason: 'markFailed 后令牌应一并清理');
      expect(m.state.value.containsKey(k), isFalse);
    });

    test('快照携带 key：离线缓存页的取消按钮能定位到对应任务', () {
      final m = DownloadTaskManager.instance;
      final k = key('snapkey');
      m.markDownloading(k, title: '带key快照');
      final snapshot = m.activeTasks().firstWhere((s) => s.title == '带key快照');
      expect(snapshot.key, k, reason: '快照必须带 key，否则无法取消/删除对应任务');
      m.markFailed(k);
    });
  });
}
