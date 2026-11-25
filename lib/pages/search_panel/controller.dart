import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:pilipala/http/search.dart';
import 'package:pilipala/models/common/search_type.dart';
import 'package:pilipala/utils/id_utils.dart';
import 'package:pilipala/utils/utils.dart';
import 'package:pilipala/utils/cookie.dart';

typedef SearchPageLoader = Future<dynamic> Function({
  required SearchType searchType,
  required String keyword,
  required int page,
  String? order,
  int? duration,
  int? tids,
});

class SearchPanelController extends GetxController {
  SearchPanelController(
      {this.keyword, this.searchType, SearchPageLoader? loadPage})
      : _loadPage = loadPage ?? SearchHttp.searchByType;
  final SearchPageLoader _loadPage;
  final isLoading = false.obs;
  final errorMessage = ''.obs;
  final emptyMessage = ''.obs;
  final requiresVerification = false.obs;
  bool hasMore = true;
  int _requestId = 0;
  Future<dynamic>? _pending;
  ScrollController scrollController = ScrollController();
  String? keyword;
  SearchType? searchType;
  RxInt page = 1.obs;
  RxList resultList = [].obs;
  // 结果排序方式 搜索类型为视频、专栏及相簿时
  RxString order = ''.obs;
  // 视频时长筛选 仅用于搜索视频
  RxInt duration = 0.obs;
  // 视频分区筛选 仅用于搜索视频 -1时不传
  RxInt tids = (-1).obs;

  Future onSearch({type = 'init'}) {
    final refreshing = type == 'onRefresh';
    if (!refreshing && isLoading.value) return _pending ?? Future.value();
    if (!refreshing && !hasMore) return Future.value();
    final requestId = ++_requestId;
    final requestedPage = refreshing ? 1 : page.value;
    isLoading.value = true;
    errorMessage.value = '';
    requiresVerification.value = false;
    return _pending = _search(requestId, requestedPage, refreshing);
  }

  Future _search(int requestId, int requestedPage, bool refreshing) async {
    try {
      final result = await _loadPage(
        searchType: searchType!,
        keyword: keyword!,
        page: requestedPage,
        order: !['video', 'article'].contains(searchType!.type)
            ? null
            : (order.value.isEmpty ? null : order.value),
        duration: searchType == SearchType.video ? duration.value : null,
        tids: searchType == SearchType.video ? tids.value : null,
      );
      if (requestId != _requestId) return result;
      if (result is Map && result['status'] == true) {
        final items = result['data']?.list ?? [];
        if (refreshing || requestedPage == 1) {
          resultList.assignAll(items);
        } else {
          resultList.addAll(items);
        }
        page.value = requestedPage + 1;
        hasMore = result['hasMore'] as bool? ?? items.isNotEmpty;
        emptyMessage.value = result['emptyMessage'] as String? ??
            (duration.value != 0 || tids.value != -1
                ? '当前筛选条件下没有结果，可调整时长或分区'
                : '没有找到相关结果');
        if (requestedPage == 1 && resultList.isNotEmpty) {
          onPushDetail(keyword, resultList);
        }
      } else {
        requiresVerification.value =
            result is Map && result['requiresVerification'] == true;
        errorMessage.value = result is Map
            ? result['msg']?.toString() ?? '搜索加载失败，请重试'
            : '搜索加载失败，请重试';
      }
      return result;
    } catch (_) {
      if (requestId == _requestId) errorMessage.value = '搜索加载失败，请重试';
      return {'status': false, 'msg': '搜索加载失败，请重试'};
    } finally {
      if (requestId == _requestId) isLoading.value = false;
    }
  }

  Future onRefresh() => onSearch(type: 'onRefresh');

  Future<void> openOfficialSearch() async {
    final url =
        Uri.https('search.bilibili.com', '/all', {'keyword': keyword ?? ''});
    try {
      await SetCookie.prepareSearch();
      if (isClosed) return;
      await Get.toNamed('/webview', parameters: {
        'url': url.toString(),
        'type': 'searchVerification',
        'pageTitle': '哔哩哔哩官方搜索',
      });
      await SetCookie.onSet();
      if (!isClosed) await onRefresh();
    } catch (_) {
      if (!isClosed) errorMessage.value = '官方搜索打开失败，请稍后重试';
    }
  }

  @override
  void onClose() {
    _requestId++;
    scrollController.dispose();
    super.onClose();
  }

  // 返回顶部并刷新
  void animateToTop() async {
    if (!scrollController.hasClients) return;
    if (scrollController.offset >=
        MediaQuery.of(Get.context!).size.height * 5) {
      scrollController.jumpTo(0);
    } else {
      await scrollController.animateTo(0,
          duration: const Duration(milliseconds: 500), curve: Curves.easeInOut);
    }
  }

  void onPushDetail(keyword, resultList) async {
    // 匹配输入内容，如果是AV、BV号且有结果 直接跳转详情页
    Map matchRes = IdUtils.matchAvorBv(input: keyword);
    List matchKeys = matchRes.keys.toList();
    String? bvid;
    try {
      bvid = resultList.first.bvid;
    } catch (_) {
      bvid = null;
    }
    // keyword 可能输入纯数字
    int? aid;
    try {
      aid = resultList.first.aid;
    } catch (_) {
      aid = null;
    }
    if (matchKeys.isNotEmpty && searchType == SearchType.video ||
        aid.toString() == keyword) {
      String heroTag = Utils.makeHeroTag(bvid);
      int cid = await SearchHttp.ab2c(aid: aid, bvid: bvid);
      if (matchKeys.isNotEmpty &&
              matchKeys.first == 'BV' &&
              matchRes[matchKeys.first] == bvid ||
          matchKeys.isNotEmpty &&
              matchKeys.first == 'AV' &&
              matchRes[matchKeys.first] == aid ||
          aid.toString() == keyword) {
        Get.toNamed(
          '/video?bvid=$bvid&cid=$cid',
          arguments: {'videoItem': resultList.first, 'heroTag': heroTag},
        );
      }
    }
  }
}
