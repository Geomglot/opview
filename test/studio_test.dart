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
    expect(find.text(renderPictureNote), findsOneWidget, reason: 'the picture jumps along, and says that is normal');
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

  testWidgets('a job asking whether to copy over a metered connection shows the question once and sends the answer', (tester) async {
    HttpOverrides.global = null;
    late HttpServer server;
    String? question = 'The comma is on cellular, which it is set to treat as metered. Copy now?';
    var finished = false;
    final answers = <Map<String, dynamic>>[];
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        Object body;
        if (req.uri.path == '/params') {
          body = _params;
        } else if (req.uri.path == '/routes') {
          body = {'online': false, 'metric': true, 'routes': [
            {'route': '0000005a--f16da7af40', 'segments': [0, 1], 'first': 0, 'last': 1, 'on_device': false, 'on_connect': true, 'detail': 'quick'},
          ]};
        } else if (req.uri.path.startsWith('/jobs')) {
          if (req.uri.path.endsWith('/answer')) {
            answers.add(jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>);
            question = null;
          }
          body = {'id': 'a', 'state': finished ? 'done' : 'running', 'message': question == null ? 'fetching' : 'waiting for an answer', 'progress': null,
              'output': '/tmp/x.mp4', 'error': null, 'preview': true, 'snapshot': null, 'question': question};
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
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    final api = StudioApi(Uri.parse('http://127.0.0.1:${server.port}'));
    await tester.pumpWidget(MaterialApp(home: StudioPage(start: () async => Sidecar(null, api))));
    await settle(() => find.text('0000005a--f16da7af40').evaluate().isNotEmpty);
    await tester.tap(find.text('0000005a--f16da7af40'));
    await tester.pump();
    await tester.tap(find.text('Preview'));
    await settle(() => find.text('Copy over a metered connection?').evaluate().isNotEmpty);
    expect(find.text('Copy over a metered connection?'), findsOneWidget);
    expect(find.textContaining('on cellular'), findsOneWidget);
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('Cancel')), findsOneWidget,
        reason: 'the dialog covers the window\'s own Cancel');
    await tester.tap(find.text('Copy now'));
    await settle(() => answers.isNotEmpty);
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(answers, [{'copy_now': true}]);
    expect(find.text('Copy over a metered connection?'), findsNothing, reason: 'answered once, not asked again');
    finished = true; // the poll stops once the job is done
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.runAsync(() => server.close(force: true));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a long fetch is asked about first, shows the time left, and Cancel asks before stopping it', (tester) async {
    HttpOverrides.global = null;
    late HttpServer server;
    String? question = 'This range needs 30 segments (about 30 minutes of drive) that are not on this computer yet.';
    var cancelled = false;
    final answers = <Map<String, dynamic>>[];
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        Object body;
        if (req.uri.path == '/params') {
          body = _params;
        } else if (req.uri.path == '/routes') {
          body = {'online': false, 'metric': true, 'routes': [
            {'route': '0000005a--f16da7af40', 'segments': [0, 1], 'first': 0, 'last': 1, 'on_device': false, 'on_connect': true, 'detail': 'quick'},
          ]};
        } else if (req.uri.path.startsWith('/jobs')) {
          if (req.uri.path.endsWith('/answer')) {
            answers.add(jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>);
            question = null;
          }
          if (req.uri.path.endsWith('/cancel')) cancelled = true;
          final fetching = question == null && !cancelled;
          body = {'id': 'a', 'state': cancelled ? 'cancelled' : 'running',
              'message': fetching ? 'fetching the quick files from connect: 120 of 800 MB, about 4 min left' : 'waiting for an answer',
              'progress': fetching ? 0.15 : null, 'output': '/tmp/x.mp4', 'error': null, 'preview': true, 'snapshot': null,
              'question': question, 'question_kind': question == null ? null : 'many',
              'fetch': fetching ? {'what': 'x', 'done': 120000000, 'total': 800000000, 'seconds_left': 240} : null};
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
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    final api = StudioApi(Uri.parse('http://127.0.0.1:${server.port}'));
    await tester.pumpWidget(MaterialApp(home: StudioPage(start: () async => Sidecar(null, api))));
    await settle(() => find.text('0000005a--f16da7af40').evaluate().isNotEmpty);
    await tester.tap(find.text('0000005a--f16da7af40'));
    await tester.pump();
    await tester.tap(find.text('Preview'));
    await settle(() => find.text('Fetch a long range?').evaluate().isNotEmpty);
    expect(find.textContaining('30 segments'), findsOneWidget);
    expect(find.text('Not now'), findsNothing, reason: 'only fetch, or cancel');
    await tester.tap(find.text('Fetch'));
    await settle(() => find.textContaining('about 4 min left').evaluate().isNotEmpty);
    expect(answers, [{'copy_now': true}]);
    expect(find.text('fetching the quick files from connect: 120 of 800 MB, about 4 min left'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await settle(() => find.text('Stop fetching?').evaluate().isNotEmpty);
    expect(find.text('Fetched 120 of 800 MB, about 4 min left'), findsOneWidget);
    await tester.tap(find.text('Keep fetching'));
    await settle(() => find.text('Stop fetching?').evaluate().isEmpty);
    expect(cancelled, isFalse, reason: 'Cancel pressed by mistake carries on');

    await tester.tap(find.text('Cancel'));
    await settle(() => find.text('Stop fetching?').evaluate().isNotEmpty);
    await tester.tap(find.text('Stop fetching'));
    await settle(() => cancelled);
    expect(cancelled, isTrue);
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.runAsync(() => server.close(force: true));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Check range is a job: it shows the fetch of the drive\'s logs with Cancel, then the range under the button', (tester) async {
    HttpOverrides.global = null;
    late HttpServer server;
    var polls = 0;
    var fail = false;
    final started = <Map<String, dynamic>>[];
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        Object body;
        if (req.uri.path == '/params') {
          body = _params;
        } else if (req.uri.path == '/routes') {
          body = {'online': false, 'metric': true, 'routes': [
            {'route': '0000005a--f16da7af40', 'segments': [0, 1], 'first': 0, 'last': 1, 'on_device': false, 'on_connect': true, 'detail': 'quick'},
          ]};
        } else if (req.uri.path.startsWith('/jobs')) {
          if (req.method == 'POST' && req.uri.path == '/jobs') {
            started.add(jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>);
            polls = 0;
          } else {
            polls++;
          }
          final running = polls < 3;
          body = {'id': 'c', 'check': true, 'preview': false, 'output': null, 'error': fail ? 'segment 9 is not in this drive' : null,
              'state': running ? 'running' : fail ? 'failed' : 'done',
              'message': running ? "fetching the drive's logs from connect: 40 of 180 MB, about 2 min left" : 'checked',
              'progress': running ? 0.2 : 1.0, 'snapshot': null, 'question': null,
              'fetch': running ? {'what': 'x', 'done': 40000000, 'total': 180000000, 'seconds_left': 120} : null,
              'range': running || fail ? null : {'zone': 'America/Toronto', 'start': '10:00:00', 'end': '10:02:00', 'seconds': 120.0}};
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
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    final api = StudioApi(Uri.parse('http://127.0.0.1:${server.port}'));
    await tester.pumpWidget(MaterialApp(home: StudioPage(start: () async => Sidecar(null, api))));
    await settle(() => find.text('0000005a--f16da7af40').evaluate().isNotEmpty);
    await tester.tap(find.text('0000005a--f16da7af40'));
    await tester.pump();
    await tester.tap(find.text('Check range'));
    await settle(() => find.textContaining('about 2 min left').evaluate().isNotEmpty);
    expect(started.single['check'], isTrue);
    expect(find.text('Checking...'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget, reason: 'a long drive can be backed out of');
    await settle(() => find.textContaining('120.0 seconds').evaluate().isNotEmpty);
    expect(find.textContaining('From 10:00:00'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsNothing);

    fail = true;
    await tester.tap(find.text('Check range'));
    await settle(() => find.text('segment 9 is not in this drive').evaluate().isNotEmpty);
    expect(find.text('segment 9 is not in this drive'), findsOneWidget);
    expect(find.textContaining('Failed:'), findsNothing, reason: 'the answer is under Check range, not where clips are');
    await tester.runAsync(() => server.close(force: true));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the filter button opens the filters, which narrow the list and say how many are shown', (tester) async {
    HttpOverrides.global = null;
    late HttpServer server;
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final Object body = req.uri.path == '/params'
            ? _params
            : req.uri.path == '/routes'
                ? {'online': true, 'metric': true, 'routes': [
                    {'route': '0000005a--f16da7af40', 'segments': [0, 1], 'first': 0, 'last': 1, 'on_device': true, 'on_connect': true,
                        'detail': 'full', 'local_start': '2026-10-31 18:30 EDT', 'local_date': '2026-10-31', 'daylight': false,
                        'start_place': 'Toronto', 'end_place': 'Oakville', 'km': 3.6},
                    {'route': '00000001--aaaaaaaaaa', 'segments': [0], 'first': 0, 'last': 0, 'on_device': false, 'on_connect': true,
                        'detail': 'quick', 'local_start': '2026-10-30 12:00 EDT', 'local_date': '2026-10-30', 'daylight': true,
                        'start_place': 'Guelph', 'end_place': 'Guelph', 'km': 1.0, 'stored': 'quick'},
                  ]}
                : {'ok': true};
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(body));
        await req.response.close();
      });
    });
    tester.view.physicalSize = const Size(1320, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final api = StudioApi(Uri.parse('http://127.0.0.1:${server.port}'));
    await tester.pumpWidget(MaterialApp(home: StudioPage(start: () async => Sidecar(null, api))));
    for (var i = 0; i < 20 && find.text('2026-10-31 18:30 EDT').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(find.byKey(const Key('drive-filters')), findsNothing);
    await tester.tap(find.byTooltip('Filter the drives'));
    await tester.pump();
    expect(find.textContaining('shown'), findsNothing, reason: 'nothing filtered yet');

    await tester.tap(find.widgetWithText(FilterChip, 'Night'));
    await tester.pump();
    expect(find.text('1 of 2 shown'), findsOneWidget);
    // hidden, the filters still apply, and the button's badge says how many parts are set
    await tester.tap(find.byTooltip('Hide the filters'));
    await tester.pump();
    expect(find.text('2026-10-30 12:00 EDT'), findsNothing);
    expect(find.text('2026-10-31 18:30 EDT'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);

    await tester.tap(find.byTooltip('Filter the drives'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'any town').first, 'guel');
    await tester.pump();
    expect(find.text('0 of 2 shown'), findsOneWidget);
    // a typed town is emptied with its cross, without editing it
    await tester.tap(find.byTooltip('Any town'));
    await tester.pump();
    expect(find.text('1 of 2 shown'), findsOneWidget);
    expect(find.text('guel'), findsNothing);
    // or a whole town is chosen from those the drives have
    await tester.tap(find.byKey(const Key('end-towns')));
    await tester.pumpAndSettle();
    expect(find.text('Oakville'), findsWidgets);
    await tester.tap(find.text('Guelph').last);
    await tester.pumpAndSettle();
    expect(find.text('0 of 2 shown'), findsOneWidget);
    // each end of the dates is picked on a calendar that turns to other months
    await tester.tap(find.byKey(const Key('date-from')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Previous month'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Hide the filters'));
    await tester.pump();
    expect(find.text('No drives match the filters.'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    await tester.tap(find.text('Clear the filters'));
    await tester.pump();
    expect(find.text('2026-10-30 12:00 EDT'), findsOneWidget);
    expect(find.text('2026-10-31 18:30 EDT'), findsOneWidget);
    await tester.runAsync(() => server.close(force: true));
    await tester.pumpWidget(const SizedBox());
  });
}
