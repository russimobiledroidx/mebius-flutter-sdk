import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mebius/mebius.dart';
import 'package:mebius/src/internal/token_info.dart';

/// CR-1: a session that outlives the credential it opened with.
///
/// What is worth proving here, in order:
///   * without `getToken`, 0.2.x behaviour is untouched — no timer, no renewal,
///     no new event;
///   * with it, the credential is swapped BEFORE expiry and nothing restarts;
///   * a provider that fails a few times does not end the broadcast;
///   * a token for another stream is refused, and refusing does not damage the
///     session.
void main() {
  setUp(() {
    Mebius.resetForTesting();
    Mebius.init(appId: 'app', gateway: 'https://gw.example');
  });
  tearDown(Mebius.resetForTesting);

  group('readToken', () {
    test('reads exp and streamId, and shrugs off anything else', () {
      final info = readToken(jwt(streamId: 's_match'));
      expect(info.streamId, 's_match');
      expect(info.expiresAt, isNotNull);

      for (final junk in ['', 'not-a-jwt', 'a.b', 'a.!!!.c']) {
        expect(readToken(junk).expiresAt, isNull, reason: junk);
        expect(readToken(junk).streamId, isNull, reason: junk);
      }
    });
  });

  group('without getToken (0.2.x behaviour)', () {
    test('schedules nothing and leaves the token alone past expiry', () {
      FakeAsync().run((async) {
        final events = <MebiusClientEventType>[];
        final client = Mebius.connect(token: jwt());
        client.events.listen((e) => events.add(e.type));
        async.flushMicrotasks();

        final before = tokenOf(client);
        // Well past expiry. Nothing must have fired: the gateway rejecting the
        // token on the next request is still the only signal, exactly as in
        // 0.2.2.
        async.elapse(const Duration(hours: 3));

        expect(tokenOf(client), before);
        expect(events, [MebiusClientEventType.connected]);
      });
    });
  });

  group('with getToken', () {
    test('renews before expiry, swaps in place, and says so once', () {
      FakeAsync().run((async) {
        var mints = 0;
        final events = <MebiusClientEventType>[];
        final client = Mebius.connect(
          token: jwt(streamId: 's_match'),
          getToken: () async {
            mints += 1;
            return jwt(streamId: 's_match', expiresIn: oneHour * (mints + 1));
          },
        );
        client.events.listen((e) => events.add(e.type));
        async.flushMicrotasks();
        final first = tokenOf(client);

        // Renewal is due a minute before expiry, so at 58 minutes nothing has
        // happened yet and at 60 it has — the point being that the swap lands
        // while the old credential is still good.
        async.elapse(const Duration(minutes: 58));
        expect(mints, 0);
        expect(tokenOf(client), first);

        async.elapse(const Duration(minutes: 2));
        expect(mints, 1);
        expect(tokenOf(client), isNot(first));
        expect(events, [
          MebiusClientEventType.connected,
          MebiusClientEventType.tokenRefreshed,
        ]);
      });
    });

    test('keeps renewing, so a long broadcast never runs out', () {
      FakeAsync().run((async) {
        var mints = 0;
        Mebius.connect(
          token: jwt(),
          getToken: () async {
            mints += 1;
            return jwt(expiresIn: oneHour * (mints + 1));
          },
        );
        async
          ..flushMicrotasks()
          // Six hours: a full match, several times the life of one credential.
          ..elapse(const Duration(hours: 6));
        expect(mints, greaterThanOrEqualTo(3));
      });
    });

    test('survives a provider that fails three times, then succeeds', () {
      FakeAsync().run((async) {
        var attempts = 0;
        final events = <MebiusClientEvent>[];
        final client = Mebius.connect(
          token: jwt(),
          getToken: () async {
            attempts += 1;
            if (attempts <= 3) {
              throw Exception('backend down');
            }
            return jwt(expiresIn: oneHour * 3);
          },
        );
        client.events.listen(events.add);
        async
          ..flushMicrotasks()
          // Past the first renewal attempt, then through the 2s/4s/8s backoff.
          ..elapse(const Duration(hours: 1))
          ..elapse(const Duration(seconds: 30));

        expect(attempts, 4);
        // The session was never declared dead: the old token stayed valid the
        // whole time, which is the entire point of retrying inside its window.
        expect(
          events.where((e) => e.type == MebiusClientEventType.error),
          isEmpty,
        );
        expect(
          events.where((e) => e.type == MebiusClientEventType.tokenRefreshed),
          hasLength(1),
        );
      });
    });

    test('reports expiry when the provider fails with no window left', () {
      FakeAsync().run((async) {
        final events = <MebiusClientEvent>[];
        // Already expired: there is no window left to retry inside.
        final client = Mebius.connect(
          token: jwt(expiresIn: -oneHour),
          getToken: () async => throw Exception('backend down'),
        );
        client.events.listen(events.add);
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 5));

        expect(
          events.map((e) => e.error?.code),
          contains(MebiusErrorCode.tokenExpired),
        );
      });
    });

    test('retries a token that is not newer, and only reports once time is up',
        () {
      FakeAsync().run((async) {
        final stale = jwt();
        final events = <MebiusClientEvent>[];
        final client = Mebius.connect(token: stale, getToken: () async => stale);
        client.events.listen(events.add);
        async
          ..flushMicrotasks()
          // Renewal is due a minute before expiry. A provider stuck on a cached
          // credential is a FAILED mint, not a dead session: the old token is
          // still good for that minute, so nothing may be reported yet.
          ..elapse(const Duration(minutes: 59, seconds: 30));
        expect(
          events.where((e) => e.error?.code == MebiusErrorCode.tokenExpired),
          isEmpty,
          reason: 'reported expiry while the old token was still valid',
        );

        // Once the window really is gone, say so — once, not in a loop.
        async.elapse(const Duration(hours: 2));
        expect(
          events.where((e) => e.error?.code == MebiusErrorCode.tokenExpired),
          hasLength(1),
        );
      });
    });

    test('drops a renewal for the wrong stream instead of installing it', () {
      FakeAsync().run((async) {
        final events = <MebiusClientEvent>[];
        final client = Mebius.connect(
          token: jwt(streamId: 's_match'),
          // A provider closure holding a stale stream id. Installing this would
          // break the session on its next request, far from the cause.
          getToken: () async => jwt(streamId: 's_other', expiresIn: oneHour * 5),
        );
        client.events.listen(events.add);
        async
          ..flushMicrotasks()
          ..elapse(const Duration(hours: 1));

        expect(tokenOf(client), isNot(contains('s_other')));
        expect(
          events.where((e) => e.type == MebiusClientEventType.tokenRefreshed),
          isEmpty,
        );
      });
    });

    test('a late provider answer does not undo an updateToken made meanwhile',
        () {
      FakeAsync().run((async) {
        late void Function() release;
        final client = Mebius.connect(
          token: jwt(streamId: 's_match'),
          getToken: () {
            final completer = Completer<String>();
            release = () => completer.complete(
                  jwt(streamId: 's_match', expiresIn: oneHour * 2),
                );
            return completer.future;
          },
        );
        async
          ..flushMicrotasks()
          // Renewal starts and blocks inside the provider.
          ..elapse(const Duration(hours: 1));

        // The app swaps the credential itself while the provider is thinking.
        final manual = jwt(streamId: 's_match', expiresIn: oneHour * 9);
        client.updateToken(manual);
        release();
        async.flushMicrotasks();

        // The provider's stale answer must not stomp what the app just set.
        expect(tokenOf(client), manual);
      });
    });

    test('a disconnect during a failing renewal leaves no timer behind', () {
      FakeAsync().run((async) {
        late void Function() fail;
        final client = Mebius.connect(
          token: jwt(),
          getToken: () {
            final completer = Completer<String>();
            fail = () => completer.completeError(Exception('backend down'));
            return completer.future;
          },
        );
        async
          ..flushMicrotasks()
          ..elapse(const Duration(hours: 1));

        // disconnect() cancels what it knows about; the provider then fails.
        // Re-arming a retry there would leave a live Timer owned by nobody.
        unawaited(client.disconnect());
        async.flushMicrotasks();
        fail();
        async.flushMicrotasks();

        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('updateToken', () {
    test('replaces the credential without restarting anything', () {
      FakeAsync().run((async) {
        final client = Mebius.connect(token: jwt(streamId: 's_match'));
        async.flushMicrotasks();
        final before = tokenOf(client);

        final next = jwt(streamId: 's_match', expiresIn: oneHour * 2);
        client.updateToken(next);

        expect(tokenOf(client), next);
        expect(tokenOf(client), isNot(before));
      });
    });

    test('throws on a token for another stream, and the session survives', () {
      FakeAsync().run((async) {
        final client = Mebius.connect(token: jwt(streamId: 's_match'));
        async.flushMicrotasks();
        final before = tokenOf(client);

        expect(
          () => client.updateToken(jwt(streamId: 's_other')),
          throwsA(isA<MebiusError>()),
        );
        // Unchanged, and still usable: a rejected swap must not be a way to
        // break a live broadcast.
        expect(tokenOf(client), before);
        expect(client.isConnected, isTrue);
      });
    });

    test('throws on an empty token', () {
      FakeAsync().run((async) {
        final client = Mebius.connect(token: jwt());
        async.flushMicrotasks();
        expect(() => client.updateToken(''), throwsA(isA<MebiusError>()));
      });
    });
  });
}

const Duration oneHour = Duration(hours: 1);

/// The credential the session is currently authenticating with.
///
/// Read through a player's engine because that is where the session's signaling
/// actually lives — the same object every request is built from, so this is the
/// value under test rather than a copy of it.
String tokenOf(MebiusClient client) =>
    client.createPlayer().engine.signaling.token;

/// An unsigned JWT carrying just the claims this SDK reads. Nothing verifies it
/// here; only the gateway holds the secret.
String jwt({String? streamId, Duration expiresIn = oneHour}) {
  final payload = <String, dynamic>{
    if (streamId != null) 'streamId': streamId,
    // clock.now(), not DateTime.now(): inside FakeAsync these differ by however
    // far the test has elapsed, and a token minted against real time would be
    // born already expired from the SDK's point of view.
    'exp': clock.now().toUtc().add(expiresIn).millisecondsSinceEpoch ~/ 1000,
  };
  final encoded = base64Url.encode(utf8.encode(jsonEncode(payload)));
  return 'header.$encoded.sig';
}
