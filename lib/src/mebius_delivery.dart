/// One playback route Mebius has prepared for a stream.
///
/// Your backend receives this list alongside the access token; hand it to
/// `Mebius.connect` untouched. Both fields are opaque: [kind] is a Mebius
/// intent label, not a media format, and [path] is resolved by Mebius against
/// its own gateway. Treating either as a format or a URL will break the moment
/// Mebius changes how a route is served — which is the point of the list.
class MebiusDelivery {
  /// Creates a delivery route descriptor.
  const MebiusDelivery({required this.kind, required this.path});

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
    return MebiusDelivery(kind: kind, path: path);
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

  /// Whether this route is safe to resolve against the Mebius gateway.
  ///
  /// The access token is a bearer credential, and a delivery path arrives as
  /// data in a response. An absolute or protocol-relative path would send that
  /// token to a host Mebius did not choose, so those are rejected outright
  /// rather than fetched.
  bool get isResolvable =>
      path.startsWith('/') && !path.startsWith('//') && !path.contains('://');

  @override
  String toString() => 'MebiusDelivery(kind: $kind, path: $path)';
}
