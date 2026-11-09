// Plays a prepared replay inside the window, at the drive's own speed, through the same layouts the export uses

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:opview/common/app_clock.dart';
import 'package:opview/replay/replay_feed.dart';
import 'package:opview/replay/replay_job.dart';
import 'package:opview/replay/replay_scene.dart';
import 'package:opview/selfdrive/ui/settings/settings_dialog.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/impl/cereal_adapter.dart';

/// playback speeds offered; above 1 frames are skipped when they cannot be drawn in time
const previewSpeeds = [0.25, 0.5, 1.0, 2.0, 4.0];

/// more late than this and frames are skipped to catch up, rather than played fast
const _lateFrames = 3;

/// never skip so many in a row that the picture appears to stop
const _maxSkipped = 5;

/// a pause in the picture this long goes in the log, for finding out why after the event
const _stallMs = 200;

/// a single draw this long means macOS has had to restart the graphics chip, which wipes what the app keeps on it
const _gpuResetMs = 5000;

/// what the window's option form calls the screen's current settings
Map<String, Object?> optionsFrom(AppSettings s) {
  final bar = s.bottomBarFor(s.layout);
  return {
    'view': s.layout.name,
    // the app's own choice for this view stays "App default", so it follows the view if that is changed later
    'bottom_bar': bar == defaultBottomBars[s.layout] ? null : bar.name,
    'collapsed_panels': [...s.collapsedPanels],
    'clock': s.clockMode.name,
    'speed_limit': s.speedLimitDisplay.name,
    'road_name': s.showRoadName ? 'show' : 'hide',
  };
}

/// the option form's choices put onto the screen's settings, the other way from [optionsFrom]; options the screen does
/// not show, or values it does not know, are left as they are. True when anything changed.
bool applyOptions(AppSettings s, Map<String, Object?> options) {
  T? byName<T extends Enum>(List<T> values, Object? name) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }

  final before = optionsFrom(s).toString();
  final view = byName(OnroadLayout.values, options['view']);
  if (view != null) s.layout = view;
  if (options.containsKey('bottom_bar')) {
    final bar = options['bottom_bar'];
    // "App default" is the view's own bar
    final chosen = bar == null ? defaultBottomBars[s.layout]! : byName(BottomBar.values, bar);
    if (chosen != null) s.bottomBars[s.layout] = chosen;
  }
  final panels = options['collapsed_panels'];
  if (panels is List) {
    s.collapsedPanels
      ..clear()
      ..addAll(panels.cast<String>());
  }
  final clock = byName(ClockMode.values, options['clock']);
  if (clock != null) s.clockMode = clock;
  final limit = byName(SpeedLimitDisplay.values, options['speed_limit']);
  if (limit != null) s.speedLimitDisplay = limit;
  final road = options['road_name'];
  if (road == 'show' || road == 'hide') s.showRoadName = road == 'show';
  if (optionsFrom(s).toString() == before) return false;
  // the settings are set directly, as for a render, so as not to touch saved preferences; the screen is told here
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  s.notifyListeners();
  return true;
}

class PreviewPlayer extends StatefulWidget {
  final String jobFile;

  /// the window's option form; a change made there shows on the preview as it plays
  final Map<String, Object?>? options;

  /// told of each change made on the preview itself: a swipe, a tap, or the app's settings screen
  final void Function(Map<String, Object?> options)? onOptionsChanged;

  /// what the job needs changed to play from a frame; without this the progress bar only shows progress
  final Future<Map<String, dynamic>> Function(String jobFile, int frame)? seek;

  /// the picture fills the space it is given, and the button says it will come back out
  final bool fullScreen;
  final VoidCallback? onToggleFullScreen;
  const PreviewPlayer(
      {super.key,
      required this.jobFile,
      this.options,
      this.onOptionsChanged,
      this.seek,
      this.fullScreen = false,
      this.onToggleFullScreen});
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
  bool _gpuReset = false;
  bool _seeking = false;
  double? _dragTo; // where along the bar the pointer is, while it is being dragged
  double _speed = 1;
  bool _speedChanged = false; // the running loop starts its clock again
  int _run = 0; // changes whenever playback is stopped or restarted, so an old loop knows to quit
  Future<void> _loopDone = Future.value(); // the feed has one reader at a time; each loop waits for the last to stop
  FeedFrame? _spare; // read by a loop that was stopped before it could show it; the next loop starts with it

  @override
  void initState() {
    super.initState();
    appNow = _now;
    // the job file has the options as they were when the preview was asked for; any changed in the form while its
    // files were fetched are the ones to show
    _takeOptions();
    _settings.addListener(_settingsChanged);
    SchedulerBinding.instance.addTimingsCallback(_timings);
    _play();
  }

  @override
  void dispose() {
    _run++;
    _settings.removeListener(_settingsChanged);
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    if (appNow == _now) appNow = DateTime.now; // a newer preview may already have taken the clock
    _feed?.close();
    _loopDone.whenComplete(_dropSpare);
    _picture?.dispose();
    super.dispose();
  }

  DateTime _now() => _time;

  bool _applying = false; // the form's own change coming back; it need not be told of it

  void _settingsChanged() {
    if (!_applying) widget.onOptionsChanged?.call(optionsFrom(_settings));
  }

  @override
  void didUpdateWidget(PreviewPlayer old) {
    super.didUpdateWidget(old);
    _takeOptions();
  }

  /// the form's options put onto the screen, without telling the form of its own change
  void _takeOptions() {
    final options = widget.options;
    if (options == null) return;
    _applying = true;
    try {
      applyOptions(_settings, options);
    } finally {
      _applying = false;
    }
  }

  void _dropSpare() {
    _spare?.picture.dispose();
    _spare = null;
  }

  void _timings(List<ui.FrameTiming> timings) {
    for (final t in timings) {
      final ms = t.rasterDuration.inMilliseconds;
      if (ms >= _stallMs) _noteStall('drawing took $ms ms');
      if (ms >= _gpuResetMs && mounted) setState(() => _gpuReset = true);
    }
  }

  /// where stalls are logged: the Mac's Logs folder, on Windows (which has no HOME) the app's local data folder, and on
  /// Linux the app's folder in the place for such things (XDG_STATE_HOME, normally ~/.local/state)
  static String? get _stallLog {
    if (Platform.isWindows) {
      final local = Platform.environment['LOCALAPPDATA'];
      return local == null ? null : '$local\\GeoRivViewReplay\\Logs\\preview.log';
    }
    final home = Platform.environment['HOME'];
    if (Platform.isLinux) {
      final state = Platform.environment['XDG_STATE_HOME'] ?? (home == null ? null : '$home/.local/state');
      return state == null ? null : '$state/GeoRivViewReplay/logs/preview.log';
    }
    return home == null ? null : '$home/Library/Logs/GeoRivViewReplay/preview.log';
  }

  void _noteStall(String what) {
    final path = _stallLog;
    if (path == null) return;
    try {
      final log = File(path)..parent.createSync(recursive: true);
      log.writeAsStringSync(
          '${DateTime.now().toIso8601String()} $what, frame $_shown, ${_settings.layout.name}, memory ${ProcessInfo.currentRss >> 20} MB\n',
          mode: FileMode.append);
    } on FileSystemException {
      // a log that cannot be written must not stop the preview
    }
  }

  /// with [oneFrame] it stops after showing a frame: a jump made while paused still shows where it landed
  Future<void> _play({bool oneFrame = false}) async {
    final run = ++_run;
    setState(() {
      _playing = !oneFrame;
      _ended = false;
      _error = null;
    });
    await _loopDone;
    if (run != _run) return;
    final done = Completer<void>();
    _loopDone = done.future;
    try {
      if (_feed == null) {
        final feed = await ReplayFeed.open(_job, _uiState, _adapter);
        if (!mounted) {
          await feed.close();
          return;
        }
        _feed = feed;
      }
      // the clock starts when the first frame is ready, so the time spent starting up is not counted as lateness
      Stopwatch? clock;
      var firstShown = _shown, skipped = 0, lastShownMs = 0;
      final frameMs = 1000 / _job.fps;
      _speedChanged = false;
      while (run == _run) {
        // well behind: pass frames without making their pictures, until the clip has caught up with the clock
        if (!oneFrame && clock != null && !_speedChanged && _spare == null && skipped < _maxSkipped) {
          final due = Duration(microseconds: ((_shown - firstShown) * 1000000 / (_job.fps * _speed)).round());
          if ((clock.elapsed - due).inMilliseconds > _lateFrames * frameMs) {
            skipped++;
            if (await _feed!.skip()) _shown++;
            continue;
          }
        }
        final frame = _spare ?? await _feed!.next();
        _spare = null;
        if (run != _run) {
          _spare = frame;
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
        if (clock == null || _speedChanged) {
          clock = Stopwatch()..start();
          firstShown = _shown;
          lastShownMs = 0;
          _speedChanged = false;
        }
        final due = Duration(microseconds: ((_shown - firstShown) * 1000000 / (_job.fps * _speed)).round());
        skipped = 0;
        if (clock.elapsed < due) await Future<void>.delayed(due - clock.elapsed);
        if (run != _run) {
          _spare = frame;
          return;
        }
        final gapMs = clock.elapsedMilliseconds - lastShownMs;
        if (gapMs - frameMs / _speed >= _stallMs && _shown > firstShown) _noteStall('picture stopped for $gapMs ms');
        lastShownMs = clock.elapsedMilliseconds;
        final previous = _picture;
        setState(() {
          _time = DateTime.fromMillisecondsSinceEpoch(frame.timeMs, isUtc: true);
          _picture = frame.picture;
          _shown++;
        });
        previous?.dispose();
        if (oneFrame) {
          setState(() => _playing = false);
          return;
        }
      }
    } catch (e) {
      if (run == _run && mounted) {
        setState(() {
          _playing = false;
          _error = '$e';
        });
      }
    } finally {
      done.complete();
    }
  }

  void _setSpeed(double speed) {
    _speed = speed;
    _speedChanged = true;
    setState(() {});
  }

  /// starts again at [frame] of the clip, playing if it was playing. Later jumps replace earlier ones still under way.
  Future<void> _seekTo(int frame) async {
    final resume = _playing;
    final run = ++_run;
    setState(() {
      _seeking = true;
      _ended = false;
      _shown = frame;
      _error = null;
    });
    final old = _feed;
    _feed = null;
    await old?.close();
    await _loopDone;
    if (run != _run) return;
    _dropSpare();
    try {
      final changes = await widget.seek!(widget.jobFile, frame);
      if (run != _run || !mounted) return;
      _clearHistory();
      final feed = await ReplayFeed.open(_job.withChanges(changes), _uiState, _adapter);
      if (run != _run || !mounted) {
        await feed.close();
        return;
      }
      _feed = feed;
      _seeking = false;
      await _play(oneFrame: !resume);
    } catch (e) {
      if (run == _run && mounted) {
        setState(() {
          _seeking = false;
          _playing = false;
          _error = '$e';
        });
      }
    }
  }

  void _clearHistory() {
    _uiState.latAccelWantHistory.clear();
    _uiState.latAccelGotHistory.clear();
    _uiState.accelCommandHistory.clear();
    _uiState.accelActualHistory.clear();
    _adapter.reset();
  }

  void _pause() {
    _run++;
    setState(() => _playing = false);
  }

  Future<void> _restart() async {
    final run = ++_run;
    final old = _feed;
    _feed = null;
    await old?.close(); // this also ends a read in progress, which is what lets the old loop stop
    await _loopDone;
    if (run != _run) return; // a later press has taken over
    _dropSpare();
    _shown = 0;
    _clearHistory();
    await _play();
  }

  /// the progress bar: click or drag along it to go to that part of the clip. The pointer's place shows until it lets go.
  Widget _progress(int total) {
    final done = total == 0 ? 0.0 : (_shown / total).clamp(0.0, 1.0);
    final bar = SizedBox(
        height: 18,
        child: Center(child: LinearProgressIndicator(value: _dragTo ?? done, minHeight: 6, borderRadius: BorderRadius.circular(3))));
    if (widget.seek == null) return bar;
    return LayoutBuilder(builder: (context, box) {
      double at(double x) => (x / box.maxWidth).clamp(0.0, 1.0);
      void go(double fraction) => _seekTo((fraction * (total - 1)).round());
      return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => go(at(d.localPosition.dx)),
            onHorizontalDragUpdate: (d) => setState(() => _dragTo = at(d.localPosition.dx)),
            onHorizontalDragEnd: (_) {
              final to = _dragTo;
              setState(() => _dragTo = null);
              if (to != null) go(to);
            },
            child: bar,
          ));
    });
  }

  String _speedLabel(double s) => '${s == s.roundToDouble() ? s.toInt() : s}x';

  @override
  Widget build(BuildContext context) {
    final total = _job.frameCount;
    final picture = AspectRatio(
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
    );
    final shownFrames = _dragTo == null ? _shown : (_dragTo! * total).round();
    // where that is in the drive, which is what the Segment fields of the range take
    final where = total == 0 ? null : _job.segmentAt(shownFrames.clamp(0, total - 1));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (widget.fullScreen) Expanded(child: Center(child: picture)) else picture,
      _progress(total),
      Row(children: [
        IconButton(
          tooltip: _playing ? 'Pause' : 'Play',
          icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
          onPressed: _seeking ? null : (_ended ? _restart : (_playing ? _pause : _play)),
        ),
        IconButton(tooltip: 'Restart', icon: const Icon(Icons.replay), onPressed: _restart),
        IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings), onPressed: () => showSettingsDialog(context, _settings)),
        PopupMenuButton<double>(
          tooltip: 'Playback speed',
          initialValue: _speed,
          onSelected: _setSpeed,
          itemBuilder: (_) => [for (final s in previewSpeeds) PopupMenuItem(value: s, child: Text(_speedLabel(s)))],
          child: SizedBox(width: 52, height: 40, child: Center(child: Text(_speedLabel(_speed)))), // the same width whatever it says
        ),
        if (widget.onToggleFullScreen != null)
          IconButton(
            tooltip: widget.fullScreen ? 'Leave full screen' : 'Full screen',
            icon: Icon(widget.fullScreen ? Icons.fullscreen_exit : Icons.fullscreen),
            onPressed: widget.onToggleFullScreen,
          ),
        const SizedBox(width: 4),
        Text('${(shownFrames / _job.fps).toStringAsFixed(1)} of ${(total / _job.fps).toStringAsFixed(1)} s'
            '${where == null ? '' : ', $where'}'),
        if (_error != null) Expanded(child: Text('  $_error', style: const TextStyle(color: Colors.red))),
      ]),
      if (_gpuReset)
        Text(
            Platform.isMacOS
                ? 'The Mac restarted its graphics chip. If text or the picture looks wrong, quit and reopen this app.'
                : 'The picture stopped for 5 seconds or more. If text or the picture looks wrong, quit and reopen this app.',
            style: const TextStyle(color: Colors.orange)),
    ]);
  }
}
