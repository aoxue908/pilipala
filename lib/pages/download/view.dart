import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:pilipala/common/widgets/network_img_layer.dart';
import 'package:pilipala/common/widgets/no_data.dart';
import 'package:pilipala/models/download/download_record.dart';
import 'package:pilipala/utils/download_task_manager.dart';
import 'package:pilipala/utils/utils.dart';
import 'package:pilipala/utils/video_download.dart';

import 'controller.dart';

/// 离线缓存页：展示所有已下载视频，可播放、可删除、可清空。
class DownloadPage extends StatelessWidget {
  const DownloadPage({super.key});

  @override
  Widget build(BuildContext context) {
    final DownloadController controller = Get.put(DownloadController());

    return Scaffold(
      appBar: AppBar(
        title: const Text('离线缓存'),
        actions: [
          Obx(
            () => controller.records.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: '清空全部',
                    icon: const Icon(Icons.delete_sweep_outlined),
                    onPressed: () => _confirmClear(context, controller),
                  ),
          ),
        ],
      ),
      body: Obx(
        () {
          final active = controller.activeTasks;
          final records = controller.records;
          if (active.isEmpty && records.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.only(bottom: 60),
                child: NoData(),
              ),
            );
          }
          // 下载中的任务排在前面，实时显示进度；已完成的记录在后。
          final int total = active.length + records.length;
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            itemCount: total,
            separatorBuilder: (_, __) => const SizedBox(height: 2),
            itemBuilder: (context, index) {
              if (index < active.length) {
                return _DownloadingItem(task: active[index]);
              }
              final record = records[index - active.length];
              return _DownloadRecordItem(
                record: record,
                onPlay: () => _playRecord(record),
                onDelete: () => _confirmDelete(context, controller, record),
              );
            },
          );
        },
      ),
      floatingActionButton: Obx(
        () => controller.records.isEmpty
            ? const SizedBox.shrink()
            : FloatingActionButton.small(
                tooltip: '仅刷新列表',
                onPressed: controller.refreshRecords,
                child: const Icon(Icons.refresh),
              ),
      ),
    );
  }

  /// 点击记录：把本地文件路径交给详情页直接播放，不再走网络取流。
  void _playRecord(DownloadRecord record) {
    final videoPath = record.videoPath;
    if (videoPath == null || videoPath.isEmpty) {
      SmartDialog.showToast('该记录没有可播放的视频文件');
      return;
    }
    // DASH 音视频分离的记录在播放器侧会自动挂载外部音轨，无需提示无声。
    Get.toNamed(
      '/video?bvid=${record.bvid}&cid=${record.cid}',
      arguments: <String, dynamic>{
        'heroTag': Utils.makeHeroTag(record.bvid),
        'pic': record.pic,
        'title': record.title,
        'durationMs': record.durationSeconds * 1000,
        'sourceType': 'normal',
        'localVideoPath': videoPath,
        'localAudioPath': record.audioPath,
      },
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    DownloadController controller,
    DownloadRecord record,
  ) async {
    final confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('删除下载'),
        content: Text(
          '删除「${record.title}」的下载记录和本地文件？此操作不可恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.delete(record.id);
    if (context.mounted) SmartDialog.showToast('已删除');
  }

  Future<void> _confirmClear(
    BuildContext context,
    DownloadController controller,
  ) async {
    final confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('清空离线缓存'),
        content: const Text('将删除全部下载记录和对应的本地文件，此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.clear();
    if (context.mounted) SmartDialog.showToast('已清空');
  }
}

/// 下载中的任务卡片：封面 + 标题 + 清晰度 + 实时进度条。
/// 与已完成记录同处一个列表，让用户明确看到"正在下载什么、进度多少"。
class _DownloadingItem extends StatelessWidget {
  const _DownloadingItem({required this.task});

  final DownloadTaskSnapshot task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final percent = (task.progress * 100).round();
    return Card(
      elevation: 0,
      color: theme.colorScheme.primary.withOpacity(0.07),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 126,
                height: 80,
                child: task.pic.isNotEmpty
                    ? NetworkImgLayer(
                        src: task.pic,
                        width: 126,
                        height: 80,
                      )
                    : Container(
                        color: theme.colorScheme.surfaceVariant,
                        child: const Icon(Icons.movie_outlined),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: 80,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        if (task.qualityLabel.isNotEmpty)
                          _Tag(text: task.qualityLabel, theme: theme),
                        const SizedBox(width: 6),
                        Text(
                          '正在下载 $percent%',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const Spacer(),
                        // 取消按钮：中断下载并清理半成品文件
                        SizedBox(
                          width: 30,
                          height: 30,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            iconSize: 18,
                            tooltip: '取消下载',
                            icon: Icon(
                              Icons.close,
                              color: theme.colorScheme.outline,
                            ),
                            onPressed: () {
                              DownloadTaskManager.instance.cancelTask(task.key);
                              SmartDialog.showToast('正在取消下载…');
                            },
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    LinearProgressIndicator(
                      value: task.progress > 0 ? task.progress : null,
                      minHeight: 4,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DownloadRecordItem extends StatelessWidget {
  const _DownloadRecordItem({
    required this.record,
    required this.onPlay,
    required this.onDelete,
  });

  final DownloadRecord record;
  final VoidCallback onPlay;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.onInverseSurface.withOpacity(0.12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPlay,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 126,
                  height: 80,
                  child: record.pic.isNotEmpty
                      ? NetworkImgLayer(
                          src: record.pic,
                          width: 126,
                          height: 80,
                        )
                      : Container(
                          color: theme.colorScheme.surfaceVariant,
                          child: const Icon(Icons.movie_outlined),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 80,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        record.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          if (record.qualityLabel.isNotEmpty)
                            _Tag(text: record.qualityLabel, theme: theme),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              record.formatTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      Text(
                        '${record.totalSize > 0 ? '${formatDownloadSize(record.totalSize)} · ' : ''}'
                        '${record.files.length} 个文件 · ${_formatTime(record.downloadedAt)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: '删除',
                icon: Icon(
                  Icons.delete_outline,
                  size: 20,
                  color: theme.colorScheme.outline,
                ),
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(int milliseconds) {
    if (milliseconds <= 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    final now = DateTime.now();
    final hhmm =
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    if (date.year == now.year &&
        date.month == now.month &&
        date.day == now.day) {
      return '今天 $hhmm';
    }
    return '${date.month}月${date.day}日 $hhmm';
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.theme});

  final String text;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
