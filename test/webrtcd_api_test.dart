import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/impl/cereal_adapter.dart';
import 'package:opview/system/webrtc/webrtcd_api.dart';

void main() {
  group('parseStreamResponse', () {
    test('returns answer on success', () {
      final json = parseStreamResponse(200, '{"sdp": "v=0", "type": "answer"}');
      expect(json['type'], 'answer');
    });

    test('busy with HTTP 200 throws WebrtcdError', () {
      expect(
        () => parseStreamResponse(200, '{"error": "busy", "message": "someone else is connected."}'),
        throwsA(isA<WebrtcdError>().having((e) => e.error, 'error', 'busy')),
      );
    });

    test('unknown service is detected', () {
      try {
        parseStreamResponse(500, '{"error": "exception", "message": "KeyError: \'liveCalibration\'"}');
        fail('should throw');
      } on WebrtcdError catch (e) {
        expect(e.isUnknownService, isTrue);
      }
    });

    test('missing enabled field is not treated as unknown service', () {
      try {
        parseStreamResponse(500, '{"error": "exception", "message": "TypeError: missing enabled"}');
        fail('should throw');
      } on WebrtcdError catch (e) {
        expect(e.isUnknownService, isFalse);
      }
    });

    test('non-JSON error throws', () {
      expect(() => parseStreamResponse(502, 'bad gateway'), throwsException);
    });
  });

  group('parseDisconnect', () {
    test('session timeout', () {
      expect(parseDisconnect('{"type": "disconnect", "data": "Session timed out"}'), 'Session timed out');
    });

    test('takeover', () {
      final reason = parseDisconnect(
          '{"type": "disconnect", "data": "Another device has connected, closing this session."}')!;
      expect(isTakeover(reason), isTrue);
      expect(isTakeover('Session timed out'), isFalse);
    });

    test('ignores telemetry', () {
      expect(parseDisconnect('{"type": "carState", "data": {"vEgo": 1.0}}'), isNull);
    });
  });

  group('service lists', () {
    test('current and legacy lists differ only by the renamed services', () {
      expect(bridgeServicesOut, contains('extrinsicsCalibration'));
      expect(bridgeServicesOut, contains('narrowRoadCameraState'));
      expect(legacyBridgeServicesOut, contains('liveCalibration'));
      expect(legacyBridgeServicesOut, contains('roadCameraState'));
      expect(bridgeServicesOut.length, legacyBridgeServicesOut.length);
    });
  });

  group('CerealAdapter renamed services', () {
    test('extrinsicsCalibration applies like liveCalibration', () {
      final state = UIState();
      CerealAdapter().apply(state, '{"type": "extrinsicsCalibration", "data": {"rpyCalib": [0.01, -0.02, 0.005]}}');
      expect(state.rpyCalib, [0.01, -0.02, 0.005]);
    });

    test('narrowRoadCameraState applies like roadCameraState', () {
      final state = UIState();
      CerealAdapter().apply(state, '{"type": "narrowRoadCameraState", "data": {"sensor": "ox03c10"}}');
      expect(state.sensor, 'ox03c10');
    });
  });
}
