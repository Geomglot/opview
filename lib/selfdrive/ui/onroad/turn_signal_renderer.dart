// turn signal arrows and blind spot warnings, either side of the top centre
// ported from sunnypilot selfdrive/ui/sunnypilot/onroad/turn_signal.py
//
// all layout at 1080p reference, scaled by screenHeight/1080.

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';

// -- constants (turn_signal.py TurnSignalConfig, mici alert_renderer.py) --

const _offsetX = 80.0;
const _offsetY = 190.0;
const _boxSize = 150.0;
const _iconWidth = 120.0;
const _iconHeight = 109.0;
const turnSignalBlinkPeriod = 60 / 80; // seconds, 80 beats a minute
const _fadeTau = 0.3;                   // seconds
const _dimAlpha = 0.2;

/// what one side shows (turn_signal.py TurnSignalController._update_signal)
enum TurnSignalKind { blindSpot, signal }

TurnSignalKind? turnSignalKind({
  required bool showBlindSpot,
  required bool blindspot,
  required bool showTurnSignals,
  required bool blinker,
}) {
  if (showBlindSpot && blindspot) return TurnSignalKind.blindSpot;
  if (showTurnSignals && blinker) return TurnSignalKind.signal;
  return null;
}

/// arrow brightness [elapsed] seconds after it came on: full at the start of each
/// blink period, then fading towards dim (the device's first-order filter)
double turnSignalAlpha(double elapsed) {
  final t = elapsed % turnSignalBlinkPeriod;
  final a = _dimAlpha + (2 - _dimAlpha) * exp(-t / _fadeTau);
  return min(a, 1.0);
}

class TurnSignalRenderer extends StatelessWidget {
  final UIState uiState;
  final double scale;

  const TurnSignalRenderer({super.key, required this.uiState, required this.scale});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    if (!st.showTurnSignals && !st.showBlindSpot) return const SizedBox.shrink();
    final now = DateTime.now();

    return LayoutBuilder(builder: (context, constraints) {
      final midX = constraints.maxWidth / 2;
      return Stack(children: [
        _side(midX - (_offsetX + _boxSize) * scale, false, now,
            turnSignalKind(showBlindSpot: st.showBlindSpot, blindspot: st.leftBlindspot,
                showTurnSignals: st.showTurnSignals, blinker: st.leftBlinker),
            st.leftSignalSince),
        _side(midX + _offsetX * scale, true, now,
            turnSignalKind(showBlindSpot: st.showBlindSpot, blindspot: st.rightBlindspot,
                showTurnSignals: st.showTurnSignals, blinker: st.rightBlinker),
            st.rightSignalSince),
      ]);
    });
  }

  Widget _side(double left, bool flip, DateTime now, TurnSignalKind? kind, DateTime? since) {
    if (kind == null) return const SizedBox.shrink();
    final alpha = kind == TurnSignalKind.signal && since != null
        ? turnSignalAlpha(now.difference(since).inMilliseconds / 1000.0)
        : 1.0;
    final asset = kind == TurnSignalKind.blindSpot
        ? 'assets/icons/blind_spot_left.png'
        : 'assets/icons/turn_signal_left.png';
    return Positioned(
      left: left,
      top: _offsetY * scale,
      width: _boxSize * scale,
      height: _boxSize * scale,
      child: Center(
        child: Opacity(
          opacity: alpha,
          child: Transform.flip(
            flipX: flip,
            child: Image.asset(asset, width: _iconWidth * scale, height: _iconHeight * scale, fit: BoxFit.fill),
          ),
        ),
      ),
    );
  }
}
