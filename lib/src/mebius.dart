import 'package:mebius/src/mebius_client.dart';
import 'package:mebius/src/mebius_delivery.dart';
import 'package:mebius/src/mebius_error.dart';
import 'package:mebius/src/mebius_events.dart';

/// The entry point to the Mebius SDK.
///
/// Configure the SDK once at app startup with [Mebius.init], then open an
/// authenticated session with [Mebius.connect].
///
/// ```dart
/// Mebius.init(
///   appId: 'your-app-id',
///   gateway: 'https://gateway.mebius.example',
/// );
/// final client = Mebius.connect(token: tokenFromBackend);
/// ```
abstract final class Mebius {
  static String? _appId;
  static String? _gateway;

  /// The configured application identifier, or `null` before [init].
  static String? get appId => _appId;

  /// The configured gateway endpoint, or `null` before [init].
  static String? get gateway => _gateway;

  /// Whether [init] has been called.
  static bool get isInitialized => _appId != null && _gateway != null;

  /// Configures the SDK.
  ///
  /// * [appId] — your Mebius application identifier.
  /// * [gateway] — the Mebius signaling endpoint your account was issued
  ///   (for example `https://gateway.mebius.example`).
  ///
  /// Call this once, typically in `main()` before `runApp`.
  static void init({required String appId, required String gateway}) {
    if (appId.isEmpty) {
      throw const MebiusError(
        MebiusErrorCode.unknown,
        'Mebius.init requires a non-empty appId.',
      );
    }
    if (gateway.isEmpty) {
      throw const MebiusError(
        MebiusErrorCode.unknown,
        'Mebius.init requires a non-empty gateway endpoint.',
      );
    }
    _appId = appId;
    _gateway = gateway;
  }

  /// Opens an authenticated session and returns a [MebiusClient].
  ///
  /// [token] is a short-lived JWT minted by your backend from your
  /// `appId` + `appSecret`. The client never holds your app secret. When the
  /// token expires, the client emits an `error` event with
  /// [MebiusErrorCode.tokenExpired]; refresh the token and reconnect.
  ///
  /// Throws a [MebiusError] with [MebiusErrorCode.unknown] if [init] has not
  /// been called.
  /// [deliveries] is the list your backend returned with the token. Pass it
  /// through as-is: Mebius orders it and picks from it. Optional — without it
  /// playback still works, but every viewer is served from Mebius origin rather
  /// than the nearest edge, which on mobile is billed per viewer.
  ///
  /// [getToken] makes the session outlive one token. Give it a function that
  /// mints a fresh token from your backend and Mebius calls it shortly BEFORE
  /// `exp`, swapping the credential in place — no reconnect, no renegotiation,
  /// no visible gap. A failing provider is retried with backoff for as long as
  /// the current token is still valid, so `TOKEN_EXPIRED` is reported only when
  /// the credential has genuinely run out. Each successful renewal emits
  /// [MebiusClientEventType.tokenRefreshed].
  ///
  /// Without [getToken] nothing changes: no renewal is scheduled and an expired
  /// token surfaces exactly when and how it always did. That matters most to a
  /// camera publisher — a match longer than the token's life is the difference
  /// between a seamless broadcast and a visible reconnect.
  static MebiusClient connect({
    required String token,
    List<MebiusDelivery> deliveries = const <MebiusDelivery>[],
    Future<String> Function()? getToken,
  }) {
    if (!isInitialized) {
      throw const MebiusError(
        MebiusErrorCode.unknown,
        'Mebius.init must be called before Mebius.connect.',
      );
    }
    if (token.isEmpty) {
      throw const MebiusError(
        MebiusErrorCode.tokenExpired,
        'A connection token is required. Mint one from your backend.',
      );
    }
    return MebiusClient.internal(
      gateway: _gateway!,
      token: token,
      deliveries: deliveries,
      getToken: getToken,
    );
  }

  /// Resets SDK configuration. Intended for tests.
  static void resetForTesting() {
    _appId = null;
    _gateway = null;
  }
}
