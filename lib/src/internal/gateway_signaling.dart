// INTERNAL — not part of the public Mebius surface.
//
// This file is the ONLY place (together with the rest of lib/src/internal/)
// where raw transport protocol terms are permitted. The public API hides all
// of these behind Mebius vocabulary.
//
// Gateway HTTP contract (all relative to the configured `gateway` base URL).
// The engine validates the access token from the `?token=` QUERY parameter:
//   * Publish (broadcaster.start): POST {gateway}/whip/{streamId}?token={jwt}
//       - Body: the local SDP offer, Content-Type: application/sdp
//       - Response: 201 Created, body = remote SDP answer (application/sdp),
//         Location header = resource URL used to tear the session down.
//   * Low-latency play (player low-latency): POST {gateway}/whep/{streamId}?token={jwt}
//       - Same SDP exchange as the publish path above.
//   * Scale play (player scale): GET {gateway}/live/{streamId}/index.m3u8?token={jwt}
//       - Returns the HLS playlist the native video pipeline consumes; segment
//         URIs inside inherit ?token= automatically (engine rewrites them).
//
// None of these path segments or protocol names ever leak to the public API.

// Internal implementation detail; not part of the documented public surface.
// ignore_for_file: public_member_api_docs

import 'package:http/http.dart' as http;
import 'package:mebius/src/mebius_error.dart';

/// Result of a successful SDP exchange with the gateway.
class SdpExchangeResult {
  SdpExchangeResult({required this.answerSdp, required this.resourceUrl});

  /// The remote SDP answer returned by the gateway.
  final String answerSdp;

  /// The resource URL (Location header) used to delete the session.
  final String? resourceUrl;
}

/// Thin HTTP signaling client that talks to the Mebius gateway.
///
/// Translates raw transport responses into [MebiusError]s using Mebius
/// vocabulary so the public layer never sees protocol terms.
class GatewaySignaling {
  GatewaySignaling({
    required this.gateway,
    required this.token,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  /// Base signaling endpoint of the Mebius gateway.
  final String gateway;

  /// Short-lived bearer token minted by the application backend.
  ///
  /// Mutable, and read at the moment each request is built rather than captured
  /// once. That is what lets a session outlive the credential it opened with:
  /// the engine checks the token on every media request, so the segmented
  /// playback route stops the instant the original one expires — however
  /// healthy the stream is. Replacing it in place renews nothing else: no
  /// renegotiation, no new tracks, no interruption.
  String token;

  final http.Client _http;

  String get _base => gateway.endsWith('/')
      ? gateway.substring(0, gateway.length - 1)
      : gateway;

  Map<String, String> get _authHeaders => {
        'Authorization': 'Bearer $token',
      };

  // Appends the access token as a query parameter. The engine validates the
  // token from the `?token=` query (its auth hook + playback gate read the
  // query, not the header); the Bearer header is kept only as a courtesy for
  // gateways that prefer it.
  String _withToken(String url) {
    final sep = url.contains('?') ? '&' : '?';
    return '$url${sep}token=${Uri.encodeQueryComponent(token)}';
  }

  /// Performs the WHIP SDP exchange to begin publishing [streamId].
  Future<SdpExchangeResult> publishOffer(
    String streamId,
    String offerSdp,
  ) {
    return _sdpExchange(
      _withToken('$_base/whip/${Uri.encodeComponent(streamId)}'),
      offerSdp,
    );
  }

  /// Performs the WHEP SDP exchange to begin low-latency playback of
  /// [streamId].
  Future<SdpExchangeResult> playOffer(
    String streamId,
    String offerSdp,
  ) {
    return _sdpExchange(
      _withToken('$_base/whep/${Uri.encodeComponent(streamId)}'),
      offerSdp,
    );
  }

  /// Returns the tokenized URL for a gateway-relative delivery path.
  ///
  /// Only used for paths the gateway itself handed us; the caller must have
  /// checked `MebiusDelivery.isResolvable` first, so an absolute path never
  /// reaches this method and the token cannot be sent to another host.
  String deliveryUrl(String path) => _withToken('$_base$path');

  /// Returns the HLS playlist URL used by the scale playback pipeline.
  ///
  /// The engine serves the playlist under `/live/{id}/index.m3u8` and requires
  /// the token in the query; segment URIs inside the playlist inherit it
  /// automatically (the engine rewrites the manifest).
  String scalePlaylistUrl(String streamId) {
    return _withToken('$_base/live/${Uri.encodeComponent(streamId)}/index.m3u8');
  }

  Future<SdpExchangeResult> _sdpExchange(String url, String offerSdp) async {
    http.Response response;
    try {
      response = await _http.post(
        Uri.parse(url),
        headers: {
          ..._authHeaders,
          'Content-Type': 'application/sdp',
        },
        body: offerSdp,
      );
    } catch (e) {
      throw MebiusError(
        MebiusErrorCode.connectionFailed,
        'Could not reach the Mebius gateway.',
        cause: e,
      );
    }
    _throwForStatus(response.statusCode);
    final location = response.headers['location'];
    return SdpExchangeResult(
      answerSdp: response.body,
      resourceUrl: location == null ? null : _resolve(location),
    );
  }

  /// Tears down a previously created session resource.
  Future<void> deleteResource(String resourceUrl) async {
    try {
      await _http.delete(Uri.parse(resourceUrl), headers: _authHeaders);
    } on Object {
      // Best-effort teardown; ignore failures during cleanup.
    }
  }

  /// Verifies that the configured stream playlist is reachable for scale mode.
  Future<void> ensureScaleReachable(String streamId, [String? url]) async {
    http.Response response;
    try {
      response = await _http.get(
        Uri.parse(url ?? scalePlaylistUrl(streamId)),
        headers: _authHeaders,
      );
    } catch (e) {
      throw MebiusError(
        MebiusErrorCode.connectionFailed,
        'Could not reach the Mebius gateway.',
        cause: e,
      );
    }
    _throwForStatus(response.statusCode);
  }

  String _resolve(String location) {
    final uri = Uri.parse(location);
    if (uri.hasScheme) {
      return location;
    }
    return '$_base${location.startsWith('/') ? '' : '/'}$location';
  }

  void _throwForStatus(int status) {
    if (status >= 200 && status < 300) {
      return;
    }
    switch (status) {
      case 401:
      case 403:
        throw const MebiusError(
          MebiusErrorCode.tokenExpired,
          'The connection token was rejected. Refresh the token and '
          'reconnect.',
        );
      case 404:
        throw const MebiusError(
          MebiusErrorCode.streamNotFound,
          'The requested stream could not be found.',
        );
      default:
        throw MebiusError(
          MebiusErrorCode.connectionFailed,
          'The Mebius gateway returned an unexpected response ($status).',
        );
    }
  }

  /// Releases held resources.
  void dispose() => _http.close();
}
