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

    test('does not fall back when framesDecoded is present and zero', () {
      // Present-and-zero is a real answer: media has arrived but nothing has
      // decoded, which is precisely the stall we must keep waiting through.
      // Falling back to framesReceived here would declare it playing.
      final reports = [
        report('inbound-rtp', {
          'kind': 'video',
          'framesDecoded': 0,
          'framesReceived': 5,
        }),
      ];

      expect(decodedVideoFrames(reports), 0);
    });

    test('sums every inbound video report rather than trusting the first', () {
      // getStats() ordering is unspecified — Android builds the report from a
      // hash map. Returning on the first video entry meant a session with two
      // of them could answer 0 while video was flowing, and fail over a route
      // that was working.
      final reports = [
        report('inbound-rtp', {'kind': 'video', 'framesDecoded': 0}),
        report('inbound-rtp', {'kind': 'video', 'framesDecoded': 9}),
      ];

      expect(decodedVideoFrames(reports), 9);
    });

    test('accepts mediaType where a platform omits kind', () {
      // `kind` is the spec field and current libwebrtc emits it. If a platform
      // ever sends only the legacy alias, matching `kind` alone fails silently:
      // no report matches, every real-time route fails over forever, and
      // nothing logs why.
      final reports = [
        report('inbound-rtp', {'mediaType': 'video', 'framesDecoded': 4}),
      ];

      expect(decodedVideoFrames(reports), 4);
    });
  });
}
