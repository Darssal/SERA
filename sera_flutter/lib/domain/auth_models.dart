import 'models.dart';

class AuthUser {
  const AuthUser({
    required this.id,
    required this.username,
    required this.email,
    this.emailVerified = false,
    this.phone,
    this.hasPassword = true,
  });
  final String id, username, email;
  final bool emailVerified;
  final String? phone;
  final bool hasPassword;
  factory AuthUser.fromJson(Json j) => AuthUser(
    id: j['id'] as String,
    username: j['username'] as String,
    email: j['email'] as String? ?? '',
    emailVerified: j['emailVerified'] == true,
    phone: j['phone'] as String?,
    hasPassword: j['hasPassword'] != false,
  );
  Json toJson() => {
    'id': id,
    'username': username,
    'email': email,
    'emailVerified': emailVerified,
    'phone': phone,
    'hasPassword': hasPassword,
  };
}

class AuthSession {
  const AuthSession({
    required this.token,
    required this.expiresAt,
    required this.user,
    this.csrfToken = '',
    this.cookieSession = false,
    String sessionId = '',
    this.onlineVerified = true,
    // Keep the public sessionId argument while storing its optional raw value.
    // ignore: prefer_initializing_formals
  }) : _sessionId = sessionId;
  final String token;
  final String csrfToken, _sessionId;
  String get sessionId => _sessionId.isNotEmpty
      ? _sessionId
      : '${user.id}:${expiresAt.toUtc().toIso8601String()}';
  final bool cookieSession, onlineVerified;
  String get identity => user.id;
  final DateTime expiresAt;
  final AuthUser user;
  factory AuthSession.fromJson(Json j) => AuthSession(
    token: j['token'] as String? ?? '',
    csrfToken: j['csrfToken'] as String? ?? '',
    cookieSession: j['cookieSession'] == true,
    sessionId:
        j['sessionId'] as String? ??
        '${(j['user'] as Map)['id']}:${j['expiresAt']}',
    onlineVerified: j['onlineVerified'] != false,
    expiresAt: DateTime.parse(j['expiresAt'] as String),
    user: AuthUser.fromJson(Map<String, dynamic>.from(j['user'] as Map)),
  );
  Json toJson() => {
    'token': token,
    'csrfToken': csrfToken,
    'cookieSession': cookieSession,
    'sessionId': sessionId,
    'onlineVerified': onlineVerified,
    'expiresAt': expiresAt.toIso8601String(),
    'user': user.toJson(),
  };
}
