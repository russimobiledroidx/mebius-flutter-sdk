// INTERNAL — not part of the public Mebius surface.
//
// Reads (never VERIFIES) a Mebius access token. The token is a short-lived JWT
// minted by the application backend; only the gateway holds the secret, so the
// client can do nothing but peek at the payload. Two fields matter here:
//
//   * `exp`      — when to renew, so a session can outlive one credential.
//   * `streamId` — what the credential is for, so swapping in a token minted
//                  for a different stream fails loudly instead of quietly
//                  breaking the session on the next request.
//
// Anything unreadable yields null. A malformed token is the gateway's problem
// to reject, and guessing here would turn a clear 401 into a client-side
// mystery.

// Internal implementation detail; not part of the documented public surface.
// ignore_for_file: public_member_api_docs

import 'dart:convert';

/// What the client can learn from an access token without verifying it.
class TokenInfo {
  const TokenInfo({this.expiresAt, this.streamId});

  /// Expiry, or null when the token carries no readable `exp`.
  final DateTime? expiresAt;

  /// The stream this token is scoped to, or null when unreadable.
  final String? streamId;
}

/// Decodes the payload of [token]. Never throws.
TokenInfo readToken(String token) {
  final parts = token.split('.');
  if (parts.length < 2) {
    return const TokenInfo();
  }
  try {
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    if (payload is! Map<String, dynamic>) {
      return const TokenInfo();
    }
    final exp = payload['exp'];
    final streamId = payload['streamId'];
    return TokenInfo(
      expiresAt: exp is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (exp * 1000).round(),
              isUtc: true,
            )
          : null,
      streamId: streamId is String && streamId.isNotEmpty ? streamId : null,
    );
  } on Object {
    return const TokenInfo();
  }
}
