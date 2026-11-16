import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mebius/src/internal/broadcast_engine.dart';

import 'support/webrtc_fakes.dart';

/// The real wiring from a live peer connection to the engine's
/// onConnectionState: both the PC and ICE callbacks, through
/// normalizeConnectionState, and that stop() detaches them so a closing
/// connection cannot emit after the broadcast has ended.
void main() {
  BroadcastEngine engineWith(FakePeerConnection pc, RecordingSignaling gw) =>
      BroadcastEngine(
        signaling: gw.signaling,
        video: true,
        audio: false,
        source: () async => FakeStream([FakeTrack()]),
        openPeerConnection: (_) async => pc,
      );

  test('PC and ICE states reach onConnectionState, normalized', () async {
    final pc = FakePeerConnection();
    final seen = <String>[];
    final engine = engineWith(pc, RecordingSignaling())
      ..onConnectionState = seen.add;

    await engine.start('s');
    pc.onConnectionState!(RTCPeerConnectionState.RTCPeerConnectionStateFailed);
    pc.onIceConnectionState!(
      RTCIceConnectionState.RTCIceConnectionStateCompleted,
    );

    expect(seen, ['failed', 'completed']);
  });

  test('stop detaches the pc state handlers', () async {
    final pc = FakePeerConnection();
    final seen = <String>[];
    final engine = engineWith(pc, RecordingSignaling())
      ..onConnectionState = seen.add;

    await engine.start('s');
    await engine.stop();

    expect(pc.onConnectionState, isNull);
    expect(pc.onIceConnectionState, isNull);
    expect(seen, isEmpty);
  });
}
