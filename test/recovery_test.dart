import 'package:flutter_test/flutter_test.dart';
import 'package:mebius/src/internal/recovery.dart';

/// The arithmetic behind reopening a route that stopped delivering.
///
/// Route selection ran once, inside the first `play()`. Whatever produced a
/// frame served the rest of the session, and when it later died the picture
/// simply froze — no error, no event, nothing for an app to react to. On a
/// 90-minute watch that looked like bad luck; on a broadcast that runs for a day
/// it is a certainty, and the viewer's word for it is a black screen.
///
/// The timers live in the player. What is tested here is what it decides: when a
/// still picture counts as a dead route, and how long to wait between reopens.
void main() {
  group('StallDetector', () {
    test('says nothing while the picture is still moving', () {
      final d = StallDetector();
      var frames = 0;
      for (var i = 0; i < 20; i++) {
        frames += 25;
        expect(d.tick(frames, const Duration(seconds: 2)), isFalse);
      }
    });

    test('reports a route as lost once the picture stands still', () {
      final d = StallDetector();
      expect(d.tick(100, const Duration(seconds: 2)), isFalse);
      // Frozen: the counter stops moving, which is all a dead route looks like.
      for (var i = 0; i < 4; i++) {
        expect(d.tick(100, const Duration(seconds: 2)), isFalse,
            reason: 'still inside the budget',);
      }
      expect(d.tick(100, const Duration(seconds: 2)), isTrue);
    });

    test('raises one recovery per stall, not one per tick', () {
      final d = StallDetector(threshold: const Duration(seconds: 4))
        ..tick(10, const Duration(seconds: 2))
        ..tick(10, const Duration(seconds: 2));
      expect(d.tick(10, const Duration(seconds: 2)), isTrue);
      expect(d.tick(10, const Duration(seconds: 2)), isFalse,
          reason: 'the stall was consumed; the next one starts counting again',);
    });

    test('treats an unreadable sample as neither progress nor a fresh start', () {
      final d = StallDetector(threshold: const Duration(seconds: 4))
        ..tick(50, const Duration(seconds: 2));
      // -1 is "could not read the stats this time", not "the playhead went back".
      expect(d.tick(-1, const Duration(seconds: 2)), isFalse);
      expect(d.tick(-1, const Duration(seconds: 2)), isTrue);
      d.reset();
      expect(d.tick(51, const Duration(seconds: 2)), isFalse);
    });

    test('forgets a frozen counter after a reopen', () {
      final d = StallDetector(threshold: const Duration(seconds: 4))
        ..tick(7, const Duration(seconds: 2))
        ..reset();
      // A reopened route counts from its own zero; without the reset that would
      // read as the playhead going backwards.
      expect(d.tick(0, const Duration(seconds: 2)), isFalse);
      expect(d.tick(1, const Duration(seconds: 2)), isFalse);
    });
  });

  group('RecoveryPolicy', () {
    test('spaces attempts out instead of hammering the edge', () {
      final p = RecoveryPolicy();
      expect(p.nextDelay(), const Duration(seconds: 1));
      expect(p.nextDelay(), const Duration(seconds: 2));
      expect(p.nextDelay(), const Duration(seconds: 4));
      expect(p.nextDelay(), const Duration(seconds: 8));
      expect(p.nextDelay(), const Duration(seconds: 16));
    });

    test('gives up after a bounded number of attempts', () {
      final p = RecoveryPolicy();
      for (var i = 0; i < kMaxRecoveryAttempts; i++) {
        expect(p.exhausted, isFalse);
        p.nextDelay();
      }
      expect(p.exhausted, isTrue);
    });

    test('caps the wait, so a long outage does not become an hour of silence', () {
      final p = RecoveryPolicy();
      for (var i = 0; i < 12; i++) {
        expect(p.nextDelay().inSeconds, lessThanOrEqualTo(30));
      }
    });

    test('counts CONSECUTIVE failures, so a flapping route can recover all day', () {
      final p = RecoveryPolicy()
        ..nextDelay()
        ..nextDelay()
        ..reset();
      expect(p.exhausted, isFalse);
      expect(p.nextDelay(), const Duration(seconds: 1));
    });
  });
}
