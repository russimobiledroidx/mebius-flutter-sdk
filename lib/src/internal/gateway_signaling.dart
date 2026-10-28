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

import 'dart:async';

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

/// Upper bound on one gateway request on the open path: the route probe and
/// the real-time SDP exchange.
///
/// Without it an edge that accepts the connection and never answers held the
/// viewer on "connecting" forever: no error, so no next route. 15 s is well
/// past a cold edge's slowest observed answer (~6 s).
const Duration kGatewayRequestTimeout = Duration(seconds: 15);

/// Upper bound on the best-effort DELETE that ends a session.
const Duration kDeleteTimeout = Duration(seconds: 3);

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
    final response = await _send(
      'POST',
      url,
      headers: {'Content-Type': 'application/sdp'},
      body: offerSdp,
      read: http.Response.fromStream,
      // A late answer still created a session on the gateway; release it.
      onLate: (late) {
        final location = late.headers['location'];
        if (location != null) {
          unawaited(deleteResource(_resolve(location)));
        }
      },
    );
    _throwForStatus(response.statusCode);
    final location = response.headers['location'];
    return SdpExchangeResult(
      answerSdp: response.body,
      resourceUrl: location == null ? null : _resolve(location),
    );
  }

  /// One gateway request on the open path, bounded by
  /// [kGatewayRequestTimeout] including [read] of its response.
  ///
  /// On timeout the request is aborted, so the socket closes, and the caller
  /// gets `connectionFailed`. If the response had already arrived, [onLate]
  /// sees it and its body is cancelled. Any failure to build or send the
  /// request, a malformed URL included, is `connectionFailed` too.
  Future<T> _send<T>(
    String method,
    String url, {
    required Future<T> Function(http.StreamedResponse) read,
    Map<String, String> headers = const {},
    String? body,
    void Function(http.StreamedResponse late)? onLate,
  }) async {
    final abort = Completer<void>();
    Future<http.StreamedResponse>? sent;
    try {
      final request = http.AbortableRequest(
        method,
        Uri.parse(url),
        abortTrigger: abort.future,
      )
        ..headers.addAll(_authHeaders)
        ..headers.addAll(headers);
      if (body != null) {
        request.body = body;
      }
      sent = _http.send(request);
      return await sent.then(read).timeout(kGatewayRequestTimeout);
    } on TimeoutException catch (e) {
      abort.complete();
      unawaited(
        sent!.then<void>(
          (late) {
            onLate?.call(late);
            // The abort closes it on clients that support aborting; this
            // closes it on the rest. [read] may already be listening.
            try {
              unawaited(late.stream.listen(null, onError: (_) {}).cancel());
            } on Object catch (_) {
              // Already listened to by [read]; the abort covers it.
            }
          },
          onError: (Object _) {},
        ),
      );
      throw MebiusError(
        MebiusErrorCode.connectionFailed,
        'The Mebius gateway did not answer in time.',
        cause: e,
      );
    } catch (e) {
      throw MebiusError(
        MebiusErrorCode.connectionFailed,
        'Could not reach the Mebius gateway.',
        cause: e,
      );
    }
  }

  /// Tears down a previously created session resource.
  ///
  /// Bounded by [kDeleteTimeout]: a stop must not hang on a dead network,
  /// and the gateway reaps an abandoned session on its own.
  Future<void> deleteResource(String resourceUrl) async {
    try {
      await _http
          .delete(Uri.parse(resourceUrl), headers: _authHeaders)
          .timeout(kDeleteTimeout);
    } on Object {
      // Best-effort teardown; ignore failures during cleanup.
    }
  }

  /// Verifies that the configured stream playlist is reachable for scale mode.
  Future<void> ensureScaleReachable(String streamId, [String? url]) async {
    final status = await _send(
      'GET',
      url ?? scalePlaylistUrl(streamId),
      // Only the status line matters. A live FLV route never ends its body,
      // so reading it (as a plain GET does) would hang the probe forever;
      // cancelling the body closes the connection after the headers.
      read: (response) async {
        unawaited(response.stream.listen(null, onError: (_) {}).cancel());
        return response.statusCode;
      },
    );
    _throwForStatus(status);
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
