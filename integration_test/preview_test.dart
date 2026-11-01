// Plays a prepared replay in the real engine, for checking the window preview on a Mac:
//   flutter test integration_test/preview_test.dart -d macos \
//     --dart-define=PREVIEW_JOB=<preview-job.json> --dart-define=PREVIEW_PNG=<where to save a frame>
// Prepare the job with the replay server (POST /jobs with "preview": true).

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:opview/studio/preview_player.dart';

const _job = String.fromEnvironment('PREVIEW_JOB');
const _png = String.fromEnvironment('PREVIEW_PNG');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the preview plays a prepared drive at its own speed', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: RepaintBoundary(key: key, child: PreviewPlayer(jobFile: _job)))));
    final clock = Stopwatch()..start();
    var saved = false;
    while (find.byIcon(Icons.play_arrow).evaluate().isEmpty || clock.elapsedMilliseconds < 500) {
      await tester.pump(const Duration(milliseconds: 100));
      if (!saved && clock.elapsedMilliseconds > 1500 && _png.isNotEmpty) {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File(_png).writeAsBytesSync(data!.buffer.asUint8List());
        saved = true;
      }
      if (clock.elapsed > const Duration(seconds: 30)) fail('the preview did not finish');
    }
    // a 3 second clip takes about 3 seconds: not instant, and not much slower than the drive
    // ignore: avoid_print
    print('PREVIEW finished after ${clock.elapsedMilliseconds} ms');
    expect(clock.elapsedMilliseconds, inInclusiveRange(2500, 6000));
  });
}
