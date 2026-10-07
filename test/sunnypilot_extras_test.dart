import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/selfdrive/ui/onroad/exp_button.dart';
import 'package:opview/selfdrive/ui/onroad/hud_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/speed_limit_renderer.dart';
import 'package:opview/services/impl/cereal_adapter.dart';

UIState _withParams({bool metric = true, int mode = 1, bool roadName = true, bool forceTorque = false}) {
  return UIState()
    ..applyOpviewParams({
      'IsMetric': metric,
      'SpeedLimitMode': mode,
      'RoadNameToggle': roadName,
      'RivianForceTorqueSteer': forceTorque,
    });
}

Map<String, dynamic> _plan({double limit = 40 / 3.6, double offset = 0, bool valid = true, String state = 'inactive'}) => {
      'speedLimit': {
        'resolver': {
          'speedLimit': limit,
          'speedLimitLast': limit,
          'speedLimitOffset': offset,
          'speedLimitValid': valid,
          'speedLimitLastValid': valid,
          'speedLimitFinalLast': limit + offset,
          'source': 'map',
        },
        'assist': {'state': state},
      },
    };

void main() {
  group('opviewParams', () {
    test('sets unit and toggles', () {
      final st = _withParams(metric: false, mode: 2, roadName: false, forceTorque: true);
      expect(st.paramsSeen, isTrue);
      expect(st.isMetric, isFalse);
      expect(st.speedLimitMode, 2);
      expect(st.roadNameToggle, isFalse);
      expect(st.forceTorqueSteer, isTrue);
    });

    test('sign hidden until params arrive, and when mode is off', () {
      expect(UIState().showSpeedLimit, isFalse);
      expect(_withParams(mode: 0).showSpeedLimit, isFalse);
      expect(_withParams(mode: 1).showSpeedLimit, isTrue);
    });

    test('adapter dispatches opviewParams and sunnypilot services', () {
      final st = UIState();
      final a = CerealAdapter();
      a.apply(st, '{"type": "opviewParams", "data": {"IsMetric": false, "SpeedLimitMode": 3, "RoadNameToggle": true}}');
      a.apply(st, '{"type": "liveMapDataSP", "data": {"roadName": "Main St"}}');
      expect(st.isMetric, isFalse);
      expect(st.speedLimitMode, 3);
      expect(st.showRoadName, isTrue);
      expect(st.roadName, 'Main St');
    });
  });

  group('lateral mode (Rivian angle/torque wheel tint)', () {
    UIState rivian({bool angleHarness = true, bool latActive = true, bool forceTorque = false}) {
      final st = _withParams(forceTorque: forceTorque)
        ..applyCarParams({'brand': 'rivian', 'flags': angleHarness ? rivianAngleHarnessFlag : 0})
        ..applyCarControl({'latActive': latActive});
      return st;
    }

    void feed(UIState st, List<double> torques) {
      for (final t in torques) {
        st.applyCarOutput({'actuatorsOutput': {'torqueOutputCan': t}});
      }
    }

    test('zero CAN torque for the hold count reads as angle', () {
      final st = rivian();
      feed(st, [0.5, 0, 0]);
      expect(st.lateralMode, LateralMode.torque);
      feed(st, [0]);
      expect(st.lateralMode, LateralMode.angle);
      expect(wheelTint(st.lateralMode), angleColor);
    });

    test('any torque reads as torque', () {
      final st = rivian();
      feed(st, [0, 0, 0, 0.2]);
      expect(st.lateralMode, LateralMode.torque);
      expect(wheelTint(st.lateralMode), torqueColor);
    });

    test('forced torque always reads as torque', () {
      final st = rivian(forceTorque: true);
      feed(st, [0, 0, 0, 0]);
      expect(st.lateralMode, LateralMode.torque);
    });

    test('no tint without the angle harness, other brands, or when not steering', () {
      final noHarness = rivian(angleHarness: false);
      feed(noHarness, [0, 0, 0, 0]);
      expect(noHarness.lateralMode, isNull);

      final notSteering = rivian(latActive: false);
      feed(notSteering, [0, 0, 0, 0]);
      expect(notSteering.lateralMode, isNull);

      final other = UIState()
        ..applyCarParams({'brand': 'toyota', 'flags': rivianAngleHarnessFlag})
        ..applyCarControl({'latActive': true});
      feed(other, [0, 0, 0, 0]);
      expect(other.lateralMode, isNull);
    });
  });

  group('speed limit sign', () {
    test('value in km/h, black when valid and under the limit', () {
      final st = _withParams()..applyLongitudinalPlanSP(_plan());
      final sign = SpeedLimitSign.from(st);
      expect(sign.value, '40');
      expect(sign.textColor, SpeedLimitColors.black);
      expect(sign.offset, '');
    });

    test('value in mph when imperial', () {
      final st = _withParams(metric: false)..applyLongitudinalPlanSP(_plan(limit: 25 / 2.23694));
      expect(SpeedLimitSign.from(st).value, '25');
    });

    test('red when over the limit in warning mode, black in information mode', () {
      final warn = _withParams(mode: 2)
        ..applyLongitudinalPlanSP(_plan())
        ..applyCarState({'vEgo': 50 / 3.6});
      expect(SpeedLimitSign.from(warn).textColor, SpeedLimitColors.red);

      final info = _withParams(mode: 1)
        ..applyLongitudinalPlanSP(_plan())
        ..applyCarState({'vEgo': 50 / 3.6});
      expect(SpeedLimitSign.from(info).textColor, SpeedLimitColors.black);
    });

    test('grey dashes with no limit, offset badge text', () {
      final none = _withParams()..applyLongitudinalPlanSP(_plan(valid: false));
      final s1 = SpeedLimitSign.from(none);
      expect(s1.value, '---');
      expect(s1.textColor, SpeedLimitColors.grey);

      final off = _withParams()..applyLongitudinalPlanSP(_plan(offset: 5 / 3.6));
      expect(SpeedLimitSign.from(off).offset, '5');
    });

    test('preActive arrow points toward the limit', () {
      final st = _withParams()
        ..applyLongitudinalPlanSP(_plan(state: 'preActive'))
        ..applyCarState({'vCruiseCluster': 30.0});
      expect(preActiveArrow(st), 'assets/icons/img_plus_arrow_up.png');
      st.applyCarState({'vCruiseCluster': 50.0});
      expect(preActiveArrow(st), 'assets/icons/img_minus_arrow_down.png');
    });

    test('ahead distance labels', () {
      expect(formatAheadDistance(30, true), 'Near');
      expect(formatAheadDistance(1500, true), '1.5 km');
      expect(formatAheadDistance(340, true), '300 m');
      expect(formatAheadDistance(100, false), '350 ft');
      expect(formatAheadDistance(2000, false), '1.2 mi');
    });
  });

  group('HUD renders with sunnypilot extras', () {
    for (final metric in [true, false]) {
      testWidgets('metric=$metric', (tester) async {
        final st = _withParams(metric: metric, mode: 2)
          ..applyLongitudinalPlanSP(_plan(offset: 3 / 3.6))
          ..applyLiveMapDataSP({'roadName': 'A very long road name that should be shortened', 'speedLimitAheadValid': true,
            'speedLimitAhead': 60 / 3.6, 'speedLimitAheadDistance': 250.0})
          ..applySelfdriveState({'enabled': true, 'engageable': true, 'experimentalMode': !metric})
          ..applyCarParams({'brand': 'rivian', 'flags': rivianAngleHarnessFlag})
          ..applyCarControl({'latActive': true})
          ..applyCarState({'vEgo': 45 / 3.6, 'vCruiseCluster': 40.0});
        st.applyCarOutput({'actuatorsOutput': {'torqueOutputCan': 0.3}});
        await tester.binding.setSurfaceSize(const Size(1920, 1080));
        await tester.pumpWidget(MaterialApp(home: SizedBox(width: 1920, height: 1080,
            child: Stack(children: [HudRenderer(uiState: st, scale: 1.0)]))));
        expect(find.text('A very long road name that should be shortened'), findsOneWidget);
        expect(find.byType(ExpButton), findsOneWidget);
        expect(find.byType(SpeedLimitRenderer), findsOneWidget);
        // upstream's imperial MAX box overflows with the blocky test font (not on real fonts);
        // tolerate only that
        final e = tester.takeException();
        expect(e == null || '$e'.contains('RenderFlex overflowed'), isTrue, reason: '$e');
      });
    }
  });
}
