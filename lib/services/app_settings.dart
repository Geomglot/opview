// app settings — viewer-side choices that live on this device, not on the comma
// stored with shared_preferences

import 'package:flutter/foundation.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
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

/// what the Enhanced layout was saved as before it was renamed
const _legacyLayoutNames = {'miciExtended': OnroadLayout.enhanced};

const _layoutKey = 'onroad_layout';
const _speedLimitKey = 'speed_limit_display';
const _collapsedKey = 'detailed_collapsed_panels';
const _roadNameKey = 'show_road_name';

class AppSettings extends ChangeNotifier {
  /// the clock is always shown, in 12 hour time; no longer a setting
  ClockMode clockMode = ClockMode.h12;
  OnroadLayout layout = OnroadLayout.classic;
  SpeedLimitDisplay speedLimitDisplay = SpeedLimitDisplay.auto;

  /// the road name pill, whatever the comma's own road name setting
  bool showRoadName = true;

  /// Detailed panels the driver has tapped shut, by name
  final Set<String> collapsedPanels = {};

  /// read saved settings; unknown or missing values keep the defaults
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    speedLimitDisplay = _byName(SpeedLimitDisplay.values, prefs.getString(_speedLimitKey), SpeedLimitDisplay.auto);
    showRoadName = prefs.getBool(_roadNameKey) ?? true;
    collapsedPanels
      ..clear()
      ..addAll(prefs.getStringList(_collapsedKey) ?? const []);
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

  Future<void> setShowRoadName(bool value) async {
    if (value == showRoadName) return;
    showRoadName = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_roadNameKey, value);
  }

  /// open a collapsed Detailed panel, or collapse an open one
  Future<void> togglePanel(String name) async {
    if (!collapsedPanels.remove(name)) collapsedPanels.add(name);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_collapsedKey, collapsedPanels.toList()..sort());
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
