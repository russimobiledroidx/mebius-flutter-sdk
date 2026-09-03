import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mebius/src/internal/playback_engine.dart';

/// The real-time route's first-frame signal.
///
/// A route that connects and sends nothing produces no error at all, which is
/// the whole reason a first-frame watchdog exists. The signal it reads therefore
/// has to mean "a picture arrived" — not "a track object exists", which is true
/// the instant the peer connection is negotiated and stays true forever after.
void main() {
  StatsReport report(String type, Map<String, dynamic> values) =>
      StatsReport('id-$type', type, 0, values);

  group('decodedVideoFrames', () {
    test('is zero when a track exists but nothing has decoded', () {
      // The bug this replaces: the engine treated the arrival of the track as
      // the frame, so this case reported success and the viewer sat on a black
      // frame with no error and no failover.
      final reports = [
        report('inbound-rtp', {'kind': 'video', 'framesDecoded': 0}),
      ];

      expect(decodedVideoFrames(reports), 0);
    });

    test('counts frames the decoder has actually produced', () {
      final reports = [
        report('inbound-rtp', {'kind': 'video', 'framesDecoded': 7}),
      ];

      expect(decodedVideoFrames(reports), 7);
    });

    test('falls back to framesReceived where framesDecoded is absent', () {
      // Not every platform reports framesDecoded. Receiving frames is still
      // proof that media is flowing, which is what the watchdog is asking.
      final reports = [
        report('inbound-rtp', {'kind': 'video', 'framesReceived': 3}),
      ];

      expect(decodedVideoFrames(reports), 3);
    });

    test('is zero when the report carries no frame counter at all', () {
      // Absent is not the same as zero, but the watchdog has to resolve it one
      // way, and "not proven" must not read as "playing".
      final reports = [
        report('inbound-rtp', {'kind': 'video', 'bytesReceived': 48000}),
      ];

      expect(decodedVideoFrames(reports), 0);
    });

    test('ignores audio, which never decodes a frame', () {
      final reports = [
        report('inbound-rtp', {'kind': 'audio', 'framesDecoded': 999}),
        report('inbound-rtp', {'kind': 'video', 'framesDecoded': 2}),
      ];

      expect(decodedVideoFrames(reports), 2);
    });

    test('ignores outbound stats, which describe what we are sending', () {
      // A monitor both publishes and plays on the same device. Counting the
      // outbound side would report a frame for a route that received none.
      final reports = [
        report('outbound-rtp', {'kind': 'video', 'framesEncoded': 120}),
      ];

      expect(decodedVideoFrames(reports), 0);
    });

    test('is zero on an empty snapshot', () {
      expect(decodedVideoFrames(const <StatsReport>[]), 0);
    });
  });
}
