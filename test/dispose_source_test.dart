import 'package:flutter_test/flutter_test.dart';
import 'package:mebius/src/internal/broadcast_engine.dart';

import 'support/webrtc_fakes.dart';

/// Teardown on a GENUINELY started broadcast: who owns a caller `source`
/// stream after stop, that the peer connection is closed and the gateway
/// resource DELETEd, and that none of that is skipped when a teardown step
/// throws.
void main() {
  BroadcastEngine engineWith({
    required FakeStream stream,
    required FakePeerConnection pc,
    required RecordingSignaling gw,
    bool disposeSourceOnStop = true,
    bool Function()? onSourceCalled,
  }) {
    return BroadcastEngine(
      signaling: gw.signaling,
      video: true,
      audio: false,
      source: () async {
        onSourceCalled?.call();
        return stream;
      },
      disposeSourceOnStop: disposeSourceOnStop,
      openPeerConnection: (_) async => pc,
    );
  }

  test('a started broadcast: stop closes the pc and DELETEs the resource',
      () async {
    final track = FakeTrack();
    final stream = FakeStream([track]);
    final pc = FakePeerConnection();
    final gw = RecordingSignaling();
    final engine = engineWith(stream: stream, pc: pc, gw: gw);

    await engine.start('s');
    expect(engine.isRunning, isTrue);
    expect(gw.requests.any((r) => r.startsWith('POST')), isTrue);

    await engine.stop();

    expect(pc.closed, isTrue);
    expect(pc.disposed, isTrue);
    expect(gw.deleted, isTrue, reason: 'the WHIP resource must be released');
    expect(engine.isRunning, isFalse);
  });

  test('stop disposes a source stream by default', () async {
    final track = FakeTrack();
    final stream = FakeStream([track]);
    final gw = RecordingSignaling();
    final engine =
        engineWith(stream: stream, pc: FakePeerConnection(), gw: gw);

    await engine.start('s');
    await engine.stop();

    expect(track.stopped, isTrue);
    expect(stream.disposed, isTrue);
  });

  test('stop leaves a source stream alive when disposeSourceOnStop is false',
      () async {
    final track = FakeTrack();
    final stream = FakeStream([track]);
    final gw = RecordingSignaling();
    final engine = engineWith(
      stream: stream,
      pc: FakePeerConnection(),
      gw: gw,
      disposeSourceOnStop: false,
    );

    await engine.start('s');
    await engine.stop();

    // App keeps its stream, but the connection and gateway resource are gone.
    expect(track.stopped, isFalse);
    expect(stream.disposed, isFalse);
    expect(gw.deleted, isTrue);
  });

  test('a source is used verbatim: getUserMedia is never called', () async {
    var sourceCalled = false;
    final engine = engineWith(
      stream: FakeStream([FakeTrack()]),
      pc: FakePeerConnection(),
      gw: RecordingSignaling(),
      onSourceCalled: () => sourceCalled = true,
    );

    await engine.start('s');

    // The source branch ran, so the built-in landscape capture constraints in
    // the getUserMedia path were never applied.
    expect(sourceCalled, isTrue);
  });

  test('stop still DELETEs and disposes even if pc.close() throws', () async {
    final track = FakeTrack();
    final stream = FakeStream([track]);
    final pc = FakePeerConnection(closeThrows: true);
    final gw = RecordingSignaling();
    final engine = engineWith(stream: stream, pc: pc, gw: gw);

    await engine.start('s');
    // Must not throw, and must not strand the rest of teardown.
    await engine.stop();

    expect(track.stopped, isTrue, reason: 'camera must be released');
    expect(stream.disposed, isTrue);
    expect(gw.deleted, isTrue, reason: 'DELETE must still run');
    expect(engine.isRunning, isFalse);
  });

  test('a failed start releases the camera it had already opened', () async {
    final track = FakeTrack();
    final stream = FakeStream([track]);
    final gw = RecordingSignaling();
    // Open fails after the source stream was captured.
    final engine = BroadcastEngine(
      signaling: gw.signaling,
      video: true,
      audio: false,
      source: () async => stream,
      openPeerConnection: (_) async =>
          throw StateError('no peer connection'),
    );

    await expectLater(engine.start('s'), throwsStateError);

    // Default disposeSourceOnStop: the half-open broadcast is torn down.
    expect(track.stopped, isTrue, reason: 'no leaked camera on failed start');
    expect(stream.disposed, isTrue);
    expect(engine.isRunning, isFalse);
  });
}
