import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mebius/src/internal/broadcast_engine.dart';
import 'package:mebius/src/internal/gateway_signaling.dart';

/// Who owns a caller `source` stream after stop, and that a supplied source is
/// published as-is — the camera-capture constraints (which are landscape) are
/// never applied to it, so a portrait source stays portrait.

class _FakeTrack extends Fake implements MediaStreamTrack {
  bool stopped = false;

  @override
  Future<void> stop() async {
    stopped = true;
  }
}

class _FakeStream extends Fake implements MediaStream {
  _FakeStream(this._tracks);

  final List<MediaStreamTrack> _tracks;
  bool disposed = false;

  @override
  List<MediaStreamTrack> getTracks() => _tracks;

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

// Fails the open so nothing native runs; the source stream is already captured
// by then, which is all stop() needs to act on.
Future<RTCPeerConnection> _noPeerConnection(Map<String, dynamic> _) async =>
    throw StateError('no native peer connection in tests');

void main() {
  final signaling = GatewaySignaling(
    gateway: 'https://gw.example',
    token: 't',
    httpClient: MockClient((_) async => http.Response('', 404)),
  );

  test('stop() leaves a source stream alive when disposeSourceOnStop is false',
      () async {
    final track = _FakeTrack();
    final stream = _FakeStream([track]);
    var sourceCalled = false;
    final engine = BroadcastEngine(
      signaling: signaling,
      video: true,
      audio: false,
      source: () async {
        sourceCalled = true;
        return stream;
      },
      disposeSourceOnStop: false,
      openPeerConnection: _noPeerConnection,
    );

    await expectLater(engine.start('s'), throwsStateError);
    await engine.stop();

    // Source used verbatim: getUserMedia (and its landscape constraints) is
    // bypassed entirely.
    expect(sourceCalled, isTrue);
    expect(track.stopped, isFalse);
    expect(stream.disposed, isFalse);
  });

  test('stop() disposes a source stream by default', () async {
    final track = _FakeTrack();
    final stream = _FakeStream([track]);
    final engine = BroadcastEngine(
      signaling: signaling,
      video: true,
      audio: false,
      source: () async => stream,
      openPeerConnection: _noPeerConnection,
    );

    await expectLater(engine.start('s'), throwsStateError);
    await engine.stop();

    expect(track.stopped, isTrue);
    expect(stream.disposed, isTrue);
  });
}
