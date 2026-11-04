import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:opview/replay/snapshot.dart';

/// [width] x [height] pixels: red on the left half, blue on the right, with a green top row
Uint8List frame(int width, int height) {
  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      if (y == 0) {
        rgba[i + 1] = 255;
      } else if (x < width ~/ 2) {
        rgba[i] = 255;
      } else {
        rgba[i + 2] = 255;
      }
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}

Future<(ui.Image, ByteData)> decode(Uint8List bmp) async {
  final codec = await ui.instantiateImageCodec(bmp);
  final image = (await codec.getNextFrame()).image;
  return (image, (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!);
}

void main() {
  test('a frame wider than the picture is shrunk, and the picture comes out the right way up in the right colours', () async {
    final (image, px) = await decode(snapshotBmp(frame(1928, 1208), 1928, 1208));
    expect((image.width, image.height), (960, 601));
    List<int> at(int x, int y) => [for (var c = 0; c < 3; c++) px.getUint8((y * image.width + x) * 4 + c)];
    expect(at(10, 300), [255, 0, 0], reason: 'red on the left');
    expect(at(950, 300), [0, 0, 255], reason: 'blue on the right');
    expect(at(10, 600), [255, 0, 0], reason: 'the bottom row is the bottom of the frame');
    expect(at(10, 0)[1], greaterThan(100), reason: 'the green top row is at the top, blended with the row below it');
  });

  test('a frame no wider than the picture keeps its size', () async {
    final (image, _) = await decode(snapshotBmp(frame(640, 400), 640, 400));
    expect((image.width, image.height), (640, 400));
  });
}
