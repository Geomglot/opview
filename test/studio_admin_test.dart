import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/replay/replay_job.dart';
import 'package:opview/studio/admin_page.dart';
import 'package:opview/studio/studio_api.dart';
import 'package:opview/studio/studio_page.dart';

class FakeApi extends StudioApi {
  FakeApi() : super(Uri.parse('http://127.0.0.1:1'));
  Map<String, dynamic> saved = {
    'host': 'comma',
    'dongle': 'aaaa',
    'devices': [
      {'dongle': 'aaaa', 'name': 'My comma'},
    ],
    'output_dir': '/Users/me/Movies',
    'token': {'state': 'expired', 'expires': 1},
    'key': {'path': '/Users/me/.ssh/id_ed25519.pub', 'public_key': 'ssh-ed25519 AAAA me'},
    'cache_bytes': 3 << 30,
    'cache_path': '/cache',
  };
  final hosts = <String>[];
  bool cleared = false;

  @override
  Future<Map<String, dynamic>> settings() async => saved;

  @override
  Future<Map<String, dynamic>> changeSettings(Map<String, Object?> changes) async {
    if (changes['host'] != null) hosts.add(changes['host'] as String);
    return saved = {...saved, ...changes};
  }

  @override
  Future<Map<String, dynamic>> checkHost(String address) async => {'ok': true, 'dongle': 'bbbb', 'error': null};

  @override
  Future<List<dynamic>> findComma() async => [
        {'address': '10.0.0.9', 'comma': true, 'dongle': 'aaaa'},
        {'address': '10.0.0.5', 'comma': false, 'dongle': null},
      ];

  @override
  Future<Map<String, dynamic>> clearCache() async {
    cleared = true;
    return {'cache_bytes': 0};
  }
}

Future<FakeApi> open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1320, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = FakeApi();
  await tester.pumpWidget(MaterialApp(home: AdminPage(api: api)));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  test('sizes read as a person would say them', () {
    expect(sizeLabel(3 << 30), '3.0 GB');
    expect(sizeLabel(250 << 20), '250 MB');
  });

  test('every kind of drive has a label', () {
    expect(detailLabel('logs'), 'Log and small video');
    expect(detailLabel('small'), 'On comma Connect');
  });

  test('a jump changes only what it says and keeps the rest of the job', () {
    final job = ReplayJob.fromJson({
      'clip': 'c', 'output': 'o', 'ffmpeg': 'f', 'encoder': 'e', 'video_inputs': ['a', 'b'], 'skip_frames': 0, 'frame_count': 100,
      'video_width': 1152, 'video_height': 722, 'width': 1920, 'height': 1080, 'fps': 20, 'bitrate': '8M', 'view': 'classic',
      'bottom_bar': null, 'collapsed_panels': <String>[], 'clock': 'h12',
    });
    final moved = job.withChanges({'video_inputs': ['b'], 'skip_frames': 7, 'frame_count': 40, 'clip_offset': 900, 'frames_before': 100, 'first_lines': ['p']});
    expect(moved.videoInputs, ['b']);
    expect((moved.skipFrames, moved.frameCount, moved.clipOffset, moved.framesBefore), (7, 40, 900, 100));
    expect(moved.firstLines, ['p']);
    expect(moved.width, 1920);
    expect((job.clipOffset, job.framesBefore), (0, 0));
  });

  testWidgets('the page says what state each thing is in', (tester) async {
    await open(tester);
    expect(find.text('My comma'), findsOneWidget);
    expect(find.textContaining('expired'), findsOneWidget);
    expect(find.textContaining('3.0 GB'), findsOneWidget);
    expect(find.textContaining('ssh-ed25519 AAAA me'), findsOneWidget);
  });

  testWidgets('an address that works is kept, and a different comma is pointed out', (tester) async {
    final api = await open(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Address or SSH name'), '10.0.0.9');
    await tester.tap(find.text('Test and use'));
    await tester.pumpAndSettle();
    expect(find.textContaining('not the device chosen above'), findsOneWidget);
    expect(api.hosts, ['10.0.0.9']);
  });

  testWidgets('a search lists what it found, and a found comma can be used', (tester) async {
    final api = await open(tester);
    await tester.tap(find.text('Find on this network'));
    await tester.pumpAndSettle();
    expect(find.text('comma aaaa'), findsOneWidget);
    expect(find.textContaining('is not a comma'), findsOneWidget);
    await tester.tap(find.text('Use').first);
    await tester.pumpAndSettle();
    expect(api.hosts, ['10.0.0.9']);
  });

  testWidgets('stored drives are only cleared after asking', (tester) async {
    final api = await open(tester);
    await tester.tap(find.text('Clear stored drives'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep them'));
    await tester.pumpAndSettle();
    expect(api.cleared, isFalse);
    await tester.tap(find.text('Clear stored drives'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.pumpAndSettle();
    expect(api.cleared, isTrue);
  });
}
