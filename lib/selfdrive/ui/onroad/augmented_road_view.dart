// augmented road view — the main onroad screen
// ported from openpilot selfdrive/ui/onroad/augmented_road_view.py
// video and overlay share one zoom + horizon offset, as on the device
//
// layer stack (matches stock render order):
//   0. RTCVideoView (zoomed and shifted by the frame transform)
//   1. ClipRect -> ModelRenderer + HudRenderer + AlertRenderer
//   2. EngagementBorder (on top of everything)

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:opview/common/transformations.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/selfdrive/ui/onroad/model_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/hud_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/alert_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/clock_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/detailed/detailed_layout.dart';
import 'package:opview/selfdrive/ui/onroad/enhanced/enhanced_layout.dart';
import 'package:opview/selfdrive/ui/settings/settings_dialog.dart';
import 'package:opview/services/app_settings.dart';

// which build this is, shown on the Connecting screen; set at build time with
// flutter build apk --dart-define=OPVIEW_BUILD=0.1.1-comma3x.N
const opviewBuild = String.fromEnvironment('OPVIEW_BUILD', defaultValue: 'dev build');

// -- border colors (augmented_road_view.py:23-27) --

const borderColors = {
  UIStatus.disengaged: Color(0xFF122839),
  UIStatus.override_: Color(0xFF89928D),
  UIStatus.engaged: Color(0xFF167F40),
  // sunnypilot MADS (sunnypilot/onroad/augmented_road_view.py BORDER_COLORS_SP)
  UIStatus.latOnly: Color(0xFF00C8C8),   // cyan: steering only
  UIStatus.longOnly: Color(0xFF961CA8),  // purple: cruise only
};

class AugmentedRoadView extends StatefulWidget {
  final UIState uiState;
  final RTCVideoRenderer? videoRenderer;

  // manual device IP, for networks where mDNS discovery does not work
  final Future<String?> Function()? loadManualHost;
  final Future<void> Function(String? host)? onSetManualHost;

  // viewer-side settings (clock, ...); null = everything at its default
  final AppSettings? settings;

  // address of the comma in use, for the settings menu
  final String? Function()? currentHost;

  const AugmentedRoadView({
    super.key,
    required this.uiState,
    this.videoRenderer,
    this.loadManualHost,
    this.onSetManualHost,
    this.settings,
    this.currentHost,
  });

  @override
  State<AugmentedRoadView> createState() => _AugmentedRoadViewState();
}

class _AugmentedRoadViewState extends State<AugmentedRoadView> {
  // cached transform inputs — only recompute when these change
  List<double> _cachedRpyCalib = [];
  List<double> _cachedWideFromDeviceEuler = [];
  String _cachedCalStatus = '';
  String _cachedDeviceType = '';
  String _cachedSensor = '';
  String _cachedStreamType = '';
  double _cachedScreenW = 0;
  double _cachedScreenH = 0;
  FrameTransform? _cachedTransform;

  // swipe between layouts: where the finger went down, and the name pill shown afterwards
  double? _swipeStartX;
  double _swipeDx = 0;
  bool _pillShown = false;
  Timer? _pillTimer;

  @override
  void dispose() {
    _pillTimer?.cancel();
    super.dispose();
  }

  /// a finished horizontal swipe: left for the next layout, right for the previous; no wrap.
  /// The name pill shows either way, so a swipe at the end still gets an answer
  void _onSwipeEnd(DragEndDetails details, double screenW, AppSettings settings) {
    final start = _swipeStartX;
    _swipeStartX = null;
    if (start == null) return;
    final v = details.primaryVelocity ?? 0;
    final far = _swipeDx.abs() >= screenW * layoutSwipeMinFraction;
    final flung = _swipeDx.abs() >= screenW * layoutSwipeFlingFraction && v.abs() >= layoutSwipeFlingVelocity;
    if (!far && !flung) return;
    final next = layoutAfterSwipe(settings.layout, towardsNext: _swipeDx < 0);
    if (next != settings.layout) settings.setLayout(next);
    _pillTimer?.cancel();
    setState(() => _pillShown = true);
    _pillTimer = Timer(layoutPillDuration, () {
      if (mounted) setState(() => _pillShown = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(builder: (context, constraints) {
        final screenW = constraints.maxWidth;
        final screenH = constraints.maxHeight;
        final scale = screenH / 1080.0;
        final borderSize = uiBorderSize * scale;

        // recompute transform only when inputs change
        final frame = _getTransform(screenW, screenH);

        // content rect (inside border)
        final contentRect = Rect.fromLTWH(
          borderSize, borderSize,
          screenW - 2 * borderSize, screenH - 2 * borderSize,
        );

        final settings = widget.settings;
        final clockMode = settings?.clockMode ?? ClockMode.h12;
        final speedLimitDisplay = settings?.speedLimitDisplay ?? SpeedLimitDisplay.auto;
        final layout = settings?.layout ?? OnroadLayout.classic;
        // read by every layout through UIState.showRoadName
        widget.uiState.roadNameEnabled = settings?.showRoadName ?? true;

        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
          // long press anywhere opens the settings
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: settings == null ? null : () => _openSettings(context, settings),
            // a sideways swipe changes the layout; one starting at a screen edge is left to Android.
            // .down: the start position is where the finger went down, not where the drag was
            // recognised (a little further along), so the edge test sees the real starting point
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: settings == null || !widget.uiState.isConnected
                ? null
                : (d) {
                    final x = d.localPosition.dx;
                    final nearEdge = x < layoutSwipeEdge || x > screenW - layoutSwipeEdge;
                    _swipeStartX = nearEdge ? null : x;
                    _swipeDx = 0;
                  },
            onHorizontalDragUpdate: settings == null || !widget.uiState.isConnected
                ? null
                : (d) => _swipeDx += d.primaryDelta ?? 0,
            onHorizontalDragEnd: settings == null || !widget.uiState.isConnected
                ? null
                : (d) => _onSwipeEnd(d, screenW, settings),
            child: Stack(
            fit: StackFit.expand,
            children: [
              if (layout == OnroadLayout.detailed)
                DetailedLayout(
                  uiState: widget.uiState,
                  clockMode: clockMode,
                  speedLimitDisplay: speedLimitDisplay,
                  collapsedPanels: settings?.collapsedPanels ?? const <String>{},
                  onTogglePanel: settings?.togglePanel,
                  frameFor: _fullScreenFrame,
                  videoBuilder: _videoLayer,
                )
              else if (layout == OnroadLayout.enhanced)
                EnhancedLayout(
                  uiState: widget.uiState,
                  clockMode: clockMode,
                  speedLimitDisplay: speedLimitDisplay,
                  frameFor: _fullScreenFrame,
                  videoBuilder: _videoLayer,
                )
              else ...[
              // layer 0 + 1a: video + model overlay
              _videoLayer(frame),
              ClipRect(
                clipper: _ContentClipper(contentRect),
                child: CustomPaint(
                  size: Size(screenW, screenH),
                  painter: ModelRendererPainter(
                    state: widget.uiState,
                    carSpaceTransform: frame.carToScreen,
                    contentRect: contentRect,
                  ),
                ),
              ),

              // layer 1b: HUD + alerts — always visible
              // RepaintBoundary isolates widget rebuilds from the video/model layer
              Padding(
                padding: EdgeInsets.all(borderSize),
                child: RepaintBoundary(
                  child: ClipRect(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        HudRenderer(uiState: widget.uiState, scale: scale, speedLimitDisplay: speedLimitDisplay),
                        if (clockMode != ClockMode.off) ClockRenderer(mode: clockMode, scale: scale),
                        AlertRenderer(uiState: widget.uiState, scale: scale),
                      ],
                    ),
                  ),
                ),
              ),

              // layer 2: engagement border — always visible
              CustomPaint(
                size: Size(screenW, screenH),
                painter: _EngagementBorderPainter(
                  status: widget.uiState.status,
                  borderSize: borderSize,
                ),
              ),
              ],

              // connected, but the telemetry has stopped: the overlay is old until it
              // comes back or the session is rebuilt (connection_manager.dart)
              if (widget.uiState.isConnected && widget.uiState.dataStale)
                Positioned(
                  top: screenH * 0.36,
                  left: 0,
                  right: 0,
                  child: Center(child: DataPausedTag(scale: scale)),
                ),

              // the layout's name for a moment after a swipe
              if (settings != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Center(
                      child: AnimatedOpacity(
                        opacity: _pillShown ? 1 : 0,
                        duration: const Duration(milliseconds: 220),
                        child: LayoutSwitchPill(layout: layout, unit: enhancedUnit(Size(screenW, screenH))),
                      ),
                    ),
                  ),
                ),

              // layer 3: connecting overlay with rolling status log
              if (!widget.uiState.isConnected)
                Container(
                  color: const Color(0xCC000000),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Connecting…',
                        style: TextStyle(
                          color: const Color(0x99FFFFFF),
                          fontSize: 40 * scale,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                      Text(
                        'OPRivView $opviewBuild',
                        style: TextStyle(color: const Color(0x66FFFFFF), fontSize: 18 * scale),
                      ),
                      SizedBox(height: 20 * scale),
                      ...widget.uiState.connectionLog.map((line) => Text(
                        line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: const Color(0x66FFFFFF),
                          fontSize: 16 * scale,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w300,
                        ),
                      )),
                      if (widget.onSetManualHost != null) ...[
                        SizedBox(height: 20 * scale),
                        TextButton(
                          onPressed: () => _showManualHostDialog(context),
                          child: Text(
                            'Set device IP',
                            style: TextStyle(color: const Color(0x99FFFFFF), fontSize: 20 * scale),
                          ),
                        ),
                      ],
                      if (settings != null)
                        TextButton(
                          onPressed: () => _openSettings(context, settings),
                          child: Text(
                            'Settings',
                            style: TextStyle(color: const Color(0x99FFFFFF), fontSize: 20 * scale),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
            ),
          ),
        );
      }),
    );
  }

  /// the settings menu, with the comma's address and a way to change it
  Future<void> _openSettings(BuildContext context, AppSettings settings) async {
    final manualHost = await widget.loadManualHost?.call();
    if (!context.mounted) return;
    await showSettingsDialog(
      context,
      settings,
      host: widget.currentHost?.call(),
      hostIsManual: manualHost != null,
      onChangeHost: widget.onSetManualHost == null ? null : () => _showManualHostDialog(context),
      build: opviewBuild,
    );
  }

  /// ask for the device IP; empty clears it and goes back to auto-discovery
  Future<void> _showManualHostDialog(BuildContext context) async {
    final current = await widget.loadManualHost?.call() ?? '';
    if (!context.mounted) return;
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Device IP'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'e.g. 192.168.1.50 (empty = auto)'),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (result != null) await widget.onSetManualHost!(result);
  }

  /// video layer: the camera image zoomed and shifted exactly as the overlay is,
  /// or black placeholder
  Widget _videoLayer(FrameTransform frame) {
    if (widget.videoRenderer == null) {
      return Container(color: Colors.black);
    }
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned(
          left: frame.videoLeft,
          top: frame.videoTop,
          width: frame.videoWidth,
          height: frame.videoHeight,
          // the stream is the whole camera frame scaled down (1152x720 for 1928x1208),
          // so cover only trims a fraction of a percent
          child: RTCVideoView(
            widget.videoRenderer!,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
          ),
        ),
      ],
    );
  }

  /// return cached transform, recompute only when inputs changed
  FrameTransform _getTransform(double screenW, double screenH) {
    final st = widget.uiState;
    if (screenW == _cachedScreenW &&
        screenH == _cachedScreenH &&
        st.calStatus == _cachedCalStatus &&
        st.deviceType == _cachedDeviceType &&
        st.sensor == _cachedSensor &&
        st.streamType == _cachedStreamType &&
        listEquals(st.rpyCalib, _cachedRpyCalib) &&
        listEquals(st.wideFromDeviceEuler, _cachedWideFromDeviceEuler) &&
        _cachedTransform != null) {
      return _cachedTransform!;
    }

    _cachedScreenW = screenW;
    _cachedScreenH = screenH;
    _cachedCalStatus = st.calStatus;
    _cachedDeviceType = st.deviceType;
    _cachedSensor = st.sensor;
    _cachedStreamType = st.streamType;
    _cachedRpyCalib = List.of(st.rpyCalib);
    _cachedWideFromDeviceEuler = List.of(st.wideFromDeviceEuler);
    return _cachedTransform = _calcFrameMatrix(screenW, screenH);
  }

  /// video placement and 3D->2D projection, one transform for both
  /// ported from augmented_road_view.py _calc_frame_matrix
  FrameTransform _calcFrameMatrix(double screenW, double screenH) {
    final isWideCamera = widget.uiState.streamType == 'wideRoad';
    final deviceCamera = _lookupCamera();
    final scale = screenH / 1080.0;
    final border = uiBorderSize * scale;
    return calcFrameTransform(
      camera: isWideCamera ? deviceCamera.ecam : deviceCamera.fcam,
      calibration: isWideCamera ? _computeWideViewFromCalib() : _computeViewFromCalib(),
      deviceZoom: isWideCamera ? 2.0 : 1.1,
      scale: scale,
      x: border,
      y: border,
      w: screenW - 2 * border,
      h: screenH - 2 * border,
    );
  }

  /// the Classic framing (zoom 1.1 road, 2.0 wide on a 1080 px tall screen) over the
  /// whole screen with no border inset, for layouts that draw their own border
  FrameTransform _fullScreenFrame(double w, double h) {
    final isWideCamera = widget.uiState.streamType == 'wideRoad';
    final deviceCamera = _lookupCamera();
    return calcFrameTransform(
      camera: isWideCamera ? deviceCamera.ecam : deviceCamera.fcam,
      calibration: isWideCamera ? _computeWideViewFromCalib() : _computeViewFromCalib(),
      deviceZoom: isWideCamera ? 2.0 : 1.1,
      scale: h / 1080.0,
      x: 0,
      y: 0,
      w: w,
      h: h,
    );
  }

  /// look up camera by device type + sensor, fallback to default
  DeviceCameraConfig _lookupCamera() {
    final st = widget.uiState;
    if (st.deviceType.isNotEmpty && st.sensor.isNotEmpty) {
      return deviceCameras[(st.deviceType, st.sensor)] ?? defaultDeviceCamera;
    }
    return defaultDeviceCamera;
  }

  /// road camera: view_from_calib = VIEW_FRAME_FROM_DEVICE_FRAME @ device_from_calib
  List<List<double>> _computeViewFromCalib() {
    final st = widget.uiState;
    if (st.rpyCalib.length != 3 || st.calStatus != 'calibrated') {
      return viewFrameFromDeviceFrame;
    }
    final deviceFromCalib = rotFromEuler(st.rpyCalib);
    return matmul3x3(viewFrameFromDeviceFrame, deviceFromCalib);
  }

  /// wide camera: view_from_wide_calib = VIEW_FRAME_FROM_DEVICE_FRAME @ wide_from_device @ device_from_calib
  /// (augmented_road_view.py:157-159)
  List<List<double>> _computeWideViewFromCalib() {
    final st = widget.uiState;
    if (st.rpyCalib.length != 3 || st.calStatus != 'calibrated') {
      return viewFrameFromDeviceFrame;
    }
    final deviceFromCalib = rotFromEuler(st.rpyCalib);
    if (st.wideFromDeviceEuler.length == 3) {
      final wideFromDevice = rotFromEuler(st.wideFromDeviceEuler);
      return matmul3x3(viewFrameFromDeviceFrame, matmul3x3(wideFromDevice, deviceFromCalib));
    }
    // fallback: same as road calibration
    return matmul3x3(viewFrameFromDeviceFrame, deviceFromCalib);
  }
}

// -- content area clipper (replaces scissor mode from stock) --

class _ContentClipper extends CustomClipper<Rect> {
  final Rect contentRect;
  _ContentClipper(this.contentRect);

  @override
  Rect getClip(Size size) => contentRect;

  @override
  bool shouldReclip(_ContentClipper oldClipper) => oldClipper.contentRect != contentRect;
}

// -- engagement border painter --

class _EngagementBorderPainter extends CustomPainter {
  final UIStatus status;
  final double borderSize;

  _EngagementBorderPainter({required this.status, required this.borderSize});

  @override
  void paint(Canvas canvas, Size size) {
    // outer black border
    final outerRect = Offset.zero & size;
    canvas.drawRect(outerRect, Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderSize);

    // inner colored rounded rect
    final innerRect = Rect.fromLTWH(
      borderSize / 2, borderSize / 2,
      size.width - borderSize, size.height - borderSize,
    );
    final borderColor = borderColors[status] ?? borderColors[UIStatus.disengaged]!;
    final rrect = RRect.fromRectAndRadius(innerRect, Radius.circular(borderSize * 1.2));
    canvas.drawRRect(rrect, Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderSize);
  }

  @override
  bool shouldRepaint(_EngagementBorderPainter old) =>
    old.status != status || old.borderSize != borderSize;
}

/// small tag over the road while the telemetry is paused
class DataPausedTag extends StatelessWidget {
  final double scale;

  const DataPausedTag({super.key, required this.scale});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        key: const ValueKey('dataPausedTag'),
        padding: EdgeInsets.symmetric(horizontal: 26 * scale, vertical: 14 * scale),
        decoration: BoxDecoration(
          color: const Color(0xD9141414),
          borderRadius: BorderRadius.circular(40 * scale),
          border: Border.all(color: const Color(0x80FF9A3C), width: 2 * scale),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 16 * scale,
              height: 16 * scale,
              decoration: const BoxDecoration(color: Color(0xFFFF9A3C), shape: BoxShape.circle),
            ),
            SizedBox(width: 14 * scale),
            Text(
              'Data paused \u00B7 reconnecting',
              style: TextStyle(color: Colors.white, fontSize: 30 * scale, fontWeight: FontWeight.w600, height: 1.0),
            ),
          ],
        ),
      ),
    );
  }
}

// -- swipe between layouts --

/// a swipe this share of the screen width changes the layout...
const layoutSwipeMinFraction = 0.25;

/// ...or a quick flick of at least this share, at this speed (logical px/s)
const layoutSwipeFlingFraction = 0.1;
const layoutSwipeFlingVelocity = 900.0;

/// swipes starting this close to the left or right edge are Android's (back gesture)
const layoutSwipeEdge = 28.0;

/// how long the layout's name stays up
const layoutPillDuration = Duration(milliseconds: 1100);

/// the layout a swipe leads to: Classic, Enhanced, Detailed in order, stopping at the ends
OnroadLayout layoutAfterSwipe(OnroadLayout current, {required bool towardsNext}) {
  const order = OnroadLayout.values;
  final i = order.indexOf(current) + (towardsNext ? 1 : -1);
  return order[i.clamp(0, order.length - 1)];
}

/// the layout's name with arrows for the ways it can still go and a dot for each layout
class LayoutSwitchPill extends StatelessWidget {
  final OnroadLayout layout;
  final double unit;  // comma four pixels

  const LayoutSwitchPill({super.key, required this.layout, required this.unit});

  @override
  Widget build(BuildContext context) {
    const order = OnroadLayout.values;
    final i = order.indexOf(layout);
    Widget arrow(String c, bool on) => Text(
          c,
          style: TextStyle(color: Colors.white.withValues(alpha: on ? 0.85 : 0.2), fontSize: 13 * unit, height: 1.0),
        );
    return Container(
      key: const ValueKey('layoutSwitchPill'),
      padding: EdgeInsets.fromLTRB(16 * unit, 9 * unit, 16 * unit, 8 * unit),
      decoration: BoxDecoration(
        color: const Color(0xE0101010),
        borderRadius: BorderRadius.circular(14 * unit),
        boxShadow: [BoxShadow(color: const Color(0x73000000), blurRadius: 20 * unit, offset: Offset(0, 4 * unit))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              arrow('\u2039', i > 0),
              SizedBox(width: 8 * unit),
              Text(
                onroadLayoutLabel(layout),
                style: TextStyle(color: Colors.white, fontSize: 15 * unit, fontWeight: FontWeight.bold, height: 1.0),
              ),
              SizedBox(width: 8 * unit),
              arrow('\u203A', i < order.length - 1),
            ],
          ),
          SizedBox(height: 6 * unit),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var d = 0; d < order.length; d++) ...[
                if (d > 0) SizedBox(width: 4 * unit),
                Container(
                  width: (d == i ? 14 : 5) * unit,
                  height: 5 * unit,
                  decoration: BoxDecoration(
                    color: d == i ? Colors.white : Colors.white.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(3 * unit),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
