import 'dart:io';

import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter/return_code.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:pilipala/http/init.dart';
import 'package:pilipala/models/video/play/url.dart';
import 'package:pilipala/utils/media_store_exporter.dart';

/// 一条实际要落盘的媒体流。
class VideoDownloadStream {
  const VideoDownloadStream({
    required this.url,
    required this.extension,
    required this.durationSeconds,
    this.knownSize,
    this.bandwidth = 0,
    this.isAudio = false,
    this.codec = '',
  });

  final String url;
  final String extension;
  final int durationSeconds;
  final int? knownSize;
  /// bps，playurl 的 bandWidth 字段；用于估算体积
  final int bandwidth;
  final bool isAudio;
  final String codec;

  int get estimatedSize {
    if (knownSize != null && knownSize! > 0) return knownSize!;
    if (bandwidth <= 0) return 0;
    return (bandwidth / 8 * durationSeconds).round();
  }
}

/// 一次下载完成后的结果：落盘路径列表 + 是否已登记进公共媒体库。
class DownloadResult {
  const DownloadResult({
    required this.paths,
    required this.exportedToGallery,
  });

  final List<String> paths;

  /// 是否至少有一个成品文件已复制登记到公共 Movies/Music 目录
  /// （文件管理器/相册可见）。false 表示全部回退在 App 私有目录。
  final bool exportedToGallery;
}

/// 下载面板里的一个格式选项。
/// [streams] 有两条时表示 DASH 视频+音频分离，会落成两个文件。
class VideoDownloadItem {
  const VideoDownloadItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.streams,
    this.qualityCode = 0,
  });

  final String id;
  final String title;
  final String subtitle;
  final List<VideoDownloadStream> streams;
  final int qualityCode;

  int get estimatedSize =>
      streams.fold(0, (sum, stream) => sum + stream.estimatedSize);
  bool get isAudioOnly => streams.isNotEmpty && streams.every((s) => s.isAudio);
}

/// 把 playurl 数据转成可下载的格式列表。
///
/// - durl（MP4 直链）：视频+音频一体，一项一个 mp4。
/// - DASH：每个清晰度一项「视频 + 音频」（两文件），再列出各音频轨。
///   同一清晰度有多种编码时只取码率最高的那条，避免列表爆炸。
/// 结果按清晰度倒序，音频排在最后，正好匹配「格式多时收起」的交互。
List<VideoDownloadItem> buildVideoDownloadItems(
  PlayUrlModel data, {
  int? durationSeconds,
}) {
  final int duration = durationSeconds ??
      (data.timeLength != null && data.timeLength! > 0
          ? (data.timeLength! / 1000).round()
          : (data.dash?.duration ?? 0));

  final items = <VideoDownloadItem>[];

  final durl = data.durl;
  if (durl != null && durl.isNotEmpty) {
    for (final item in durl) {
      final url = item.url;
      if (url == null || url.isEmpty) continue;
      items.add(
        VideoDownloadItem(
          id: 'durl_${item.order ?? items.length}',
          title: '${qualityLabel(data.quality ?? 0)} MP4',
          subtitle: '视频 + 音频 · MP4 直链',
          qualityCode: data.quality ?? 0,
          streams: [
            VideoDownloadStream(
              url: url,
              extension: 'mp4',
              durationSeconds: duration,
              knownSize: item.size,
            ),
          ],
        ),
      );
    }
  }

  final dash = data.dash;
  if (dash != null) {
    final videos = dash.video ?? <VideoItem>[];
    final audios = dash.audio ?? <AudioItem>[];

    // 最佳音频：id 越大音质越好（30216 < 30232 < 30280 < 30250 < 30251）
    AudioItem? bestAudio;
    for (final audio in audios) {
      if (audio.baseUrl == null || audio.baseUrl!.isEmpty) continue;
      if (bestAudio == null || (audio.id ?? 0) > (bestAudio.id ?? 0)) {
        bestAudio = audio;
      }
    }

    // 每个清晰度取码率最高的一条流
    final bestByQuality = <int, VideoItem>{};
    for (final video in videos) {
      if (video.baseUrl == null || video.baseUrl!.isEmpty) continue;
      final q = video.id ?? 0;
      final current = bestByQuality[q];
      if (current == null || (video.bandWidth ?? 0) > (current.bandWidth ?? 0)) {
        bestByQuality[q] = video;
      }
    }
    final sortedQualities = bestByQuality.keys.toList()..sort((a, b) => b - a);
    for (final q in sortedQualities) {
      final video = bestByQuality[q]!;
      final streams = <VideoDownloadStream>[
        VideoDownloadStream(
          url: video.baseUrl!,
          extension: 'm4s',
          durationSeconds: duration,
          bandwidth: video.bandWidth ?? 0,
          codec: video.codecs ?? '',
        ),
      ];
      if (bestAudio != null) {
        final audioExt = audioExtension(bestAudio.mimeType ?? '',
            codecs: bestAudio.codecs ?? '');
        streams.add(
          VideoDownloadStream(
            url: bestAudio.baseUrl!,
            extension: audioExt,
            durationSeconds: duration,
            bandwidth: bestAudio.bandWidth ?? 0,
            isAudio: true,
            codec: bestAudio.codecs ?? '',
          ),
        );
      }
      final codec = codecLabel(video.codecs ?? '');
      final size = video.width != null && video.height != null
          ? '${video.width}×${video.height}'
          : '';
      final subtitleParts = <String>[
        if (codec.isNotEmpty) codec,
        if (size.isNotEmpty) size,
        streams.length > 1 ? '视频 + 音频 · 合并为 MP4' : '仅视频',
      ];
      items.add(
        VideoDownloadItem(
          id: 'dash_video_$q',
          title: qualityLabel(q),
          subtitle: subtitleParts.join(' · '),
          streams: streams,
          qualityCode: q,
        ),
      );
    }

    // 独立音频轨（去重）
    final seenAudio = <int>{};
    final sortedAudios = audios.where((a) => a.baseUrl != null && a.baseUrl!.isNotEmpty).toList()
      ..sort((a, b) => (b.id ?? 0) - (a.id ?? 0));
    for (final audio in sortedAudios) {
      final id = audio.id ?? 0;
      if (!seenAudio.add(id)) continue;
      final ext = audioExtension(audio.mimeType ?? '',
          codecs: audio.codecs ?? '');
      items.add(
        VideoDownloadItem(
          id: 'dash_audio_$id',
          title: '音频（$ext）',
          subtitle: '${audio.quality ?? '最佳音频流'} · 独立音频',
          qualityCode: 0,
          streams: [
            VideoDownloadStream(
              url: audio.baseUrl!,
              extension: ext,
              durationSeconds: duration,
              bandwidth: audio.bandWidth ?? 0,
              isAudio: true,
              codec: audio.codecs ?? '',
            ),
          ],
        ),
      );
    }
  }

  return items;
}

/// 折叠时的可见条数；展开后显示全部。
int visibleDownloadItemCount(
  int total,
  bool expanded, {
  int collapsedCount = 4,
}) {
  if (total <= 0) return 0;
  if (expanded) return total;
  return total < collapsedCount ? total : collapsedCount;
}

/// 单条流的下载进度（0.0 ~ 1.0）。
///
/// total 来自 CDN 的 Content-Length；部分响应拿不到（total<=0），
/// 此时用该流的估算体积兜底——否则进度会一直停在 0%，
/// 下载完成后直接跳"已下载"，表现为"进度卡住不刷新"。
double streamProgressRatio({
  required int received,
  required int total,
  required int expectedBytes,
}) {
  if (total > 0) return (received / total).clamp(0.0, 1.0);
  if (expectedBytes > 0) return (received / expectedBytes).clamp(0.0, 1.0);
  return 0.0;
}

/// 人类可读体积。
String formatDownloadSize(int bytes) {
  if (bytes <= 0) return '大小未知';
  const units = ['B', 'KB', 'MB', 'GB'];
  double value = bytes.toDouble();
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  if (unit == 0) return '${bytes}B';
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit]}';
}

/// 文件名清洗：去掉各平台非法字符，避免落盘失败。
String sanitizeDownloadFileName(String name, {int maxLength = 80}) {
  final cleaned = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
  final safe = cleaned.isEmpty ? 'bilibili_video' : cleaned;
  return safe.length > maxLength ? safe.substring(0, maxLength) : safe;
}

String qualityLabel(int code) {
  switch (code) {
    case 6:
      return '240p';
    case 16:
      return '360p';
    case 32:
      return '480p';
    case 64:
      return '720p';
    case 74:
      return '720p60';
    case 80:
      return '1080p';
    case 112:
      return '1080p+';
    case 116:
      return '1080p60';
    case 120:
      return '4K';
    case 125:
      return 'HDR';
    case 126:
      return '杜比视界';
    case 127:
      return '8K';
    default:
      return code > 0 ? '${code}p' : '视频';
  }
}

String codecLabel(String codecs) {
  final c = codecs.toLowerCase();
  if (c.startsWith('av01')) return 'AV1';
  if (c.startsWith('hev') || c.startsWith('hvc')) return 'HEVC';
  if (c.startsWith('dvh')) return '杜比视界';
  if (c.startsWith('avc')) return 'AVC';
  return c.isEmpty ? '' : codecs.split('.').first;
}

String audioExtension(String mimeType, {String codecs = ''}) {
  final mime = mimeType.toLowerCase();
  final codec = codecs.toLowerCase();
  if (mime.contains('flac') || codec.contains('flac')) return 'flac';
  if (mime.contains('ec3') || mime.contains('eac3') || codec.contains('ec3')) {
    return 'ec3';
  }
  if (mime.contains('opus') || mime.contains('webm') || codec.contains('opus')) {
    return 'opus';
  }
  return 'm4a';
}

/// 构建 ffmpeg 无损封装命令参数：分离的视频流 + 音频流 → 单个 MP4。
///
/// - `-c copy`：不重编码，只重新封装容器，长视频也只需几秒；
/// - `-movflags +faststart`：把索引(moov)放到文件头部，方便其它播放器拖动进度条；
/// - `-map 0:v:0 / 1:a:0`：显式只取视频轨第一条 + 音频轨第一条，避免流顺序歧义。
List<String> buildMuxArgs(
  String videoPath,
  String audioPath,
  String outputPath,
) {
  return <String>[
    '-y',
    '-i', videoPath,
    '-i', audioPath,
    '-map', '0:v:0',
    '-map', '1:a:0',
    '-c', 'copy',
    '-movflags', '+faststart',
    outputPath,
  ];
}

/// 下载服务：按格式项逐条流下载到本地。
///
/// 关键请求头（参考 Bili23-Downloader）：
/// - referer：B站 CDN 校验来源，缺了会 403
/// - Accept-Encoding: identity：媒体已压缩，禁止节点再做 gzip，否则字节错位
/// - cookie：复用 App 登录态，会员清晰度才拿得到
class VideoDownloadService {
  /// 下载一条格式项，返回落盘后的文件路径列表。
  ///
  /// [onProgress] 回报【整条格式项】的合并进度（0.0 ~ 1.0）：
  /// DASH 视频+音频两条流按预期字节权重加权合并；单条流内若 CDN 未返回
  /// Content-Length（total<=0），用该流的估算体积兜底——否则进度会一直停在 0%，
  /// 下载完成直接跳"已下载"，表现为"进度卡住"。
  static Future<DownloadResult> download(
    VideoDownloadItem item, {
    required String title,
    required void Function(double ratio) onProgress,
    CancelToken? cancelToken,
  }) async {
    final baseDir = await _resolveDownloadDir();
    final folder = Directory('${baseDir.path}${Platform.pathSeparator}B站下载');
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }

    final baseName = sanitizeDownloadFileName(title);
    final paths = <String>[];

    // 每条流的预期字节数（真实 size 优先，其次带宽估算），用于权重与 total 兜底。
    final expected = item.streams.map((s) => s.estimatedSize).toList();
    final totalExpected = expected.fold(0, (sum, e) => sum + e);
    final bool weighted = totalExpected > 0;
    final weights = weighted
        ? expected.map((e) => e / totalExpected).toList()
        : List<double>.filled(item.streams.length, 1 / item.streams.length);
    double completedWeight = 0; // 已完成流的权重和

    try {
      for (var i = 0; i < item.streams.length; i++) {
        final stream = item.streams[i];
        final role = item.streams.length > 1
            ? (stream.isAudio ? '_audio' : '_video')
            : '';
        final fileName =
            '$baseName${item.qualityCode > 0 ? '_${item.qualityCode}' : ''}$role.${stream.extension}';
        final target = File(
          '${folder.path}${Platform.pathSeparator}$fileName',
        );

        await _downloadWithRetry(
          stream.url,
          target,
          cancelToken: cancelToken,
          onProgress: (received, total) {
            final double streamRatio = streamProgressRatio(
              received: received,
              total: total,
              expectedBytes: expected[i],
            );
            final double overall =
                (completedWeight + streamRatio * weights[i]).clamp(0.0, 1.0);
            onProgress(overall);
          },
        );
        completedWeight += weights[i];
        onProgress(completedWeight.clamp(0.0, 1.0));
        paths.add(target.path);
      }

      // DASH 音视频分离流：下载完成后用 ffmpeg 无损封装为单个 MP4
      //（参考 Bili23-Downloader 的做法，-c copy 不重编码，秒级完成）。
      // 封装失败（ffmpeg 异常/平台不支持）时回退为保留两个分轨文件。
      final bool isSeparatedVideo = item.streams.length == 2 &&
          paths.length == 2 &&
          !item.isAudioOnly &&
          item.streams.where((s) => !s.isAudio).length == 1;
      if (isSeparatedVideo) {
        final quality = item.qualityCode > 0 ? '_${item.qualityCode}' : '';
        final mergedPath =
            '${folder.path}${Platform.pathSeparator}$baseName$quality.mp4';
        final merged = await mergeStreamsIntoMp4(
          paths[0],
          paths[1],
          mergedPath,
          cancelToken: cancelToken,
        );
        if (merged) {
          // 成功后删除临时分轨文件，只留一个可直接分享/播放的 mp4
          for (final path in paths) {
            try {
              final file = File(path);
              if (await file.exists()) await file.delete();
            } catch (_) {}
          }
          // 登记进公共媒体库，文件管理器/相册可直接看到；失败回退私有目录原文件。
          final exported = await _registerToPublicGallery(
            mergedPath,
            isAudio: false,
          );
          return DownloadResult(
            paths: [exported ?? mergedPath],
            exportedToGallery: exported != null,
          );
        }
      }
      // 一体 MP4 / 仅音频 / 封装失败回退的分轨：逐个登记到公共媒体库。
      final exportedPaths = <String>[];
      var exportedAny = false;
      for (var i = 0; i < paths.length; i++) {
        final isAudio = paths.length > 1
            ? (i < item.streams.length && item.streams[i].isAudio)
            : item.isAudioOnly;
        final exported = await _registerToPublicGallery(
          paths[i],
          isAudio: isAudio,
        );
        if (exported != null) exportedAny = true;
        exportedPaths.add(exported ?? paths[i]);
      }
      return DownloadResult(paths: exportedPaths, exportedToGallery: exportedAny);
    } catch (e) {
      // 失败/取消时清理已落盘的半成品，避免留下无声/无画面的残缺文件
      for (final path in paths) {
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// 下载文件所在文件夹（B站下载 子目录）。供"打开所在文件夹"复用。
  static Future<Directory> downloadDirectory() async {
    final base = await _resolveDownloadDir();
    final folder = Directory('${base.path}${Platform.pathSeparator}B站下载');
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }
    return folder;
  }

  static Future<Directory> _resolveDownloadDir() async {
    if (Platform.isAndroid || Platform.isIOS) {
      // 应用专属外部目录，Android 10+ 无需存储权限即可写入。
      final dir = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      return dir;
    }
    return await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
  }

  /// 下载完成后把成品文件登记到公共媒体库（仅 Android 实际落库）。
  ///
  /// 源文件先写在 App 专属目录以保证离线播放/外部音轨路径稳定；这里再复制
  /// 一份到公共 Movies/Music 目录并写入 MediaStore，系统文件管理器、相册、
  /// 其它播放器即可直接看到。
  ///
  /// 登记成功后删除私有目录原件，避免同一视频占两份空间；返回公共存储下的
  /// 真实路径。登记失败返回 null，调用方继续使用私有目录原文件，不影响下载结果。
  static Future<String?> _registerToPublicGallery(
    String privatePath, {
    required bool isAudio,
  }) async {
    if (!Platform.isAndroid) return null;
    try {
      final file = File(privatePath);
      if (!await file.exists()) return null;
      final displayName = file.uri.pathSegments.last;
      final exported = await MediaStoreExporter.exportFile(
        filePath: privatePath,
        displayName: displayName,
        kind: isAudio ? MediaStoreKind.audio : MediaStoreKind.video,
        subDir: 'PiliPala',
      );
      if (exported != null && exported.isNotEmpty) {
        // 公共副本已落地，删除私有原件回收空间；删不掉不影响公共副本使用。
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
        return exported;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 在系统文件管理器中定位到某个已下载文件；filePath 为空时打开下载文件夹。
  ///
  /// 返回 null 表示成功拉起；返回非 null 字符串为给用户的兜底提示
  /// （如"路径已复制到剪贴板"），由调用方 toast。
  ///
  /// 平台差异：
  /// - 桌面端：file:// / 目录 URI 直接拉起资源管理器；
  /// - Android 7+：系统禁止 file:// 直开，改用 share_plus 系统分享面板
  ///   （内部走 FileProvider，用户可选文件管理器或其它应用打开）。
  static Future<String?> openDownloadLocation({String? filePath}) async {
    if (kIsWeb) return '当前平台不支持打开文件';
    try {
      if (filePath != null && filePath.isNotEmpty) {
        final file = File(filePath);
        if (await file.exists()) {
          if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
            final uri = Uri.file(filePath, windows: Platform.isWindows);
            if (await canLaunchUrl(uri)) {
              final ok = await launchUrl(uri, mode: LaunchMode.platformDefault);
              return ok ? null : null; // 桌面端拉起即算成功
            }
          }
          // 移动端：系统分享面板打开（可靠，FileProvider 由 share_plus 处理）
          try {
            await Share.shareXFiles(
              [XFile(filePath)],
              text: 'B站下载文件',
            );
          } catch (_) {
            // 用户关闭分享面板等场景不影响结果判定
          }
          return null;
        }
      }
      final folder = await downloadDirectory();
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        final uri = Uri.directory(folder.path, windows: Platform.isWindows);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.platformDefault);
          return null;
        }
      }
      // 移动端没有直接打开文件夹的通道：把路径复制到剪贴板兜底
      await Clipboard.setData(ClipboardData(text: folder.path));
      return '文件在：${folder.path}（路径已复制）';
    } catch (_) {
      return '打开失败，请在「离线缓存」中查看';
    }
  }

  /// 用 ffmpeg 把分离的视频/音频流无损封装成单个 MP4。
  ///
  /// 返回 true 表示封装成功；返回 false 表示封装失败
  /// （ffmpeg 运行出错或当前平台不支持 ffmpeg），上层回退为保留分轨文件。
  /// 用户已取消时抛 HttpException，与下载阶段取消语义一致。
  static Future<bool> mergeStreamsIntoMp4(
    String videoPath,
    String audioPath,
    String outputPath, {
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) {
      throw const HttpException('已取消');
    }
    final args = buildMuxArgs(videoPath, audioPath, outputPath);
    try {
      final session = await FFmpegKit.executeWithArguments(args);
      final code = await session.getReturnCode();
      if (ReturnCode.isSuccess(code)) return true;
    } catch (_) {
      // ffmpeg_kit 只在 Android/iOS/macOS 有原生实现；桌面端缺插件时
      // 退回调用系统 PATH 里的 ffmpeg（参数完全一致），失败才真正回退。
      if (!kIsWeb &&
          (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
        if (await _mergeWithSystemFfmpeg(args, outputPath)) return true;
      }
    }
    // ffmpeg 报错或平台不支持时可能已写出半成品，删掉避免留下打不开的 mp4
    try {
      final partial = File(outputPath);
      if (await partial.exists()) await partial.delete();
    } catch (_) {}
    return false;
  }

  /// 桌面端兜底：调用系统 ffmpeg 可执行文件（需本机已安装并在 PATH 中）。
  static Future<bool> _mergeWithSystemFfmpeg(
    List<String> args,
    String outputPath,
  ) async {
    try {
      final result = await Process.run('ffmpeg', args);
      if (result.exitCode != 0) return false;
      final output = File(outputPath);
      return await output.exists() && await output.length() > 0;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _downloadWithRetry(
    String url,
    File target, {
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
    int attempts = 3,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < attempts; attempt++) {
      // 取消后不再重试
      if (cancelToken?.isCancelled ?? false) {
        throw const HttpException('已取消');
      }
      try {
        final cookie = Request.dio.options.headers['cookie']?.toString() ?? '';
        final dio = Dio(
          BaseOptions(
            headers: <String, dynamic>{
              'referer': 'https://www.bilibili.com/',
              'user-agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
              // 关键：禁止 CDN 再做 gzip/br，否则 Range 与实际写入字节错位
              'Accept-Encoding': 'identity',
              if (cookie.isNotEmpty) 'cookie': cookie,
            },
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 30),
            followRedirects: true,
          ),
        );
        await dio.download(
          url,
          target.path,
          cancelToken: cancelToken,
          onReceiveProgress: onProgress,
        );
        return;
      } catch (e) {
        // 用户取消：立即退出，绝不重试
        if (cancelToken?.isCancelled ?? false) {
          rethrow;
        }
        lastError = e;
        if (attempt < attempts - 1) {
          await Future.delayed(Duration(seconds: 1 << attempt));
        }
      }
    }
    throw lastError ?? const HttpException('下载失败');
  }
}

/// 仅用于异常兜底的最小实现，避免额外 import http 包。
class HttpException implements Exception {
  const HttpException(this.message);
  final String message;
  @override
  String toString() => message;
}
