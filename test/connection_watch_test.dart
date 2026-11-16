import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mebius/src/internal/connection_watch.dart';

/// The rule a broadcast's connection health follows: `failed` is terminal at
/// once, a `disconnected` is forgiven only if it clears inside the grace
/// window, and no failure is ever raised twice for the same broadcast.
void main() {
  group('ConnectionWatch', () {
    test('surfaces every state in order', () {
      final states = <String>[];
      var failures = 0;
      ConnectionWatch(onState: states.add, onFailed: () => failures++)
        ..report('connecting')
        ..report('connected');
      expect(states, ['connecting', 'connected']);
      expect(failures, 0);
    });

    test('a failed state emits the state first, then one failure', () {
      final order = <String>[];
      ConnectionWatch(
        onState: (s) => order.add('state:$s'),
        onFailed: () => order.add('failed'),
      ).report('failed');
      // Order is the contract: an app sees why (the state) before the error.
      expect(order, ['state:failed', 'failed']);
    });

    test('a disconnect that recovers inside the grace window is not an error', () {
      fakeAsync((async) {
        var failures = 0;
        final w = ConnectionWatch(
          onState: (_) {},
          onFailed: () => failures++,
        )..report('disconnected');
        async.elapse(const Duration(seconds: 3));
        w.report('connected');
        async.elapse(const Duration(seconds: 10));
        expect(failures, 0);
      });
    });

    test('a disconnect longer than the grace window fails exactly once', () {
      fakeAsync((async) {
        var failures = 0;
        ConnectionWatch(
          onState: (_) {},
          onFailed: () => failures++,
        ).report('disconnected');
        async.elapse(const Duration(seconds: 6));
        expect(failures, 1);
      });
    });

    test('a failed after a grace-expired disconnect does not double-report', () {
      fakeAsync((async) {
        var failures = 0;
        final w = ConnectionWatch(
          onState: (_) {},
          onFailed: () => failures++,
        )..report('disconnected');
        async.elapse(const Duration(seconds: 6));
        w.report('failed');
        expect(failures, 1);
      });
    });

    test('reset re-arms the watch for the next broadcast', () {
      var failures = 0;
      final w = ConnectionWatch(
        onState: (_) {},
        onFailed: () => failures++,
      )..report('failed');
      expect(failures, 1);
      w
        ..reset()
        ..report('failed');
      expect(failures, 2);
    });

    test('dispose cancels a pending grace timer so stop cannot later fail', () {
      fakeAsync((async) {
        var failures = 0;
        ConnectionWatch(
          onState: (_) {},
          onFailed: () => failures++,
        )
          ..report('disconnected')
          ..dispose();
        async.elapse(const Duration(seconds: 10));
        expect(failures, 0);
      });
    });

    test('connecting is not recovery: a flap that never reconnects fails once',
        () {
      fakeAsync((async) {
        var failures = 0;
        final w = ConnectionWatch(
          onState: (_) {},
          onFailed: () => failures++,
        )..report('disconnected');
        async.elapse(const Duration(seconds: 2));
        // WebRTC goes disconnected -> connecting while it tries to recover.
        // That is not `connected`, so the grace window keeps running from the
        // first disconnect; it must still fail.
        w.report('connecting');
        async.elapse(const Duration(seconds: 4));
        expect(failures, 1);
      });
    });

    test('a second disconnect after a real recovery gets its own grace window',
        () {
      fakeAsync((async) {
        var failures = 0;
        final w = ConnectionWatch(
          onState: (_) {},
          onFailed: () => failures++,
        )..report('disconnected');
        async.elapse(const Duration(seconds: 3));
        w.report('connected'); // recovered: cancels the first window
        async.elapse(const Duration(seconds: 10));
        expect(failures, 0, reason: 'first episode cleared');
        // A fresh disconnect must start counting from zero, not inherit the
        // already-elapsed time.
        w.report('disconnected');
        async.elapse(const Duration(seconds: 4));
        expect(failures, 0, reason: 'still inside the second window');
        async.elapse(const Duration(seconds: 2));
        expect(failures, 1);
      });
    });
  });
}
