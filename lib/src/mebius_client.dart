import 'dart:async';

import 'package:mebius/src/internal/gateway_signaling.dart';
import 'package:mebius/src/mebius_broadcaster.dart';
import 'package:mebius/src/mebius_delivery.dart';
import 'package:mebius/src/mebius_error.dart';
import 'package:mebius/src/mebius_events.dart';
import 'package:mebius/src/mebius_player.dart';

/// An authenticated session with the Mebius gateway.
///
/// Create a client with `Mebius.connect` after calling `Mebius.init`. A client
/// is the factory for [MebiusBroadcaster] and [MebiusPlayer] instances and is
/// the source of connection lifecycle events.
///
/// ```dart
/// final client = Mebius.connect(token: backendToken);
/// client.events.listen((event) {
///   if (event.type == MebiusClientEventType.error &&
///       event.error?.code == MebiusErrorCode.tokenExpired) {
///     // Refresh the token from your backend and reconnect.
///   }
/// });
/// ```
class MebiusClient {
  /// Internal: constructed by `Mebius.connect`.
  MebiusClient.internal({
    required String gateway,
    required String token,
    List<MebiusDelivery> deliveries = const <MebiusDelivery>[],
  })  : _deliveries = deliveries,
        _signaling = GatewaySignaling(gateway: gateway, token: token) {
    // Connection to the gateway is established lazily on first publish/play,
    // but we surface a `connected` event immediately so applications can wire
    // up their UI deterministically.
    scheduleMicrotask(() {
      _connected = true;
      _emit(const MebiusClientEvent(MebiusClientEventType.connected));
    });
  }

  final GatewaySignaling _signaling;
  final List<MebiusDelivery> _deliveries;
  final StreamController<MebiusClientEvent> _events =
      StreamController<MebiusClientEvent>.broadcast();
  final List<MebiusBroadcaster> _broadcasters = [];
  final List<MebiusPlayer> _players = [];
  bool _connected = false;
  bool _disposed = false;

  /// Whether this client currently considers itself connected.
  bool get isConnected => _connected && !_disposed;

  /// The stream of connection lifecycle events
  /// (`connected`, `disconnected`, `error`).
  Stream<MebiusClientEvent> get events => _events.stream;

  /// Creates a broadcaster bound to this client's connection.
  ///
  /// Set [video] and/or [audio] to choose which media is captured. At least
  /// one must be enabled.
  MebiusBroadcaster createBroadcaster({
    bool video = true,
    bool audio = true,
  }) {
    _ensureConnected();
    if (!video && !audio) {
      throw const MebiusError(
        MebiusErrorCode.unknown,
        'A broadcaster requires at least one of video or audio.',
      );
    }
    final broadcaster = MebiusBroadcaster.internal(
      signaling: _signaling,
      video: video,
      audio: audio,
    );
    _broadcasters.add(broadcaster);
    return broadcaster;
  }

  /// Creates a player bound to this client's connection.
  ///
  /// The [mode] selects the playback strategy; the underlying delivery route is
  /// chosen automatically and re-chosen if it stops delivering frames.
  ///
  /// The default changed from `lowLatency` to [MebiusPlayerMode.auto]: a plain
  /// viewer does not need a real-time connection, and defaulting to one spent a
  /// per-viewer server session on every audience member.
  MebiusPlayer createPlayer({
    MebiusPlayerMode mode = MebiusPlayerMode.auto,
  }) {
    _ensureConnected();
    final player = MebiusPlayer.internal(
      signaling: _signaling,
      mode: mode,
      deliveries: _deliveries,
    );
    _players.add(player);
    return player;
  }

  /// Creates a player for a stream you are interacting WITH — the other side of
  /// a co-broadcast — where a second of delay makes the interaction feel broken.
  ///
  /// Same API as a player; only the delay budget differs. It starts on the
  /// real-time route and falls back by itself if that route sends no frames,
  /// which is the part apps used to hand-roll and get wrong in front of a live
  /// audience.
  MebiusPlayer createMonitor() =>
      createPlayer(mode: MebiusPlayerMode.lowLatency);

  /// Disconnects from the gateway and releases all broadcasters and players
  /// created by this client.
  ///
  /// Emits a [MebiusClientEventType.disconnected] event.
  Future<void> disconnect() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _connected = false;
    for (final b in List.of(_broadcasters)) {
      await b.dispose();
    }
    for (final p in List.of(_players)) {
      await p.dispose();
    }
    _broadcasters.clear();
    _players.clear();
    _emit(const MebiusClientEvent(MebiusClientEventType.disconnected));
    _signaling.dispose();
    await _events.close();
  }

  void _emit(MebiusClientEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  void _ensureConnected() {
    if (!isConnected) {
      throw const MebiusError(
        MebiusErrorCode.notConnected,
        'The Mebius client is not connected.',
      );
    }
  }
}
