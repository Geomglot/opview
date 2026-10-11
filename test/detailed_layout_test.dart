// Detailed layout: its data, formatting, and the widget tree

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/detailed/detailed_layout.dart';
import 'package:opview/selfdrive/ui/onroad/enhanced/enhanced_layout.dart';
import 'package:opview/selfdrive/ui/onroad/model_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/top_row.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/impl/cereal_adapter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'golden/mock_ui_state.dart';

void _screen(WidgetTester tester, double w, double h) {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

AppSettings _detailed({SpeedLimitDisplay speedLimit = SpeedLimitDisplay.auto}) {
  final s = AppSettings();
  s.layout = OnroadLayout.detailed;
  s.speedLimitDisplay = speedLimit;
  return s;
}

/// the comma reports that speed limits are turned on
UIState _withLimits(UIState s) => s
  ..paramsSeen = true
  ..speedLimitMode = 1;

Widget _app(UIState state, AppSettings settings) =>
    MaterialApp(home: AugmentedRoadView(uiState: state, settings: settings));

void main() {
  group('formatting', () {
    test('acceleration, never -0.00', () {
      expect(formatAccel(-0.4249), '-0.42 m/s²');
      expect(formatAccel(-0.001), '0.00 m/s²');
      expect(formatAccelPair(0.824, -0.001), '0.82 / 0.00');
    });

    test('personality and gear', () {
      expect(formatPersonality('standard'), 'Standard');
      expect(formatPersonality(''), detailedNoValue);
      expect(formatGear('drive'), 'D');
      expect(formatGear('park'), 'P');
      expect(formatGear('unknown'), detailedNoValue);
      expect(formatGear('sport'), 'SPORT');
    });

    test('distance to the next speed limit', () {
      expect(formatNextLimitDistance(644, false), '0.4 mi');
      expect(formatNextLimitDistance(100, false), '350 ft');
      expect(formatNextLimitDistance(1500, true), '1.5 km');
      expect(formatNextLimitDistance(340, true), '350 m');
    });

    test('time to the lead only while closing', () {
      expect(timeToLead(30, -5), closeTo(6.0, 1e-9));
      expect(timeToLead(30, 0), isNull);
      expect(timeToLead(30, 2), isNull);
    });

    test('network bars', () {
      expect(networkBars('great'), 4);
      expect(networkBars('poor'), 1);
      expect(networkBars('unknown'), 0);
    });
  });

  group('data', () {
    test('speed limit: current, else the last known, else none', () {
      final s = UIState();
      expect(speedLimitToShow(s), isNull);
      s.speedLimitLastValid = true;
      s.speedLimitLast = 20;
      expect(speedLimitToShow(s), 20);
      s.speedLimitValid = true;
      s.speedLimit = 25;
      expect(speedLimitToShow(s), 25);
    });

    test('new car, control and device fields are read', () {
      final s = UIState();
      final a = CerealAdapter();
      a.apply(s, '{"type": "carState", "data": {"aEgo": -0.4, "steeringRateDeg": 3.2, "steeringTorque": 0.5, '
          '"gasPressed": true, "brakePressed": false, "gearShifter": "drive", "cruiseState": {"enabled": true}}}');
      a.apply(s, '{"type": "carControl", "data": {"latActive": true, "longActive": true, '
          '"actuators": {"accel": -0.6, "steeringAngleDeg": 4.0}}}');
      a.apply(s, '{"type": "selfdriveState", "data": {"enabled": true, "personality": "relaxed"}}');
      a.apply(s, '{"type": "controlsState", "data": {"curvature": 0.002, "desiredCurvature": 0.003, '
          '"lateralControlState": {"torqueState": {"saturated": true}}}}');
      a.apply(s, '{"type": "deviceState", "data": {"cpuTempC": [55.0, 61.5, 58.0], "memoryUsagePercent": 48, '
          '"freeSpacePercent": 28.0, "networkStrength": "good", "powerDrawW": 6.1}}');
      a.apply(s, '{"type": "liveCalibration", "data": {"calStatus": "calibrating", "calPerc": 42}}');
      expect(s.aEgo, -0.4);
      expect(s.steeringRateDeg, 3.2);
      expect(s.gasPressed, true);
      expect(s.gearShifter, 'drive');
      expect(s.cruiseEnabled, true);
      expect(s.longActive, true);
      expect(s.accelCommand, -0.6);
      expect(s.personality, 'relaxed');
      expect(s.lateralSaturated, true);
      expect(s.cpuTempC, 61.5);
      expect(s.memoryUsagePercent, 48);
      expect(s.networkStrength, 'good');
      expect(s.calPerc, 42);
    });

    test('radar match is held for a second so the badge does not flicker', () {
      var now = DateTime(2026, 10, 9, 12);
      final s = UIState()..clock = () => now;
      Map<String, dynamic> lead(bool radar) => {'leadOne': {'present': true, 'dRel': 30.0, 'radar': radar}};
      expect(s.leadRadarRecent, false);
      s.applyRadarState(lead(true));
      expect(s.leadRadarRecent, true);
      // the match drops out briefly: still shown as radar
      now = now.add(const Duration(milliseconds: 400));
      s.applyRadarState(lead(false));
      expect(s.leadRadarRecent, true);
      // a full second without a match: vision only
      now = now.add(const Duration(milliseconds: 700));
      s.applyRadarState(lead(false));
      expect(s.leadRadarRecent, false);
      // and never with no lead at all
      s.applyRadarState(lead(true));
      s.applyRadarState({'leadOne': {'present': false}});
      expect(s.leadRadarRecent, false);
    });

    test('sideways acceleration comes from the curvatures', () {
      final s = UIState()
        ..vEgo = 20
        ..curvature = 0.002
        ..desiredCurvature = 0.0025;
      expect(s.latAccelGot, closeTo(0.8, 1e-9));
      expect(s.latAccelWant, closeTo(1.0, 1e-9));
    });

    test('history keeps ten seconds, newest last', () {
      final s = UIState();
      for (var i = 0; i < UIState.historyLength + 30; i++) {
        s.aEgo = i.toDouble();
        s.applyModelV2({});
      }
      expect(s.accelActualHistory.length, UIState.historyLength);
      expect(s.accelActualHistory.last, (UIState.historyLength + 29).toDouble());
      // nothing commanded while openpilot is not in control of speed
      expect(s.accelCommandHistory.every((v) => v == 0), true);
    });
  });

  group('screen', () {
    testWidgets('draws every panel, on wide and short screens, without errors', (tester) async {
      for (final size in const [Size(1920, 1080), Size(1920, 720), Size(1280, 800)]) {
        _screen(tester, size.width, size.height);
        await tester.pumpWidget(_app(createMockUIState(), _detailed()));
        expect(find.byType(DetailedLayout), findsOneWidget);
        expect(find.text('STEERING'), findsOneWidget);
        expect(find.text('DRIVER'), findsOneWidget);
        expect(find.text('LONGITUDINAL'), findsOneWidget);
        expect(find.text('LEAD'), findsOneWidget);
        expect(find.byKey(const ValueKey('detailedClock')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '$size');
      }
    });

    testWidgets('mode badge: experimental or chill', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(_app(createMockUIState(experimentalMode: true), _detailed()));
      expect(find.byKey(const ValueKey('detailedExperimental')), findsOneWidget);
      await tester.pumpWidget(_app(createMockUIState(), _detailed()));
      expect(find.byKey(const ValueKey('detailedChill')), findsOneWidget);
    });

    testWidgets('speed limit pill: limit, next limit, or dashes', (tester) async {
      _screen(tester, 1920, 1080);
      final state = _withLimits(createMockUIState());
      state.isMetric = false;
      await tester.pumpWidget(_app(state, _detailed(speedLimit: SpeedLimitDisplay.always)));
      final pill = find.byKey(const ValueKey('topRowSpeedLimit'));
      expect(find.descendant(of: pill, matching: find.text('– –')), findsOneWidget);
      expect(find.descendant(of: pill, matching: find.byKey(const ValueKey('topRowSpeedLimitOutline'))), findsOneWidget);
      expect(find.byKey(const ValueKey('topRowNextLimit')), findsNothing);

      state
        ..speedLimitValid = true
        ..speedLimit = 45 / msToMph
        ..speedLimitAheadValid = true
        ..speedLimitAhead = 35 / msToMph
        ..speedLimitAheadDistance = 644;
      await tester.pumpWidget(_app(state, _detailed()));
      expect(find.descendant(of: pill, matching: find.text('45')), findsOneWidget);
      expect(find.byKey(const ValueKey('topRowNextLimit')), findsOneWidget);
      // set speed and speed limit are the same width
      final unit = enhancedUnit(const Size(1920, 1080));
      expect(tester.getSize(pill).width, closeTo(topRowSidePillWidth * unit, 0.01));
      expect(tester.getSize(find.byKey(const ValueKey('topRowSetSpeed'))).width, closeTo(topRowSidePillWidth * unit, 0.01));
    });

    testWidgets('speed limit setting: Auto waits for a limit, Off never shows it', (tester) async {
      _screen(tester, 1920, 1080);
      final state = _withLimits(createMockUIState());
      final pill = find.byKey(const ValueKey('topRowSpeedLimit'));
      await tester.pumpWidget(_app(state, _detailed()));
      expect(pill, findsNothing);

      state.applyLongitudinalPlanSP({
        'speedLimit': {
          'resolver': {'speedLimit': 20.0, 'speedLimitValid': true},
        },
      });
      await tester.pumpWidget(_app(state, _detailed()));
      expect(pill, findsOneWidget);

      // once seen it stays, even when the limit drops out
      state.applyLongitudinalPlanSP({});
      await tester.pumpWidget(_app(state, _detailed()));
      expect(pill, findsOneWidget);

      await tester.pumpWidget(_app(state, _detailed(speedLimit: SpeedLimitDisplay.off)));
      expect(pill, findsNothing);
    });

    testWidgets('tapping a panel folds it to its title, at the same width', (tester) async {
      _screen(tester, 1920, 1080);
      SharedPreferences.setMockInitialValues({});
      final settings = _detailed();
      final state = createMockUIState();
      await tester.pumpWidget(MaterialApp(
        home: ListenableBuilder(
          listenable: settings,
          builder: (context, _) => AugmentedRoadView(uiState: state, settings: settings),
        ),
      ));
      final panel = find.byKey(const ValueKey('detailedPanel_STEERING'));
      final open = tester.getSize(panel);
      expect(find.text('Mode'), findsOneWidget);
      expect(find.text('▾'), findsNWidgets(4));

      await tester.tap(find.text('STEERING'));
      await tester.pumpAndSettle();
      expect(settings.collapsedPanels, {'steering'});
      expect(find.text('Mode'), findsNothing);
      expect(find.descendant(of: panel, matching: find.text('▸')), findsOneWidget);
      expect(tester.getSize(panel).width, closeTo(open.width, 0.01));
      expect(tester.getSize(panel).height, lessThan(open.height / 3));
      // the other panels are untouched
      expect(find.text('Attention'), findsOneWidget);

      await tester.tap(find.text('STEERING'));
      await tester.pumpAndSettle();
      expect(settings.collapsedPanels, isEmpty);
      expect(find.text('Mode'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a folded panel hides its badge', (tester) async {
      _screen(tester, 1920, 1080);
      final settings = _detailed()..collapsedPanels.add('longitudinal');
      await tester.pumpWidget(_app(createMockUIState(experimentalMode: true), settings));
      expect(find.byKey(const ValueKey('detailedExperimental')), findsNothing);
      expect(find.text('LONGITUDINAL'), findsOneWidget);
    });

    testWidgets('driver icon and confidence indicator, the same size, side by side', (tester) async {
      _screen(tester, 1920, 1080);
      final state = createMockUIState()..dmSeen = true;
      await tester.pumpWidget(_app(state, _detailed()));
      final unit = enhancedUnit(const Size(1920, 1080));
      final driver = tester.getRect(find.byKey(const ValueKey('driverIcon')));
      final conf = tester.getRect(find.byKey(const ValueKey('confidenceIndicator')));
      expect(driver.width, closeTo(enhancedDriverIconSize * unit, 0.01));
      expect(conf.width, closeTo(driver.width, 0.01));
      expect(conf.height, closeTo(driver.height, 0.01));
      expect(conf.top, closeTo(driver.top, 0.01));
      expect(conf.left, closeTo(driver.right + 6 * unit, 0.01));
      // clear of the panels below
      expect(conf.bottom, lessThan(tester.getRect(find.byKey(const ValueKey('detailedPanel_STEERING'))).top));
    });

    testWidgets('lead panel: filled in with a lead, dashes while disengaged', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(_app(createMockUIState(), _detailed()));
      final panel = find.byType(DetailedLeadPanel);
      // mock: 18 m/s, lead 30 m ahead
      expect(find.descendant(of: panel, matching: find.text('1.7 s')), findsOneWidget);
      await tester.pumpWidget(_app(createMockUIState(engaged: false), _detailed()));
      expect(find.descendant(of: panel, matching: find.text(enhancedNoLeadValue)), findsNWidgets(6));
    });

    testWidgets('path is drawn like Enhanced: more solid and further out', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(_app(createMockUIState(), _detailed()));
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter)
          .whereType<ModelRendererPainter>()
          .single;
      expect(painter.pathOpacity, enhancedPathOpacity);
      expect(painter.maxPathDistance, enhancedPathDistance);
      expect(painter.pathFadeStop, enhancedPathFadeStop);
      // the second lead car in teal, not the warning colours
      expect(painter.secondLeadColor, detailedSecondLeadColor);
    });

    testWidgets('second lead row is teal when there is one', (tester) async {
      _screen(tester, 1920, 1080);
      final state = createMockUIState();
      state.applyRadarState({
        'leadOne': {'present': true, 'dRel': 30.0, 'vRel': -2.0, 'yRel': 0.0},
        'leadTwo': {'present': true, 'dRel': 60.0, 'vRel': 0.0, 'yRel': 1.0},
      });
      await tester.pumpWidget(_app(state, _detailed()));
      final value = find.descendant(
          of: find.byType(DetailedLeadPanel), matching: find.text(formatLeadDistance(60.0, state.isMetric)));
      expect(tester.widget<Text>(value).style?.color, detailedSecondLeadColor);
      expect(tester.takeException(), isNull);
    });

    testWidgets('alerts still show over the panels', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(_app(createMockUIState(alertText1: 'Pay Attention', alertSize: 1), _detailed()));
      expect(find.byKey(const ValueKey('enhancedAlertCard')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
