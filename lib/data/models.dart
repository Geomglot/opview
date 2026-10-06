// data models for webrtc messaging

/// POST body for /stream endpoint
class StreamRequest {
  final String sdp;
  final List<String> cameras;
  final List<String> bridgeServicesIn;
  final List<String> bridgeServicesOut;
  // newer webrtcd requires this; true asks for video + data now and takes over
  // from any other connected viewer
  final bool enabled;

  const StreamRequest({
    required this.sdp,
    this.cameras = const ['road'],
    this.bridgeServicesIn = const [],
    required this.bridgeServicesOut,
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
    'sdp': sdp,
    'cameras': cameras,
    'bridge_services_in': bridgeServicesIn,
    'bridge_services_out': bridgeServicesOut,
    'enabled': enabled,
  };
}
