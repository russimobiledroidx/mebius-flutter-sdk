import 'package:flutter_test/flutter_test.dart';
import 'package:mebius/mebius.dart';
import 'package:mebius/src/internal/gateway_signaling.dart';
import 'package:mebius/src/internal/playback_engine.dart';

/// The token `deliveries` a laddered (SportStream) tenant receives.
final List<MebiusDelivery> _laddered = MebiusDelivery.listFromJson([
  {
    'kind': 'fast',
    'path': '/d/fast/s1',
    'renditions': [
      for (final (id, h, kbps) in [
        ('1080p', 1080, 5000),
        ('720p', 720, 2800),
        ('480p', 480, 1000),
      ])
        {'id': id, 'height': h, 'bitrateKbps': kbps, 'path': '/d/fast/s1/$id'},
    ],
  },
  {
    'kind': 'wide',
    'path': '/d/wide/s1',
    'renditions': [
      for (final (id, h, kbps) in [
        ('1080p', 1080, 5000),
        ('720p', 720, 2800),
        ('480p', 480, 1000),
      ])
        {'id': id, 'height': h, 'bitrateKbps': kbps, 'path': '/d/wide/s1/$id'},
    ],
  },
  {'kind': 'local', 'path': '/live/s1/index.m3u8'},
]);

/// The same stream for a tenant without a ladder (Shortie): no `renditions`.
final List<MebiusDelivery> _plain = MebiusDelivery.listFromJson([
  {'kind': 'fast', 'path': '/d/fast/s1'},
  {'kind': 'wide', 'path': '/d/wide/s1'},
  {'kind': 'local', 'path': '/live/s1/index.m3u8'},
]);

List<String?> _paths(List<PlaybackCandidate> c) =>
    c.map((x) => x.path).toList();

void main() {
  group('renditions parsing', () {
    test('reads the ladder, ignoring unknown fields', () {
      final d = MebiusDelivery.tryFromJson({
        'kind': 'wide',
        'path': '/d/wide/s1',
        'future': true,
        'renditions': [
          {
            'id': '720p',
            'height': 720,
            'bitrateKbps': 2800,
            'path': '/d/wide/s1/720p',
            'codec': 'h264',
          },
        ],
      })!;
      expect(d.renditions.single.id, '720p');
      expect(d.renditions.single.height, 720);
      expect(d.renditions.single.bitrateKbps, 2800);
      expect(d.renditions.single.path, '/d/wide/s1/720p');
    });

    test('absent or malformed renditions mean no ladder', () {
      expect(_plain.every((d) => d.renditions.isEmpty), isTrue);
      final d = MebiusDelivery.tryFromJson(
        {'kind': 'wide', 'path': '/d/wide/s1', 'renditions': 'nope'},
      )!;
      expect(d.renditions, isEmpty);
    });

    test('skips bad rungs, including ones that would leak the token', () {
      final d = MebiusDelivery.tryFromJson({
        'kind': 'wide',
        'path': '/d/wide/s1',
        'renditions': [
          null,
          {'id': '720p', 'path': '/d/wide/s1/720p'}, // no height
          {'id': 'x', 'height': 720, 'path': 'https://evil.example/x'},
          {'id': '480p', 'height': 480, 'path': '/d/wide/s1/480p'},
        ],
      })!;
      expect(d.renditions.map((r) => r.id), ['480p']);
      expect(d.renditions.single.bitrateKbps, 0);
    });
  });

  group('pickRendition', () {
    final rungs = _laddered.first.renditions;

    test('manual id opens that rung; unknown id falls back to source', () {
      expect(pickRendition(rungs, quality: '720p')?.path, '/d/fast/s1/720p');
      expect(pickRendition(rungs, quality: '4k'), isNull);
    });

    test('uncapped auto opens the route itself', () {
      expect(pickRendition(rungs), isNull);
    });

    test('capped auto opens the highest rung under the cap, else lowest', () {
      expect(pickRendition(rungs, maxHeight: 1080)?.id, '1080p');
      expect(pickRendition(rungs, maxHeight: 720)?.id, '720p');
      expect(pickRendition(rungs, maxHeight: 600)?.id, '480p');
      expect(pickRendition(rungs, maxHeight: 240)?.id, '480p');
    });

    test('no ladder never picks a rung', () {
      expect(pickRendition(const [], quality: '720p', maxHeight: 480), isNull);
    });
  });

  group('buildCandidates with a ladder', () {
    test('uncapped auto plays the wide master (native ABR), not FLV', () {
      final c = buildCandidates(PlaybackPipeline.scale, _laddered, flv: true);
      expect(_paths(c), ['/d/wide/s1', '/live/s1/index.m3u8', null]);
      expect(c.any((x) => x.flv), isFalse);
    });

    test('a manual pick opens that rung on FLV and on wide, same token', () {
      final c = buildCandidates(
        PlaybackPipeline.scale,
        _laddered,
        flv: true,
        quality: '720p',
      );
      expect(_paths(c), [
        '/d/fast/s1/720p',
        '/d/wide/s1/720p',
        '/live/s1/index.m3u8',
        null,
      ]);
      expect(c.first.flv, isTrue);

      // Opened exactly like `path`: gateway-relative, same token appended.
      final s = GatewaySignaling(gateway: 'https://gw.example', token: 'tok');
      expect(
        s.deliveryUrl(c[1].path!),
        'https://gw.example/d/wide/s1/720p?token=tok',
      );
      s.dispose();
    });

    test('capped auto opens the capped rung', () {
      final c = buildCandidates(
        PlaybackPipeline.scale,
        _laddered,
        maxHeight: 720,
      );
      expect(_paths(c), ['/d/wide/s1/720p', '/live/s1/index.m3u8', null]);
    });

    test('no ladder: quality settings change nothing', () {
      for (final flv in [true, false]) {
        final base = buildCandidates(PlaybackPipeline.scale, _plain, flv: flv);
        final tuned = buildCandidates(
          PlaybackPipeline.scale,
          _plain,
          flv: flv,
          quality: '720p',
          maxHeight: 480,
        );
        expect(_paths(tuned), _paths(base));
        expect(tuned.map((x) => x.flv), base.map((x) => x.flv));
      }
      expect(
        _paths(buildCandidates(PlaybackPipeline.scale, _plain, flv: true)),
        ['/d/fast/s1', '/d/wide/s1', '/live/s1/index.m3u8', null],
      );
    });
  });

  group('MebiusPlayer quality API', () {
    setUp(() {
      Mebius.resetForTesting();
      Mebius.init(appId: 'app_1', gateway: 'https://gw.example');
    });
    tearDown(Mebius.resetForTesting);

    test('qualities is empty without a ladder', () async {
      final client = Mebius.connect(token: 'tok', deliveries: _plain);
      final player = client.createPlayer();
      expect(player.qualities, isEmpty);
      await expectLater(player.setQuality('720p'), throwsA(isA<MebiusError>()));
      await player.setQuality('auto'); // always accepted
      await client.disconnect();
    });

    test('qualities lists the ladder; setQuality selects the rung URL', () async {
      final client = Mebius.connect(token: 'tok', deliveries: _laddered);
      final player = client.createPlayer();
      expect(player.qualities.map((q) => q.id), ['1080p', '720p', '480p']);
      expect(player.qualities.first.bitrateKbps, 5000);

      // Not playing: the choice is stored for the next play.
      await player.setQuality('480p');
      expect(player.engine.quality, '480p');
      await player.setMaxQuality(720);
      expect(player.engine.maxHeight, 720);
      await player.setQuality('auto');
      expect(player.engine.quality, isNull);
      await player.setMaxQuality(0);
      expect(player.engine.maxHeight, isNull);
      await client.disconnect();
    });
  });
}
