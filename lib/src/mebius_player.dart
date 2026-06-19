import 'dart:async';

import 'package:mebius/src/internal/gateway_signaling.dart';
import 'package:mebius/src/internal/playback_engine.dart';
import 'package:mebius/src/mebius_error.dart';
import 'package:mebius/src/mebius_events.dart';

/// Selects the playback strategy used by a [MebiusPlayer].
enum MebiusPlayerMode {
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
/// final player = client.createPlayer(mode: MebiusPlayerMode.lowLatency);
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
  }) : _engine = PlaybackEngine(
          signaling: signaling,
          pipeline: mode == MebiusPlayerMode.lowLatency
              ? PlaybackPipeline.lowLatency
              : PlaybackPipeline.scale,
        );

  /// The playback mode this player was created with.
  final MebiusPlayerMode mode;

  final PlaybackEngine _engine;
  final StreamController<MebiusPlayerEvent> _events =
      StreamController<MebiusPlayerEvent>.broadcast();
  Timer? _statsTimer;
  bool _disposed = false;

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
    try {
      await _engine.start(streamId);
    } catch (e) {
      throw MebiusError.from(e);
    }
    _emit(const MebiusPlayerEvent(MebiusPlayerEventType.playing));
    _startStatsTimer();
  }

  /// Stops playback and releases resources.
  ///
  /// Emits a [MebiusPlayerEventType.ended] event.
  Future<void> stop() async {
    _statsTimer?.cancel();
    _statsTimer = null;
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
    _statsTimer?.cancel();
    await _engine.stop();
    await _events.close();
  }

  void _startStatsTimer() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_disposed || !_engine.isPlaying) {
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
    });
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
