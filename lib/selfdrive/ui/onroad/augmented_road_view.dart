// augmented road view — the main onroad screen
// ported from openpilot selfdrive/ui/onroad/augmented_road_view.py
// video and overlay share one zoom + horizon offset, as on the device
//
// layer stack (matches stock render order):
//   0. RTCVideoView (zoomed and shifted by the frame transform)
//   1. ClipRect -> ModelRenderer + HudRenderer + AlertRenderer
//   2. EngagementBorder (on top of everything)

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:opview/common/transformations.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/selfdrive/ui/onroad/model_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/hud_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/alert_renderer.dart';

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

  const AugmentedRoadView({
    super.key,
    required this.uiState,
    this.videoRenderer,
    this.loadManualHost,
    this.onSetManualHost,
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

        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
          child: Stack(
            fit: StackFit.expand,
            children: [
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
                        HudRenderer(uiState: widget.uiState, scale: scale),
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
                        'opview $opviewBuild',
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
                    ],
                  ),
                ),
            ],
          ),
        );
      }),
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
