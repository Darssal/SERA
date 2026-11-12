import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class AuthSessionStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PreferencesSessionStorage implements AuthSessionStorage {
  PreferencesSessionStorage(this.preferences);
  final SharedPreferencesAsync preferences;
  @override
  Future<String?> read(String key) => preferences.getString(key);
  @override
  Future<void> write(String key, String value) =>
      preferences.setString(key, value);
  @override
  Future<void> delete(String key) => preferences.remove(key);
}

class SecureSessionStorage implements AuthSessionStorage {
  const SecureSessionStorage();
  static const storage = FlutterSecureStorage();
  @override
  Future<String?> read(String key) => storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => storage.delete(key: key);
}

AuthSessionStorage defaultAuthStorage() => kIsWeb
    ? PreferencesSessionStorage(SharedPreferencesAsync())
    : const SecureSessionStorage();
