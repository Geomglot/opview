// Detailed layout
//
// the Enhanced layout's camera, border, path, lead box, driver icon, torque bar,
// blind spot glow and alerts, with as much of the comma's data as fits around them:
//   - top row, centred on the speed: set speed | speed | speed limit (and the next one),
//     shared with Enhanced (top_row.dart)
//   - top left: driver monitoring and model confidence, as in Enhanced
//   - top right: clock and device health (CPU temperature, memory, disk, Wi-Fi,
//     power draw, calibration)
//   - left: STEERING and DRIVER panels
//   - right: LONGITUDINAL and LEAD panels; tapping a panel folds it to its title
//   - bottom: gear, turn signal, blind spot, lane line confidence, path curvature
//
// sizes are in comma four pixels, scaled by `unit`, as in the Enhanced layout.

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:opview/common/transformations.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/selfdrive/ui/onroad/clock_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/enhanced/enhanced_layout.dart';
import 'package:opview/selfdrive/ui/onroad/exp_button.dart';
import 'package:opview/selfdrive/ui/onroad/hud_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/model_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/throttled.dart';
import 'package:opview/selfdrive/ui/onroad/top_row.dart';
import 'package:opview/services/app_settings.dart';

// -- sizes, in comma four pixels --

const detailedPanelWidth = 112.0;
const detailedPanelTop = 82.0;        // below the driver icon
const detailedCornerWidth = 82.0;     // clock and device health, top right
const _rowHeight = 9.0;
const _traceHeight = 20.0;

// -- colours --

const _panelColor = Color(0xBD101010);
const _chipColor = Color(0x99101010);
const _labelColor = Color(0xFF9A9A9A);
const _dimColor = Color(0xFF6E6E6E);
const _green = Color(0xFF3ADB6D);
const _orange = Color(0xFFFF9A3C);
const _blue = Color(0xFF4D9DFF);

/// the second lead car: its box on the road and its row in the LEAD panel. Teal, unlike any
/// warning or border colour, as openpilot only follows the first lead
const detailedSecondLeadColor = Color(0xFF2DD4BF);

/// shown for a value that is not available right now
const detailedNoValue = '–';

// -- formatting --

/// "-0.42 m/s²"; never "-0.00"
String formatAccel(double v) {
  final text = v.toStringAsFixed(2);
  return '${text == '-0.00' ? '0.00' : text} m/s²';
}

/// "0.82 / 0.79"
String formatAccelPair(double want, double got) {
  String f(double v) {
    final t = v.toStringAsFixed(2);
    return t == '-0.00' ? '0.00' : t;
  }
  return '${f(want)} / ${f(got)}';
}

/// relaxed / standard / aggressive, capitalised
String formatPersonality(String p) => p.isEmpty ? detailedNoValue : '${p[0].toUpperCase()}${p.substring(1)}';

/// P R N D, or the name for anything else
String formatGear(String gear) {
  switch (gear) {
    case 'park':
      return 'P';
    case 'reverse':
      return 'R';
    case 'neutral':
      return 'N';
    case 'drive':
      return 'D';
    case '':
    case 'unknown':
      return detailedNoValue;
    default:
      return gear.toUpperCase();
  }
}

/// seconds until the lead is reached at the current closing speed, or null when not closing
double? timeToLead(double dRel, double vRel) => vRel < -0.1 ? dRel / -vRel : null;

/// Wi-Fi / cell strength as 0..4 bars
int networkBars(String strength) {
  switch (strength) {
    case 'poor':
      return 1;
    case 'moderate':
      return 2;
    case 'good':
      return 3;
    case 'great':
      return 4;
    default:
      return 0;
  }
}

// -- layout --

class DetailedLayout extends StatelessWidget {
  final UIState uiState;
  final ClockMode clockMode;
  final SpeedLimitDisplay speedLimitDisplay;
  final FrameTransform Function(double w, double h) frameFor;
  final Widget Function(FrameTransform frame) videoBuilder;

  /// names of the panels folded to their title ([detailedPanelNames])
  final Set<String> collapsedPanels;

  /// called with a panel's name when it is tapped
  final void Function(String name)? onTogglePanel;

  const DetailedLayout({
    super.key,
    required this.uiState,
    required this.clockMode,
    this.speedLimitDisplay = SpeedLimitDisplay.auto,
    required this.frameFor,
    required this.videoBuilder,
    this.collapsedPanels = const {},
    this.onTogglePanel,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final st = uiState;
      final w = constraints.maxWidth, h = constraints.maxHeight;
      final unit = enhancedUnit(Size(w, h));
      final radius = BorderRadius.circular(enhancedCornerRadius * unit);
      final edge = (enhancedBorderWidth + enhancedMargin) * unit;
      final frame = frameFor(w, h);
      final hudBottom = edge + (enhancedSpeedPillHeight + roadNameGap + roadNamePillHeight) * unit;
      final panelTop = (enhancedBorderWidth + detailedPanelTop) * unit;

      Widget column(List<Widget> children) => Align(
            alignment: Alignment.topCenter,
            // a short screen shrinks the panels rather than cutting them off
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.topCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0) SizedBox(height: 4 * unit),
                    children[i],
                  ],
                ],
              ),
            ),
          );

      return ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
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
                secondLeadColor: detailedSecondLeadColor,
              ),
            ),
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
            if (st.showBlindSpot && st.leftBlindspot) _glow(unit, left: true),
            if (st.showBlindSpot && st.rightBlindspot) _glow(unit, left: false),
            CustomPaint(
              painter: EnhancedTorqueBarPainter(value: st.torqueBarValue, status: st.status, unit: unit),
            ),

            // top row: set speed | speed | speed limit
            Positioned(
              top: edge,
              left: 0,
              right: 0,
              height: enhancedSpeedPillHeight * unit,
              child: SpeedTopRow(uiState: st, unit: unit, speedLimitDisplay: speedLimitDisplay),
            ),
            if (st.showRoadName)
              Positioned(
                top: edge + (enhancedSpeedPillHeight + roadNameGap) * unit,
                left: 0,
                right: 0,
                child: Center(child: RoadNamePill(name: st.roadName, unit: unit, maxWidth: w * 0.4)),
              ),

            // driver monitoring and model confidence, top left
            ...enhancedDriverAndConfidence(st, unit, edge),

            // clock and device health, top right
            Positioned(
              right: edge,
              top: edge,
              width: detailedCornerWidth * unit,
              // readouts refresh about 5 times a second, the camera and path 20
              child: ThrottledByVersion(
                state: st,
                builder: (_) => DetailedDeviceGrid(uiState: st, unit: unit, clockMode: clockMode),
              ),
            ),

            // side panels
            Positioned(
              left: edge,
              top: panelTop,
              bottom: edge,
              width: detailedPanelWidth * unit,
              child: ThrottledByVersion(
                state: st,
                builder: (_) => column([
                  DetailedSteeringPanel(uiState: st, unit: unit, collapsed: collapsedPanels.contains('steering'), onTap: _toggle('steering')),
                  DetailedDriverPanel(uiState: st, unit: unit, collapsed: collapsedPanels.contains('driver'), onTap: _toggle('driver')),
                ]),
              ),
            ),
            Positioned(
              right: edge,
              top: panelTop,
              bottom: edge,
              width: detailedPanelWidth * unit,
              child: ThrottledByVersion(
                state: st,
                builder: (_) => column([
                  DetailedLongitudinalPanel(uiState: st, unit: unit, collapsed: collapsedPanels.contains('longitudinal'), onTap: _toggle('longitudinal')),
                  DetailedLeadPanel(uiState: st, unit: unit, collapsed: collapsedPanels.contains('lead'), onTap: _toggle('lead')),
                ]),
              ),
            ),

            // car and model state, bottom centre
            Positioned(
              left: edge + (detailedPanelWidth + 8) * unit,
              right: edge + (detailedPanelWidth + 8) * unit,
              bottom: 6.5 * unit,
              child: ThrottledByVersion(
                state: st,
                builder: (_) => DetailedStatusStrip(uiState: st, unit: unit),
              ),
            ),

            EnhancedAlert(uiState: st, unit: unit),

            // border in the engagement colour, drawn on top but letting taps
            // through to the panels underneath
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

  VoidCallback? _toggle(String name) {
    final f = onTogglePanel;
    return f == null ? null : () => f(name);
  }

  Widget _glow(double unit, {required bool left}) {
    const glow = Color(0x8CFF9628);
    return Positioned(
      key: ValueKey(left ? 'blindSpotLeft' : 'blindSpotRight'),
      left: left ? 0 : null,
      right: left ? null : 0,
      top: 0,
      bottom: 0,
      width: enhancedGlowWidth * unit,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: left ? Alignment.centerLeft : Alignment.centerRight,
            end: left ? Alignment.centerRight : Alignment.centerLeft,
            colors: const [glow, Color(0x00FF9628)],
          ),
        ),
      ),
    );
  }
}


// -- panels --

/// names of the side panels, as stored in the settings when folded
const detailedPanelNames = ['steering', 'driver', 'longitudinal', 'lead'];

/// dark card with a title, an optional badge, and rows of label and value; tapping it
/// folds it down to the title (same width) and back
class _Panel extends StatelessWidget {
  final double unit;
  final String title;
  final Widget? badge;
  final List<(String, String, Color)> rows;
  final Widget? footer;
  final bool collapsed;
  final VoidCallback? onTap;

  const _Panel({
    required this.unit,
    required this.title,
    this.badge,
    required this.rows,
    this.footer,
    this.collapsed = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final titleStyle = TextStyle(
      color: const Color(0xFFCFCFCF),
      fontSize: 5.6 * unit,
      fontWeight: FontWeight.bold,
      letterSpacing: 0.6 * unit,
      height: 1.0,
    );
    final titleRow = SizedBox(
      height: 8 * unit,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _shrink(
            alignment: Alignment.centerLeft,
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: titleStyle),
                SizedBox(width: 2 * unit),
                Text(collapsed ? '▸' : '▾', key: ValueKey('detailedPanelArrow_$title'), style: titleStyle),
              ],
            ),
          ),
          if (badge != null && !collapsed) ...[
            SizedBox(width: 3 * unit),
            _shrink(alignment: Alignment.centerRight, badge!),
          ],
        ],
      ),
    );
    final card = Container(
      key: ValueKey('detailedPanel_$title'),
      width: detailedPanelWidth * unit,
      padding: collapsed
          ? EdgeInsets.symmetric(horizontal: 6 * unit, vertical: 3.5 * unit)
          : EdgeInsets.symmetric(horizontal: 6 * unit, vertical: 4.5 * unit),
      decoration: BoxDecoration(color: _panelColor, borderRadius: BorderRadius.circular(7 * unit)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          titleRow,
          if (!collapsed) ...[
            SizedBox(height: 2 * unit),
            for (final (label, value, color) in rows)
              SizedBox(
                height: _rowHeight * unit,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _shrink(
                      alignment: Alignment.centerLeft,
                      Text(label, style: TextStyle(color: _labelColor, fontSize: 5.6 * unit, fontWeight: FontWeight.w600, height: 1.0)),
                    ),
                    SizedBox(width: 3 * unit),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          value,
                          style: TextStyle(
                            color: color,
                            fontSize: 7 * unit,
                            fontWeight: FontWeight.bold,
                            height: 1.0,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (footer != null) footer!,
          ],
        ],
      ),
    );
    if (onTap == null) return card;
    // only a tap: a long press still reaches the settings
    return GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: card);
  }
}

/// [child] at its natural size when it fits in its share of a row, scaled down when not
Widget _shrink(Widget child, {required Alignment alignment}) =>
    Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: alignment, child: child));

/// small outlined tag for a panel title
Widget detailedBadge(double unit, String text, Color color, {Key? key}) {
  return Container(
    key: key,
    padding: EdgeInsets.symmetric(horizontal: 3 * unit, vertical: 0.6 * unit),
    decoration: BoxDecoration(
      border: Border.all(color: color, width: 0.5 * unit),
      borderRadius: BorderRadius.circular(4 * unit),
    ),
    child: Text(text, style: TextStyle(color: color, fontSize: 4.6 * unit, fontWeight: FontWeight.bold, height: 1.0)),
  );
}

/// the last ten seconds of two values: [want] dashed white, [got] solid in [gotColor]
Widget _trace(
  double unit, {
  required String label,
  required List<double> want,
  required List<double> got,
  required String wantName,
  required String gotName,
  required Color gotColor,
  required double lo,
  required double hi,
}) {
  Widget key(String name, Color c) => Padding(
        padding: EdgeInsets.only(left: 5 * unit),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 5 * unit, height: 1 * unit, color: c),
          SizedBox(width: 2 * unit),
          Text(name, style: TextStyle(color: _labelColor, fontSize: 4.8 * unit, height: 1.0)),
        ]),
      );
  return Container(
    margin: EdgeInsets.only(top: 3 * unit),
    padding: EdgeInsets.only(top: 3 * unit),
    decoration: BoxDecoration(border: Border(top: BorderSide(color: const Color(0x1FFFFFFF), width: 0.5 * unit))),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          _shrink(alignment: Alignment.centerLeft, Text(label, style: TextStyle(color: _labelColor, fontSize: 4.8 * unit, height: 1.0))),
          _shrink(
            alignment: Alignment.centerRight,
            Row(mainAxisSize: MainAxisSize.min, children: [key(wantName, Colors.white), key(gotName, gotColor)]),
          ),
        ]),
        SizedBox(height: 2 * unit),
        SizedBox(
          height: _traceHeight * unit,
          child: CustomPaint(
            painter: DetailedTracePainter(want: want, got: got, gotColor: gotColor, lo: lo, hi: hi, unit: unit),
          ),
        ),
      ],
    ),
  );
}

/// two lines over a fixed range, with a faint zero line
class DetailedTracePainter extends CustomPainter {
  final List<double> want;
  final List<double> got;
  final Color gotColor;
  final double lo;
  final double hi;
  final double unit;
  final int _wantLength;
  final double _wantLast;
  final double _gotLast;

  DetailedTracePainter({
    required this.want,
    required this.got,
    required this.gotColor,
    required this.lo,
    required this.hi,
    required this.unit,
  })  : _wantLength = want.length,
        _wantLast = want.isEmpty ? 0 : want.last,
        _gotLast = got.isEmpty ? 0 : got.last;

  @override
  void paint(Canvas canvas, Size size) {
    double y(double v) => size.height - ((v.clamp(lo, hi) - lo) / (hi - lo)) * size.height;
    canvas.drawLine(
      Offset(0, y(0)),
      Offset(size.width, y(0)),
      Paint()
        ..color = const Color(0x2EFFFFFF)
        ..strokeWidth = 0.5 * unit,
    );
    // always spread over the full ten seconds, so the newest sample is at the right edge
    final dx = size.width / (UIState.historyLength - 1);
    Path line(List<double> values) {
      final path = Path();
      final start = UIState.historyLength - values.length;
      for (var i = 0; i < values.length; i++) {
        final p = Offset((start + i) * dx, y(values[i]));
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      return path;
    }

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    if (got.length > 1) {
      stroke
        ..color = gotColor
        ..strokeWidth = 1.4 * unit;
      canvas.drawPath(line(got), stroke);
    }
    if (want.length > 1) {
      // dashed: draw every other stretch of the path
      final dash = 2.5 * unit, gap = 2 * unit;
      stroke
        ..color = Colors.white
        ..strokeWidth = 1.1 * unit;
      for (final metric in line(want).computeMetrics()) {
        for (double d = 0; d < metric.length; d += dash + gap) {
          canvas.drawPath(metric.extractPath(d, min(d + dash, metric.length)), stroke);
        }
      }
    }
  }

  @override
  bool shouldRepaint(DetailedTracePainter old) =>
      old._wantLength != _wantLength || old._wantLast != _wantLast || old._gotLast != _gotLast || old.unit != unit;
}

class DetailedSteeringPanel extends StatelessWidget {
  final UIState uiState;
  final double unit;
  final bool collapsed;
  final VoidCallback? onTap;

  const DetailedSteeringPanel({super.key, required this.uiState, required this.unit, this.collapsed = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    final (String mode, Color modeColor) = switch (st.steeringMode) {
      LateralMode.angle => ('ANGLE', angleColor),
      LateralMode.torque => ('TORQUE', torqueColor),
      null => ('OFF', HudColors.grey),
    };
    final on = st.latActive;
    return _Panel(
      unit: unit,
      collapsed: collapsed,
      onTap: onTap,
      title: 'STEERING',
      badge: on
          ? (st.lateralSaturated
              ? detailedBadge(unit, 'SATURATED', _orange, key: const ValueKey('detailedSaturated'))
              : detailedBadge(unit, 'NOT SATURATED', _green))
          : null,
      rows: [
        ('Mode', mode, modeColor),
        ('Target', on ? formatSteeringAngle(st.targetSteeringAngleDeg) : detailedNoValue, Colors.white),
        ('Actual', formatSteeringAngle(st.steeringAngleDeg), Colors.white),
        ('Rate', '${st.steeringRateDeg.toStringAsFixed(1)}°/s', Colors.white),
        ('Torque cmd', on ? '${(st.torqueOutput * 100).round()}%' : detailedNoValue, Colors.white),
        ('Driver torque', st.steeringTorque.toStringAsFixed(1), Colors.white),
        ('Lat accel', on ? formatAccelPair(st.latAccelWant, st.latAccelGot) : detailedNoValue, Colors.white),
      ],
      footer: _trace(
        unit,
        label: 'lat accel, 10 s',
        want: st.latAccelWantHistory,
        got: st.latAccelGotHistory,
        wantName: 'want',
        gotName: 'got',
        gotColor: _green,
        lo: -2,
        hi: 2,
      ),
    );
  }
}

class DetailedDriverPanel extends StatelessWidget {
  final UIState uiState;
  final double unit;
  final bool collapsed;
  final VoidCallback? onTap;

  const DetailedDriverPanel({super.key, required this.uiState, required this.unit, this.collapsed = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    final seen = st.dmSeen;
    final attention = st.dmAwarenessPercent.round();
    return _Panel(
      unit: unit,
      collapsed: collapsed,
      onTap: onTap,
      title: 'DRIVER',
      rows: [
        ('Face', !seen ? detailedNoValue : (st.dmFaceDetected ? 'detected' : 'not seen'),
            st.dmFaceDetected ? _green : _orange),
        ('Attention', seen ? '$attention%' : detailedNoValue, st.dmAwarenessUnfull ? _orange : _green),
        ('Policy', st.dmPolicy.isEmpty ? detailedNoValue : st.dmPolicy, Colors.white),
      ],
    );
  }
}

class DetailedLongitudinalPanel extends StatelessWidget {
  final UIState uiState;
  final double unit;
  final bool collapsed;
  final VoidCallback? onTap;

  const DetailedLongitudinalPanel({super.key, required this.uiState, required this.unit, this.collapsed = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    final pedals = [if (st.gasPressed) 'throttle', if (st.brakePressed) 'brake'];
    return _Panel(
      unit: unit,
      collapsed: collapsed,
      onTap: onTap,
      title: 'LONGITUDINAL',
      badge: st.experimentalMode
          ? detailedBadge(unit, 'EXPERIMENTAL', _orange, key: const ValueKey('detailedExperimental'))
          : detailedBadge(unit, 'CHILL', HudColors.grey, key: const ValueKey('detailedChill')),
      rows: [
        ('ACC', st.cruiseEnabled ? 'on' : 'off', st.cruiseEnabled ? _green : _dimColor),
        ('Personality', formatPersonality(st.personality), Colors.white),
        ('Accel cmd', st.longActive ? formatAccel(st.accelCommand) : detailedNoValue, Colors.white),
        ('Accel actual', formatAccel(st.aEgo), Colors.white),
        ('Throttle / brake', pedals.isEmpty ? '— / —' : pedals.join(' + '), pedals.isEmpty ? _dimColor : _orange),
      ],
      footer: _trace(
        unit,
        label: 'accel, 10 s',
        want: st.accelCommandHistory,
        got: st.accelActualHistory,
        wantName: 'cmd',
        gotName: 'actual',
        gotColor: _orange,
        lo: -2,
        hi: 1.5,
      ),
    );
  }
}

class DetailedLeadPanel extends StatelessWidget {
  final UIState uiState;
  final double unit;
  final bool collapsed;
  final VoidCallback? onTap;

  const DetailedLeadPanel({super.key, required this.uiState, required this.unit, this.collapsed = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    final shown = enhancedShowsLead(st.status);
    final lead = shown ? st.activeLead : null;
    if (lead == null) {
      const dash = enhancedNoLeadValue, c = Color(0xFF8A8A8A);
      return _Panel(unit: unit, collapsed: collapsed, onTap: onTap, title: 'LEAD', rows: const [
        ('Distance', dash, c),
        ('Gap', dash, c),
        ('Closing', dash, c),
        ('Lead speed', dash, c),
        ('Time to impact', dash, c),
        ('Second lead', dash, c),
      ]);
    }
    double numOf(Map<String, dynamic> m, String k) => (m[k] as num?)?.toDouble() ?? 0.0;
    final dRel = numOf(lead, 'dRel'), vRel = numOf(lead, 'vRel');
    final speedUnit = st.isMetric ? 'km/h' : 'mph';
    final warn = leadWarnColor(leadWarnLevel(dRel, vRel));
    final ttl = timeToLead(dRel, vRel);
    final two = st.leadTwo;
    var second = detailedNoValue;
    if (two != null && isLeadPresent(two) && (numOf(two, 'dRel') - dRel).abs() > 3.0) {
      second = formatLeadDistance(numOf(two, 'dRel'), st.isMetric);
    }
    // held for a second, so a momentary loss of the radar match does not flicker it
    final radar = st.leadRadarRecent;
    return _Panel(
      unit: unit,
      collapsed: collapsed,
      onTap: onTap,
      title: 'LEAD',
      badge: detailedBadge(unit, radar ? 'RADAR + VISION' : 'VISION', _blue),
      rows: [
        ('Distance', formatLeadDistance(dRel, st.isMetric), warn),
        ('Gap', formatLeadGap(dRel, st.vEgo), warn),
        ('Closing', formatLeadRelSpeed(vRel, st.speedConv, speedUnit), Colors.white),
        ('Lead speed', '${max(0.0, (st.vEgo + vRel) * st.speedConv).round()} $speedUnit', Colors.white),
        ('Time to impact', ttl != null && ttl < 99 ? '${ttl.toStringAsFixed(1)} s' : detailedNoValue, Colors.white),
        ('Second lead', second, second == detailedNoValue ? Colors.white : detailedSecondLeadColor),
      ],
    );
  }
}

// -- top right: clock and device health --

class DetailedDeviceGrid extends StatelessWidget {
  final UIState uiState;
  final double unit;
  final ClockMode clockMode;

  const DetailedDeviceGrid({super.key, required this.uiState, required this.unit, required this.clockMode});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    final gap = 2 * unit;
    Widget cell(String label, Widget value) => Container(
          height: 10 * unit,
          padding: EdgeInsets.symmetric(horizontal: 3 * unit),
          decoration: BoxDecoration(color: _chipColor, borderRadius: BorderRadius.circular(4 * unit)),
          child: Row(children: [
            Text(label, style: TextStyle(color: _labelColor, fontSize: 4.6 * unit, height: 1.0)),
            SizedBox(width: 2 * unit),
            // a long value shrinks rather than overflowing the cell
            Expanded(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: value)),
          ]),
        );
    Text v(String text, [Color color = Colors.white]) => Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 5.6 * unit,
            fontWeight: FontWeight.bold,
            height: 1.0,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        );
    final seen = st.deviceSeen;
    final calibrated = st.calStatus == 'calibrated';
    final calText = calibrated ? '100%' : (st.calPerc > 0 ? '${st.calPerc}%' : detailedNoValue);
    final rows = [
      [
        cell('CPU', v(seen ? '${st.cpuTempC.round()}°C' : detailedNoValue)),
        cell('Mem', v(seen ? '${st.memoryUsagePercent}%' : detailedNoValue)),
      ],
      [
        cell('Disk', v(seen ? '${(100 - st.freeSpacePercent).round()}%' : detailedNoValue)),
        cell('Wi-Fi', _bars(networkBars(st.networkStrength))),
      ],
      [
        cell('Power', v(seen ? '${st.powerDrawW.toStringAsFixed(1)} W' : detailedNoValue)),
        cell('Calib', v(calText, calibrated ? _green : _orange)),
      ],
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (clockMode != ClockMode.off) ...[
          Container(
            key: const ValueKey('detailedClock'),
            height: 13 * unit,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: _chipColor, borderRadius: BorderRadius.circular(4 * unit)),
            child: ClockText(
              mode: clockMode,
              style: TextStyle(color: Colors.white, fontSize: 9 * unit, fontWeight: FontWeight.bold, height: 1.0),
              suffixStyle: TextStyle(color: _labelColor, fontSize: 5 * unit, fontWeight: FontWeight.w600, height: 1.0),
              suffixGap: 2 * unit,
            ),
          ),
          SizedBox(height: gap),
        ],
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          Row(children: [
            Expanded(child: rows[i][0]),
            SizedBox(width: gap),
            Expanded(child: rows[i][1]),
          ]),
        ],
      ],
    );
  }

  /// four rising bars, lit up to [n]
  Widget _bars(int n) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < 4; i++)
          Container(
            margin: EdgeInsets.only(left: i == 0 ? 0 : 0.6 * unit),
            width: 1.6 * unit,
            height: (2 + i * 1.3) * unit,
            color: i < n ? _green : const Color(0x40FFFFFF),
          ),
      ],
    );
  }
}

// -- bottom: car and model state --

class DetailedStatusStrip extends StatelessWidget {
  final UIState uiState;
  final double unit;

  const DetailedStatusStrip({super.key, required this.uiState, required this.unit});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    Widget chip(String text, Color color) => Container(
          margin: EdgeInsets.symmetric(horizontal: 1.5 * unit),
          padding: EdgeInsets.symmetric(horizontal: 3.5 * unit, vertical: 1.6 * unit),
          decoration: BoxDecoration(color: const Color(0xB3101010), borderRadius: BorderRadius.circular(4 * unit)),
          child: Text(text, style: TextStyle(color: color, fontSize: 5.2 * unit, fontWeight: FontWeight.bold, height: 1.0)),
        );
    final signal = st.leftBlinker && st.rightBlinker
        ? '◀ hazards ▶'
        : st.leftBlinker
            ? '◀ signal'
            : st.rightBlinker
                ? 'signal ▶'
                : null;
    final bsm = [if (st.leftBlindspot) 'L', if (st.rightBlindspot) 'R'];
    // lanes 1 and 2 are the ones either side of the car
    final probs = st.laneLineProbs;
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          chip(formatGear(st.gearShifter), Colors.white),
          if (signal != null) chip(signal, _orange),
          if (bsm.isNotEmpty) chip('BSM ${bsm.join(' ')}', _orange),
          chip('lanes L ${probs[1].toStringAsFixed(2)} · R ${probs[2].toStringAsFixed(2)}', Colors.white),
          chip('curv ${st.curvature.toStringAsFixed(4)}', Colors.white),
        ],
      ),
    );
  }
}
