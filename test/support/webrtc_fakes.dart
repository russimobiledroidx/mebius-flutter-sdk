// Test doubles for the broadcaster path: a peer connection whose start
// SUCCEEDS (so stop(), the DELETE, and post-stop behaviour can be exercised on
// a genuinely running engine, not just a failed start), plus a signaling
// client backed by an in-memory gateway that records the requests it receives.

// The state-callback fields mirror flutter_webrtc's own untyped `Function?`
// signature; narrowing their return type would break the override.
// ignore_for_file: inference_failure_on_function_return_type

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mebius/src/internal/gateway_signaling.dart';

class FakeTrack extends Fake implements MediaStreamTrack {
  bool stopped = false;

  @override
  String? get kind => 'video';

  @override
  Future<void> stop() async {
    stopped = true;
  }
}

class FakeStream extends Fake implements MediaStream {
  FakeStream(this._tracks);

  final List<MediaStreamTrack> _tracks;
  bool disposed = false;

  @override
  List<MediaStreamTrack> getTracks() => _tracks;

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class FakeSender extends Fake implements RTCRtpSender {}

/// A peer connection that lets start() complete. [closeThrows] makes [close]
/// fail, to prove stop() still tears the rest down and DELETEs the resource.
class FakePeerConnection extends Fake implements RTCPeerConnection {
  FakePeerConnection({this.closeThrows = false});

  final bool closeThrows;
  bool closed = false;
  bool disposed = false;

  @override
  Function(RTCPeerConnectionState state)? onConnectionState;

  @override
  Function(RTCIceConnectionState state)? onIceConnectionState;

  @override
  Future<RTCRtpSender> addTrack(
    MediaStreamTrack track, [
    MediaStream? stream,
  ]) async =>
      FakeSender();

  @override
  Future<List<RTCRtpSender>> getSenders() async => const <RTCRtpSender>[];

  @override
  Future<List<RTCRtpTransceiver>> getTransceivers() async =>
      const <RTCRtpTransceiver>[];

  @override
  Future<RTCSessionDescription> createOffer([
    Map<String, dynamic>? constraints,
  ]) async =>
      RTCSessionDescription('v=0', 'offer');

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {}

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {}

  @override
  Future<List<StatsReport>> getStats([MediaStreamTrack? track]) async =>
      const <StatsReport>[];

  @override
  Future<void> close() async {
    if (closeThrows) {
      throw StateError('close failed');
    }
    closed = true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// Signaling over an in-memory gateway. WHIP publish answers 201 with a
/// Location, so a resource URL is set and the DELETE on stop has something to
/// target; every request method+path is recorded.
class RecordingSignaling {
  RecordingSignaling({
    this.location = 'https://gw.example/whip/s/resource-1',
  }) {
    signaling = GatewaySignaling(
      gateway: 'https://gw.example',
      token: 't',
      httpClient: MockClient((req) async {
        requests.add('${req.method} ${req.url.path}');
        if (req.method == 'POST') {
          return http.Response('v=0', 201, headers: {'location': location});
        }
        return http.Response('', 200);
      }),
    );
  }

  final String location;
  final List<String> requests = <String>[];
  late final GatewaySignaling signaling;

  bool get deleted => requests.any((r) => r.startsWith('DELETE'));
}
