// in-app updates: version compare, the GitHub release, and the Settings row

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opview/selfdrive/ui/settings/settings_dialog.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/updater.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _release(String tag, {bool apk = true}) => {
      'tag_name': tag,
      'body': "## What's Changed\n\n- Swipe sideways to change the layout\n- Smaller road name\n\n## Download\n\n- **OPRivView APK**",
      'assets': [
        if (apk)
          {'name': 'OPRivView-${tag.substring(1)}.apk', 'browser_download_url': 'https://example.invalid/a.apk', 'size': 19000000},
      ],
    };

Updater _updater(String installed, http.Response Function() answer) =>
    Updater(installed: installed, client: () => MockClient((_) async => answer()));

void main() {
  group('versions', () {
    test('a later release is newer, the same or an earlier one is not', () {
      expect(isNewerVersion('0.1.1-mici.5', '0.1.1-mici.4'), isTrue);
      expect(isNewerVersion('0.1.2-mici.1', '0.1.1-mici.9'), isTrue);
      expect(isNewerVersion('0.1.1-mici.10', '0.1.1-mici.9'), isTrue);
      expect(isNewerVersion('0.1.1-mici.5', '0.1.1-mici.5'), isFalse);
      expect(isNewerVersion('0.1.1-mici.4', '0.1.1-mici.5'), isFalse);
    });

    test('a branch or dev build can always update to a release', () {
      expect(isNewerVersion('0.1.1-mici.5', 'layouts-1143043'), isTrue);
      expect(isNewerVersion('0.1.1-mici.5', 'dev build'), isTrue);
    });

    test('release notes: the change lines only', () {
      expect(releaseNoteLines(_release('v0.1.1-mici.5')['body'] as String),
          ['Swipe sideways to change the layout', 'Smaller road name']);
    });

    test('a release without an APK is not offered', () {
      expect(ReleaseInfo.fromJson(_release('v0.1.1-mici.5', apk: false)), isNull);
      final r = ReleaseInfo.fromJson(_release('v0.1.1-mici.5'))!;
      expect(r.version, '0.1.1-mici.5');
      expect(r.apkSize, 19000000);
    });
  });

  group('checking', () {
    test('newer release: available', () async {
      final u = _updater('0.1.1-mici.4', () => http.Response(jsonEncode(_release('v0.1.1-mici.5')), 200));
      await u.check();
      expect(u.status, UpdateStatus.available);
      expect(u.latest!.version, '0.1.1-mici.5');
    });

    test('same release: up to date', () async {
      final u = _updater('0.1.1-mici.5', () => http.Response(jsonEncode(_release('v0.1.1-mici.5')), 200));
      await u.check();
      expect(u.status, UpdateStatus.upToDate);
    });

    test('a list of releases: the newest with an APK, pre-releases included, drafts skipped', () async {
      final list = [
        {..._release('v0.1.2-rivian.3'), 'draft': true},
        _release('v0.1.2-rivian.2', apk: false),
        {..._release('v0.1.2-rivian.1'), 'prerelease': true},
        _release('v0.1.1-comma3x.5'),
      ];
      final u = _updater('0.1.1-comma3x.5', () => http.Response(jsonEncode(list), 200));
      await u.check();
      expect(u.status, UpdateStatus.available);
      expect(u.latest!.version, '0.1.2-rivian.1');
    });

    test('GitHub unreachable or refusing: failed, with a reason', () async {
      final u = _updater('0.1.1-mici.5', () => http.Response('{}', 403));
      await u.check();
      expect(u.status, UpdateStatus.failed);
      expect(u.message, contains('403'));
    });
  });

  group('settings', () {
    Future<AppSettings> open(WidgetTester tester, Updater updater) async {
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
              onPressed: () => showSettingsDialog(context, settings, build: 'x', updater: updater),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return settings;
    }

    testWidgets('two columns: brightness on the left, updates on the right', (tester) async {
      await open(tester, _updater('0.1.1-mici.4', () => http.Response('{}', 200)));
      expect(find.text('BRIGHTNESS'), findsOneWidget);
      expect(find.text('OPRIVVIEW UPDATES'), findsOneWidget);
      expect(tester.getCenter(find.text('BRIGHTNESS')).dx, lessThan(tester.getCenter(find.text('OPRIVVIEW UPDATES')).dx));
      expect(find.byKey(const ValueKey('updateCheck')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Check finds a newer release and offers Update with its notes', (tester) async {
      await open(tester, _updater('0.1.1-mici.4', () => http.Response(jsonEncode(_release('v0.1.1-mici.5')), 200)));
      await tester.tap(find.byKey(const ValueKey('updateCheck')));
      await tester.pumpAndSettle();
      expect(find.text('Update available'), findsOneWidget);
      expect(find.byKey(const ValueKey('updateInstall')), findsOneWidget);
      expect(find.text('• Swipe sideways to change the layout'), findsOneWidget);
    });

    testWidgets('brightness: Auto by default, the slider sets it, Auto hands it back', (tester) async {
      final settings = await open(tester, _updater('0.1.1-mici.4', () => http.Response('{}', 200)));
      expect(settings.brightness, isNull);
      await tester.tap(find.byKey(const ValueKey('brightnessSlider')));  // the middle of the track
      await tester.pumpAndSettle();
      expect(settings.brightness, isNotNull);
      await tester.tap(find.byKey(const ValueKey('brightnessAuto')));
      await tester.pumpAndSettle();
      expect(settings.brightness, isNull);
    });
  });

  test('brightness is remembered', () async {
    SharedPreferences.setMockInitialValues({});
    final a = AppSettings();
    await a.load();
    await a.setBrightness(0.3);
    final b = AppSettings();
    await b.load();
    expect(b.brightness, closeTo(0.3, 1e-9));
    await b.setBrightness(null);
    final c = AppSettings();
    await c.load();
    expect(c.brightness, isNull);
    expect(c.manualBrightness, 0.6);
  });
}
