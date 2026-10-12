import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mebius/mebius.dart';
import 'package:mebius/src/internal/gateway_signaling.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// AVPlayer on iOS live HLS, as video_player sees it: the reported duration is
/// the live window, and the platform playhead runs on past it. video_player
/// clamps `value.position` to that duration; the platform does not.
class _LivePlatform extends VideoPlayerPlatform {
  _LivePlatform({required this.duration, required this.positionAt});

  final Duration duration;
  final Duration Function(Duration sinceOpen) positionAt;
  int opened = 0;
  final Map<int, DateTime> _openedAt = {};
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
  Future<Duration> getPosition(int playerId) async =>
      positionAt(clock.now().difference(_openedAt[playerId]!));

  @override
  Future<void> dispose(int playerId) async {}

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

/// Plays one HLS route on [platform] for [watch] of fake time and reports how
/// many times the route was opened and what the player said.
({int opens, List<MebiusPlayerEventType> events, Duration? clamped}) _watch(
  _LivePlatform platform, {
  required Duration watch,
}) {
  late ({
    int opens,
    List<MebiusPlayerEventType> events,
    Duration? clamped,
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
    out = (
      opens: platform.opened,
      events: List.of(events),
      clamped: player.engine.videoController?.value.position,
    );
    unawaited(player.dispose());
    async.flushMicrotasks();
  });
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('iOS live HLS: a playhead clamped at the 6 s duration is not a stall',
      () {
    // The device log: AVPlayer playing, the SDK tearing it down every ~12 s.
    final r = _watch(
      _LivePlatform(
        duration: const Duration(seconds: 6),
        positionAt: (t) => t,
      ),
      watch: const Duration(seconds: 60),
    );
    // The reproduction holds: video_player's own position is stuck at 6 s.
    expect(r.clamped, const Duration(seconds: 6));
    expect(r.opens, 1, reason: 'no reopen over 60 s of a moving picture');
    expect(r.events, [
      MebiusPlayerEventType.buffering,
      MebiusPlayerEventType.playing,
      ...List.filled(r.events.length - 2, MebiusPlayerEventType.stats),
    ]);
  });

  test('a truly frozen platform playhead still recovers at ~10–12 s', () {
    final platform = _LivePlatform(
      duration: const Duration(seconds: 6),
      positionAt: (_) => const Duration(seconds: 2),
    );
    expect(
      _watch(platform, watch: const Duration(seconds: 9)).opens,
      1,
    );
    final r = _watch(
      _LivePlatform(
        duration: const Duration(seconds: 6),
        positionAt: (_) => const Duration(seconds: 2),
      ),
      watch: const Duration(seconds: 15),
    );
    expect(r.opens, 2, reason: 'the stall detector reopened the route');
    expect(
      r.events.where((e) => e == MebiusPlayerEventType.buffering).length,
      2,
    );
  });

  test('the first frame is read from the platform playhead', () {
    // A live item whose duration reads as zero: value.position is clamped to
    // zero forever, so the old check never saw a frame and walked away.
    final r = _watch(
      _LivePlatform(duration: Duration.zero, positionAt: (t) => t),
      watch: const Duration(seconds: 3),
    );
    expect(r.clamped, Duration.zero);
    expect(r.opens, 1);
    expect(r.events, contains(MebiusPlayerEventType.playing));
  });
}
