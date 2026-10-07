// camera intrinsics + coordinate transforms + rotation math
// ported from openpilot common/transformations/camera.py + orientation.py
//
// no numpy, no 3D library. just 3x3 matrices in lists.
// all projection is: intrinsic @ calibration @ point → perspective divide

import 'dart:math';

// -- camera config --

class CameraConfig {
  final int width;
  final int height;
  final double focalLength;

  const CameraConfig(this.width, this.height, this.focalLength);

  // intrinsic matrix K — camera_frame_from_view_frame
  List<List<double>> get intrinsics => [
    [focalLength, 0.0, width / 2.0],
    [0.0, focalLength, height / 2.0],
    [0.0, 0.0, 1.0],
  ];
}

class DeviceCameraConfig {
  final CameraConfig fcam;  // forward camera
  final CameraConfig ecam;  // external/wide camera

  const DeviceCameraConfig({required this.fcam, required this.ecam});
}

// -- hardcoded device cameras (from camera.py) --

const _arOxFisheye = CameraConfig(1928, 1208, 567.0);
const _osFisheye = CameraConfig(1344, 760, 425.25);  // 2688/2, 1520/2, 567*3/4
const _arOxConfig = DeviceCameraConfig(
  fcam: CameraConfig(1928, 1208, 2648.0),
  ecam: _arOxFisheye,
);
const _osConfig = DeviceCameraConfig(
  fcam: CameraConfig(1344, 760, 1141.5),  // 1522*3/4
  ecam: _osFisheye,
);

// lookup by (deviceType, sensor) — matches camera.py DEVICE_CAMERAS
final Map<(String, String), DeviceCameraConfig> deviceCameras = {
  // tici variants
  ('tici', 'ar0231'): _arOxConfig,
  ('tici', 'ox03c10'): _arOxConfig,
  ('tici', 'os04c10'): _osConfig,
  ('tici', 'unknown'): _arOxConfig,
  // tizi variants
  ('tizi', 'ar0231'): _arOxConfig,
  ('tizi', 'ox03c10'): _arOxConfig,
  ('tizi', 'os04c10'): _osConfig,
  // mici variants
  ('mici', 'ar0231'): _arOxConfig,
  ('mici', 'ox03c10'): _arOxConfig,
  ('mici', 'os04c10'): _osConfig,
  // fallbacks
  ('unknown', 'ar0231'): _arOxConfig,
  ('unknown', 'ox03c10'): _arOxConfig,
  ('pc', 'unknown'): _arOxConfig,
};

// default when we haven't seen deviceState yet
const defaultDeviceCamera = _arOxConfig;

// -- coordinate frame transforms --
// device: x=forward, y=right, z=down
// view:   x=right,   y=down,  z=forward

const viewFrameFromDeviceFrame = [
  [0.0, 1.0, 0.0],
  [0.0, 0.0, 1.0],
  [1.0, 0.0, 0.0],
];

// calibrationd default height
const heightInit = 1.22;

// -- matrix math --

/// 3x3 matrix multiply: C = A @ B
List<List<double>> matmul3x3(List<List<double>> a, List<List<double>> b) {
  final c = List.generate(3, (_) => List.filled(3, 0.0));
  for (int i = 0; i < 3; i++) {
    for (int j = 0; j < 3; j++) {
      c[i][j] = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j];
    }
  }
  return c;
}

/// 3x3 matrix @ 3-vector
List<double> matvec3(List<List<double>> m, List<double> v) {
  return [
    m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
    m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
    m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2],
  ];
}

// -- rotation from euler angles --

/// rotation matrix from [roll, pitch, yaw]
/// standard aerospace: Rz(yaw) @ Ry(pitch) @ Rx(roll)
List<List<double>> rotFromEuler(List<double> rpy) {
  final r = rpy[0], p = rpy[1], y = rpy[2];
  final cr = cos(r), sr = sin(r);
  final cp = cos(p), sp = sin(p);
  final cy = cos(y), sy = sin(y);

  return [
    [cy * cp, cy * sp * sr - sy * cr, cy * sp * cr + sy * sr],
    [sy * cp, sy * sp * sr + cy * cr, sy * sp * cr - cy * sr],
    [-sp,     cp * sr,                cp * cr               ],
  ];
}

// -- video framing (augmented_road_view.py _calc_frame_matrix) --

/// a far point straight ahead, used to find the horizon
const infPoint = [1000.0, 0.0, 0.0];

/// where the camera image goes on screen, and the matching car-space -> screen
/// transform for the overlay. Both come from one zoom and one offset, as on the device.
class FrameTransform {
  final double zoom;        // screen px per camera px
  final double videoLeft;   // camera image placement, screen px
  final double videoTop;
  final double videoWidth;
  final double videoHeight;
  final List<List<double>> carToScreen;

  const FrameTransform(this.zoom, this.videoLeft, this.videoTop, this.videoWidth, this.videoHeight, this.carToScreen);
}

/// port of the device's frame matrix for a content rect at ([x], [y]) of size [w] x [h].
/// [deviceZoom] is the device's zoom (1.1 road, 2.0 wide) on the 1080 px tall 3X screen;
/// [scale] (screen height / 1080) keeps the same height of picture as the 3X. As on the
/// device, the zoom grows if needed to cover the whole rect, and the image is shifted
/// towards the calibrated horizon but never so far that an edge shows.
FrameTransform calcFrameTransform({
  required CameraConfig camera,
  required List<List<double>> calibration,
  required double deviceZoom,
  required double scale,
  required double x,
  required double y,
  required double w,
  required double h,
}) {
  final intrinsic = camera.intrinsics;
  final calibTransform = matmul3x3(intrinsic, calibration);
  final kep = matvec3(calibTransform, infPoint);
  final cx = intrinsic[0][2], cy = intrinsic[1][2];

  final zoom = [deviceZoom * scale, w / (2 * cx), h / (2 * cy)].reduce(max);

  final margin = 5 * scale;
  final maxXOffset = max(0.0, cx * zoom - w / 2 - margin);
  final maxYOffset = max(0.0, cy * zoom - h / 2 - margin);
  var xOffset = 0.0, yOffset = 0.0;
  if (kep[2].abs() > 1e-6) {
    xOffset = ((kep[0] / kep[2] - cx) * zoom).clamp(-maxXOffset, maxXOffset);
    yOffset = ((kep[1] / kep[2] - cy) * zoom).clamp(-maxYOffset, maxYOffset);
  }

  final tx = (w / 2 + x - xOffset) - cx * zoom;
  final ty = (h / 2 + y - yOffset) - cy * zoom;
  final videoTransform = [
    [zoom, 0.0, tx],
    [0.0, zoom, ty],
    [0.0, 0.0, 1.0],
  ];
  return FrameTransform(zoom, tx, ty, camera.width * zoom, camera.height * zoom,
      matmul3x3(videoTransform, calibTransform));
}
