import 'package:flutter_test/flutter_test.dart';
import 'package:mebius/src/internal/broadcast_engine.dart';

void main() {
  group('h264FirstCodecs', () {
    test('offers H264 before VP8', () {
      // Order is the whole point: the gateway's segment-based deliveries cannot
      // carry VP8, so a VP8-first offer reaches those viewers as audio only.
      expect(h264FirstCodecs.first.mimeType, 'video/H264');
      expect(
        h264FirstCodecs.map((c) => c.mimeType),
        containsAllInOrder(<String>['video/H264', 'video/VP8']),
      );
    });

    test('keeps VP8 as a fallback rather than forcing H264', () {
      // A device with no H264 encoder must still be able to broadcast.
      expect(
        h264FirstCodecs.any((c) => c.mimeType == 'video/VP8'),
        isTrue,
      );
    });

    test('declares the 90kHz video clock rate', () {
      for (final c in h264FirstCodecs) {
        expect(c.clockRate, 90000);
      }
    });
  });
}
