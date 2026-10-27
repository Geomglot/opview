// the bottom bar: the torque bar, the lane centering indicator, or nothing, chosen per layout
// (AppSettings.bottomBars); a tap at the bottom centre of the screen moves to the next choice

import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/onroad/enhanced/enhanced_layout.dart';
import 'package:opview/selfdrive/ui/onroad/lane_centering.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';

/// what a bottom bar choice draws right now
enum BottomBarShown { torque, laneCentering, none }

BottomBarShown shownBottomBar(BottomBar choice, UIState st) {
  switch (choice) {
    case BottomBar.torque:
      return BottomBarShown.torque;
    case BottomBar.laneCentering:
      return BottomBarShown.laneCentering;
    case BottomBar.auto:
      return st.laneCenteringAvailable ? BottomBarShown.laneCentering : BottomBarShown.torque;
    case BottomBar.off:
      return BottomBarShown.none;
  }
}

/// from the bottom of the screen to the lower edge of the arc: where the torque bar rests
double bottomArcBottom(double unit) => (22 + enhancedBorderWidth) * unit;

/// a tap here moves to the next bottom bar choice: the middle half of the width, the bottom
/// [bottomBarTapHeight] of the height
const bottomBarTapWidth = 0.5;
const bottomBarTapHeight = 0.22;

bool inBottomBarTapZone(Offset p, Size screen) =>
    (p.dx - screen.width / 2).abs() <= screen.width * bottomBarTapWidth / 2 &&
    p.dy >= screen.height * (1 - bottomBarTapHeight);

/// the arc at the bottom centre: the torque bar or the lane centering indicator
class BottomArc extends StatelessWidget {
  final UIState uiState;
  final BottomBar choice;
  final double unit;  // comma four pixels

  const BottomArc({super.key, required this.uiState, required this.choice, required this.unit});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    switch (shownBottomBar(choice, st)) {
      case BottomBarShown.torque:
        return CustomPaint(
          key: const ValueKey('bottomTorqueBar'),
          painter: EnhancedTorqueBarPainter(value: st.torqueBarValue, status: st.status, unit: unit),
        );
      case BottomBarShown.laneCentering:
        return CustomPaint(
          key: const ValueKey('bottomLaneCentering'),
          painter: LaneCenteringArcPainter(
            lc: st.laneCentering,
            unit: unit,
            radius: enhancedTorqueRadius,
            spanDeg: enhancedTorqueAngleSpanDeg,
            bottom: bottomArcBottom(unit),
          ),
        );
      case BottomBarShown.none:
        return const SizedBox.shrink();
    }
  }
}

/// the bottom bar's new choice for a moment after a tap, with a dot for each choice
class BottomBarPill extends StatelessWidget {
  final BottomBar choice;
  final double unit;  // comma four pixels

  const BottomBarPill({super.key, required this.choice, required this.unit});

  @override
  Widget build(BuildContext context) {
    const order = BottomBar.values;
    final i = order.indexOf(choice);
    return Container(
      key: const ValueKey('bottomBarPill'),
      padding: EdgeInsets.fromLTRB(16 * unit, 7 * unit, 16 * unit, 8 * unit),
      decoration: BoxDecoration(
        color: const Color(0xE0101010),
        borderRadius: BorderRadius.circular(14 * unit),
        boxShadow: [BoxShadow(color: const Color(0x73000000), blurRadius: 20 * unit, offset: Offset(0, 4 * unit))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'BOTTOM BAR',
            style: TextStyle(
              color: const Color(0xFF9A9A9A),
              fontSize: 7 * unit,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.6 * unit,
              height: 1.0,
            ),
          ),
          SizedBox(height: 4 * unit),
          Text(
            bottomBarLabel(choice),
            style: TextStyle(color: Colors.white, fontSize: 15 * unit, fontWeight: FontWeight.bold, height: 1.0),
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
