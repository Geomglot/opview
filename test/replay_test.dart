import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opview/replay/raw_frames.dart';
import 'package:opview/replay/replay_job.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/studio/preview_player.dart';
import 'package:opview/studio/version.dart';

Map<String, dynamic> job(Map<String, dynamic> over) => {
      'clip': 'c', 'output': 'o', 'ffmpeg': 'f', 'encoder': 'e', 'video_inputs': ['a'], 'skip_frames': 0, 'frame_count': 1,
      'video_width': 4, 'video_height': 2, 'width': 8, 'height': 4, 'fps': 20, 'bitrate': '8M', 'view': 'classic',
      'bottom_bar': null, 'collapsed_panels': <String>[], 'clock': 'h12', ...over,
    };

void main() {
  group('RawFrameReader', () {
    test('joins chunks that split a frame', () async {
      final r = RawFrameReader(Stream.fromIterable([[1, 2], [3, 4, 5], [6]]), 3);
      expect(await r.next(), Uint8List.fromList([1, 2, 3]));
      expect(await r.next(), Uint8List.fromList([4, 5, 6]));
      expect(await r.next(), isNull);
    });

    test('a part frame at the end of the video is no frame', () async {
      final r = RawFrameReader(Stream.fromIterable([[1, 2]]), 3);
      expect(await r.next(), isNull);
    });
  });

  test('a build with no release version reads the guides on the branch', () {
    // tests run without --dart-define=OPRIVVIEW_REPLAY_VERSION, like a bare `flutter run`
    expect(isReleaseBuild, isFalse);
    expect(guidesUrl, 'https://github.com/Geomglot/opview/blob/rivian-support/replay/docs');
  });

  group('ReplayJob settings', () {
    test('says which segment a frame is in and how far into it, also when the clip starts part-way in', () {
      // a clip from 15 s into segment 4 (frame 300 at 20 fps), running on into segment 5
      final j = ReplayJob.fromJson(job({'segment_starts': [[4, 0, 300], [5, 900, 0]]}));
      expect(j.segmentAt(0), 'segment 4, 0:15');
      expect(j.segmentAt(899), 'segment 4, 0:59');
      expect(j.segmentAt(900), 'segment 5, 0:00');
      expect(j.segmentAt(1110), 'segment 5, 0:10');
      expect(ReplayJob.fromJson(job({})).segmentAt(0), isNull); // a job file from before segments were listed
    });

    test('ffmpeg encodes as it always has on a Mac and Windows', () {
      expect(ReplayJob.fromJson(job({})).encodeArgs(), [
        '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', '8x4', '-r', '20', '-i', '-',
        '-c:v', 'e', '-b:v', '8M', '-pix_fmt', 'yuv420p', 'o',
      ]);
    });

    test("Linux's VA-API encoder gets its device and its frames uploaded to the graphics card", () {
      final args = ReplayJob.fromJson(job({'encoder': 'h264_vaapi', 'encoder_device': '/dev/dri/renderD128'})).encodeArgs();
      expect(args, [
        '-v', 'error', '-y', '-vaapi_device', '/dev/dri/renderD128', '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', '8x4',
        '-r', '20', '-i', '-', '-vf', 'format=nv12,hwupload', '-c:v', 'h264_vaapi', '-b:v', '8M', 'o',
      ]);
    });

    test('wide camera files are optional', () {
      expect(ReplayJob.fromJson(job({})).wideInputs, isNull);
      expect(ReplayJob.fromJson(job({'wide_inputs': ['w']})).wideInputs, ['w']);
    });

    test('the chosen view is used', () {
      expect(ReplayJob.fromJson(job({'view': 'detailed'})).settings().layout, OnroadLayout.detailed);
    });

    test("no bottom bar choice keeps the app's default for the view", () {
      final s = ReplayJob.fromJson(job({'view': 'enhanced'})).settings();
      expect(s.bottomBarFor(OnroadLayout.enhanced), defaultBottomBars[OnroadLayout.enhanced]);
    });

    test('bottom bar and folded panels come from the job', () {
      final s = ReplayJob.fromJson(job({'view': 'detailed', 'bottom_bar': 'laneCentering', 'collapsed_panels': ['lead'], 'clock': 'h24'})).settings();
      expect(s.bottomBarFor(OnroadLayout.detailed), BottomBar.laneCentering);
      expect(s.collapsedPanels, {'lead'});
      expect(s.clockMode, ClockMode.h24);
    });
  });

  group('changes made on the preview', () {
    test('reach the option form in its own terms', () {
      final s = AppSettings()
        ..layout = OnroadLayout.detailed
        ..clockMode = ClockMode.h24
        ..speedLimitDisplay = SpeedLimitDisplay.always
        ..showRoadName = false;
      s.bottomBars[OnroadLayout.detailed] = BottomBar.off;
      s.collapsedPanels.add('lead');
      expect(optionsFrom(s), {
        'view': 'detailed',
        'bottom_bar': 'off',
        'collapsed_panels': ['lead'],
        'clock': 'h24',
        'speed_limit': 'always',
        'road_name': 'hide',
      });
    });

    test('and the form\'s changes reach the preview, the other way', () {
      final s = AppSettings();
      var told = 0;
      s.addListener(() => told++);
      final options = {
        'view': 'detailed',
        'bottom_bar': 'off',
        'collapsed_panels': ['lead'],
        'clock': 'h24',
        'speed_limit': 'always',
        'road_name': 'hide',
        'resolution': '1080p', // not shown on the screen: left alone
      };
      expect(applyOptions(s, options), isTrue);
      expect(told, 1);
      expect(optionsFrom(s), {...options}..remove('resolution'));
      expect(applyOptions(s, options), isFalse, reason: 'nothing new, so the screen is not redrawn');
      expect(told, 1);
      applyOptions(s, {'bottom_bar': null});
      expect(s.bottomBarFor(OnroadLayout.detailed), BottomBar.torque, reason: 'App default is the view\'s own bar');
    });

    test('leave the app default as the app default', () {
      expect(optionsFrom(AppSettings())['bottom_bar'], isNull);
    });

    test('a speed limit and road name choice carries through to a render', () {
      final s = ReplayJob.fromJson(job({'speed_limit': 'off', 'road_name': 'hide'})).settings();
      expect(s.speedLimitDisplay, SpeedLimitDisplay.off);
      expect(s.showRoadName, isFalse);
    });
  });
}
