// INTERNAL — not part of the public Mebius surface.
//
// The decision behind a broadcaster's `connectionState` and `error` events:
// which peer-connection states count as a failure, and how long a blip is
// allowed to last before it becomes one. The timer lives here; the WebRTC
// wiring that feeds it lives in BroadcastEngine, and the event emission in
// MebiusBroadcaster. Kept apart so this logic is testable without a native
// peer connection.

import 'dart:async';

/// Decides, from peer-connection state reports, when a live broadcast has
/// failed — and surfaces every state along the way.
///
/// The SDK does not reconnect: a failed connection is terminal, and the app
/// decides whether to start a new broadcast. Two things count as failure:
///   * `failed` — reported immediately.
///   * `disconnected` that does not return to `connected`/`completed` within
///     [graceWindow]. WebRTC uses `disconnected` for a transient blip it often
///     recovers from on its own, so a short one is not an error.
///
/// At most one failure is raised per [reset] cycle, so a `failed` that follows
/// a grace-expired `disconnected` (or the reverse) does not double-report.
class ConnectionWatch {
  /// Creates a watch. [onState] fires for every reported state; [onFailed]
  /// fires once when the connection is judged to have failed.
  ConnectionWatch({
    required this.onState,
    required this.onFailed,
    this.graceWindow = const Duration(seconds: 5),
  });

  /// Called for every state reported, with the normalised lower-case name
  /// (`connected`, `disconnected`, `failed`, `completed`, ...).
  final void Function(String state) onState;

  /// Called once, when the connection is judged to have failed.
  final void Function() onFailed;

  /// How long a `disconnected` may last before it is treated as a failure.
  final Duration graceWindow;

  Timer? _grace;
  bool _failed = false;
  bool _disposed = false;
  String? _last;

  /// Feeds one normalised state into the watch.
  ///
  /// The peer connection and its ICE transport are both wired to this, so the
  /// same state arrives twice; an immediate repeat is dropped so an app sees
  /// one event per real change. Reports after [dispose] are ignored.
  void report(String state) {
    if (_disposed || state == _last) {
      return;
    }
    _last = state;
    onState(state);
    switch (state) {
      case 'failed':
        _raise();
      case 'disconnected':
        _grace ??= Timer(graceWindow, _raise);
      case 'connected':
      case 'completed':
      case 'closed':
        _grace?.cancel();
        _grace = null;
    }
  }

  void _raise() {
    _grace?.cancel();
    _grace = null;
    if (_failed) {
      return;
    }
    _failed = true;
    onFailed();
  }

  /// Re-arms the watch for a fresh broadcast: forgets the previous failure,
  /// the last state, and any pending grace window, and re-enables reporting
  /// after a [dispose].
  void reset() {
    _grace?.cancel();
    _grace = null;
    _failed = false;
    _disposed = false;
    _last = null;
  }

  /// Cancels any pending grace timer and ignores further reports, so a stopped
  /// broadcast cannot later raise a failure.
  void dispose() {
    _grace?.cancel();
    _grace = null;
    _disposed = true;
  }
}
