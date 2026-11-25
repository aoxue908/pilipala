// 视频下载格式生成与折叠逻辑自测：全部直接调用生产代码的纯函数。
import 'package:flutter_test/flutter_test.dart';
import 'package:pilipala/models/video/play/url.dart';
import 'package:pilipala/utils/video_download.dart';

void main() {
zhg  group('下载格式生成：DASH 音视频组合与音频轨', () {
    late PlayUrlModel dashModel;

    setUp(() {
      dashModel = PlayUrlModel(
        quality: 80,
        timeLength: 600000,
        dash: Dash(
          duration: 600,
          video: [
            VideoItem(
              id: 80,
              baseUrl: 'video_80_avc',
              bandWidth: 100000,
              codecs: 'avc1.640032',
              width: 1920,
              height: 1080,
            ),
            VideoItem(
              id: 80,
              baseUrl: 'video_80_hevc',
              bandWidth: 200000,
              codecs: 'hvc1.1.6',
              width: 1920,
              height: 1080,
            ),
            VideoItem(
              id: 64,
              baseUrl: 'video_64',
              bandWidth: 80000,
              codecs: 'avc1.64001f',
              width: 1280,
              height: 720,
            ),
          ],
          audio: [
            AudioItem(
              id: 30280,
              baseUrl: 'audio_192',
              bandWidth: 192000,
              mimeType: 'audio/mp4',
              quality: '192K',
            ),
            AudioItem(
              id: 30216,
              baseUrl: 'audio_64',
              bandWidth: 64000,
              mimeType: 'audio/mp4',
              quality: '64K',
            ),
          ],
        ),
      );
    });

    test('每个清晰度一项 + 每条音频一项，按清晰度倒序', () {
      final items = buildVideoDownloadItems(dashModel);
      expect(items.length, 4);
      expect(items[0].title, '1080p');
      expect(items[1].title, '720p');
      expect(items[2].title, contains('音频'));
      expect(items[3].title, contains('音频'));
    });

    test('同一清晰度多编码只取码率最高的流，避免列表爆炸', () {
      final items = buildVideoDownloadItems(dashModel);
      expect(items[0].streams.length, 2);
      expect(items[0].streams.first.url, 'video_80_hevc');
      expect(items[0].streams.first.codec, 'hvc1.1.6');
      expect(items[0].subtitle, contains('视频 + 音频'));
      expect(items[0].subtitle, contains('HEVC'));
    });

    test('组合项的第二条流是最佳音频（192K）', () {
      final items = buildVideoDownloadItems(dashModel);
      expect(items[0].streams[1].url, 'audio_192');
      expect(items[0].streams[1].isAudio, isTrue);
      expect(items[0].streams[1].extension, 'm4a');
    });

    test('体积按码率×时长估算', () {
      final items = buildVideoDownloadItems(dashModel);
      // 视频 200000bps + 音频 192000bps，600 秒
      expect(
        items[0].estimatedSize,
        (200000 / 8 * 600).round() + (192000 / 8 * 600).round(),
      );
    });

    test('mimeType 决定音频扩展名', () {
      final model = PlayUrlModel(
        dash: Dash(
          video: [],
          audio: [
            AudioItem(id: 30251, baseUrl: 'flac', mimeType: 'audio/flac'),
            AudioItem(id: 30250, baseUrl: 'dolby', mimeType: 'audio/ec3'),
            AudioItem(id: 30232, baseUrl: 'opus', mimeType: 'audio/webm'),
          ],
        ),
      );
      final items = buildVideoDownloadItems(model);
      expect(items.map((e) => e.streams.first.extension).toList(),
          ['flac', 'ec3', 'opus']);
    });
  });

  group('durl MP4 直链：视频音频一体', () {
    test('一项一个 mp4，体积直接用接口返回的 size', () {
      final items = buildVideoDownloadItems(
        PlayUrlModel(
          quality: 64,
          timeLength: 120000,
          durl: [
            Durl(order: 1, url: 'https://cdn.example/video.mp4', size: 9876543),
          ],
        ),
      );
      expect(items.length, 1);
      expect(items[0].title, '720p MP4');
      expect(items[0].subtitle, contains('MP4 直链'));
      expect(items[0].streams.length, 1);
      expect(items[0].streams.first.extension, 'mp4');
      expect(items[0].estimatedSize, 9876543);
    });
  });

  group('DASH 音视频合并为 MP4 的命令', () {
    test('无损封装：-c copy + 显式 map + faststart，输出 mp4', () {
      final args = buildMuxArgs(
        '/dl/a_80_video.m4s',
        '/dl/a_80_audio.m4a',
        '/dl/a_80.mp4',
      );
      expect(args.first, '-y');
      expect(args[args.length - 1], '/dl/a_80.mp4');
      expect(args, containsAllInOrder(['-i', '/dl/a_80_video.m4s']));
      expect(args, containsAllInOrder(['-i', '/dl/a_80_audio.m4a']));
      expect(args, containsAllInOrder(['-map', '0:v:0']));
      expect(args, containsAllInOrder(['-map', '1:a:0']));
      expect(args, containsAllInOrder(['-c', 'copy']));
      expect(args, containsAllInOrder(['-movflags', '+faststart']));
      // 不能出现重编码参数（保持最简：不转码、不掉画质）
      expect(args.join(' '), isNot(contains('libx264')));
    });
  });

  group('格式列表折叠与展示', () {
    test('默认只显示 4 项，展开后显示全部', () {
      expect(visibleDownloadItemCount(9, false), 4);
      expect(visibleDownloadItemCount(9, true), 9);
    });

    test('总数不足 4 项时全部显示', () {
      expect(visibleDownloadItemCount(2, false), 2);
    });

    test('空列表不显示', () {
      expect(visibleDownloadItemCount(0, true), 0);
    });

    test('体积格式化', () {
      expect(formatDownloadSize(0), '大小未知');
      expect(formatDownloadSize(1024), '1.0 KB');
      expect(formatDownloadSize(2 * 1024 * 1024), '2.0 MB');
    });

    test('文件名清洗掉各平台非法字符', () {
      expect(sanitizeDownloadFileName('a/b:c*d?e"f<g>h|i'), 'a_b_c_d_e_f_g_h_i');
      expect(sanitizeDownloadFileName('   '), 'bilibili_video');
    });

    test('清晰度码映射', () {
      expect(qualityLabel(80), '1080p');
      expect(qualityLabel(127), '8K');
      expect(qualityLabel(999), '999p');
    });
  });
}
