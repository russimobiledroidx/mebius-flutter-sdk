/// Stable, platform-independent error codes surfaced by the Mebius SDK.
///
/// These codes are identical across every Mebius client SDK
/// (Dart/Swift/Kotlin/TS), so application code can switch on them portably.
enum MebiusErrorCode {
  /// The supplied connection token has expired. The application should mint a
  /// fresh short-lived token from its backend and reconnect.
  tokenExpired,

  /// A required runtime permission (camera and/or microphone) was denied by
  /// the user or the operating system.
  permissionDenied,

  /// The SDK could not establish or maintain a connection to the Mebius
  /// gateway.
  connectionFailed,

  /// An operation was attempted that requires an active connection, but the
  /// client is not currently connected.
  notConnected,

  /// The requested stream could not be found on the Mebius gateway.
  streamNotFound,

  /// An unexpected error occurred that does not map to a more specific code.
  unknown,
}

/// Returns the canonical wire string for [code] (e.g. `TOKEN_EXPIRED`).
String mebiusErrorCodeName(MebiusErrorCode code) {
  switch (code) {
    case MebiusErrorCode.tokenExpired:
      return 'TOKEN_EXPIRED';
    case MebiusErrorCode.permissionDenied:
      return 'PERMISSION_DENIED';
    case MebiusErrorCode.connectionFailed:
      return 'CONNECTION_FAILED';
    case MebiusErrorCode.notConnected:
      return 'NOT_CONNECTED';
    case MebiusErrorCode.streamNotFound:
      return 'STREAM_NOT_FOUND';
    case MebiusErrorCode.unknown:
      return 'UNKNOWN';
  }
}

/// The error type thrown and emitted by the Mebius SDK.
///
/// Every failure raised by the SDK — whether thrown synchronously, returned
/// from a `Future`, or delivered through an `error` event — is a
/// [MebiusError]. Inspect [code] to react programmatically and [message] for a
/// human-readable description.
class MebiusError implements Exception {
  /// Creates a [MebiusError] with the given [code], [message] and optional
  /// underlying [cause].
  const MebiusError(this.code, this.message, {this.cause});

  /// Creates a [MebiusError] from an arbitrary thrown [error], mapping it to
  /// [MebiusErrorCode.unknown] when it is not already a [MebiusError].
  factory MebiusError.from(Object error, {MebiusErrorCode? code}) {
    if (error is MebiusError) {
      return error;
    }
    return MebiusError(
      code ?? MebiusErrorCode.unknown,
      error.toString(),
      cause: error,
    );
  }

  /// The stable error code for this failure.
  final MebiusErrorCode code;

  /// A human-readable description of the failure, phrased in Mebius terms.
  final String message;

  /// The underlying object that triggered this error, if any.
  final Object? cause;

  /// The canonical wire string for [code] (e.g. `TOKEN_EXPIRED`).
  String get codeName => mebiusErrorCodeName(code);

  @override
  String toString() => 'MebiusError($codeName): $message';
}
