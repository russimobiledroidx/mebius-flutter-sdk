import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mebius/mebius.dart';
import 'package:mebius/src/internal/gateway_signaling.dart';

void main() {
  group('GatewaySignaling engine contract', () {
    test('route probe answers from the status line; a live FLV body never ends', () async {
      // An HTTP-FLV route streams for as long as the broadcast runs. A probe
      // that read the body would never return.
      final body = StreamController<List<int>>();
      addTearDown(body.close);
      var cancelled = false;
      body.onCancel = () => cancelled = true;
      final mock = MockClient.streaming((req, _) async {
        body.add([0x46, 0x4c, 0x56]); // "FLV", and nothing after it
        return http.StreamedResponse(body.stream, 200);
      });
      final sig = GatewaySignaling(
        gateway: 'https://engine.example',
        token: 'tok',
        httpClient: mock,
      );
      await sig
          .ensureScaleReachable('s', 'https://engine.example/d/fast/s?token=tok')
          .timeout(const Duration(seconds: 2));
      await pumpEventQueue();
      expect(cancelled, isTrue, reason: 'the connection must not stay open');
    });

    test('route probe still refuses a non-2xx route', () async {
      final mock = MockClient.streaming(
        (req, _) async => http.StreamedResponse(const Stream.empty(), 403),
      );
      final sig = GatewaySignaling(
        gateway: 'https://engine.example',
        token: 'tok',
        httpClient: mock,
      );
      await expectLater(
        sig.ensureScaleReachable('s', 'https://engine.example/d/fast/s?token=tok'),
        throwsA(isA<MebiusError>()),
      );
    });

    test('scale playlist URL uses /live and carries the token in the query', () {
      final sig = GatewaySignaling(
        gateway: 'https://engine.example/',
        token: 'tok123',
      );
      addTearDown(sig.dispose);
      expect(
        sig.scalePlaylistUrl('s_abc'),
        'https://engine.example/live/s_abc/index.m3u8?token=tok123',
      );
    });

    test('publish posts to /whip/{id}?token= with the SDP offer', () async {
      late Uri captured;
      String? capturedBody;
      final mock = MockClient((req) async {
        captured = req.url;
        capturedBody = req.body;
        return http.Response(
          'answer-sdp',
          201,
          headers: {'location': '/whip/s_abc/session1'},
        );
      });
      final sig = GatewaySignaling(
        gateway: 'https://engine.example',
        token: 'pubTOKEN',
        httpClient: mock,
      );
      final res = await sig.publishOffer('s_abc', 'offer-sdp');
      expect(captured.toString(),
          'https://engine.example/whip/s_abc?token=pubTOKEN',);
      expect(capturedBody, 'offer-sdp');
      expect(res.answerSdp, 'answer-sdp');
      expect(res.resourceUrl, 'https://engine.example/whip/s_abc/session1');
    });

    test('play posts to /whep/{id}?token=', () async {
      late Uri captured;
      final mock = MockClient((req) async {
        captured = req.url;
        return http.Response('answer', 201);
      });
      final sig = GatewaySignaling(
        gateway: 'https://engine.example',
        token: 'playTOKEN',
        httpClient: mock,
      );
      await sig.playOffer('s_xyz', 'offer');
      expect(captured.toString(),
          'https://engine.example/whep/s_xyz?token=playTOKEN',);
    });
  });
}
