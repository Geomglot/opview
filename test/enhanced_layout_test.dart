// Enhanced layout: its data, formatting, and the widget tree

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/common/transformations.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/clock_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/enhanced/enhanced_layout.dart';
import 'package:opview/selfdrive/ui/onroad/hud_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/model_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/top_row.dart';
import 'package:opview/selfdrive/ui/onroad/turn_signal_renderer.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/impl/cereal_adapter.dart';
import 'package:opview/services/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'golden/mock_ui_state.dart';

void _screen(WidgetTester tester, double w, double h) {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

AppSettings _enhanced({ClockMode clock = ClockMode.h12}) {
  final s = AppSettings();
  s.layout = OnroadLayout.enhanced;
  s.clockMode = clock;
  return s;
}

Widget _app(UIState state, AppSettings settings) =>
    MaterialApp(home: AugmentedRoadView(uiState: state, settings: settings));

// comma four pixel size and the edge inset on the 1920x1080 test screen
const _unit = 1920 / 536;
const _edge = (enhancedBorderWidth + enhancedMargin) * _unit;

void main() {
  test('comma four pixel size fits its 536x240 screen inside any screen', () {
    expect(enhancedUnit(const Size(536, 240)), 1.0);
    // wide screens are limited by height, tall ones by width
    expect(enhancedUnit(const Size(1920, 720)), closeTo(3.0, 1e-9));
    expect(enhancedUnit(const Size(1024, 768)), closeTo(1024 / 536, 1e-9));
  });

  group('torqueBarValue', () {
    test('torque control: the car output torque, sign flipped', () {
      final s = UIState();
      s.applyControlsState({'lateralControlState': {'torqueState': {}}});
      s.applyCarOutput({'actuatorsOutput': {'torque': 0.4}});
      expect(s.torqueBarValue, closeTo(-0.4, 1e-9));
    });

    test('angle control: desired lateral acceleration over 3 m/s2, only while steering', () {
      final s = UIState();
      s.applyCarState({'vEgo': 20.0});
      s.applyControlsState({'desiredCurvature': 0.003, 'lateralControlState': {'angleState': {}}});
      expect(s.torqueBarValue, 0.0);
      s.applyCarControl({'latActive': true});
      expect(s.torqueBarValue, closeTo(0.003 * 400 / 3, 1e-9));
    });

    test('is limited to -1..1', () {
      final s = UIState();
      s.applyCarOutput({'actuatorsOutput': {'torque': -3.0}});
      expect(s.torqueBarValue, 1.0);
    });
  });

  group('driver monitoring', () {
    test('cone colour: green with full attention, orange once it runs down', () {
      expect(enhancedDriverConeColor(awarenessFull: true), const Color(0xFF00FF40));
      expect(enhancedDriverConeColor(awarenessFull: false), const Color(0xFFFF7300));
    });

    test('current openpilot message: policy, face, awareness and head direction', () {
      final s = UIState();
      expect(s.dmSeen, false);
      const msg = '{"type": "driverMonitoringState", "data": {"activePolicy": "vision", "isRHD": false, '
          '"visionPolicyState": {"faceDetected": true, "awarenessPercent": 80.0, "pose": {"pitch": 0.0, "yaw": 0.3}}}}';
      final adapter = CerealAdapter();
      for (var i = 0; i < 60; i++) {
        adapter.apply(s, msg);
      }
      expect(s.dmSeen, true);
      expect(s.dmActive, true);
      expect(s.dmFaceDetected, true);
      expect(s.dmAwarenessPercent, 80.0);
      expect(s.dmAwarenessUnfull, true);
      // 6 degrees of pitch are added and the yaw sign flipped, then atan2(2 * pitch, yaw)
      final expected = atan2(2 * 6 * pi / 180, -0.3) * 180 / pi;
      expect(s.dmRotationDeg, closeTo(expected, 0.5));
    });

    test('looking straight ahead points the cone up', () {
      final s = UIState();
      for (var i = 0; i < 60; i++) {
        s.applyDriverMonitoringState({
          'activePolicy': 'vision',
          'visionPolicyState': {'faceDetected': true, 'awarenessPercent': 100.0, 'pose': {'pitch': 0.0, 'yaw': 0.0}},
        });
      }
      expect(s.dmRotationDeg, closeTo(90, 0.5));
      expect(s.dmAwarenessUnfull, false);
    });

    test('a policy other than vision is not active', () {
      final s = UIState();
      s.applyDriverMonitoringState({'activePolicy': 'wheeltouch', 'visionPolicyState': {'awarenessPercent': 10.0}});
      expect(s.dmActive, false);
      expect(s.dmAwarenessUnfull, false);
    });

    test('older openpilot message with flat fields still works', () {
      final s = UIState();
      s.applyDriverMonitoringState({'faceDetected': true, 'isActiveMode': true, 'awarenessStatus': 0.5});
      expect(s.dmActive, true);
      expect(s.dmFaceDetected, true);
      expect(s.dmAwarenessPercent, 50.0);
      expect(s.dmAwarenessUnfull, true);
    });
  });

  group('steering readout', () {
    test('angles have one decimal and no negative zero', () {
      expect(formatSteeringAngle(12.34), '12.3°');
      expect(formatSteeringAngle(-3.26), '-3.3°');
      expect(formatSteeringAngle(-0.04), '0.0°');
      expect(formatSteeringAngle(0), '0.0°');
    });

    test('steering angle and target angle are read from the car messages', () {
      final s = UIState();
      s.applyCarState({'steeringAngleDeg': -12.5});
      expect(s.steeringAngleDeg, -12.5);
      s.applyCarControl({'latActive': true, 'actuators': {'steeringAngleDeg': 7.5}});
      expect(s.targetSteeringAngleDeg, 7.5);
      s.applyCarControl({'latActive': false});
      expect(s.targetSteeringAngleDeg, 0.0);
    });

    test('mode: nothing when not steering, else the Rivian mode or the controller in use', () {
      final s = UIState();
      s.lateralControlKind = 'torqueState';
      expect(s.steeringMode, isNull);
      s.latActive = true;
      expect(s.steeringMode, LateralMode.torque);
      s.lateralControlKind = 'angleState';
      expect(s.steeringMode, LateralMode.angle);
      // an angle-capable Rivian's own inference wins
      s.lateralMode = LateralMode.torque;
      expect(s.steeringMode, LateralMode.torque);
    });
  });

  group('lead car', () {
    test('lead info shows in every state except disengaged', () {
      for (final s in UIStatus.values) {
        expect(enhancedShowsLead(s), s != UIStatus.disengaged, reason: '$s');
      }
    });

    test('urgency rises as the lead gets closer or we close faster', () {
      expect(leadWarnLevel(60, 0), 0.0);          // far away
      expect(leadWarnLevel(60, -20), 0.0);        // far away, however fast we close
      expect(leadWarnLevel(30, 0), closeTo(0.25, 1e-9));
      expect(leadWarnLevel(30, -5), closeTo(0.75, 1e-9));
      expect(leadWarnLevel(30, 5), closeTo(0.25, 1e-9));  // pulling away adds nothing
      expect(leadWarnLevel(5, -10), 1.0);         // limited to 1
    });

    test('colour runs white, orange, red', () {
      expect(leadWarnColor(0.0).toARGB32(), 0xFFFFFFFF);
      expect(leadWarnColor(0.5).toARGB32(), 0xFFFF9A3C);
      expect(leadWarnColor(1.0).toARGB32(), 0xFFFF3B3B);
    });

    test('distance in metres or feet', () {
      expect(formatLeadDistance(32.4, true), '32 m');
      expect(formatLeadDistance(32.0, false), '105 ft');
    });

    test('time gap, with a dash when standing still', () {
      expect(formatLeadGap(30, 20), '1.5 s');
      expect(formatLeadGap(30, 0), '–');
    });

    test('speed difference carries its sign', () {
      expect(formatLeadRelSpeed(-2, msToMph, 'mph'), '-4 mph');
      expect(formatLeadRelSpeed(1, msToKph, 'km/h'), '+4 km/h');
      expect(formatLeadRelSpeed(0, msToMph, 'mph'), '0 mph');
    });

    test('active lead is the radar lead only while it reports one', () {
      final s = UIState();
      expect(s.activeLead, isNull);
      s.applyRadarState({'leadOne': {'status': false, 'dRel': 20.0}});
      expect(s.activeLead, isNull);
      s.applyRadarState({'leadOne': {'status': true, 'dRel': 20.0}});
      expect(s.activeLead, isNotNull);
    });

    test('newer cereal names the lead flag present instead of status', () {
      final s = UIState();
      s.applyRadarState({'leadOne': {'present': false, 'dRel': 20.0}});
      expect(s.activeLead, isNull);
      s.applyRadarState({'leadOne': {'present': true, 'dRel': 20.0}});
      expect(s.activeLead, isNotNull);
      expect(isLeadPresent(null), isFalse);
    });

    test('a radarState with Infinity in it still arrives', () {
      final s = UIState();
      const msg = '{"type": "radarState", "data": {"leadOne": {"present": true, '
          '"dRel": 20.0, "vRel": -1.0, "aLeadTau": Infinity, "aLeadK": -Infinity}}}';
      CerealAdapter().apply(s, msg);
      expect(s.activeLead, isNotNull);
      expect(s.activeLead!['dRel'], 20.0);
      expect(s.activeLead!['aLeadTau'], isNull);
    });
  });

  group('alerts', () {
    test('critical or full-size alerts take the screen, the rest are a card', () {
      expect(enhancedAlertIsFullScreen(1, 0), false);  // small notice
      expect(enhancedAlertIsFullScreen(2, 1), false);  // medium prompt
      expect(enhancedAlertIsFullScreen(1, 2), true);   // small but critical
      expect(enhancedAlertIsFullScreen(2, 2), true);
      expect(enhancedAlertIsFullScreen(3, 0), true);   // sent at full size
    });

    test('colour by severity', () {
      expect(enhancedAlertColor(1, fullScreen: false), const Color(0xF1DA6F25));
      expect(enhancedAlertColor(2, fullScreen: true), const Color(0xF1C92231));
      expect(enhancedAlertColor(0, fullScreen: false), isNot(enhancedAlertColor(1, fullScreen: false)));
    });
  });

  test('border colours cover every engagement state', () {
    final colours = {for (final status in UIStatus.values) enhancedBorderColor(status)};
    expect(colours.length, UIStatus.values.length);
  });

  test('the camera framing is the Classic one, without the border inset', () {
    // Classic at 1920x1080: zoom 1.1 inside a 30 px border
    final tici = deviceCameras[('tici', 'ar0231')]!.fcam;
    final classic = calcFrameTransform(
      camera: tici, calibration: viewFrameFromDeviceFrame, deviceZoom: 1.1, scale: 1.0,
      x: 30, y: 30, w: 1860, h: 1020,
    );
    final full = calcFrameTransform(
      camera: tici, calibration: viewFrameFromDeviceFrame, deviceZoom: 1.1, scale: 1.0,
      x: 0, y: 0, w: 1920, h: 1080,
    );
    expect(full.zoom, closeTo(classic.zoom, 1e-9));
    expect(full.videoWidth, closeTo(classic.videoWidth, 1e-6));
  });

  group('layout setting', () {
    test('defaults to Classic and is saved', () async {
      SharedPreferences.setMockInitialValues({});
      final a = AppSettings();
      await a.load();
      expect(a.layout, OnroadLayout.classic);
      await a.setLayout(OnroadLayout.enhanced);

      final b = AppSettings();
      await b.load();
      expect(b.layout, OnroadLayout.enhanced);
    });

    test('a layout saved under its old name is still Enhanced', () async {
      SharedPreferences.setMockInitialValues({'onroad_layout': 'miciExtended'});
      final s = AppSettings();
      await s.load();
      expect(s.layout, OnroadLayout.enhanced);
    });

    testWidgets('Classic draws the original HUD', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(_app(createMockUIState(), AppSettings()));
      expect(find.byType(HudRenderer), findsOneWidget);
      expect(find.byType(EnhancedLayout), findsNothing);
    });

    testWidgets('can be changed from the settings menu', (tester) async {
      _screen(tester, 1920, 1080);
      SharedPreferences.setMockInitialValues({});
      final settings = AppSettings();
      await tester.pumpWidget(MaterialApp(
        home: ListenableBuilder(
          listenable: settings,
          builder: (context, _) => AugmentedRoadView(uiState: createMockUIState(), settings: settings),
        ),
      ));

      await tester.longPress(find.byType(AugmentedRoadView));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enhanced'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(settings.layout, OnroadLayout.enhanced);
      expect(find.byType(EnhancedLayout), findsOneWidget);
      expect(find.byType(HudRenderer), findsNothing);
    });
  });

  group('overlay painter', () {
    ModelRendererPainter painterOf(WidgetTester tester) {
      final paints = tester.widgetList<CustomPaint>(find.byType(CustomPaint));
      return paints.map((p) => p.painter).whereType<ModelRendererPainter>().single;
    }

    testWidgets('edge lines and the lead box are on in Enhanced and off in Classic', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(_app(createMockUIState(), _enhanced()));
      expect(painterOf(tester).pathEdgeLines, true);
      expect(painterOf(tester).leadReticle, true);
      expect(painterOf(tester).leadTagMinTop, greaterThan(_edge));
      expect(tester.takeException(), isNull);
      expect(painterOf(tester).showLeads, true);
      expect(painterOf(tester).pathOpacity, enhancedPathOpacity);
      expect(painterOf(tester).maxPathDistance, enhancedPathDistance);
      expect(painterOf(tester).pathFadeStop, enhancedPathFadeStop);

      await tester.pumpWidget(_app(createMockUIState(engaged: false), _enhanced()));
      expect(painterOf(tester).showLeads, false);

      await tester.pumpWidget(_app(createMockUIState(), AppSettings()));
      expect(painterOf(tester).pathEdgeLines, false);
      expect(painterOf(tester).leadReticle, false);
      // Classic keeps the stock path
      expect(painterOf(tester).pathOpacity, 1.0);
      expect(painterOf(tester).maxPathDistance, maxDrawDistance);
      expect(painterOf(tester).pathFadeStop, 0.5);
    });

    testWidgets('paints without errors in every state and at every lead distance', (tester) async {
      _screen(tester, 1920, 1080);
      final states = [
        createMockUIState(),
        createMockUIState(engaged: false),
        createMockUIState(experimentalMode: true),
        createMockUIState(leadDRel: 4.0),    // very close: the tag tucks into the box
        createMockUIState(leadDRel: 95.0),   // far
        createMockUIState(leadDRel: 0),      // no lead
      ];
      // two different cars ahead
      final two = createMockUIState(leadDRel: 20.0);
      two.leadTwo = {'status': true, 'dRel': 45.0, 'yRel': 0.3, 'vRel': 1.0};
      states.add(two);
      // imperial distance tag
      final imperial = createMockUIState();
      imperial.isMetric = false;
      states.add(imperial);

      for (final state in states) {
        await tester.pumpWidget(_app(state, _enhanced()));
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('EnhancedLayout', () {
    testWidgets('the camera view fills the screen; the speed is centred with its unit below', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(_app(createMockUIState(), _enhanced()));
      expect(tester.getSize(find.byType(EnhancedLayout)), const Size(1920, 1080));
      // 18 m/s is 64.8 km/h
      final speed = tester.getRect(find.text('65'));
      final unit = tester.getRect(find.text('km/h'));
      expect(speed.center.dx, closeTo(960, 1.0));
      expect(unit.center.dx, closeTo(960, 1.0));
      expect(unit.top, greaterThanOrEqualTo(speed.bottom - 1));
      expect(speed.top, lessThan(1080 * 0.3));
    });

    testWidgets('set speed and speed limit are matching pills either side of the speed, tops in line', (tester) async {
      _screen(tester, 1920, 1080);
      final state = createMockUIState()
        ..paramsSeen = true
        ..speedLimitMode = 1
        ..speedLimitValid = true
        ..speedLimit = 25;
      await tester.pumpWidget(_app(state, _enhanced()));
      expect(find.byType(SpeedTopRow), findsOneWidget);
      expect(find.text('MAX'), findsOneWidget);
      expect(find.text('80'), findsOneWidget);
      expect(find.text('LIMIT'), findsOneWidget);

      final max = tester.getRect(find.byKey(const ValueKey('topRowSetSpeed')));
      final limit = tester.getRect(find.byKey(const ValueKey('topRowSpeedLimit')));
      final speed = tester.getRect(find.ancestor(of: find.text('65'), matching: find.byType(Container)).first);
      expect(limit.width, closeTo(max.width, 0.01));
      expect(limit.height, closeTo(max.height, 0.01));
      expect(max.width, closeTo(topRowSidePillWidth * _unit, 0.01));
      expect(max.height, closeTo(topRowSidePillHeight * _unit, 0.01));
      // mirrored about the centre of the screen, tops level with the speed pill
      expect(960 - max.right, closeTo(limit.left - 960, 0.01));
      expect(max.top, closeTo(speed.top, 0.01));
      expect(limit.top, closeTo(speed.top, 0.01));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a small 12 hour clock in the top right corner', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(_app(createMockUIState(), _enhanced()));
      final clock = find.byKey(const ValueKey('enhancedClock'));
      final r = tester.getRect(clock);
      expect(r.right, closeTo(1920 - _edge, 0.01));
      expect(r.top, closeTo(_edge, 0.01));
      expect(r.width, closeTo(enhancedClockWidth * _unit, 0.01));
      expect(r.height, closeTo(enhancedClockHeight * _unit, 0.01));
      expect(tester.widget<ClockText>(find.descendant(of: clock, matching: find.byType(ClockText))).mode, ClockMode.h12);
      // the speed stays centred with nothing beside it
      expect(tester.getRect(find.text('65')).center.dx, closeTo(960, 1.0));
    });

    testWidgets('speed limit pill follows the setting', (tester) async {
      _screen(tester, 1920, 1080);
      final state = createMockUIState()
        ..paramsSeen = true
        ..speedLimitMode = 1;
      final pill = find.byKey(const ValueKey('topRowSpeedLimit'));
      await tester.pumpWidget(_app(state, _enhanced()));
      expect(pill, findsNothing);  // Auto, and no limit yet
      await tester.pumpWidget(_app(state, _enhanced()..speedLimitDisplay = SpeedLimitDisplay.always));
      expect(find.descendant(of: pill, matching: find.text('– –')), findsOneWidget);
      // turned off on the comma: never shown
      state.speedLimitMode = speedLimitModeOff;
      await tester.pumpWidget(_app(state, _enhanced()..speedLimitDisplay = SpeedLimitDisplay.always));
      expect(pill, findsNothing);
    });

    testWidgets('lays out without errors on every screen shape', (tester) async {
      for (final (w, h) in const [(1920.0, 1080.0), (1024.0, 768.0), (1280.0, 480.0), (844.0, 390.0), (1920.0, 720.0)]) {
        _screen(tester, w, h);
        final state = createMockUIState();
        state.paramsSeen = true;
        state.showBlindSpot = true;
        state.leftBlindspot = true;
        state.rightBlindspot = true;
        state.roadNameToggle = true;
        state.roadName = 'Cam Fella Boulevard';
        state.applyCarControl({'latActive': true, 'actuators': {'steeringAngleDeg': -112.6}});
        state.applyDriverMonitoringState({'faceDetected': true});
        await tester.pumpWidget(_app(state, _enhanced(clock: ClockMode.h12)));
        expect(tester.takeException(), isNull, reason: '${w}x$h');
        expect(find.text('Cam Fella Boulevard'), findsOneWidget, reason: '${w}x$h');
      }
    });

    testWidgets('road name follows the app setting', (tester) async {
      _screen(tester, 1920, 1080);
      final state = createMockUIState()
        ..roadNameToggle = false  // the comma's own setting no longer matters
        ..roadName = 'Cam Fella Boulevard';
      await tester.pumpWidget(_app(state, _enhanced()));
      expect(find.text('Cam Fella Boulevard'), findsOneWidget);
      // the small see-through pill, just under the speed
      final pill = tester.getRect(find.byKey(const ValueKey('roadNamePill')));
      expect(pill.height, closeTo(roadNamePillHeight * _unit, 0.01));
      expect(pill.top, closeTo(_edge + (enhancedSpeedPillHeight + roadNameGap) * _unit, 0.01));
      await tester.pumpWidget(_app(state, _enhanced()..showRoadName = false));
      expect(find.text('Cam Fella Boulevard'), findsNothing);
    });

    testWidgets('imperial units show mph, and no speed limit sign is drawn', (tester) async {
      _screen(tester, 1920, 1080);
      final state = createMockUIState(leadDRel: 0);
      state.isMetric = false;
      state.paramsSeen = true;
      state.speedLimitMode = 1;
      state.speedLimitValid = true;
      state.speedLimitLast = 13.4;  // 30 mph
      state.speedLimitFinalLast = 13.4;
      await tester.pumpWidget(_app(state, _enhanced()));
      expect(find.text('mph'), findsOneWidget);
      expect(find.text('40'), findsOneWidget);  // 18 m/s
      expect(find.text('30'), findsNothing);
      expect(find.text('SPEED'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('driver monitoring icon appears once its data arrives', (tester) async {
      _screen(tester, 1920, 1080);
      final state = createMockUIState();
      await tester.pumpWidget(_app(state, _enhanced()));
      expect(find.byIcon(Icons.person), findsNothing);

      state.applyDriverMonitoringState({'faceDetected': true, 'isDistracted': false});
      await tester.pumpWidget(_app(state, _enhanced()));
      expect(find.byIcon(Icons.person), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('driver icon is live only while engaged and camera monitoring runs', () {
      final s = createMockUIState();
      s.applyDriverMonitoringState({'activePolicy': 'vision', 'visionPolicyState': {'faceDetected': true}});
      expect(enhancedDriverIconLive(s), true);
      s.status = UIStatus.disengaged;
      expect(enhancedDriverIconLive(s), false);
      s.status = UIStatus.latOnly;
      s.applyDriverMonitoringState({'activePolicy': 'wheelTouch', 'visionPolicyState': {'faceDetected': false}});
      expect(enhancedDriverIconLive(s), false);
    });

    testWidgets('disengaged: the driver icon stays, dimmed and empty, and it still draws', (tester) async {
      _screen(tester, 1920, 1080);
      final state = createMockUIState(engaged: false, vCruiseCluster: 0);
      state.applyDriverMonitoringState({'faceDetected': true});
      await tester.pumpWidget(_app(state, _enhanced()));
      expect(find.byType(EnhancedLayout), findsOneWidget);
      expect(find.byIcon(Icons.person), findsOneWidget);
      final icon = tester.widget<Opacity>(find.ancestor(of: find.byIcon(Icons.person), matching: find.byType(Opacity)).first);
      expect(icon.opacity, lessThan(1.0));
      expect(tester.takeException(), isNull);
    });
  });

  group('confidence', () {
    test('the target follows the disengage predictions for the active mode', () {
      final s = createMockUIState();
      s.applyModelV2({
        'meta': {
          'disengagePredictions': {
            'brakeDisengageProbs': [0.1, 0.4],
            'steerOverrideProbs': [0.2, 0.05],
          },
        },
      });
      expect(s.confidenceSeen, true);
      s.status = UIStatus.engaged;
      expect(s.confidenceTarget, closeTo(0.6 * 0.8, 1e-9));
      s.status = UIStatus.latOnly;
      expect(s.confidenceTarget, closeTo(0.8, 1e-9));
      s.status = UIStatus.longOnly;
      expect(s.confidenceTarget, closeTo(0.6, 1e-9));
    });

    test('the shown value eases towards the target rather than jumping', () {
      final s = createMockUIState()..status = UIStatus.engaged;
      final bad = {
        'meta': {
          'disengagePredictions': {'brakeDisengageProbs': [0.9], 'steerOverrideProbs': [0.0]},
        },
      };
      s.applyModelV2(bad);
      expect(s.confidenceFiltered, lessThan(1.0));
      expect(s.confidenceFiltered, greaterThan(0.5));
      for (var i = 0; i < 100; i++) {
        s.applyModelV2(bad);
      }
      expect(s.confidenceFiltered, closeTo(0.1, 0.01));
    });

    test('dot size and colour', () {
      expect(confidenceDotRadius(0), closeTo(0.08, 1e-9));
      expect(confidenceDotRadius(1), closeTo(0.34, 1e-9));
      expect(confidenceDotRadius(2), closeTo(0.34, 1e-9));
      expect(confidenceColors(0.9).$1, const Color(0xFF00FFCC));
      expect(confidenceColors(0.3).$1, const Color(0xFFFFC800));
      expect(confidenceColors(0.1).$1, const Color(0xFFFF0015));
    });

    testWidgets('beside the driver icon, the same size; empty and dimmed until engaged with data', (tester) async {
      _screen(tester, 1920, 1080);
      final state = createMockUIState();
      state.applyDriverMonitoringState({'faceDetected': true});
      await tester.pumpWidget(_app(state, _enhanced()));
      final ind = find.byKey(const ValueKey('confidenceIndicator'));
      final driver = tester.getRect(find.byKey(const ValueKey('driverIcon')));
      final conf = tester.getRect(ind);
      expect(driver.width, closeTo(enhancedDriverIconSize * _unit, 0.01));
      expect(conf.width, closeTo(driver.width, 0.01));
      expect(conf.height, closeTo(driver.height, 0.01));
      expect(conf.top, closeTo(_edge, 0.01));
      expect(conf.left, closeTo(driver.right + 6 * _unit, 0.01));

      ConfidencePainter painter() => tester
          .widgetList<CustomPaint>(find.descendant(of: ind, matching: find.byType(CustomPaint)))
          .map((p) => p.painter)
          .whereType<ConfidencePainter>()
          .single;
      Opacity opacity() => tester.widget<Opacity>(find.descendant(of: ind, matching: find.byType(Opacity)));
      // no predictions yet
      expect(painter().confidence, isNull);
      expect(opacity().opacity, lessThan(1.0));

      state.applyModelV2({
        'meta': {
          'disengagePredictions': {'brakeDisengageProbs': [0.0], 'steerOverrideProbs': [0.0]},
        },
      });
      await tester.pumpWidget(_app(state, _enhanced()));
      expect(painter().confidence, isNotNull);
      expect(opacity().opacity, 1.0);

      state.status = UIStatus.disengaged;
      await tester.pumpWidget(_app(state, _enhanced()));
      expect(painter().confidence, isNull);
      expect(tester.takeException(), isNull);
    });
  });

  group('readouts', () {
    testWidgets('steering: mode, target and actual angle, bottom left', (tester) async {
      _screen(tester, 1920, 1080);
      final state = createMockUIState();
      state.applyCarControl({'latActive': true, 'actuators': {'steeringAngleDeg': 12.34}});
      state.steeringAngleDeg = -3.26;
      state.lateralControlKind = 'angleState';
      await tester.pumpWidget(_app(state, _enhanced()));
      final pills = find.byType(EnhancedSteeringPills);
      expect(find.descendant(of: pills, matching: find.text('ANGLE')), findsOneWidget);
      expect(find.descendant(of: pills, matching: find.text('12.3°')), findsOneWidget);
      expect(find.descendant(of: pills, matching: find.text('-3.3°')), findsOneWidget);
      final rect = tester.getRect(pills);
      expect(rect.left, closeTo(_edge, 0.01));
      expect(rect.bottom, closeTo(1080 - _edge, 0.01));
      expect(tester.takeException(), isNull);
    });

    testWidgets('steering: OFF and no target when openpilot is not steering', (tester) async {
      _screen(tester, 1920, 1080);
      final state = createMockUIState();
      state.steeringAngleDeg = 1.0;
      await tester.pumpWidget(_app(state, _enhanced()));
      final pills = find.byType(EnhancedSteeringPills);
      expect(find.descendant(of: pills, matching: find.text('OFF')), findsOneWidget);
      expect(find.descendant(of: pills, matching: find.text('–')), findsOneWidget);
      expect(find.descendant(of: pills, matching: find.text('1.0°')), findsOneWidget);
    });

    testWidgets('lead: gap, speed difference and lead speed, flush with the right edge', (tester) async {
      _screen(tester, 1920, 1080);
      // mock: 18 m/s, lead 30 m ahead and 2 m/s slower
      await tester.pumpWidget(_app(createMockUIState(), _enhanced()));
      final pills = find.byType(EnhancedLeadPills);
      expect(find.descendant(of: pills, matching: find.text('1.7 s')), findsOneWidget);
      expect(find.descendant(of: pills, matching: find.text('-7 km/h')), findsOneWidget);
      expect(find.descendant(of: pills, matching: find.text('58 km/h')), findsOneWidget);
      final rect = tester.getRect(pills);
      expect(rect.right, closeTo(1920 - _edge, 0.01));
      expect(rect.bottom, closeTo(1080 - _edge, 0.01));
      expect(tester.takeException(), isNull);
    });

    testWidgets('both readouts are the same size, mirrored left and right', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(_app(createMockUIState(), _enhanced()));
      final steering = tester.getRect(find.byType(EnhancedSteeringPills));
      final lead = tester.getRect(find.byType(EnhancedLeadPills));
      expect(steering.width, closeTo(enhancedInfoPillWidth * _unit, 0.01));
      expect(lead.size.width, closeTo(steering.size.width, 0.01));
      expect(lead.size.height, closeTo(steering.size.height, 0.01));
      expect(steering.left, closeTo(1920 - lead.right, 0.01));
    });

    testWidgets('lead readout stays with dashes when there is no lead car', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(_app(createMockUIState(leadDRel: 0), _enhanced()));
      final pills = find.byType(EnhancedLeadPills);
      expect(find.descendant(of: pills, matching: find.text('GAP')), findsOneWidget);
      expect(find.descendant(of: pills, matching: find.text(enhancedNoLeadValue)), findsNWidgets(3));
      expect(tester.getRect(pills).height, closeTo(tester.getRect(find.byType(EnhancedSteeringPills)).height, 0.01));
    });

    testWidgets('lead readout dashes out while disengaged, even with a lead car', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(_app(createMockUIState(engaged: false), _enhanced()));
      final pills = find.byType(EnhancedLeadPills);
      expect(find.descendant(of: pills, matching: find.text(enhancedNoLeadValue)), findsNWidgets(3));
      expect(find.descendant(of: pills, matching: find.text('1.7 s')), findsNothing);
    });

    testWidgets('lead readout is filled in while steering only', (tester) async {
      _screen(tester, 1920, 1080);
      final state = createMockUIState();
      state.status = UIStatus.latOnly;
      await tester.pumpWidget(_app(state, _enhanced()));
      final pills = find.byType(EnhancedLeadPills);
      expect(find.descendant(of: pills, matching: find.text('1.7 s')), findsOneWidget);
      expect(find.descendant(of: pills, matching: find.text(enhancedNoLeadValue)), findsNothing);
    });
  });

  group('alerts on screen', () {
    testWidgets('a notice is a card between the readouts, and the driver icon stays', (tester) async {
      _screen(tester, 1920, 1080);
      final state = createMockUIState(alertText1: 'Pay Attention', alertSize: 1);
      state.applyDriverMonitoringState({'faceDetected': true});
      await tester.pumpWidget(_app(state, _enhanced()));

      final card = tester.getRect(find.byKey(const ValueKey('enhancedAlertCard')));
      expect(find.byKey(const ValueKey('enhancedAlertFull')), findsNothing);
      expect(find.text('Pay Attention'), findsOneWidget);
      expect(card.center.dx, closeTo(960, 1.0));
      expect(card.left, greaterThan(tester.getRect(find.byType(EnhancedSteeringPills)).right));
      expect(card.right, lessThan(tester.getRect(find.byType(EnhancedLeadPills)).left));
      expect(card.top, greaterThan(1080 * 0.5));
      expect(find.byIcon(Icons.person), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a medium alert shows its second line; a small one does not', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(_app(
        createMockUIState(alertText1: 'Touch Steering Wheel', alertText2: 'Driver Unresponsive', alertSize: 2, alertStatus: 1),
        _enhanced(),
      ));
      expect(find.text('Touch Steering Wheel'), findsOneWidget);
      expect(find.text('Driver Unresponsive'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(_app(
        createMockUIState(alertText1: 'Pay Attention', alertText2: 'not shown', alertSize: 1),
        _enhanced(),
      ));
      expect(find.text('not shown'), findsNothing);
    });

    testWidgets('a critical alert takes the whole screen even when sent small', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(_app(
        createMockUIState(alertText1: 'BRAKE!', alertText2: 'Risk of Collision', alertSize: 1, alertStatus: 2),
        _enhanced(),
      ));
      expect(find.byKey(const ValueKey('enhancedAlertCard')), findsNothing);
      expect(tester.getSize(find.byKey(const ValueKey('enhancedAlertFull'))), const Size(1920, 1080));
      expect(find.text('BRAKE!'), findsOneWidget);
      expect(find.text('Risk of Collision'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a full-size alert takes the whole screen', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(_app(
        createMockUIState(
          alertText1: 'TAKE CONTROL IMMEDIATELY',
          alertText2: 'Steering Temporarily Unavailable',
          alertSize: 3,
          alertStatus: 1,
        ),
        _enhanced(),
      ));
      expect(find.byKey(const ValueKey('enhancedAlertFull')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('blind spot', () {
    UIState withBlindSpots({required bool show, bool left = false, bool right = false}) {
      final state = createMockUIState();
      state.showBlindSpot = show;
      state.showTurnSignals = true;
      state.leftBlindspot = left;
      state.rightBlindspot = right;
      state.leftBlinker = true;
      return state;
    }

    testWidgets('a glow on the occupied side only', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(_app(withBlindSpots(show: true, right: true), _enhanced()));
      expect(find.byKey(const ValueKey('blindSpotLeft')), findsNothing);
      final glow = tester.getRect(find.byKey(const ValueKey('blindSpotRight')));
      expect(glow.right, 1920);
      expect(glow.height, 1080);
      expect(glow.width, closeTo(enhancedGlowWidth * _unit, 0.01));

      await tester.pumpWidget(_app(withBlindSpots(show: true, left: true, right: true), _enhanced()));
      expect(tester.getRect(find.byKey(const ValueKey('blindSpotLeft'))).left, 0);
      expect(find.byKey(const ValueKey('blindSpotRight')), findsOneWidget);
    });

    testWidgets('nothing when the comma has blind spot display turned off', (tester) async {
      _screen(tester, 1920, 1080);
      await tester.pumpWidget(_app(withBlindSpots(show: false, left: true, right: true), _enhanced()));
      expect(find.byKey(const ValueKey('blindSpotLeft')), findsNothing);
      expect(find.byKey(const ValueKey('blindSpotRight')), findsNothing);
    });

    testWidgets('no turn signal or blind spot icons in this layout; Classic keeps them', (tester) async {
      _screen(tester, 1920, 1080);
      final state = withBlindSpots(show: true, left: true);
      await tester.pumpWidget(_app(state, _enhanced()));
      expect(find.byType(TurnSignalRenderer), findsNothing);

      await tester.pumpWidget(_app(state, AppSettings()));
      expect(find.byType(TurnSignalRenderer), findsOneWidget);
    });
  });
}
