// ignore_for_file: invalid_use_of_protected_member

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:pilipala/common/skeleton/media_bangumi.dart';
import 'package:pilipala/common/skeleton/video_card_h.dart';
import 'package:pilipala/common/widgets/http_error.dart';
import 'package:pilipala/models/common/search_type.dart';

import 'controller.dart';
import 'widgets/article_panel.dart';
import 'widgets/live_panel.dart';
import 'widgets/media_bangumi_panel.dart';
import 'widgets/user_panel.dart';
import 'widgets/video_panel.dart';

class SearchPanel extends StatefulWidget {
  final String? keyword;
  final SearchType? searchType;
  final String? tag;
  const SearchPanel(
      {required this.keyword, required this.searchType, this.tag, Key? key})
      : super(key: key);

  @override
  State<SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<SearchPanel>
    with AutomaticKeepAliveClientMixin {
  late SearchPanelController _searchPanelController;

  late final String _controllerTag;
  late final VoidCallback _scrollListener;
  late ScrollController scrollController;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _controllerTag = widget.tag ?? 'search-${identityHashCode(this)}';
    _searchPanelController = Get.put(
      SearchPanelController(
        keyword: widget.keyword,
        searchType: widget.searchType,
      ),
      tag: _controllerTag,
    );

    /// 专栏默认排序
    if (widget.searchType == SearchType.article) {
      _searchPanelController.order.value = 'totalrank';
    }
    scrollController = _searchPanelController.scrollController;
    _scrollListener = () {
      if (scrollController.position.pixels >=
              scrollController.position.maxScrollExtent - 100 &&
          _searchPanelController.errorMessage.value.isEmpty) {
        _searchPanelController.onSearch(type: 'onLoad');
      }
    };
    scrollController.addListener(_scrollListener);
    _searchPanelController.onRefresh();
  }

  @override
  void dispose() {
    scrollController.removeListener(_scrollListener);
    final filterTag =
        'search-filter-${identityHashCode(_searchPanelController)}';
    Get.delete<VideoPanelController>(tag: filterTag);
    Get.delete<ArticlePanelController>(tag: filterTag);
    Get.delete<SearchPanelController>(tag: _controllerTag);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final ctr = _searchPanelController;
    return RefreshIndicator(
      onRefresh: () async {
        await ctr.onRefresh();
      },
      child: Obx(() {
        final list = ctr.resultList;
        final loading = ctr.isLoading.value;
        final error = ctr.errorMessage.value;
        if (list.isEmpty && loading) {
          return ListView.builder(
              itemCount: 10,
              itemBuilder: (context, index) =>
                  widget.searchType == SearchType.media_bangumi
                      ? const MediaBangumiSkeleton()
                      : const VideoCardHSkeleton());
        }
        if (list.isEmpty &&
            error.isNotEmpty &&
            widget.searchType != SearchType.video) {
          return CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [HttpError(errMsg: error, fn: () => ctr.onRefresh())],
          );
        }
        Widget panel;
        switch (widget.searchType) {
          case SearchType.video:
            panel = SearchVideoPanel(ctr: ctr, list: list.toList());
            break;
          case SearchType.media_bangumi:
            panel = searchMbangumiPanel(context, ctr, list);
            break;
          case SearchType.bili_user:
            panel = searchUserPanel(context, ctr, list);
            break;
          case SearchType.live_room:
            panel = searchLivePanel(context, ctr, list);
            break;
          case SearchType.article:
            panel = SearchArticlePanel(ctr: ctr, list: list.toList());
            break;
          default:
            return const SizedBox();
        }
        if (list.isNotEmpty && error.isNotEmpty) {
          return Column(children: [
            Row(children: [
              Expanded(child: Text(error)),
              TextButton(
                  onPressed: () => ctr.onRefresh(), child: const Text('重试')),
              if (ctr.requiresVerification.value)
                TextButton(
                    onPressed: ctr.openOfficialSearch,
                    child: const Text('官方搜索'))
            ]),
            Expanded(child: panel),
          ]);
        }
        return panel;
      }),
    );
  }
}
