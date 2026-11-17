import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/connection_manager.dart';

UIState _state({bool experimental = false, double vEgo = 0}) => UIState()
  ..experimentalMode = experimental
  ..vEgo = vEgo;

void main() {
  group('older branches: Experimental mode', () {
    test('road camera outside Experimental mode', () {
      expect(cameraTarget(_state(vEgo: 1), 'road'), 'road');
      expect(cameraTarget(_state(vEgo: 1), 'wideRoad'), 'road');
    });

    test('wide below 10 m/s, road above 15, kept in between', () {
      expect(cameraTarget(_state(experimental: true, vEgo: 9), 'road'), 'wideRoad');
      expect(cameraTarget(_state(experimental: true, vEgo: 12), 'wideRoad'), 'wideRoad');
      expect(cameraTarget(_state(experimental: true, vEgo: 12), 'road'), 'road');
      expect(cameraTarget(_state(experimental: true, vEgo: 16), 'wideRoad'), 'road');
    });
  });

  group('branches without Experimental mode: openpilot longitudinal', () {
    test('the comma sends OpenpilotLongitudinalControl and the wide camera follows it', () {
      final st = _state()..applyOpviewParams({'OpenpilotLongitudinalControl': true});
      expect(cameraTarget(st, 'road'), 'wideRoad', reason: 'at a standstill, as drive 85 started');
      st.vEgo = 7;
      expect(cameraTarget(st, 'wideRoad'), 'wideRoad');
      expect(cameraTarget(st, 'road'), 'road');
      st.vEgo = 11;
      expect(cameraTarget(st, 'wideRoad'), 'road');
      st.vEgo = 4;
      expect(cameraTarget(st, 'road'), 'wideRoad');
    });

    test('stock longitudinal stays on the road camera', () {
      final st = _state(experimental: true, vEgo: 1)..applyOpviewParams({'OpenpilotLongitudinalControl': false});
      expect(cameraTarget(st, 'road'), 'road');
    });

    test('a comma that leaves the key out goes back to the Experimental mode rule', () {
      final st = _state(vEgo: 1)..applyOpviewParams({'OpenpilotLongitudinalControl': true});
      st.applyOpviewParams({'IsMetric': true});
      expect(st.openpilotLongitudinal, isNull);
      expect(cameraTarget(st, 'road'), 'road');
    });
  });
}
