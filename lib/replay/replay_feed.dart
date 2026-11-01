// Reads a prepared replay one frame at a time: applies the logged messages to the UI state and decodes the camera
// picture, so the exporter and the in-window preview draw exactly the same thing.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:opview/replay/raw_frames.dart';
import 'package:opview/replay/replay_job.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/impl/cereal_adapter.dart';

class FeedFrame {
  /// the camera picture for this frame; the caller disposes it
  final ui.Image picture;
  /// the drive's local wall clock, as milliseconds the clock widgets read as hours and minutes
  final int timeMs;
  /// true when this frame uses the wide camera, in which case the UI state's stream type was set to match
  final bool wide;
  FeedFrame(this.picture, this.timeMs, this.wide);
}

class ReplayFeed {
  final ReplayJob job;
  final UIState uiState;
  final CerealAdapter adapter;
  final Process _decoder;
  final Process? _wideDecoder;
  final RawFrameReader _frames;
  final RawFrameReader? _wideFrames;
  final StreamIterator<String> _lines;
  int framesRead = 0;

  ReplayFeed._(this.job, this.uiState, this.adapter, this._decoder, this._wideDecoder, this._frames, this._wideFrames, this._lines);

  static Future<ReplayFeed> open(ReplayJob job, UIState uiState, CerealAdapter adapter) async {
    Future<Process> decode(List<String> files, int skip) => Process.start(job.ffmpeg, [
          '-v', 'error', '-f', job.videoFormat, if (job.videoFormat == 'hevc') ...['-framerate', '${job.fps}'],
          '-i', 'concat:${files.join('|')}',
          '-vf', 'trim=start_frame=$skip,setpts=PTS-STARTPTS,scale=${job.videoWidth}:${job.videoHeight}',
          '-frames:v', '${job.frameCount}', '-pix_fmt', 'rgba', '-f', 'rawvideo', '-',
        ]);
    final decoder = await decode(job.videoInputs, job.skipFrames);
    decoder.stderr.listen(stderr.add);
    // the wide camera is read in step with the road camera, so either picture is ready for any frame
    final wideInputs = job.wideInputs;
    final wideDecoder = wideInputs == null ? null : await decode(wideInputs, job.wideSkipFrames);
    wideDecoder?.stderr.listen(stderr.add);
    final bytes = job.videoWidth * job.videoHeight * 4;
    return ReplayFeed._(
      job, uiState, adapter, decoder, wideDecoder,
      RawFrameReader(decoder.stdout, bytes),
      wideDecoder == null ? null : RawFrameReader(wideDecoder.stdout, bytes),
      StreamIterator(File(job.clip).openRead().transform(utf8.decoder).transform(const LineSplitter())),
    );
  }

  Future<ui.Image> _toImage(Uint8List rgba) {
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, job.videoWidth, job.videoHeight, ui.PixelFormat.rgba8888, done.complete);
    return done.future;
  }

  /// the next frame, with every message logged before it already applied; null at the end of the drive
  Future<FeedFrame?> next() async {
    while (await _lines.moveNext()) {
      final line = _lines.current;
      if (!line.startsWith('F ')) {
        adapter.apply(uiState, line);
        continue;
      }
      final parts = line.split(' ');
      final wide = parts.length > 2 && parts[2] == 'W';
      final road = await _frames.next();
      final widePixels = await _wideFrames?.next();
      final pixels = wide ? widePixels : road;
      if (pixels == null) throw 'the video ended after $framesRead frames, expected ${job.frameCount}';
      framesRead++;
      uiState.streamType = wide ? 'wideRoad' : 'road';
      return FeedFrame(await _toImage(pixels), int.parse(parts[1]), wide);
    }
    return null;
  }

  Future<void> close() async {
    // a forced stop: ffmpeg blocked writing to a pipe nobody reads never acts on a polite one, and stays running
    _decoder.kill(ProcessSignal.sigkill);
    _wideDecoder?.kill(ProcessSignal.sigkill);
    await _lines.cancel();
  }
}
