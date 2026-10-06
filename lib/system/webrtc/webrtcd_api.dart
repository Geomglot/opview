// webrtcd API client
// POST /stream to negotiate WebRTC session
// ported from openpilot system/webrtc/webrtcd.py

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:opview/data/models.dart';

// everything the stock UI subscribes to
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
];

// same list with the service names used before openpilot renamed them
const legacyBridgeServicesOut = [
  'carState',
  'selfdriveState',
  'controlsState',
  'modelV2',
  'liveCalibration',
  'radarState',
  'longitudinalPlan',
  'deviceState',
  'roadCameraState',
];

/// webrtcd answered but refused the session (e.g. busy, unknown service)
class WebrtcdError implements Exception {
  final String error;
  final String message;
  WebrtcdError(this.error, this.message);

  /// webrtcd raises KeyError for a service name it does not know
  bool get isUnknownService => message.startsWith('KeyError');

  @override
  String toString() => 'webrtcd $error: $message';
}

/// exchange SDP with webrtcd, returns answer SDP
/// tries current service names first, then the pre-rename names for older openpilot
Future<Map<String, dynamic>> postStream(String host, String offerSdp, {String camera = 'road'}) async {
  try {
    return await _post(host, offerSdp, camera, bridgeServicesOut);
  } on WebrtcdError catch (e) {
    if (!e.isUnknownService) rethrow;
    return await _post(host, offerSdp, camera, legacyBridgeServicesOut);
  }
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
