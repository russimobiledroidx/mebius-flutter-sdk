import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// What enrolling a device yields: its id and the secret it authenticates
/// with. The secret is shown once by the engine and never again.
class MebiusDeviceCredentials {
  /// Creates credentials for [deviceId] (`dev_…`) with [deviceSecret] (`dsk_…`).
  const MebiusDeviceCredentials({
    required this.deviceId,
    required this.deviceSecret,
  });

  /// The device id, `dev_…`.
  final String deviceId;

  /// The device secret, `dsk_…`. Never log it or write it to a plain file.
  final String deviceSecret;
}

/// Where an agent keeps its device credentials between runs.
abstract interface class MebiusCredentialStore {
  /// The stored credentials, or null when the device is not enrolled.
  Future<MebiusDeviceCredentials?> read();

  /// Replaces the stored credentials.
  Future<void> write(MebiusDeviceCredentials credentials);

  /// Forgets the stored credentials.
  Future<void> clear();
}

/// Keeps credentials in the OS keychain: Keychain on macOS, DPAPI-protected
/// storage on Windows (via `flutter_secure_storage`).
class MebiusSecureCredentialStore implements MebiusCredentialStore {
  /// Creates a store under [key]; change it only to keep two agents apart.
  MebiusSecureCredentialStore({
    this.key = 'io.mebius.screen.device',
    FlutterSecureStorage? storage,
  }) : _storage = storage ??
            const FlutterSecureStorage(
              // The login keychain. The data-protection keychain needs a
              // keychain-access-groups entitlement, i.e. a signing team, which
              // a fresh agent build does not have.
              mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            );

  /// The storage key the credentials live under.
  final String key;

  final FlutterSecureStorage _storage;

  @override
  Future<MebiusDeviceCredentials?> read() async {
    final raw = await _storage.read(key: key);
    if (raw == null) {
      return null;
    }
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return MebiusDeviceCredentials(
        deviceId: m['deviceId'] as String,
        deviceSecret: m['deviceSecret'] as String,
      );
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(MebiusDeviceCredentials credentials) => _storage.write(
        key: key,
        value: jsonEncode({
          'deviceId': credentials.deviceId,
          'deviceSecret': credentials.deviceSecret,
        }),
      );

  @override
  Future<void> clear() => _storage.delete(key: key);
}
