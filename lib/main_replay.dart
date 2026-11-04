// OPRivView replay: draws a drive through the real onroad layouts and writes it to an MP4
// with OPRIVVIEW_JOB set (by the replay server) it renders that job; without it, it opens the replay window

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:opview/common/app_clock.dart';
import 'package:opview/replay/replay_feed.dart';
import 'package:opview/replay/replay_job.dart';
import 'package:opview/replay/replay_scene.dart';
import 'package:opview/replay/snapshot.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/impl/cereal_adapter.dart';
import 'package:opview/studio/studio_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final path = Platform.environment['OPRIVVIEW_JOB'];
  if (path == null) {
    // no job to render: this is the app the user opens
    runApp(MaterialApp(debugShowCheckedModeBanner: false, theme: ThemeData.dark(useMaterial3: true), home: const StudioPage()));
    return;
  }
  runApp(MaterialApp(debugShowCheckedModeBanner: false, home: ReplayRender(job: ReplayJob.load(path))));
}

class ReplayRender extends StatefulWidget {
  final ReplayJob job;
  const ReplayRender({super.key, required this.job});

  @override
  State<ReplayRender> createState() => _ReplayRenderState();
}

class _ReplayRenderState extends State<ReplayRender> {
  final _boundary = GlobalKey();
  final _uiState = UIState()..isConnected = true;
  final _adapter = CerealAdapter();
  late final AppSettings _settings = widget.job.settings();
  ui.Image? _picture;
  Process? _encoder;
  DateTime _time = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  @override
  void initState() {
    super.initState();
    appNow = () => _time;
    // when the server that asked for this render goes away, so does the render
    if (Platform.environment['OPRIVVIEW_WATCH_STDIN'] != null) stdin.listen(null, onDone: _abandon);
    WidgetsBinding.instance.addPostFrameCallback((_) => _run().then((_) => exit(0), onError: _fail));
  }

  void _abandon() {
    _encoder?.kill(ProcessSignal.sigkill);
    File(widget.job.output).deleteSync();
    exit(1);
  }

  Never _fail(Object e, StackTrace s) {
    stderr.writeln('render failed: $e\n$s');
    exit(1);
  }

  /// written beside and then moved over the last one, so the window never reads half a picture
  void _writeSnapshot(Uint8List rgba, String path) {
    try {
      final part = File('$path.part');
      part.writeAsBytesSync(snapshotBmp(rgba, widget.job.width, widget.job.height));
      part.renameSync(path);
    } on FileSystemException {
      // on Windows the move fails while the window is reading the last one; the next picture will do
    }
  }

  Future<void> _run() async {
    final job = widget.job;
    final feed = await ReplayFeed.open(job, _uiState, _adapter);
    final encoder = _encoder = await Process.start(job.ffmpeg, [
      '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', '${job.width}x${job.height}',
      '-r', '${job.fps}', '-i', '-', '-c:v', job.encoder, '-b:v', job.bitrate, '-pix_fmt', 'yuv420p', job.output,
    ]);
    encoder.stderr.listen(stderr.add);

    var done = 0;
    final clock = Stopwatch()..start();
    final snapshot = Platform.environment['OPRIVVIEW_SNAPSHOT'];
    var nextSnapshotMs = 0;
    FeedFrame? frame;
    while ((frame = await feed.next()) != null) {
      final previous = _picture;
      setState(() {
        _time = DateTime.fromMillisecondsSinceEpoch(frame!.timeMs, isUtc: true);
        _picture = frame.picture;
      });
      // drawn here rather than when the screen asks for a frame, which it stops doing for a hidden window. Time on screen
      // moves with the drive, so animations run at the speed they did in the car however long a frame takes to make.
      final binding = WidgetsBinding.instance;
      binding.handleBeginFrame(Duration(microseconds: done * 1000000 ~/ job.fps));
      binding.handleDrawFrame();
      previous?.dispose();

      final boundary = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      final pixels = data!.buffer.asUint8List();
      encoder.stdin.add(pixels);
      await encoder.stdin.flush();
      // the frame it has reached, for the window to show: about once a second, less often if making one is slow here
      if (snapshot != null && clock.elapsedMilliseconds >= nextSnapshotMs) {
        final took = Stopwatch()..start();
        _writeSnapshot(pixels, snapshot);
        nextSnapshotMs = clock.elapsedMilliseconds + max(1000, took.elapsedMilliseconds * snapshotSpacing);
      }
      if (++done % job.fps == 0) {
        final where = job.segmentAt(done - 1);
        stderr.writeln('frame $done of ${job.frameCount} after ${clock.elapsed.inSeconds} s${where == null ? '' : ', $where'}');
      }
    }
    await feed.close();
    await encoder.stdin.close();
    final code = await encoder.exitCode;
    if (code != 0) throw 'ffmpeg could not write ${job.output}';
    if (done != job.frameCount) throw 'drew $done frames, expected ${job.frameCount}';
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final w = job.width.toDouble(), h = job.height.toDouble();
    // laid out at the output size whatever the window size
    return OverflowBox(
      alignment: Alignment.topLeft,
      minWidth: w, maxWidth: w, minHeight: h, maxHeight: h,
      child: RepaintBoundary(
        key: _boundary,
        child: ReplayScene(job: job, uiState: _uiState, settings: _settings, picture: _picture),
      ),
    );
  }
}
