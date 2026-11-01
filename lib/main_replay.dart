// OPRivView replay: draws a drive through the real onroad layouts and writes it to an MP4
// with OPRIVVIEW_JOB set (by the replay server) it renders that job; without it, it opens the replay window

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:opview/common/app_clock.dart';
import 'package:opview/replay/raw_frames.dart';
import 'package:opview/replay/replay_job.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
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
  DateTime _time = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  @override
  void initState() {
    super.initState();
    appNow = () => _time;
    WidgetsBinding.instance.addPostFrameCallback((_) => _run().then((_) => exit(0), onError: _fail));
  }

  Never _fail(Object e, StackTrace s) {
    stderr.writeln('render failed: $e\n$s');
    exit(1);
  }

  Future<ui.Image> _toImage(Uint8List rgba, int w, int h) {
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, done.complete);
    return done.future;
  }

  Future<void> _run() async {
    final job = widget.job;
    Future<Process> decode(List<String> files) => Process.start(job.ffmpeg, [
          '-v', 'error', '-f', job.videoFormat, if (job.videoFormat == 'hevc') ...['-framerate', '${job.fps}'],
          '-i', 'concat:${files.join('|')}',
          '-vf', 'trim=start_frame=${job.skipFrames},setpts=PTS-STARTPTS,scale=${job.videoWidth}:${job.videoHeight}',
          '-frames:v', '${job.frameCount}', '-pix_fmt', 'rgba', '-f', 'rawvideo', '-',
        ]);
    final decoder = await decode(job.videoInputs);
    decoder.stderr.listen(stderr.add);
    // the wide camera is read in step with the road camera, so either picture is ready for any frame
    final wideInputs = job.wideInputs;
    final wideDecoder = wideInputs == null ? null : await decode(wideInputs);
    wideDecoder?.stderr.listen(stderr.add);
    final encoder = await Process.start(job.ffmpeg, [
      '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', '${job.width}x${job.height}',
      '-r', '${job.fps}', '-i', '-', '-c:v', job.encoder, '-b:v', job.bitrate, '-pix_fmt', 'yuv420p', job.output,
    ]);
    encoder.stderr.listen(stderr.add);

    final frameBytes = job.videoWidth * job.videoHeight * 4;
    final frames = RawFrameReader(decoder.stdout, frameBytes);
    final wideFrames = wideDecoder == null ? null : RawFrameReader(wideDecoder.stdout, frameBytes);
    final lines = StreamIterator(File(job.clip).openRead().transform(utf8.decoder).transform(const LineSplitter()));
    var done = 0;
    final clock = Stopwatch()..start();
    while (await lines.moveNext()) {
      final line = lines.current;
      if (!line.startsWith('F ')) {
        _adapter.apply(_uiState, line);
        continue;
      }
      final parts = line.split(' ');
      final wide = parts.length > 2 && parts[2] == 'W';
      final road = await frames.next();
      final widePixels = await wideFrames?.next();
      final pixels = wide ? widePixels : road;
      if (pixels == null) throw 'the video ended after $done frames, expected ${job.frameCount}';
      final picture = await _toImage(pixels, job.videoWidth, job.videoHeight);
      final previous = _picture;
      setState(() {
        _time = DateTime.fromMillisecondsSinceEpoch(int.parse(parts[1]), isUtc: true);
        _uiState.streamType = wide ? 'wideRoad' : 'road';
        _picture = picture;
      });
      await WidgetsBinding.instance.endOfFrame;
      previous?.dispose();

      final boundary = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      encoder.stdin.add(data!.buffer.asUint8List());
      await encoder.stdin.flush();
      if (++done % job.fps == 0) stderr.writeln('frame $done of ${job.frameCount} after ${clock.elapsed.inSeconds} s');
    }
    await lines.cancel();
    await encoder.stdin.close();
    final code = await encoder.exitCode;
    decoder.kill();
    wideDecoder?.kill();
    if (code != 0) throw 'ffmpeg could not write ${job.output}';
    if (done != job.frameCount) throw 'drew $done frames, expected ${job.frameCount}';
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final w = job.width.toDouble(), h = job.height.toDouble();
    final picture = _picture;
    // laid out at the output size whatever the window size, so the layouts see the screen they will be recorded at
    return OverflowBox(
      alignment: Alignment.topLeft,
      minWidth: w, maxWidth: w, minHeight: h, maxHeight: h,
      child: RepaintBoundary(
        key: _boundary,
        child: MediaQuery(
          data: MediaQueryData(size: ui.Size(w, h)),
          child: Scaffold(
            backgroundColor: Colors.black,
            body: AugmentedRoadView(
              uiState: _uiState,
              settings: _settings,
              videoChild: picture == null ? const SizedBox.shrink() : RawImage(image: picture, fit: BoxFit.cover),
            ),
          ),
        ),
      ),
    );
  }
}
