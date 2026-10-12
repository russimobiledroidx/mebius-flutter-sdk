import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mebius/mebius.dart';
import 'package:mebius/src/internal/gateway_signaling.dart';
import 'package:mebius/src/internal/playback_engine.dart';
import 'package:video_player/video_player.dart';

/// A platform player that never reaches the platform: [initialize] does what
/// the test says, and [dispose] records whether the engine still exposed it.
class _Controller extends VideoPlayerController {
  _Controller(this.engine, this.init) : super.networkUrl(Uri.parse('x:'));

  final PlaybackEngine engine;
  final Future<void> Function() init;
  int disposes = 0;
  bool? publishedAtDispose;

  @override
  Future<void> initialize() => init();

  @override
  Future<void> dispose() async {
    disposes += 1;
    publishedAtDispose ??= identical(engine.videoController, this);
    await super.dispose();
  }
}

({PlaybackEngine engine, List<_Controller> made}) _engine(
  Future<void> Function() init,
) {
  final engine = PlaybackEngine(
    signaling: GatewaySignaling(
      gateway: 'https://gw.example',
      token: 'tok',
      httpClient: MockClient((_) async => http.Response('', 200)),
    ),
    pipeline: PlaybackPipeline.scale,
  )..deliveries = const [MebiusDelivery(kind: 'wide', path: '/d/wide/s1')];
  final made = <_Controller>[];
  engine.createController = (url, hint) {
    final c = _Controller(engine, init);
    made.add(c);
    return c;
  };
  return (engine: engine, made: made);
}

void main() {
  test('an initialize that never completes: each player disposed once', () {
    // wide, then the origin playlist: both hang. Before the bound the viewer
    // sat on "connecting" forever; after it, without an immediate dispose,
    // both native players kept fetching.
    fakeAsync((async) {
      final t = _engine(() => Completer<void>().future);
      Object? error;
      unawaited(
        t.engine.start('s1').then<void>(
          (_) {},
          onError: (Object e) {
            error = e;
          },
        ),
      );
      async.elapse(kHlsInitializeTimeout * 2 + const Duration(seconds: 1));
      expect(error, isA<MebiusError>());
      expect(t.made, hasLength(2));
      expect(t.made.map((c) => c.disposes), [1, 1]);
      expect(t.engine.videoController, isNull);
    });
  });

  test('a failed initialize is unpublished before it is disposed', () async {
    final t = _engine(() => Future<void>.error(StateError('no')));
    await expectLater(t.engine.start('s1'), throwsA(isA<MebiusError>()));
    expect(t.made, hasLength(2));
    for (final c in t.made) {
      expect(c.disposes, 1);
      expect(c.publishedAtDispose, isFalse);
    }
    expect(t.engine.videoController, isNull);
  });
}
