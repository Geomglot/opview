// Starts the replay server next to the app, or finds one already running

import 'dart:async';
import 'dart:io';

import 'package:opview/studio/studio_api.dart';

class Sidecar {
  final Process? process;
  final StudioApi api;
  Sidecar(this.process, this.api);

  /// OPRIVVIEW_SERVER_URL uses a server you started yourself. Otherwise the server inside the app is used, or in a
  /// development build the one in the replay folder,
  /// found from OPRIVVIEW_REPLAY_DIR or by walking up from this app (a development build sits inside the repo).
  static Future<Sidecar> start() async {
    final url = Platform.environment['OPRIVVIEW_SERVER_URL'];
    if (url != null) return Sidecar(null, StudioApi(Uri.parse(url)));

    final port = await _freePort();
    final args = ['--port', '$port', '--app', Platform.resolvedExecutable, '--exit-with-parent'];
    final resources = '${File(Platform.resolvedExecutable).parent.parent.path}/Resources';
    final packaged = File('$resources/oprivview-replay-server/oprivview-replay-server');
    final Process p;
    if (packaged.existsSync()) {
      // an installed app carries its own server and ffmpeg. A downloaded app has every file marked as downloaded, and
      // macOS stops each marked program with a dialog; the user has approved this app by now, so its parts need no more
      await Process.run('/usr/bin/xattr', ['-dr', 'com.apple.quarantine', File(resources).parent.path]);
      p = await Process.start(packaged.path, args, environment: {'OPRIVVIEW_FFMPEG_DIR': '$resources/ffmpeg'});
    } else {
      final dir = _replayDir();
      p = await Process.start('${dir.path}/.venv/bin/python', ['-m', 'oprivview_replay.server', ...args], workingDirectory: dir.path);
    }
    p.stderr.drain<void>();
    p.stdout.drain<void>();
    final api = StudioApi(Uri.parse('http://127.0.0.1:$port'));
    for (var i = 0; i < 100; i++) {
      if (await api.healthy()) return Sidecar(p, api);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    p.kill();
    throw StudioError('the replay server did not start');
  }

  static Directory _replayDir() {
    final env = Platform.environment['OPRIVVIEW_REPLAY_DIR'];
    if (env != null) return Directory(env);
    var d = File(Platform.resolvedExecutable).parent;
    while (d.parent.path != d.path) {
      final candidate = Directory('${d.path}/replay');
      if (File('${candidate.path}/oprivview_replay/server.py').existsSync()) return candidate;
      d = d.parent;
    }
    throw StudioError('cannot find the replay folder; set OPRIVVIEW_REPLAY_DIR');
  }

  static Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  void stop() {
    api.close();
    process?.kill();
  }
}
