import 'package:flutter_test/flutter_test.dart';
import 'package:mebius/mebius.dart';
import 'package:mebius/src/internal/gateway_signaling.dart';
import 'package:mebius/src/internal/playback_engine.dart';

/// The delivery list a gateway with a CDN configured returns today.
const _deliveries = <MebiusDelivery>[
  MebiusDelivery(kind: 'fast', path: '/d/fast/s_abc'),
  MebiusDelivery(kind: 'wide', path: '/d/wide/s_abc'),
  MebiusDelivery(kind: 'local', path: '/live/s_abc/index.m3u8'),
];

void main() {
  group('MebiusDelivery parsing', () {
    test('reads a well-formed list', () {
      final list = MebiusDelivery.listFromJson([
        {'kind': 'wide', 'path': '/d/wide/s1'},
      ]);
      expect(list, hasLength(1));
      expect(list.first.kind, 'wide');
      expect(list.first.path, '/d/wide/s1');
    });

    test('skips malformed entries rather than throwing', () {
      // The list arrives from a network response, so a bad entry must degrade to
      // one fewer route, never to a crash on a viewer's device.
      final list = MebiusDelivery.listFromJson([
        null,
        'nope',
        {'kind': 'wide'},
        {'path': '/d/wide/s1'},
        {'kind': 1, 'path': 2},
        {'kind': 'wide', 'path': '/d/wide/s1'},
      ]);
      expect(list, hasLength(1));
    });

    test('tolerates a missing or wrongly-typed deliveries field', () {
      expect(MebiusDelivery.listFromJson(null), isEmpty);
      expect(MebiusDelivery.listFromJson('deliveries'), isEmpty);
      expect(MebiusDelivery.listFromJson(<Object>[]), isEmpty);
    });
  });

  group('MebiusDelivery.isResolvable', () {
    test('accepts a plain gateway-relative path', () {
      expect(const MebiusDelivery(kind: 'wide', path: '/d/wide/s1').isResolvable, isTrue);
    });

    test('rejects anything that could send the token to another host', () {
      // The access token is a bearer credential; a delivery path is untrusted
      // response data. An absolute or protocol-relative path here is how that
      // token would end up at a host Mebius did not choose.
      for (final path in <String>[
        'https://evil.example/steal',
        '//evil.example/steal',
        'http://evil.example/x',
        'd/wide/s1',
        '',
      ]) {
        expect(
          MebiusDelivery(kind: 'wide', path: path).isResolvable,
          isFalse,
          reason: 'accepted $path',
        );
      }
    });
  });

  group('buildCandidates', () {
    test('keeps the gateway order and puts the origin route last', () {
      final c = buildCandidates(PlaybackPipeline.scale, _deliveries);
      // wide + local from the gateway, then the origin playlist. Origin must be
      // last: every byte of it is billed to us, unlike an edge route.
      expect(c, hasLength(3));
      expect(c[0].path, '/d/wide/s_abc');
      expect(c[1].path, '/live/s_abc/index.m3u8');
      expect(c.last.path, isNull);
    });

    test('never offers the buffered route on this platform', () {
      // The platform player cannot play it. Declaring it would repeat the exact
      // mistake of shipping a mode that can never play.
      final c = buildCandidates(PlaybackPipeline.scale, _deliveries);
      expect(c.map((x) => x.path), isNot(contains('/d/fast/s_abc')));
    });

    test('tries the real-time route first for low latency, then degrades', () {
      final c = buildCandidates(PlaybackPipeline.lowLatency, _deliveries);
      expect(c.first.pipeline, PlaybackPipeline.lowLatency);
      expect(c.length, greaterThan(1), reason: 'must be able to fall back');
    });

    test('drops a delivery whose path is not resolvable', () {
      final c = buildCandidates(PlaybackPipeline.scale, const [
        MebiusDelivery(kind: 'wide', path: 'https://evil.example/x'),
      ]);
      expect(c, hasLength(1)); // origin fallback only
      expect(c.single.path, isNull);
    });

    test('still yields a playable route with no deliveries at all', () {
      // Every existing integration passes none. They must keep working.
      expect(buildCandidates(PlaybackPipeline.scale, const []), hasLength(1));
    });

    test('skips an unknown kind rather than guessing', () {
      final c = buildCandidates(PlaybackPipeline.scale, const [
        MebiusDelivery(kind: 'quantum', path: '/d/quantum/s1'),
      ]);
      expect(c, hasLength(1));
    });
  });

  group('GatewaySignaling.deliveryUrl', () {
    test('resolves against the gateway and carries the token', () {
      final s = GatewaySignaling(gateway: 'https://gw.example', token: 'tok');
      final uri = Uri.parse(s.deliveryUrl('/d/wide/s1'));
      expect(uri.origin, 'https://gw.example');
      expect(uri.path, '/d/wide/s1');
      expect(uri.queryParameters['token'], 'tok');
      s.dispose();
    });
  });

  group('Mebius.connect', () {
    setUp(() {
      Mebius.resetForTesting();
      Mebius.init(appId: 'app_1', gateway: 'https://gw.example');
    });
    tearDown(Mebius.resetForTesting);

    test('accepts deliveries and still connects without them', () async {
      final withList = Mebius.connect(token: 'tok', deliveries: _deliveries);
      expect(withList.isConnected, isFalse); // connects on a microtask
      await Future<void>.delayed(Duration.zero);
      expect(withList.isConnected, isTrue);
      await withList.disconnect();

      final without = Mebius.connect(token: 'tok');
      await Future<void>.delayed(Duration.zero);
      expect(without.isConnected, isTrue);
      await without.disconnect();
    });

    test('a plain player no longer defaults to a real-time session', () async {
      // Defaulting to the real-time route spent a per-viewer server session on
      // every audience member; only a monitor should ask for one.
      final client = Mebius.connect(token: 'tok', deliveries: _deliveries);
      await Future<void>.delayed(Duration.zero);
      expect(client.createPlayer().mode, MebiusPlayerMode.auto);
      expect(client.createMonitor().mode, MebiusPlayerMode.lowLatency);
      await client.disconnect();
    });
  });

  test('the first-frame budget is the one the SDKs agreed on', () {
    // Mirrored across every Mebius SDK (web, Flutter, Android, iOS) so a viewer
    // sees the same behaviour on each. Changing it here alone is a bug.
    expect(kFirstFrameTimeout, const Duration(seconds: 8));
  });
}
