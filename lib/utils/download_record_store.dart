import 'dart:io';

import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:pilipala/models/download/download_record.dart';
import 'package:pilipala/utils/media_store_exporter.dart';
import 'package:pilipala/utils/storage.dart';

/// 下载记录的 Hive 读写封装。
///
/// 每个 key 是一条记录，value 是 DownloadRecord.toJson() 的普通 Map，
/// 不引入 TypeAdapter / generated code，方便升级和单测。
class DownloadRecordStore {
  static Box<dynamic> get _box => GStrorage.downloads;

  /// 记录发生变化时自增，供页面 Obx 监听刷新（避免依赖 Hive listenable API）。
  static final RxInt revision = 0.obs;

  static void _notifyChanged() => revision.value++;

  /// 列表按下载时间倒序，最新在最前。
  static List<DownloadRecord> list() {
    final result = _box.values
        .whereType<Map>()
        .map((map) => DownloadRecord.fromJson(map))
        .toList();
    result.sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
    return result;
  }

  static DownloadRecord? get(String id) {
    final value = _box.get(id);
    if (value is Map) return DownloadRecord.fromJson(value);
    return null;
  }

  /// 查某个视频某个格式是否已下载且文件仍存在；返回最近的一条有效记录。
  static DownloadRecord? findDownloaded({
    required String bvid,
    required int cid,
    required String formatId,
  }) {
    final candidates = list().where(
      (r) => r.bvid == bvid && r.cid == cid && r.formatId == formatId,
    );
    for (final record in candidates) {
      if (record.files.isEmpty) continue;
      var allExist = true;
      for (final file in record.files) {
        if (file.path.isEmpty || !File(file.path).existsSync()) {
          allExist = false;
          break;
        }
      }
      if (allExist) return record;
    }
    return null;
  }

  static Future<void> add(DownloadRecord record) async {
    await _box.put(record.id, record.toJson());
    _notifyChanged();
  }

  /// 生成记录 id：【必须确定性】= bvid_cid_itemId。
  ///
  /// 历史教训：曾掺入时间戳导致同一格式的每次调用都拿到不同 id——
  /// 下载面板的防重入检查（isDownloading(key)）永远不命中，多点几次按钮
  /// 就开出多个并发下载；进度查询也因 key 变化永远读到 0%。
  /// 同一视频同一格式重复下载时，同 id 记录直接覆盖（文件同名覆盖），语义正确。
  static String makeId({
    required String bvid,
    required int cid,
    required String itemId,
  }) {
    return '${bvid}_${cid}_$itemId';
  }

  /// 删除记录并清理对应本地文件；文件不存在时静默跳过。
  static Future<void> delete(String id) async {
    final record = get(id);
    if (record != null) {
      for (final file in record.files) {
        await _removeLocalFile(file.path);
      }
    }
    await _box.delete(id);
    _notifyChanged();
  }

  /// 清空全部记录及其文件。
  static Future<void> clear() async {
    for (final id in _box.keys.toList()) {
      final record = get(id.toString());
      if (record != null) {
        for (final file in record.files) {
          await _removeLocalFile(file.path);
        }
      }
    }
    await _box.clear();
    _notifyChanged();
  }

  /// 删除单个本地文件：公共媒体库副本走 MediaStore 移除；
  /// 私有目录文件直接 File.delete。任一步失败都静默跳过，不影响记录移除。
  static Future<void> _removeLocalFile(String path) async {
    if (path.isEmpty) return;
    try {
      // 先按公共媒体库路径删除（Android 上非私有目录的副本）。
      final removed = await MediaStoreExporter.deleteFromMediaStore(path);
      if (removed) return;
      final entity = File(path);
      if (await entity.exists()) await entity.delete();
    } catch (_) {
      // 文件被占用或已删除都不影响记录移除
    }
  }
}
