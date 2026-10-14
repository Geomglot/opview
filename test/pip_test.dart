// picture-in-picture: the small layout, and when the stream stops and restarts

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/app.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/pip_layout.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'golden/mock_ui_state.dart';

void _screen(WidgetTester tester, double w, double h) {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _app(UIState state, {AppSettings? settings}) =>
    MaterialApp(home: AugmentedRoadView(uiState: state, settings: settings ?? AppSettings(), pip: true));

void main() {
  group('PiP layout', () {
    for (final size in const [Size(480, 270), Size(320, 180), Size(1280, 720)]) {
      testWidgets('speed, MAX and lead at ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        _screen(tester, size.width, size.height);
        final state = createMockUIState();
        await tester.pumpWidget(_app(state));
        expect(tester.takeException(), isNull);
        expect(find.byType(PipLayout), findsOneWidget);
        expect(find.byKey(const ValueKey('pipSpeed')), findsOneWidget);
        expect(find.text('${state.displaySpeed.round()}'), findsOneWidget);
        expect(find.byKey(const ValueKey('pipMax')), findsOneWidget);
        expect(find.byKey(const ValueKey('pipLead')), findsOneWidget);
        expect(find.byKey(const ValueKey('pipBorder')), findsOneWidget);
      });
    }

    testWidgets('every layout setting shows the same PiP window', (tester) async {
      _screen(tester, 480, 270);
      for (final layout in OnroadLayout.values) {
        await tester.pumpWidget(_app(createMockUIState(), settings: AppSettings()..layout = layout));
        expect(find.byType(PipLayout), findsOneWidget, reason: '$layout');
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('no lead pill while disengaged', (tester) async {
      _screen(tester, 480, 270);
      await tester.pumpWidget(_app(createMockUIState(engaged: false)));
      expect(find.byKey(const ValueKey('pipLead')), findsNothing);
    });

    testWidgets('an alert shows as a banner', (tester) async {
      _screen(tester, 480, 270);
      await tester.pumpWidget(_app(createMockUIState(alertText1: 'TAKE CONTROL IMMEDIATELY', alertSize: 3, alertStatus: 2)));
      expect(find.byKey(const ValueKey('pipAlert')), findsOneWidget);
      expect(find.text('TAKE CONTROL IMMEDIATELY'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the speed limit pill follows the app setting', (tester) async {
      _screen(tester, 480, 270);
      final state = createMockUIState()
        ..paramsSeen = true
        ..speedLimitMode = 1
        ..speedLimitValid = true
        ..speedLimit = 25;
      await tester.pumpWidget(_app(state));
      expect(find.byKey(const ValueKey('pipLimit')), findsOneWidget);
      await tester.pumpWidget(_app(state, settings: AppSettings()..speedLimitDisplay = SpeedLimitDisplay.off));
      expect(find.byKey(const ValueKey('pipLimit')), findsNothing);
    });

    testWidgets('not connected: just a Connecting note', (tester) async {
      _screen(tester, 480, 270);
      final state = UIState();
      await tester.pumpWidget(_app(state));
      expect(find.text('Connecting…'), findsOneWidget);
      expect(find.byKey(const ValueKey('pipSpeed')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    test('lead text', () {
      expect(pipLeadText(30, 15, true), '30 m · 2.0 s');
      expect(pipLeadText(30, 0, false), '98 ft · –');
    });
  });

  group('LifecycleReconnect', () {
    test('PiP and the notification shade (inactive and back) do not reconnect', () {
      final l = LifecycleReconnect();
      expect(l.onChange(AppLifecycleState.inactive), LifecycleAction.none);
      expect(l.onChange(AppLifecycleState.resumed), LifecycleAction.none);
    });

    test('a real trip to the background pauses, and coming back reconnects once', () {
      final l = LifecycleReconnect();
      expect(l.onChange(AppLifecycleState.inactive), LifecycleAction.none);
      expect(l.onChange(AppLifecycleState.hidden), LifecycleAction.none);
      expect(l.onChange(AppLifecycleState.paused), LifecycleAction.pause);
      expect(l.onChange(AppLifecycleState.hidden), LifecycleAction.none);
      expect(l.onChange(AppLifecycleState.inactive), LifecycleAction.none);
      expect(l.onChange(AppLifecycleState.resumed), LifecycleAction.reconnect);
      expect(l.onChange(AppLifecycleState.inactive), LifecycleAction.none);
      expect(l.onChange(AppLifecycleState.resumed), LifecycleAction.none);
    });
  });
}
