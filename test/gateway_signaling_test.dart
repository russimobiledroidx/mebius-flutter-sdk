import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mebius/src/internal/gateway_signaling.dart';

void main() {
  group('GatewaySignaling engine contract', () {
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
