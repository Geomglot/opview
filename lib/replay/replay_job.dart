// one render, as written by the replay tool (replay/oprivview_replay/render.py)

import 'dart:convert';
import 'dart:io';

import 'package:opview/services/app_settings.dart';

class ReplayJob {
  final String clip;
  final String output;
  final String ffmpeg;
  final String encoder;
  final List<String> videoInputs;
  final int skipFrames;
  final int frameCount;
  final int videoWidth;
  final int videoHeight;
  final int width;
  final int height;
  final int fps;
  final String bitrate;
  final OnroadLayout view;
  final BottomBar? bottomBar;
  final List<String> collapsedPanels;
  final ClockMode clock;

  ReplayJob.fromJson(Map<String, dynamic> j)
      : clip = j['clip'] as String,
        output = j['output'] as String,
        ffmpeg = j['ffmpeg'] as String,
        encoder = j['encoder'] as String,
        videoInputs = (j['video_inputs'] as List).cast<String>(),
        skipFrames = j['skip_frames'] as int,
        frameCount = j['frame_count'] as int,
        videoWidth = j['video_width'] as int,
        videoHeight = j['video_height'] as int,
        width = j['width'] as int,
        height = j['height'] as int,
        fps = j['fps'] as int,
        bitrate = j['bitrate'] as String,
        view = OnroadLayout.values.byName(j['view'] as String),
        bottomBar = j['bottom_bar'] == null ? null : BottomBar.values.byName(j['bottom_bar'] as String),
        collapsedPanels = (j['collapsed_panels'] as List).cast<String>(),
        clock = ClockMode.values.byName(j['clock'] as String);

  static ReplayJob load(String path) =>
      ReplayJob.fromJson(jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>);

  /// settings for this render only: set directly, because the setters and load() touch saved preferences
  AppSettings settings() {
    final s = AppSettings()
      ..layout = view
      ..clockMode = clock;
    if (bottomBar != null) s.bottomBars[view] = bottomBar!;
    s.collapsedPanels.addAll(collapsedPanels);
    return s;
  }
}
