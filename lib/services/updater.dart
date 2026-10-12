// in-app updates: compare this build with the newest GitHub release of Geomglot/opview (pre-releases included),
// download its APK, and hand it to Android's installer (which always asks to confirm).
// Updates install over the app only when both are signed with the same release key

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:opview/services/system_service.dart' as system;

/// this build's version: the release tag without its "v" (e.g. 0.1.1-mici.5), set at build
/// time with --dart-define=OPVIEW_BUILD; branch builds are "<branch>-<sha>"
const installedVersion = String.fromEnvironment('OPVIEW_BUILD', defaultValue: 'dev build');

// the newest releases first; /releases/latest would skip pre-releases, and all of Geomglot's are pre-releases
const _latestReleaseUrl = 'https://api.github.com/repos/Geomglot/opview/releases?per_page=10';

class ReleaseInfo {
  final String version;  // tag without the leading v
  final String apkUrl;
  final int apkSize;
  final String notes;

  const ReleaseInfo({required this.version, required this.apkUrl, required this.apkSize, required this.notes});

  /// the release from GitHub's JSON, or null when it has no APK
  static ReleaseInfo? fromJson(Map<String, dynamic> json) {
    final tag = json['tag_name'] as String? ?? '';
    final assets = (json['assets'] as List? ?? const []).whereType<Map<String, dynamic>>();
    final apk = assets.where((a) => (a['name'] as String? ?? '').endsWith('.apk')).firstOrNull;
    if (tag.isEmpty || apk == null) return null;
    return ReleaseInfo(
      version: tag.startsWith('v') ? tag.substring(1) : tag,
      apkUrl: apk['browser_download_url'] as String? ?? '',
      apkSize: (apk['size'] as num?)?.toInt() ?? 0,
      notes: json['body'] as String? ?? '',
    );
  }
}

/// the newest release with an APK: from a list of releases (newest first, drafts skipped), or a single release
ReleaseInfo? newestRelease(Object? json) {
  if (json is Map<String, dynamic>) return ReleaseInfo.fromJson(json);
  if (json is! List) return null;
  for (final r in json.whereType<Map<String, dynamic>>()) {
    if (r['draft'] == true) continue;
    final info = ReleaseInfo.fromJson(r);
    if (info != null) return info;
  }
  return null;
}

/// the numbers in a version, in order: 0.1.1-mici.5 -> [0, 1, 1, 5]
List<int> versionNumbers(String v) => RegExp(r'\d+').allMatches(v).map((m) => int.parse(m[0]!)).toList();

/// whether [latest] is newer than [installed]. A build that is not a release (a branch or dev
/// build, no leading number) can always update to a release
bool isNewerVersion(String latest, String installed) {
  if (!RegExp(r'^\d').hasMatch(installed)) return true;
  final a = versionNumbers(latest), b = versionNumbers(installed);
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// "- Detailed: ..." lines from the release notes, without headings or the download section
List<String> releaseNoteLines(String notes, {int max = 4}) {
  final out = <String>[];
  for (final raw in const LineSplitter().convert(notes)) {
    final line = raw.trim();
    if (line.startsWith('## Download')) break;
    if (line.startsWith('- ')) out.add(line.substring(2));
    if (out.length == max) break;
  }
  return out;
}

enum UpdateStatus { idle, checking, upToDate, available, downloading, installing, failed }

class Updater extends ChangeNotifier {
  final http.Client Function() _client;
  final String installed;

  Updater({http.Client Function()? client, this.installed = installedVersion}) : _client = client ?? http.Client.new;

  UpdateStatus status = UpdateStatus.idle;
  ReleaseInfo? latest;
  int received = 0;
  int total = 0;
  String message = '';
  bool _cancelled = false;

  void _set(UpdateStatus s, [String msg = '']) {
    status = s;
    message = msg;
    notifyListeners();
  }

  /// ask GitHub for the latest release
  Future<void> check() async {
    if (status == UpdateStatus.checking || status == UpdateStatus.downloading) return;
    _set(UpdateStatus.checking);
    final client = _client();
    try {
      final r = await client
          .get(Uri.parse(_latestReleaseUrl), headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) {
        _set(UpdateStatus.failed, 'GitHub answered ${r.statusCode}');
        return;
      }
      final release = newestRelease(jsonDecode(r.body));
      if (release == null) {
        _set(UpdateStatus.failed, 'The latest release has no APK');
        return;
      }
      latest = release;
      _set(isNewerVersion(release.version, installed) ? UpdateStatus.available : UpdateStatus.upToDate);
    } catch (e) {
      _set(UpdateStatus.failed, 'No connection to GitHub');
    } finally {
      client.close();
    }
  }

  /// download the latest release's APK, then hand it to Android's installer
  Future<void> downloadAndInstall() async {
    final release = latest;
    if (release == null || status == UpdateStatus.downloading) return;
    _cancelled = false;
    received = 0;
    total = release.apkSize;
    _set(UpdateStatus.downloading);
    final client = _client();
    try {
      final dir = Directory('${Directory.systemTemp.path}/updates');  // the app's cache on Android
      await dir.create(recursive: true);
      final file = File('${dir.path}/OPRivView-update.apk');
      final response = await client.send(http.Request('GET', Uri.parse(release.apkUrl)));
      if (response.statusCode != 200) {
        _set(UpdateStatus.failed, 'Download failed (${response.statusCode})');
        return;
      }
      if ((response.contentLength ?? 0) > 0) total = response.contentLength!;
      final sink = file.openWrite();
      try {
        await for (final chunk in response.stream) {
          if (_cancelled) break;
          sink.add(chunk);
          received += chunk.length;
          notifyListeners();
        }
      } finally {
        await sink.close();
      }
      if (_cancelled) {
        if (await file.exists()) await file.delete();
        _set(UpdateStatus.available);
        return;
      }
      _set(UpdateStatus.installing);
      if (!await system.canInstallApks()) {
        // Android asks once to allow installs from this app; after that, Update again
        await system.openInstallSettings();
        _set(UpdateStatus.available, 'Allow "Install unknown apps" for OPRivView, then Update again');
        return;
      }
      await system.installApk(file.path);
      _set(UpdateStatus.available, 'Confirm the install on screen');
    } catch (e) {
      _set(UpdateStatus.failed, 'Download failed');
    } finally {
      client.close();
    }
  }

  void cancel() => _cancelled = true;
}

/// the one updater for the app, shared by every Settings dialog
final appUpdater = Updater();
