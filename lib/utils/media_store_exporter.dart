import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// 媒体类型：决定写入哪一个 MediaStore 集合。
/// - video：MediaStore.Video，进 Movies/<relativeSubDir>/
/// - audio：MediaStore.Audio，进 Music/<relativeSubDir>/
enum MediaStoreKind { video, audio }

/// 把已下载的成品媒体登记进系统公共媒体库（MediaStore）。
///
/// 背景：Dart 下载先落在 App 专属外部目录（Android/data/<包名>/files/...），
/// 该目录被分区存储隔离，系统文件管理器的“最近/视频”默认扫描不到。
/// 本封装在 Android 上把文件复制（登记）到公共的 Movies / Music 目录，
/// 让文件管理器、相册、其它播放器都能直接看到；桌面与 iOS 无需处理。
///
/// 失败一律静默回退：返回 null，调用方继续使用私有目录里的原文件。
class MediaStoreExporter {
  MediaStoreExporter._();

  static const MethodChannel _channel = MethodChannel('pilipala/media_store');

  /// 媒体类型：决定写入哪一个 MediaStore 集合。
  /// - video：MediaStore.Video，进 Movies/<relativeSubDir>/
  /// - audio：MediaStore.Audio，进 Music/<relativeSubDir>/
  static String _kindName(MediaStoreKind kind) =>
      kind == MediaStoreKind.video ? 'video' : 'audio';

  /// 下载完成后在 Android 上申请一次对应媒体的读取权限。
  ///
  /// Android 13+ 细粒度权限：视频走 Permission.videos，音频走 Permission.audio；
  /// 低版本走 Permission.storage。被拒/永久拒绝不抛错，仅返回 false，
  /// 后续登记若因此失败，调用方按回退处理。
  static Future<bool> _ensurePermission(MediaStoreKind kind) async {
    if (!Platform.isAndroid) return true;
    try {
      final permission = await _resolvePermission(kind);
      final status = await permission.status;
      if (status.isGranted) return true;
      final requested = await permission.request();
      return requested.isGranted;
    } catch (_) {
      return false;
    }
  }

  static Future<Permission> _resolvePermission(MediaStoreKind kind) async {
    // Android 13+ 细粒度媒体权限；低版本（<33）没有 videos/audio 权限，
    // 回退到通用存储权限（READ/WRITE_EXTERNAL_STORAGE 已在 manifest 声明）。
    try {
      final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
      if (sdk >= 33) {
        return kind == MediaStoreKind.video ? Permission.videos : Permission.audio;
      }
    } catch (_) {}
    return Permission.storage;
  }

  /// 把 [filePath] 登记进公共媒体库。
  ///
  /// [displayName] 为媒体库中展示的文件名（含扩展名）；
  /// [subDir] 为相对 Movies/Music 下的子文件夹名（按应用名归集），默认“PiliPala”。
  ///
  /// 成功返回公共存储下的真实文件路径（DATA 列）；失败返回 null。
  static Future<String?> exportFile({
    required String filePath,
    required String displayName,
    required MediaStoreKind kind,
    String subDir = 'PiliPala',
  }) async {
    if (!Platform.isAndroid) return null;
    final file = File(filePath);
    if (!await file.exists()) return null;

    if (!await _ensurePermission(kind)) {
      return null;
    }

    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'exportToMediaStore',
        <String, dynamic>{
          'filePath': filePath,
          'displayName': displayName,
          'subDir': subDir,
          'kind': _kindName(kind),
        },
      );
      final savedPath = result?['path']?.toString();
      if (savedPath != null && savedPath.isNotEmpty) return savedPath;
      return null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 按公共存储路径删除 MediaStore 中的媒体记录及其文件。
  ///
  /// 私有目录文件仍由调用方用 `File.delete()` 处理；本方法只负责清理已经
  /// 登记进公共媒体库的副本。删除成功返回 true；找不到记录或失败返回 false。
  static Future<bool> deleteFromMediaStore(String publicPath) async {
    if (!Platform.isAndroid || publicPath.isEmpty) return false;
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'deleteFromMediaStore',
        <String, dynamic>{'path': publicPath},
      );
      return result?['deleted'] == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
