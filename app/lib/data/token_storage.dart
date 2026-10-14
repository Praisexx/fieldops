import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class Session {
  const Session({required this.accessToken, required this.refreshToken, required this.userId, required this.name, required this.email});
  final String accessToken;
  final String refreshToken;
  final String userId;
  final String name;
  final String email;

  Session withTokens(String access, String refresh) =>
      Session(accessToken: access, refreshToken: refresh, userId: userId, name: name, email: email);

  /// Access-token expiry read from the JWT payload; null if unparsable (then we just rely on 401 handling).
  DateTime? get accessExpiry {
    try {
      final payload = accessToken.split('.')[1];
      final json = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(payload)))) as Map;
      return DateTime.fromMillisecondsSinceEpoch((json['exp'] as int) * 1000);
    } catch (_) {
      return null;
    }
  }
}

abstract class TokenStorage {
  Future<Session?> read();
  Future<void> write(Session s);
  Future<void> clear();
}

/// Tokens live in the Android Keystore-backed secure storage, never in plain prefs or SQLite.
class SecureTokenStorage implements TokenStorage {
  SecureTokenStorage([FlutterSecureStorage? s]) : _s = s ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  static const _key = 'session';

  @override
  Future<Session?> read() async {
    final raw = await _s.read(key: _key);
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map;
      return Session(
        accessToken: j['a'] as String,
        refreshToken: j['r'] as String,
        userId: j['u'] as String,
        name: j['n'] as String,
        email: j['e'] as String,
      );
    } catch (_) {
      await clear();
      return null;
    }
  }

  @override
  Future<void> write(Session s) => _s.write(
        key: _key,
        value: jsonEncode({'a': s.accessToken, 'r': s.refreshToken, 'u': s.userId, 'n': s.name, 'e': s.email}),
      );

  @override
  Future<void> clear() => _s.delete(key: _key);
}

class MemoryTokenStorage implements TokenStorage {
  Session? value;
  @override
  Future<Session?> read() async => value;
  @override
  Future<void> write(Session s) async => value = s;
  @override
  Future<void> clear() async => value = null;
}
