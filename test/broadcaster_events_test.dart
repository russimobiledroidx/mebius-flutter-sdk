import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mebius/src/internal/gateway_signaling.dart';
import 'package:mebius/src/mebius_broadcaster.dart';
import 'package:mebius/src/mebius_error.dart';
import 'package:mebius/src/mebius_events.dart';

/// How the broadcaster maps engine connection states onto its event stream,
/// and that a state arriving after stop raises nothing. The engine's
/// `onConnectionState` is the seam the live peer connection fires through;
/// driving it directly needs no native WebRTC. (The pc -> engine wiring itself
/// is covered in broadcast_wiring_test.)
GatewaySignaling _signaling() => GatewaySignaling(
      gateway: 'https://gw.example',
      token: 't',
      httpClient: MockClient((_) async => http.Response('', 404)),
    );

MebiusBroadcaster _broadcaster() => MebiusBroadcaster.internal(
      signaling: _signaling(),
      video: true,
      audio: false,
    );

void main() {
  test('a failed connection emits connectionState then an error event',
      () async {
    final b = _broadcaster();
    final events = <MebiusBroadcasterEvent>[];
    final sub = b.events.listen(events.add);

    b.engine.onConnectionState!('failed');
    await Future<void>.delayed(Duration.zero);

    expect(
      events.map((e) => e.type),
      [
        MebiusBroadcasterEventType.connectionState,
        MebiusBroadcasterEventType.error,
      ],
    );
    expect(events[0].connectionState, 'failed');
    expect(events[1].error?.code, MebiusErrorCode.connectionFailed);

    await sub.cancel();
    await b.dispose();
  });

  test('a brief disconnect that recovers emits states but no error', () async {
    final b = _broadcaster();
    final events = <MebiusBroadcasterEvent>[];
    final sub = b.events.listen(events.add);

    b.engine.onConnectionState!('disconnected');
    b.engine.onConnectionState!('connected');
    await Future<void>.delayed(Duration.zero);

    expect(
      events.every((e) => e.type != MebiusBroadcasterEventType.error),
      isTrue,
    );
    expect(events.map((e) => e.connectionState), ['disconnected', 'connected']);

    await sub.cancel();
    await b.dispose();
  });

  test('a state arriving after stop raises nothing', () async {
    final b = _broadcaster();
    final events = <MebiusBroadcasterEvent>[];
    final sub = b.events.listen(events.add);

    await b.stop(); // disposes the watch
    b.engine.onConnectionState!('failed');
    await Future<void>.delayed(Duration.zero);

    // `stopped` is expected; a failure or connectionState after stop is not.
    expect(
      events.where(
        (e) =>
            e.type == MebiusBroadcasterEventType.error ||
            e.type == MebiusBroadcasterEventType.connectionState,
      ),
      isEmpty,
      reason: 'no error or connectionState after stop',
    );

    await sub.cancel();
    await b.dispose();
  });
}
