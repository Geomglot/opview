// The replay window: pick a drive, a start and end, the options, and render

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:opview/studio/admin_page.dart';
import 'package:opview/studio/desktop.dart';
import 'package:opview/studio/preview_player.dart';
import 'package:opview/studio/replay_updater.dart';
import 'package:opview/studio/sidecar.dart';
import 'package:opview/studio/studio_api.dart';
import 'package:opview/studio/version.dart';

// friendlier names for choices; anything not listed shows as it is
const choiceLabels = {
  'torque': 'Torque bar',
  'laneCentering': 'Lane keeping',
  'auto': 'Automatic',
  'off': 'Off',
  'h12': '12 hour',
  'h24': '24 hour',
  'logs': 'Log and small video',
  'always': 'Always',
  'show': 'Show',
  'hide': 'Hide',
};

String choiceLabel(String c) => choiceLabels[c] ?? '${c[0].toUpperCase()}${c.substring(1)}';

/// under the picture of a render's progress, which jumps along because it is only the frame reached, about once a second
const renderPictureNote = 'This shows the frame the render has reached, about once a second, so it looks jerky. '
    'That is normal: the MP4 has every frame.';

/// one line for the drive pane about an upload to Connect the app asked the comma for; null when there is none
String? uploadLine(Map<String, dynamic>? u) {
  if (u == null || u['requested'] != true) return null;
  if (u['done'] == true) return 'The full files are on comma Connect now.';
  final head = 'Upload to comma Connect: ${u['uploaded']} of ${u['files']} files there';
  final current = u['current'] as Map<String, dynamic>?;
  if (current != null) {
    return '$head. Uploading ${current['file']} of segment ${current['segment']}: '
        '${(((current['progress'] as num?) ?? 0) * 100).round()}%.';
  }
  if (u['answered'] == false) return '$head. The comma is not answering; it uploads once it is online.';
  if (((u['queued'] as num?) ?? 0) > 0) {
    return u['metered'] == true ? '$head. The comma is waiting for an unmetered connection.' : "$head. Waiting in the comma's upload queue.";
  }
  return '$head. Waiting for comma Connect to list the uploaded files.';
}

/// how much of a running render's clip exists, e.g. "Made so far: 0:31 of 2:00"
String madeSoFar(Map<String, dynamic> job) {
  final done = ((job['progress'] as num?) ?? 0).toDouble();
  final total = ((job['range'] as Map?)?['seconds'] as num?)?.toDouble();
  if (total == null) return 'Made so far: ${(done * 100).round()}%';
  String clock(double s) => '${s ~/ 60}:${(s.floor() % 60).toString().padLeft(2, '0')}';
  return 'Made so far: ${clock(done * total)} of ${clock(total)}';
}

/// A drive's distance in the comma's own units; km when the comma cannot be reached to ask
String distanceLabel(double km, bool? metric) =>
    metric == false ? '${(km / 1.609344).toStringAsFixed(1)} miles' : '${km.toStringAsFixed(1)} km';

/// One end of the range: a segment number (the default) or a local time of day
class RangeEnd {
  bool byTime = false;
  final text = TextEditingController();
}

class StudioPage extends StatefulWidget {
  /// starts or finds the replay server; tests supply their own
  final Future<Sidecar> Function() start;
  const StudioPage({super.key, this.start = Sidecar.start});
  @override
  State<StudioPage> createState() => _StudioPageState();
}

// the native side of full screen: macos/Runner/MainFlutterWindow.swift
const _window = MethodChannel('oprivview/window');

/// what a drive in the list can show
String detailLabel(String detail) => switch (detail) {
      'full' => 'Full detail (on the comma)',
      'logs' => 'Log and small video',
      'quick' => 'Quick detail only',
      _ => 'On comma Connect',
    };

class _StudioPageState extends State<StudioPage> {
  Sidecar? _sidecar;
  final _addDrive = TextEditingController();
  String? _addError;
  bool _adding = false;
  bool _fullScreen = false;
  final _preview = GlobalKey(); // keeps the preview playing as it moves in and out of full screen
  String? _fatal;
  List<ParamSpec> _specs = [];
  List<RouteInfo> _routes = [];
  String? _routesError;
  bool? _metric;
  RouteInfo? _route;
  final _start = RangeEnd(), _end = RangeEnd();
  final _output = TextEditingController();
  final Map<String, Object?> _options = {};
  String? _resolved, _resolveError;
  bool _checking = false;
  Map<String, dynamic>? _job;
  String? _previewFile; // set once the server has prepared a preview, which starts playing
  Uint8List? _snapshot; // the frame a render has reached, while it runs
  Timer? _poll;
  final _updater = ReplayUpdater();

  @override
  void initState() {
    super.initState();
    _start.text.addListener(_rangeChanged);
    _end.text.addListener(_rangeChanged);
    // macOS's own green button or Esc can end full screen too
    _window.setMethodCallHandler((call) async {
      if (call.method == 'exitedFullScreen' && mounted) setState(() => _fullScreen = false);
    });
    _boot();
  }

  Future<void> _toggleFullScreen() async {
    final on = !_fullScreen;
    setState(() => _fullScreen = on);
    try {
      await _window.invokeMethod('setFullScreen', on);
    } on MissingPluginException {
      // no native window under a widget test; the layout still changes
    }
  }

  Future<void> _addDriveFromField() async {
    final text = _addDrive.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _adding = true;
      _addError = null;
    });
    try {
      await _sidecar!.api.addDrive(text);
      _addDrive.clear();
      await _loadRoutes();
    } catch (e) {
      setState(() => _addError = '$e');
    } finally {
      setState(() => _adding = false);
    }
  }

  Future<void> _removeDrive(RouteInfo r) async {
    await _sidecar!.api.removeDrive(r.addedAs!);
    if (_route?.addedAs == r.addedAs) {
      setState(() {
        _route = null;
        _previewFile = null;
      });
    }
    await _loadRoutes();
  }

  Future<void> _openAdmin() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AdminPage(api: _sidecar!.api)));
    await _loadRoutes(); // the comma or the account may have changed
  }

  // a result from Check range only describes the range it was checked with
  void _rangeChanged() {
    if (_resolved != null || _resolveError != null) {
      setState(() {
        _resolved = null;
        _resolveError = null;
      });
    }
  }

  Future<void> _boot() async {
    try {
      final s = await widget.start();
      _sidecar = s;
      final specs = await s.api.params();
      setState(() {
        _specs = specs;
        for (final p in specs) {
          _options[p.name] = p.many ? <String>[...(p.defaultValue as List).cast<String>()] : p.defaultValue;
        }
      });
      await _loadRoutes();
      // an update quits the app: stop the server first, as closing the window does
      quitForUpdate = () {
        _sidecar?.stop();
        exit(0);
      };
      unawaited(_checkForUpdate(quiet: true));
    } catch (e) {
      setState(() => _fatal = '$e');
    }
  }

  Future<void> _loadRoutes() async {
    final r = await _sidecar!.api.routes();
    setState(() {
      _routes = r.routes;
      _routesError = r.error;
      _metric = r.metric;
    });
  }

  /// ask GitHub for a newer version, and offer it; [quiet] (at start) says nothing unless there is one
  Future<void> _checkForUpdate({bool quiet = false}) async {
    void say(String text) {
      if (!quiet && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }

    if (!_updater.enabled) {
      say('This is a local build (${replayVersion.isEmpty ? 'no version' : replayVersion}), so it does not update itself.');
      return;
    }
    bool includeTests = true;
    try {
      includeTests = (await _sidecar!.api.settings())['test_versions'] as bool? ?? true;
    } catch (_) {
      // the setting could not be read; offering test versions is the default
    }
    await _updater.check(includeTests: includeTests);
    if (!mounted) return;
    switch (_updater.status) {
      case ReplayUpdateStatus.available:
        await _offerUpdate();
      case ReplayUpdateStatus.upToDate:
        say('OPRivView Replay $replayVersion is the newest version.');
      default:
        say(_updater.message);
    }
  }

  Future<void> _offerUpdate() async {
    final release = _updater.latest!;
    // read when Update is pressed rather than when the dialog was drawn, since a render can start or end meanwhile
    final refused = ValueNotifier(false);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ListenableBuilder(
        listenable: Listenable.merge([_updater, refused]),
        builder: (context, _) {
          final busy = _updater.status == ReplayUpdateStatus.downloading || _updater.status == ReplayUpdateStatus.installing;
          return AlertDialog(
            title: Text('OPRivView Replay ${release.version} is available'),
            content: SizedBox(
                width: 560,
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('You have $replayVersion.${release.prerelease ? ' This is a test version.' : ''}'),
                  const SizedBox(height: 12),
                  ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 280),
                      child: SingleChildScrollView(child: SelectableText(plainNotes(release.notes), style: Theme.of(context).textTheme.bodySmall))),
                  const SizedBox(height: 12),
                  if (_updater.status == ReplayUpdateStatus.downloading && _updater.total > 0)
                    LinearProgressIndicator(value: _updater.received / _updater.total),
                  if (_updater.message.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_updater.message)),
                  if (refused.value) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Finish or cancel the render or preview first.')),
                ])),
            actions: [
              TextButton(onPressed: () => openOnDesktop(release.pageUrl), child: const Text('Release page')),
              TextButton(
                  onPressed: () {
                    if (busy) _updater.cancel();
                    Navigator.of(context).pop();
                  },
                  child: Text(busy ? 'Cancel' : 'Later')),
              FilledButton(
                  onPressed: busy
                      ? null
                      : () {
                          refused.value = _job?['state'] == 'running';
                          if (!refused.value) _updater.downloadAndInstall();
                        },
                  child: const Text('Update')),
            ],
          );
        },
      ),
    );
    refused.dispose();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _updater.dispose();
    _jobPolled.dispose();
    _uploadPoll?.cancel();
    _sidecar?.stop();
    super.dispose();
  }

  RangeRequest? _request() {
    final route = _route;
    if (route == null) return null;
    int? seg(RangeEnd e) => !e.byTime && e.text.text.trim().isNotEmpty ? int.tryParse(e.text.text.trim()) : null;
    String? time(RangeEnd e) => e.byTime && e.text.text.trim().isNotEmpty ? e.text.text.trim() : null;
    return RangeRequest(route.route,
        startSegment: seg(_start), endSegment: seg(_end), startTime: time(_start), endTime: time(_end));
  }

  Future<void> _resolve() async {
    final r = _request();
    if (r == null) return;
    setState(() {
      _resolved = null;
      _resolveError = null;
      _checking = true;
    });
    try {
      final j = await _sidecar!.api.resolve(r);
      setState(() => _resolved = 'Zone ${j['zone']}\nFrom ${j['start']}\nTo     ${j['end']}\n${j['seconds']} seconds');
    } catch (e) {
      setState(() => _resolveError = '$e');
    } finally {
      setState(() => _checking = false);
    }
  }

  // the computer's own save dialog, which also asks before replacing a file; no plugin needed. On Windows the app's
  // window code opens it (windows/runner/flutter_window.cpp)
  Future<void> _chooseOutput() async {
    final name = _route == null ? 'replay.mp4' : '${_route!.route}.mp4';
    if (Platform.isWindows) {
      final chosen = await _window.invokeMethod<String>('chooseSaveFile', name);
      if (chosen != null) _output.text = chosen;
      return;
    }
    final r = await Process.run('osascript', ['-e', 'POSIX path of (choose file name with prompt "Save the MP4 as" default name "$name")']);
    if (r.exitCode == 0) _output.text = (r.stdout as String).trim();
  }

  Future<void> _render({bool preview = false}) async {
    final r = _request();
    if (r == null) return;
    setState(() {
      _job = {'state': 'running', 'message': 'starting', 'preview': preview};
      _resolveError = null;
      _previewFile = null;
      _showSnapshot(null);
    });
    try {
      final out = _output.text.trim().isEmpty ? null : _output.text.trim();
      final j = await _sidecar!.api.startJob(r, _options, out, preview: preview);
      setState(() => _job = j);
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(seconds: 1), (t) async {
        final j = await _sidecar!.api.job(_job!['id']);
        final snapshot = await _readSnapshot(j);
        if (!mounted) return;
        setState(() {
          _job = j;
          _showSnapshot(snapshot);
          _jobPolled.value++;
          if (j['state'] == 'done' && j['preview'] == true) _previewFile = j['job_file'] as String?;
        });
        if (j['state'] != 'running') {
          t.cancel();
          _watchUpload(); // the job may have asked the comma to upload this drive's full files
        }
        final question = j['state'] == 'running' ? j['question'] as String? : null;
        if (question != null && !_asking && _answered != j['id']) unawaited(_ask(j['id'] as String, question));
      });
    } catch (e) {
      setState(() {
        _job = null;
        _resolveError = '$e';
      });
    }
  }

  bool _asking = false; // a job's question is open, so the next poll does not open it again
  String? _answered; // the job whose question was answered; the server may still show it for a moment

  /// a job waiting on the user: whether to copy through comma's server over the comma's metered connection
  Future<void> _ask(String id, String question) async {
    _asking = true;
    try {
      // the dialog covers the window's own Cancel, so it has one of its own: for a range started by mistake
      final choice = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Copy over a metered connection?'),
          content: SizedBox(width: 520, child: Text(question)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, 'cancel'), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, 'not now'), child: const Text('Not now')),
            FilledButton(onPressed: () => Navigator.pop(context, 'copy'), child: const Text('Copy now')),
          ],
        ),
      );
      _answered = id;
      if (choice == null || !mounted || _job?['id'] != id) return;
      if (choice == 'cancel') {
        _poll?.cancel();
        final j = await _sidecar!.api.cancel(id);
        if (mounted) setState(() => _job = j);
        return;
      }
      await _sidecar!.api.answer(id, choice == 'copy');
    } on StudioError {
      // the job ended or was cancelled while the question was open
    } finally {
      _asking = false;
    }
  }

  /// the picture a running render has reached; the one already shown if the file is being replaced just then
  Future<Uint8List?> _readSnapshot(Map<String, dynamic> j) async {
    final path = j['state'] == 'running' ? j['snapshot'] as String? : null;
    if (path == null) return null;
    try {
      return await File(path).readAsBytes();
    } on FileSystemException {
      return _snapshot;
    }
  }

  /// each picture is new to Flutter's image cache, so the one it replaces is dropped from it
  void _showSnapshot(Uint8List? bytes) {
    final old = _snapshot;
    if (identical(old, bytes)) return;
    if (old != null) imageCache.evict(MemoryImage(old));
    _snapshot = bytes;
  }

  Map<String, dynamic>? _upload; // how an upload of the selected drive's full files to Connect is going
  Timer? _uploadPoll;

  /// Look at the selected drive's upload to Connect, if the app asked for one, and keep looking every 15 s until it is
  /// done. Asking the comma takes a few seconds, more while it is offline, so it is not done more often.
  void _watchUpload() {
    _uploadPoll?.cancel();
    final route = _route;
    if (route == null || route.addedAs != null || _sidecar == null) return;
    Future<void> look() async {
      Map<String, dynamic> u;
      try {
        u = await _sidecar!.api.uploadStatus(route.route);
      } on Object {
        return; // the server is busy or gone; the next look may do better
      }
      if (!mounted || _route?.route != route.route) return;
      setState(() => _upload = u);
      if (u['requested'] != true || u['done'] == true) {
        _uploadPoll?.cancel();
        if (u['done'] == true) await _loadRoutes(); // the drive now lists at full detail
      }
    }

    unawaited(look());
    _uploadPoll = Timer.periodic(const Duration(seconds: 15), (_) => look());
  }

  /// counts the job's updates, for the Cancel question, which is outside this page's own rebuilds
  final _jobPolled = ValueNotifier(0);

  /// once a render has made frames, Cancel asks whether to keep them as a shorter clip, throw them away, or carry on (in
  /// case Cancel was pressed by mistake). The render keeps going while the question is open.
  Future<void> _cancel() async {
    final id = _job!['id'] as String;
    final made = _job!['preview'] != true && ((_job!['progress'] as num?) ?? 0) > 0;
    final choice = !made
        ? 'discard'
        : await showDialog<String>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Stop the render?'),
                content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('You can keep the part made so far as a shorter clip, with "(partial)" added to its name, '
                      'or throw it away.'),
                  const SizedBox(height: 12),
                  // the render carries on behind the question, so this keeps up with it
                  ValueListenableBuilder(valueListenable: _jobPolled, builder: (_, __, ___) => Text(madeSoFar(_job ?? const {}))),
                ]),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context, 'continue'), child: const Text('Keep rendering')),
                  TextButton(onPressed: () => Navigator.pop(context, 'discard'), child: const Text('Discard')),
                  FilledButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text("Save what's done")),
                ],
              )) ??
            'continue';
    // the render may have finished, or failed, while the question was open
    if (choice == 'continue' || !mounted || _job?['id'] != id || _job?['state'] != 'running') return;
    if (choice == 'save') {
      final j = await _sidecar!.api.finish(id);
      if (mounted) setState(() => _job = j); // the poll carries on until the clip is saved
      return;
    }
    _poll?.cancel();
    final j = await _sidecar!.api.cancel(id);
    setState(() {
      _job = j;
      _showSnapshot(null);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _fatal != null
          ? Center(child: Text(_fatal!, style: const TextStyle(color: Colors.red)))
          : _sidecar == null || _specs.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _fullScreen && _previewFile != null
                  ? _fullScreenPreview()
                  : Row(children: [
                  SizedBox(width: 280, child: _routeList()),
                  const VerticalDivider(width: 1),
                  SizedBox(width: 420, child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: _form())),
                  const VerticalDivider(width: 1),
                  Expanded(child: _outputPane()),
                ]),
    );
  }

  Widget _previewPlayer() => PreviewPlayer(
        key: _preview,
        jobFile: _previewFile!,
        onOptionsChanged: (o) => setState(() => _options.addAll(o)),
        seek: _sidecar!.api.seek,
        fullScreen: _fullScreen,
        onToggleFullScreen: _toggleFullScreen,
      );

  // nothing but the picture and its controls; Esc comes back out
  Widget _fullScreenPreview() => Focus(
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.escape) return KeyEventResult.ignored;
          _toggleFullScreen();
          return KeyEventResult.handled;
        },
        child: ColoredBox(color: Colors.black, child: _previewPlayer()),
      );

  Widget _routeList() => Column(children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
            child: Row(children: [
              Expanded(
                  child: TextField(
                      controller: _addDrive,
                      onSubmitted: (_) => _addDriveFromField(),
                      style: Theme.of(context).textTheme.bodySmall,
                      decoration: InputDecoration(
                        hintText: 'Paste a public drive or device',
                        isDense: true,
                        errorText: _addError,
                        errorMaxLines: 3,
                      ))),
              _adding
                  ? const Padding(
                      padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                  : IconButton(tooltip: 'Add', icon: const Icon(Icons.add), onPressed: _addDriveFromField),
              IconButton(tooltip: 'App settings', icon: const Icon(Icons.settings), onPressed: _openAdmin),
              PopupMenuButton<String>(
                tooltip: 'Help',
                icon: const Icon(Icons.help_outline),
                onSelected: (v) => v == 'update' ? _checkForUpdate() : openOnDesktop(v),
                itemBuilder: (_) => [
                  PopupMenuItem(value: '$guidesUrl/USER_GUIDE.md', child: const Text('User guide')),
                  PopupMenuItem(value: '$guidesUrl/${Platform.isWindows ? 'INSTALL-WINDOWS.md' : 'INSTALL.md'}', child: const Text('Install guide')),
                  const PopupMenuItem(value: 'update', child: Text('Check for updates')),
                  if (replayVersion.isNotEmpty) PopupMenuItem(enabled: false, child: Text('Version $replayVersion')),
                ],
              ),
            ])),
        if (_routesError != null)
          Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: [
                Text(_routesError!, style: const TextStyle(color: Colors.orange)),
                TextButton(onPressed: _loadRoutes, child: const Text('Try again')),
              ])),
        Expanded(
            child: ListView(children: [
          for (final r in _routes)
            ListTile(
              dense: true,
              selected: r == _route,
              title: Text(r.localStart ?? r.route),
              subtitle: Text([
                if (r.localStart != null) r.route,
                if (r.place != null) r.place!,
                'segments ${r.first} to ${r.last}${r.km == null ? '' : ', ${distanceLabel(r.km!, _metric)}'}',
                if (r.addedAs != null) 'Public drive: ${detailLabel(r.detail)}' else detailLabel(r.detail),
              ].join('\n')),
              isThreeLine: r.localStart != null,
              trailing: r.addedAs == null
                  ? null
                  : IconButton(tooltip: 'Remove from the list', icon: const Icon(Icons.close, size: 18), onPressed: () => _removeDrive(r)),
              // a job in progress keeps the window on its drive, so its progress and Cancel stay in view
              onTap: _job?['state'] == 'running' ? null : () => setState(() {
                if (r.route != _route?.route) {
                  // a range only means something for the drive it was typed for
                  _start.text.clear();
                  _end.text.clear();
                }
                _route = r;
                _resolved = null;
                _resolveError = null;
                _job = null;
                _previewFile = null; // the old preview belongs to the drive that was selected before
                _upload = null;
                _watchUpload();
              }),
            ),
        ])),
      ]);

  // the drive, the range and the options; this column scrolls on its own
  Widget _form() {
    final route = _route;
    final small = Theme.of(context).textTheme.bodySmall;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(route == null ? 'Choose a drive from the list' : route.localStart ?? route.route, style: Theme.of(context).textTheme.titleLarge),
      if (route?.localStart != null) Text(route!.route, style: small),
      if (uploadLine(_upload) != null)
        Padding(padding: const EdgeInsets.only(top: 6), child: Text(uploadLine(_upload)!, style: small?.copyWith(color: Colors.lightBlueAccent))),
      const SizedBox(height: 16),
      _rangeRow('Start', _start, route),
      _rangeRow('End', _end, route),
      const SizedBox(height: 4),
      Text('Leave a field empty for the start or end of the drive. Times are local to where the drive happened.', style: small),
      const SizedBox(height: 8),
      Row(children: [
        OutlinedButton(onPressed: route == null || _checking ? null : _resolve, child: Text(_checking ? 'Checking...' : 'Check range')),
        if (_checking) const Padding(padding: EdgeInsets.only(left: 12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
      ]),
      const Divider(height: 32),
      for (final p in _specs.where((p) => !p.advanced)) _option(p),
      ExpansionTile(
        title: const Text('Advanced'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final p in _specs.where((p) => p.advanced)) _option(p)],
      ),
    ]);
  }

  // what comes out: always on screen, so progress and the finished clip are never out of sight
  Widget _outputPane() {
    final running = _job?['state'] == 'running';
    return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
              child: SingleChildScrollView(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _previewFile != null
                ? _previewPlayer()
                : running && _snapshot != null
                ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Image.memory(_snapshot!, gaplessPlayback: true, fit: BoxFit.contain),
                    Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(renderPictureNote, style: Theme.of(context).textTheme.bodySmall)),
                  ])
                : AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Container(
                        alignment: Alignment.center,
                        color: Colors.white10,
                        child: Text(running ? 'Working on it...' : 'The preview plays here'))),
            if (_resolved != null) Padding(padding: const EdgeInsets.only(top: 12), child: SelectableText(_resolved!, style: TextStyle(fontFamily: Platform.isWindows ? 'Consolas' : 'Menlo', fontSize: 12))),
            if (_resolveError != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_resolveError!, style: const TextStyle(color: Colors.red))),
            if (_job != null) _jobStatus(),
          ]))),
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
                child: TextField(
                    controller: _output,
                    decoration: InputDecoration(
                        labelText: 'Output file',
                        hintText: 'Leave empty to save in ${Platform.isWindows ? 'Videos' : 'Movies'}',
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                        isDense: true))),
            if (Platform.isMacOS || Platform.isWindows) ...[
              const SizedBox(width: 8),
              TextButton(onPressed: _chooseOutput, child: const Text('Choose...')),
            ],
          ]),
          const SizedBox(height: 12),
          Row(children: [
            OutlinedButton(onPressed: _route == null || running ? null : () => _render(preview: true), child: const Text('Preview')),
            const SizedBox(width: 12),
            FilledButton(onPressed: _route == null || running ? null : _render, child: const Text('Render MP4')),
            if (running && _job?['id'] != null) ...[
              const SizedBox(width: 12),
              TextButton(onPressed: _job?['stopping'] == true ? null : _cancel, child: const Text('Cancel')),
            ],
          ]),
        ]));
  }

  Widget _rangeRow(String label, RangeEnd e, RouteInfo? route) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(width: 50, child: Text(label)),
        SegmentedButton<bool>(
          showSelectedIcon: false, // a tick would widen the selected side and push the field along
          segments: const [ButtonSegment(value: true, label: Text('Time')), ButtonSegment(value: false, label: Text('Segment'))],
          selected: {e.byTime},
          onSelectionChanged: (s) => setState(() {
            e.byTime = s.first;
            e.text.clear();
          }),
        ),
        const SizedBox(width: 12),
        Expanded(
            child: TextField(
                controller: e.text,
                decoration: InputDecoration(
                    hintText: e.byTime ? 'HH:MM:SS' : (route == null ? 'number' : '${route.first}-${route.last}'), isDense: true))),
      ]));

  Widget _option(ParamSpec p) {
    final title = '${p.label[0].toUpperCase()}${p.label.substring(1)}';
    final Widget control;
    if (p.many) {
      final chosen = _options[p.name] as List<String>;
      control = Wrap(spacing: 8, children: [
        for (final c in p.choices!)
          FilterChip(
            label: Text(choiceLabel(c)),
            selected: chosen.contains(c),
            onSelected: (on) => setState(() => on ? chosen.add(c) : chosen.remove(c)),
          ),
      ]);
    } else if (p.choices != null) {
      // a null default means "the app's own choice"; show it as the first option
      final hasDefault = p.defaultValue == null;
      Widget chip(String? value, String label) => ChoiceChip(
            label: Text(label),
            selected: _options[p.name] == value,
            onSelected: (on) {
              if (on) setState(() => _options[p.name] = value);
            },
          );
      control = Wrap(spacing: 8, runSpacing: 4, children: [
        if (hasDefault) chip(null, 'App default'),
        for (final c in p.choices!) chip(c, choiceLabel(c)),
      ]);
    } else {
      control = SizedBox(
          width: 160,
          child: TextFormField(
            initialValue: '${_options[p.name] ?? ''}',
            decoration: const InputDecoration(isDense: true),
            onChanged: (v) => _options[p.name] = p.kind == 'integer' ? (int.tryParse(v) ?? _options[p.name]) : v,
          ));
    }
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title),
          if (p.help.isNotEmpty) Text(p.help, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          control,
        ]));
  }

  Widget _jobStatus() {
    final j = _job!;
    final state = j['state'];
    return Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (state == 'running') LinearProgressIndicator(value: (j['progress'] as num?)?.toDouble()),
          const SizedBox(height: 6),
          Text(state == 'failed' ? 'Failed: ${j['error']}' : state == 'cancelled' ? 'Stopped. No clip was saved.' : j['preview'] == true && state == 'done' ? '' : '${j['message']}',
              style: TextStyle(color: state == 'failed' ? Colors.red : null)),
          // e.g. that the comma was asked to put the full files on Connect; it stays after the job
          if (j['note'] != null) Text('${j['note']}', style: Theme.of(context).textTheme.bodySmall),
          if (state == 'done' && j['preview'] != true)
            Row(children: [
              Expanded(child: SelectableText(j['output'])),
              TextButton(onPressed: () => showInFileManager(j['output']), child: Text('Show in $fileManagerName')),
              TextButton(onPressed: () => openOnDesktop(j['output']), child: const Text('Play')),
            ]),
        ]));
  }
}
