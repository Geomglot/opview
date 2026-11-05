// one render, as written by the replay tool (replay/oprivview_replay/render.py)

import 'dart:convert';
import 'dart:io';

import 'package:opview/services/app_settings.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';

class ReplayJob {
  final String clip;
  final String output;
  final String ffmpeg;
  final String encoder;
  /// Linux's VA-API encoder only: the graphics device it encodes on, such as /dev/dri/renderD128
  final String? encoderDevice;
  final List<String> videoInputs;
  /// 'hevc' for the raw camera files, 'mpegts' for the small qcamera files
  final String videoFormat;
  /// the wide camera files for the same segments, or null when no frame uses the wide camera
  final List<String>? wideInputs;
  final int skipFrames;
  /// frames to drop from the start of the wide camera files; they can start at a different keyframe
  final int wideSkipFrames;
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
  final SpeedLimitDisplay speedLimit;
  final bool showRoadName;
  /// where in the clip to start reading, and how many frames there to read past without drawing: set when jumping
  final int clipOffset;
  final int framesBefore;
  /// lines to apply first, which a clip read from the middle would otherwise miss
  final List<String> firstLines;
  /// for each segment in the clip: its number, the clip frame it starts at, and the frame within the segment the clip
  /// starts at (only the first segment of a clip can start part-way in). Empty for job files from before it was added.
  final List<(int segment, int first, int skip)> segmentStarts;
  final Map<String, dynamic> _json;

  ReplayJob.fromJson(Map<String, dynamic> j)
      : _json = j,
        clipOffset = j['clip_offset'] as int? ?? 0,
        framesBefore = j['frames_before'] as int? ?? 0,
        firstLines = (j['first_lines'] as List?)?.cast<String>() ?? const [],
        segmentStarts = [
          for (final s in (j['segment_starts'] as List? ?? const []).cast<List>()) (s[0] as int, s[1] as int, s[2] as int)
        ],
        clip = j['clip'] as String,
        output = j['output'] as String,
        ffmpeg = j['ffmpeg'] as String,
        encoder = j['encoder'] as String,
        encoderDevice = j['encoder_device'] as String?,
        videoInputs = (j['video_inputs'] as List).cast<String>(),
        videoFormat = j['video_format'] as String? ?? 'hevc',
        wideInputs = (j['wide_inputs'] as List?)?.cast<String>(),
        skipFrames = j['skip_frames'] as int,
        wideSkipFrames = (j['wide_skip_frames'] ?? j['skip_frames']) as int,
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
        clock = ClockMode.values.byName(j['clock'] as String),
        speedLimit = SpeedLimitDisplay.values.byName(j['speed_limit'] as String? ?? 'auto'),
        showRoadName = (j['road_name'] as String? ?? 'show') == 'show';

  /// where [frame] of the clip is in the drive, e.g. "segment 4, 0:15"; null when the job does not say
  String? segmentAt(int frame) {
    if (segmentStarts.isEmpty) return null;
    final (segment, first, skip) = segmentStarts.lastWhere((s) => s.$2 <= frame, orElse: () => segmentStarts.first);
    final seconds = (skip + frame - first) ~/ fps;
    return 'segment $segment, ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  /// what ffmpeg is told to turn the renderer's RGBA frames, read from its standard input, into the MP4. VA-API takes its
  /// frames on the graphics card, so they are converted and uploaded there and it picks the pixel format itself.
  List<String> encodeArgs() {
    final device = encoderDevice;
    return [
      '-v', 'error', '-y', if (device != null) ...['-vaapi_device', device],
      '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', '${width}x$height', '-r', '$fps', '-i', '-',
      if (device != null) ...['-vf', 'format=nv12,hwupload'],
      '-c:v', encoder, '-b:v', bitrate, if (device == null) ...['-pix_fmt', 'yuv420p'], output,
    ];
  }

  /// this job with some of its fields replaced, as the server gives them for a jump
  ReplayJob withChanges(Map<String, dynamic> changes) => ReplayJob.fromJson({..._json, ...changes});

  static ReplayJob load(String path) =>
      ReplayJob.fromJson(jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>);

  /// settings for this render only: set directly, because the setters and load() touch saved preferences
  AppSettings settings() {
    final s = AppSettings()
      ..layout = view
      ..clockMode = clock
      ..speedLimitDisplay = speedLimit
      ..showRoadName = showRoadName;
    if (bottomBar != null) s.bottomBars[view] = bottomBar!;
    s.collapsedPanels.addAll(collapsedPanels);
    return s;
  }
}
