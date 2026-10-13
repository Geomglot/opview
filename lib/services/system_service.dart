// screen brightness and installing an app update, via MainActivity's system channel.
// Best effort: in tests, and on platforms without the channel, these do nothing

import 'package:flutter/foundation.dart';
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

/// the folder to save a downloaded update in, which the installer can be given files from;
/// null without the channel
Future<String?> updateDir() async {
  try {
    return await _channel.invokeMethod<String>('updateDir');
  } catch (_) {
    return null;
  }
}

/// hand a downloaded APK to Android's installer, which asks to confirm. Throws on failure
Future<void> installApk(String path) => _channel.invokeMethod('installApk', path);

/// true while Android shows the app as a picture-in-picture window
final pipMode = ValueNotifier<bool>(false);

/// follow MainActivity's picture-in-picture changes into [pipMode]
void listenForPip() {
  try {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pipChanged') pipMode.value = call.arguments == true;
    });
  } catch (_) {
    // no channel: never in PiP
  }
}

/// whether going Home shrinks the app to a floating window
Future<void> setPipEnabled(bool enabled) async {
  try {
    await _channel.invokeMethod('setPipEnabled', enabled);
  } catch (_) {
    // no channel, or PiP not supported: nothing to turn on
  }
}
