// In-app updates for GeoRivView Replay on the Mac, Windows and Linux: find the newest replay release on GitHub that has a file
// for this computer, offer it, download it, check it against GitHub's SHA-256, and install it.
// Separate from the Android app's updater (lib/services/updater.dart): replay releases are tagged replay-v<version>,
// have a .dmg, .exe or .AppImage rather than an APK, and order their test versions before the final one.
// Windows: the installer (replay/packaging/windows-installer.iss) runs silently, closes this app and reopens it.
// Mac: the new app is copied out of the disk image and checked, and a script swaps it in once this app has quit.
// Linux: the new AppImage takes the place of the one running, and is opened.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:opview/studio/desktop.dart';
import 'package:opview/studio/version.dart';

/// the newest releases first; drafts are not listed to anyone else, and pre-releases are included.
/// OPRIVVIEW_RELEASES_URL replaces it, to try an update against a list of your own (in the same form as GitHub's).
final replayReleasesUrl =
    Platform.environment['OPRIVVIEW_RELEASES_URL'] ?? 'https://api.github.com/repos/Geomglot/opview/releases?per_page=20';

/// A replay version: 0.1.2 or a test of it, 0.1.2-test.3. Tests come before the version they lead to.
class ReplayVersion implements Comparable<ReplayVersion> {
  final List<int> numbers;
  final int? test;
  const ReplayVersion(this.numbers, [this.test]);

  /// null for anything else, such as a local "-dev" build
  static ReplayVersion? parse(String text) {
    final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:-test\.(\d+))?$').firstMatch(text.trim());
    if (m == null) return null;
    return ReplayVersion([for (var i = 1; i <= 3; i++) int.parse(m[i]!)], m[4] == null ? null : int.parse(m[4]!));
  }

  @override
  int compareTo(ReplayVersion other) {
    for (var i = 0; i < 3; i++) {
      if (numbers[i] != other.numbers[i]) return numbers[i].compareTo(other.numbers[i]);
    }
    if (test == other.test) return 0;
    if (test == null) return 1; // the final version comes after all its tests
    if (other.test == null) return -1;
    return test!.compareTo(other.test!);
  }

  bool operator >(ReplayVersion other) => compareTo(other) > 0;

  @override
  String toString() => '${numbers.join('.')}${test == null ? '' : '-test.$test'}';
}

/// the end of the release file's name for this computer: what replay-release.yml uploads
Future<String> assetSuffixForThisComputer() async {
  if (Platform.isWindows) return '-Windows.exe';
  if (Platform.isLinux) return '-Linux-x86_64.AppImage';
  // right even when this app runs under Rosetta, unlike asking which chip the app itself is built for
  final r = await Process.run('/usr/sbin/sysctl', ['-n', 'hw.optional.arm64']);
  return (r.stdout as String).trim() == '1' ? '-macOS-ARM.dmg' : '-macOS-Intel.dmg';
}

class ReplayRelease {
  final ReplayVersion version;
  final String tag, pageUrl, notes;
  final bool prerelease;
  final String fileName, fileUrl;
  final int size;
  /// from GitHub's digest of the file; null when GitHub gives none, and then [sumsUrl] is used
  final String? sha256;
  final String? sumsUrl;

  const ReplayRelease({required this.version, required this.tag, required this.pageUrl, required this.notes,
      required this.prerelease, required this.fileName, required this.fileUrl, required this.size, this.sha256, this.sumsUrl});
}

/// the newest replay release in GitHub's list that has a file ending [suffix]; test versions only when [includeTests]
ReplayRelease? newestReplayRelease(Object? json, {required String suffix, required bool includeTests}) {
  if (json is! List) return null;
  ReplayRelease? best;
  for (final r in json.whereType<Map<String, dynamic>>()) {
    final tag = r['tag_name'] as String? ?? '';
    if (r['draft'] == true || !tag.startsWith('replay-v')) continue;
    final version = ReplayVersion.parse(tag.substring('replay-v'.length));
    if (version == null) continue; // the older releases named for one platform, such as replay-v0.1.1-windows-test.1
    final prerelease = r['prerelease'] == true;
    if ((prerelease || version.test != null) && !includeTests) continue;
    final assets = (r['assets'] as List? ?? const []).whereType<Map<String, dynamic>>();
    final file = assets.where((a) => a['name'] == 'GeoRivView-Replay-$version$suffix').firstOrNull ??
        assets.where((a) => a['name'] == 'OPRivView-Replay-$version$suffix').firstOrNull; // the name before GeoRivView
    if (file == null) continue;
    if (best != null && !(version > best.version)) continue;
    final digest = file['digest'] as String? ?? '';
    best = ReplayRelease(
      version: version,
      tag: tag,
      pageUrl: r['html_url'] as String? ?? 'https://github.com/Geomglot/opview/releases/tag/$tag',
      notes: r['body'] as String? ?? '',
      prerelease: prerelease,
      fileName: file['name'] as String,
      fileUrl: file['browser_download_url'] as String? ?? '',
      size: (file['size'] as num?)?.toInt() ?? 0,
      sha256: digest.startsWith('sha256:') ? digest.substring(7).toLowerCase() : null,
      sumsUrl: assets.where((a) => a['name'] == 'SHA256SUMS').firstOrNull?['browser_download_url'] as String?,
    );
  }
  return best;
}

/// [name]'s SHA-256 from a SHA256SUMS file (`<hash>  <name>` lines, as sha256sum writes them)
String? sha256From(String sums, String name) {
  for (final line in const LineSplitter().convert(sums)) {
    final m = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(line.trim());
    if (m != null && m[2] == name) return m[1]!.toLowerCase();
  }
  return null;
}

/// release notes as plain text for the update dialog: headings, bold and links written out without their marks
String plainNotes(String markdown) => const LineSplitter()
    .convert(markdown)
    .map((line) => line
        .replaceFirst(RegExp(r'^#+\s*'), '')
        .replaceAll('**', '')
        .replaceAll('`', '')
        .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!))
    .join('\n')
    .trim();

/// a file's SHA-256 in hex, worked out off the UI thread (a release file is around 100 MB)
Future<String> fileSha256(String path) => Isolate.run(() async => (await sha256.bind(File(path).openRead()).first).toString());

enum ReplayUpdateStatus { idle, checking, upToDate, available, downloading, installing, failed }

class ReplayUpdater extends ChangeNotifier {
  final http.Client Function() _client;
  final String installed;
  final Future<String> Function() _suffix;
  final Future<Directory> Function() _downloads;

  /// puts the downloaded file in place; returns what to tell the user, or does not return because the app has quit
  final Future<String> Function(File file) _install;

  ReplayUpdater({
    http.Client Function()? client,
    this.installed = replayVersion,
    Future<String> Function()? suffix,
    Future<Directory> Function()? downloads,
    Future<String> Function(File file)? install,
  })  : _client = client ?? http.Client.new,
        _suffix = suffix ?? assetSuffixForThisComputer,
        _downloads = downloads ?? (() async => Directory('${Directory.systemTemp.path}${Platform.pathSeparator}OPRivViewReplay-update')),
        _install = install ?? installForThisComputer;

  ReplayUpdateStatus status = ReplayUpdateStatus.idle;
  ReplayRelease? latest;
  int received = 0, total = 0;
  String message = '';
  bool _cancelled = false;

  /// updates only make sense for a release build: a local "-dev" build, or one with no version, does not parse
  ReplayVersion? get installedVersion => ReplayVersion.parse(installed);
  bool get enabled => installedVersion != null;

  void _set(ReplayUpdateStatus s, [String msg = '']) {
    status = s;
    message = msg;
    notifyListeners();
  }

  /// ask GitHub for the newest release this computer can use
  Future<void> check({required bool includeTests}) async {
    final current = installedVersion;
    if (current == null || status == ReplayUpdateStatus.checking || status == ReplayUpdateStatus.downloading) return;
    _set(ReplayUpdateStatus.checking);
    final client = _client();
    try {
      final r = await client
          .get(Uri.parse(replayReleasesUrl), headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) {
        _set(ReplayUpdateStatus.failed, 'GitHub answered ${r.statusCode}');
        return;
      }
      final release = newestReplayRelease(jsonDecode(r.body), suffix: await _suffix(), includeTests: includeTests);
      latest = release;
      _set(release != null && release.version > current ? ReplayUpdateStatus.available : ReplayUpdateStatus.upToDate);
    } catch (e) {
      _set(ReplayUpdateStatus.failed, 'Could not reach GitHub to check for updates');
    } finally {
      client.close();
    }
  }

  /// download the newer release's file (or reuse a whole one downloaded before), check it, and install it
  Future<void> downloadAndInstall() async {
    final release = latest;
    if (release == null || status == ReplayUpdateStatus.downloading || status == ReplayUpdateStatus.installing) return;
    _cancelled = false;
    received = 0;
    total = release.size;
    final client = _client();
    var step = 'Download failed';
    try {
      final dir = await _downloads();
      await dir.create(recursive: true);
      final file = File('${dir.path}${Platform.pathSeparator}${release.fileName}');
      // downloads of other versions are no longer needed
      await for (final old in dir.list()) {
        if (old is File && old.path != file.path) await old.delete();
      }
      _set(ReplayUpdateStatus.downloading, 'Checking for an earlier download');
      final want = release.sha256 ?? await _sumsFor(client, release);
      if (want == null) {
        _set(ReplayUpdateStatus.failed, 'The release gives no checksum for ${release.fileName}, so it was not downloaded');
        return;
      }
      if (await file.exists() && await file.length() == release.size && await fileSha256(file.path) == want) {
        received = total;
      } else {
        _set(ReplayUpdateStatus.downloading);
        if (!await _download(client, release, file, want)) return;
      }
      step = 'Could not install the update';
      _set(ReplayUpdateStatus.installing);
      _set(ReplayUpdateStatus.available, await _install(file));
    } catch (e) {
      _set(ReplayUpdateStatus.failed, '$step: $e');
    } finally {
      client.close();
    }
  }

  Future<String?> _sumsFor(http.Client client, ReplayRelease release) async {
    if (release.sumsUrl == null) return null;
    final r = await client.get(Uri.parse(release.sumsUrl!)).timeout(const Duration(seconds: 30));
    return r.statusCode == 200 ? sha256From(r.body, release.fileName) : null;
  }

  /// download into [file]; false (with the status set) unless it arrived whole and matches [want]
  Future<bool> _download(http.Client client, ReplayRelease release, File file, String want) async {
    final response = await client.send(http.Request('GET', Uri.parse(release.fileUrl)));
    if (response.statusCode != 200) {
      _set(ReplayUpdateStatus.failed, 'Download failed (${response.statusCode})');
      return false;
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
    if (!_cancelled) _set(ReplayUpdateStatus.downloading, 'Checking the download');
    if (_cancelled || (total > 0 && received < total) || await fileSha256(file.path) != want) {
      final why = _cancelled ? '' : (received < total ? 'Download incomplete: try again' : 'Download damaged: try again');
      await file.delete();
      _set(_cancelled ? ReplayUpdateStatus.available : ReplayUpdateStatus.failed, why);
      return false;
    }
    return true;
  }

  void cancel() => _cancelled = true;
}

/// what quits the app for an update: set by the window, which stops the replay server first
void Function() quitForUpdate = () => exit(0);

/// Windows: the installer, silently, which closes this app (and its server), replaces it, and opens the new version.
/// Mac: the new app is copied out of the disk image beside this one and checked, then a small script swaps the two once
/// this app has quit and opens the new one. Where that cannot work, the disk image is shown in the Finder instead.
/// Linux: the new AppImage replaces the running one under the same name, so shortcuts to it keep working, and is opened.
Future<String> installForThisComputer(File file) async {
  if (Platform.isWindows) {
    await Process.start(file.path, ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/RELAUNCH'], mode: ProcessStartMode.detached);
    quitForUpdate();
    return 'Installing'; // not reached once the app has quit
  }
  if (Platform.isLinux) return _installLinux(file);
  final app = File(Platform.resolvedExecutable).parent.parent.parent.path; // .../GeoRivView Replay.app
  final writable = (await Process.run('/bin/test', ['-w', File(app).parent.path])).exitCode == 0;
  final refusal = macInstallRefusal(app, writable: writable);
  if (refusal != null) return _byHand(file, refusal);
  try {
    final arch = await assetSuffixForThisComputer() == '-macOS-ARM.dmg' ? 'arm64' : 'x86_64';
    final (staged, name) = await _stageMacApp(file, app, arch);
    final script = File('${file.parent.path}/swap-app.sh');
    await script.writeAsString(macSwapScript);
    // the new app goes in under its own name, so a renamed app (OPRivView Replay to GeoRivView Replay) is renamed too
    await Process.start('/usr/bin/nohup',
        ['/bin/bash', script.path, app, staged, '${file.parent.path}/swap-app.log', '${File(app).parent.path}/$name'],
        mode: ProcessStartMode.detached);
  } on _MacInstallError catch (e) {
    return _byHand(file, e.message);
  }
  quitForUpdate();
  return 'Installing'; // not reached once the app has quit
}

/// why the app at [app] cannot replace itself, or null if it can
String? macInstallRefusal(String app, {required bool writable}) {
  if (!app.endsWith('.app')) return 'This copy of the app is not in an app bundle';
  if (app.startsWith('/Volumes/')) return 'The app is running from the disk image rather than from Applications';
  if (app.contains('/AppTranslocation/')) {
    return 'macOS is running the app from a temporary place, because it was opened where it was downloaded. Move it to '
        'Applications first';
  }
  if (!writable) return 'This Mac account cannot change the folder the app is in';
  return null;
}

/// the AppImage this app is running from (the AppImage itself says, in APPIMAGE) or why it cannot replace itself
String? linuxInstallRefusal(String? appImage, {required bool writable}) {
  if (appImage == null || appImage.isEmpty) return 'This copy of the app is not running from its AppImage';
  if (!writable) return 'This account cannot change the folder the AppImage is in';
  return null;
}

/// a running program's file can be replaced on Linux: the program keeps the old one open until it quits. The new file
/// is copied beside the old one first (the download may be on another disk, where a rename cannot reach) and made
/// runnable, then renamed over it in one step, so the AppImage is never half there.
Future<String> _installLinux(File file) async {
  final current = Platform.environment['APPIMAGE'];
  final writable = current != null && (await Process.run('test', ['-w', File(current).parent.path])).exitCode == 0;
  final refusal = linuxInstallRefusal(current, writable: writable);
  if (refusal != null) {
    await showInFileManager(file.path);
    return '$refusal, so it cannot update itself. The new version is downloaded: put ${file.uri.pathSegments.last} in its '
        'place, quit this app, and open the new one.';
  }
  final target = File(current!);
  final staged = File('${target.parent.path}/.${file.uri.pathSegments.last}.new');
  await file.copy(staged.path);
  final chmod = await Process.run('chmod', ['755', staged.path]);
  if (chmod.exitCode != 0) {
    await staged.delete();
    return 'Could not make the new version runnable: ${'${chmod.stderr}'.trim()}';
  }
  await staged.rename(target.path);
  await Process.start(target.path, const [], mode: ProcessStartMode.detached);
  quitForUpdate();
  return 'Installing'; // not reached once the app has quit
}

Future<String> _byHand(File dmg, String why) async {
  await showInFileManager(dmg.path);
  return '$why, so it cannot update itself. The new version is downloaded: open ${dmg.uri.pathSegments.last}, quit this '
      'app, and drag the new app over the old one.';
}

class _MacInstallError implements Exception {
  final String message;
  _MacInstallError(this.message);
}

/// copies the app out of [dmg] to a hidden bundle beside [app] (the same disk, so the swap is a rename) and checks the
/// copy will run here: its server and ffmpeg are this Mac's arch (the app's own binary is universal, so it says
/// nothing), and its signature is whole. Returns the copy's path, and the name of the app in the disk image.
Future<(String, String)> _stageMacApp(File dmg, String app, String arch) async {
  Future<void> run(String what, String exe, List<String> args) async {
    final r = await Process.run(exe, args);
    if (r.exitCode != 0) throw _MacInstallError('$what failed: ${'${r.stderr}'.trim()}');
  }

  final staged = '${File(app).parent.path}/.${app.split('/').last.replaceFirst(RegExp(r'\.app$'), '')}-update.app';
  final mount = await Directory.systemTemp.createTemp('OPRivViewReplay-mount');
  late String name;
  try {
    await run('Opening the disk image', '/usr/bin/hdiutil',
        ['attach', '-nobrowse', '-readonly', '-noautoopen', '-mountpoint', mount.path, dmg.path]);
    try {
      final inside = Directory(mount.path).listSync().whereType<Directory>().where((d) => d.path.endsWith('.app')).toList();
      if (inside.length != 1) throw _MacInstallError('The disk image does not hold one app');
      name = inside.single.path.split('/').last;
      if (await Directory(staged).exists()) await Directory(staged).delete(recursive: true);
      await run('Copying the new app', '/usr/bin/ditto', [inside.single.path, staged]);
    } finally {
      final r = await Process.run('/usr/bin/hdiutil', ['detach', mount.path]);
      if (r.exitCode != 0) await Process.run('/usr/bin/hdiutil', ['detach', '-force', mount.path]);
    }
  } finally {
    if (await mount.exists()) await mount.delete();
  }
  try {
    final res = '$staged/Contents/Resources';
    for (final b in ['ffmpeg/ffmpeg', 'ffmpeg/ffprobe', 'oprivview-replay-server/oprivview-replay-server']) {
      await run('Checking the new app is for this Mac', '/usr/bin/lipo', ['$res/$b', '-verify_arch', arch]);
    }
    await run('Checking the new app is whole', '/usr/bin/codesign', ['--verify', '--deep', '--strict', staged]);
    // a disk image copied from one marked as downloaded marks the app too, and macOS would then stop it with a dialog;
    // the download has already been checked against the release's SHA-256
    await Process.run('/usr/bin/xattr', ['-dr', 'com.apple.quarantine', staged]);
  } catch (_) {
    await Directory(staged).delete(recursive: true);
    rethrow;
  }
  return (staged, name);
}

/// run detached, after the app has quit: puts the new bundle in the old one's place and opens it. The old bundle is kept
/// aside until the new one is seen running, and put back (and opened) if anything goes wrong.
/// Arguments: the installed app, the checked copy beside it, a log file, and where the new app goes (the installed app's
/// place unless the app has been renamed; an older app's updater leaves it out).
const macSwapScript = r'''
app=$1 new=$2 target=${4:-$1}
exec >>"$3" 2>&1
echo "$(date): replacing $app with $target"
old="$(dirname "$app")/.$(basename "$app" .app)-old.app"
running() { pgrep -f -- "$1/Contents/" >/dev/null; }
# the app, its server and any ffmpeg all run from inside the bundle; give them half a minute to go
for i in $(seq 60); do running "$app" || break; sleep 0.5; done
running "$app" && echo "still running after 30 s; replacing anyway (a running program is not harmed by its folder moving)"
# something else already has the new name: keep the old one rather than touch it
if [ "$target" != "$app" ] && [ -e "$target" ]; then echo "$target is already there; keeping the name $app"; target=$app; fi
rm -rf "$old"
if ! mv "$app" "$old"; then echo "could not move the old app aside"; rm -rf "$new"; open "$app"; exit 1; fi
if ! mv "$new" "$target"; then echo "could not move the new app in"; mv "$old" "$app"; open "$app"; exit 1; fi
open "$target"
# seen running, and still running 5 s later: a new app that fails at once is caught even if it was glimpsed starting
for i in $(seq 20); do running "$target" && break; sleep 0.5; done
sleep 5
if running "$target"; then
  rm -rf "$old"
  echo "the new app is running"
else
  echo "the new app did not start; putting the old one back"
  rm -rf "$target"
  mv "$old" "$app"
  open "$app"
  exit 1
fi
''';
