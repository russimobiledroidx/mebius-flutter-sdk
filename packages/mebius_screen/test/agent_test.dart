import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mebius_screen/mebius_screen.dart';
import 'package:mebius_screen/src/agent.dart';
import 'package:mebius_screen/src/injector.dart';

class _Store implements MebiusCredentialStore {
  MebiusDeviceCredentials? value;
  @override
  Future<MebiusDeviceCredentials?> read() async => value;
  @override
  Future<void> write(MebiusDeviceCredentials c) async => value = c;
  @override
  Future<void> clear() async => value = null;
}

class _Publisher implements ScreenPublisher {
  final List<String> log = [];
  Error? failStart;
  Map<String, Object?>? lastStart;
  @override
  Future<void> start({
    required String sessionId,
    required String publishToken,
    required int maxBitrateKbps,
    required List<Map<String, dynamic>> iceServers,
  }) async {
    log.add('start $sessionId');
    if (failStart != null) {
      throw failStart!;
    }
    lastStart = {
      'token': publishToken,
      'kbps': maxBitrateKbps,
      'ice': iceServers,
    };
  }

  @override
  Future<void> stop() async => log.add('stop');
}

class _Injector implements InputInjector {
  final List<MebiusInputEvent> events = [];
  int releases = 0;
  Error? fail;
  @override
  void inject(MebiusInputEvent event) {
    if (fail != null) {
      throw fail!;
    }
    events.add(event);
  }

  @override
  void releaseAll() => releases++;
}

class _ClosableClient extends MockClient {
  _ClosableClient(super.fn) : super.streaming();
  bool closed = false;
  @override
  void close() => closed = true;
}

/// An engine whose event stream the test writes to.
class _Engine {
  final List<StreamController<List<int>>> streams = [];
  final List<http.BaseRequest> requests = [];
  int status = 200;

  late final _ClosableClient client = _ClosableClient((req, _) async {
    requests.add(req);
    final c = StreamController<List<int>>();
    streams.add(c);
    return http.StreamedResponse(c.stream, status);
  });

  void send(Map<String, Object?> event) =>
      streams.last.add(utf8.encode('data: ${jsonEncode(event)}\n\n'));
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  late _Store store;
  late _Engine engine;
  late _Publisher publisher;
  late _Injector injector;
  late MebiusScreenAgent agent;

  setUp(() {
    store = _Store()
      ..value = const MebiusDeviceCredentials(
        deviceId: 'dev_1',
        deviceSecret: 'dsk_secret',
      );
    engine = _Engine();
    publisher = _Publisher();
    injector = _Injector();
    agent = MebiusScreenAgent(
      engineUrl: Uri.parse('https://engine.example'),
      credentials: store,
      httpClient: engine.client,
      publisher: publisher,
      injector: injector,
      random: Random(0),
    );
  });

  tearDown(() => agent.disconnect());

  Map<String, Object?> start(String id, {String mode = 'control'}) => {
    'type': 'session.start',
    'sessionId': id,
    'mode': mode,
    'userId': 'admin-42',
    'publishToken': 'pub_$id',
    'maxBitrateKbps': 900,
    'iceServers': [
      {
        'urls': ['turn:t.example:3478'],
        'username': 'u',
        'credential': 'c',
      },
    ],
  };

  Map<String, Object?> input(String id) => {
    'type': 'input',
    'sessionId': id,
    'input': [
      {'type': 'move', 'x': 0.5, 'y': 0.25},
    ],
  };

  group('enroll', () {
    test('stores the credentials the engine returns', () async {
      late http.Request sent;
      final a = MebiusScreenAgent(
        engineUrl: Uri.parse('https://engine.example'),
        credentials: store..value = null,
        httpClient: MockClient((req) async {
          sent = req;
          return http.Response(
            '{"deviceId":"dev_9","deviceSecret":"dsk_9"}',
            201,
          );
        }),
      );
      expect(await a.isEnrolled, isFalse);
      await a.enroll(code: 'enr_1', name: 'LAPTOP', os: 'macos');
      expect(sent.url.path, '/api/v1/screen/agent/enroll');
      expect(jsonDecode(sent.body), {
        'enrollToken': 'enr_1',
        'name': 'LAPTOP',
        'os': 'macos',
      });
      expect(store.value?.deviceSecret, 'dsk_9');
      expect(await a.isEnrolled, isTrue);
    });

    test('a rejected code is tokenExpired and stores nothing', () async {
      final a = MebiusScreenAgent(
        engineUrl: Uri.parse('https://engine.example'),
        credentials: store..value = null,
        httpClient: MockClient((_) async => http.Response('{}', 401)),
      );
      await expectLater(
        a.enroll(code: 'enr_x', name: 'n', os: 'windows'),
        throwsA(
          isA<MebiusError>().having(
            (e) => e.code,
            'code',
            MebiusErrorCode.tokenExpired,
          ),
        ),
      );
      expect(store.value, isNull);
    });
  });

  test('connect needs an enrolled device', () async {
    store.value = null;
    expect(agent.connect, throwsStateError);
  });

  test('opens the event stream with the device secret', () async {
    await agent.connect();
    await _settle();
    final req = engine.requests.single;
    expect(
      req.url.toString(),
      'https://engine.example/api/v1/screen/agent/events',
    );
    expect(req.headers['Authorization'], 'Bearer dsk_secret');
  });

  test('session.start publishes and announces; session.stop stops', () async {
    final sessions = <MebiusScreenSession>[];
    final ended = <String>[];
    agent.onSession.listen(sessions.add);
    agent.onSessionEnded.listen(ended.add);
    await agent.connect();
    await _settle();

    engine.send(start('scr_1', mode: 'view'));
    await _settle();
    expect(publisher.log, ['start scr_1']);
    expect(publisher.lastStart, {
      'token': 'pub_scr_1',
      'kbps': 900,
      'ice': [
        {
          'urls': ['turn:t.example:3478'],
          'username': 'u',
          'credential': 'c',
        },
      ],
    });
    expect(sessions.single.sessionId, 'scr_1');
    expect(sessions.single.mode, 'view');
    expect(sessions.single.userId, 'admin-42');

    engine.send({'type': 'session.stop', 'sessionId': 'scr_other'});
    await _settle();
    expect(publisher.log, [
      'start scr_1',
    ], reason: 'another session is ignored');

    engine.send({'type': 'session.stop', 'sessionId': 'scr_1'});
    await _settle();
    expect(publisher.log, ['start scr_1', 'stop']);
    expect(ended, ['scr_1']);
    expect(agent.session, isNull);
  });

  test('a new session replaces the running one; a repeat is ignored', () async {
    final ended = <String>[];
    agent.onSessionEnded.listen(ended.add);
    await agent.connect();
    await _settle();
    engine
      ..send(start('scr_1'))
      ..send(start('scr_1'))
      ..send(start('scr_2'));
    await _settle();
    expect(publisher.log, ['start scr_1', 'stop', 'start scr_2']);
    expect(ended, ['scr_1']);
    expect(agent.session?.sessionId, 'scr_2');
  });

  test('input is applied only during a control session', () async {
    final applied = <MebiusInputEvent>[];
    agent.onInput.listen(applied.add);
    await agent.connect();
    await _settle();

    engine.send(input('scr_1'));
    await _settle();
    expect(injector.events, isEmpty, reason: 'no session');

    engine.send(start('scr_1', mode: 'view'));
    await _settle();
    engine.send(input('scr_1'));
    await _settle();
    expect(injector.events, isEmpty, reason: 'view-only');

    engine.send(start('scr_2'));
    await _settle();
    engine
      ..send(input('scr_1'))
      ..send(input('scr_2'));
    await _settle();
    expect(injector.events, hasLength(1), reason: 'only the current session');
    expect(injector.events.single.toJson(), {
      'type': 'move',
      'x': 0.5,
      'y': 0.25,
    });
    expect(applied, hasLength(1));

    engine.send({'type': 'session.stop', 'sessionId': 'scr_2'});
    await _settle();
    engine.send(input('scr_2'));
    await _settle();
    expect(injector.events, hasLength(1), reason: 'after stop');
  });

  test('a dropped stream ends the session and reconnects', () async {
    final ended = <String>[];
    agent.onSessionEnded.listen(ended.add);
    await agent.connect();
    await _settle();
    engine.send(start('scr_1'));
    await _settle();

    await engine.streams.last.close();
    await _settle();
    expect(ended, ['scr_1']);
    expect(publisher.log.last, 'stop');

    // First retry is 0.8–1 s away.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(engine.requests, hasLength(2));
  });

  test('disconnect stops the session and does not reconnect', () async {
    await agent.connect();
    await _settle();
    engine.send(start('scr_1'));
    await _settle();
    await agent.disconnect();
    expect(publisher.log, ['start scr_1', 'stop']);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(engine.requests, hasLength(1));
  });

  test('a rejected device secret reports and stops reconnecting', () async {
    engine.status = 401;
    final errors = <MebiusError>[];
    agent.onError.listen(errors.add);
    await agent.connect();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(engine.requests, hasLength(1));
    expect(errors.single.code, MebiusErrorCode.tokenExpired);
  });

  test(
    'a bad message or a failing injector does not drop the stream',
    () async {
      final errors = <MebiusError>[];
      agent.onError.listen(errors.add);
      await agent.connect();
      await _settle();
      engine.send(start('scr_1'));
      engine.streams.last
        ..add(utf8.encode('data: {not json\n\n'))
        ..add(utf8.encode('data: [1,2]\n\n'));
      engine.send({
        'type': 'session.start',
        'sessionId': 'scr_2',
        'mode': 'control',
        'userId': 7,
      });
      await _settle();
      injector.fail = StateError('Accessibility permission missing');
      engine
        ..send(input('scr_2'))
        ..send(input('scr_2'));
      await _settle();
      expect(errors, hasLength(1), reason: 'one input error per session');
      expect(errors.single.code, MebiusErrorCode.permissionDenied);
      expect(errors.single.message, contains('Accessibility'));
      injector.fail = null;
      engine.send(input('scr_2'));
      await _settle();
      expect(injector.events, hasLength(1), reason: 'stream still alive');
      expect(engine.requests, hasLength(1), reason: 'no reconnect');
      expect(agent.session?.userId, '', reason: 'a mistyped field falls back');
    },
  );

  test('held input is released whenever a session ends', () async {
    await agent.connect();
    await _settle();
    engine
      ..send(start('scr_1'))
      ..send(start('scr_2')); // switch
    await _settle();
    expect(injector.releases, 1);
    engine.send({'type': 'session.stop', 'sessionId': 'scr_2'}); // stop
    await _settle();
    expect(injector.releases, 2);
    engine.send(start('scr_3'));
    await _settle();
    await engine.streams.last.close(); // stream dropped
    await _settle();
    expect(injector.releases, 3);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    engine.send(start('scr_4'));
    await _settle();
    await agent.disconnect(); // disconnect
    expect(injector.releases, 4);
  });

  test('a failed publish is reported and its capture released', () async {
    publisher.failStart = StateError('no screen');
    final errors = <MebiusError>[];
    agent.onError.listen(errors.add);
    await agent.connect();
    await _settle();
    engine.send(start('scr_1'));
    await _settle();
    expect(publisher.log, ['start scr_1', 'stop']);
    expect(errors.single.message, contains('no screen'));
  });

  test('a client the caller passed in is not closed', () async {
    await agent.dispose();
    expect(engine.client.closed, isFalse);
  });
}
