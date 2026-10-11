// swiping sideways on the driving screen changes the layout

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/services/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'golden/mock_ui_state.dart';

void main() {
  test('swipes step through the layouts and stop at the ends', () {
    expect(layoutAfterSwipe(OnroadLayout.classic, towardsNext: true), OnroadLayout.enhanced);
    expect(layoutAfterSwipe(OnroadLayout.enhanced, towardsNext: true), OnroadLayout.detailed);
    expect(layoutAfterSwipe(OnroadLayout.detailed, towardsNext: true), OnroadLayout.detailed);
    expect(layoutAfterSwipe(OnroadLayout.enhanced, towardsNext: false), OnroadLayout.classic);
    expect(layoutAfterSwipe(OnroadLayout.classic, towardsNext: false), OnroadLayout.classic);
  });

  group('on screen', () {
    late AppSettings settings;

    Future<void> show(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      settings = AppSettings();
      final state = createMockUIState();
      await tester.pumpWidget(MaterialApp(
        home: ListenableBuilder(
          listenable: settings,
          builder: (context, _) => AugmentedRoadView(uiState: state, settings: settings),
        ),
      ));
    }

    double pillOpacity(WidgetTester tester) => tester
        .widget<AnimatedOpacity>(find.ancestor(of: find.byKey(const ValueKey('layoutSwitchPill')), matching: find.byType(AnimatedOpacity)))
        .opacity;

    testWidgets('a long swipe left moves on a layout and shows its name for a moment', (tester) async {
      await show(tester);
      expect(pillOpacity(tester), 0);
      await tester.dragFrom(const Offset(1300, 600), const Offset(-700, 0));
      await tester.pump();
      expect(settings.layout, OnroadLayout.enhanced);
      expect(pillOpacity(tester), 1);
      expect(find.descendant(of: find.byKey(const ValueKey('layoutSwitchPill')), matching: find.text('Enhanced')),
          findsOneWidget);

      await tester.dragFrom(const Offset(600, 600), const Offset(700, 0));  // and back
      await tester.pump();
      expect(settings.layout, OnroadLayout.classic);

      await tester.pump(layoutPillDuration + const Duration(milliseconds: 300));
      expect(pillOpacity(tester), 0);
    });

    testWidgets('short drags and swipes from the screen edge do nothing', (tester) async {
      await show(tester);
      await tester.dragFrom(const Offset(1000, 600), const Offset(-150, 0));  // under a quarter, slow
      await tester.pump();
      expect(settings.layout, OnroadLayout.classic);
      await tester.dragFrom(const Offset(1910, 600), const Offset(-900, 0));  // Android's back gesture
      await tester.pump();
      expect(settings.layout, OnroadLayout.classic);
      expect(pillOpacity(tester), 0);
      await tester.pump(layoutPillDuration);
    });

    testWidgets('long press still opens the settings', (tester) async {
      await show(tester);
      await tester.longPress(find.byType(AugmentedRoadView));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
    });
  });
}
