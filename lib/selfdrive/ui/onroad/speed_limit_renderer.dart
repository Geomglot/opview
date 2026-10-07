// speed limit sign — Vienna (metric) or MUTCD (imperial), offset badge, "ahead" box,
// and the +/- arrow while speed limit assist is waiting to apply.
// ported from sunnypilot selfdrive/ui/sunnypilot/onroad/speed_limit.py
//
// all layout at 1080p reference, scaled by screenHeight/1080.

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';

// -- constants (speed_limit.py, hud_renderer.py UI_CONFIG) --

const _setSpeedWidthMetric = 200.0;
const _setSpeedWidthImperial = 172.0;
const _setSpeedHeight = 204.0;
const _arrowSize = 200.0;
const _meterToFoot = 3.28084;
const _meterToMile = 0.000621371;

class SpeedLimitColors {
  static const white = Color(0xFFFFFFFF);
  static const black = Color(0xFF000000);
  static const red = Color(0xFFEB2020);
  static const grey = Color(0xFF919B95);
  static const darkGrey = Color(0xFF4D4D4D);
  static const subBg = Color(0xB4000000);
  static const mutcdLines = Color(0x64FFFFFF);
}

/// what the sign shows, worked out from UIState (speed_limit.py _draw_sign_main)
class SpeedLimitSign {
  final String value;
  final String offset;
  final Color textColor;
  final bool hasLimit;

  const SpeedLimitSign(this.value, this.offset, this.textColor, this.hasLimit);

  factory SpeedLimitSign.from(UIState st) {
    final conv = st.speedConv;
    final hasLimit = st.speedLimitValid || st.speedLimitLastValid;
    final speed = st.displaySpeed;
    final isOverspeed = hasLimit && (st.speedLimitFinalLast * conv).round() < speed.round();
    final warning = st.speedLimitMode >= speedLimitModeWarning;

    final value = hasLimit ? '${(st.speedLimitLast * conv).round()}' : '---';
    var offset = '';
    final off = st.speedLimitOffset * conv;
    if (off != 0) {
      offset = '${off > 0 ? '' : '-'}${off.abs().round()}';
    }

    var color = SpeedLimitColors.black;
    if (warning && isOverspeed) {
      color = SpeedLimitColors.red;
    } else if (!st.speedLimitValid) {
      color = SpeedLimitColors.grey;
    }
    return SpeedLimitSign(value, offset, color, hasLimit);
  }
}

/// AlertFadeAnimator: while assist is preActive, on for 0.75 s of every second then a quick fade
double preActiveAlpha(bool preActive, DateTime now) {
  if (!preActive) return 1.0;
  final phase = (now.millisecondsSinceEpoch % 1000) / 1000.0;
  if (phase < 0.75) return 1.0;
  return exp(-(phase - 0.75) / 0.05);
}

/// arrow asset while preActive: up if the set speed is below the limit, down if above
String? preActiveArrow(UIState st) {
  if (st.speedLimitAssistState != 'preActive' || !st.isCruiseSet) return null;
  final setRound = st.setSpeed.round();
  final limitRound = (st.speedLimitFinalLast * st.speedConv).round();
  if (setRound < limitRound) return 'assets/icons/img_plus_arrow_up.png';
  if (setRound > limitRound) return 'assets/icons/img_minus_arrow_down.png';
  return null;
}

/// distance label for the "ahead" box (speed_limit.py _format_dist)
String formatAheadDistance(double d, bool isMetric) {
  if (isMetric) {
    if (d < 50) return 'Near';
    if (d >= 1000) return '${(d / 1000).toStringAsFixed(1)} km';
    final rounded = d < 200 ? (d / 10).round() * 10 : (d / 100).round() * 100;
    return '$rounded m';
  }
  final ft = d * _meterToFoot;
  if (ft < 100) return 'Near';
  if (ft >= 900) return '${(d * _meterToMile).toStringAsFixed(1)} mi';
  if (ft < 500) return '${(ft / 50).round() * 50} ft';
  return '${(ft / 100).round() * 100} ft';
}

class SpeedLimitRenderer extends StatelessWidget {
  final UIState uiState;
  final double scale;

  const SpeedLimitRenderer({super.key, required this.uiState, required this.scale});

  @override
  Widget build(BuildContext context) {
    if (!uiState.showSpeedLimit) return const SizedBox.shrink();

    final st = uiState;
    final width = st.isMetric ? _setSpeedWidthMetric : _setSpeedWidthImperial;
    final signRect = Rect.fromLTWH(60 + width + 30 - 6, 45 - 6, width, _setSpeedHeight + 6 * 2);
    final preActive = st.speedLimitAssistState == 'preActive';
    final alpha = preActiveAlpha(preActive, DateTime.now());
    final arrow = preActive ? preActiveArrow(st) : null;

    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: SpeedLimitPainter(
              sign: SpeedLimitSign.from(st),
              rect: signRect,
              scale: scale,
              vienna: st.isMetric,
              alpha: alpha,
              ahead: preActive ? null : _aheadText(st),
              fontFamily: DefaultTextStyle.of(context).style.fontFamily,
            ),
          ),
        ),
        if (arrow != null)
          Positioned(
            left: (signRect.right + 12 * 1.4) * scale,
            top: (signRect.top + (signRect.height - _arrowSize) / 2) * scale,
            width: _arrowSize * scale,
            height: _arrowSize * scale,
            child: Opacity(opacity: alpha, child: Image.asset(arrow, fit: BoxFit.contain)),
          ),
      ],
    );
  }

  /// value and distance for the "ahead" box, or null when it should not show
  (String, String)? _aheadText(UIState st) {
    final conv = st.speedConv;
    final ahead = st.speedLimitAhead * conv;
    final valid = st.speedLimitAheadValid && ahead > 0 && ahead != st.speedLimit * conv;
    if (!(valid && st.speedLimitSource == 'map')) return null;
    return ('${ahead.round()}', formatAheadDistance(st.speedLimitAheadDistance, st.isMetric));
  }
}

class SpeedLimitPainter extends CustomPainter {
  final SpeedLimitSign sign;
  final Rect rect;      // 1080p reference units
  final double scale;
  final bool vienna;
  final double alpha;
  final (String, String)? ahead;
  final String? fontFamily;  // same font as the rest of the HUD

  SpeedLimitPainter({
    required this.sign,
    required this.rect,
    required this.scale,
    required this.vienna,
    required this.alpha,
    required this.ahead,
    this.fontFamily,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(scale);
    if (vienna) {
      _vienna(canvas);
    } else {
      _mutcd(canvas);
    }
    if (ahead != null) _ahead(canvas, ahead!);
    canvas.restore();
  }

  Color _a(Color c) => c.withValues(alpha: c.a * alpha);

  void _text(Canvas canvas, String text, double size, Offset center, Color color, FontWeight weight) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(fontFamily: fontFamily, color: color, fontSize: size, fontWeight: weight, height: 1.0)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  void _vienna(Canvas canvas) {
    final center = rect.center;
    final radius = (rect.width + 18) / 2;
    canvas.drawCircle(center, radius, Paint()..color = _a(SpeedLimitColors.white));
    // red ring from 0.75 r to r
    canvas.drawCircle(center, radius * 0.875, Paint()
      ..color = _a(SpeedLimitColors.red)
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 0.25);
    _text(canvas, sign.value, sign.value.length >= 3 ? 70 : 85, center, _a(sign.textColor), FontWeight.bold);

    if (sign.offset.isNotEmpty && sign.hasLimit) {
      final sr = radius * 0.4;
      final sc = Offset(rect.right - sr / 2, rect.top + sr / 2);
      canvas.drawCircle(sc, sr, Paint()..color = _a(SpeedLimitColors.black));
      canvas.drawCircle(sc, sr - 1.5, Paint()
        ..color = _a(SpeedLimitColors.darkGrey)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3);
      final fs = sign.offset.length < 3 ? 0.5 : 0.45;
      _text(canvas, sign.offset, sr * 2 * fs, sc, _a(SpeedLimitColors.white), FontWeight.bold);
    }
  }

  void _mutcd(Canvas canvas) {
    final outerRadius = 0.35 * rect.width / 2;
    canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(outerRadius)), Paint()..color = _a(SpeedLimitColors.white));
    final inner = rect.deflate(10);
    canvas.drawRRect(RRect.fromRectAndRadius(inner, Radius.circular(outerRadius - 10)), Paint()
      ..color = _a(SpeedLimitColors.black)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4);

    final midX = rect.center.dx;
    _text(canvas, 'SPEED', 40, Offset(midX, rect.top + 40), _a(SpeedLimitColors.black), FontWeight.w600);
    _text(canvas, 'LIMIT', 40, Offset(midX, rect.top + 80), _a(SpeedLimitColors.black), FontWeight.w600);
    _text(canvas, sign.value, 90, Offset(midX, rect.top + 150), _a(sign.textColor), FontWeight.bold);

    if (sign.offset.isNotEmpty && sign.hasLimit) {
      final box = rect.width * 0.3;
      final overlap = box * 0.2;
      final s = Rect.fromLTWH(rect.right - box / 1.5 + overlap, rect.top - box / 1.25 + overlap, box, box);
      final r = Radius.circular(0.35 * box / 2);
      canvas.drawRRect(RRect.fromRectAndRadius(s, r), Paint()..color = _a(SpeedLimitColors.black));
      canvas.drawRRect(RRect.fromRectAndRadius(s, r), Paint()
        ..color = _a(SpeedLimitColors.darkGrey)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6);
      final fs = sign.offset.length < 3 ? 0.6 : 0.475;
      _text(canvas, sign.offset, box * fs, s.center, _a(SpeedLimitColors.white), FontWeight.bold);
    }
  }

  void _ahead(Canvas canvas, (String, String) ahead) {
    final r = Rect.fromLTWH(rect.left + (rect.width - 170) / 2, rect.bottom + 10, 170, 160);
    final rr = RRect.fromRectAndRadius(r, const Radius.circular(0.35 * 160 / 2));
    canvas.drawRRect(rr, Paint()..color = SpeedLimitColors.subBg);
    canvas.drawRRect(rr, Paint()
      ..color = SpeedLimitColors.mutcdLines
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3);
    final midX = r.center.dx;
    _text(canvas, 'AHEAD', 40, Offset(midX, r.top + 28), SpeedLimitColors.grey, FontWeight.w600);
    _text(canvas, ahead.$1, 70, Offset(midX, r.top + 82), SpeedLimitColors.white, FontWeight.bold);
    _text(canvas, ahead.$2, 36, Offset(midX, r.top + 134), SpeedLimitColors.grey, FontWeight.normal);
  }

  @override
  bool shouldRepaint(SpeedLimitPainter old) =>
      old.sign.value != sign.value ||
      old.sign.offset != sign.offset ||
      old.sign.textColor != sign.textColor ||
      old.vienna != vienna ||
      old.alpha != alpha ||
      old.ahead != ahead ||
      old.scale != scale;
}
