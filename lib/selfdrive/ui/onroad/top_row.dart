// top row shared by the Enhanced and Detailed layouts: set speed | speed | speed limit
//
// sizes are in comma four pixels, scaled by `unit`

import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/onroad/hud_renderer.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';

const topRowSpeedPillHeight = 52.0;
const topRowSidePillWidth = 84.0;   // set speed and speed limit
const topRowSidePillHeight = 40.0;
const roadNamePillHeight = 16.0;  // under the speed, Enhanced and Detailed
const roadNameGap = 4.0;          // between the speed pill and the road name

const _limitPillColor = Color(0xDBCED0D2);  // soft grey-white
const _limitTextColor = Color(0xFF1A1A1A);
const _limitLabelColor = Color(0xFF555555);

/// distance to the next speed limit: "0.4 mi" / "650 ft", or "0.6 km" / "350 m"
String formatNextLimitDistance(double metres, bool isMetric) {
  if (isMetric) {
    return metres >= 1000 ? '${(metres / 1000).toStringAsFixed(1)} km' : '${(metres / 50).round() * 50} m';
  }
  final miles = metres / 1609.344;
  return miles >= 0.1 ? '${miles.toStringAsFixed(1)} mi' : '${(metres * 3.28084 / 50).round() * 50} ft';
}

/// the speed limit to show, in m/s, or null when there is none
double? speedLimitToShow(UIState st) {
  if (st.speedLimitValid && st.speedLimit > 0) return st.speedLimit;
  if (st.speedLimitLastValid && st.speedLimitLast > 0) return st.speedLimitLast;
  return null;
}

/// set speed | speed | speed limit, with the speed centred and the tops of the
/// three pills in line
class SpeedTopRow extends StatelessWidget {
  final UIState uiState;
  final double unit;
  final SpeedLimitDisplay speedLimitDisplay;

  const SpeedTopRow({super.key, required this.uiState, required this.unit, this.speedLimitDisplay = SpeedLimitDisplay.auto});

  @override
  Widget build(BuildContext context) {
    final st = uiState;
    final gap = SizedBox(width: 8 * unit);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.topRight,
            child: st.isCruiseAvailable ? _setSpeed() : const SizedBox.shrink(),
          ),
        ),
        gap,
        _speed(),
        gap,
        Expanded(
          child: Align(
            alignment: Alignment.topLeft,
            child: st.speedLimitVisible(speedLimitDisplay) ? _limit() : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  Widget _box({Key? key, Color color = const Color(0xB3141414), required Widget child}) {
    return Container(
      key: key,
      width: topRowSidePillWidth * unit,
      height: topRowSidePillHeight * unit,
      padding: EdgeInsets.symmetric(horizontal: 10 * unit),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12 * unit)),
      child: FittedBox(fit: BoxFit.scaleDown, child: child),
    );
  }

  Widget _speed() {
    return Container(
      height: topRowSpeedPillHeight * unit,
      constraints: BoxConstraints(minWidth: 74 * unit),
      padding: EdgeInsets.symmetric(horizontal: 12 * unit),
      decoration: BoxDecoration(color: const Color(0xB3141414), borderRadius: BorderRadius.circular(12 * unit)),
      child: Center(
        widthFactor: 1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${uiState.displaySpeed.round()}',
              style: TextStyle(color: HudColors.white, fontSize: 33 * unit, fontWeight: FontWeight.bold, height: 0.95),
            ),
            Text(
              uiState.isMetric ? 'km/h' : 'mph',
              style: TextStyle(color: HudColors.grey, fontSize: 11 * unit, fontWeight: FontWeight.w600, height: 1.0),
            ),
          ],
        ),
      ),
    );
  }

  Widget _setSpeed() {
    final st = uiState;
    Color maxColor = HudColors.grey;
    Color speedColor = HudColors.grey;
    if (st.isCruiseSet) {
      speedColor = HudColors.white;
      if (st.status == UIStatus.engaged) {
        maxColor = HudColors.engaged;
      } else if (st.status == UIStatus.disengaged) {
        maxColor = HudColors.disengaged;
      } else if (st.status == UIStatus.override_) {
        maxColor = HudColors.override_;
      }
    }
    return _box(
      key: const ValueKey('topRowSetSpeed'),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text('MAX', style: TextStyle(color: maxColor, fontSize: 11 * unit, fontWeight: FontWeight.w600, height: 1.0)),
          SizedBox(width: 5 * unit),
          Text(
            st.isCruiseSet ? '${st.setSpeed.round()}' : '–',
            style: TextStyle(color: speedColor, fontSize: 24 * unit, fontWeight: FontWeight.bold, height: 1.0),
          ),
        ],
      ),
    );
  }

  /// the mirror of the set speed pill, light like a road sign: the limit then a small
  /// LIMIT, and the next limit underneath when one is coming up
  Widget _limit() {
    final st = uiState;
    final limit = speedLimitToShow(st);
    final hasNext = limit != null && st.speedLimitAheadValid && st.speedLimitAhead > 0 && st.speedLimitAheadDistance > 0;
    final labelStyle = TextStyle(color: _limitLabelColor, fontSize: 10 * unit, fontWeight: FontWeight.w600, height: 1.0);
    final pill = _box(
      color: _limitPillColor,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                limit != null ? '${(limit * st.speedConv).round()}' : '– –',
                style: TextStyle(color: _limitTextColor, fontSize: (hasNext ? 22 : 24) * unit, fontWeight: FontWeight.bold, height: 1.0),
              ),
              SizedBox(width: 5 * unit),
              Text('LIMIT', style: labelStyle),
            ],
          ),
          if (hasNext) ...[
            SizedBox(height: 2.5 * unit),
            Text.rich(
              TextSpan(children: [
                const TextSpan(text: 'next '),
                TextSpan(
                  text: '${(st.speedLimitAhead * st.speedConv).round()}',
                  style: const TextStyle(color: _limitTextColor, fontWeight: FontWeight.bold),
                ),
                TextSpan(text: ' in ${formatNextLimitDistance(st.speedLimitAheadDistance, st.isMetric)}'),
              ]),
              key: const ValueKey('topRowNextLimit'),
              style: TextStyle(color: _limitLabelColor, fontSize: 5.6 * unit, fontWeight: FontWeight.w600, height: 1.0),
            ),
          ],
        ],
      ),
    );
    // a thin dark line just inside the edge, like the border of a speed limit sign
    return Stack(
      key: const ValueKey('topRowSpeedLimit'),
      children: [
        pill,
        Positioned.fill(
          child: IgnorePointer(
            child: Padding(
              padding: EdgeInsets.all(2.5 * unit),
              child: DecoratedBox(
                key: const ValueKey('topRowSpeedLimitOutline'),
                decoration: BoxDecoration(
                  border: Border.all(color: _limitTextColor, width: 1.1 * unit),
                  borderRadius: BorderRadius.circular(9.5 * unit),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}


/// the road name under the speed: small and see-through, so it stays secondary to the speed
class RoadNamePill extends StatelessWidget {
  final String name;
  final double unit;
  final double maxWidth;

  const RoadNamePill({super.key, required this.name, required this.unit, required this.maxWidth});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      key: const ValueKey('roadNamePill'),
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        height: roadNamePillHeight * unit,
        padding: EdgeInsets.symmetric(horizontal: 7 * unit),
        decoration: BoxDecoration(color: const Color(0x80141414), borderRadius: BorderRadius.circular(8 * unit)),
        child: Center(
          widthFactor: 1,
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: const Color(0xB3FFFFFF), fontSize: 9 * unit, fontWeight: FontWeight.w600, height: 1.0),
          ),
        ),
      ),
    );
  }
}
