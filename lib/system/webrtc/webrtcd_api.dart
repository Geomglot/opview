// webrtcd API client
// POST /stream to negotiate WebRTC session
// ported from openpilot system/webrtc/webrtcd.py

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:opview/data/models.dart';

// everything the stock UI subscribes to, plus the sunnypilot extras
// (speed limit sign, road name, Rivian angle/torque wheel tint)
const bridgeServicesOut = [
  'carState',
  'selfdriveState',
  'controlsState',
  'modelV2',
  'extrinsicsCalibration',
  'radarState',
  'longitudinalPlan',
  'deviceState',
  'narrowRoadCameraState',
  'longitudinalPlanSP',
  'liveMapDataSP',
  'carControl',
  'carOutput',
];

// names used before openpilot renamed these services
const legacyServiceNames = {
  'extrinsicsCalibration': 'liveCalibration',
  'narrowRoadCameraState': 'roadCameraState',
};

// most services a device could reject before we give up
const _maxServiceRetries = 8;

/// webrtcd answered but refused the session (e.g. busy, unknown service)
class WebrtcdError implements Exception {
  final String error;
  final String message;
  WebrtcdError(this.error, this.message);

  /// webrtcd raises KeyError for a service name it does not know
  bool get isUnknownService => message.startsWith('KeyError');

  /// the service named in a KeyError, e.g. KeyError: 'liveCalibration'
  String? get unknownService => RegExp(r"KeyError: '([^']+)'").firstMatch(message)?.group(1);

  @override
  String toString() => 'webrtcd $error: $message';
}

/// exchange SDP with webrtcd, returns answer SDP.
/// older devices reject services they do not have: use the old name if it was renamed,
/// otherwise leave that service out, and try again
Future<Map<String, dynamic>> postStream(String host, String offerSdp, {String camera = 'road'}) async {
  var services = List<String>.of(bridgeServicesOut);
  for (var attempt = 0;; attempt++) {
    try {
      return await _post(host, offerSdp, camera, services);
    } on WebrtcdError catch (e) {
      final next = servicesWithout(services, e.unknownService);
      if (!e.isUnknownService || next == null || attempt >= _maxServiceRetries) rethrow;
      services = next;
    }
  }
}

/// [services] with [rejected] replaced by its old name, or removed; null if that changes nothing
List<String>? servicesWithout(List<String> services, String? rejected) {
  if (rejected == null || !services.contains(rejected)) return null;
  final legacy = legacyServiceNames[rejected];
  return [
    for (final s in services)
      if (s != rejected) s else if (legacy != null) legacy,
  ];
}

Future<Map<String, dynamic>> _post(String host, String offerSdp, String camera, List<String> services) async {
  final request = StreamRequest(
    sdp: offerSdp,
    cameras: [camera],
    bridgeServicesOut: services,
  );

  final url = Uri.parse('http://$host:5001/stream');
  final response = await http.post(
    url,
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode(request.toJson()),
  // a reconnect right after a dropped session can take ~8.5 s while webrtcd
  // closes the stale one, so allow well over that
  ).timeout(const Duration(seconds: 20));

  return parseStreamResponse(response.statusCode, response.body);
}

/// webrtcd reports errors as {"error": ..., "message": ...}, sometimes with HTTP 200 (busy)
Map<String, dynamic> parseStreamResponse(int statusCode, String body) {
  Map<String, dynamic>? json;
  try {
    json = jsonDecode(body) as Map<String, dynamic>;
  } catch (_) {}

  if (json != null && json.containsKey('error')) {
    throw WebrtcdError('${json['error']}', '${json['message'] ?? ''}');
  }
  if (statusCode != 200 || json == null) {
    throw Exception('webrtcd returned $statusCode: $body');
  }
  return json;
}

/// webrtcd ends sessions with `{"type": "disconnect", "data": "<reason>"}` on the data channel
/// (session timeout, or another viewer connected). returns the reason, or null for other messages
String? parseDisconnect(String chunk) {
  if (!chunk.contains('"disconnect"')) return null;
  try {
    final json = jsonDecode(chunk) as Map<String, dynamic>;
    if (json['type'] != 'disconnect') return null;
    return '${json['data'] ?? ''}';
  } catch (_) {
    return null;
  }
}

/// true when the session was ended because another viewer took over
bool isTakeover(String reason) => reason.startsWith('Another device');
