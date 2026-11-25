import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pilipala/http/search.dart';
import 'package:pilipala/models/common/search_type.dart';
import 'package:pilipala/pages/search_panel/controller.dart';
import 'package:pilipala/pages/search_panel/widgets/video_panel.dart';

Map<String, dynamic> video(int id) => {
      'type': 'video',
      'id': id,
      'aid': id,
      'mid': id,
      'bvid': 'BV$id',
      'title': 'EnglishPod $id',
      'author': 'author',
      'duration': '05:00',
    };
Map<String, dynamic> response(List items, {int pages = 0, int total = 100}) => {
      'code': 0,
      'data': {'numPages': pages, 'numResults': total, 'result': items},
    };
Map<String, dynamic> success(List items, {bool more = true}) =>
    {'status': true, 'data': Data(list: items), 'hasMore': more};

void main() {
  final verificationPayload = {
    'code': 0,
    'message': '0',
    'data': {'v_voucher': 'test-verification-required'},
  };
  Map combined(List items) => {
        'code': 0,
        'data': {
          'top_tlist': {'video': 1000},
          'pageinfo': {
            'video': {'numResults': 1000, 'total': 1000, 'pages': 50}
          },
          'result': [
            {'result_type': 'article', 'data': []},
            {'result_type': 'video', 'data': items}
          ],
        }
      };

  test('真实故障结构：code为0但只有v_voucher，必须提示验证且不换接口重试', () async {
    final calls = <String>[];
    final result = await SearchHttp.fetchSearchResults(
      searchType: SearchType.video,
      page: 1,
      params: {'keyword': 'nhk新闻'},
      request: (endpoint, params) async {
        calls.add(endpoint);
        return verificationPayload;
      },
    );
    expect(result['status'], isFalse);
    expect(result['reason'], 'verification');
    expect(result['requiresVerification'], isTrue);
    expect(result['msg'], contains('安全验证'));
    expect(calls.length, 1);
    expect(result.toString(), isNot(contains('test-verification-required')));
    expect(
        SearchHttp.parseSearchResponse(jsonEncode(verificationPayload),
            searchType: SearchType.video, page: 2)['reason'],
        'verification');
  });

  test('异常卡片不拖垮整页，数字字符串和缺省字段可安全显示', () {
    final result = SearchHttp.parseSearchResponse(
        response([
          video(1),
          null,
          {'type': 'live_room'},
          {'title': 'missing IDs'},
          {
            ...video(2),
            'aid': '2',
            'mid': '2',
            'id': '2',
            'duration': '直播',
            'pubdate': '1700000000',
            'senddate': '1700000000',
            'video_review': '3'
          },
          {
            ...video(3),
            'duration': 240,
            'play': null,
            'danmaku': null,
            'author': null
          },
        ]),
        searchType: SearchType.video,
        page: 1);
    expect(result['status'], isTrue);
    expect(result['data'].list.length, 3);
    expect(result['invalidCount'], 3);
    expect(result['data'].list[1].duration, 0);
    expect(result['data'].list[1].pubdate, 1700000000);
    expect(result['data'].list[2].duration, 240);
    expect(result['data'].list[2].stat.view, 0);
    expect(result['data'].list[2].owner.name, '');
  });

  test('普通缺失响应仅首屏默认筛选允许一次备用读取，仍执行屏蔽', () async {
    var calls = 0;
    final result = await SearchHttp.fetchSearchResults(
      searchType: SearchType.video,
      page: 1,
      params: {'keyword': 'nhk新闻'},
      blockedMids: {1},
      request: (_, params) async =>
          ++calls == 1 ? response([]) : combined([video(1), video(2)]),
    );
    expect(calls, 2);
    expect(result['source'], 'combined');
    expect(result['data'].list.single.aid, 2);
    expect(result['blockedCount'], 1);
    expect(result['hasMore'], isTrue);
  });

  test('翻页、排序、时长分区筛选及明确请求限制不会切到不同条件的结果', () async {
    for (final parameters in [
      {'page': 2},
      {'order': 'pubdate'},
      {'duration': 3},
      {'tids': 202},
    ]) {
      var calls = 0;
      await SearchHttp.fetchSearchResults(
          searchType: SearchType.video,
          page: parameters['page'] as int? ?? 1,
          params: {'keyword': 'nhk新闻', ...parameters},
          request: (_, __) async {
            calls++;
            return {'code': 0, 'data': null};
          });
      expect(calls, 1, reason: '$parameters');
    }
    var calls = 0;
    final blocked = await SearchHttp.fetchSearchResults(
        searchType: SearchType.video,
        page: 1,
        params: {'keyword': 'nhk新闻'},
        request: (_, __) async {
          calls++;
          return {'code': -412};
        });
    expect(calls, 1);
    expect(blocked['requiresVerification'], isTrue);
  });

  test('备用读取失败保留原错误，验证状态优先于空结果', () async {
    var calls = 0;
    final result = await SearchHttp.fetchSearchResults(
        searchType: SearchType.video,
        page: 1,
        params: {'keyword': 'nhk新闻'},
        request: (_, __) async {
          if (++calls == 1) return response([]);
          throw const SocketException('offline');
        });
    expect(result['status'], isFalse);
    expect(result['reason'], 'missing');
    calls = 0;
    final restricted = await SearchHttp.fetchSearchResults(
        searchType: SearchType.video,
        page: 1,
        params: {'keyword': 'nhk新闻'},
        request: (_, __) async =>
            ++calls == 1 ? response([], total: 0) : verificationPayload);
    expect(restricted['requiresVerification'], isTrue);
  });

  test('验证中不跳过页码，成功重试后清除验证状态', () async {
    var calls = 0;
    final ctr = SearchPanelController(
        keyword: 'nhk新闻',
        searchType: SearchType.video,
        loadPage: (
                {required searchType,
                required keyword,
                required page,
                order,
                duration,
                tids}) async =>
            ++calls == 1
                ? SearchHttp.parseSearchResponse(verificationPayload,
                    searchType: searchType, page: page)
                : success(['recovered'], more: false));
    await ctr.onRefresh();
    expect(ctr.requiresVerification.value, isTrue);
    expect(ctr.page.value, 1);
    await ctr.onRefresh();
    expect(ctr.requiresVerification.value, isFalse);
    expect(ctr.errorMessage.value, isEmpty);
    expect(ctr.resultList, ['recovered']);
    ctr.onClose();
  });

  testWidgets('横屏矮窗口仍能直接看到验证原因和两个按钮', (tester) async {
    Get.testMode = true;
    tester.view.physicalSize = const Size(900, 260);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final ctr =
        SearchPanelController(keyword: 'nhk新闻', searchType: SearchType.video);
    ctr.errorMessage.value =
        SearchHttp.searchVerificationFailure(verificationPayload)!['msg'];
    ctr.requiresVerification.value = true;
    await tester.pumpWidget(GetMaterialApp(
        home: Scaffold(body: SearchVideoPanel(ctr: ctr, list: const []))));
    expect(find.text('打开官方搜索').hitTestable(), findsOneWidget);
    expect(find.text('重新加载').hitTestable(), findsOneWidget);
    expect(find.text(ctr.errorMessage.value).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    ctr.onClose();
    Get.reset();
  });

  if (const bool.fromEnvironment('SEARCH_CAPTURE_CHECK')) {
    test('回放本次真实响应：两个词的视频接口要求验证，综合接口各有20条视频', () {
      for (final keyword in ['nhk', 'englishpod']) {
        final primary = SearchHttp.parseSearchResponse(
            File('scratch/offline_check/search_${keyword}_type.json')
                .readAsStringSync(),
            searchType: SearchType.video,
            page: 1);
        expect(primary['reason'], 'verification');
        final combined = SearchHttp.parseCombinedVideoResponse(
            File('scratch/offline_check/search_${keyword}_combined.json')
                .readAsStringSync());
        expect(combined['status'], isTrue);
        expect(combined['data'].list.length, 20);
        expect(combined['invalidCount'], 0);
      }
    });
  }

  test('页数为0、数量大于0时仍展示实际items，兼容JSON字符串', () {
    for (final payload in [
      response([video(1)]),
      jsonEncode(response([video(1)]))
    ]) {
      final result = SearchHttp.parseSearchResponse(payload,
          searchType: SearchType.video, page: 1);
      expect(result['status'], isTrue);
      expect(result['data'].list.single.title, 'EnglishPod 1');
    }
  });

  test('列表缺失或有数量却空列表不能伪装成成功的无数据', () {
    for (final payload in [
      {'code': 0, 'data': null},
      {
        'code': 0,
        'data': {'numResults': 99}
      },
      response([]),
      {'code': -412, 'message': '请求被限制'},
    ]) {
      final result = SearchHttp.parseSearchResponse(payload,
          searchType: SearchType.video, page: 1);
      expect(result['status'], isFalse);
      expect(result['msg'], isNotEmpty);
    }
    final empty = SearchHttp.parseSearchResponse(response([], total: 0),
        searchType: SearchType.video, page: 1);
    expect(empty['status'], isTrue);
    expect(empty['data'].list, isEmpty);
    expect(empty['hasMore'], isFalse);
  });

  test('全部屏蔽时解释原因，使用服务端原始数量判断是否还有下一页', () {
    final result = SearchHttp.parseSearchResponse(
        response([video(1)], pages: 2),
        searchType: SearchType.video,
        page: 1,
        blockedMids: {1});
    expect(result['data'].list, isEmpty);
    expect(result['emptyMessage'], contains('屏蔽'));
    expect(result['hasMore'], isTrue);
  });

  test('筛选请求乱序返回，旧空结果不能覆盖新结果或修改页码', () async {
    final old = Completer<dynamic>();
    final fresh = Completer<dynamic>();
    final orders = <String?>[];
    final ctr = SearchPanelController(
        keyword: 'englishpod',
        searchType: SearchType.video,
        loadPage: (
            {required searchType,
            required keyword,
            required page,
            order,
            duration,
            tids}) {
          orders.add(order);
          return orders.length == 1 ? old.future : fresh.future;
        });
    final first = ctr.onRefresh();
    ctr.order.value = 'pubdate';
    final second = ctr.onRefresh();
    fresh.complete(success(['new']));
    await second;
    old.complete(success([], more: false));
    await first;
    expect(orders, [null, 'pubdate']);
    expect(ctr.resultList, ['new']);
    expect(ctr.page.value, 2);
    expect(ctr.hasMore, isTrue);
    expect(ctr.isLoading.value, isFalse);
    ctr.onClose();
  });

  test('翻页不并发，请求失败不跳页，重试成功后清除错误', () async {
    final pending = Completer<dynamic>();
    final pages = <int>[];
    final ctr = SearchPanelController(
        keyword: 'englishpod',
        searchType: SearchType.video,
        loadPage: (
            {required searchType,
            required keyword,
            required page,
            order,
            duration,
            tids}) {
          pages.add(page);
          return pages.length == 1
              ? pending.future
              : Future.value(success(['ok'], more: false));
        });
    final first = ctr.onSearch();
    final duplicate = ctr.onSearch(type: 'onLoad');
    expect(pages, [1]);
    pending.completeError(Exception('network failure'));
    await first;
    await duplicate;
    expect(ctr.page.value, 1);
    expect(ctr.errorMessage.value, isNotEmpty);
    await ctr.onRefresh();
    expect(pages, [1, 1]);
    expect(ctr.resultList, ['ok']);
    expect(ctr.errorMessage.value, isEmpty);
    await ctr.onSearch(type: 'onLoad');
    expect(pages, [1, 1]);
    ctr.onClose();
  });

  testWidgets('视频空页保留重试入口，不同搜索页不共享筛选状态', (tester) async {
    Get.testMode = true;
    var requests = 0;
    final ctr = SearchPanelController(
        keyword: 'englishpod',
        searchType: SearchType.video,
        loadPage: (
            {required searchType,
            required keyword,
            required page,
            order,
            duration,
            tids}) async {
          requests++;
          return success([], more: false);
        });
    ctr.errorMessage.value = '搜索有匹配内容，但列表未完整返回，请重试';
    final panel = SearchVideoPanel(ctr: ctr, list: const []);
    await tester.pumpWidget(GetMaterialApp(home: Scaffold(body: panel)));
    expect(find.text(ctr.errorMessage.value), findsOneWidget);
    await tester.tap(find.text('重新加载'));
    await tester.pump();
    expect(requests, 1);
    panel.controller.currentTimeFilterval.value = 3;
    final other =
        SearchPanelController(keyword: 'other', searchType: SearchType.video);
    expect(
        SearchVideoPanel(ctr: other, list: const [])
            .controller
            .currentTimeFilterval
            .value,
        0);
    await tester.pumpWidget(const SizedBox());
    ctr.onClose();
    other.onClose();
    Get.reset();
  });
}
