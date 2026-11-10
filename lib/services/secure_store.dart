import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The only place secrets live: the Cloudflare API token, the Worker VLESS
/// UUID and the WARP account (private key included).
///
/// Nothing here ever goes into SharedPreferences, a log line, a config file
/// or git. The values are read back only when they are needed for a deploy
/// or a connection, and the Cloudflare token is wiped when the user removes
/// the Worker account.
class SecureStore {
  SecureStore._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static const _cfTokenKey = 'voidrau_cf_token';
  static const _workerUuidKey = 'voidrau_worker_uuid';
  static const _warpAccountKey = 'voidrau_warp_account';

  static Future<void> saveCloudflareToken(String token) =>
      _storage.write(key: _cfTokenKey, value: token);

  static Future<String?> readCloudflareToken() =>
      _storage.read(key: _cfTokenKey);

  static Future<void> deleteCloudflareToken() =>
      _storage.delete(key: _cfTokenKey);

  static Future<void> saveWorkerUuid(String uuid) =>
      _storage.write(key: _workerUuidKey, value: uuid);

  static Future<String?> readWorkerUuid() => _storage.read(key: _workerUuidKey);

  static Future<void> deleteWorkerUuid() => _storage.delete(key: _workerUuidKey);

  /// The WARP account as JSON (see WarpAccount.toJson).
  static Future<void> saveWarpAccount(String json) =>
      _storage.write(key: _warpAccountKey, value: json);

  static Future<String?> readWarpAccount() =>
      _storage.read(key: _warpAccountKey);

  static Future<void> deleteWarpAccount() =>
      _storage.delete(key: _warpAccountKey);

  /// Wipes every Xray secret (token, UUID, WARP account) at once.
  static Future<void> clearXraySecrets() => Future.wait([
        deleteCloudflareToken(),
        deleteWorkerUuid(),
        deleteWarpAccount(),
      ]);
}
