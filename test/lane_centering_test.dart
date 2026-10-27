// lane centering indicator: its half second summary, the data it is fed, the per-layout bottom
// bar choice, and where each layout draws it

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/bottom_bar.dart';
import 'package:opview/selfdrive/ui/onroad/detailed/detailed_layout.dart';
import 'package:opview/selfdrive/ui/onroad/lane_centering.dart';
import 'package:opview/selfdrive/ui/settings/settings_dialog.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/impl/cereal_adapter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'golden/mock_ui_state.dart';

final _t0 = DateTime(2026, 10, 27, 12);

/// [n] samples 50 ms apart from [start]; returns the time after the last
DateTime _feed(LaneCenteringIndicator lc, LaneCenteringSample s, int n,
    {double vEgo = 20, required DateTime start}) {
  var t = start;
  for (var i = 0; i < n; i++) {
    lc.update(s, vEgo, t);
    t = t.add(const Duration(milliseconds: 50));
  }
  return t;
}

const _correcting = LaneCenteringSample(active: true, correction: 0.0005, offset: 0.12);
const _gated = LaneCenteringSample();
const _oneLine = LaneCenteringSample(active: true, correction: -0.0005, offset: 0.3, singleLine: true, lineSide: 1);

/// a UIState that lane centering would show on: its setting on and steering
UIState _steering() {
  final st = createMockUIState();
  st.paramsSeen = true;
  st.laneCenteringEnabled = true;
  st.latActive = true;
  st.vEgo = 20;
  st.isMetric = true;
  return st;
}

void main() {
  group('indicator', () {
    test('push is the correction times speed squared, latched for half a second', () {
      final lc = LaneCenteringIndicator();
      // the first sample commits at once; the next figure stands until 0.5 s later
      lc.update(_gated, 20, _t0);
      expect(lc.shownState, LaneCenteringState.gated);
      final t = _feed(lc, _correcting, 9, start: _t0.add(const Duration(milliseconds: 50)));
      expect(lc.shownState, LaneCenteringState.gated, reason: 'not yet half a second');
      lc.update(_correcting, 20, t);
      expect(lc.shownState, LaneCenteringState.correcting);
      expect(lc.shownPush, closeTo(0.0005 * 400, 1e-9));
      expect(lc.pushText, '0.20');
      expect(lc.shownColor, laneCenteringMint);
    });

    test('distance off center in cm or inches, with the side the car sits on', () {
      final lc = LaneCenteringIndicator();
      lc.update(_correcting, 20, _t0);
      expect(lc.offsetParts(isMetric: true), ('12L', 'cm'));
      expect(lc.offsetParts(isMetric: false), ('5L', 'in'));
      final right = LaneCenteringIndicator()
        ..update(const LaneCenteringSample(active: true, holding: true, offset: -0.05), 20, _t0);
      expect(right.offsetParts(isMetric: true), ('5R', 'cm'));
      final centered = LaneCenteringIndicator()..update(const LaneCenteringSample(active: true, holding: true), 20, _t0);
      expect(centered.offsetParts(isMetric: true), ('', 'on center'));
      expect(centered.stateLabel, 'centered');
      expect(LaneCenteringIndicator().offsetParts(isMetric: true), ('', ''));
    });

    test('no lines: gray, and the bar shows a gate dropout at once', () {
      final lc = LaneCenteringIndicator();
      _feed(lc, _correcting, 3, start: _t0);
      expect(lc.color, laneCenteringMint);
      lc.update(_gated, 20, _t0.add(const Duration(milliseconds: 150)));
      expect(lc.color, laneCenteringGray, reason: 'the bar is live');
      expect(lc.active, isFalse);
      expect(lc.shownState, LaneCenteringState.correcting, reason: 'the words are latched');
    });

    test('the bar is smoothed, not stepped', () {
      final lc = LaneCenteringIndicator();
      lc.update(_correcting, 20, _t0);
      expect(lc.push, closeTo(0.2, 1e-9), reason: 'the first sample is taken as it is');
      lc.update(const LaneCenteringSample(active: true, correction: 0.001), 20, _t0.add(const Duration(milliseconds: 50)));
      // tau 0.1 s, dt 0.05 s: a third of the way from 0.2 to 0.4
      expect(lc.push, closeTo(0.2 + 0.2 / 3, 1e-9));
      expect(lc.barFraction, closeTo((0.2 + 0.2 / 3) / laneCenteringFullScale, 1e-9));
    });

    test('One-Line Mode on most frames: light blue and the line side', () {
      final lc = LaneCenteringIndicator();
      lc.update(_gated, 20, _t0);
      final t = _feed(lc, _oneLine, 10, start: _t0.add(const Duration(milliseconds: 50)));
      lc.update(_oneLine, 20, t);
      expect(lc.shownSingleLine, isTrue);
      expect(lc.shownLineSide, 1);
      expect(lc.shownColor, laneCenteringLightBlue);
      expect(lc.color, laneCenteringLightBlue);
    });

    test('a line flickering into One-Line Mode on a few frames does not turn it blue', () {
      final lc = LaneCenteringIndicator();
      lc.update(_gated, 20, _t0);
      var t = _feed(lc, _correcting, 7, start: _t0.add(const Duration(milliseconds: 50)));
      t = _feed(lc, _oneLine, 3, start: t);
      lc.update(_correcting, 20, t);
      expect(lc.shownSingleLine, isFalse);
      expect(lc.shownLineSide, 0);
      expect(lc.shownColor, laneCenteringMint);
    });

    test('clipped on most frames is red; a hard push is amber', () {
      final clipped = LaneCenteringIndicator()
        ..update(const LaneCenteringSample(active: true, correction: 0.0005, clipped: true), 20, _t0);
      expect(clipped.shownColor, laneCenteringRed);
      expect(clipped.color, laneCenteringRed);
      final hard = LaneCenteringIndicator()
        ..update(const LaneCenteringSample(active: true, correction: 0.002), 20, _t0);
      expect(hard.shownColor, laneCenteringAmber);
    });
  });

  group('data', () {
    test('carControlSP feeds the indicator while lane centering is on and steering', () {
      final st = _steering();
      CerealAdapter().apply(st, '{"type":"carControlSP","data":{"laneCentering":'
          '{"active":true,"holding":false,"correction":0.0005,"offset":0.12}}}');
      expect(st.laneCenteringSeen, isTrue);
      expect(st.laneCenteringAvailable, isTrue);
      expect(st.laneCentering.visible, isTrue);
      expect(st.laneCentering.shownPush, closeTo(0.2, 1e-9));
    });

    test('hidden while not steering or with lane centering off on the comma', () {
      final st = _steering()..latActive = false;
      st.applyCarControlSP({'laneCentering': {'active': true}});
      expect(st.laneCentering.visible, isFalse);
      st
        ..latActive = true
        ..laneCenteringEnabled = false;
      st.applyCarControlSP({'laneCentering': {'active': true}});
      expect(st.laneCentering.visible, isFalse);
      expect(st.laneCenteringAvailable, isFalse);
    });

    test('a branch without lane centering leaves it unseen', () {
      final st = _steering();
      st.applyCarControlSP({'mads': {}});
      expect(st.laneCenteringSeen, isFalse);
      expect(st.laneCenteringAvailable, isFalse);
    });

    test('the device setting arrives with the other settings', () {
      final st = createMockUIState();
      st.applyOpviewParams({'LaneCenteringEnabled': true});
      expect(st.laneCenteringEnabled, isTrue);
      st.applyOpviewParams({});
      expect(st.laneCenteringEnabled, isFalse);
    });
  });

  group('bottom bar setting', () {
    test('each layout keeps what it showed before by default', () {
      final s = AppSettings();
      expect(s.bottomBarFor(OnroadLayout.classic), BottomBar.off);
      expect(s.bottomBarFor(OnroadLayout.enhanced), BottomBar.torque);
      expect(s.bottomBarFor(OnroadLayout.detailed), BottomBar.torque);
    });

    test('a tap cycles through every choice, Auto included, and wraps', () {
      expect(nextBottomBar(BottomBar.torque), BottomBar.laneCentering);
      expect(nextBottomBar(BottomBar.laneCentering), BottomBar.auto);
      expect(nextBottomBar(BottomBar.auto), BottomBar.off);
      expect(nextBottomBar(BottomBar.off), BottomBar.torque);
    });

    test('saved per layout', () async {
      SharedPreferences.setMockInitialValues({});
      final s = AppSettings();
      await s.setBottomBar(OnroadLayout.classic, BottomBar.laneCentering);
      await s.setBottomBar(OnroadLayout.detailed, BottomBar.auto);
      final again = AppSettings();
      await again.load();
      expect(again.bottomBarFor(OnroadLayout.classic), BottomBar.laneCentering);
      expect(again.bottomBarFor(OnroadLayout.enhanced), BottomBar.torque);
      expect(again.bottomBarFor(OnroadLayout.detailed), BottomBar.auto);
    });

    test('Auto: lane centering while it is on, the torque bar otherwise', () {
      final st = _steering();
      expect(shownBottomBar(BottomBar.auto, st), BottomBarShown.torque, reason: 'no lane centering data yet');
      st.applyCarControlSP({'laneCentering': {'active': true}});
      expect(shownBottomBar(BottomBar.auto, st), BottomBarShown.laneCentering);
      st.laneCenteringEnabled = false;
      expect(shownBottomBar(BottomBar.auto, st), BottomBarShown.torque);
      expect(shownBottomBar(BottomBar.off, st), BottomBarShown.none);
    });
  });

  group('on screen', () {
    late AppSettings settings;
    late UIState st;

    Future<void> show(WidgetTester tester, OnroadLayout layout, BottomBar choice) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      settings = AppSettings()..layout = layout;
      settings.bottomBars[layout] = choice;
      st = _steering();
      st.applyCarControlSP({'laneCentering': {'active': true, 'correction': 0.0005, 'offset': 0.12}});
      await tester.pumpWidget(MaterialApp(
        home: ListenableBuilder(
          listenable: settings,
          builder: (context, _) => AugmentedRoadView(uiState: st, settings: settings),
        ),
      ));
    }

    testWidgets('Enhanced: the lane centering arc and its figures take the torque bar\'s place', (tester) async {
      await show(tester, OnroadLayout.enhanced, BottomBar.laneCentering);
      expect(find.byKey(const ValueKey('bottomLaneCentering')), findsOneWidget);
      expect(find.byKey(const ValueKey('bottomTorqueBar')), findsNothing);
      expect(find.byKey(const ValueKey('laneCenteringCaption')), findsOneWidget);
      expect(find.text('0.20'), findsOneWidget);
      expect(find.text('12L'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Enhanced: Torque keeps the torque bar, Off shows neither', (tester) async {
      await show(tester, OnroadLayout.enhanced, BottomBar.torque);
      expect(find.byKey(const ValueKey('bottomTorqueBar')), findsOneWidget);
      expect(find.byKey(const ValueKey('laneCenteringCaption')), findsNothing);
      settings.bottomBars[OnroadLayout.enhanced] = BottomBar.off;
      settings.notifyListeners();
      await tester.pump();
      expect(find.byKey(const ValueKey('bottomTorqueBar')), findsNothing);
      expect(find.byKey(const ValueKey('bottomLaneCentering')), findsNothing);
    });

    testWidgets('Classic: the full form at the bottom, moved up above an alert', (tester) async {
      await show(tester, OnroadLayout.classic, BottomBar.laneCentering);
      final pill = find.byKey(const ValueKey('laneCenteringPill'));
      expect(pill, findsOneWidget);
      final low = tester.getRect(pill);
      expect(low.bottom, greaterThan(1080 * 0.9), reason: 'at the bottom of the screen');
      expect((low.center.dx - 960).abs(), lessThan(1));

      st
        ..alertSize = 1
        ..alertText1 = 'Steer Assist Active';
      st.notifyNow();
      settings.notifyListeners();
      await tester.pump();
      final raised = tester.getRect(pill);
      final alert = tester.getRect(find.text('Steer Assist Active'));
      expect(raised.bottom, lessThan(alert.top), reason: 'above the alert');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Classic: Torque now shows the torque bar too', (tester) async {
      await show(tester, OnroadLayout.classic, BottomBar.torque);
      expect(find.byKey(const ValueKey('bottomTorqueBar')), findsOneWidget);
      expect(find.byKey(const ValueKey('laneCenteringPill')), findsNothing);
    });

    testWidgets('Detailed: the arc, and lane centering rows in the STEERING panel', (tester) async {
      await show(tester, OnroadLayout.detailed, BottomBar.laneCentering);
      expect(find.byKey(const ValueKey('bottomLaneCentering')), findsOneWidget);
      expect(find.text('Centering'), findsOneWidget);
      expect(find.text('correcting · 12L cm'), findsOneWidget);
      expect(find.text('▶ 0.20 m/s²'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tap at the bottom centre cycles this layout\'s bottom bar and names it', (tester) async {
      await show(tester, OnroadLayout.enhanced, BottomBar.torque);
      await tester.tapAt(const Offset(960, 1040));
      await tester.pump();
      expect(settings.bottomBarFor(OnroadLayout.enhanced), BottomBar.laneCentering);
      expect(settings.bottomBarFor(OnroadLayout.classic), BottomBar.off, reason: 'other layouts keep theirs');
      expect(find.descendant(of: find.byKey(const ValueKey('bottomBarPill')), matching: find.text('Lane centering')),
          findsOneWidget);

      for (final next in [BottomBar.auto, BottomBar.off, BottomBar.torque]) {
        await tester.tapAt(const Offset(960, 1040));
        await tester.pump();
        expect(settings.bottomBarFor(OnroadLayout.enhanced), next);
      }
      await tester.pump(layoutPillDuration + const Duration(milliseconds: 300));
    });

    testWidgets('a tap away from the bottom centre changes nothing', (tester) async {
      await show(tester, OnroadLayout.enhanced, BottomBar.torque);
      await tester.tapAt(const Offset(960, 500));
      await tester.tapAt(const Offset(100, 1040));
      await tester.pump();
      expect(settings.bottomBarFor(OnroadLayout.enhanced), BottomBar.torque);
      await tester.pump(layoutPillDuration + const Duration(milliseconds: 300));
    });
  });

  testWidgets('the settings menu sets the bottom bar for the current layout only', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final settings = AppSettings()..layout = OnroadLayout.detailed;
    await tester.pumpWidget(MaterialApp(
      home: Material(
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSettingsDialog(context, settings, build: 'x'),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('BOTTOM BAR · DETAILED'), findsOneWidget);
    await tester.tap(find.text('Lane centering'));
    await tester.pumpAndSettle();
    expect(settings.bottomBarFor(OnroadLayout.detailed), BottomBar.laneCentering);
    expect(settings.bottomBarFor(OnroadLayout.enhanced), BottomBar.torque);
    // everything still fits without scrolling
    expect(tester.getRect(find.byKey(const ValueKey('brightnessSlider'))).bottom, lessThan(1080));
    expect(tester.getRect(find.byKey(const ValueKey('updatesRow'))).bottom, lessThan(1080));
  });

  test('Detailed rows while not steering are dashes', () {
    final st = _steering();
    st.applyCarControlSP({'laneCentering': {'active': true}});
    st.latActive = false;
    st.applyCarControlSP({'laneCentering': {'active': true}});
    expect(laneCenteringRows(st).map((r) => r.$2), [detailedNoValue, detailedNoValue]);
  });
}
