import 'package:flutter_test/flutter_test.dart';
import 'package:mebius/mebius.dart';

void main() {
  setUp(Mebius.resetForTesting);
  tearDown(Mebius.resetForTesting);

  group('Mebius.init', () {
    test('records configuration', () {
      Mebius.init(appId: 'app', gateway: 'https://gw.example');
      expect(Mebius.isInitialized, isTrue);
      expect(Mebius.appId, 'app');
      expect(Mebius.gateway, 'https://gw.example');
    });

    test('rejects empty appId', () {
      expect(
        () => Mebius.init(appId: '', gateway: 'https://gw.example'),
        throwsA(
          isA<MebiusError>().having(
            (e) => e.code,
            'code',
            MebiusErrorCode.unknown,
          ),
        ),
      );
    });

    test('rejects empty gateway', () {
      expect(
        () => Mebius.init(appId: 'app', gateway: ''),
        throwsA(isA<MebiusError>()),
      );
    });
  });

  group('Mebius.connect', () {
    test('throws when not initialized', () {
      expect(
        () => Mebius.connect(token: 'jwt'),
        throwsA(
          isA<MebiusError>().having(
            (e) => e.code,
            'code',
            MebiusErrorCode.unknown,
          ),
        ),
      );
    });

    test('throws TOKEN_EXPIRED on empty token', () {
      Mebius.init(appId: 'app', gateway: 'https://gw.example');
      expect(
        () => Mebius.connect(token: ''),
        throwsA(
          isA<MebiusError>().having(
            (e) => e.code,
            'code',
            MebiusErrorCode.tokenExpired,
          ),
        ),
      );
    });

    test('returns a client when initialized', () async {
      Mebius.init(appId: 'app', gateway: 'https://gw.example');
      final client = Mebius.connect(token: 'jwt');
      addTearDown(client.disconnect);
      expect(client, isA<MebiusClient>());
    });
  });

  group('MebiusClient', () {
    test('emits connected then disconnected', () async {
      Mebius.init(appId: 'app', gateway: 'https://gw.example');
      final client = Mebius.connect(token: 'jwt');
      final events = <MebiusClientEventType>[];
      client.events.listen((e) => events.add(e.type));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(events, contains(MebiusClientEventType.connected));
      expect(client.isConnected, isTrue);
      await client.disconnect();
      expect(events, contains(MebiusClientEventType.disconnected));
      expect(client.isConnected, isFalse);
    });

    test('createBroadcaster requires at least one of video/audio', () async {
      Mebius.init(appId: 'app', gateway: 'https://gw.example');
      final client = Mebius.connect(token: 'jwt');
      addTearDown(client.disconnect);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        () => client.createBroadcaster(video: false, audio: false),
        throwsA(isA<MebiusError>()),
      );
    });

    test('factories throw NOT_CONNECTED after disconnect', () async {
      Mebius.init(appId: 'app', gateway: 'https://gw.example');
      final client = Mebius.connect(token: 'jwt');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await client.disconnect();
      expect(
        client.createPlayer,
        throwsA(
          isA<MebiusError>().having(
            (e) => e.code,
            'code',
            MebiusErrorCode.notConnected,
          ),
        ),
      );
    });
  });

  group('MebiusError', () {
    test('exposes canonical wire code names', () {
      expect(
        const MebiusError(MebiusErrorCode.tokenExpired, 'x').codeName,
        'TOKEN_EXPIRED',
      );
      expect(
        const MebiusError(MebiusErrorCode.streamNotFound, 'x').codeName,
        'STREAM_NOT_FOUND',
      );
    });

    test('from wraps arbitrary errors as unknown', () {
      final err = MebiusError.from(StateError('boom'));
      expect(err.code, MebiusErrorCode.unknown);
      expect(err.cause, isA<StateError>());
    });

    test('from passes through existing MebiusError', () {
      const original = MebiusError(MebiusErrorCode.streamNotFound, 'nope');
      expect(MebiusError.from(original), same(original));
    });
  });

  group('MebiusPlayerMode', () {
    test('player created with chosen mode', () async {
      Mebius.init(appId: 'app', gateway: 'https://gw.example');
      final client = Mebius.connect(token: 'jwt');
      addTearDown(client.disconnect);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final player = client.createPlayer(mode: MebiusPlayerMode.scale);
      expect(player.mode, MebiusPlayerMode.scale);
      expect(player.isPlaying, isFalse);
    });
  });
}
