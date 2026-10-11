import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mebius/mebius.dart';
import 'package:mebius/src/internal/gateway_signaling.dart';
import 'package:mebius/src/internal/playback_engine.dart';

List<Map<String, Object>> _rungs(String base) => [
      for (final (id, h, kbps) in [
        ('1080p', 1080, 5000),
        ('720p', 720, 2800),
        ('480p', 480, 1000),
      ])
        {'id': id, 'height': h, 'bitrateKbps': kbps, 'path': '$base/$id'},
    ];

/// The token `deliveries` a laddered (SportStream) tenant receives.
final List<MebiusDelivery> _laddered = MebiusDelivery.listFromJson([
  {'kind': 'fast', 'path': '/d/fast/s1', 'renditions': _rungs('/d/fast/s1')},
  {'kind': 'wide', 'path': '/d/wide/s1', 'renditions': _rungs('/d/wide/s1')},
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

/// Plays nothing: records each route the engine opens and lets a test decide
/// when (via [hold]) and whether (via [failing]) it produces a frame.
class _FakeEngine extends PlaybackEngine {
  _FakeEngine(List<MebiusDelivery> d)
      : super(
          signaling: GatewaySignaling(gateway: 'https://gw.example', token: 't'),
          pipeline: PlaybackPipeline.scale,
        ) {
    deliveries = d;
  }

  final Set<String?> failing = <String?>{};
  Completer<void>? hold;
  int inFlight = 0;
  int maxInFlight = 0;
  String? playing;

  @override
  bool get isPlaying => playing != null;

  @override
  Future<bool> openCandidate(String streamId, PlaybackCandidate c) async {
    inFlight += 1;
    maxInFlight = math.max(maxInFlight, inFlight);
    try {
      final h = hold;
      if (h != null) {
        await h.future;
      }
      if (failing.contains(c.path)) {
        return false;
      }
      playing = c.path;
      return true;
    } finally {
      inFlight -= 1;
    }
  }

  @override
  Future<void> stop() async {
    playing = null;
  }
}

({MebiusPlayer player, _FakeEngine engine, List<MebiusQualityChange> changes})
    _player({
  List<MebiusDelivery>? deliveries,
  MebiusPlayerMode mode = MebiusPlayerMode.auto,
}) {
  final engine = _FakeEngine(deliveries ?? _laddered);
  final player = MebiusPlayer.internal(
    signaling: engine.signaling,
    mode: mode,
    deliveries: engine.deliveries,
    engine: engine,
  );
  final changes = <MebiusQualityChange>[];
  player.qualityChanged.listen(changes.add);
  return (player: player, engine: engine, changes: changes);
}

const _auto = MebiusQualityChange(id: null, auto: true);
MebiusQualityChange _manual(String id) =>
    MebiusQualityChange(id: id, auto: false);

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
      expect(
        d.renditions.single,
        const MebiusQuality(
          id: '720p',
          height: 720,
          bitrateKbps: 2800,
          path: '/d/wide/s1/720p',
        ),
      );
      expect(d.toString(), contains('720p'));
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

  group('rung choice', () {
    final rungs = _laddered.first.renditions;

    test('pickRendition: highest under the cap, else lowest', () {
      expect(pickRendition(rungs, null)?.id, '1080p');
      expect(pickRendition(rungs, 720)?.id, '720p');
      expect(pickRendition(rungs, 600)?.id, '480p');
      expect(pickRendition(rungs, 240)?.id, '480p');
      expect(pickRendition(const [], 480), isNull);
    });

    test('allowedRungs: ladder order, unknown ids ignored, none = all', () {
      expect(allowedRungs(rungs, null), rungs);
      expect(allowedRungs(rungs, const []), rungs);
      expect(
        allowedRungs(rungs, const ['480p', '4k', '1080p']).map((r) => r.id),
        ['1080p', '480p'],
      );
      expect(allowedRungs(rungs, const ['4k']), rungs);
    });
  });

  group('buildCandidates with a ladder', () {
    test('uncapped auto: wide master first, FLV kept as its fallback', () {
      final c = buildCandidates(PlaybackPipeline.scale, _laddered, flv: true);
      expect(
        _paths(c),
        ['/d/wide/s1', '/d/fast/s1', '/live/s1/index.m3u8', null],
      );
      expect(c.map((x) => x.flv), [false, true, false, false]);
      expect(c.first.qualityId, isNull);
    });

    test('a manual pick opens only that rung, FLV first; overrides the cap', () {
      final c = buildCandidates(
        PlaybackPipeline.scale,
        _laddered,
        flv: true,
        quality: '720p',
        maxHeight: 480,
      );
      expect(_paths(c), ['/d/fast/s1/720p', '/d/wide/s1/720p']);
      expect(c.map((x) => x.qualityId), ['720p', '720p']);
      expect(c.first.flv, isTrue);

      // Opened exactly like `path`: gateway-relative, same token appended.
      final s = GatewaySignaling(gateway: 'https://gw.example', token: 'tok');
      expect(
        s.deliveryUrl(c[1].path!),
        'https://gw.example/d/wide/s1/720p?token=tok',
      );
      s.dispose();
    });

    test('a pick no route has yields nothing, so the engine falls to auto', () {
      expect(
        buildCandidates(PlaybackPipeline.scale, _laddered, quality: '4k'),
        isEmpty,
      );
    });

    test('capped auto opens the capped rung, FLV first', () {
      final c = buildCandidates(
        PlaybackPipeline.scale,
        _laddered,
        flv: true,
        maxHeight: 720,
      );
      expect(_paths(c), [
        '/d/fast/s1/720p',
        '/d/wide/s1/720p',
        '/live/s1/index.m3u8',
        null,
      ]);
    });

    test('allowed set: master carries q, FLV takes the highest allowed rung', () {
      final c = buildCandidates(
        PlaybackPipeline.scale,
        _laddered,
        flv: true,
        allowed: const ['1080p', '720p'],
      );
      expect(_paths(c), [
        '/d/wide/s1?q=1080p,720p',
        '/d/fast/s1/1080p',
        '/live/s1/index.m3u8',
        null,
      ]);
      final s = GatewaySignaling(gateway: 'https://gw.example', token: 'tok');
      expect(
        s.deliveryUrl(c.first.path!),
        'https://gw.example/d/wide/s1?q=1080p,720p&token=tok',
      );
      s.dispose();
    });

    test('allowed set under a cap: highest allowed rung at or under it', () {
      final c = buildCandidates(
        PlaybackPipeline.scale,
        _laddered,
        flv: true,
        maxHeight: 1000,
        allowed: const ['1080p', '480p'],
      );
      expect(_paths(c).take(2), ['/d/fast/s1/480p', '/d/wide/s1/480p']);
    });

    test('no ladder: quality settings change nothing', () {
      for (final flv in [true, false]) {
        final base = buildCandidates(PlaybackPipeline.scale, _plain, flv: flv);
        final tuned = buildCandidates(
          PlaybackPipeline.scale,
          _plain,
          flv: flv,
          maxHeight: 480,
          allowed: const ['720p'],
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
    test('no ladder: qualities empty, unknown ids rejected, no events',
        () async {
      final t = _player(deliveries: _plain);
      expect(t.player.qualities, isEmpty);
      await expectLater(
        t.player.setQuality('720p'),
        throwsA(isA<MebiusError>()),
      );
      await t.player.play('s1');
      expect(t.engine.playing, '/d/fast/s1'); // exactly as before 0.6.0
      expect(t.changes, isEmpty);
      await t.player.dispose();
    });

    test('low-latency mode: no qualities, setQuality is a no-op', () async {
      final t = _player(mode: MebiusPlayerMode.lowLatency);
      expect(t.player.qualities, isEmpty);
      await t.player.setQuality('720p');
      expect(t.engine.quality, isNull);
      await t.player.dispose();
    });

    test('play reports auto; setQuality reopens on the rung', () async {
      final t = _player();
      expect(t.player.qualities.map((q) => q.id), ['1080p', '720p', '480p']);
      await t.player.play('s1');
      expect(t.engine.playing, '/d/wide/s1');
      await t.player.setQuality('720p');
      expect(t.engine.playing, '/d/fast/s1/720p');
      await t.player.setMaxQuality(480); // manual pick ignores the cap
      expect(t.engine.playing, '/d/fast/s1/720p');
      expect(t.changes, [_auto, _manual('720p')]);
      await t.player.dispose();
    });

    test('M1: a second pick during a reopen wins and is reported truthfully',
        () async {
      final t = _player();
      await t.player.play('s1');
      t.engine.hold = Completer<void>();
      final first = t.player.setQuality('720p');
      await Future<void>.delayed(Duration.zero); // 720p open is now in flight
      await t.player.setQuality('480p'); // returns at once: open in flight
      t.engine.hold!.complete();
      await first;
      expect(t.engine.playing, '/d/fast/s1/480p');
      expect(t.changes, [_auto, _manual('720p'), _manual('480p')]);
      expect(t.engine.maxInFlight, 1);
      await t.player.dispose();
    });

    test('M2: a pick during the first play never opens a second route',
        () async {
      final t = _player();
      t.engine.hold = Completer<void>();
      final playing = t.player.play('s1');
      await t.player.setQuality('720p');
      await t.player.setMaxQuality(480);
      t.engine.hold!.complete();
      await playing;
      expect(t.engine.maxInFlight, 1);
      expect(t.engine.playing, '/d/fast/s1/720p');
      expect(t.changes, [_auto, _manual('720p')]);
      await t.player.dispose();
    });

    test('a pinned rung that will not open falls back to auto', () async {
      final t = _player();
      await t.player.play('s1');
      t.engine.failing.addAll(['/d/fast/s1/720p', '/d/wide/s1/720p']);
      await t.player.setQuality('720p');
      expect(t.engine.playing, '/d/wide/s1');
      expect(t.engine.quality, isNull);
      expect(t.changes.last, _auto);
      await t.player.dispose();
    });

    test('L2: a reopen rescued by recovery still reports the quality',
        () async {
      final t = _player();
      await t.player.play('s1');
      t.engine.failing.addAll([
        '/d/fast/s1/720p',
        '/d/wide/s1/720p',
        '/d/wide/s1',
        '/d/fast/s1',
        '/live/s1/index.m3u8',
        null,
      ]);
      await t.player.setQuality('720p'); // nothing opens: recovery takes over
      t.engine.failing.clear();
      final rescued = t.player.qualityChanged.first;
      await rescued.timeout(const Duration(seconds: 5));
      expect(t.engine.playing, '/d/wide/s1');
      expect(t.changes, [_auto, _auto]);
      await t.player.dispose();
    });

    test('L3: a stale reopen does not stop a newer session', () async {
      final t = _player();
      await t.player.play('s1');
      final staleOpen = t.engine.hold = Completer<void>();
      final stale = t.player.setQuality('720p');
      await Future<void>.delayed(Duration.zero); // 720p open is in flight
      await t.player.stop();
      final replayOpen = t.engine.hold = Completer<void>();
      final replay = t.player.play('s1');
      replayOpen.complete();
      await replay;
      staleOpen.complete(); // the stale reopen lands after the replay
      await stale;
      expect(t.engine.isPlaying, isTrue);
      await t.player.dispose();
    });

    test('setAllowedQualities filters qualities and steers auto', () async {
      final t = _player();
      final lists = <List<String>>[];
      t.player.qualitiesChanged.listen(
        (q) => lists.add(q.map((r) => r.id).toList()),
      );
      await t.player.play('s1');
      await t.player.setQuality('480p');
      await t.player.setAllowedQualities(['1080p', '720p', '4k']);
      expect(t.player.qualities.map((q) => q.id), ['1080p', '720p']);
      // The pinned 480p is no longer allowed: back to auto, within the set.
      expect(t.engine.quality, isNull);
      expect(t.engine.playing, '/d/wide/s1?q=1080p,720p');
      await expectLater(
        t.player.setQuality('480p'),
        throwsA(isA<MebiusError>()),
      );
      await t.player.setAllowedQualities(['720p', '1080p']); // same set
      await t.player.setAllowedQualities(['4k']); // names none: all allowed
      expect(t.player.qualities, hasLength(3));
      expect(lists, [
        ['1080p', '720p', '480p'],
        ['1080p', '720p'],
        ['1080p', '720p', '480p'],
      ]);
      // Survives a replay.
      await t.player.setAllowedQualities(['720p', '480p']);
      await t.player.stop();
      await t.player.play('s1');
      expect(t.engine.playing, '/d/wide/s1?q=720p,480p');
      await t.player.dispose();
    });
  });
}
