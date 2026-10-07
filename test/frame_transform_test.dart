import 'package:flutter_test/flutter_test.dart';
import 'package:opview/common/transformations.dart';

void main() {
  // -- calcFrameTransform: expected values from the device's own Python
  //    (augmented_road_view.py _calc_frame_matrix, numpy on a comma 3X) --

  group('calcFrameTransform matches the device', () {
    const screenW = 1280.0, screenH = 600.0;
    const scale = screenH / 1080.0;
    const border = 30 * scale;
    final cam = deviceCameras[('tizi', 'ox03c10')]!;
    final deviceFromCalib = rotFromEuler([0, 0.02, -0.01]);

    FrameTransform frame(CameraConfig c, List<List<double>> calib, double zoom) => calcFrameTransform(
        camera: c, calibration: calib, deviceZoom: zoom, scale: scale,
        x: border, y: border, w: screenW - 2 * border, h: screenH - 2 * border);

    List<double> project(FrameTransform f) {
      final p = matvec3(f.carToScreen, [20.0, 1.0, 1.2]);
      return [p[0] / p[2], p[1] / p[2]];
    }

    test('wide camera: 2x zoom kept, image shifted to the horizon', () {
      final calib = matmul3x3(viewFrameFromDeviceFrame, matmul3x3(rotFromEuler([0, 0.01, 0.03]), deviceFromCalib));
      final f = frame(cam.ecam, calib, 2.0);
      expect(f.zoom, closeTo(1.1111, 1e-3));
      expect(f.videoLeft, closeTo(-443.7112, 1e-2));
      expect(f.videoTop, closeTo(-352.202, 1e-2));
      final p = project(f);
      expect(p[0], closeTo(671.5054, 1e-2));
      expect(p[1], closeTo(337.7893, 1e-2));
    });

    test('road camera on a wide screen: zoom grows to fill the width', () {
      final f = frame(cam.fcam, matmul3x3(viewFrameFromDeviceFrame, deviceFromCalib), 1.1);
      expect(f.zoom, closeTo(0.6466, 1e-3));
      expect(f.videoLeft, closeTo(16.6667, 1e-2));
      expect(f.videoTop, closeTo(-56.3024, 1e-2));
      final p = project(f);
      expect(p[0], closeTo(708.3688, 1e-2));
      expect(p[1], closeTo(402.6225, 1e-2));
    });

    test('video always covers the content area', () {
      for (final zoom in [1.1, 2.0]) {
        final f = frame(zoom == 2.0 ? cam.ecam : cam.fcam, matmul3x3(viewFrameFromDeviceFrame, deviceFromCalib), zoom);
        expect(f.videoLeft, lessThanOrEqualTo(border + 1e-6));
        expect(f.videoTop, lessThanOrEqualTo(border + 1e-6));
        expect(f.videoLeft + f.videoWidth, greaterThanOrEqualTo(screenW - border - 1e-6));
        expect(f.videoTop + f.videoHeight, greaterThanOrEqualTo(screenH - border - 1e-6));
      }
    });
  });
}
