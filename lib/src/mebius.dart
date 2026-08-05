import 'package:mebius/src/mebius_client.dart';
import 'package:mebius/src/mebius_delivery.dart';
import 'package:mebius/src/mebius_error.dart';

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
  static MebiusClient connect({
    required String token,
    List<MebiusDelivery> deliveries = const <MebiusDelivery>[],
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
    );
  }

  /// Resets SDK configuration. Intended for tests.
  static void resetForTesting() {
    _appId = null;
    _gateway = null;
  }
}
