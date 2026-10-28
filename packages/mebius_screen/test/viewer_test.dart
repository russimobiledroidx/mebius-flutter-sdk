import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mebius_screen/mebius_screen.dart';
import 'package:mebius_screen/src/viewer.dart';

String _jwt(DateTime exp) {
  String part(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'HS256'})}.'
      '${part({'exp': exp.millisecondsSinceEpoch ~/ 1000})}.sig';
}

MebiusInputEvent _move(double x) => MebiusInputEvent('move', x: x, y: 0);
MebiusInputEvent _key(String k) => MebiusInputEvent('keydown', key: k);

void main() {
  group('InputBatcher', () {
    test('sends once per interval and collapses consecutive moves', () {
      fakeAsync((async) {
        final batches = <List<MebiusInputEvent>>[];
        final b = InputBatcher((e) async => batches.add(e))
          ..add(_move(0.1))
          ..add(_move(0.2))
          ..add(_key('KeyA'))
          ..add(_move(0.3))
          ..add(_move(0.4));
        async.elapse(const Duration(milliseconds: 20));
        expect(batches, isEmpty);
        async.elapse(const Duration(milliseconds: 20));
        expect(batches, hasLength(1));
        expect(batches.single.map((e) => e.toJson()).toList(), [
          {'type': 'move', 'x': 0.2, 'y': 0.0},
          {'type': 'keydown', 'key': 'KeyA'},
          {'type': 'move', 'x': 0.4, 'y': 0.0},
        ]);
        b.add(_key('KeyB'));
        async.elapse(const Duration(milliseconds: 40));
        expect(batches, hasLength(2));
      });
    });

    test('splits into requests of at most 64, in order, one at a time', () {
      fakeAsync((async) {
        final batches = <List<MebiusInputEvent>>[];
        var inFlight = 0;
        var maxInFlight = 0;
        final b = InputBatcher((e) async {
          inFlight++;
          maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          batches.add(e);
          inFlight--;
        });
        for (var i = 0; i < 150; i++) {
          b.add(_key('K$i'));
        }
        async.elapse(const Duration(milliseconds: 100));
        expect(batches.map((e) => e.length), [64, 64, 22]);
        expect(
          batches.expand((e) => e).map((e) => e.key),
          [for (var i = 0; i < 150; i++) 'K$i'],
        );
        expect(maxInFlight, 1);
      });
    });

    test('a failed send does not stop later batches', () {
      fakeAsync((async) {
        var calls = 0;
        final b = InputBatcher((e) async {
          calls++;
          throw StateError('offline');
        })..add(_key('A'));
        async.elapse(const Duration(milliseconds: 40));
        b.add(_key('B'));
        async.elapse(const Duration(milliseconds: 40));
        expect(calls, 2);
      });
    });
  });

  group('InputSender', () {
    final now = DateTime.utc(2026, 10, 28, 9);
    final url = Uri.parse('https://e.example/api/v1/screen/sessions/scr_1/input');

    test('posts the batch with the view token', () async {
      late http.Request sent;
      final s = InputSender(
        client: MockClient((r) async {
          sent = r;
          return http.Response('', 204);
        }),
        url: url,
        token: 'tok',
        refreshToken: () async => fail('no refresh'),
      );
      await s.send([_move(0.5)]);
      expect(sent.headers['Authorization'], 'Bearer tok');
      expect(jsonDecode(sent.body), {
        'events': [
          {'type': 'move', 'x': 0.5, 'y': 0.0},
        ],
      });
    });

    test('renews a token about to expire before sending', () async {
      final old = _jwt(now.add(const Duration(seconds: 30)));
      final fresh = _jwt(now.add(const Duration(minutes: 10)));
      final used = <String?>[];
      final renewed = <String>[];
      final s = InputSender(
        client: MockClient((r) async {
          used.add(r.headers['Authorization']);
          return http.Response('', 204);
        }),
        url: url,
        token: old,
        refreshToken: () async => fresh,
        onToken: renewed.add,
      );
      await withClock(Clock.fixed(now), () => s.send([_move(0)]));
      expect(used, ['Bearer $fresh']);
      expect(renewed, [fresh]);

      // Fresh enough now: no second renewal.
      await withClock(Clock.fixed(now), () => s.send([_move(0)]));
      expect(renewed, hasLength(1));
    });

    test('renews once on a 401 and retries', () async {
      final statuses = [401, 204];
      final used = <String?>[];
      var refreshes = 0;
      final s = InputSender(
        client: MockClient((r) async {
          used.add(r.headers['Authorization']);
          return http.Response('', statuses.removeAt(0));
        }),
        url: url,
        token: 'old',
        refreshToken: () async {
          refreshes++;
          return 'new';
        },
      );
      await s.send([_move(0)]);
      expect(used, ['Bearer old', 'Bearer new']);
      expect(refreshes, 1);
    });

    test('a refusal for good is reported; a server error is not', () async {
      for (final (status, reported) in [
        (403, true),
        (409, true),
        (401, true),
        (500, false),
        (429, false),
      ]) {
        final rejected = <int>[];
        final s = InputSender(
          client: MockClient((_) async => http.Response('', status)),
          url: url,
          token: 't',
          refreshToken: () async => 't2',
          onRejected: rejected.add,
        );
        await s.send([_move(0)]);
        expect(rejected, reported ? [status] : isEmpty, reason: '$status');
      }
    });
  });

  group('retryFor', () {
    test('retries every second until it works', () {
      fakeAsync((async) {
        var tries = 0;
        var done = false;
        unawaited(retryFor(() async {
          if (++tries < 4) {
            throw StateError('not publishing yet');
          }
        }).then((_) => done = true));
        async.elapse(const Duration(seconds: 3));
        expect(tries, 4);
        expect(done, isTrue);
      });
    });

    test('gives up after ~15 s with the last error', () {
      fakeAsync((async) {
        var tries = 0;
        Object? error;
        unawaited(retryFor(() async {
          tries++;
          throw StateError('$tries');
        }).catchError((Object e) => error = e));
        async.elapse(const Duration(seconds: 20));
        expect(tries, 16); // t = 0, 1, … 15 s
        expect('$error', contains('16'));
      });
    });
  });

  test('jwtExpiry reads exp and tolerates junk', () {
    final exp = DateTime.utc(2030);
    expect(jwtExpiry(_jwt(exp)), exp);
    expect(jwtExpiry('not-a-jwt'), isNull);
    expect(jwtExpiry('a.!!!.c'), isNull);
  });

  test('enableControl needs a watched session', () {
    final v = MebiusScreenViewer(engineUrl: Uri.parse('https://e.example'));
    expect(
      () => v.enableControl(refreshToken: () async => ''),
      throwsStateError,
    );
  });
}
