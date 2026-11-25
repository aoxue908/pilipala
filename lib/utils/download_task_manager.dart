import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// 单个下载任务的实时状态 + 展示元信息。
class DownloadTaskSnapshot {
  const DownloadTaskSnapshot({
    required this.key,
    required this.downloading,
    required this.title,
    required this.pic,
    required this.qualityLabel,
    required this.formatTitle,
    required this.bvid,
    required this.cid,
    this.progress = 0.0,
    this.error,
  });

  /// 任务标识（bvid_cid_itemId），取消/删除操作都靠它。
  final String key;
  final bool downloading;
  final double progress;
  final String? error;
  final String title;
  final String pic;
  final String qualityLabel;
  final String formatTitle;
  final String bvid;
  final int cid;

  DownloadTaskSnapshot copyWith({double? progress, bool? downloading}) {
    return DownloadTaskSnapshot(
      key: key,
      downloading: downloading ?? this.downloading,
      title: title,
      pic: pic,
      qualityLabel: qualityLabel,
      formatTitle: formatTitle,
      bvid: bvid,
      cid: cid,
      progress: progress ?? this.progress,
      error: error,
    );
  }
}

/// 全局下载任务状态管理器（单例）。
///
/// 为什么必须是全局：下载状态绝不能放在下载面板的 State 里。
/// 面板一关 State 就 dispose，进度、"下载中"状态全部丢失；重新打开
/// 面板又显示成未下载，用户再点一次会重复下载同一个文件。
/// 这里如实记录每个任务的实时状态，面板和「离线缓存」页都是观察者，
/// 下载任务本身也不再依赖面板是否还活着。
class DownloadTaskManager {
  DownloadTaskManager._();
  static final DownloadTaskManager instance = DownloadTaskManager._();

  /// key 用 bvid_cid_itemId（与下载记录 id 一致），避免不同视频的同名格式串台。
  final ValueNotifier<Map<String, DownloadTaskSnapshot>> state =
      ValueNotifier<Map<String, DownloadTaskSnapshot>>({});

  /// 每个任务的取消令牌：交给 dio.download，取消时中断网络流并清理半成品。
  final Map<String, CancelToken> _cancelTokens = {};

  bool isDownloading(String key) => state.value[key]?.downloading ?? false;

  double progressOf(String key) {
    final snapshot = state.value[key];
    return snapshot == null ? 0.0 : snapshot.progress;
  }

  /// 当前所有下载中的任务（供「离线缓存」页展示进行中卡片）。
  List<DownloadTaskSnapshot> activeTasks() {
    return state.value.values.where((s) => s.downloading).toList();
  }

  void markDownloading(
    String key, {
    required String title,
    String pic = '',
    String qualityLabel = '',
    String formatTitle = '',
    String bvid = '',
    int cid = 0,
  }) {
    _cancelTokens[key] = CancelToken();
    state.value = <String, DownloadTaskSnapshot>{
      ...state.value,
      key: DownloadTaskSnapshot(
        key: key,
        downloading: true,
        progress: 0,
        title: title,
        pic: pic,
        qualityLabel: qualityLabel,
        formatTitle: formatTitle,
        bvid: bvid,
        cid: cid,
      ),
    };
  }

  void updateProgress(String key, double ratio) {
    final current = state.value[key];
    if (current == null || !current.downloading) return;
    final double clamped = ratio.clamp(0.0, 1.0);
    // 合并后的整体进度单调递增；这里保留防倒退保护，避免抖动。
    if (clamped <= current.progress) return;
    state.value = <String, DownloadTaskSnapshot>{
      ...state.value,
      key: current.copyWith(progress: clamped),
    };
  }

  /// 取消某个下载任务：dio 立即中断网络流，上层负责清理半成品与移除状态。
  void cancelTask(String key) {
    _cancelTokens[key]?.cancel('用户取消');
  }

  /// 任务的取消令牌：下载发起时传给 dio.download。
  CancelToken? tokenOf(String key) => _cancelTokens[key];

  /// 该任务是否已被取消（供上层区分"失败"与"用户取消"提示语）。
  bool isCancelled(String key) => _cancelTokens[key]?.isCancelled ?? false;

  void markDone(String key) {
    _cancelTokens.remove(key);
    final current = state.value[key];
    if (current == null) return;
    state.value = <String, DownloadTaskSnapshot>{
      ...state.value,
      key: current.copyWith(downloading: false, progress: 1),
    };
  }

  void markFailed(String key) {
    _cancelTokens.remove(key);
    if (!state.value.containsKey(key)) return;
    final next = Map<String, DownloadTaskSnapshot>.from(state.value);
    next.remove(key);
    state.value = next;
  }
}
