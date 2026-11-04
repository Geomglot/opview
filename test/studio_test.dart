import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/replay/snapshot.dart';
import 'package:opview/studio/sidecar.dart';
import 'package:opview/studio/studio_api.dart';
import 'package:opview/studio/studio_page.dart';

const _params = [
  {'name': 'view', 'label': 'view', 'help': 'layout', 'default': 'classic', 'choices': ['classic', 'enhanced', 'detailed'], 'kind': 'text', 'many': false},
  {'name': 'bottom_bar', 'label': 'bottom bar', 'help': 'bar', 'default': null, 'choices': ['torque', 'laneCentering', 'auto', 'off'], 'kind': 'text', 'many': false},
  {'name': 'collapsed_panels', 'label': 'collapsed panels', 'help': 'panels', 'default': [], 'choices': ['steering', 'lead'], 'kind': 'text', 'many': true},
];

void main() {
  testWidgets('choosing a drive and the lane keeping bar sends those choices', (tester) async {
    HttpOverrides.global = null; // the test binding blocks real network use; this talks to a local fake
    late HttpServer server;
    final posted = <Map<String, dynamic>>[];
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        Object body;
        if (req.uri.path == '/params') {
          body = _params;
        } else if (req.uri.path == '/routes') {
          body = {'online': true, 'metric': false, 'routes': [
            {'route': '0000005a--f16da7af40', 'segments': [0, 1], 'first': 0, 'last': 1, 'on_device': true, 'on_connect': true, 'detail': 'full', 'local_start': '2026-10-31 09:18 EDT', 'km': 3.6},
            {'route': '00000001--aaaaaaaaaa', 'segments': [0], 'first': 0, 'last': 0, 'on_device': false, 'on_connect': true, 'detail': 'quick'},
          ]};
        } else if (req.uri.path == '/jobs' && req.method == 'POST') {
          posted.add(jsonDecode(await utf8.decoder.bind(req).join()));
          body = {'id': 'a', 'state': 'done', 'message': 'finished', 'progress': 1.0, 'output': '/tmp/x.mp4', 'error': null};
        } else {
          body = {'ok': true};
        }
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(body));
        await req.response.close();
      });
    });
    tester.view.physicalSize = const Size(1320, 820); // the window's real opening size
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final api = StudioApi(Uri.parse('http://127.0.0.1:${server.port}'));
    await tester.pumpWidget(MaterialApp(home: StudioPage(start: () async => Sidecar(null, api))));
    for (var i = 0; i < 20 && find.text('2026-10-31 09:18 EDT').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(find.textContaining('2.2 miles'), findsOneWidget); // 3.6 km, on a comma set to miles
    expect(find.text('Lane keeping'), findsOneWidget);
    expect(find.text('Torque bar'), findsOneWidget);

    expect(find.textContaining('Quick detail only'), findsOneWidget);
    expect(find.textContaining('Full detail (on the comma)'), findsOneWidget);
    expect(find.byTooltip('Help'), findsOneWidget);
    await tester.tap(find.text('2026-10-31 09:18 EDT'));
    await tester.pump();
    // the range is by segment unless Time is chosen, and the fields say which segments the drive has
    expect(find.text('0-1'), findsNWidgets(2));
    await tester.tap(find.text('Lane keeping'));
    await tester.tap(find.text('Detailed'));
    await tester.pump();
    await tester.ensureVisible(find.text('Lead')); // lower down the scrolling options column
    await tester.pump();
    await tester.tap(find.text('Lead'));
    await tester.pump();
    await tester.tap(find.text('Preview'));
    for (var i = 0; i < 20 && posted.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(posted.single['preview'], true);
    posted.clear();
    await tester.pump(const Duration(seconds: 2)); // let the job poll finish
    await tester.tap(find.text('Render MP4'));
    for (var i = 0; i < 20 && posted.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(posted.single['route'], '0000005a--f16da7af40');
    expect(posted.single['options'], {'view': 'detailed', 'bottom_bar': 'laneCentering', 'collapsed_panels': ['lead']});
    await tester.runAsync(() => server.close(force: true));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a running render shows the picture it has reached, Cancel asks before stopping, and the placeholder returns when done', (tester) async {
    HttpOverrides.global = null;
    late HttpServer server;
    late Directory dir;
    var state = 'running';
    final asked = <String>[]; // cancel and finish requests
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('studio-snapshot-test');
      final shot = File('${dir.path}/render-snapshot.bmp');
      await shot.writeAsBytes(snapshotBmp(Uint8List(8 * 5 * 4), 8, 5)); // a small black picture, as the renderer writes them
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        Object body;
        if (req.uri.path == '/params') {
          body = _params;
        } else if (req.uri.path == '/routes') {
          body = {'online': true, 'metric': true, 'routes': [
            {'route': '0000005a--f16da7af40', 'segments': [0, 1], 'first': 0, 'last': 1, 'on_device': true, 'on_connect': false, 'detail': 'full'},
          ]};
        } else if (req.uri.path.startsWith('/jobs')) {
          if (req.uri.path.endsWith('/cancel') || req.uri.path.endsWith('/finish')) asked.add(req.uri.path);
          body = {'id': 'a', 'state': state, 'message': state == 'running' ? 'frame 40 of 100 after 2 s, segment 0, 0:02' : 'finished',
              'progress': state == 'running' ? 0.4 : 1.0, 'output': '/tmp/x.mp4', 'error': null, 'preview': false,
              'snapshot': state == 'running' ? shot.path : null, 'range': {'seconds': 100.0}};
        } else {
          body = {'ok': true};
        }
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(body));
        await req.response.close();
      });
    });
    tester.view.physicalSize = const Size(1320, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 40 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 300)); // moves the once-a-second poll along
      }
    }

    final api = StudioApi(Uri.parse('http://127.0.0.1:${server.port}'));
    await tester.pumpWidget(MaterialApp(home: StudioPage(start: () async => Sidecar(null, api))));
    await settle(() => find.text('0000005a--f16da7af40').evaluate().isNotEmpty);
    await tester.tap(find.text('0000005a--f16da7af40'));
    await tester.pump();
    await tester.tap(find.text('Render MP4'));
    await settle(() => find.byType(Image).evaluate().isNotEmpty);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Working on it...'), findsNothing);
    expect(find.textContaining('segment 0, 0:02'), findsOneWidget);

    // Cancel asks first; carrying on sends nothing, and Save asks the server to finish early
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(find.text('Stop the render?'), findsOneWidget);
    expect(find.text('Made so far: 0:40 of 1:40'), findsOneWidget); // 40% of a 100 s range
    await tester.tap(find.text('Keep rendering'));
    await tester.pump();
    expect(find.text('Stop the render?'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.tap(find.text("Save what's done"));
    await settle(() => asked.isNotEmpty);
    expect(asked, ['/jobs/a/finish']);
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50))); // its answer arrives
      await tester.pump();
    }

    state = 'done';
    await settle(() => find.byType(Image).evaluate().isEmpty);
    expect(find.byType(Image), findsNothing);
    expect(find.text('The preview plays here'), findsOneWidget);
    await tester.runAsync(() async {
      await server.close(force: true);
      await dir.delete(recursive: true);
    });
    await tester.pumpWidget(const SizedBox());
  });
}
