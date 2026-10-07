// road name pill, top centre
// ported from sunnypilot selfdrive/ui/sunnypilot/onroad/road_name.py
//
// all layout at 1080p reference, scaled by screenHeight/1080.

import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';

class RoadNameRenderer extends StatelessWidget {
  final UIState uiState;
  final double scale;

  const RoadNameRenderer({super.key, required this.uiState, required this.scale});

  @override
  Widget build(BuildContext context) {
    if (!uiState.showRoadName) return const SizedBox.shrink();

    return Positioned(
      top: -4 * scale,
      left: 0,
      right: 0,
      child: Center(
        child: LayoutBuilder(builder: (context, constraints) {
          return Container(
            height: 60 * scale,
            constraints: BoxConstraints(minWidth: 200 * scale, maxWidth: constraints.maxWidth - 40 * scale),
            padding: EdgeInsets.symmetric(horizontal: 20 * scale),
            decoration: BoxDecoration(
              color: const Color(0x78000000),
              borderRadius: BorderRadius.circular(6 * scale),
            ),
            child: Center(
              widthFactor: 1,
              child: Text(
                uiState.roadName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: const Color(0xC8FFFFFF),
                  fontSize: 46 * scale,
                  fontWeight: FontWeight.w600,
                  height: 1.0,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
