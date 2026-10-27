// app settings — viewer-side choices that live on this device, not on the comma
// stored with shared_preferences

import 'package:flutter/foundation.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/system_service.dart' as system;
import 'package:shared_preferences/shared_preferences.dart';

/// clock on the driving display
enum ClockMode { off, system, h12, h24 }

/// speed limit choices, in the order the settings menu offers them
String speedLimitDisplayLabel(SpeedLimitDisplay d) {
  switch (d) {
    case SpeedLimitDisplay.auto:
      return 'Auto';
    case SpeedLimitDisplay.always:
      return 'Always';
    case SpeedLimitDisplay.off:
      return 'Off';
  }
}

/// which driving display to draw
enum OnroadLayout { classic, enhanced, detailed }

String onroadLayoutLabel(OnroadLayout layout) {
  switch (layout) {
    case OnroadLayout.classic:
      return 'Classic';
    case OnroadLayout.enhanced:
      return 'Enhanced';
    case OnroadLayout.detailed:
      return 'Detailed';
  }
}

/// what sits at the bottom centre of a layout. Auto: lane centering while it is turned on in
/// the comma's settings, the torque bar otherwise
enum BottomBar { torque, laneCentering, auto, off }

String bottomBarLabel(BottomBar b) {
  switch (b) {
    case BottomBar.torque:
      return 'Torque';
    case BottomBar.laneCentering:
      return 'Lane centering';
    case BottomBar.auto:
      return 'Auto';
    case BottomBar.off:
      return 'Off';
  }
}

/// what each layout showed before the choice existed: Classic had no torque bar
const defaultBottomBars = {
  OnroadLayout.classic: BottomBar.off,
  OnroadLayout.enhanced: BottomBar.torque,
  OnroadLayout.detailed: BottomBar.torque,
};

/// the next choice for a tap on the bottom bar, wrapping round
BottomBar nextBottomBar(BottomBar b) => BottomBar.values[(b.index + 1) % BottomBar.values.length];

/// what the Enhanced layout was saved as before it was renamed
const _legacyLayoutNames = {'miciExtended': OnroadLayout.enhanced};

const _layoutKey = 'onroad_layout';
const _speedLimitKey = 'speed_limit_display';
const _collapsedKey = 'detailed_collapsed_panels';
const _roadNameKey = 'show_road_name';
const _brightnessKey = 'screen_brightness';
const _pipKey = 'picture_in_picture';
String _bottomBarKey(OnroadLayout layout) => 'bottom_bar_${layout.name}';

/// the dimmest the brightness slider goes: still readable at night
const minBrightness = 0.05;

class AppSettings extends ChangeNotifier {
  /// the clock is always shown, in 12 hour time; no longer a setting
  ClockMode clockMode = ClockMode.h12;
  OnroadLayout layout = OnroadLayout.classic;
  SpeedLimitDisplay speedLimitDisplay = SpeedLimitDisplay.auto;

  /// the road name pill, whatever the comma's own road name setting
  bool showRoadName = true;

  /// shrink to a floating window on Home while connected; off: Home stops the stream as before
  bool pictureInPicture = true;

  /// this app's screen brightness while it is open, 0.05..1; null follows the head unit
  double? brightness;

  /// the last brightness set by hand, for the slider while Auto is on
  double manualBrightness = 0.6;

  /// the bottom bar choice for each layout
  final Map<OnroadLayout, BottomBar> bottomBars = Map.of(defaultBottomBars);

  BottomBar bottomBarFor(OnroadLayout layout) => bottomBars[layout] ?? defaultBottomBars[layout]!;

  /// Detailed panels the driver has tapped shut, by name
  final Set<String> collapsedPanels = {};

  /// read saved settings; unknown or missing values keep the defaults
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    speedLimitDisplay = _byName(SpeedLimitDisplay.values, prefs.getString(_speedLimitKey), SpeedLimitDisplay.auto);
    showRoadName = prefs.getBool(_roadNameKey) ?? true;
    pictureInPicture = prefs.getBool(_pipKey) ?? true;
    final savedBrightness = prefs.getDouble(_brightnessKey);
    brightness = savedBrightness == null || savedBrightness < 0 ? null : savedBrightness.clamp(minBrightness, 1.0).toDouble();
    if (savedBrightness != null && savedBrightness >= 0) manualBrightness = brightness!;
    system.setAppBrightness(brightness);
    collapsedPanels
      ..clear()
      ..addAll(prefs.getStringList(_collapsedKey) ?? const []);
    for (final l in OnroadLayout.values) {
      bottomBars[l] = _byName(BottomBar.values, prefs.getString(_bottomBarKey(l)), defaultBottomBars[l]!);
    }
    final savedLayout = prefs.getString(_layoutKey);
    layout = _legacyLayoutNames[savedLayout] ?? _byName(OnroadLayout.values, savedLayout, OnroadLayout.classic);
    notifyListeners();
  }

  Future<void> setSpeedLimitDisplay(SpeedLimitDisplay value) async {
    if (value == speedLimitDisplay) return;
    speedLimitDisplay = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_speedLimitKey, value.name);
  }

  /// [value] null: follow the head unit's brightness (Auto)
  Future<void> setBrightness(double? value) async {
    final v = value?.clamp(minBrightness, 1.0).toDouble();
    if (v == brightness) return;
    brightness = v;
    if (v != null) manualBrightness = v;
    notifyListeners();
    system.setAppBrightness(v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_brightnessKey, v ?? -1);
  }

  Future<void> setShowRoadName(bool value) async {
    if (value == showRoadName) return;
    showRoadName = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_roadNameKey, value);
  }

  Future<void> setPictureInPicture(bool value) async {
    if (value == pictureInPicture) return;
    pictureInPicture = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_pipKey, value);
  }

  /// open a collapsed Detailed panel, or collapse an open one
  Future<void> togglePanel(String name) async {
    if (!collapsedPanels.remove(name)) collapsedPanels.add(name);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_collapsedKey, collapsedPanels.toList()..sort());
  }

  Future<void> setBottomBar(OnroadLayout layout, BottomBar value) async {
    if (value == bottomBarFor(layout)) return;
    bottomBars[layout] = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_bottomBarKey(layout), value.name);
  }

  Future<void> setLayout(OnroadLayout value) async {
    if (value == layout) return;
    layout = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_layoutKey, value.name);
  }
}

T _byName<T extends Enum>(List<T> values, String? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}
