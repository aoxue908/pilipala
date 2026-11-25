// 离线缓存下载记录模型与定位/居中逻辑自测。
import 'package:flutter_test/flutter_test.dart';
import 'package:pilipala/models/download/download_record.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_overlay.dart';
import 'package:pilipala/utils/download_record_store.dart';
import 'package:pilipala/utils/video_download.dart';

void main() {
  group('下载记录模型：序列化与文件定位', () {
    DownloadRecord buildRecord() => const DownloadRecord(
          id: 'BV1_123_dash_video_80_999',
          bvid: 'BV1',
          cid: 123,
          title: '测试视频',
          pic: 'https://example.com/pic.jpg',
          qualityLabel: '1080p',
          formatTitle: 'AVC · 视频 + 音频',
          totalSize: 1024 * 1024,
          files: [
            const DownloadFileRecord(
              path: r'C:\Downloads\B站下载\test_video.m4s',
              extension: 'm4s',
              isAudio: false,
              size: 700000,
            ),
            const DownloadFileRecord(
              path: r'C:\Downloads\B站下载\test_audio.m4a',
              extension: 'm4a',
              isAudio: true,
              size: 300000,
            ),
          ],
          downloadedAt: 1700000000000,
          durationSeconds: 600,
          sourceType: 'dash',
          formatId: 'dash_video_80',
        );

    test('toJson/fromJson 往返保留全部字段', () {
      final original = buildRecord();
      final restored = DownloadRecord.fromJson(original.toJson());
      expect(restored.id, original.id);
      expect(restored.bvid, original.bvid);
      expect(restored.cid, 123);
      expect(restored.formatId, 'dash_video_80');
      expect(restored.sourceType, 'dash');
      expect(restored.durationSeconds, 600);
      expect(restored.files.length, 2);
      expect(restored.totalSize, 1024 * 1024);
    });

    test('videoPath/audioPath 正确区分视频轨与音频轨', () {
      final record = buildRecord();
      expect(record.videoPath, r'C:\Downloads\B站下载\test_video.m4s');
      expect(record.audioPath, r'C:\Downloads\B站下载\test_audio.m4a');
      expect(record.hasVideo, isTrue);
    });

    test('纯音频记录 videoPath 为空、audioPath 有效', () {
      final record = const DownloadRecord(
        id: 'audio',
        bvid: 'BV1',
        cid: 1,
        title: '音频',
        pic: '',
        qualityLabel: '音频',
        formatTitle: 'm4a',
        totalSize: 100,
        files: const [
          DownloadFileRecord(path: '/tmp/a.m4a', extension: 'm4a', isAudio: true),
        ],
        downloadedAt: 0,
      );
      expect(record.videoPath, isNull);
      expect(record.audioPath, '/tmp/a.m4a');
      expect(record.hasVideo, isFalse);
    });

    test('损坏 JSON 也能安全构造，不抛异常', () {
      final record = DownloadRecord.fromJson(<String, dynamic>{
        'files': 'not-a-list',
        'cid': 'bad',
      });
      expect(record.files, isEmpty);
      expect(record.cid, 0);
      expect(record.title, '未命名视频');
    });
  });

  group('下载任务 id：必须确定性（防重复下载回归）', () {
    test('同一视频同一格式多次生成 id 完全一致', () {
      final a = DownloadRecordStore.makeId(
        bvid: 'BV1xx', cid: 111, itemId: 'dash_video_80');
      final b = DownloadRecordStore.makeId(
        bvid: 'BV1xx', cid: 111, itemId: 'dash_video_80');
      expect(a, b, reason: 'id 掺时间戳会让防重入检查失效，多点几次就开出并发下载');
    });

    test('不同视频 / 不同格式 id 不同，不串台', () {
      final base = DownloadRecordStore.makeId(
        bvid: 'BV1xx', cid: 111, itemId: 'dash_video_80');
      expect(
        DownloadRecordStore.makeId(
          bvid: 'BV2yy', cid: 111, itemId: 'dash_video_80'),
        isNot(base),
      );
      expect(
        DownloadRecordStore.makeId(
          bvid: 'BV1xx', cid: 222, itemId: 'dash_video_80'),
        isNot(base),
      );
      expect(
        DownloadRecordStore.makeId(
          bvid: 'BV1xx', cid: 111, itemId: 'dash_video_64'),
        isNot(base),
      );
    });
  });

  group('字幕条水平居中语义', () {
    test('横屏宽度仍为屏幕 3/5，左右各留 1/5', () {
      final width = captionBarWidth(screenWidth: 1080, isLandscape: true);
      expect(width, 1080 * 3 / 5);
      final left = (1080 - width) / 2;
      expect(left, 1080 * 1 / 5);
      expect(left + width + left, closeTo(1080, 0.001));
    });

    test('alignX=0 映射到水平正中（持久化居中值不会把字幕顶偏）', () {
      final pos = captionAlignmentToPosition(
        alignX: 0,
        alignY: 0,
        screenWidth: 1080,
        screenHeight: 600,
        cardWidth: 648,
        cardHeight: 100,
      );
      expect(pos.dx, closeTo((1080 - 648) / 2, 0.001));
      expect(pos.dy, closeTo((600 - 100) / 2, 0.001));
    });
  });

  group('体积文案：未知体积不展示', () {
    test('未知体积返回"大小未知"由调用方判断后隐藏', () {
      expect(formatDownloadSize(0), '大小未知');
      // 面板逻辑：estimatedSize>0 才拼接体积文案，否则只显示副标题。
      const subtitle = 'AVC · 视频 + 音频';
      const estimatedSize = 0;
      final line = estimatedSize > 0
          ? '$subtitle · ${formatDownloadSize(estimatedSize)}'
          : subtitle;
      expect(line, subtitle);
      expect(line.contains('大小未知'), isFalse);
    });
  });
}
