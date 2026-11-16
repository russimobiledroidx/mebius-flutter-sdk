import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mebius/src/internal/broadcast_engine.dart';
import 'package:mebius/src/internal/gateway_signaling.dart';
import 'package:mebius/src/internal/playback_engine.dart';

class _Stream extends Fake implements MediaStream {
  @override
  List<MediaStreamTrack> getTracks() => const [];

  @override
  Future<void> dispose() async {}
}

const _turn = <Map<String, dynamic>>[
  {
    'urls': ['turn:turn.example:3478'],
    'username': 'u',
    'credential': 'c',
  },
];

void main() {
  final signaling = GatewaySignaling(
    gateway: 'https://gw.example',
    token: 't',
    httpClient: MockClient((_) async => http.Response('', 404)),
  );

  // Captures the configuration, then fails the open so nothing native runs.
  Map<String, dynamic>? seen;
  Future<RTCPeerConnection> capture(Map<String, dynamic> config) async {
    seen = config;
    throw StateError('no native peer connection in tests');
  }

  setUp(() => seen = null);

  test('a broadcaster opens its peer connection with the supplied servers',
      () async {
    final engine = BroadcastEngine(
      signaling: signaling,
      video: true,
      audio: false,
      source: () async => _Stream(),
      iceServers: _turn,
      openPeerConnection: capture,
    );
    await expectLater(engine.start('s'), throwsStateError);
    expect(seen?['iceServers'], _turn);
  });

  test('a real-time player opens its peer connection with the supplied servers',
      () async {
    final engine = PlaybackEngine(
      signaling: signaling,
      pipeline: PlaybackPipeline.lowLatency,
      iceServers: _turn,
      openPeerConnection: capture,
    );
    await expectLater(engine.start('s'), throwsA(anything));
    expect(seen?['iceServers'], _turn);
  });

  test('without servers the configuration is what it always was', () {
    expect(peerConfiguration(const []), {
      'iceServers': <Map<String, dynamic>>[],
      'sdpSemantics': 'unified-plan',
    });
  });
}
