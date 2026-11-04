// the picture of a render's progress that the window shows while it waits (lib/studio/studio_page.dart)

import 'dart:typed_data';

/// how wide it is at most: enough for the window's output pane
const snapshotWidth = 960;

/// after a picture, wait this many times as long as it took (and at least a second) before the next, so making them
/// never takes more than about a twentieth of a render however slow this computer is
const snapshotSpacing = 20;

/// a frame's RGBA pixels, shrunk to at most [maxWidth] across, as an uncompressed BMP the window can show as it is.
/// It is made from the pixels already read back for the encoder: drawing the frame a second time at the smaller size
/// and compressing it as a PNG took most of a second on a computer without a graphics card, and halved the render's speed.
Uint8List snapshotBmp(Uint8List rgba, int width, int height, {int maxWidth = snapshotWidth}) {
  final w = width <= maxWidth ? width : maxWidth;
  final h = (height * w / width).round();
  const header = 54;
  final size = w * h * 4;
  final out = Uint8List(header + size);
  ByteData.sublistView(out)
    ..setUint8(0, 0x42) // "BM"
    ..setUint8(1, 0x4D)
    ..setUint32(2, out.length, Endian.little)
    ..setUint32(10, header, Endian.little)
    ..setUint32(14, 40, Endian.little) // the size of this second part of the header
    ..setInt32(18, w, Endian.little)
    ..setInt32(22, -h, Endian.little) // negative: the rows run top to bottom, as they come
    ..setUint16(26, 1, Endian.little)
    ..setUint16(28, 32, Endian.little) // bits per pixel; no compression
    ..setUint32(34, size, Endian.little);
  final stride = width * 4;
  var o = header;
  for (var y = 0; y < h; y++) {
    final sy = y * height ~/ h;
    final below = sy + 1 < height ? stride : 0;
    for (var x = 0; x < w; x++) {
      final sx = x * width ~/ w;
      final i = sy * stride + sx * 4;
      final right = sx + 1 < width ? 4 : 0;
      // the average of the four pixels there, which keeps thin lines and text from breaking up as they shrink.
      // BMP keeps each pixel as blue, green, red, then a byte that is not used
      final a = i + right, b = i + below, c = i + below + right;
      out[o] = (rgba[i + 2] + rgba[a + 2] + rgba[b + 2] + rgba[c + 2] + 2) >> 2;
      out[o + 1] = (rgba[i + 1] + rgba[a + 1] + rgba[b + 1] + rgba[c + 1] + 2) >> 2;
      out[o + 2] = (rgba[i] + rgba[a] + rgba[b] + rgba[c] + 2) >> 2;
      out[o + 3] = 255;
      o += 4;
    }
  }
  return out;
}
