/// 一条已落盘的媒体文件（视频轨 / 音频轨 / 一体 MP4）。
class DownloadFileRecord {
  const DownloadFileRecord({
    required this.path,
    required this.extension,
    this.isAudio = false,
    this.size = 0,
  });

  final String path;
  final String extension;
  final bool isAudio;
  final int size;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'extension': extension,
        'isAudio': isAudio,
        'size': size,
      };

  factory DownloadFileRecord.fromJson(Map json) {
    return DownloadFileRecord(
      path: json['path']?.toString() ?? '',
      extension: json['extension']?.toString() ?? '',
      isAudio: json['isAudio'] == true,
      size: (json['size'] is num) ? (json['size'] as num).round() : 0,
    );
  }
}

/// 一次下载操作生成的记录，用于「离线缓存」列表展示与本地播放/删除。
///
/// 存进 Hive 的是 toJson() 的普通 Map，不依赖 TypeAdapter，避免生成代码。
class DownloadRecord {
  const DownloadRecord({
    required this.id,
    required this.bvid,
    required this.cid,
    required this.title,
    required this.pic,
    required this.qualityLabel,
    required this.formatTitle,
    required this.totalSize,
    required this.files,
    required this.downloadedAt,
    this.durationSeconds = 0,
    this.sourceType = 'dash',
    this.formatId = '',
  });

  final String id;
  final String bvid;
  final int cid;
  final String title;
  final String pic;
  final String qualityLabel;
  final String formatTitle;
  final int totalSize;
  final List<DownloadFileRecord> files;
  final int downloadedAt;
  final int durationSeconds;
  final String sourceType;
  /// 下载面板里的格式项 id（如 dash_video_80），用于回查"该格式是否已下载"。
  final String formatId;

  /// 可独立播放的视频文件路径（一体 MP4 或 DASH 视频轨）。
  String? get videoPath {
    for (final file in files) {
      if (!file.isAudio && file.path.isNotEmpty) return file.path;
    }
    return null;
  }

  /// DASH 分离出来的音频轨路径；一体 MP4 时为 null。
  String? get audioPath {
    for (final file in files) {
      if (file.isAudio && file.path.isNotEmpty) return file.path;
    }
    return null;
  }

  bool get hasVideo => videoPath != null;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'bvid': bvid,
        'cid': cid,
        'title': title,
        'pic': pic,
        'qualityLabel': qualityLabel,
        'formatTitle': formatTitle,
        'totalSize': totalSize,
        'downloadedAt': downloadedAt,
        'durationSeconds': durationSeconds,
        'sourceType': sourceType,
        'formatId': formatId,
        'files': files.map((f) => f.toJson()).toList(),
      };

  factory DownloadRecord.fromJson(Map json) {
    final rawFiles = json['files'];
    final files = <DownloadFileRecord>[];
    if (rawFiles is List) {
      for (final item in rawFiles) {
        if (item is Map) files.add(DownloadFileRecord.fromJson(item));
      }
    }
    return DownloadRecord(
      id: json['id']?.toString() ?? '',
      bvid: json['bvid']?.toString() ?? '',
      cid: (json['cid'] is num) ? (json['cid'] as num).round() : 0,
      title: json['title']?.toString() ?? '未命名视频',
      pic: json['pic']?.toString() ?? '',
      qualityLabel: json['qualityLabel']?.toString() ?? '',
      formatTitle: json['formatTitle']?.toString() ?? '',
      totalSize: (json['totalSize'] is num)
          ? (json['totalSize'] as num).round()
          : 0,
      downloadedAt: (json['downloadedAt'] is num)
          ? (json['downloadedAt'] as num).round()
          : 0,
      durationSeconds: (json['durationSeconds'] is num)
          ? (json['durationSeconds'] as num).round()
          : 0,
      sourceType: json['sourceType']?.toString() ?? 'dash',
      formatId: json['formatId']?.toString() ?? '',
      files: files,
    );
  }
}
