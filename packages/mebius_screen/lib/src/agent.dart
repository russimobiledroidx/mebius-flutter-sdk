import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:mebius/mebius.dart';
import 'package:mebius_screen/src/credentials.dart';
import 'package:mebius_screen/src/injector.dart';
import 'package:mebius_screen/src/input_event.dart';
import 'package:mebius_screen/src/sse.dart';
import 'package:meta/meta.dart';

/// A session the engine opened on this device.
class MebiusScreenSession {
  /// Creates a session description.
  const MebiusScreenSession({
    required this.sessionId,
    required this.mode,
    this.userId = '',
  });

  /// The session id, `scr_…`.
  final String sessionId;

  /// `view` (watch only) or `control` (watch and drive mouse/keyboard).
  final String mode;

  /// The admin id the client backend passed when creating the session; empty
  /// when it passed none. An id, not a name: resolve names from your backend.
  final String userId;

  /// Whether the admin may drive this device's mouse and keyboard.
  bool get isControl => mode == 'control';
}

/// Publishes the screen for one session. The agent's seam for tests.
@internal
abstract interface class ScreenPublisher {
  /// Captures the primary screen and publishes it as [sessionId].
  Future<void> start({
    required String sessionId,
    required String publishToken,
    required int maxBitrateKbps,
    required List<Map<String, dynamic>> iceServers,
  });

  /// Stops publishing and releases the capture.
  Future<void> stop();
}

/// Publishes through the `mebius` broadcaster, with a screen capture as the
/// media source.
class _WebrtcScreenPublisher implements ScreenPublisher {
  _WebrtcScreenPublisher(this._engineUrl);

  final Uri _engineUrl;
  MebiusClient? _client;

  @override
  Future<void> start({
    required String sessionId,
    required String publishToken,
    required int maxBitrateKbps,
    required List<Map<String, dynamic>> iceServers,
  }) async {
    // A per-session client: the publish token is the session's credential,
    // and Mebius.init's app-wide gateway is not this engine's concern.
    final client = MebiusClient.internal(
      gateway: '$_engineUrl',
      token: publishToken,
    );
    _client = client;
    await client
        .createBroadcaster(
          audio: false,
          maxBitrateKbps: maxBitrateKbps,
          source: capturePrimaryScreen,
          iceServers: iceServers,
        )
        .start(sessionId);
  }

  @override
  Future<void> stop() async {
    final client = _client;
    _client = null;
    await client?.disconnect();
  }
}

/// Opens the primary display as a media stream, with no picker. Primary
/// because that is the display the injectors drive, so a click lands where
/// the admin saw it.
Future<MediaStream> capturePrimaryScreen() async {
  final sources = await desktopCapturer.getSources(types: [SourceType.Screen]);
  if (sources.isEmpty) {
    throw StateError('No screen to capture.');
  }
  final source = pickPrimary(sources, (s) => s.id, primaryScreenSourceId());
  return navigator.mediaDevices.getDisplayMedia({
    'audio': false,
    'video': {
      'deviceId': {'exact': source.id},
      // Screens are mostly still text: 15 fps keeps it readable for less.
      'mandatory': {'frameRate': 15.0},
    },
  });
}

/// The employee-side agent: enrolls this device once, keeps it online, and
/// publishes the screen (and accepts remote input) while an admin has a
/// session open.
///
/// ```dart
/// final agent = MebiusScreenAgent(
///   engineUrl: Uri.parse('https://stream.mebius.io'),
///   credentials: MebiusSecureCredentialStore(),
/// );
/// if (!await agent.isEnrolled) {
///   await agent.enroll(code: enrollCode, name: hostName, os: 'macos');
/// }
/// agent.onSession.listen((s) => showNotice(s.mode));
/// agent.onSessionEnded.listen((_) => hideNotice());
/// await agent.connect();
/// ```
class MebiusScreenAgent {
  /// Creates an agent for the engine at [engineUrl].
  MebiusScreenAgent({
    required this.engineUrl,
    required MebiusCredentialStore credentials,
    http.Client? httpClient,
    @visibleForTesting ScreenPublisher? publisher,
    @visibleForTesting InputInjector? injector,
    @visibleForTesting Random? random,
  }) : _credentials = credentials,
       _http = httpClient ?? http.Client(),
       _ownsHttp = httpClient == null,
       _publisher = publisher ?? _WebrtcScreenPublisher(engineUrl),
       _injector = injector,
       _random = random ?? Random();

  /// A connection that delivers nothing, not even the 15 s ping, for this
  /// long is dead (a half-open socket), and is replaced.
  static const Duration silenceLimit = Duration(seconds: 45);

  /// The engine base URL, e.g. `https://stream.mebius.io`.
  final Uri engineUrl;

  final MebiusCredentialStore _credentials;
  final http.Client _http;
  final bool _ownsHttp;
  final ScreenPublisher _publisher;
  InputInjector? _injector;
  final Random _random;

  final _sessions = StreamController<MebiusScreenSession>.broadcast();
  final _ended = StreamController<String>.broadcast();
  final _inputs = StreamController<MebiusInputEvent>.broadcast();
  final _errors = StreamController<MebiusError>.broadcast();

  /// A connection that stays up this long has proven the engine reachable,
  /// so the next drop starts the backoff from 1 s again. One that drops
  /// sooner (an engine accepting and closing at once) keeps backing off.
  static const Duration _stableAfter = Duration(seconds: 10);

  bool _running = false;
  Completer<void> _stop = Completer<void>();
  MebiusScreenSession? _session;

  /// Input failed once in this session; further failures stay quiet so a
  /// missing permission is one error, not one per mouse move.
  bool _inputFailed = false;

  /// Session start/stop, one at a time and in arrival order.
  Future<void> _ops = Future<void>.value();

  /// A session opened on this device: show the employee it is being watched.
  Stream<MebiusScreenSession> get onSession => _sessions.stream;

  /// The id of a session that ended, whoever ended it.
  Stream<String> get onSessionEnded => _ended.stream;

  /// Each remote input as it is applied (control sessions only).
  Stream<MebiusInputEvent> get onInput => _inputs.stream;

  /// Failures the agent cannot act on alone: a publish that failed, or the
  /// device credential being rejected ([MebiusErrorCode.tokenExpired]: the
  /// device was revoked, enroll again). The latter also stops reconnecting.
  Stream<MebiusError> get onError => _errors.stream;

  /// The session in progress, if any.
  MebiusScreenSession? get session => _session;

  /// Whether this device holds credentials.
  Future<bool> get isEnrolled async => await _credentials.read() != null;

  /// Exchanges a one-time enroll code (`enr_…`) for device credentials and
  /// stores them. [os] is free text the admin sees, e.g. `windows`, `macos`.
  ///
  /// Throws [MebiusError] with [MebiusErrorCode.tokenExpired] when the code is
  /// wrong, expired or already used.
  Future<void> enroll({
    required String code,
    required String name,
    required String os,
  }) async {
    final http.Response res;
    try {
      res = await _http.post(
        engineUrl.resolve('/api/v1/screen/agent/enroll'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'enrollToken': code, 'name': name, 'os': os}),
      );
    } on Object catch (e) {
      throw MebiusError(
        MebiusErrorCode.connectionFailed,
        'Could not reach Mebius to enroll.',
        cause: e,
      );
    }
    if (res.statusCode == 401) {
      throw const MebiusError(
        MebiusErrorCode.tokenExpired,
        'The enroll code is wrong, expired or already used.',
      );
    }
    if (res.statusCode != 201 && res.statusCode != 200) {
      throw MebiusError(
        MebiusErrorCode.connectionFailed,
        'Enroll failed (${res.statusCode}): ${res.body}',
      );
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    await _credentials.write(
      MebiusDeviceCredentials(
        deviceId: body['deviceId'] as String,
        deviceSecret: body['deviceSecret'] as String,
      ),
    );
  }

  /// Brings the device online and keeps it there, reconnecting with backoff,
  /// until [disconnect]. Returns once started; it does not wait for the first
  /// connection. Throws [StateError] when the device is not enrolled.
  Future<void> connect() async {
    final creds = await _credentials.read();
    if (creds == null) {
      throw StateError('Enroll this device before connecting.');
    }
    if (_running) {
      return;
    }
    _running = true;
    _stop = Completer<void>();
    unawaited(_loop(creds.deviceSecret));
  }

  /// Takes the device offline and stops any session in progress.
  Future<void> disconnect() async {
    if (!_running) {
      return;
    }
    _running = false;
    _stop.complete();
    await _queue(_endSession);
  }

  /// Disconnects and releases the agent.
  Future<void> dispose() async {
    await disconnect();
    if (_ownsHttp) {
      _http.close();
    }
    await _sessions.close();
    await _ended.close();
    await _inputs.close();
    await _errors.close();
  }

  Future<void> _loop(String secret) async {
    // This loop's own stop signal: a connect() right after disconnect() starts
    // a new loop, and this one must still end.
    final stop = _stop;
    var attempt = 0;
    while (!stop.isCompleted) {
      final abort = Completer<void>();
      try {
        final req =
            http.AbortableRequest(
                'GET',
                engineUrl.resolve('/api/v1/screen/agent/events'),
                abortTrigger: Future.any([abort.future, stop.future]),
              )
              ..headers.addAll({
                'Authorization': 'Bearer $secret',
                'Accept': 'text/event-stream',
              });
        final res = await _http.send(req);
        if (res.statusCode == 401 || res.statusCode == 403) {
          _running = false;
          _emitError(
            const MebiusError(
              MebiusErrorCode.tokenExpired,
              'The device credential was rejected; the device may have been '
              'revoked. Enroll it again.',
            ),
          );
          unawaited(res.stream.listen(null, onError: (_) {}).cancel());
          break;
        }
        if (res.statusCode == 200) {
          final openedAt = clock.now();
          final parser = SseParser();
          try {
            await for (final chunk
                in res.stream.transform(utf8.decoder).timeout(silenceLimit)) {
              parser.add(chunk).forEach(_handle);
            }
          } finally {
            if (clock.now().difference(openedAt) >= _stableAfter) {
              attempt = 0;
            }
          }
        } else {
          unawaited(res.stream.listen(null, onError: (_) {}).cancel());
        }
      } on Object catch (_) {
        // Network loss, abort, silence: all mean reconnect.
      } finally {
        abort.complete();
      }
      // The engine ends the session when this connection drops.
      await _queue(_endSession);
      if (stop.isCompleted || !_running) {
        break;
      }
      await Future.any([
        Future<void>.delayed(reconnectDelay(attempt++, _random)),
        stop.future,
      ]);
    }
    await _queue(_endSession);
  }

  /// One message. Nothing in it may end the event stream: a malformed event
  /// is dropped, the next one still arrives.
  void _handle(String data) {
    try {
      final m = jsonDecode(data);
      if (m is Map<String, dynamic>) {
        _dispatch(m);
      }
    } on Object {
      // Malformed or unexpected: skip this message only.
    }
  }

  void _dispatch(Map<String, dynamic> m) {
    final id = m['sessionId'];
    if (id is! String) {
      return;
    }
    T? field<T>(String k) => m[k] is T ? m[k] as T : null;
    switch (m['type']) {
      case 'session.start':
        final s = MebiusScreenSession(
          sessionId: id,
          mode: field<String>('mode') ?? 'view',
          userId: field<String>('userId') ?? '',
        );
        final ice = (field<List<dynamic>>('iceServers') ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        unawaited(
          _queue(
            () => _startSession(
              s,
              field<String>('publishToken') ?? '',
              field<num>('maxBitrateKbps')?.toInt() ?? 1500,
              ice,
            ),
          ),
        );
      case 'session.stop':
        unawaited(
          _queue(() async {
            if (_session?.sessionId == id) {
              await _endSession();
            }
          }),
        );
      case 'input':
        _applyInput(id, m['input']);
    }
  }

  void _applyInput(String sessionId, Object? input) {
    final s = _session;
    // Gated here as well as on the engine: a stray or late event must never
    // move the mouse outside a control session.
    if (s == null ||
        s.sessionId != sessionId ||
        !s.isControl ||
        input is! List) {
      return;
    }
    for (final raw in input.whereType<Map<String, dynamic>>()) {
      final MebiusInputEvent e;
      try {
        e = MebiusInputEvent.fromJson(raw);
        // Built on first use, inside the try: a missing framework or symbol
        // is an input error, not a dead event stream.
        (_injector ??= platformInjector()).inject(e);
      } on Object catch (err) {
        if (!_inputFailed) {
          _inputFailed = true;
          _emitError(
            MebiusError(
              MebiusErrorCode.permissionDenied,
              err is StateError ? err.message : 'Could not apply remote input.',
              cause: err,
            ),
          );
        }
        return;
      }
      if (!_inputs.isClosed) {
        _inputs.add(e);
      }
    }
  }

  Future<void> _startSession(
    MebiusScreenSession s,
    String token,
    int kbps,
    List<Map<String, dynamic>> iceServers,
  ) async {
    if (_session?.sessionId == s.sessionId) {
      return; // A repeated start for the session already running.
    }
    // One session per device: a new one replaces whatever was running.
    await _endSession();
    if (!_running) {
      return;
    }
    _session = s;
    _inputFailed = false;
    if (!_sessions.isClosed) {
      _sessions.add(s);
    }
    try {
      await _publisher.start(
        sessionId: s.sessionId,
        publishToken: token,
        maxBitrateKbps: kbps,
        iceServers: iceServers,
      );
    } on Object catch (e) {
      _emitError(MebiusError.from(e));
      // Release whatever the attempt opened (the capture above all). The
      // session stays current until the engine ends it (publisher_left).
      try {
        await _publisher.stop();
      } on Object {
        // Nothing more to release.
      }
    }
  }

  Future<void> _endSession() async {
    final s = _session;
    if (s == null) {
      return;
    }
    _session = null;
    // Nothing the admin pressed stays pressed once they are gone.
    _injector?.releaseAll();
    try {
      await _publisher.stop();
    } on Object catch (_) {
      // Stopping is best-effort; the session is over regardless.
    }
    if (!_ended.isClosed) {
      _ended.add(s.sessionId);
    }
  }

  /// Runs [op] after every op queued before it. A failing op (they handle
  /// their own errors; this is the backstop) never blocks the ones after it.
  Future<void> _queue(Future<void> Function() op) {
    return _ops = _ops
        .then((_) => op())
        .then<void>(
          (_) {},
          onError: (Object _) {},
        );
  }

  void _emitError(MebiusError e) {
    if (!_errors.isClosed) {
      _errors.add(e);
    }
  }
}
