import 'package:get/get.dart';
import 'package:pilipala/models/download/download_record.dart';
import 'package:pilipala/utils/download_record_store.dart';
import 'package:pilipala/utils/download_task_manager.dart';

/// 「离线缓存」列表控制器：数据来自本地 Hive 记录 + 全局下载任务状态。
class DownloadController extends GetxController {
  final RxList<DownloadRecord> records = <DownloadRecord>[].obs;
  /// 正在下载中的任务（含实时进度），与已完成记录分开展示。
  final RxList<DownloadTaskSnapshot> activeTasks = <DownloadTaskSnapshot>[].obs;

  Worker? _revisionWorker;

  DownloadTaskManager get _tasks => DownloadTaskManager.instance;

  @override
  void onInit() {
    super.onInit();
    refreshRecords();
    _refreshActiveTasks();
    // 下载在别的页面完成，返回本页时通过 revision 自动同步最新记录。
    _revisionWorker = ever(DownloadRecordStore.revision, (_) => refreshRecords());
    // 全局下载进度/状态变化（含面板关闭后仍在后台下载的任务）实时刷新。
    _tasks.state.addListener(_refreshActiveTasks);
  }

  @override
  void onClose() {
    _revisionWorker?.dispose();
    _tasks.state.removeListener(_refreshActiveTasks);
    super.onClose();
  }

  void _refreshActiveTasks() {
    activeTasks.value = _tasks.activeTasks();
  }

  void refreshRecords() {
    records.value = DownloadRecordStore.list();
  }

  Future<void> delete(String id) async {
    await DownloadRecordStore.delete(id);
    refreshRecords();
  }

  Future<void> clear() async {
    await DownloadRecordStore.clear();
    refreshRecords();
  }
}
