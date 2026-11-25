import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_overlay.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_preferences.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/realtime_captions.dart';

void main() {
  double indicatorOpacity(WidgetTester tester) => tester
      .widget<Opacity>(find.byKey(const ValueKey('caption-drag-indicator')))
      .opacity;
  Future<Finder> showOverlay(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final captions = RealtimeCaptions()..showOriginal.value = true;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: CaptionOverlay(
          captions: captions,
          preferences: CaptionPreferences(),
        ),
      ),
    ));
    return find.byWidgetPredicate((widget) =>
        widget is GestureDetector && widget.onVerticalDragUpdate != null);
  }

  for (final size in [const Size(800, 400), const Size(400, 800)]) {
    testWidgets('拖动条仅拖动时显示，超过100px仍可移动，松手保留 $size', (tester) async {
      final handle = await showOverlay(tester, size);
      final initial = tester.getRect(handle);
      expect(initial.height, greaterThanOrEqualTo(48));
      expect(indicatorOpacity(tester), 0);

      // 位于命中区上沿，远离原先只有 16px 的中央窄条。
      final gesture = await tester.startGesture(
        Offset(initial.center.dx, initial.top + 4),
      );
      await tester.pump();
      expect(indicatorOpacity(tester), 0);
      await gesture.moveBy(const Offset(0, -24));
      await tester.pump();
      expect(tester.getTopLeft(handle).dy, closeTo(initial.top - 24, 0.01));
      expect(indicatorOpacity(tester), 1);

      await gesture.moveBy(const Offset(0, -200));
      await tester.pump();
      final moved = tester.getTopLeft(handle).dy;
      expect(moved, closeTo(initial.top - 224, 0.01));
      await gesture.moveBy(const Offset(0, 5));
      await tester.pump();
      expect(tester.getTopLeft(handle).dy, closeTo(moved + 5, 0.01));

      await gesture.up();
      await tester.pump();
      expect(tester.getTopLeft(handle).dy, closeTo(moved + 5, 0.01));
      expect(indicatorOpacity(tester), 0);
      // 在新位置再次按住，不能出现只移动画面、命中区留在原地的情况。
      await tester.drag(handle, const Offset(0, -30));
      await tester.pump();
      expect(tester.getTopLeft(handle).dy, closeTo(moved - 25, 0.01));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('向下拖动不越出屏幕，取消后保留位置并隐藏拖动条', (tester) async {
    const size = Size(800, 400);
    final handle = await showOverlay(tester, size);
    final initial = tester.getRect(handle);
    final gesture = await tester.startGesture(initial.center);
    await gesture.moveBy(const Offset(0, 200));
    await tester.pump();
    expect(tester.getTopLeft(handle).dy, closeTo(initial.top + 30, 0.01));
    final caption = find.text('正在聆听并识别字幕…');
    expect(tester.getBottomLeft(caption).dy, lessThanOrEqualTo(size.height));
    await gesture.cancel();
    await tester.pump();
    expect(tester.getTopLeft(handle).dy, closeTo(initial.top + 30, 0.01));
    expect(indicatorOpacity(tester), 0);
  });

  testWidgets('可拖到屏幕顶部，超出边界后反向立即响应', (tester) async {
    final handle = await showOverlay(tester, const Size(400, 800));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(0, -2000));
    await tester.pump();
    expect(tester.getTopLeft(handle).dy, 0);
    await gesture.moveBy(const Offset(0, 5));
    await tester.pump();
    expect(tester.getTopLeft(handle).dy, 5);
    await gesture.up();
    await tester.pump();
    expect(tester.getTopLeft(handle).dy, 5);
    await tester.drag(handle, const Offset(0, 200));
    await tester.pump();
    expect(tester.getTopLeft(handle).dy, closeTo(205, 0.01));
  });

  testWidgets('停在屏幕中间，字幕刷新和横竖屏切换后仍能操作', (tester) async {
    final handle = await showOverlay(tester, const Size(400, 800));
    await tester.drag(handle, Offset(0, 320 - tester.getTopLeft(handle).dy));
    await tester.pump();
    expect(tester.getTopLeft(handle).dy, closeTo(320, 0.01));
    final captions =
        tester.widget<CaptionOverlay>(find.byType(CaptionOverlay)).captions;
    captions.status.value = '新的字幕状态';
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(handle).dy, closeTo(320, 0.01));
    await tester.binding.setSurfaceSize(const Size(800, 400));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(handle).dy, closeTo(160, 0.01));
    expect(indicatorOpacity(tester), 0);
    await tester.drag(handle, const Offset(0, -50));
    await tester.pump();
    expect(tester.getTopLeft(handle).dy, closeTo(110, 0.01));
    expect(tester.takeException(), isNull);
  });
}
