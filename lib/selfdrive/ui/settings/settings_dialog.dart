// settings menu — opened by a long press on the driving display, or from the
// connecting screen. A dark panel in the style of the Enhanced layout's pills:
// one row of buttons per setting, with the current choice highlighted

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';

const _panelColor = Color(0xF7161616);
const _rowColor = Color(0x12FFFFFF);
const _labelColor = Color(0xFFA6A6A6);

/// [host] is the comma's address, if known, and [hostIsManual] whether it was typed
/// in; [onChangeHost] opens the address prompt. [build] names the installed build
Future<void> showSettingsDialog(
  BuildContext context,
  AppSettings settings, {
  String? host,
  bool hostIsManual = false,
  VoidCallback? onChangeHost,
  String? build,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      // sized like the Enhanced layout: in comma four pixels, scaled to the screen
      final screen = MediaQuery.sizeOf(dialogContext);
      final unit = min(screen.height / 240.0, screen.width / 536.0);
      return Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: screen.height * 0.94),
          child: Material(
            color: _panelColor,
            borderRadius: BorderRadius.circular(14 * unit),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: 270 * unit,
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(16 * unit, 13 * unit, 16 * unit, 11 * unit),
                child: ListenableBuilder(
                  listenable: settings,
                  builder: (context, _) => _SettingsBody(
                    settings: settings,
                    unit: unit,
                    host: host,
                    hostIsManual: hostIsManual,
                    onChangeHost: onChangeHost == null
                        ? null
                        : () {
                            Navigator.of(dialogContext).pop();
                            onChangeHost();
                          },
                    onClose: () => Navigator.of(dialogContext).pop(),
                    buildLabel: build,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _SettingsBody extends StatelessWidget {
  final AppSettings settings;
  final double unit;
  final String? host;
  final bool hostIsManual;
  final VoidCallback? onChangeHost;
  final VoidCallback onClose;
  final String? buildLabel;

  const _SettingsBody({
    required this.settings,
    required this.unit,
    required this.host,
    required this.hostIsManual,
    required this.onChangeHost,
    required this.onClose,
    required this.buildLabel,
  });

  @override
  Widget build(BuildContext context) {
    final buildName = buildLabel;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Settings',
                style: TextStyle(color: Colors.white, fontSize: 15 * unit, fontWeight: FontWeight.bold, height: 1.0),
              ),
            ),
            InkWell(
              onTap: onClose,
              customBorder: const CircleBorder(),
              child: Container(
                width: 20 * unit,
                height: 20 * unit,
                decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0x1AFFFFFF)),
                child: Icon(Icons.close, color: const Color(0xD9FFFFFF), size: 13 * unit, semanticLabel: 'Close'),
              ),
            ),
          ],
        ),

        _label('LAYOUT'),
        _choices<OnroadLayout>(OnroadLayout.values, settings.layout, onroadLayoutLabel, settings.setLayout),

        _label('SPEED LIMIT'),
        _choices<SpeedLimitDisplay>(
          SpeedLimitDisplay.values,
          settings.speedLimitDisplay,
          speedLimitDisplayLabel,
          settings.setSpeedLimitDisplay,
        ),
        _note('All layouts. Auto hides it until the comma has a speed limit (maps or the car)'),

        _label('ROAD NAME'),
        _choices<bool>(const [true, false], settings.showRoadName, (v) => v ? 'Show' : 'Hide', settings.setShowRoadName),
        _note("All layouts, whatever the comma's own setting. Needs the comma's downloaded maps"),

        _label('COMMA DEVICE'),
        _deviceRow(),

        if (buildName != null)
          Padding(
            padding: EdgeInsets.only(top: 9 * unit),
            child: Text(
              'OPRivView · $buildName',
              textAlign: TextAlign.center,
              style: TextStyle(color: const Color(0x66FFFFFF), fontSize: 8 * unit, height: 1.0),
            ),
          ),
      ],
    );
  }

  Widget _label(String text) {
    return Padding(
      padding: EdgeInsets.fromLTRB(2 * unit, 9 * unit, 0, 4 * unit),
      child: Text(
        text,
        style: TextStyle(
          color: _labelColor,
          fontSize: 8.5 * unit,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5 * unit,
          height: 1.0,
        ),
      ),
    );
  }

  Widget _note(String text) {
    return Padding(
      padding: EdgeInsets.fromLTRB(2 * unit, 4 * unit, 0, 0),
      child: Text(text, style: TextStyle(color: const Color(0x80FFFFFF), fontSize: 7.5 * unit, height: 1.2)),
    );
  }

  /// one row of buttons; the current choice is the white one
  Widget _choices<T>(List<T> values, T current, String Function(T) labelOf, void Function(T) onPick) {
    return Container(
      padding: EdgeInsets.all(3 * unit),
      decoration: BoxDecoration(color: _rowColor, borderRadius: BorderRadius.circular(9 * unit)),
      child: Row(
        children: [
          for (final value in values)
            Expanded(
              child: InkWell(
                onTap: () => onPick(value),
                borderRadius: BorderRadius.circular(7 * unit),
                child: Container(
                  height: 24 * unit,
                  padding: EdgeInsets.symmetric(horizontal: 4 * unit),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: value == current ? Colors.white : null,
                    borderRadius: BorderRadius.circular(7 * unit),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      labelOf(value),
                      maxLines: 1,
                      style: TextStyle(
                        color: value == current ? const Color(0xFF111111) : const Color(0xCCFFFFFF),
                        fontSize: 10.5 * unit,
                        fontWeight: value == current ? FontWeight.bold : FontWeight.w500,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// the comma's address, how it was found, and a button to change it
  Widget _deviceRow() {
    final address = host;
    final change = onChangeHost;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10 * unit, vertical: 6 * unit),
      decoration: BoxDecoration(color: _rowColor, borderRadius: BorderRadius.circular(9 * unit)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  address ?? 'Not found yet',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white, fontSize: 10.5 * unit, fontWeight: FontWeight.w600, height: 1.0),
                ),
                SizedBox(height: 3 * unit),
                Text(
                  address == null ? 'searching the network' : (hostIsManual ? 'entered by hand' : 'found automatically'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _labelColor, fontSize: 8.5 * unit, height: 1.0),
                ),
              ],
            ),
          ),
          if (change != null)
            InkWell(
              onTap: change,
              borderRadius: BorderRadius.circular(7 * unit),
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 10 * unit, vertical: 6 * unit),
                decoration: BoxDecoration(
                  color: const Color(0x1FFFFFFF),
                  borderRadius: BorderRadius.circular(7 * unit),
                ),
                child: Text(
                  'Change',
                  style: TextStyle(color: Colors.white, fontSize: 10 * unit, fontWeight: FontWeight.w600, height: 1.0),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
