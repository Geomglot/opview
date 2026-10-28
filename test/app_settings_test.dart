// viewer-side settings: storage, the clock, and the settings dialog

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/clock_renderer.dart';
import 'package:opview/selfdrive/ui/settings/settings_dialog.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _clock(ClockMode mode, DateTime time, {bool system24 = false}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(alwaysUse24HourFormat: system24),
      child: Stack(children: [ClockRenderer(mode: mode, scale: 1.0, now: () => time)]),
    ),
  );
}

void main() {
  group('formatClock', () {
    test('24 hour pads the hour', () {
      expect(formatClock(DateTime(2026, 10, 7, 9, 5), use24Hour: true), '09:05');
      expect(formatClock(DateTime(2026, 10, 7, 14, 30), use24Hour: true), '14:30');
      expect(formatClock(DateTime(2026, 10, 7, 0, 0), use24Hour: true), '00:00');
    });

    test('12 hour uses 12 for midnight and noon', () {
      expect(formatClock(DateTime(2026, 10, 7, 0, 7), use24Hour: false), '12:07 AM');
      expect(formatClock(DateTime(2026, 10, 7, 12, 0), use24Hour: false), '12:00 PM');
      expect(formatClock(DateTime(2026, 10, 7, 9, 5), use24Hour: false), '9:05 AM');
      expect(formatClock(DateTime(2026, 10, 7, 23, 59), use24Hour: false), '11:59 PM');
    });
  });

  group('AppSettings', () {
    test('defaults: a 12 hour clock, the speed limit on Auto, every panel open', () {
      final s = AppSettings();
      expect(s.clockMode, ClockMode.h12);
      expect(s.speedLimitDisplay, SpeedLimitDisplay.auto);
      expect(s.collapsedPanels, isEmpty);
    });

    test('a clock setting saved by an older build is ignored', () async {
      SharedPreferences.setMockInitialValues({'clock_mode': 'off'});
      final s = AppSettings();
      await s.load();
      expect(s.clockMode, ClockMode.h12);
    });

    test('saves and reloads 24 hour time', () async {
      SharedPreferences.setMockInitialValues({});
      final a = AppSettings();
      await a.setClock24Hour(true);
      expect(a.clockMode, ClockMode.h24);
      final b = AppSettings();
      await b.load();
      expect(b.clockMode, ClockMode.h24);
      await b.setClock24Hour(false);
      final c = AppSettings();
      await c.load();
      expect(c.clockMode, ClockMode.h12);
    });

    test('saves and reloads the speed limit choice', () async {
      SharedPreferences.setMockInitialValues({});
      final a = AppSettings();
      await a.load();
      await a.setSpeedLimitDisplay(SpeedLimitDisplay.off);

      final b = AppSettings();
      await b.load();
      expect(b.speedLimitDisplay, SpeedLimitDisplay.off);
    });

    test('an unknown saved value falls back to the default', () async {
      SharedPreferences.setMockInitialValues({'speed_limit_display': 'sometimes'});
      final s = AppSettings();
      await s.load();
      expect(s.speedLimitDisplay, SpeedLimitDisplay.auto);
    });

    test('notifies listeners on change only', () async {
      SharedPreferences.setMockInitialValues({});
      final s = AppSettings();
      var calls = 0;
      s.addListener(() => calls++);
      await s.setSpeedLimitDisplay(SpeedLimitDisplay.always);
      await s.setSpeedLimitDisplay(SpeedLimitDisplay.always);
      expect(calls, 1);
    });

    test('road name: shown by default, can be hidden, remembered', () async {
      SharedPreferences.setMockInitialValues({});
      final a = AppSettings();
      await a.load();
      expect(a.showRoadName, isTrue);
      await a.setShowRoadName(false);
      final b = AppSettings();
      await b.load();
      expect(b.showRoadName, isFalse);
    });

    test('picture-in-picture: on by default, can be turned off, remembered', () async {
      SharedPreferences.setMockInitialValues({});
      final a = AppSettings();
      await a.load();
      expect(a.pictureInPicture, isTrue);
      await a.setPictureInPicture(false);
      final b = AppSettings();
      await b.load();
      expect(b.pictureInPicture, isFalse);
    });

    test('the road name follows the app setting, not the comma one', () {
      final st = UIState()
        ..roadName = 'Main St'
        ..roadNameToggle = false;
      expect(st.showRoadName, isTrue);
      st.roadNameEnabled = false;
      expect(st.showRoadName, isFalse);
      st
        ..roadNameEnabled = true
        ..roadName = '';
      expect(st.showRoadName, isFalse);  // no name from the maps
    });

    test('folded Detailed panels toggle and are remembered', () async {
      SharedPreferences.setMockInitialValues({});
      final a = AppSettings();
      await a.load();
      await a.togglePanel('lead');
      await a.togglePanel('steering');
      await a.togglePanel('steering');
      expect(a.collapsedPanels, {'lead'});

      final b = AppSettings();
      await b.load();
      expect(b.collapsedPanels, {'lead'});
    });
  });

  group('ClockText', () {
    testWidgets('can draw AM/PM separately, for a smaller style', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: ClockText(
            mode: ClockMode.h12,
            style: const TextStyle(fontSize: 24),
            suffixStyle: const TextStyle(fontSize: 11),
            suffixGap: 5,
            now: () => DateTime(2026, 10, 7, 14, 5),
          ),
        ),
      ));
      expect(find.text('2:05'), findsOneWidget);
      expect(find.text('PM'), findsOneWidget);
      expect(tester.getRect(find.text('PM')).left, greaterThan(tester.getRect(find.text('2:05')).right));
    });

    testWidgets('24 hour time has no suffix to split off', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: ClockText(
            mode: ClockMode.h24,
            style: const TextStyle(fontSize: 24),
            suffixStyle: const TextStyle(fontSize: 11),
            now: () => DateTime(2026, 10, 7, 14, 5),
          ),
        ),
      ));
      expect(find.text('14:05'), findsOneWidget);
    });
  });

  group('settings menu', () {
    test('short names, in the order offered', () {
      expect(SpeedLimitDisplay.values.map(speedLimitDisplayLabel).toList(), ['Auto', 'Always', 'Off']);
      expect(OnroadLayout.values.map(onroadLayoutLabel).toList(), ['Classic', 'Enhanced', 'Detailed']);
    });

    Future<AppSettings> open(WidgetTester tester, {String? host, bool manual = false, VoidCallback? onChange}) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final settings = AppSettings();
      await tester.pumpWidget(MaterialApp(
        home: Material(
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSettingsDialog(context, settings,
                  host: host, hostIsManual: manual, onChangeHost: onChange, build: 'abc1234'),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return settings;
    }

    testWidgets('the clock choice switches between 12 and 24 hour time', (tester) async {
      final settings = await open(tester);
      expect(find.text('CLOCK'), findsOneWidget);
      await tester.tap(find.text('24 hr'));
      await tester.pumpAndSettle();
      expect(settings.clockMode, ClockMode.h24);
      await tester.tap(find.text('12 hr'));
      await tester.pumpAndSettle();
      expect(settings.clockMode, ClockMode.h12);
    });

    testWidgets('shows the comma address, how it was found, and the build', (tester) async {
      await open(tester, host: '192.168.1.50');
      expect(find.text('192.168.1.50'), findsOneWidget);
      expect(find.text('found automatically'), findsOneWidget);
      expect(find.text('OPRivView \u00B7 abc1234'), findsOneWidget);
      expect(find.text('Change'), findsNothing);  // no way to change it was given
      expect(tester.takeException(), isNull);
    });

    testWidgets('says when the address was typed in, and when there is none yet', (tester) async {
      await open(tester, host: '10.0.0.5', manual: true);
      expect(find.text('entered by hand'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsNothing);

      await open(tester);
      expect(find.text('Not found yet'), findsOneWidget);
      expect(find.text('searching the network'), findsOneWidget);
    });

    testWidgets('Change closes the menu and asks for the address', (tester) async {
      var asked = 0;
      await open(tester, host: '192.168.1.50', onChange: () => asked++);
      // the menu scrolls once it is taller than the screen
      await tester.ensureVisible(find.text('Change'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();
      expect(asked, 1);
      expect(find.text('Settings'), findsNothing);
    });

    testWidgets('fits a screen as short as the comma four shape', (tester) async {
      await open(tester, host: '192.168.1.50', onChange: () {});
      tester.view.physicalSize = const Size(1072, 480);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('ClockRenderer', () {
    final afternoon = DateTime(2026, 10, 7, 14, 5);

    testWidgets('24 hour mode', (tester) async {
      await tester.pumpWidget(_clock(ClockMode.h24, afternoon));
      expect(find.text('14:05'), findsOneWidget);
    });

    testWidgets('12 hour mode', (tester) async {
      await tester.pumpWidget(_clock(ClockMode.h12, afternoon, system24: true));
      expect(find.text('2:05 PM'), findsOneWidget);
    });

    testWidgets('system mode follows the device setting', (tester) async {
      await tester.pumpWidget(_clock(ClockMode.system, afternoon, system24: true));
      expect(find.text('14:05'), findsOneWidget);
      await tester.pumpWidget(_clock(ClockMode.system, afternoon, system24: false));
      await tester.pump();
      expect(find.text('2:05 PM'), findsOneWidget);
    });

    testWidgets('advances without any driving data arriving', (tester) async {
      var time = DateTime(2026, 10, 7, 14, 5, 58);
      await tester.pumpWidget(MaterialApp(
        home: Stack(children: [ClockRenderer(mode: ClockMode.h24, scale: 1.0, now: () => time)]),
      ));
      expect(find.text('14:05'), findsOneWidget);
      time = DateTime(2026, 10, 7, 14, 6, 0);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('14:06'), findsOneWidget);
    });
  });

  group('AugmentedRoadView settings', () {
    UIState connected() {
      final s = UIState();
      s.isConnected = true;
      return s;
    }

    // same full HD surface the screenshot tests use
    void fullHd(WidgetTester tester) {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets('Classic always shows a 12 hour clock', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: connected(), settings: AppSettings())));
      expect(find.byType(ClockRenderer), findsOneWidget);
      expect(tester.widget<ClockRenderer>(find.byType(ClockRenderer)).mode, ClockMode.h12);
    });

    testWidgets('the menu offers 12 or 24 hour time, but no way to hide the clock', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: connected(), settings: AppSettings())));
      await tester.longPress(find.byType(AugmentedRoadView));
      await tester.pumpAndSettle();
      expect(find.text('CLOCK'), findsOneWidget);
      expect(find.text('24 hr'), findsOneWidget);
      expect(find.text('SPEED LIMIT'), findsOneWidget);
      expect(find.text('ROAD NAME'), findsOneWidget);
    });

    testWidgets('picture-in-picture can be turned off from the menu', (tester) async {
      fullHd(tester);
      SharedPreferences.setMockInitialValues({});
      final settings = AppSettings();
      await settings.load();
      await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: connected(), settings: settings)));
      await tester.longPress(find.byType(AugmentedRoadView));
      await tester.pumpAndSettle();
      expect(find.text('PICTURE-IN-PICTURE'), findsOneWidget);
      // the speed limit row has an Off too; picture-in-picture is the last one
      await tester.ensureVisible(find.text('Off').last);
      await tester.tap(find.text('Off').last);
      await tester.pumpAndSettle();
      expect(settings.pictureInPicture, isFalse);
    });

    testWidgets('long press opens settings and a choice takes effect', (tester) async {
      fullHd(tester);
      SharedPreferences.setMockInitialValues({});
      final settings = AppSettings();
      await tester.pumpWidget(MaterialApp(
        home: ListenableBuilder(
          listenable: settings,
          builder: (context, _) => AugmentedRoadView(uiState: connected(), settings: settings),
        ),
      ));

      await tester.longPress(find.byType(AugmentedRoadView));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);

      await tester.tap(find.text('Always'));
      await tester.pumpAndSettle();
      expect(settings.speedLimitDisplay, SpeedLimitDisplay.always);

      await tester.tap(find.text('Enhanced'));
      await tester.pumpAndSettle();
      expect(settings.layout, OnroadLayout.enhanced);
    });

    testWidgets('settings are reachable from the connecting screen', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: UIState(), settings: AppSettings())));
      expect(find.text('Settings'), findsOneWidget);
    });
  });
}
