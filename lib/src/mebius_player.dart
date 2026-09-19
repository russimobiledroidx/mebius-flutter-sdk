import 'dart:async';

import 'package:mebius/src/internal/gateway_signaling.dart';
import 'package:mebius/src/internal/playback_engine.dart';
import 'package:mebius/src/internal/recovery.dart';
import 'package:mebius/src/mebius_delivery.dart';
import 'package:mebius/src/mebius_error.dart';
import 'package:mebius/src/mebius_events.dart';

/// Selects the playback strategy used by a [MebiusPlayer].
enum MebiusPlayerMode {
  /// Let Mebius choose per viewer, and fall back on its own if the chosen route
  /// stops delivering frames. The recommended default.
  auto,

  /// Optimized for the lowest possible glass-to-glass latency. Best for
  /// interactive use cases such as auctions, betting or two-way experiences.
  lowLatency,

  /// Optimized for reach and resilience over latency. Best for large
  /// audiences and unstable networks.
  scale,
}

/// Plays a live stream from the Mebius gateway.
///
/// Obtain a player from `MebiusClient.createPlayer`. Render its video by
/// passing this instance to a `MebiusView`.
///
/// ```dart
/// final player = client.createPlayer(); // mode defaults to auto
/// player.events.listen((event) {
///   if (event.type == MebiusPlayerEventType.playing) {
///     // Video is rendering.
///   }
/// });
/// await player.play('my-stream', viewTarget);
/// ```
class MebiusPlayer {
  /// Internal: constructed by `MebiusClient.createPlayer`.
  MebiusPlayer.internal({
    required GatewaySignaling signaling,
    required this.mode,
    List<MebiusDelivery> deliveries = const <MebiusDelivery>[],
  }) : _engine = PlaybackEngine(
          signaling: signaling,
          pipeline: mode == MebiusPlayerMode.lowLatency
              ? PlaybackPipeline.lowLatency
              : PlaybackPipeline.scale,
        ) {
    _engine.deliveries = deliveries;
  }

  /// The playback mode this player was created with.
  final MebiusPlayerMode mode;

  final PlaybackEngine _engine;
  final StreamController<MebiusPlayerEvent> _events =
      StreamController<MebiusPlayerEvent>.broadcast();
  Timer? _statsTimer;
  bool _disposed = false;

  /// The stream being played, so a lost route can be reopened without the caller.
  String? _streamId;
  final RecoveryPolicy _recovery = RecoveryPolicy();
  final StallDetector _stall = StallDetector();
  bool _recovering = false;

  /// Bumped by [stop] and [dispose]. A recovery loop can be several seconds deep
  /// in a backoff when the caller gives up, and it must not reopen a route into a
  /// player that has been torn down.
  int _session = 0;

  /// Whether this player is currently playing.
  bool get isPlaying => _engine.isPlaying;

  /// The stream of lifecycle events
  /// (`playing`, `buffering`, `ended`, `stats`).
  Stream<MebiusPlayerEvent> get events => _events.stream;

  /// Internal: the live playback engine, used by `MebiusView`.
  PlaybackEngine get engine => _engine;

  /// Plays the stream identified by [streamId].
  ///
  /// The [viewTarget] is an opaque, platform-agnostic surface handle. In
  /// Flutter you typically render through a `MebiusView` widget instead, in
  /// which case `null` may be passed. The parameter exists to keep the API
  /// surface identical across all Mebius client SDKs.
  ///
  /// Emits a [MebiusPlayerEventType.playing] event on success. Throws a
  /// [MebiusError] on failure.
  Future<void> play(String streamId, [Object? viewTarget]) async {
    _ensureUsable();
    _emit(const MebiusPlayerEvent(MebiusPlayerEventType.buffering));
    _streamId = streamId;
    _recovery.reset();
    _stall.reset();
    try {
      await _engine.start(streamId);
    } catch (e) {
      throw MebiusError.from(e);
    }
    _emit(const MebiusPlayerEvent(MebiusPlayerEventType.playing));
    _startSupervision();
  }

  /// Stops playback and releases resources.
  ///
  /// Emits a [MebiusPlayerEventType.ended] event.
  Future<void> stop() async {
    // Retires a recovery that may be sitting in a backoff right now; it checks
    // this on the way out of every await.
    _session += 1;
    _statsTimer?.cancel();
    _statsTimer = null;
    _streamId = null;
    await _engine.stop();
    _emit(const MebiusPlayerEvent(MebiusPlayerEventType.ended));
  }

  /// Sets the playback volume. [volume] is clamped to the range 0..1.
  Future<void> setVolume(double volume) => _engine.setVolume(volume);

  /// Stops playback (if active) and permanently releases this player.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _session += 1;
    _statsTimer?.cancel();
    _streamId = null;
    await _engine.stop();
    await _events.close();
  }

  static const Duration _tick = Duration(seconds: 2);

  /// Reports statistics and watches the route that is serving.
  ///
  /// One timer for both because they read the same snapshot: the `progress`
  /// entry is what says whether the picture is still moving, and asking for it
  /// separately would cost a second native `getStats` every tick.
  void _startSupervision() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(_tick, (_) async {
      if (_disposed || _recovering || !_engine.isPlaying) {
        return;
      }
      final s = await _engine.readStats();
      if (s.isEmpty) {
        return;
      }
      _emit(
        MebiusPlayerEvent(
          MebiusPlayerEventType.stats,
          stats: MebiusPlaybackStats(
            inboundBitrateKbps: (s['bitrate'] ?? 0).toDouble(),
            frameRate: (s['fps'] ?? 0).toDouble(),
            bufferedMs: (s['buffered'] ?? 0).toInt(),
          ),
        ),
      );
      if (_stall.tick((s['progress'] ?? -1).toInt(), _tick)) {
        await _recover();
      }
    });
  }

  /// Reopens the stream after the route that was serving stopped delivering.
  ///
  /// This is the difference between a broadcast a viewer can leave running and
  /// one that has to be restarted by hand. Route selection happened once, inside
  /// the first [play]: whichever route produced a frame served the rest of the
  /// session, and when it later died — a CDN edge restarting, the publisher
  /// reconnecting, a phone changing network — the picture simply froze. Nothing
  /// was reported, because neither pipeline knows it has stopped receiving.
  ///
  /// The reopen walks the full route list again rather than retrying the dead
  /// one, because the usual causes take out one route and not the others. The
  /// token needs no handling here: the client renews it on its own schedule, and
  /// every route stamps the current token as it builds its URL.
  Future<void> _recover() async {
    final streamId = _streamId;
    if (_recovering || _disposed || streamId == null) {
      return;
    }
    _recovering = true;
    final session = _session;
    _emit(const MebiusPlayerEvent(MebiusPlayerEventType.buffering));
    try {
      while (!_disposed && _session == session && !_recovery.exhausted) {
        await Future<void>.delayed(_recovery.nextDelay());
        if (_disposed || _session != session) {
          return;
        }
        await _engine.stop();
        try {
          await _engine.start(streamId);
        } on Object catch (_) {
          // Every route refused this time round. The next attempt is the
          // answer, not an error the viewer can act on.
          continue;
        }
        if (_disposed || _session != session) {
          // Stopped while the route was opening: do not leave it running.
          await _engine.stop();
          return;
        }
        // Proven healthy again, so the budget is for CONSECUTIVE failures: a
        // long broadcast that loses its route once an hour must not run out of
        // attempts by the afternoon.
        _recovery.reset();
        _stall.reset();
        _emit(const MebiusPlayerEvent(MebiusPlayerEventType.playing));
        return;
      }
      if (!_disposed && _session == session) {
        // Either the broadcast really is over or this device is off the network;
        // both are the end of the session as far as the app is concerned.
        //
        // Clearing the stream closes the session to further recovery: without it
        // a later tick re-enters with the budget already spent and emits a
        // second `ended`, and an app that tears itself down on `ended` gets to
        // do it twice.
        _streamId = null;
        _emit(const MebiusPlayerEvent(MebiusPlayerEventType.ended));
      }
    } finally {
      _recovering = false;
    }
  }

  void _emit(MebiusPlayerEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  void _ensureUsable() {
    if (_disposed) {
      throw const MebiusError(
        MebiusErrorCode.notConnected,
        'This player has been disposed.',
      );
    }
  }
}
