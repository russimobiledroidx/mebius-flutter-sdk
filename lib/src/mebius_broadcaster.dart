import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;

import 'package:mebius/src/internal/broadcast_engine.dart';
import 'package:mebius/src/internal/connection_watch.dart';
import 'package:mebius/src/internal/gateway_signaling.dart';
import 'package:mebius/src/mebius_error.dart';
import 'package:mebius/src/mebius_events.dart';

/// Broadcasts live camera and microphone media to the Mebius gateway.
///
/// Obtain a broadcaster from `MebiusClient.createBroadcaster`. Drive a preview
/// of the outgoing video by passing this instance to a `MebiusView`.
///
/// ```dart
/// final broadcaster = client.createBroadcaster();
/// broadcaster.events.listen((event) {
///   if (event.type == MebiusBroadcasterEventType.started) {
///     // Broadcasting is live.
///   }
/// });
/// await broadcaster.start('my-stream');
/// ```
class MebiusBroadcaster {
  /// Internal: constructed by `MebiusClient.createBroadcaster`.
  MebiusBroadcaster.internal({
    required GatewaySignaling signaling,
    required bool video,
    required bool audio,
    int? maxBitrateKbps = kDefaultMaxBitrateKbps,
    Future<MediaStream> Function()? source,
    List<Map<String, dynamic>> iceServers = const <Map<String, dynamic>>[],
    bool disposeSourceOnStop = true,
  }) : _engine = BroadcastEngine(
          signaling: signaling,
          video: video,
          audio: audio,
          maxBitrateKbps: maxBitrateKbps,
          source: source,
          iceServers: iceServers,
          disposeSourceOnStop: disposeSourceOnStop,
        ) {
    _watch = ConnectionWatch(
      onState: (state) => _emit(
        MebiusBroadcasterEvent(
          MebiusBroadcasterEventType.connectionState,
          connectionState: state,
        ),
      ),
      onFailed: () => _emit(
        const MebiusBroadcasterEvent(
          MebiusBroadcasterEventType.error,
          error: MebiusError(
            MebiusErrorCode.connectionFailed,
            'The broadcast connection failed. The SDK does not reconnect; '
            'start a new broadcast to resume.',
          ),
        ),
      ),
    );
    _engine.onConnectionState = _watch.report;
  }

  final BroadcastEngine _engine;
  late final ConnectionWatch _watch;
  final StreamController<MebiusBroadcasterEvent> _events =
      StreamController<MebiusBroadcasterEvent>.broadcast();
  Timer? _statsTimer;
  bool _disposed = false;

  /// Whether this broadcaster is currently live.
  bool get isBroadcasting => _engine.isRunning;

  /// The stream of lifecycle events (`started`, `stopped`, `stats`,
  /// `connectionState`, `error`).
  Stream<MebiusBroadcasterEvent> get events => _events.stream;

  /// Internal: the live broadcast engine, used by `MebiusView`.
  BroadcastEngine get engine => _engine;

  /// Starts broadcasting under the identifier [streamId].
  ///
  /// Emits a [MebiusBroadcasterEventType.started] event on success. Throws a
  /// [MebiusError] (for example with [MebiusErrorCode.permissionDenied] or
  /// [MebiusErrorCode.connectionFailed]) on failure.
  Future<void> start(String streamId) async {
    _ensureUsable();
    _watch.reset();
    try {
      await _engine.start(streamId);
    } catch (e) {
      throw MebiusError.from(e);
    }
    _emit(const MebiusBroadcasterEvent(MebiusBroadcasterEventType.started));
    _startStatsTimer();
  }

  /// Stops broadcasting and releases capture resources.
  ///
  /// Emits a [MebiusBroadcasterEventType.stopped] event.
  Future<void> stop() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    _watch.dispose();
    await _engine.stop();
    _emit(const MebiusBroadcasterEvent(MebiusBroadcasterEventType.stopped));
  }

  /// Switches between the front- and rear-facing cameras.
  Future<void> switchCamera() => _engine.switchCamera();

  /// Enables or disables the outgoing microphone.
  void setMicEnabled({required bool enabled}) =>
      _engine.setMicEnabled(enabled: enabled);

  /// Enables or disables the outgoing camera.
  void setCameraEnabled({required bool enabled}) =>
      _engine.setCameraEnabled(enabled: enabled);

  /// Stops broadcasting (if active) and permanently releases this broadcaster.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _statsTimer?.cancel();
    _watch.dispose();
    await _engine.stop();
    await _events.close();
  }

  void _startStatsTimer() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_disposed || !_engine.isRunning) {
        return;
      }
      final s = await _engine.readStats();
      if (s.isEmpty) {
        return;
      }
      _emit(
        MebiusBroadcasterEvent(
          MebiusBroadcasterEventType.stats,
          stats: MebiusBroadcastStats(
            outboundBitrateKbps: (s['bitrate'] ?? 0).toDouble(),
            frameRate: (s['fps'] ?? 0).toDouble(),
            packetsSent: (s['packets'] ?? 0).toInt(),
          ),
        ),
      );
    });
  }

  void _emit(MebiusBroadcasterEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  void _ensureUsable() {
    if (_disposed) {
      throw const MebiusError(
        MebiusErrorCode.notConnected,
        'This broadcaster has been disposed.',
      );
    }
  }
}
