import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/replay/replay_scene.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/studio/preview_player.dart';

import 'replay_test.dart' show job;

void main() {
  testWidgets('options changed in the form while the preview was fetching show when it opens', (tester) async {
    final dir = Directory.systemTemp.createTempSync('preview-options');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/job.json')..writeAsStringSync(jsonEncode(job({'view': 'classic', 'clock': 'h12', 'width': 1600, 'height': 800})));
    final told = <Map<String, Object?>>[];
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PreviewPlayer(jobFile: file.path, options: const {'view': 'detailed', 'clock': 'h24'}, onOptionsChanged: told.add))));
    final settings = tester.widget<ReplayScene>(find.byType(ReplayScene)).settings;
    expect(settings.layout, OnroadLayout.detailed);
    expect(settings.clockMode, ClockMode.h24);
    expect(told, isEmpty, reason: 'the form is not told of its own choices');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30)); // the test's job has no video to open, so let its retries lapse
  });
}
