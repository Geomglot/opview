// lane centering indicator: which way lane centering is nudging the car and how hard
// ported from sunnypilot dys-a selfdrive/ui/sunnypilot/onroad/lane_centering_indicator.py
//
// The correction is a curvature, which means nothing to a driver, so it is shown as the
// sideways push it produces: push = correction * vEgo^2, in m/s^2.
//
// Two rates, as on the device. The bar is live (lightly smoothed), so a lane gate dropout of a
// few frames still shows. Everything written in words or figures, the One-Line Mode blue and the
// painted-line mark are latched: replaced twice a second by a summary of the half second just
// ended, so a figure stands long enough to be read and a flickering state does not flash.
//
// Three forms:
//   - LaneCenteringArcPainter: the bar, bent like the torque bar and in the same place
//     (Enhanced, Detailed, and Classic's torque slot)
//   - LaneCenteringCaption: one latched line of text above the arc (Enhanced)
//   - LaneCenteringPill: the device's full form, text over a straight bar (Classic)

import 'dart:math';

import 'package:flutter/material.dart';

const laneCenteringFullScale = 0.5;  // m/s^2 at the end of the bar
const laneCenteringAmberAbove = 0.5; // m/s^2
const laneCenteringSmoothTau = 0.1;  // s, just enough to stop the bar shimmering
const laneCenteringTextRefresh = Duration(milliseconds: 500);

/// a gap in the data longer than this starts the bar's smoothing afresh
const _maxSmoothGap = Duration(milliseconds: 500);

const _mToCm = 100.0;
const _mToIn = 39.3701;

// -- colours, as on the device --

const laneCenteringGray = Color(0xFF919B95);
const laneCenteringDimWhite = Color(0xC8FFFFFF);
const laneCenteringMint = Color(0xFF80D8A6);
const laneCenteringAmber = Color(0xFFFFBC00);
const laneCenteringLightBlue = Color(0xFF78BEFF);  // One-Line Mode
const laneCenteringRed = Color(0xFFE2564B);

const _track = Color(0x46FFFFFF);
const _graduation = Color(0x78FFFFFF);
const _detent = Color(0xEBFFFFFF);
const _shadow = Color(0x96000000);

/// what a half second window is summarised as; amber and red are shades of correcting
enum LaneCenteringState { gated, holding, correcting }

/// one carControlSP.laneCentering message
class LaneCenteringSample {
  final bool active;       // the lane lines passed every gate
  final bool holding;      // inside the deadband, deliberately doing nothing
  final double correction; // 1/m, signed, positive is to the right
  final double offset;     // m, signed, distance off the aim point
  final bool clipped;      // the demand was cut back
  final bool singleLine;   // One-Line Mode is in charge
  final int lineSide;      // +1 right, -1 left, 0 when not in One-Line Mode

  const LaneCenteringSample({
    this.active = false,
    this.holding = false,
    this.correction = 0.0,
    this.offset = 0.0,
    this.clipped = false,
    this.singleLine = false,
    this.lineSide = 0,
  });

  factory LaneCenteringSample.fromJson(Map<String, dynamic> d) => LaneCenteringSample(
        active: d['active'] as bool? ?? false,
        holding: d['holding'] as bool? ?? false,
        correction: (d['correction'] as num?)?.toDouble() ?? 0.0,
        offset: (d['offset'] as num?)?.toDouble() ?? 0.0,
        clipped: d['clipped'] as bool? ?? false,
        singleLine: d['singleLine'] as bool? ?? false,
        lineSide: (d['lineSide'] as num?)?.toInt() ?? 0,
      );
}

/// the indicator's state, fed one sample per carControlSP message
class LaneCenteringIndicator {
  // live: the bar only
  bool visible = false;
  bool active = false;   // correcting this frame (gates passed, not holding)
  double push = 0.0;     // smoothed, m/s^2
  Color color = laneCenteringMint;

  // latched, replaced whole every laneCenteringTextRefresh
  LaneCenteringState shownState = LaneCenteringState.gated;
  double shownPush = 0.0;
  double shownOffset = 0.0;
  Color shownColor = laneCenteringGray;
  bool shownSingleLine = false;
  int shownLineSide = 0;

  DateTime? _lastSample;
  DateTime _nextCommit = DateTime.fromMillisecondsSinceEpoch(0);
  final _counts = {for (final s in LaneCenteringState.values) s: 0};
  int _nValid = 0;
  int _nClipped = 0;
  int _nSingleLine = 0;
  int _sumLineSide = 0;
  double _sumPush = 0.0;
  double _sumOffset = 0.0;

  /// nothing to show: lane centering is off, or nothing is steering
  void hide() {
    visible = false;
  }

  void update(LaneCenteringSample lc, double vEgo, DateTime now) {
    final wasVisible = visible;
    visible = true;
    if (!wasVisible) {
      // nothing from before the indicator appeared is worth averaging into the first figure
      push = 0.0;
      _lastSample = null;
      _startWindow(DateTime.fromMillisecondsSinceEpoch(0));
    }

    active = lc.active && !lc.holding;

    final raw = lc.active ? lc.correction * vEgo * vEgo : 0.0;
    final last = _lastSample;
    final gap = last == null ? null : now.difference(last);
    if (gap == null || gap > _maxSmoothGap || gap.isNegative) {
      push = raw;
    } else {
      final dt = gap.inMicroseconds / 1e6;
      push += (raw - push) * dt / (laneCenteringSmoothTau + dt);
    }
    _lastSample = now;

    color = _barColor(lc);
    _sample(lc, raw);

    if (!now.isBefore(_nextCommit)) {
      _commitWindow();
      _startWindow(now.add(laneCenteringTextRefresh));
    }
  }

  /// live every frame, so a gate dropout of a few frames shows as a flash of gray; the
  /// One-Line Mode blue follows the latched summary, so it changes no faster than the words
  Color _barColor(LaneCenteringSample lc) {
    if (!lc.active) return laneCenteringGray;
    if (lc.clipped) return laneCenteringRed;
    if (push.abs() >= laneCenteringAmberAbove) return laneCenteringAmber;
    if (shownSingleLine) return laneCenteringLightBlue;
    if (lc.holding) return laneCenteringDimWhite;
    return laneCenteringMint;
  }

  void _startWindow(DateTime nextCommit) {
    _counts.updateAll((k, v) => 0);
    _nValid = 0;
    _nClipped = 0;
    _nSingleLine = 0;
    _sumLineSide = 0;
    _sumPush = 0.0;
    _sumOffset = 0.0;
    _nextCommit = nextCommit;
  }

  void _sample(LaneCenteringSample lc, double rawPush) {
    if (!lc.active) {
      _counts[LaneCenteringState.gated] = _counts[LaneCenteringState.gated]! + 1;
      return;
    }
    // push and offset only mean anything when the gates passed, so gated frames count for the
    // state but are kept out of both averages
    final s = lc.holding ? LaneCenteringState.holding : LaneCenteringState.correcting;
    _counts[s] = _counts[s]! + 1;
    _nValid++;
    if (lc.clipped) _nClipped++;
    if (lc.singleLine) {
      _nSingleLine++;
      _sumLineSide += lc.lineSide;
    }
    _sumPush += rawPush;
    _sumOffset += lc.offset;
  }

  void _commitWindow() {
    shownPush = _nValid > 0 ? _sumPush / _nValid : 0.0;
    shownOffset = _nValid > 0 ? _sumOffset / _nValid : 0.0;
    // whichever state held for most of the window (the first listed wins a tie, as on the device)
    var best = LaneCenteringState.gated;
    for (final s in LaneCenteringState.values) {
      if (_counts[s]! > _counts[best]!) best = s;
    }
    shownState = best;
    // One-Line Mode counts if it ran on most of the frames where the gates passed
    shownSingleLine = shownState != LaneCenteringState.gated && _nSingleLine * 2 > _nValid;
    shownLineSide = shownSingleLine ? _sumLineSide.sign : 0;

    if (shownState == LaneCenteringState.gated) {
      shownColor = laneCenteringGray;
    } else if (shownState == LaneCenteringState.holding) {
      shownColor = shownSingleLine ? laneCenteringLightBlue : laneCenteringDimWhite;
    } else if (_nClipped * 2 > _nValid) {
      shownColor = laneCenteringRed;
    } else if (shownPush.abs() >= laneCenteringAmberAbove) {
      shownColor = laneCenteringAmber;
    } else if (shownSingleLine) {
      shownColor = laneCenteringLightBlue;
    } else {
      shownColor = laneCenteringMint;
    }
  }

  /// the bar's fill, -1..1 of the scale
  double get barFraction => (push / laneCenteringFullScale).clamp(-1.0, 1.0).toDouble();

  /// the latched push, e.g. "0.21"
  String get pushText => shownPush.abs().toStringAsFixed(2);

  /// the latched distance off center as (amount, unit): ("12L", "cm"); ("", "on center") when
  /// there is no number to show; ("", "") when gated
  (String, String) offsetParts({required bool isMetric}) {
    if (shownState == LaneCenteringState.gated) return ('', '');
    final amount = shownOffset.abs() * (isMetric ? _mToCm : _mToIn);
    if (amount < 0.5) return ('', 'on center');
    // the reported offset is the error being closed, so the car sits on the far side of it
    final side = shownOffset > 0 ? 'L' : 'R';
    return ('${amount.round()}$side', isMetric ? 'cm' : 'in');
  }

  /// the word shown in place of the push when not correcting
  String get stateLabel {
    if (shownState == LaneCenteringState.gated) return 'no lines';
    return shownSingleLine ? 'clear of line' : 'centered';
  }
}

// -- drawing --

/// the bar, bent along the same arc as the Enhanced torque bar and in the same place
class LaneCenteringArcPainter extends CustomPainter {
  final LaneCenteringIndicator lc;
  final double unit;      // comma four pixels
  final double radius;    // the torque bar's radius
  final double spanDeg;   // the torque bar's span
  final double bottom;    // from the bottom of the screen to the arc's lower edge

  // repaint keys: the indicator is mutated in place
  final double _fraction;
  final bool _active;
  final Color _color;
  final int _lineSide;

  LaneCenteringArcPainter({
    required this.lc,
    required this.unit,
    required this.radius,
    required this.spanDeg,
    required this.bottom,
  })  : _fraction = lc.barFraction,
        _active = lc.active,
        _color = lc.color,
        _lineSide = lc.shownLineSide;

  static const thickness = 14.0;  // comma four pixels, the torque bar's resting thickness

  @override
  void paint(Canvas canvas, Size size) {
    if (!lc.visible) return;
    final t = thickness * unit;
    final r = radius * unit;
    final midR = r + t / 2;
    final center = Offset(size.width / 2, size.height + r - bottom);
    final arc = Rect.fromCircle(center: center, radius: midR);
    const top = -pi / 2;
    final halfSpan = spanDeg / 2 * pi / 180;

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = t
      ..strokeCap = StrokeCap.round;

    void arcPart(double start, double sweep, Color c) {
      final shadowCenter = center.translate(0.8 * unit, 0.8 * unit);
      canvas.drawArc(Rect.fromCircle(center: shadowCenter, radius: midR), start, sweep, false, stroke..color = _shadow);
      canvas.drawArc(arc, start, sweep, false, stroke..color = c);
    }

    // track: drawn without a shadow, as the torque bar's is
    canvas.drawArc(arc, top - halfSpan, 2 * halfSpan, false, stroke..color = _track);

    // a point on the arc's middle line, [a] radians from the top, [dr] further out
    Offset at(double a, [double dr = 0]) =>
        center + Offset(sin(a) * (midR + dr), -cos(a) * (midR + dr));

    // half scale graduations
    final tick = Paint()
      ..color = _graduation
      ..strokeWidth = max(1.0, t * 0.14);
    for (final f in const [-0.5, 0.5]) {
      final a = halfSpan * f;
      canvas.drawLine(at(a, -t * 0.28), at(a, t * 0.28), tick);
    }

    if (_active) {
      final sweep = halfSpan * _fraction;
      if (sweep.abs() * midR >= 1.0) arcPart(top, sweep, _color);
    } else {
      // a stub at the center: gray when gated, dim white while holding
      canvas.drawCircle(at(0), max(1.5 * unit, t * 0.28), Paint()..color = _color);
    }

    // the detent sits on top so the center stays readable at any fill
    canvas.drawLine(
      at(0, -t * 0.8),
      at(0, t * 0.8),
      Paint()
        ..color = _detent
        ..strokeWidth = max(2.0, t * 0.14),
    );

    if (_lineSide != 0) {
      // One-Line Mode: a painted line standing just beyond the end of the arc on its line's side
      final a = (halfSpan + (t * 0.9) / midR) * _lineSide;
      final mark = Paint()
        ..strokeWidth = max(3.0, t * 0.3)
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(at(a, -t).translate(0.8 * unit, 0.8 * unit), at(a, t).translate(0.8 * unit, 0.8 * unit),
          mark..color = _shadow);
      canvas.drawLine(at(a, -t), at(a, t), mark..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(LaneCenteringArcPainter old) =>
      old._fraction != _fraction ||
      old._active != _active ||
      old._color != _color ||
      old._lineSide != _lineSide ||
      old.lc.visible != lc.visible ||
      old.unit != unit ||
      old.bottom != bottom;
}

/// the bar straight, as in the device's full form
class LaneCenteringBarPainter extends CustomPainter {
  final LaneCenteringIndicator lc;

  final double _fraction;
  final bool _active;
  final Color _color;
  final int _lineSide;

  LaneCenteringBarPainter(this.lc)
      : _fraction = lc.barFraction,
        _active = lc.active,
        _color = lc.color,
        _lineSide = lc.shownLineSide;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    // room either side for the painted-line mark
    final markW = max(3.0, h * 0.3);
    final gap = max(4.0, h * 0.4);
    final inset = markW + gap;
    final x = inset, w = size.width - 2 * inset;
    final r = Radius.circular(h / 2);
    const s = Offset(3, 3);

    void pill(Rect rect, Color c, {bool shadow = true}) {
      if (shadow) canvas.drawRRect(RRect.fromRectAndRadius(rect.shift(s), r), Paint()..color = _shadow);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, r), Paint()..color = c);
    }

    pill(Rect.fromLTWH(x, 0, w, h), _track);

    final gradW = max(1.0, h * 0.14);
    for (final f in const [0.25, 0.75]) {
      canvas.drawRect(Rect.fromLTWH(x + w * f - gradW / 2, h * 0.22, gradW, h * 0.56), Paint()..color = _graduation);
    }

    final cx = x + w / 2;
    if (_active) {
      final span = _fraction * w / 2;
      if (span.abs() >= 1.0) {
        pill(Rect.fromLTWH(span >= 0 ? cx : cx + span, 0, span.abs(), h), _color, shadow: false);
      }
    } else {
      final stub = max(3.0, h * 0.28);
      pill(Rect.fromLTWH(cx - stub / 2, 0, stub, h), _color, shadow: false);
    }

    final detentW = max(2.0, h * 0.14);
    canvas.drawRect(Rect.fromLTWH(cx - detentW / 2, -h * 0.3, detentW, h * 1.6), Paint()..color = _detent);

    if (_lineSide != 0) {
      final mx = _lineSide > 0 ? x + w + gap : x - gap - markW;
      pill(Rect.fromLTWH(mx, -h * 0.5, markW, h * 2), Colors.white);
    }
  }

  @override
  bool shouldRepaint(LaneCenteringBarPainter old) =>
      old._fraction != _fraction || old._active != _active || old._color != _color || old._lineSide != _lineSide;
}

/// text with its own dark copy behind it, for drawing straight onto the road
Widget _shadowed(String text, double size, Color color, {Key? key}) {
  final style = TextStyle(fontSize: size, fontWeight: FontWeight.bold, height: 1.0, color: color);
  return Text(
    text,
    key: key,
    maxLines: 1,
    style: style.copyWith(shadows: [Shadow(color: _shadow, offset: Offset(size * 0.05, size * 0.05))]),
  );
}

/// a small right- or left-pointing triangle
class _ArrowPainter extends CustomPainter {
  final bool right;
  final Color color;

  const _ArrowPainter({required this.right, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    Path tri(Offset o) => Path()
      ..moveTo(o.dx + (right ? w : 0), o.dy + h / 2)
      ..lineTo(o.dx + (right ? w * 0.2 : w * 0.8), o.dy + h * 0.075)
      ..lineTo(o.dx + (right ? w * 0.2 : w * 0.8), o.dy + h * 0.925)
      ..close();
    canvas.drawPath(tri(Offset(w * 0.08, w * 0.08)), Paint()..color = _shadow);
    canvas.drawPath(tri(Offset.zero), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.right != right || old.color != color;
}

/// the latched figures in one row: arrow and push (or the state word) on the left, the
/// distance off center (or "one line") on the right. [size] is the height of the numbers
List<Widget> _figures(LaneCenteringIndicator lc, {required bool isMetric, required double size}) {
  final unitSize = size * 0.57;
  final left = <Widget>[];
  if (lc.shownState == LaneCenteringState.correcting) {
    left.addAll([
      SizedBox(
        width: size * 0.6,
        height: size * 0.65,
        child: CustomPaint(painter: _ArrowPainter(right: lc.shownPush >= 0, color: lc.shownColor)),
      ),
      SizedBox(width: size * 0.25),
      _shadowed(lc.pushText, size, lc.shownColor, key: const ValueKey('laneCenteringPush')),
      SizedBox(width: size * 0.19),
      _shadowed('m/s²', unitSize, Colors.white),
    ]);
  } else {
    final holding = lc.shownState == LaneCenteringState.holding;
    left.add(_shadowed(lc.stateLabel, size * 0.76, holding ? Colors.white : lc.shownColor,
        key: const ValueKey('laneCenteringState')));
  }

  final right = <Widget>[];
  if (lc.shownSingleLine) {
    right.add(_shadowed('one line', size * 0.76, laneCenteringLightBlue, key: const ValueKey('laneCenteringOneLine')));
  } else {
    final (amount, unit) = lc.offsetParts(isMetric: isMetric);
    if (amount.isNotEmpty) {
      right.addAll([
        _shadowed(amount, size, lc.shownColor, key: const ValueKey('laneCenteringOffset')),
        SizedBox(width: size * 0.19),
        _shadowed(unit, unitSize, Colors.white),
      ]);
    } else if (unit.isNotEmpty) {
      right.add(_shadowed(unit, size * 0.62, Colors.white, key: const ValueKey('laneCenteringOffset')));
    }
  }
  return [
    Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: left),
    Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: right),
  ];
}

/// the device's full form: the latched figures over the live straight bar. [scale] is the
/// Classic layout's, the comma 3X screen's 2160x1080 scaled to fit
class LaneCenteringPill extends StatelessWidget {
  final LaneCenteringIndicator lc;
  final bool isMetric;
  final double scale;

  const LaneCenteringPill({super.key, required this.lc, required this.isMetric, required this.scale});

  static const width = 630.0;
  static const height = 144.0;

  @override
  Widget build(BuildContext context) {
    if (!lc.visible) return const SizedBox.shrink();
    final figures = _figures(lc, isMetric: isMetric, size: 63 * scale);
    return SizedBox(
      key: const ValueKey('laneCenteringPill'),
      width: width * scale,
      height: height * scale,
      child: Column(
        children: [
          SizedBox(height: 18 * scale),
          SizedBox(
            height: 63 * scale,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 36 * scale),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.bottomLeft, child: figures[0])),
                  SizedBox(width: 12 * scale),
                  Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.bottomRight, child: figures[1])),
                ],
              ),
            ),
          ),
          const Spacer(),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 36 * scale - 18 * scale),
            child: SizedBox(
              height: 24 * scale,
              width: double.infinity,
              child: CustomPaint(painter: LaneCenteringBarPainter(lc)),
            ),
          ),
          SizedBox(height: 30 * scale),
        ],
      ),
    );
  }
}

/// one latched line of figures, for above the arc in the Enhanced layout. Each half keeps to
/// its own side of the centre line, [halfGap] clear of it, so a wide left half never crosses it
class LaneCenteringCaption extends StatelessWidget {
  final LaneCenteringIndicator lc;
  final bool isMetric;
  final double unit;  // comma four pixels

  static const halfGap = 14.0;

  const LaneCenteringCaption({super.key, required this.lc, required this.isMetric, required this.unit});

  @override
  Widget build(BuildContext context) {
    if (!lc.visible) return const SizedBox.shrink();
    final figures = _figures(lc, isMetric: isMetric, size: 11 * unit);
    return Row(
      key: const ValueKey('laneCenteringCaption'),
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: halfGap * unit),
            child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.bottomRight, child: figures[0]),
          ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(left: halfGap * unit),
            child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.bottomLeft, child: figures[1]),
          ),
        ),
      ],
    );
  }
}
