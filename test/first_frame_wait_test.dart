import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mebius/mebius.dart';
import 'package:mebius/src/internal/playback_engine.dart';

/// Runs [awaitFirstFrame] on a fake clock and reports what it decided and
/// when. [script] maps elapsed time to what the route shows at that moment.
({bool? result, Duration at}) _run({
  required bool hls,
  required FrameProbe Function(Duration elapsed) script,
  bool Function(Duration elapsed)? current,
}) {
  bool? result;
  var at = Duration.zero;
  fakeAsync((async) {
    final start = clock.now();
    Duration elapsed() => clock.now().difference(start);
    unawaited(
      awaitFirstFrame(
        hls: hls,
        current: () => current?.call(elapsed()) ?? true,
        probe: () async => script(elapsed()),
      ).then((r) {
        result = r;
        at = elapsed();
      }),
    );
    async.elapse(const Duration(seconds: 60));
  });
  return (result: result, at: at);
}

void main() {
  test('HLS: a route still loading at 8 s is kept; first frame at 12 s', () {
    // The iPhone failure: cold-edge playlists take ~10 s, so 8 s abandoned a
    // route that was about to play and restarted the next one from zero.
    final r = _run(
      hls: true,
      script: (t) => t >= const Duration(seconds: 12)
          ? FrameProbe.frame
          : FrameProbe.progressing,
    );
    expect(r.result, isTrue);
    expect(r.at, greaterThanOrEqualTo(const Duration(seconds: 12)));
    expect(r.at, lessThan(const Duration(seconds: 13)));
  });

  test('HLS: a silent route also gets the full 20 s before abandoning', () {
    final r = _run(hls: true, script: (_) => FrameProbe.waiting);
    expect(r.result, isFalse);
    expect(r.at, greaterThanOrEqualTo(kHlsFirstFrameTimeout));
    expect(r.at, lessThan(kHlsFirstFrameTimeout + const Duration(seconds: 1)));
  });

  test('HLS: still progressing at 20 s extends, but never past 30 s', () {
    final r = _run(hls: true, script: (_) => FrameProbe.progressing);
    expect(r.result, isFalse);
    expect(r.at, greaterThanOrEqualTo(kHlsFirstFrameHardCap));
    expect(r.at, lessThan(kHlsFirstFrameHardCap + const Duration(seconds: 1)));

    final late = _run(
      hls: true,
      script: (t) => t >= const Duration(seconds: 25)
          ? FrameProbe.frame
          : FrameProbe.progressing,
    );
    expect(late.result, isTrue);
  });

  test('HLS: an error at 2 s is abandoned immediately', () {
    final r = _run(
      hls: true,
      script: (t) => t >= const Duration(seconds: 2)
          ? FrameProbe.failed
          : FrameProbe.progressing,
    );
    expect(r.result, isFalse);
    expect(r.at, lessThan(const Duration(milliseconds: 2500)));
  });

  test('FLV: unchanged — abandoned at 8 s whatever the probe says', () {
    for (final seen in [FrameProbe.progressing, FrameProbe.waiting]) {
      final r = _run(hls: false, script: (_) => seen);
      expect(r.result, isFalse);
      expect(r.at, greaterThanOrEqualTo(kFirstFrameTimeout));
      expect(r.at, lessThan(kFirstFrameTimeout + const Duration(seconds: 1)));
    }
    final frame = _run(
      hls: false,
      script: (t) => t >= const Duration(seconds: 1)
          ? FrameProbe.frame
          : FrameProbe.waiting,
    );
    expect(frame.result, isTrue);
    expect(kFirstFrameTimeout, const Duration(seconds: 8));
  });

  test('a stop during the longer HLS wait retires the open at once', () {
    // The generation check still wins: a frame that arrives after stop()
    // belongs to whatever came next, not to this open.
    final r = _run(
      hls: true,
      current: (t) => t < const Duration(seconds: 15),
      script: (t) => t >= const Duration(seconds: 15)
          ? FrameProbe.frame
          : FrameProbe.progressing,
    );
    expect(r.result, isFalse);
    expect(r.at, lessThan(const Duration(milliseconds: 15500)));
  });

  group('HLS progress on iOS', () {
    // AVPlayer keeps isBuffering false before the first frame, and a live
    // playlist's buffered end grows one segment (~3 s) at a time.
    FrameProbe Function(Duration) segments({
      required Duration frameAt,
      Duration stallAt = const Duration(hours: 1),
    }) {
      final progress = HlsProgress();
      return (t) {
        if (t >= frameAt) {
          return FrameProbe.frame;
        }
        final grown = (t < stallAt ? t : stallAt).inSeconds ~/ 3 * 3;
        return progress.progressing(
          isBuffering: false,
          bufferedEnd: Duration(seconds: grown),
        )
            ? FrameProbe.progressing
            : FrameProbe.waiting;
      };
    }

    test('buffered grows every 3 s, first frame at 24 s: kept', () {
      final r = _run(
        hls: true,
        script: segments(frameAt: const Duration(seconds: 24)),
      );
      expect(r.result, isTrue);
      expect(r.at, greaterThanOrEqualTo(const Duration(seconds: 24)));
    });

    test('buffer that stopped growing at 9 s is abandoned at 20 s', () {
      final r = _run(
        hls: true,
        script: segments(
          frameAt: const Duration(seconds: 28),
          stallAt: const Duration(seconds: 9),
        ),
      );
      expect(r.result, isFalse);
      expect(r.at, lessThan(const Duration(seconds: 21)));
    });

    test('isBuffering alone counts as progress', () {
      final p = HlsProgress();
      expect(
        p.progressing(isBuffering: true, bufferedEnd: Duration.zero),
        isTrue,
      );
      expect(
        p.progressing(isBuffering: false, bufferedEnd: Duration.zero),
        isFalse,
      );
    });
  });

  group('initializeWithin', () {
    for (final completes in [true, false]) {
      test(
          'times out with connectionFailed and disposes at once '
          '(open ${completes ? 'completes late' : 'never completes'})', () {
        fakeAsync((async) {
          final init = Completer<void>();
          var disposed = 0;
          Object? error;
          unawaited(
            initializeWithin(
              () => init.future,
              () async => disposed += 1,
              kHlsInitializeTimeout,
            ).then<void>(
              (_) {},
              onError: (Object e) {
                error = e;
              },
            ),
          );
          async.elapse(const Duration(seconds: 19));
          expect(error, isNull);
          expect(disposed, 0);
          async.elapse(const Duration(seconds: 1));
          expect(
            error,
            isA<MebiusError>().having(
              (e) => e.code,
              'code',
              MebiusErrorCode.connectionFailed,
            ),
          );
          // Not waiting for the open: one that never completes must still be
          // released (the real dispose waits for the native create step).
          expect(disposed, 1);
          if (completes) {
            init.complete();
          }
          async.elapse(const Duration(seconds: 60));
          expect(disposed, 1, reason: 'disposed exactly once');
        });
      });
    }

    test('an initialize that throws is disposed and rethrown at once', () {
      fakeAsync((async) {
        var disposed = 0;
        Object? error;
        unawaited(
          initializeWithin(
            () => Future<void>.error(StateError('bad')),
            () async => disposed += 1,
            kHlsInitializeTimeout,
          ).then<void>(
            (_) {},
            onError: (Object e) {
              error = e;
            },
          ),
        );
        async.flushMicrotasks();
        expect(error, isA<StateError>());
        expect(disposed, 1);
      });
    });

    test('a timely initialize is left alone', () {
      fakeAsync((async) {
        var disposed = 0;
        var done = false;
        unawaited(
          initializeWithin(
            () => Future<void>.delayed(const Duration(seconds: 3)),
            () async => disposed += 1,
            kFlvInitializeTimeout,
          ).then<void>((_) => done = true),
        );
        async.elapse(const Duration(seconds: 30));
        expect(done, isTrue);
        expect(disposed, 0);
      });
    });
  });
}
