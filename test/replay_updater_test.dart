import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opview/studio/replay_updater.dart';

ReplayVersion v(String text) => ReplayVersion.parse(text)!;

Map<String, dynamic> release(String tag, List<String> files,
        {bool prerelease = false, bool draft = false, Map<String, String> digests = const {}}) =>
    {
      'tag_name': tag,
      'draft': draft,
      'prerelease': prerelease,
      'html_url': 'https://github.com/Geomglot/opview/releases/tag/$tag',
      'body': 'notes for $tag',
      'assets': [
        for (final f in files)
          {'name': f, 'browser_download_url': 'https://example.test/$tag/$f', 'size': 4, if (digests[f] != null) 'digest': 'sha256:${digests[f]}'},
      ],
    };

void main() {
  group('versions', () {
    test('tests come before the version they lead to, and numbers compare as numbers', () {
      expect(v('0.1.2-test.2') > v('0.1.2-test.1'), isTrue);
      expect(v('0.1.2') > v('0.1.2-test.9'), isTrue);
      expect(v('0.1.2-test.10') > v('0.1.2-test.2'), isTrue);
      expect(v('0.1.10') > v('0.1.2'), isTrue);
      expect(v('0.2.0-test.1') > v('0.1.9'), isTrue);
      expect(v('0.1.2').compareTo(v('0.1.2')), 0);
    });

    test('local builds and the old one-platform tags are not versions', () {
      expect(ReplayVersion.parse('0.1.2-dev'), isNull);
      expect(ReplayVersion.parse(''), isNull);
      expect(ReplayVersion.parse('0.1.1-windows-test.1'), isNull);
      expect(ReplayUpdater(installed: '0.1.2-dev').enabled, isFalse);
      expect(ReplayUpdater(installed: '0.1.2-test.1').enabled, isTrue);
    });
  });

  group('choosing a release', () {
    final list = [
      release('v0.1.2-rivian.9', ['OPRivView-0.1.2-rivian.9.apk'], prerelease: true), // the Android app's
      release('replay-v0.1.3-test.1', ['OPRivView-Replay-0.1.3-test.1-Windows.exe'], draft: true, prerelease: true),
      release('replay-v0.1.2-test.2', ['OPRivView-Replay-0.1.2-test.2-Windows.exe', 'OPRivView-Replay-0.1.2-test.2-macOS-ARM.dmg'],
          prerelease: true),
      release('replay-v0.1.2', ['OPRivView-Replay-0.1.2-Windows.exe', 'OPRivView-Replay-0.1.2-macOS-Intel.dmg']),
      release('replay-v0.1.1-windows-test.1', ['OPRivView-Replay-0.1.1-Windows.zip'], prerelease: true),
    ];

    test('the newest version with a file for this computer; drafts and the Android app are left out', () {
      expect(newestReplayRelease(list, suffix: '-Windows.exe', includeTests: true)!.version.toString(), '0.1.2');
      expect(newestReplayRelease(list, suffix: '-macOS-ARM.dmg', includeTests: true)!.version.toString(), '0.1.2-test.2');
      expect(newestReplayRelease(list, suffix: '-macOS-Intel.dmg', includeTests: true)!.fileName,
          'OPRivView-Replay-0.1.2-macOS-Intel.dmg');
    });

    test('test versions only when asked for', () {
      expect(newestReplayRelease(list, suffix: '-macOS-ARM.dmg', includeTests: false), isNull);
      expect(newestReplayRelease(list, suffix: '-Windows.exe', includeTests: false)!.version.toString(), '0.1.2');
    });

    test('release notes lose their Markdown marks', () {
      expect(plainNotes("## What's new\n\n- **Bold** and [a link](https://x.test) and `code`\n"),
          "What's new\n\n- Bold and a link and code");
    });

    test("a SHA256SUMS line gives a file's checksum", () {
      final sums = '${'a' * 64}  OPRivView-Replay-0.1.2-Windows.exe\n${'B' * 64}  OPRivView-Replay-0.1.2-macOS-ARM.dmg\n';
      expect(sha256From(sums, 'OPRivView-Replay-0.1.2-macOS-ARM.dmg'), 'b' * 64);
      expect(sha256From(sums, 'other'), isNull);
    });
  });

  group('updating', () {
    final bytes = utf8.encode('new!');
    final good = sha256.convert(bytes).toString();
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('replay-update-test'));
    tearDown(() => dir.deleteSync(recursive: true));

    ReplayUpdater updater(List<Map<String, dynamic>> releases, {required List<String> got, List<String>? installed}) => ReplayUpdater(
          installed: '0.1.2-test.1',
          suffix: () async => '-Windows.exe',
          downloads: () async => dir,
          install: (file) async {
            installed?.add(file.path);
            return 'installed';
          },
          client: () => MockClient((req) async {
            got.add(req.url.toString());
            if (req.url.host == 'api.github.com') return http.Response(jsonEncode(releases), 200);
            return http.Response.bytes(bytes, 200, headers: {'content-length': '${bytes.length}'});
          }),
        );

    test('a newer release is offered, downloaded, checked and installed; a second Update reuses the download', () async {
      final got = <String>[], installed = <String>[];
      final u = updater([release('replay-v0.1.2-test.2', ['OPRivView-Replay-0.1.2-test.2-Windows.exe'], prerelease: true,
          digests: {'OPRivView-Replay-0.1.2-test.2-Windows.exe': good})], got: got, installed: installed);
      await u.check(includeTests: true);
      expect(u.status, ReplayUpdateStatus.available);
      await u.downloadAndInstall();
      expect(installed.single, endsWith('OPRivView-Replay-0.1.2-test.2-Windows.exe'));
      expect(u.message, 'installed');
      await u.downloadAndInstall();
      expect(got.where((url) => url.endsWith('.exe')), hasLength(1), reason: 'the saved download matched');
    });

    test('nothing newer, nothing offered', () async {
      final u = updater([release('replay-v0.1.2-test.1', ['OPRivView-Replay-0.1.2-test.1-Windows.exe'], prerelease: true)], got: []);
      await u.check(includeTests: true);
      expect(u.status, ReplayUpdateStatus.upToDate);
    });

    test('a download that does not match its checksum is thrown away and not installed', () async {
      final installed = <String>[];
      final u = updater([release('replay-v0.1.2', ['OPRivView-Replay-0.1.2-Windows.exe'], digests: {'OPRivView-Replay-0.1.2-Windows.exe': 'f' * 64})],
          got: [], installed: installed);
      await u.check(includeTests: false);
      await u.downloadAndInstall();
      expect(u.status, ReplayUpdateStatus.failed);
      expect(installed, isEmpty);
      expect(dir.listSync(), isEmpty);
    });

    test('without a digest the checksum comes from SHA256SUMS, and with neither nothing is downloaded', () async {
      final got = <String>[];
      final r = release('replay-v0.1.2', ['OPRivView-Replay-0.1.2-Windows.exe', 'SHA256SUMS']);
      final u = ReplayUpdater(
        installed: '0.1.2-test.1',
        suffix: () async => '-Windows.exe',
        downloads: () async => dir,
        install: (file) async => 'installed',
        client: () => MockClient((req) async {
          got.add(req.url.toString());
          if (req.url.host == 'api.github.com') return http.Response(jsonEncode([r]), 200);
          if (req.url.path.endsWith('SHA256SUMS')) return http.Response('$good  OPRivView-Replay-0.1.2-Windows.exe\n', 200);
          return http.Response.bytes(bytes, 200);
        }),
      );
      await u.check(includeTests: false);
      await u.downloadAndInstall();
      expect(u.message, 'installed');

      final bare = updater([release('replay-v0.1.2', ['OPRivView-Replay-0.1.2-Windows.exe'])], got: got..clear());
      await bare.check(includeTests: false);
      await bare.downloadAndInstall();
      expect(bare.status, ReplayUpdateStatus.failed);
      expect(got.where((url) => url.endsWith('.exe')), isEmpty);
    });
  });

  group('Mac install', () {
    test('an app in Applications, or any folder the user can change, replaces itself', () {
      expect(macInstallRefusal('/Applications/OPRivView Replay.app', writable: true), isNull);
      expect(macInstallRefusal('/Users/me/Apps/OPRivView Replay.app', writable: true), isNull);
    });

    test('an app on the disk image, moved by macOS to a temporary place, or in a folder it cannot change, does not', () {
      expect(macInstallRefusal('/Volumes/OPRivView Replay/OPRivView Replay.app', writable: true), contains('disk image'));
      expect(macInstallRefusal('/private/var/folders/x/T/AppTranslocation/ABC/d/OPRivView Replay.app', writable: true),
          contains('temporary place'));
      expect(macInstallRefusal('/Applications/OPRivView Replay.app', writable: false), contains('cannot change'));
      expect(macInstallRefusal('/usr/local/bin', writable: true), isNotNull);
    });
  });
}
