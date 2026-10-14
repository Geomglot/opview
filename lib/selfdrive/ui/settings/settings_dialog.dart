// settings menu — opened by a long press on the driving display, or from the
// connecting screen. A dark panel in the style of the Enhanced layout's pills, in two
// columns: what the screen shows on the left (layout, speed limit, brightness), the
// comma, the road name and app updates on the right

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/app_settings.dart';
import 'package:opview/services/updater.dart';

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
  Updater? updater,
}) {
  final updates = updater ?? appUpdater;
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
              width: 430 * unit,
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(16 * unit, 13 * unit, 16 * unit, 11 * unit),
                child: ListenableBuilder(
                  listenable: Listenable.merge([settings, updates]),
                  builder: (context, _) => _SettingsBody(
                    settings: settings,
                    updater: updates,
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
  final Updater updater;
  final double unit;
  final String? host;
  final bool hostIsManual;
  final VoidCallback? onChangeHost;
  final VoidCallback onClose;
  final String? buildLabel;

  const _SettingsBody({
    required this.settings,
    required this.updater,
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

        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 11,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _label('LAYOUT'),
                  _choices<OnroadLayout>(OnroadLayout.values, settings.layout, onroadLayoutLabel, settings.setLayout),
                  _label('SPEED LIMIT'),
                  _choices<SpeedLimitDisplay>(
                    SpeedLimitDisplay.values,
                    settings.speedLimitDisplay,
                    speedLimitDisplayLabel,
                    settings.setSpeedLimitDisplay,
                  ),
                  _note('All layouts. Auto hides it until the comma has a speed limit'),
                  _label('BRIGHTNESS'),
                  _brightnessRow(),
                  _note('Auto follows the head unit. Set here, it applies while OPRivView is open'),
                ],
              ),
            ),
            SizedBox(width: 16 * unit),
            Expanded(
              flex: 10,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _label('COMMA DEVICE'),
                  _deviceRow(),
                  _label('ROAD NAME'),
                  _choices<bool>(const [true, false], settings.showRoadName, (v) => v ? 'Show' : 'Hide', settings.setShowRoadName),
                  _label('OPRIVVIEW UPDATES'),
                  _updatesRow(),
                ],
              ),
            ),
          ],
        ),

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

  /// a small rounded button; [primary] is white, for the one thing to do next
  Widget _button(String text, VoidCallback? onTap, {bool primary = false, Key? key}) {
    return InkWell(
      key: key,
      onTap: onTap,
      borderRadius: BorderRadius.circular(7 * unit),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10 * unit, vertical: 6 * unit),
        decoration: BoxDecoration(
          color: primary ? Colors.white : const Color(0x1FFFFFFF),
          borderRadius: BorderRadius.circular(7 * unit),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: primary ? const Color(0xFF111111) : Colors.white,
            fontSize: 10 * unit,
            fontWeight: primary ? FontWeight.bold : FontWeight.w600,
            height: 1.0,
          ),
        ),
      ),
    );
  }

  /// dim and bright suns either side of a slider, the value, and Auto (the slider greys out)
  Widget _brightnessRow() {
    final auto = settings.brightness == null;
    final value = settings.brightness ?? settings.manualBrightness;
    Widget sun(double size, double alpha) =>
        Icon(Icons.wb_sunny_outlined, size: size * unit, color: Colors.white.withValues(alpha: alpha));
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8 * unit, vertical: 3 * unit),
      decoration: BoxDecoration(color: _rowColor, borderRadius: BorderRadius.circular(9 * unit)),
      child: Row(
        children: [
          sun(9, 0.5),
          Expanded(
            child: Opacity(
              opacity: auto ? 0.4 : 1,
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 3 * unit,
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: const Color(0x2EFFFFFF),
                  thumbColor: Colors.white,
                  overlayShape: SliderComponentShape.noOverlay,
                  thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6 * unit),
                ),
                child: Slider(
                  key: const ValueKey('brightnessSlider'),
                  value: value,
                  min: minBrightness,
                  max: 1,
                  // moving the slider takes brightness off Auto
                  onChanged: (v) => settings.setBrightness(v),
                ),
              ),
            ),
          ),
          sun(12, 0.85),
          SizedBox(
            width: 30 * unit,
            child: Text(
              '${(value * 100).round()}%',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: Colors.white.withValues(alpha: auto ? 0.4 : 1),
                fontSize: 9.5 * unit,
                fontWeight: FontWeight.bold,
                height: 1.0,
              ),
            ),
          ),
          SizedBox(width: 6 * unit),
          _button('Auto', () => settings.setBrightness(auto ? settings.manualBrightness : null),
              primary: auto, key: const ValueKey('brightnessAuto')),
        ],
      ),
    );
  }

  /// installed version and Check; a newer release with Update and its notes; download progress
  Widget _updatesRow() {
    final u = updater;
    final release = u.latest;
    final titleStyle = TextStyle(color: Colors.white, fontSize: 10.5 * unit, fontWeight: FontWeight.w600, height: 1.0);
    final subStyle = TextStyle(color: _labelColor, fontSize: 8.5 * unit, height: 1.2);
    Widget title;
    String sub;
    Widget action;
    switch (u.status) {
      case UpdateStatus.idle:
        title = Text(u.installed, style: titleStyle, maxLines: 1, overflow: TextOverflow.ellipsis);
        sub = 'Installed';
        action = _button('Check', u.check, key: const ValueKey('updateCheck'));
      case UpdateStatus.checking:
        title = Text(u.installed, style: titleStyle, maxLines: 1, overflow: TextOverflow.ellipsis);
        sub = 'Checking GitHub…';
        action = _button('Check', null);
      case UpdateStatus.upToDate:
        title = Text(u.installed, style: titleStyle, maxLines: 1, overflow: TextOverflow.ellipsis);
        sub = 'Up to date';
        action = _button('Check', u.check, key: const ValueKey('updateCheck'));
      case UpdateStatus.available:
      case UpdateStatus.installing:
        title = Row(
          children: [
            Container(
              width: 6 * unit,
              height: 6 * unit,
              margin: EdgeInsets.only(right: 4 * unit),
              decoration: const BoxDecoration(color: Color(0xFF3ADB6D), shape: BoxShape.circle),
            ),
            Flexible(child: Text('Update available', style: titleStyle, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
        );
        sub = u.message.isNotEmpty ? u.message : (release?.version ?? '');
        action = _button('Update', u.status == UpdateStatus.installing ? null : u.downloadAndInstall,
            primary: true, key: const ValueKey('updateInstall'));
      case UpdateStatus.downloading:
        String mb(int b) => (b / 1048576).toStringAsFixed(1);
        final frac = u.total > 0 ? (u.received / u.total).clamp(0.0, 1.0).toDouble() : 0.0;
        title = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Downloading update', style: titleStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
            SizedBox(height: 4 * unit),
            ClipRRect(
              borderRadius: BorderRadius.circular(2 * unit),
              child: LinearProgressIndicator(
                value: frac,
                minHeight: 4 * unit,
                backgroundColor: const Color(0x26FFFFFF),
                color: Colors.white,
              ),
            ),
          ],
        );
        sub = u.total > 0 ? '${mb(u.received)} of ${mb(u.total)} MB' : '${mb(u.received)} MB';
        action = _button('Cancel', u.cancel, key: const ValueKey('updateCancel'));
      case UpdateStatus.failed:
        title = Text(u.installed, style: titleStyle, maxLines: 1, overflow: TextOverflow.ellipsis);
        sub = u.message;
        action = _button('Retry', u.check, key: const ValueKey('updateCheck'));
    }
    final notes = (u.status == UpdateStatus.available && release != null) ? releaseNoteLines(release.notes) : const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: const ValueKey('updatesRow'),
          padding: EdgeInsets.symmetric(horizontal: 10 * unit, vertical: 6 * unit),
          decoration: BoxDecoration(color: _rowColor, borderRadius: BorderRadius.circular(9 * unit)),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    title,
                    SizedBox(height: 3 * unit),
                    Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: subStyle),
                  ],
                ),
              ),
              SizedBox(width: 8 * unit),
              action,
            ],
          ),
        ),
        for (final line in notes)
          Padding(
            padding: EdgeInsets.fromLTRB(4 * unit, 4 * unit, 0, 0),
            child: Text('• $line',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: const Color(0xFFBDBDBD), fontSize: 8 * unit)),
          ),
      ],
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
