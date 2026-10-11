// screen brightness and installing an app update, via MainActivity's system channel.
// Best effort: in tests, and on platforms without the channel, these do nothing

import 'package:flutter/services.dart';

const _channel = MethodChannel('org.dragonpilot.opview/system');

/// this app's screen brightness, 0..1; null hands it back to the head unit's own setting
Future<void> setAppBrightness(double? value) async {
  try {
    await _channel.invokeMethod('setBrightness', value ?? -1.0);
  } catch (_) {
    // no channel (tests, other platforms): nothing to set
  }
}

/// whether Android lets this app start an install ("Install unknown apps")
Future<bool> canInstallApks() async {
  try {
    return await _channel.invokeMethod<bool>('canInstallApks') ?? false;
  } catch (_) {
    return false;
  }
}

/// open Android's "Install unknown apps" page for this app
Future<void> openInstallSettings() async {
  try {
    await _channel.invokeMethod('openInstallSettings');
  } catch (_) {
    // nothing to open
  }
}

/// hand a downloaded APK to Android's installer, which asks to confirm. Throws on failure
Future<void> installApk(String path) => _channel.invokeMethod('installApk', path);
