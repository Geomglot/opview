// steering wheel / experimental mode button, top right (display only, not tappable)
// ported from openpilot selfdrive/ui/onroad/exp_button.py with the sunnypilot
// Rivian angle/torque tint from selfdrive/ui/sunnypilot/onroad/lateral_mode.py
//
// all layout at 1080p reference, scaled by screenHeight/1080.

import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';

const _borderSize = 30.0;
const _buttonSize = 192.0;
const _iconSize = 144.0;

const angleColor = Color(0xFF3ADB6D);   // green
const torqueColor = Color(0xFF4D9DFF);  // blue

/// tint for the wheel, or null when MADS is not steering an angle-capable Rivian
Color? wheelTint(LateralMode? mode) => switch (mode) {
      LateralMode.angle => angleColor,
      LateralMode.torque => torqueColor,
      null => null,
    };

class ExpButton extends StatelessWidget {
  final UIState uiState;
  final double scale;

  const ExpButton({super.key, required this.uiState, required this.scale});

  @override
  Widget build(BuildContext context) {
    final exp = uiState.experimentalMode;
    final alpha = (uiState.engageable || uiState.enabled) ? 255 : 180;
    final tint = wheelTint(uiState.lateralMode);
    final iconColor = (tint != null && !exp ? tint : Colors.white).withAlpha(alpha);
    final size = _buttonSize * scale;

    return Positioned(
      top: _borderSize * scale,
      right: _borderSize * scale,
      width: size,
      height: size,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xA6000000),
          // tinting the coloured experimental icon is invisible, so it gets a ring instead
          border: tint != null && exp ? Border.all(color: tint.withAlpha(alpha), width: 8 * scale) : null,
        ),
        alignment: Alignment.center,
        child: Image.asset(
          exp ? 'assets/icons/experimental.png' : 'assets/icons/chffr_wheel.png',
          width: _iconSize * scale,
          height: _iconSize * scale,
          color: iconColor,
          colorBlendMode: BlendMode.modulate,
        ),
      ),
    );
  }
}
