import 'package:mebius/src/mebius_error.dart';
import 'package:meta/meta.dart';

/// Lifecycle states emitted by a `MebiusClient` connection.
enum MebiusClientEventType {
  /// The client has established a connection to the Mebius gateway.
  connected,

  /// The client has disconnected from the Mebius gateway.
  disconnected,

  /// The client encountered an error. The accompanying event carries a
  /// [MebiusError].
  error,
}

/// Lifecycle states emitted by a `MebiusBroadcaster`.
enum MebiusBroadcasterEventType {
  /// Broadcasting has started and media is being delivered to the gateway.
  started,

  /// Broadcasting has stopped.
  stopped,

  /// A periodic statistics update is available.
  stats,
}

/// Lifecycle states emitted by a `MebiusPlayer`.
enum MebiusPlayerEventType {
  /// Playback is active and media is rendering.
  playing,

  /// Playback has stalled and is buffering.
  buffering,

  /// Playback has ended.
  ended,

  /// A periodic statistics update is available.
  stats,
}

/// An event emitted on a `MebiusClient`'s event stream.
@immutable
class MebiusClientEvent {
  /// Creates a client event of [type], optionally carrying an [error] (set
  /// only when [type] is [MebiusClientEventType.error]).
  const MebiusClientEvent(this.type, {this.error});

  /// The kind of client lifecycle event.
  final MebiusClientEventType type;

  /// The associated error, present only for
  /// [MebiusClientEventType.error] events.
  final MebiusError? error;

  @override
  String toString() => 'MebiusClientEvent(${type.name}'
      '${error != null ? ', $error' : ''})';
}

/// Snapshot of broadcast statistics delivered with a `stats` event.
@immutable
class MebiusBroadcastStats {
  /// Creates a broadcast statistics snapshot.
  const MebiusBroadcastStats({
    required this.outboundBitrateKbps,
    required this.frameRate,
    required this.packetsSent,
  });

  /// Outbound video bitrate in kilobits per second.
  final double outboundBitrateKbps;

  /// Encoded frames delivered per second.
  final double frameRate;

  /// Total media packets sent since broadcasting started.
  final int packetsSent;

  @override
  String toString() => 'MebiusBroadcastStats(bitrate=${outboundBitrateKbps}kbps'
      ', fps=$frameRate, packets=$packetsSent)';
}

/// An event emitted on a `MebiusBroadcaster`'s event stream.
@immutable
class MebiusBroadcasterEvent {
  /// Creates a broadcaster event of [type], optionally carrying [stats] (set
  /// only when [type] is [MebiusBroadcasterEventType.stats]).
  const MebiusBroadcasterEvent(this.type, {this.stats});

  /// The kind of broadcaster lifecycle event.
  final MebiusBroadcasterEventType type;

  /// The associated statistics, present only for
  /// [MebiusBroadcasterEventType.stats] events.
  final MebiusBroadcastStats? stats;

  @override
  String toString() => 'MebiusBroadcasterEvent(${type.name}'
      '${stats != null ? ', $stats' : ''})';
}

/// Snapshot of playback statistics delivered with a `stats` event.
@immutable
class MebiusPlaybackStats {
  /// Creates a playback statistics snapshot.
  const MebiusPlaybackStats({
    required this.inboundBitrateKbps,
    required this.frameRate,
    required this.bufferedMs,
  });

  /// Inbound video bitrate in kilobits per second.
  final double inboundBitrateKbps;

  /// Decoded frames rendered per second.
  final double frameRate;

  /// Amount of media currently buffered, in milliseconds.
  final int bufferedMs;

  @override
  String toString() => 'MebiusPlaybackStats(bitrate=${inboundBitrateKbps}kbps'
      ', fps=$frameRate, buffered=${bufferedMs}ms)';
}

/// An event emitted on a `MebiusPlayer`'s event stream.
@immutable
class MebiusPlayerEvent {
  /// Creates a player event of [type], optionally carrying [stats] (set only
  /// when [type] is [MebiusPlayerEventType.stats]).
  const MebiusPlayerEvent(this.type, {this.stats});

  /// The kind of player lifecycle event.
  final MebiusPlayerEventType type;

  /// The associated statistics, present only for
  /// [MebiusPlayerEventType.stats] events.
  final MebiusPlaybackStats? stats;

  @override
  String toString() => 'MebiusPlayerEvent(${type.name}'
      '${stats != null ? ', $stats' : ''})';
}
