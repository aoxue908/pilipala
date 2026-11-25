import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:pilipala/models/download/download_record.dart';
import 'package:pilipala/models/video/play/url.dart';
import 'package:pilipala/utils/download_record_store.dart';
import 'package:pilipala/utils/download_task_manager.dart';
import 'package:pilipala/utils/video_download.dart';

/// 视频下载选择面板：下拉框选分辨率 + 单个主下载按钮的紧凑设计。
///
/// 交互：
/// - 下拉框列出全部格式（清晰度倒序 + 各音频轨），默认选中最高清晰度；
/// - 信息行显示当前选中格式的编码/尺寸/体积；
/// - 主按钮三态：未下载=下载、下载中=进度+取消、已下载=打开所在位置。
void showVideoDownloadSheet({
  required BuildContext context,
  required PlayUrlModel playUrl,
  required String title,
  String bvid = '',
  int cid = 0,
  String pic = '',
  int durationSeconds = 0,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (modalContext) => VideoDownloadSheet(
      playUrl: playUrl,
      title: title,
      bvid: bvid,
      cid: cid,
      pic: pic,
      durationSeconds: durationSeconds,
    ),
  );
}

class VideoDownloadSheet extends StatefulWidget {
  const VideoDownloadSheet({
    required this.playUrl,
    required this.title,
    this.bvid = '',
    this.cid = 0,
    this.pic = '',
    this.durationSeconds = 0,
    super.key,
  });

  final PlayUrlModel playUrl;
  final String title;
  final String bvid;
  final int cid;
  final String pic;
  final int durationSeconds;

  @override
  State<VideoDownloadSheet> createState() => _VideoDownloadSheetState();
}

class _VideoDownloadSheetState extends State<VideoDownloadSheet> {
  late final List<VideoDownloadItem> _items;
  /// 当前下拉框选中的格式（默认最高清晰度；列表为空时不初始化）。
  late VideoDownloadItem _selected;
  /// 已下载格式 → 本地文件路径（首个视频文件），用于把按钮切成"打开文件夹"态。
  final Map<String, String> _downloadedPath = {};

  /// 全局下载状态的 key（bvid_cid_itemId），与下载记录 id 一致。
  String _taskKey(String itemId) => DownloadRecordStore.makeId(
        bvid: widget.bvid,
        cid: widget.cid,
        itemId: itemId,
      );

  DownloadTaskManager get _tasks => DownloadTaskManager.instance;

  @override
  void initState() {
    super.initState();
    _items = buildVideoDownloadItems(widget.playUrl);
    if (_items.isNotEmpty) _selected = _items.first;
    _refreshDownloadedState();
    // 监听全局下载状态：面板关掉再打开、或下载在后台完成时，进度/状态都能刷新。
    _tasks.state.addListener(_onTasksChanged);
  }

  @override
  void dispose() {
    _tasks.state.removeListener(_onTasksChanged);
    super.dispose();
  }

  void _onTasksChanged() {
    if (mounted) setState(() {});
  }

  /// 从下载记录回查每个格式是否已落盘且文件仍存在。
  void _refreshDownloadedState() {
    _downloadedPath.clear();
    for (final item in _items) {
      final record = DownloadRecordStore.findDownloaded(
        bvid: widget.bvid,
        cid: widget.cid,
        formatId: item.id,
      );
      if (record != null) {
        _downloadedPath[item.id] = record.videoPath ?? record.audioPath ?? '';
      }
    }
  }

  /// 打开某个已下载格式的所在位置。
  Future<void> _openLocation(String itemId) async {
    final path = _downloadedPath[itemId];
    final hint = await VideoDownloadService.openDownloadLocation(filePath: path);
    if (!mounted) return;
    if (hint != null) SmartDialog.showToast(hint);
  }

  /// 跳转到 App 内的「离线缓存」列表（与底部“打开所在位置”区分开）。
  void _goToCacheList() {
    Navigator.of(context).pop();
    Get.toNamed('/download');
  }

  Future<void> _startDownload(VideoDownloadItem item) async {
    final key = _taskKey(item.id);
    if (_tasks.isDownloading(key)) return;
    _tasks.markDownloading(
      key,
      title: widget.title,
      pic: widget.pic,
      qualityLabel: item.title,
      formatTitle: item.subtitle,
      bvid: widget.bvid,
      cid: widget.cid,
    );

    try {
      final result = await VideoDownloadService.download(
        item,
        title: '${widget.title}_${item.id}',
        cancelToken: _tasks.tokenOf(key),
        onProgress: (ratio) {
          // 进度写入全局状态：即使面板已关闭也不影响写记录，重开面板仍可见。
          _tasks.updateProgress(key, ratio);
        },
      );
      final paths = result.paths;
      // 关键：下载完成必须先写记录，不能因为面板已关闭（!mounted）就跳过。
      // 否则关掉面板后下载其实完成了，记录却没落盘，重开面板永远看不到已下载态。
      await _saveRecord(item, paths);
      _tasks.markDone(key);
      _refreshDownloadedState();
      if (!mounted) return;
      setState(() {});
      final galleryDir = item.isAudioOnly ? 'Music/PiliPala' : 'Movies/PiliPala';
      SmartDialog.showToast(
        result.exportedToGallery
            ? (paths.length > 1
                ? '已保存 ${paths.length} 个文件，可在系统「$galleryDir」或离线缓存查看'
                : '已保存，可在系统「$galleryDir」或离线缓存查看')
            : (paths.length > 1
                ? '已保存 ${paths.length} 个文件，可在「离线缓存」查看'
                : '已保存，可在「离线缓存」查看'),
      );
    } catch (e) {
      final bool cancelled = _tasks.isCancelled(key);
      _tasks.markFailed(key);
      _refreshDownloadedState();
      if (!mounted) return;
      setState(() {});
      SmartDialog.showToast(cancelled ? '已取消下载' : '下载失败：$e');
    }
  }

  /// 把本次下载落盘的文件写成一条可展示、可播放、可删除的记录。
  ///
  /// 注意：DASH 分离流下载后会经 ffmpeg 合并为单个 mp4（临时分轨已删除），
  /// 所以扩展名/音频标记必须按【最终文件】推导，不能直接套 streams。
  Future<void> _saveRecord(VideoDownloadItem item, List<String> paths) async {
    final files = <DownloadFileRecord>[];
    for (var i = 0; i < paths.length; i++) {
      final ext = paths[i].split('.').last.toLowerCase();
      // 多文件回退时按流的角色标记；单文件（一体 mp4 / 合并 mp4）按格式项判断
      final bool isAudio = paths.length > 1
          ? (i < item.streams.length && item.streams[i].isAudio)
          : item.isAudioOnly;
      var size = 0;
      try {
        size = await File(paths[i]).length();
      } catch (_) {
        // 读不到真实大小就退回估算值
        size = i < item.streams.length
            ? item.streams[i].estimatedSize
            : item.estimatedSize;
      }
      files.add(
        DownloadFileRecord(
          path: paths[i],
          extension: ext,
          isAudio: isAudio,
          size: size,
        ),
      );
    }

    final record = DownloadRecord(
      id: DownloadRecordStore.makeId(
        bvid: widget.bvid,
        cid: widget.cid,
        itemId: item.id,
      ),
      bvid: widget.bvid,
      cid: widget.cid,
      title: widget.title,
      pic: widget.pic,
      qualityLabel: item.title,
      formatTitle: item.subtitle,
      totalSize: files.fold(0, (sum, file) => sum + file.size),
      files: files,
      downloadedAt: DateTime.now().millisecondsSinceEpoch,
      durationSeconds: widget.durationSeconds,
      sourceType: item.id.startsWith('durl') ? 'durl' : 'dash',
      formatId: item.id,
    );
    await DownloadRecordStore.add(record);
  }

  /// 下拉框右侧的短元信息：视频取「编码 · 分辨率」，音频取音质档。
  String _dropdownMeta(VideoDownloadItem item) {
    final parts = item.subtitle.split(' · ');
    if (item.isAudioOnly) return parts.isNotEmpty ? parts.first : '';
    return parts.length >= 2 ? '${parts[0]} · ${parts[1]}' : item.subtitle;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenH = MediaQuery.of(context).size.height;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: screenH * 0.82),
      child: Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 顶部把手
            Container(
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outline.withOpacity(0.35),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '下载视频',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            if (_items.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  '暂无可用格式',
                  style: TextStyle(color: theme.colorScheme.outline),
                ),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildQualityDropdown(theme),
                      const SizedBox(height: 10),
                      _buildSelectedInfo(theme),
                      const SizedBox(height: 16),
                      _buildMainAction(theme),
                    ],
                  ),
                ),
              ),
            SizedBox(height: MediaQuery.of(context).viewInsets.bottom),
          ],
        ),
      ),
    );
  }

  /// 分辨率下拉框：全部格式（清晰度倒序 + 音频轨），默认选中最高清晰度。
  Widget _buildQualityDropdown(ThemeData theme) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outline.withOpacity(0.2),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<VideoDownloadItem>(
          value: _selected,
          isExpanded: true,
          borderRadius: BorderRadius.circular(12),
          icon: Icon(
            Icons.expand_more,
            color: theme.colorScheme.outline,
          ),
          items: _items
              .map(
                (item) => DropdownMenuItem<VideoDownloadItem>(
                  value: item,
                  child: Row(
                    children: [
                      Icon(
                        item.isAudioOnly
                            ? Icons.audiotrack_outlined
                            : Icons.movie_outlined,
                        size: 18,
                        color: theme.colorScheme.outline,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _dropdownMeta(item),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value == null || value.id == _selected.id) return;
            setState(() => _selected = value);
          },
        ),
      ),
    );
  }

  /// 当前选中格式的详情行：编码/尺寸/音频档 · 估算体积；已下载时补状态提示。
  Widget _buildSelectedInfo(ThemeData theme) {
    final key = _taskKey(_selected.id);
    final downloaded =
        !_tasks.isDownloading(key) && _downloadedPath.containsKey(_selected.id);
    final sizeText = _selected.estimatedSize > 0
        ? ' · 约 ${formatDownloadSize(_selected.estimatedSize)}'
        : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.info_outline,
              size: 14,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${_selected.subtitle}$sizeText',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          ],
        ),
        if (downloaded)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: InkWell(
              onTap: _goToCacheList,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle,
                      size: 14,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '该格式已下载',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      Icons.video_library_outlined,
                      size: 14,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '视频缓存',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 主下载按钮三态：
  /// 未下载=全宽下载按钮；下载中=进度条+取消；已下载=打开所在位置。
  Widget _buildMainAction(ThemeData theme) {
    final item = _selected;
    final key = _taskKey(item.id);
    final downloading = _tasks.isDownloading(key);
    final progress = _tasks.progressOf(key);
    final downloaded = !downloading && _downloadedPath.containsKey(item.id);

    if (downloading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: progress > 0 ? progress : null,
                    minHeight: 6,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 64,
                child: Text(
                  progress > 0
                      ? '${(progress * 100).round()}%'
                      : '连接中…',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 42,
            child: OutlinedButton.icon(
              onPressed: () {
                _tasks.cancelTask(key);
                SmartDialog.showToast('正在取消下载…');
              },
              icon: const Icon(Icons.close, size: 18),
              label: const Text('取消下载'),
            ),
          ),
        ],
      );
    }

    if (downloaded) {
      return SizedBox(
        height: 48,
        width: double.infinity,
        child: FilledButton.tonalIcon(
          onPressed: () => _openLocation(item.id),
          icon: const Icon(Icons.folder_open, size: 20),
          label: const Text('已下载 · 打开所在位置'),
        ),
      );
    }

    final sizeText = item.estimatedSize > 0
        ? '（约 ${formatDownloadSize(item.estimatedSize)}）'
        : '';
    return SizedBox(
      height: 48,
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: () => _startDownload(item),
        icon: const Icon(Icons.download, size: 20),
        label: Text(
          item.isAudioOnly ? '下载音频$sizeText' : '下载 MP4$sizeText',
        ),
      ),
    );
  }
}
