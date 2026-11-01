import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opview/replay/raw_frames.dart';
import 'package:opview/replay/replay_job.dart';
import 'package:opview/services/app_settings.dart';

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

  group('ReplayJob settings', () {
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
}
