// Enhanced layout
//
// the camera fills the screen inside a rounded border in the engagement colour, and
// everything else is drawn over it in dark pills:
//   - top row, centred on the speed: set speed | speed | speed limit (top_row.dart)
//   - road name under the speed
//   - driver monitoring icon and model confidence, top left
//   - a small clock, top right
//   - steering readout, bottom left: angle or torque mode, target and actual angle
//   - lead car readout, bottom right: time gap, speed difference, the lead's speed
//   - torque bar, bottom centre
//   - a box around the lead car with its distance (drawn by the model renderer)
//   - a glow from the screen edge on a side whose blind spot is occupied
//   - alerts as a compact card above the torque bar; critical ones take the screen
//
// it began as a port of the comma four's own driving screen (openpilot
// selfdrive/ui/mici/onroad): the driver monitoring icon and the torque bar still
// follow that code, and sizes are in comma four pixels (its screen is 240 tall),
// scaled by `unit`. The camera framing and the path are the Classic ones.

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:opview/common/transformations.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/selfdrive/ui/onroad/clock_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/exp_button.dart';
import 'package:opview/selfdrive/ui/onroad/hud_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/model_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/throttled.dart';
import 'package:opview/selfdrive/ui/onroad/top_row.dart';
import 'package:opview/services/app_settings.dart';

// -- sizes, in comma four pixels --

const enhancedRefWidth = 536.0;
const enhancedRefHeight = 240.0;
const enhancedCornerRadius = 12.0;
const enhancedBorderWidth = 4.0;
const enhancedMargin = 16.0;          // gap between the border and the corner elements
const enhancedDriverIconSize = 48.6;  // also the confidence indicator
const enhancedClockWidth = 60.0;      // corner clock
const enhancedClockHeight = 16.0;
const enhancedSpeedPillHeight = 52.0;
const enhancedInfoPillWidth = 100.0;  // steering and lead readouts
const enhancedInfoPillHeight = 20.0;
const enhancedInfoPillGap = 4.0;
const enhancedGlowWidth = 70.0;

// path: a bit more solid than stock, drawn further out, and fading later
const enhancedPathOpacity = 1.35;
const enhancedPathDistance = 150.0;  // metres; stock 100
const enhancedPathFadeStop = 0.65;   // stock 0.5

// torque bar (mici torque_bar.py uses a span of 12.7; shortened to clear the readouts)
const _torqueAngleSpanDeg = 8.0;
const _torqueRadius = 1200.0;

// alert sizes and severities, as in cereal
const _alertSizeNone = 0;
const _alertSizeSmall = 1;
const _alertSizeFull = 3;
const _alertStatusUserPrompt = 1;
const _alertStatusCritical = 2;

// -- colours --

const _pillColor = Color(0xB3141414);
const _discColor = Color(0xE6101010);
const _labelColor = HudColors.grey;
const _blindSpotGlow = Color(0x8CFF9628);

/// border around the screen, by engagement state
Color enhancedBorderColor(UIStatus status) {
  switch (status) {
    case UIStatus.disengaged:
      return const Color(0xFF6E6E6E);  // grey
    case UIStatus.override_:
      return const Color(0xFFB4B4B4);
    case UIStatus.engaged:
      return const Color(0xFF17C653);  // green
    case UIStatus.latOnly:
      return const Color(0xFF4D9DFF);  // blue: steering only
    case UIStatus.longOnly:
      return const Color(0xFF961CA8);  // purple: cruise only
  }
}

/// cone on the driver monitoring icon: green while attention is full, orange once
/// it starts to run down (mici driver_state.py CONE_COLOR_*)
Color enhancedDriverConeColor({required bool awarenessFull}) {
  return awarenessFull ? const Color(0xFF00FF40) : const Color(0xFFFF7300);
}

/// the driver icon shows its cone (head direction, attention) only while openpilot is
/// engaged in some form and camera monitoring is running; otherwise it is an empty,
/// dimmed placeholder
bool enhancedDriverIconLive(UIState st) => st.status != UIStatus.disengaged && st.dmActive;

/// alert background: dark for a notice, orange when a response is needed, red when critical
Color enhancedAlertColor(int alertStatus, {required bool fullScreen}) {
  if (alertStatus == _alertStatusCritical) return const Color(0xF1C92231);
  if (alertStatus == _alertStatusUserPrompt) return const Color(0xF1DA6F25);
  return fullScreen ? const Color(0xF1151515) : const Color(0xE0141414);
}

/// critical alerts and full-size alerts cover the whole screen; the rest are a card
bool enhancedAlertIsFullScreen(int alertSize, int alertStatus) =>
    alertSize == _alertSizeFull || alertStatus == _alertStatusCritical;

// -- geometry --

/// comma four pixel size on a screen: its 536x240 display scaled to fit inside
double enhancedUnit(Size screen) => min(screen.height / enhancedRefHeight, screen.width / enhancedRefWidth);

// -- layout --

class EnhancedLayout extends StatelessWidget {
  final UIState uiState;
  final ClockMode clockMode;
  final SpeedLimitDisplay speedLimitDisplay;

  /// where the camera image goes and the matching overlay transform, for the whole
  /// screen; the same framing as the Classic layout
  final FrameTransform Function(double w, double h) frameFor;
  final Widget Function(FrameTransform frame) videoBuilder;

  const EnhancedLayout({
    super.key,
    required this.uiState,
    required this.clockMode,
    this.speedLimitDisplay = SpeedLimitDisplay.auto,
    required this.frameFor,
    required this.videoBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final st = uiState;
      final w = constraints.maxWidth, h = constraints.maxHeight;
      final unit = enhancedUnit(Size(w, h));
      final radius = BorderRadius.circular(enhancedCornerRadius * unit);
      final edge = (enhancedBorderWidth + enhancedMargin) * unit;  // screen edge to corner elements
      final frame = frameFor(w, h);

      // bottom of the road name pill: the lead's distance tag stays below it
      final hudBottom = edge + (enhancedSpeedPillHeight + roadNameGap + roadNamePillHeight) * unit;

      return ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // camera over the whole screen, with the path, lane lines and lead box
            videoBuilder(frame),
            CustomPaint(
              painter: ModelRendererPainter(
                state: st,
                carSpaceTransform: frame.carToScreen,
                contentRect: Rect.fromLTWH(0, 0, w, h),
                pathEdgeLines: true,
                leadReticle: true,
                leadTagMinTop: hudBottom + 4 * unit,
                showLeads: enhancedShowsLead(st.status),
                pathOpacity: enhancedPathOpacity,
                maxPathDistance: enhancedPathDistance,
                pathFadeStop: enhancedPathFadeStop,
              ),
            ),

            // fade out the bottom of the overlay, as the comma four does
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: h * 0.35,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0x99000000)],
                  ),
                ),
              ),
            ),

            // blind spot: glow from the edge on the occupied side, under everything else
            if (st.showBlindSpot && st.leftBlindspot)
              Positioned(
                key: const ValueKey('blindSpotLeft'),
                left: 0,
                top: 0,
                bottom: 0,
                width: enhancedGlowWidth * unit,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [_blindSpotGlow, Color(0x00FF9628)],
                    ),
                  ),
                ),
              ),
            if (st.showBlindSpot && st.rightBlindspot)
              Positioned(
                key: const ValueKey('blindSpotRight'),
                right: 0,
                top: 0,
                bottom: 0,
                width: enhancedGlowWidth * unit,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerRight,
                      end: Alignment.centerLeft,
                      colors: [_blindSpotGlow, Color(0x00FF9628)],
                    ),
                  ),
                ),
              ),

            CustomPaint(
              painter: EnhancedTorqueBarPainter(value: st.torqueBarValue, status: st.status, unit: unit),
            ),

            // top row: set speed | speed | speed limit, with the speed centred
            Positioned(
              top: edge,
              left: 0,
              right: 0,
              height: enhancedSpeedPillHeight * unit,
              child: SpeedTopRow(uiState: st, unit: unit, speedLimitDisplay: speedLimitDisplay),
            ),

            // road name under the speed
            if (st.showRoadName)
              Positioned(
                top: edge + (enhancedSpeedPillHeight + roadNameGap) * unit,
                left: 0,
                right: 0,
                child: Center(child: RoadNamePill(name: st.roadName, unit: unit, maxWidth: w * 0.5)),
              ),

            // driver monitoring and model confidence, top left
            ...enhancedDriverAndConfidence(st, unit, edge),

            // small clock, top right
            if (clockMode != ClockMode.off)
              Positioned(
                right: edge,
                top: edge,
                child: EnhancedCornerClock(unit: unit, clockMode: clockMode),
              ),

            // steering readout, bottom left
            Positioned(
              left: edge,
              bottom: edge,
              child: ThrottledByVersion(state: st, builder: (_) => EnhancedSteeringPills(uiState: st, unit: unit)),
            ),

            // lead car readout, bottom right
            Positioned(
              right: edge,
              bottom: edge,
              child: ThrottledByVersion(state: st, builder: (_) => EnhancedLeadPills(uiState: st, unit: unit)),
            ),

            EnhancedAlert(uiState: st, unit: unit),

            // border in the engagement colour, on top of everything
            // drawn on top but lets taps through to the panels underneath
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(color: enhancedBorderColor(st.status), width: enhancedBorderWidth * unit),
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}

// -- pills --

/// one line of a readout: small grey label on the left, value on the right. All of
/// them are the same width, so the values line up; a long value shrinks to fit
Widget _infoPill(double unit, String label, String value, Color valueColor) {
  return Container(
    width: enhancedInfoPillWidth * unit,
    height: enhancedInfoPillHeight * unit,
    padding: EdgeInsets.symmetric(horizontal: 8 * unit),
    decoration: BoxDecoration(
      color: _pillColor,
      borderRadius: BorderRadius.circular(7 * unit),
    ),
    child: Row(
      children: [
        Text(
          label,
          style: TextStyle(color: _labelColor, fontSize: 8.5 * unit, fontWeight: FontWeight.w600, height: 1.0),
        ),
        SizedBox(width: 4 * unit),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              value,
              style: TextStyle(
                color: valueColor,
                fontSize: 12 * unit,
                fontWeight: FontWeight.bold,
                height: 1.0,
                // digits of equal width, so values do not jitter as they change
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}


// -- steering readout --

/// "12.3°", never "-0.0°"
String formatSteeringAngle(double deg) {
  final text = deg.toStringAsFixed(1);
  return '${text == '-0.0' ? '0.0' : text}°';
}

/// bottom left: steering mode, the angle openpilot is asking for, and the angle
/// the wheel is at
class EnhancedSteeringPills extends StatelessWidget {
  final UIState uiState;
  final double unit;

  const EnhancedSteeringPills({super.key, required this.uiState, required this.unit});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    final String modeText;
    final Color modeColor;
    switch (st.steeringMode) {
      case LateralMode.angle:
        modeText = 'ANGLE';
        modeColor = angleColor;
      case LateralMode.torque:
        modeText = 'TORQUE';
        modeColor = torqueColor;
      case null:
        modeText = 'OFF';
        modeColor = HudColors.grey;
    }
    final gap = SizedBox(height: enhancedInfoPillGap * unit);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _infoPill(unit, 'STEER', modeText, modeColor),
        gap,
        // only meaningful while openpilot is steering
        _infoPill(unit, 'TARGET', st.latActive ? formatSteeringAngle(st.targetSteeringAngleDeg) : '–',
            HudColors.white),
        gap,
        _infoPill(unit, 'ACTUAL', formatSteeringAngle(st.steeringAngleDeg), HudColors.white),
      ],
    );
  }
}

// -- lead car readout --

/// lead car box and numbers show whenever openpilot is doing something (steering
/// only, cruise only, fully engaged, or overridden), not while disengaged
bool enhancedShowsLead(UIStatus status) => status != UIStatus.disengaged;

/// shown in each lead pill while there is no lead to report
const enhancedNoLeadValue = '– –';
const _noLeadColor = Color(0xFF8A8A8A);

/// following time in seconds, or a dash when standing still
String formatLeadGap(double dRel, double vEgo) => vEgo > 0.5 ? '${(dRel / vEgo).toStringAsFixed(1)} s' : '–';

/// speed difference to the lead with its sign: "-3 mph" is closing, "+2 mph" is pulling away
String formatLeadRelSpeed(double vRel, double conv, String speedUnit) {
  final v = (vRel * conv).round();
  return '${v > 0 ? '+' : ''}$v $speedUnit';
}

/// bottom right, always there: time gap, speed difference, and the lead's own
/// speed, or grey dashes with no lead car or while disengaged. The distance is on
/// the tag above the lead's box
class EnhancedLeadPills extends StatelessWidget {
  final UIState uiState;
  final double unit;

  const EnhancedLeadPills({super.key, required this.uiState, required this.unit});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    final lead = enhancedShowsLead(st.status) ? st.activeLead : null;
    final gap = SizedBox(height: enhancedInfoPillGap * unit);
    if (lead == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _infoPill(unit, 'GAP', enhancedNoLeadValue, _noLeadColor),
          gap,
          _infoPill(unit, 'REL', enhancedNoLeadValue, _noLeadColor),
          gap,
          _infoPill(unit, 'LEAD', enhancedNoLeadValue, _noLeadColor),
        ],
      );
    }

    final dRel = (lead['dRel'] as num?)?.toDouble() ?? 0.0;
    final vRel = (lead['vRel'] as num?)?.toDouble() ?? 0.0;
    final speedUnit = st.isMetric ? 'km/h' : 'mph';
    final leadSpeed = max(0.0, (st.vEgo + vRel) * st.speedConv).round();
    final warn = leadWarnColor(leadWarnLevel(dRel, vRel));
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _infoPill(unit, 'GAP', formatLeadGap(dRel, st.vEgo), warn),
        gap,
        _infoPill(unit, 'REL', formatLeadRelSpeed(vRel, st.speedConv, speedUnit), HudColors.white),
        gap,
        _infoPill(unit, 'LEAD', '$leadSpeed $speedUnit', HudColors.white),
      ],
    );
  }
}

// -- alerts --

/// notices and prompts are a compact card above the torque bar, between the two
/// readouts, so the rest of the display stays visible. Critical alerts, and any
/// alert openpilot sends at full size, cover the whole screen
class EnhancedAlert extends StatelessWidget {
  final UIState uiState;
  final double unit;

  const EnhancedAlert({super.key, required this.uiState, required this.unit});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    if (st.alertSize == _alertSizeNone) return const SizedBox.shrink();

    if (enhancedAlertIsFullScreen(st.alertSize, st.alertStatus)) {
      return Positioned.fill(
        child: Container(
          key: const ValueKey('enhancedAlertFull'),
          color: enhancedAlertColor(st.alertStatus, fullScreen: true),
          padding: EdgeInsets.all(20 * unit),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(flex: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  st.alertText1,
                  style: TextStyle(color: Colors.white, fontSize: 44 * unit, fontWeight: FontWeight.bold, height: 1.1),
                ),
              ),
              const Spacer(),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  st.alertText2,
                  style: TextStyle(color: Colors.white, fontSize: 24 * unit, height: 1.1),
                ),
              ),
              const Spacer(flex: 2),
            ],
          ),
        ),
      );
    }

    final showSecondLine = st.alertSize != _alertSizeSmall && st.alertText2.isNotEmpty;
    return Positioned(
      left: 0,
      right: 0,
      bottom: (enhancedBorderWidth + enhancedMargin + 46) * unit,
      child: Center(
        child: Container(
          key: const ValueKey('enhancedAlertCard'),
          constraints: BoxConstraints(minWidth: 150 * unit, maxWidth: 262 * unit),
          padding: EdgeInsets.symmetric(horizontal: 18 * unit, vertical: 11 * unit),
          decoration: BoxDecoration(
            color: enhancedAlertColor(st.alertStatus, fullScreen: false),
            borderRadius: BorderRadius.circular(12 * unit),
            boxShadow: [BoxShadow(color: const Color(0x59000000), blurRadius: 10 * unit, offset: Offset(0, 2 * unit))],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                st.alertText1,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 20 * unit, fontWeight: FontWeight.bold, height: 1.1),
              ),
              if (showSecondLine) ...[
                SizedBox(height: 6 * unit),
                Text(
                  st.alertText2,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: const Color(0xF2FFFFFF), fontSize: 13 * unit, height: 1.1),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// -- driver monitoring icon --

/// dark disc with a cone (drawn as an arc) on the side the driver's head is turned
/// towards; the person glyph is the painter's child. [rotationDeg] is the comma
/// four's head rotation, where 90 is straight ahead and puts the cone at the top
class EnhancedDriverIconPainter extends CustomPainter {
  final Color? coneColor;  // null: no cone
  final double rotationDeg;

  const EnhancedDriverIconPainter({required this.coneColor, required this.rotationDeg});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    canvas.drawCircle(c, r, Paint()..color = _discColor);
    final color = coneColor;
    if (color == null) return;
    final arc = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.16
      ..strokeCap = StrokeCap.round;
    // 100 degrees wide; the device turns its cone image by (rotation - 90) from the top
    final middle = (rotationDeg - 180) * pi / 180;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r * 0.84), middle - 50 * pi / 180, 100 * pi / 180, false, arc);
  }

  @override
  bool shouldRepaint(EnhancedDriverIconPainter old) => old.coneColor != coneColor || old.rotationDeg != rotationDeg;
}

// -- driver monitoring and confidence, top left --

/// the model confidence indicator shows a dot only while openpilot is engaged in some
/// form and confidence data has arrived; otherwise it is an empty, dimmed ring
bool enhancedConfidenceLive(UIState st) => st.status != UIStatus.disengaged && st.confidenceSeen;

/// the driver monitoring icon at the top left corner and the confidence indicator
/// beside it, the same size; for the Enhanced and Detailed layouts' Stacks
List<Widget> enhancedDriverAndConfidence(UIState st, double unit, double edge) {
  final size = enhancedDriverIconSize * unit;
  if (!st.started) return const [];
  final driverLive = enhancedDriverIconLive(st);
  final confLive = enhancedConfidenceLive(st);
  return [
    // shown whenever the comma reports on the driver: the cone points where the
    // driver's head is turned; dimmed, without the cone, while not engaged or while
    // camera monitoring is not running
    if (st.dmSeen)
      Positioned(
        key: const ValueKey('driverIcon'),
        left: edge,
        top: edge,
        width: size,
        height: size,
        child: Opacity(
          opacity: driverLive ? 1.0 : 0.35,
          child: CustomPaint(
            painter: EnhancedDriverIconPainter(
              coneColor: driverLive ? enhancedDriverConeColor(awarenessFull: !st.dmAwarenessUnfull) : null,
              rotationDeg: st.dmRotationDeg,
            ),
            child: Center(child: Icon(Icons.person, color: Colors.white, size: size * 0.62)),
          ),
        ),
      ),
    Positioned(
      key: const ValueKey('confidenceIndicator'),
      left: edge + size + 6 * unit,
      top: edge,
      width: size,
      height: size,
      child: Opacity(
        opacity: confLive ? 1.0 : 0.35,
        child: CustomPaint(painter: ConfidencePainter(confidence: confLive ? st.confidenceFiltered : null)),
      ),
    ),
  ];
}

/// colours of the comma four's confidence ball (mici confidence_ball.py): green when
/// confident, amber when unsure, red when about to disengage
(Color, Color) confidenceColors(double c) {
  if (c > 0.5) return (const Color(0xFF00FFCC), const Color(0xFF00FF26));
  if (c > 0.2) return (const Color(0xFFFFC800), const Color(0xFFFF7300));
  return (const Color(0xFFFF0015), const Color(0xFFFF0059));
}

/// radius of the confidence dot as a share of the indicator's size
double confidenceDotRadius(double confidence) => 0.08 + 0.26 * confidence.clamp(0.0, 1.0).toDouble();

/// dark disc with a fixed thin ring; the dot inside grows with confidence and shrinks
/// as a disengagement becomes likely. [confidence] null draws the ring alone
class ConfidencePainter extends CustomPainter {
  final double? confidence;

  const ConfidencePainter({required this.confidence});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final c = size.center(Offset.zero);
    canvas.drawCircle(c, s / 2, Paint()..color = _discColor);
    canvas.drawCircle(
      c,
      s * 0.40,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.045
        ..color = const Color(0x2EFFFFFF),
    );
    final conf = confidence;
    if (conf == null) return;
    final r = s * confidenceDotRadius(conf);
    final (top, bottom) = confidenceColors(conf.clamp(0.0, 1.0).toDouble());
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(
      c,
      r,
      Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [top, bottom]).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(ConfidencePainter old) => old.confidence != confidence;
}

// -- clock, top right --

/// a small time pill in the top right corner, with a smaller AM/PM
class EnhancedCornerClock extends StatelessWidget {
  final double unit;
  final ClockMode clockMode;

  const EnhancedCornerClock({super.key, required this.unit, required this.clockMode});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('enhancedClock'),
      width: enhancedClockWidth * unit,
      height: enhancedClockHeight * unit,
      padding: EdgeInsets.symmetric(horizontal: 4 * unit),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: const Color(0xB3141414), borderRadius: BorderRadius.circular(6 * unit)),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: ClockText(
          mode: clockMode,
          style: TextStyle(color: HudColors.white, fontSize: 9 * unit, fontWeight: FontWeight.bold, height: 1.0),
          suffixStyle: TextStyle(color: _labelColor, fontSize: 5 * unit, fontWeight: FontWeight.w600, height: 1.0),
          suffixGap: 1.5 * unit,
        ),
      ),
    );
  }
}

// -- torque bar (mici/onroad/torque_bar.py) --

/// arc along the bottom of the screen: grey track, filled from the centre towards
/// the side the car is steering, turning orange near the limit
class EnhancedTorqueBarPainter extends CustomPainter {
  final double value;  // -1..1
  final UIStatus status;
  final double unit;

  const EnhancedTorqueBarPainter({required this.value, required this.status, required this.unit});

  @override
  void paint(Canvas canvas, Size size) {
    // hidden when nothing is steering
    if (status == UIStatus.disengaged || status == UIStatus.longOnly) return;
    final steering = status == UIStatus.engaged || status == UIStatus.latOnly;

    final mag = value.abs();
    final offset = (_interp(mag, 0.5, 1, 22, 26) + enhancedBorderWidth) * unit;
    final thickness = _interp(mag, 0.5, 1, 14, 56) * unit;
    final radius = _torqueRadius * unit;
    final midR = radius + thickness / 2;
    final center = Offset(size.width / 2, size.height + radius - offset);
    final arc = Rect.fromCircle(center: center, radius: midR);

    const top = -pi / 2;
    const halfSpan = _torqueAngleSpanDeg / 2 * pi / 180;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round;

    // track
    final trackAlpha = steering ? _interp(mag, 0.5, 1, 0.25, 0.5) : 0.15;
    paint.color = Color.fromRGBO(255, 255, 255, trackAlpha);
    canvas.drawArc(arc, top - halfSpan, 2 * halfSpan, false, paint);

    // fill
    if (mag > 0.001) {
      final hot = max(0.0, mag - 0.75) * 4;
      paint.color = steering
          ? Color.lerp(const Color(0xE6FFFFFF), const Color(0xFFFF7300), hot)!
          : const Color(0x59FFFFFF);
      canvas.drawArc(arc, top, halfSpan * value, false, paint);
    }

    // centre dot while the bar is thin
    if (mag < 0.5) {
      canvas.drawCircle(
        Offset(center.dx, size.height - offset - thickness / 2),
        5 * unit,
        Paint()..color = const Color(0xE6B6B6B6),
      );
    }
  }

  @override
  bool shouldRepaint(EnhancedTorqueBarPainter old) =>
      old.value != value || old.status != status || old.unit != unit;
}

/// linear interpolation of [x] from [x0]..[x1] to [y0]..[y1], held at the ends
double _interp(double x, double x0, double x1, double y0, double y1) {
  if (x <= x0) return y0;
  if (x >= x1) return y1;
  return y0 + (y1 - y0) * (x - x0) / (x1 - x0);
}
