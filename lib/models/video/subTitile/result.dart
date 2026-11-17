class SubTitlteModel {
  SubTitlteModel({
    this.aid,
    this.bvid,
    this.cid,
    this.loginMid,
    this.loginMidHash,
    this.isOwner,
    this.name,
    this.subtitles,
  });

  int? aid;
  String? bvid;
  int? cid;
  int? loginMid;
  String? loginMidHash;
  bool? isOwner;
  String? name;
  List<SubTitlteItemModel>? subtitles;

  factory SubTitlteModel.fromJson(Map json) => SubTitlteModel(
        aid: json["aid"] is int
            ? json["aid"]
            : int.tryParse(json["aid"]?.toString() ?? ''),
        bvid: json["bvid"]?.toString(),
        cid: json["cid"] is int
            ? json["cid"]
            : int.tryParse(json["cid"]?.toString() ?? ''),
        loginMid: json["login_mid"] is int
            ? json["login_mid"]
            : int.tryParse(json["login_mid"]?.toString() ?? ''),
        loginMidHash: json["login_mid_hash"]?.toString(),
        isOwner: json["is_owner"] == true,
        name: json["name"]?.toString(),
        subtitles: ((json["subtitle"] is Map
                    ? (json["subtitle"]["subtitles"] ?? json["subtitle"]["list"])
                    : (json["subtitles"] ?? json["list"])) as List? ??
                const [])
            .whereType<Map>()
            .map((item) => SubTitlteItemModel.fromJson(Map<String, dynamic>.from(item)))
            .toList(),
      );
}

class SubTitlteItemModel {
  SubTitlteItemModel({
    this.id,
    this.lan,
    this.lanDoc,
    this.isLock,
    this.subtitleUrl,
    this.type,
    this.aiType,
    this.aiStatus,
    this.title,
    this.code,
    this.content,
    this.body,
  });

  int? id;
  String? lan;
  String? lanDoc;
  bool? isLock;
  String? subtitleUrl;
  int? type;
  int? aiType;
  int? aiStatus;
  String? title;
  int? code;
  String? content;
  List? body;

  bool get isAi =>
      (subtitleUrl?.contains('ai_subtitle') ?? false) ||
      (lan?.startsWith('ai') ?? false) ||
      (lanDoc?.contains('自动生成') ?? false) ||
      (aiType != null && aiType != 0);

  factory SubTitlteItemModel.fromJson(Map<String, dynamic> json) =>
      SubTitlteItemModel(
        id: json["id"] is int
            ? json["id"]
            : int.tryParse(json["id"]?.toString() ?? ''),
        lan: (json["lan"] as String?)?.replaceAll('-', ''),
        lanDoc: json["lan_doc"]?.toString(),
        isLock: json["is_lock"] == true,
        subtitleUrl: json["subtitle_url"]?.toString(),
        type: json["type"] is int
            ? json["type"]
            : int.tryParse(json["type"]?.toString() ?? ''),
        aiType: json["ai_type"] is int
            ? json["ai_type"]
            : int.tryParse(json["ai_type"]?.toString() ?? ''),
        aiStatus: json["ai_status"] is int
            ? json["ai_status"]
            : int.tryParse(json["ai_status"]?.toString() ?? ''),
        title: (json["lan_doc"] ?? json["title"])?.toString(),
        content: '',
        body: [],
      );
}
