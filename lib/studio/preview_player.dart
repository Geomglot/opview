// Plays a prepared replay inside the window, at the drive's own speed, through the same layouts the export uses

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:opview/common/app_clock.dart';
import 'package:opview/replay/replay_feed.dart';
import 'package:opview/replay/replay_job.dart';
import 'package:opview/replay/replay_scene.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/impl/cereal_adapter.dart';

class PreviewPlayer extends StatefulWidget {
  final String jobFile;
  const PreviewPlayer({super.key, required this.jobFile});
  @override
  State<PreviewPlayer> createState() => _PreviewPlayerState();
}

class _PreviewPlayerState extends State<PreviewPlayer> {
  late final ReplayJob _job = ReplayJob.load(widget.jobFile);
  late final AppSettings _settings = _job.settings();
  final _uiState = UIState()..isConnected = true;
  final _adapter = CerealAdapter();
  ReplayFeed? _feed;
  ui.Image? _picture;
  DateTime _time = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  bool _playing = false, _ended = false;
  int _shown = 0;
  String? _error;
  int _run = 0; // changes whenever playback is stopped or restarted, so an old loop knows to quit

  @override
  void initState() {
    super.initState();
    appNow = () => _time;
    _play();
  }

  @override
  void dispose() {
    _run++;
    appNow = DateTime.now;
    _feed?.close();
    _picture?.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    final run = ++_run;
    setState(() {
      _playing = true;
      _ended = false;
      _error = null;
    });
    try {
      _feed ??= await ReplayFeed.open(_job, _uiState, _adapter);
      // the clock starts when the first frame is ready, so the time spent starting up is not counted as lateness
      Stopwatch? clock;
      var firstShown = _shown;
      while (run == _run) {
        final frame = await _feed!.next();
        if (run != _run) {
          frame?.picture.dispose();
          return;
        }
        if (frame == null) {
          setState(() {
            _playing = false;
            _ended = true;
          });
          return;
        }
        // hold the frame until its moment, so the preview runs at the drive's own speed
        if (clock == null) {
          clock = Stopwatch()..start();
          firstShown = _shown;
        }
        final due = Duration(microseconds: ((_shown - firstShown) * 1000000 / _job.fps).round());
        if (clock.elapsed < due) await Future<void>.delayed(due - clock.elapsed);
        if (run != _run) {
          frame.picture.dispose();
          return;
        }
        final previous = _picture;
        setState(() {
          _time = DateTime.fromMillisecondsSinceEpoch(frame.timeMs, isUtc: true);
          _picture = frame.picture;
          _shown++;
        });
        previous?.dispose();
      }
    } catch (e) {
      if (run == _run && mounted) {
        setState(() {
          _playing = false;
          _error = '$e';
        });
      }
    }
  }

  void _pause() {
    _run++;
    setState(() => _playing = false);
  }

  Future<void> _restart() async {
    _run++;
    final old = _feed;
    _feed = null;
    await old?.close();
    _shown = 0;
    _uiState.latAccelWantHistory.clear();
    _uiState.latAccelGotHistory.clear();
    _uiState.accelCommandHistory.clear();
    _uiState.accelActualHistory.clear();
    _adapter.reset();
    await _play();
  }

  @override
  Widget build(BuildContext context) {
    final total = _job.frameCount;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AspectRatio(
        aspectRatio: _job.width / _job.height,
        child: ClipRect(
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: _job.width.toDouble(),
              height: _job.height.toDouble(),
              child: ReplayScene(job: _job, uiState: _uiState, settings: _settings, picture: _picture),
            ),
          ),
        ),
      ),
      LinearProgressIndicator(value: total == 0 ? 0 : (_shown / total).clamp(0.0, 1.0)),
      Row(children: [
        IconButton(
          tooltip: _playing ? 'Pause' : 'Play',
          icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
          onPressed: _ended ? _restart : (_playing ? _pause : _play),
        ),
        IconButton(tooltip: 'Restart', icon: const Icon(Icons.replay), onPressed: _restart),
        Text('${(_shown / _job.fps).toStringAsFixed(1)} of ${(total / _job.fps).toStringAsFixed(1)} s'),
        if (_error != null) Expanded(child: Text('  $_error', style: const TextStyle(color: Colors.red))),
      ]),
    ]);
  }
}
