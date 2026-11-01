// camera frames from ffmpeg, as fixed-size blocks of RGBA pixels

import 'dart:async';
import 'dart:typed_data';

class RawFrameReader {
  final StreamIterator<List<int>> _chunks;
  final int frameBytes;
  List<int> _held = const [];
  int _heldAt = 0;

  RawFrameReader(Stream<List<int>> source, this.frameBytes) : _chunks = StreamIterator(source);

  /// the next whole frame, or null at the end of the video
  Future<Uint8List?> next() async {
    final frame = Uint8List(frameBytes);
    var filled = 0;
    while (filled < frameBytes) {
      if (_heldAt == _held.length) {
        if (!await _chunks.moveNext()) return null;
        _held = _chunks.current;
        _heldAt = 0;
      }
      final take = (_held.length - _heldAt).clamp(0, frameBytes - filled);
      frame.setRange(filled, filled + take, _held, _heldAt);
      filled += take;
      _heldAt += take;
    }
    return frame;
  }
}
