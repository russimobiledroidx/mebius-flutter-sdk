import 'dart:async';

import 'package:clock/clock.dart';

import 'package:mebius/src/internal/broadcast_engine.dart';
import 'package:mebius/src/internal/gateway_signaling.dart';
import 'package:mebius/src/internal/token_info.dart';
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
    Future<String> Function()? getToken,
  })  : _deliveries = deliveries,
        _getToken = getToken,
        _signaling = GatewaySignaling(gateway: gateway, token: token) {
    // Connection to the gateway is established lazily on first publish/play,
    // but we surface a `connected` event immediately so applications can wire
    // up their UI deterministically.
    scheduleMicrotask(() {
      _connected = true;
      _emit(const MebiusClientEvent(MebiusClientEventType.connected));
    });
    _scheduleRefresh(readToken(token).expiresAt);
  }

  /// Renew this far ahead of expiry.
  ///
  /// Wide enough that a slow backend, a couple of retries and a timer throttled
  /// by a backgrounded app all still land before the old credential dies. The
  /// old one keeps working the whole time, so being early costs nothing.
  static const Duration _refreshMargin = Duration(minutes: 1);

  /// First retry delay after a failed renewal; doubles up to [_retryMax].
  static const Duration _retryBase = Duration(seconds: 2);
  static const Duration _retryMax = Duration(seconds: 30);

  /// Largest doubling applied to [_retryBase]. See [_onRefreshFailed].
  static const int _maxBackoffShift = 5;

  final GatewaySignaling _signaling;
  final List<MebiusDelivery> _deliveries;
  final Future<String> Function()? _getToken;
  final StreamController<MebiusClientEvent> _events =
      StreamController<MebiusClientEvent>.broadcast();
  final List<MebiusBroadcaster> _broadcasters = [];
  final List<MebiusPlayer> _players = [];
  Timer? _refreshTimer;
  int _refreshFailures = 0;

  /// Bumped whenever the credential is replaced by anyone.
  ///
  /// An automatic renewal awaits an app-supplied provider, and during that await
  /// the app may call [updateToken] itself. Without this counter the provider's
  /// late answer would silently overwrite the token the app just set — and
  /// re-arm a schedule for it. A refresh that comes back holding a stale
  /// generation has been superseded and drops its result.
  int _tokenGeneration = 0;
  bool _connected = false;
  bool _disposed = false;

  /// Whether this client currently considers itself connected.
  bool get isConnected => _connected && !_disposed;

  /// The stream of connection lifecycle events
  /// (`connected`, `disconnected`, `error`).
  Stream<MebiusClientEvent> get events => _events.stream;

  /// Replaces the credential this session authenticates with, in place.
  ///
  /// Publishing and playback are NOT stopped: there is no renegotiation, no
  /// track rebuild and no reconnect. The new token is simply what every
  /// subsequent request to the gateway carries. For a camera publisher that is
  /// the difference between a six-hour broadcast and a broadcast that drops
  /// mid-match to reconnect.
  ///
  /// Throws a [MebiusError] when [token] is empty, or when it is scoped to a
  /// different stream than the current one — swapping in a credential for
  /// another stream would not renew this session, it would break it on the next
  /// request, far from the line that caused it.
  ///
  /// ponytail: a segmented playback session already running keeps the URL it was
  /// started with, because the platform video player is handed a URL once and
  /// offers no hook to re-stamp its segment requests. Publishing and every
  /// request made after this call do use the new token. Lift the ceiling by
  /// restarting playback on the current route if that route is ever the one a
  /// long unattended viewer sits on.
  void updateToken(String token) {
    if (token.isEmpty) {
      throw const MebiusError(
        MebiusErrorCode.tokenExpired,
        'updateToken requires a non-empty token.',
      );
    }
    final next = readToken(token);
    final current = readToken(_signaling.token);
    if (next.streamId != null &&
        current.streamId != null &&
        next.streamId != current.streamId) {
      throw MebiusError(
        MebiusErrorCode.unknown,
        'This token is for stream "${next.streamId}", but the session is on '
        '"${current.streamId}". Mint a token for the stream in use.',
      );
    }
    _signaling.token = token;
    _refreshFailures = 0;
    _tokenGeneration++;
    _scheduleRefresh(next.expiresAt);
  }

  /// Creates a broadcaster bound to this client's connection.
  ///
  /// Set [video] and/or [audio] to choose which media is captured. At least
  /// one must be enabled.
  /// Creates a broadcaster for publishing from this device.
  ///
  /// [maxBitrateKbps] caps what the video encoder may send. It defaults to the
  /// ceiling every Mebius SDK uses, which matches the studio's OBS encoder — so a
  /// broadcast costs the same whichever path it came from. Pass 0 or null to lift
  /// the cap and let WebRTC decide.
  ///
  /// Worth understanding before changing: nothing transcodes downstream, so every
  /// viewer is delivered at exactly the bitrate published here. One broadcaster's
  /// setting is multiplied by the size of its audience — a number that looks
  /// generous for one host is a bandwidth bill for a thousand viewers.
  MebiusBroadcaster createBroadcaster({
    bool video = true,
    bool audio = true,
    int? maxBitrateKbps = kDefaultMaxBitrateKbps,
  }) {
    _ensureConnected();
    if (!video && !audio) {
      throw const MebiusError(
        MebiusErrorCode.unknown,
        'A broadcaster requires at least one of video or audio.',
      );
    }
    final broadcaster = MebiusBroadcaster.internal(
      maxBitrateKbps: maxBitrateKbps,
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
    _refreshTimer?.cancel();
    _refreshTimer = null;
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

  /// Arms the renewal that keeps this session alive past [expiresAt].
  ///
  /// Nothing is armed without a `getToken` provider. That is deliberate and is
  /// the compatibility guarantee: an app written against 0.2.x sees exactly the
  /// behaviour it saw before — the gateway rejects the expired token on the next
  /// request and the SDK reports [MebiusErrorCode.tokenExpired] then, at the same
  /// moment it always did. No new timer, no new error, no new event.
  void _scheduleRefresh(DateTime? expiresAt) {
    final getToken = _getToken;
    // An unreadable expiry is not a reason to DISARM. A token this SDK cannot
    // parse is still a token the gateway may well accept, and silently turning
    // auto-renewal off for the rest of the session — with no event and no error —
    // is the worst of the available answers. Leave whatever is already armed.
    if (getToken == null || expiresAt == null) {
      return;
    }
    _refreshTimer?.cancel();
    _refreshTimer = null;
    final lead = expiresAt.difference(clock.now().toUtc()) - _refreshMargin;
    _refreshTimer = Timer(
      lead.isNegative ? Duration.zero : lead,
      () => unawaited(_refresh(expiresAt)),
    );
  }

  Future<void> _refresh(DateTime previousExpiry) async {
    final getToken = _getToken;
    if (!isConnected || getToken == null) {
      return;
    }
    final generation = _tokenGeneration;
    String next;
    try {
      next = await getToken();
    } on Object catch (e) {
      _onRefreshFailed(previousExpiry, e);
      return;
    }
    // Disconnected, or the credential was replaced by updateToken while the
    // provider was thinking. Either way this answer is stale: applying it would
    // revive a dead session or undo the app's own swap.
    if (!isConnected || generation != _tokenGeneration) {
      return;
    }
    final info = readToken(next);
    final current = readToken(_signaling.token);
    if (info.streamId != null &&
        current.streamId != null &&
        info.streamId != current.streamId) {
      // The same guard updateToken applies by hand. A provider closure holding a
      // stale stream id would otherwise install a credential that breaks the
      // session on its next request, with nothing pointing at the cause.
      _onRefreshFailed(
        previousExpiry,
        StateError(
          'Mebius token refresh returned a token for stream '
          '"${info.streamId}", but the session is on "${current.streamId}".',
        ),
      );
      return;
    }
    if (next.isEmpty ||
        (info.expiresAt != null && !info.expiresAt!.isAfter(previousExpiry))) {
      // A token that does not outlive the one it replaces cannot keep the
      // session alive, so it is a failed mint — handled as one. Retrying inside
      // the remaining window matters: a provider can be briefly serving a cached
      // response and hand back a genuinely newer token moments later, and
      // reporting expiry here would end the broadcast a full margin early.
      _onRefreshFailed(
        previousExpiry,
        StateError('Mebius token refresh returned a token that is not newer.'),
      );
      return;
    }
    _refreshFailures = 0;
    _signaling.token = next;
    _tokenGeneration++;
    _emit(const MebiusClientEvent(MebiusClientEventType.tokenRefreshed));
    _scheduleRefresh(info.expiresAt);
  }

  /// A failed renewal is not a dead session: the current token is valid until
  /// [expiry] and the broadcast is still live. Retry inside that window, and
  /// only report expiry once the window has actually run out.
  void _onRefreshFailed(DateTime expiry, Object cause) {
    // disconnect() may have run while the provider was awaited. Re-arming here
    // would leave a live Timer — and the whole client graph it captures — owned
    // by nobody, because disconnect() has already cancelled what it knew about.
    if (!isConnected) {
      return;
    }
    final remaining = expiry.difference(clock.now().toUtc());
    if (remaining <= Duration.zero) {
      _emit(
        MebiusClientEvent(
          MebiusClientEventType.error,
          error: MebiusError(
            MebiusErrorCode.tokenExpired,
            'The connection token expired and could not be renewed.',
            cause: cause,
          ),
        ),
      );
      return;
    }
    _refreshFailures += 1;
    // Clamp the shift, not just the result. `1 << 63` overflows a Dart int to a
    // negative number, so an unclamped exponent turns a long outage into a
    // NEGATIVE delay — a timer that fires immediately, forever. The cap is 5
    // because 2s << 5 already exceeds _retryMax; anything beyond it is dead
    // arithmetic with a live failure mode.
    final backoff = _retryBase * (1 << (_refreshFailures - 1).clamp(0, _maxBackoffShift));
    final delay = <Duration>[backoff, _retryMax, remaining]
        .reduce((a, b) => a < b ? a : b);
    _refreshTimer?.cancel();
    _refreshTimer = Timer(delay, () => unawaited(_refresh(expiry)));
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
