import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mebius/mebius.dart';
import 'package:mebius/src/internal/gateway_signaling.dart';
import 'package:mebius/src/internal/playback_engine.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// What a live stream's duration reads as in Dart: ExoPlayer's TIME_UNSET
/// overflows to exactly 1 ms, and video_player clamps `value.position` to it.
const _liveDuration = Duration(milliseconds: 1);

/// A platform player for one live stream, as video_player sees it: a
/// meaningless duration, and a platform playhead given by [positionAt].
class _LivePlatform extends VideoPlayerPlatform {
  _LivePlatform({required this.positionAt, this.duration = _liveDuration});

  final Duration duration;
  final Duration Function(Duration sinceOpen) positionAt;
  int opened = 0;
  int callsAfterDispose = 0;
  final Map<int, DateTime> _openedAt = {};
  final Set<int> _disposed = {};
  final Map<int, StreamController<VideoEvent>> _events = {};

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = ++opened;
    _openedAt[id] = clock.now();
    // onCancel returns a future from this zone: without it cancel() hands back
    // a root-zone future that fake time never completes, and the controller's
    // dispose() would hang the test (not the app).
    _events[id] = StreamController<VideoEvent>(onCancel: Future<void>.value);
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    final events = _events[playerId]!;
    scheduleMicrotask(
      () => events.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: duration,
          size: const Size(1920, 1080),
        ),
      ),
    );
    return events.stream;
  }

  @override
  Future<Duration> getPosition(int playerId) async {
    if (_disposed.contains(playerId)) {
      // What a released native player does when asked anyway.
      callsAfterDispose += 1;
      throw StateError('player $playerId is disposed');
    }
    return positionAt(clock.now().difference(_openedAt[playerId]!));
  }

  @override
  Future<void> dispose(int playerId) async => _disposed.add(playerId);

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}
}

/// Android live HLS: the playhead is relative to the live window, so it rises
/// for one [segment] and then drops back by one on each playlist refresh.
Duration Function(Duration) _sawtooth(Duration segment) => (t) =>
    const Duration(seconds: 12) +
    Duration(microseconds: t.inMicroseconds % segment.inMicroseconds);

/// Plays one HLS route on [platform] for [watch] of fake time, then disposes
/// the player and reports what happened.
({
  int opens,
  List<MebiusPlayerEventType> events,
  Duration? clamped,
  int timersLeft,
}) _watch(_LivePlatform platform, {required Duration watch}) {
  late ({
    int opens,
    List<MebiusPlayerEventType> events,
    Duration? clamped,
    int timersLeft,
  }) out;
  fakeAsync((async) {
    VideoPlayerPlatform.instance = platform;
    final player = MebiusPlayer.internal(
      signaling: GatewaySignaling(
        gateway: 'https://gw.example',
        token: 'tok',
        httpClient: MockClient((_) async => http.Response('', 200)),
      ),
      mode: MebiusPlayerMode.scale,
      deliveries: const [MebiusDelivery(kind: 'wide', path: '/d/wide/s1')],
    );
    final events = <MebiusPlayerEventType>[];
    player.events.listen((e) => events.add(e.type));
    unawaited(player.play('s1'));
    async.elapse(watch);
    final clamped = player.engine.videoController?.value.position;
    unawaited(player.dispose());
    async.elapse(const Duration(seconds: 5));
    out = (
      opens: platform.opened,
      events: events,
      clamped: clamped,
      timersLeft: async.periodicTimerCount,
    );
  });
  return out;
}

int _count(List<MebiusPlayerEventType> events, MebiusPlayerEventType type) =>
    events.where((e) => e == type).length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('iOS live HLS: a playhead clamped to the 1 ms duration is not a stall',
      () {
    // The device log: AVPlayer playing, the SDK tearing it down every ~12 s.
    final r = _watch(
      _LivePlatform(positionAt: (t) => const Duration(seconds: 30) + t),
      watch: const Duration(seconds: 60),
    );
    // The reproduction holds: video_player's own position is stuck.
    expect(r.clamped, _liveDuration);
    expect(r.opens, 1, reason: 'no reopen over 60 s of a moving picture');
    expect(_count(r.events, MebiusPlayerEventType.buffering), 1);
    expect(r.timersLeft, 0, reason: 'nothing keeps polling after dispose');
  });

  for (final seconds in [2, 6]) {
    test('Android live HLS: a ${seconds}s-segment sawtooth playhead is not a '
        'stall', () {
      final r = _watch(
        _LivePlatform(positionAt: _sawtooth(Duration(seconds: seconds))),
        watch: const Duration(seconds: 60),
      );
      expect(r.opens, 1);
      expect(_count(r.events, MebiusPlayerEventType.buffering), 1);
      expect(r.timersLeft, 0);
    });
  }

  test('a truly frozen platform playhead still recovers at ~10–12 s', () {
    Duration frozen(Duration _) => const Duration(seconds: 30);
    expect(
      _watch(
        _LivePlatform(positionAt: frozen),
        watch: const Duration(seconds: 9),
      ).opens,
      1,
    );
    final r = _watch(
      _LivePlatform(positionAt: frozen),
      watch: const Duration(seconds: 15),
    );
    expect(r.opens, 2, reason: 'the stall detector reopened the route');
    expect(_count(r.events, MebiusPlayerEventType.buffering), 2);
    expect(r.timersLeft, 0);
  });

  test('a disposed player is never asked for its playhead', () {
    // Recovery releases a controller every cycle; the sampler must stop with
    // it rather than poll a released native player.
    final platform =
        _LivePlatform(positionAt: (_) => const Duration(seconds: 30));
    final r = _watch(platform, watch: const Duration(seconds: 40));
    expect(r.opens, greaterThan(1));
    expect(platform.callsAfterDispose, 0);
    expect(r.timersLeft, 0);
  });

  test('the first frame is read from the platform playhead', () {
    // value.position is clamped to the duration forever, so a check on it
    // could only ever see 1 ms (or zero) of picture.
    final r = _watch(
      _LivePlatform(
        duration: Duration.zero,
        positionAt: (t) => const Duration(seconds: 30) + t,
      ),
      watch: const Duration(seconds: 3),
    );
    expect(r.clamped, Duration.zero);
    expect(r.opens, 1);
    expect(r.events, contains(MebiusPlayerEventType.playing));
  });

  group('ForwardProgress', () {
    test('adds forward steps, ignores backward jumps and unknowns', () {
      final p = ForwardProgress()
        ..add(const Duration(seconds: 12))
        ..add(const Duration(seconds: 13))
        ..add(null)
        ..add(const Duration(seconds: 11)) // playlist refresh
        ..add(const Duration(milliseconds: 11500));
      expect(p.totalMs, 1500);
    });

    test('a frozen playhead adds nothing', () {
      final p = ForwardProgress();
      for (var i = 0; i < 10; i++) {
        p.add(const Duration(seconds: 5));
      }
      expect(p.totalMs, 0);
    });
  });
}
