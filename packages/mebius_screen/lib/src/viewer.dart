import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;
import 'package:http/http.dart' as http;
import 'package:mebius/mebius.dart';
import 'package:mebius_screen/src/input_event.dart';

/// Runs [attempt] until it succeeds, every [interval], for up to [limit];
/// then rethrows the last failure. For the first seconds of a session, when
/// the agent has not started publishing and opening the video fails.
@internal
Future<void> retryFor(
  Future<void> Function() attempt, {
  Duration interval = const Duration(seconds: 1),
  Duration limit = const Duration(seconds: 15),
  bool Function()? cancelled,
}) async {
  final deadline = clock.now().add(limit);
  while (true) {
    try {
      return await attempt();
    } on Object {
      if (clock.now().add(interval).isAfter(deadline) ||
          (cancelled?.call() ?? false)) {
        rethrow;
      }
    }
    await Future<void>.delayed(interval);
  }
}

/// The `exp` of a JWT, read without verifying it; null when unreadable.
@internal
DateTime? jwtExpiry(String token) {
  final parts = token.split('.');
  if (parts.length < 2) {
    return null;
  }
  try {
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    final exp = payload is Map<String, dynamic> ? payload['exp'] : null;
    return exp is num
        ? DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000, isUtc: true)
        : null;
  } on Object {
    return null;
  }
}

/// Collects input and sends it at most once per [interval], up to
/// [maxPerRequest] events per request, one request at a time and in order.
/// Consecutive moves collapse into the latest: only where the pointer ended
/// up matters, and it keeps a fast mouse inside the per-request limit.
@internal
class InputBatcher {
  /// Creates a batcher that hands each batch to `send`.
  InputBatcher(
    this._send, {
    this.interval = const Duration(milliseconds: 33),
  });

  /// The engine's per-request limit.
  static const int maxPerRequest = 64;

  /// How long input gathers before it is sent.
  final Duration interval;

  final Future<void> Function(List<MebiusInputEvent>) _send;
  final List<MebiusInputEvent> _pending = [];
  Timer? _timer;
  bool _sending = false;

  /// Queues [event] for the next batch.
  void add(MebiusInputEvent event) {
    if (event.type == 'move' &&
        _pending.isNotEmpty &&
        _pending.last.type == 'move') {
      _pending.last = event;
    } else {
      _pending.add(event);
    }
    _timer ??= Timer(interval, () => unawaited(_flush()));
  }

  /// Sends everything queued now rather than at the next tick.
  Future<void> flush() {
    _timer?.cancel();
    return _flush();
  }

  Future<void> _flush() async {
    _timer = null;
    if (_sending) {
      return; // The loop below picks these up.
    }
    _sending = true;
    try {
      while (_pending.isNotEmpty) {
        final n = min(maxPerRequest, _pending.length);
        final batch = _pending.sublist(0, n);
        _pending.removeRange(0, n);
        try {
          await _send(batch);
        } on Object {
          // Lost input is not retried: replayed late, a click lands
          // somewhere the admin no longer means.
        }
      }
    } finally {
      _sending = false;
    }
  }
}

/// Posts input batches with the view token, renewing it shortly before it
/// expires and once on a 401.
@internal
class InputSender {
  /// Creates a sender posting to [url].
  InputSender({
    required http.Client client,
    required this.url,
    required this.token,
    required Future<String> Function() refreshToken,
    this.onToken,
    this.onRejected,
  }) : _http = client,
       _refreshToken = refreshToken;

  /// Renew this long before `exp`.
  static const Duration refreshMargin = Duration(minutes: 1);

  /// The input endpoint for the session.
  final Uri url;

  /// The view token currently in use.
  String token;

  /// Called with each renewed token.
  final void Function(String token)? onToken;

  /// Called with the status of a batch the engine refused for good.
  final void Function(int status)? onRejected;

  final http.Client _http;
  final Future<String> Function() _refreshToken;

  /// Sends one batch.
  Future<void> send(List<MebiusInputEvent> events) async {
    final exp = jwtExpiry(token);
    if (exp != null &&
        !clock.now().toUtc().isBefore(exp.subtract(refreshMargin))) {
      await _refresh();
    }
    var res = await _post(events);
    if (res.statusCode == 401 && await _refresh()) {
      res = await _post(events);
    }
    // For good: bad token, view-only, no such session, session over. A 5xx
    // or 429 costs this batch only.
    if (const {401, 403, 404, 409}.contains(res.statusCode)) {
      onRejected?.call(res.statusCode);
    }
  }

  Future<bool> _refresh() async {
    try {
      final next = await _refreshToken();
      if (next.isEmpty) {
        return false;
      }
      token = next;
      onToken?.call(next);
      return true;
    } on Object {
      return false; // Keep the old token; the engine says if it is dead.
    }
  }

  Future<http.Response> _post(List<MebiusInputEvent> events) => _http.post(
    url,
    headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({
      'events': [for (final e in events) e.toJson()],
    }),
  );
}

/// The admin side: watches a device's screen and, in a control session,
/// drives its mouse and keyboard. Render it with `MebiusScreenView`.
///
/// ```dart
/// final viewer = MebiusScreenViewer(engineUrl: Uri.parse('https://stream.mebius.io'));
/// await viewer.watch(sessionId: sessionId, token: token);
/// viewer.enableControl(refreshToken: () => myApi.newSessionToken(sessionId));
/// viewer.onEnded.listen((reason) => close());
/// ```
class MebiusScreenViewer {
  /// Creates a viewer for the engine at [engineUrl].
  MebiusScreenViewer({required this.engineUrl, http.Client? httpClient})
    : _http = httpClient ?? http.Client(),
      _ownsHttp = httpClient == null;

  /// The engine base URL, e.g. `https://stream.mebius.io`.
  final Uri engineUrl;

  final http.Client _http;
  final bool _ownsHttp;
  final HeldInput _held = HeldInput();
  final _ended = StreamController<String>.broadcast();
  final ValueNotifier<MediaStream?> _stream = ValueNotifier(null);

  MebiusClient? _client;
  MebiusPlayer? _player;
  StreamSubscription<MebiusPlayerEvent>? _playerEvents;
  String? _sessionId;
  String? _token;
  InputBatcher? _batcher;
  bool _closed = false;

  /// Fires once when the video ends for good (the session ended or the agent
  /// stopped publishing). The reason is `ended`; the engine's own `endReason`
  /// is in the session history your backend reads.
  Stream<String> get onEnded => _ended.stream;

  /// Whether input is being sent.
  bool get controlEnabled => _batcher != null;

  /// The incoming screen, for `MebiusScreenView`.
  @internal
  ValueListenable<MediaStream?> get stream => _stream;

  /// Opens the video of [sessionId] with its view [token], retrying for up
  /// to ~15 s while the agent starts publishing. [iceServers] are the
  /// RTCIceServer maps the session response carried, if any.
  ///
  /// Throws [MebiusError] if the video never opens.
  Future<void> watch({
    required String sessionId,
    required String token,
    List<Map<String, dynamic>> iceServers = const [],
  }) async {
    if (_closed || _player != null) {
      throw StateError('A viewer watches one session; create another.');
    }
    final client = MebiusClient.internal(gateway: '$engineUrl', token: token);
    final player = client.createPlayer(
      mode: MebiusPlayerMode.lowLatency,
      iceServers: iceServers,
    );
    _client = client;
    _player = player;
    _playerEvents = player.events.listen((e) {
      switch (e.type) {
        case MebiusPlayerEventType.playing:
          // A recovered route is a new stream.
          _stream.value = player.engine.remoteStream;
        case MebiusPlayerEventType.ended:
          _stream.value = null;
          disableControl();
          if (!_ended.isClosed) {
            _ended.add('ended');
          }
        case MebiusPlayerEventType.buffering || MebiusPlayerEventType.stats:
          break;
      }
    });
    try {
      await retryFor(() => player.play(sessionId), cancelled: () => _closed);
    } on Object {
      // Leave the viewer as it was, so watch() can be called again.
      await _playerEvents?.cancel();
      _playerEvents = null;
      _player = null;
      _client = null;
      await client.disconnect();
      rethrow;
    }
    _sessionId = sessionId;
    _token = token;
    _stream.value = player.engine.remoteStream;
  }

  /// Starts sending pointer and keyboard input from `MebiusScreenView` (or
  /// [sendInput]). [refreshToken] returns a fresh view token for this
  /// session from your backend; it is called shortly before the current one
  /// expires, and once if the engine answers 401.
  ///
  /// Turned off again by itself when the engine refuses input for good: the
  /// session is view-only (403), over or offline (409), or the token could
  /// not be renewed.
  void enableControl({required Future<String> Function() refreshToken}) {
    final sessionId = _sessionId;
    final token = _token;
    if (sessionId == null || token == null) {
      throw StateError('Call watch() before enableControl().');
    }
    unawaited(_stopControl());
    late final InputBatcher batcher;
    final sender = InputSender(
      client: _http,
      url: engineUrl.resolve(
        '/api/v1/screen/sessions/${Uri.encodeComponent(sessionId)}/input',
      ),
      token: token,
      refreshToken: refreshToken,
      onToken: (t) {
        _token = t;
        // So a video reconnect opens with a live token too.
        try {
          _client?.updateToken(t);
        } on Object {
          // The video keeps the token it has.
        }
      },
      // A late answer for an earlier enableControl must not turn this one off.
      onRejected: (_) {
        if (identical(_batcher, batcher)) {
          disableControl();
        }
      },
    );
    _batcher = batcher = InputBatcher(sender.send);
  }

  /// Stops sending input, after releasing every key and button the admin
  /// still holds on the device.
  void disableControl() => unawaited(_stopControl());

  /// Queues one input event; ignored unless control is enabled.
  void sendInput(MebiusInputEvent event) {
    final b = _batcher;
    if (b != null) {
      _held.track(event);
      b.add(event);
    }
  }

  /// Sends the ups for everything held, e.g. when the view loses focus and
  /// would never see the key-up.
  @internal
  void releaseHeld() => _held.release().forEach(sendInput);

  Future<void> _stopControl() async {
    final b = _batcher;
    if (b == null) {
      return;
    }
    _held.release().forEach(b.add);
    _batcher = null;
    await b.flush();
  }

  /// Stops watching and releases the viewer. The session itself ends on the
  /// engine once no viewer is left for 60 s, or when your backend ends it.
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _stopControl();
    await _playerEvents?.cancel();
    _stream.value = null;
    await _client?.disconnect();
    if (_ownsHttp) {
      _http.close();
    }
    await _ended.close();
    _stream.dispose();
  }
}
