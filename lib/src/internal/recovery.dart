// INTERNAL — not part of the public Mebius surface.
//
// The two decisions behind reopening a route that stopped delivering, kept as
// plain objects with no timers and no I/O so they can be tested directly. The
// player owns the clock; these own the arithmetic.

// Internal implementation detail; not part of the documented public surface.
// ignore_for_file: public_member_api_docs

/// How long the picture may stand still before its route is treated as dead.
///
/// Deliberately longer than the first-frame budget: a route that is merely slow
/// deserves to finish, because reopening a healthy stream costs the viewer a
/// rebuffer for nothing.
const Duration kStallRecoveryTimeout = Duration(seconds: 10);

/// How many times a lost route is reopened before the session is declared over.
///
/// The SDK cannot tell "the broadcast ended" from "the edge dropped us" — both
/// look like a route that stopped producing frames. So it assumes the
/// recoverable case, which is the common one on a long broadcast, and spends a
/// bounded amount of time proving itself wrong.
const int kMaxRecoveryAttempts = 5;

const Duration _kRecoveryBase = Duration(seconds: 1);

/// Ceiling on the reopen delay. Bounded because every viewer of one broadcast
/// fails at the same instant — an edge restart is not an individual event — and
/// an unbounded retry storm from a full room is how a recovery mechanism becomes
/// the outage.
const Duration _kRecoveryMax = Duration(seconds: 30);

/// Counts reopen attempts and spaces them out.
class RecoveryPolicy {
  int _attempts = 0;

  /// Attempts spent since the last [reset].
  int get attempts => _attempts;

  /// Whether the budget is used up and the session should be declared over.
  bool get exhausted => _attempts >= kMaxRecoveryAttempts;

  /// Delay before the next attempt, consuming one attempt from the budget.
  ///
  /// Doubles per attempt: 1s, 2s, 4s, 8s, 16s.
  Duration nextDelay() {
    final ms = _kRecoveryBase.inMilliseconds * (1 << _attempts);
    _attempts += 1;
    return Duration(
      milliseconds:
          ms > _kRecoveryMax.inMilliseconds ? _kRecoveryMax.inMilliseconds : ms,
    );
  }

  /// Forgets the attempts spent. Called when playback is proven healthy again.
  void reset() {
    _attempts = 0;
  }
}

/// Decides when a route has stopped delivering, from a monotonic progress count.
///
/// Flutter has no event for "this route died": the platform player and the peer
/// connection both sit there reporting a healthy session while nothing arrives.
/// The only trustworthy signal is whether the picture is still moving, so that is
/// what is measured — decoded frames on the real-time route, playhead position on
/// the segmented one. Both only ever go up while media is flowing.
class StallDetector {
  StallDetector({this.threshold = kStallRecoveryTimeout});

  /// How long without progress counts as a stall.
  final Duration threshold;

  int _last = -1;
  Duration _still = Duration.zero;

  /// Feeds one observation taken [interval] after the previous one.
  ///
  /// Returns true exactly once per stall, when the picture has stood still for
  /// longer than [threshold]. A negative [progress] means the source could not be
  /// read this time — a stats call that threw, a controller mid-teardown — and is
  /// neither progress nor evidence of a stall, so the clock keeps running but the
  /// mark is left alone.
  bool tick(int progress, Duration interval) {
    if (progress < 0) {
      _still += interval;
    } else if (progress > _last) {
      _last = progress;
      _still = Duration.zero;
      return false;
    } else {
      _still += interval;
    }
    if (_still >= threshold) {
      // Consumed, so one stall raises one recovery rather than one per tick for
      // as long as the freeze lasts.
      _still = Duration.zero;
      return true;
    }
    return false;
  }

  /// Forgets everything observed so far. Called whenever a route is (re)opened.
  void reset() {
    _last = -1;
    _still = Duration.zero;
  }
}
