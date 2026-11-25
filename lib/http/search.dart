import 'dart:convert';
import '../services/loggeer.dart';
import 'package:hive/hive.dart';
import 'package:pilipala/models/search/all.dart';
import 'package:pilipala/utils/wbi_sign.dart';
import '../models/bangumi/info.dart';
import '../models/common/search_type.dart';
import '../models/search/hot.dart';
import '../models/search/result.dart';
import '../models/search/suggest.dart';
import '../utils/storage.dart';
import 'index.dart';

class SearchHttp {
  static Box setting = GStrorage.setting;
  static Future hotSearchList() async {
    var res = await Request().get(Api.hotSearchList);
    if (res.data is String) {
      Map<String, dynamic> resultMap = json.decode(res.data);
      if (resultMap['code'] == 0) {
        return {
          'status': true,
          'data': HotSearchModel.fromJson(resultMap),
        };
      }
    } else if (res.data is Map<String, dynamic> && res.data['code'] == 0) {
      return {
        'status': true,
        'data': HotSearchModel.fromJson(res.data),
      };
    }

    return {
      'status': false,
      'data': [],
      'msg': '请求错误 🙅',
    };
  }

  // 获取搜索建议
  static Future searchSuggest({required term}) async {
    var res = await Request().get(Api.searchSuggest,
        data: {'term': term, 'main_ver': 'v1', 'highlight': term});
    if (res.data is String) {
      Map<String, dynamic> resultMap = json.decode(res.data);
      if (resultMap['code'] == 0) {
        if (resultMap['result'] is Map) {
          resultMap['result']['term'] = term;
        }
        return {
          'status': true,
          'data': resultMap['result'] is Map
              ? SearchSuggestModel.fromJson(resultMap['result'])
              : [],
        };
      } else {
        return {
          'status': false,
          'data': [],
          'msg': '请求错误 🙅',
        };
      }
    } else {
      return {
        'status': false,
        'data': [],
        'msg': '请求错误 🙅',
      };
    }
  }

  // 分类搜索
  static Future searchByType({
    required SearchType searchType,
    required String keyword,
    required page,
    String? order,
    int? duration,
    int? tids,
  }) async {
    var reqData = {
      'search_type': searchType.type,
      'keyword': keyword,
      // 'order_sort': 0,
      // 'user_type': 0,
      'page': page,
      'web_location': 333.999,
      if (order != null) 'order': order,
      if (duration != null) 'duration': duration,
      if (tids != null && tids != -1) 'tids': tids,
    };
    try {
      final blocked = searchType == SearchType.video
          ? (setting.get(SettingBoxKey.blackMidsList, defaultValue: <int>[])
                  as List)
              .map((value) => int.tryParse(value.toString()))
              .whereType<int>()
              .toSet()
          : <int>{};
      final result = await fetchSearchResults(
        searchType: searchType,
        page: page,
        params: reqData,
        blockedMids: blocked,
        request: (endpoint, params) async {
          final signed =
              await WbiSign().makSign(Map<String, dynamic>.from(params));
          return (await Request().get(endpoint, data: signed)).data;
        },
      );
      if (result['status'] != true ||
          (result['invalidCount'] as int? ?? 0) > 0 ||
          result['source'] == 'combined') {
        // Only structural metadata, never cookies, signatures, URLs or query text.
        getLogger<SearchHttp>().e('搜索诊断 type=${searchType.type} page=$page '
            'source=${result['source']} reason=${result['reason']} code=${result['code']} '
            'raw=${result['rawCount']} invalid=${result['invalidCount']} '
            'blocked=${result['blockedCount']}');
      }
      return result;
    } catch (_) {
      getLogger<SearchHttp>()
          .e('搜索诊断 stage=request type=${searchType.type} page=$page');
      return {'status': false, 'msg': '搜索加载失败，请重试'};
    }
  }

  /// Only the unfiltered first video page may use the combined-search video
  /// block. Sorting/filtering and later pages must retain their exact semantics.
  static Future<Map<String, dynamic>> fetchSearchResults({
    required SearchType searchType,
    required int page,
    required Map<String, dynamic> params,
    required Future<dynamic> Function(String, Map<String, dynamic>) request,
    Set<int> blockedMids = const {},
  }) async {
    final primary = parseSearchResponse(await request(Api.searchByType, params),
        searchType: searchType, page: page, blockedMids: blockedMids);
    final unfiltered = searchType == SearchType.video &&
        page == 1 &&
        (params['order'] == null ||
            params['order'] == '' ||
            params['order'] == 'totalrank') &&
        (params['duration'] == null || params['duration'] == 0) &&
        (params['tids'] == null || params['tids'] == -1 || params['tids'] == 0);
    final suspect = primary['status'] == true
        ? primary['rawCount'] == 0
        : ['missing', 'format', 'items', 'parse'].contains(primary['reason']);
    if (!unfiltered || !suspect) return {...primary, 'source': 'type'};
    try {
      final alternate = parseCombinedVideoResponse(
          await request(Api.searchCount, {
            'keyword': params['keyword'],
            'page': 1,
            'web_location': params['web_location'],
          }),
          blockedMids: blockedMids);
      if (alternate['requiresVerification'] == true) {
        return {...alternate, 'source': 'combined'};
      }
      if (alternate['status'] == true &&
          (alternate['rawCount'] as int? ?? 0) > 0) {
        return {...alternate, 'source': 'combined'};
      }
      // A positive combined count with missing items is an error, not "no data".
      if (primary['status'] == true && alternate['reason'] == 'missing') {
        return {...alternate, 'source': 'combined'};
      }
    } catch (_) {
      // Preserve the original error/empty response if the single fallback fails.
    }
    return {...primary, 'source': 'type'};
  }

  static Map<String, dynamic> parseCombinedVideoResponse(dynamic payload,
      {Set<int> blockedMids = const {}}) {
    try {
      if (payload is String) payload = json.decode(payload);
      final verification = searchVerificationFailure(payload);
      if (verification != null) return verification;
      if (payload is! Map || payload['code'] != 0 || payload['data'] is! Map) {
        return {'status': false, 'reason': 'request'};
      }
      final body = payload['data'] as Map;
      final blocks = body['result'];
      if (blocks is! List) return {'status': false, 'reason': 'format'};
      List? videos;
      for (final block in blocks) {
        if (block is Map &&
            block['result_type'] == 'video' &&
            block['data'] is List) {
          videos = block['data'] as List;
          break;
        }
      }
      final pageInfo =
          body['pageinfo'] is Map ? body['pageinfo']['video'] : null;
      final total = pageInfo is Map
          ? pageInfo['total']
          : (body['top_tlist'] is Map ? body['top_tlist']['video'] : null);
      return parseSearchResponse({
        'code': 0,
        'data': {
          'result': videos,
          'numResults': total,
          'numPages': pageInfo is Map ? pageInfo['pages'] : null,
        }
      }, searchType: SearchType.video, page: 1, blockedMids: blockedMids);
    } catch (_) {
      return {'status': false, 'reason': 'format'};
    }
  }

  static Map<String, dynamic> parseSearchResponse(
    dynamic payload, {
    required SearchType searchType,
    required int page,
    Set<int> blockedMids = const {},
  }) {
    try {
      if (payload is String) payload = json.decode(payload);
      final verification = searchVerificationFailure(payload);
      if (verification != null) return verification;
      if (payload is! Map || payload['code'] != 0) {
        return {
          'status': false,
          'reason': 'request',
          'code': payload is Map ? payload['code'] : null,
          'msg': payload is Map
              ? payload['message']?.toString() ?? '搜索请求失败，请重试'
              : '搜索响应异常，请重试'
        };
      }
      final body = payload['data'];
      if (body is! Map) {
        return {'status': false, 'reason': 'missing', 'msg': '搜索结果未完整返回，请重试'};
      }
      final total = int.tryParse('${body['numResults']}');
      final pages = int.tryParse('${body['numPages']}');
      final raw = body['result'];
      // Results are authoritative; numPages may be zero even with valid items.
      if (raw != null && raw is! List) {
        return {'status': false, 'reason': 'format', 'msg': '搜索结果格式异常，请重试'};
      }
      if (raw == null && total != 0 ||
          (raw is List && raw.isEmpty && page == 1 && (total ?? 0) > 0)) {
        return {
          'status': false,
          'reason': 'missing',
          'msg': '搜索有匹配内容，但列表未完整返回，请重试'
        };
      }
      final items = raw as List? ?? [];
      final dataJson = Map<String, dynamic>.from(body);
      dataJson['result'] = items;
      dynamic data;
      var blockedCount = 0;
      var invalidCount = 0;
      switch (searchType) {
        case SearchType.video:
          final videos = <SearchVideoItemModel>[];
          for (final item in items) {
            if (item is! Map) {
              invalidCount++;
              continue;
            }
            try {
              final copy = Map<String, dynamic>.from(item);
              // Ad/live/other cards can share the list. They are not playable
              // video rows; never let one such card discard the entire page.
              if (copy['type'] != null &&
                  copy['type'] != 'video' &&
                  copy['type'] != 'ketang') {
                invalidCount++;
                continue;
              }
              final video = SearchVideoItemModel.fromJson(copy);
              if (video.aid == null ||
                  video.aid! <= 0 ||
                  video.bvid == null ||
                  video.bvid!.isEmpty ||
                  video.title!.trim().isEmpty) {
                invalidCount++;
                continue;
              }
              if (blockedMids.contains(video.mid)) {
                blockedCount++;
                continue;
              }
              videos.add(video);
            } catch (_) {
              invalidCount++;
            }
          }
          if (videos.isEmpty && invalidCount > 0 && blockedCount == 0) {
            return {
              'status': false,
              'reason': 'items',
              'rawCount': items.length,
              'invalidCount': invalidCount,
              'blockedCount': 0,
              'msg': '返回的内容暂时无法显示，请重新加载'
            };
          }
          data = SearchVideoModel(list: videos);
          break;
        case SearchType.live_room:
          data = SearchLiveModel.fromJson(dataJson);
          break;
        case SearchType.bili_user:
          data = SearchUserModel.fromJson(dataJson);
          break;
        case SearchType.media_bangumi:
          data = SearchMBangumiModel.fromJson(dataJson);
          break;
        case SearchType.article:
          data = SearchArticleModel.fromJson(dataJson);
          break;
      }
      return {
        'status': true,
        'data': data,
        'rawCount': items.length,
        'invalidCount': invalidCount,
        'blockedCount': blockedCount,
        'hasMore':
            items.isNotEmpty && (pages == null || pages <= 0 || page < pages),
        'emptyMessage':
            blockedCount > 0 && blockedCount + invalidCount == items.length
                ? '本页结果已被屏蔽设置过滤'
                : null,
      };
    } catch (_) {
      return {'status': false, 'reason': 'parse', 'msg': '搜索结果解析失败，请重试'};
    }
  }

  static Map<String, dynamic>? searchVerificationFailure(dynamic payload) {
    if (payload is! Map) return null;
    final body = payload['data'];
    final voucher = body is Map ? body['v_voucher'] : null;
    if ((voucher is String && voucher.isNotEmpty) ||
        (payload['v_voucher'] is String && payload['v_voucher'].isNotEmpty)) {
      return {
        'status': false,
        'reason': 'verification',
        'code': payload['code'],
        'requiresVerification': true,
        'msg': '哔哩哔哩要求安全验证，暂未返回视频列表。请打开官方搜索处理后重试。',
      };
    }
    if (payload['code'] == -412 || payload['code'] == -352) {
      return {
        'status': false,
        'reason': 'restricted',
        'code': payload['code'],
        'requiresVerification': true,
        'msg': '搜索请求被哔哩哔哩限制（${payload['code']}）。可稍后重试，或打开官方搜索查看。',
      };
    }
    return null;
  }

  static Future<int> ab2c({int? aid, String? bvid}) async {
    Map<String, dynamic> data = {};
    if (aid != null) {
      data['aid'] = aid;
    } else if (bvid != null) {
      data['bvid'] = bvid;
    }
    final dynamic res =
        await Request().get(Api.ab2c, data: <String, dynamic>{...data});
    if (res.data['code'] == 0) {
      return res.data['data'].first['cid'];
    } else {
      return -1;
    }
  }

  static Future<Map<String, dynamic>> bangumiInfo(
      {int? seasonId, int? epId}) async {
    final Map<String, dynamic> data = {};
    if (seasonId != null) {
      data['season_id'] = seasonId;
    } else if (epId != null) {
      data['ep_id'] = epId;
    }
    final dynamic res =
        await Request().get(Api.bangumiInfo, data: <String, dynamic>{...data});
    if (res.data['code'] == 0) {
      return {
        'status': true,
        'data': BangumiInfoModel.fromJson(res.data['result']),
      };
    } else {
      return {
        'status': false,
        'data': [],
        'msg': '请求错误 🙅',
      };
    }
  }

  static Future<Map<String, dynamic>> ab2cWithPic(
      {int? aid, String? bvid}) async {
    Map<String, dynamic> data = {};
    if (aid != null) {
      data['aid'] = aid;
    } else if (bvid != null) {
      data['bvid'] = bvid;
    }
    final dynamic res =
        await Request().get(Api.ab2c, data: <String, dynamic>{...data});
    return {
      'cid': res.data['data'].first['cid'],
      'pic': res.data['data'].first['first_frame'],
    };
  }

  static Future<Map<String, dynamic>> searchCount(
      {required String keyword}) async {
    Map<String, dynamic> data = {
      'keyword': keyword,
      'web_location': 333.999,
    };
    Map params = await WbiSign().makSign(data);
    final dynamic res = await Request().get(Api.searchCount, data: params);
    if (res.data['code'] == 0) {
      return {
        'status': true,
        'data': SearchAllModel.fromJson(res.data['data']),
      };
    } else {
      return {
        'status': false,
        'data': [],
        'msg': '请求错误 🙅',
      };
    }
  }
}

class Data {
  List<dynamic> list;

  Data({this.list = const []});
}
