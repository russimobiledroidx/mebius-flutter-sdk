import 'package:meta/meta.dart';

/// One playback route Mebius has prepared for a stream.
///
/// Your backend receives this list alongside the access token; hand it to
/// `Mebius.connect` untouched. Both fields are opaque: [kind] is a Mebius
/// intent label, not a media format, and [path] is resolved by Mebius against
/// its own gateway. Treating either as a format or a URL will break the moment
/// Mebius changes how a route is served — which is the point of the list.
class MebiusDelivery {
  /// Creates a delivery route descriptor.
  const MebiusDelivery({
    required this.kind,
    required this.path,
    this.renditions = const <MebiusQuality>[],
  });

  /// Builds a delivery from the JSON object your backend returned.
  ///
  /// Returns `null` for anything unusable, so a malformed or hostile entry is
  /// skipped rather than played.
  static MebiusDelivery? tryFromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final kind = json['kind'];
    final path = json['path'];
    if (kind is! String || path is! String) {
      return null;
    }
    final rungs = json['renditions'];
    return MebiusDelivery(
      kind: kind,
      path: path,
      renditions: rungs is List
          ? rungs
              .map(MebiusQuality._tryFromJson)
              .whereType<MebiusQuality>()
              .toList(growable: false)
          : const <MebiusQuality>[],
    );
  }

  /// Parses the `deliveries` array from a token response, skipping bad entries.
  static List<MebiusDelivery> listFromJson(Object? json) {
    if (json is! List) {
      return const <MebiusDelivery>[];
    }
    return json
        .map(MebiusDelivery.tryFromJson)
        .whereType<MebiusDelivery>()
        .toList(growable: false);
  }

  /// Mebius intent label for this route. Opaque to your app.
  final String kind;

  /// Mebius-relative path for this route. Opaque to your app.
  final String path;

  /// The quality ladder this route offers, highest first as the gateway lists
  /// it. Empty when the stream has no ladder — the route plays at source
  /// quality only.
  final List<MebiusQuality> renditions;

  /// Whether this route is safe to resolve against the Mebius gateway.
  ///
  /// The access token is a bearer credential, and a delivery path arrives as
  /// data in a response. An absolute or protocol-relative path would send that
  /// token to a host Mebius did not choose, so those are rejected outright
  /// rather than fetched.
  bool get isResolvable => _resolvable(path);

  @override
  String toString() =>
      'MebiusDelivery(kind: $kind, path: $path, renditions: $renditions)';
}

bool _resolvable(String path) =>
    path.startsWith('/') && !path.startsWith('//') && !path.contains('://');

/// One rung of a stream's quality ladder, e.g. 720p.
///
/// Read from `MebiusPlayer.qualities`; pass [id] to `MebiusPlayer.setQuality`.
@immutable
class MebiusQuality {
  /// Creates a quality rung.
  const MebiusQuality({
    required this.id,
    required this.height,
    required this.bitrateKbps,
    required this.path,
  });

  /// A rung missing an id, height or path is skipped, and so is one whose path
  /// could send the token off the gateway (same rule as [MebiusDelivery.path]).
  static MebiusQuality? _tryFromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final id = json['id'];
    final height = json['height'];
    final bitrate = json['bitrateKbps'];
    final path = json['path'];
    if (id is! String || height is! num || path is! String) {
      return null;
    }
    if (!_resolvable(path)) {
      return null;
    }
    return MebiusQuality(
      id: id,
      height: height.toInt(),
      bitrateKbps: bitrate is num ? bitrate.toInt() : 0,
      path: path,
    );
  }

  /// Stable id to pass to `MebiusPlayer.setQuality`, e.g. `"720p"`. Safe to
  /// show as a label.
  final String id;

  /// Frame height in pixels.
  final int height;

  /// Nominal video bitrate in kbps; 0 when the gateway did not say.
  final int bitrateKbps;

  /// Mebius-relative path of this rung. Opaque to your app.
  final String path;

  @override
  bool operator ==(Object other) =>
      other is MebiusQuality &&
      other.id == id &&
      other.height == height &&
      other.bitrateKbps == bitrateKbps &&
      other.path == path;

  @override
  int get hashCode => Object.hash(id, height, bitrateKbps, path);

  @override
  String toString() => 'MebiusQuality($id, ${height}p, $bitrateKbps kbps)';
}
