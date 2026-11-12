import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/auth_models.dart';
import '../domain/models.dart';
import 'workspace_repository.dart';
import 'auth_storage.dart';
import 'account_event_channel.dart';
import 'auth_dio_native.dart'
    if (dart.library.js_interop) 'auth_dio_web.dart'
    as credentials;
export '../domain/auth_models.dart';
export 'auth_storage.dart';
export 'account_event_channel.dart';

const _bindingKey = 'sera.auth.bound-session';

String _emailActionToken(String input, String expectedPath) {
  final value = input.trim();
  if (!value.contains('://')) return value;
  try {
    final uri = Uri.parse(value);
    final action = Uri.parse(uri.fragment);
    final tokens = action.queryParametersAll['token'];
    if (const ['http', 'https'].contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        action.path == expectedPath &&
        tokens != null &&
        tokens.length == 1 &&
        tokens.single.isNotEmpty) {
      return tokens.single;
    }
  } on FormatException {
    // Keep malformed or wrong-purpose links out of the confirmation request.
  }
  throw const RepositoryException('请粘贴此操作对应的完整邮件链接或有效凭证。');
}

/// Delivery reports describe what the server actually accepted. A local spool
/// is intentionally distinct from an SMTP server accepting an email.
class AuthMailDelivery {
  const AuthMailDelivery({
    required this.mode,
    required this.status,
    required this.message,
    required this.developmentPreview,
  });
  final String mode, status, message;
  final bool developmentPreview;
  bool get isLocal => mode == 'local';

  factory AuthMailDelivery.fromJson(Json body) {
    final mode = body['deliveryMode'] ?? body['delivery'];
    final status = body['deliveryStatus'];
    final message = body['message'];
    if (!const ['local', 'mailpit', 'smtp'].contains(mode) ||
        status is! String ||
        status.isEmpty ||
        message is! String ||
        message.trim().isEmpty) {
      throw const RepositoryException('邮件服务未返回有效的投递状态，请重试。');
    }
    return AuthMailDelivery(
      mode: mode as String,
      status: status,
      message: message,
      developmentPreview: mode == 'local' && body['developmentPreview'] == true,
    );
  }
}

class DevelopmentVerificationMail {
  const DevelopmentVerificationMail({
    required this.subject,
    required this.verificationUrl,
    required this.token,
    required this.expiresAt,
  });
  final String subject, verificationUrl, token;
  final DateTime expiresAt;

  factory DevelopmentVerificationMail.fromJson(Json body) {
    final url = body['verificationUrl'];
    final uri = url is String ? Uri.tryParse(url) : null;
    final route = uri == null ? null : Uri.tryParse(uri.fragment);
    final token = route?.queryParameters['token'];
    final expiresAt = body['expiresAt'] is String
        ? DateTime.tryParse(body['expiresAt'] as String)
        : null;
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        route?.path != '/verify-email' ||
        token == null ||
        token.isEmpty ||
        expiresAt == null ||
        body['subject'] is! String) {
      throw const RepositoryException('开发邮件格式无效，请重新发送验证邮件。');
    }
    return DevelopmentVerificationMail(
      subject: body['subject'] as String,
      verificationUrl: url as String,
      token: token,
      expiresAt: expiresAt,
    );
  }
}

class DevelopmentVerificationMailbox {
  const DevelopmentVerificationMailbox({required this.message, this.mail});
  final String message;
  final DevelopmentVerificationMail? mail;
  factory DevelopmentVerificationMailbox.fromJson(Json body) {
    if (body['deliveryMode'] != 'local' ||
        body['message'] is! String ||
        (body['mail'] != null && body['mail'] is! Map)) {
      throw const RepositoryException('开发邮箱响应无效，请重试。');
    }
    return DevelopmentVerificationMailbox(
      message: body['message'] as String,
      mail: body['mail'] == null
          ? null
          : DevelopmentVerificationMail.fromJson(
              Map<String, dynamic>.from(body['mail'] as Map),
            ),
    );
  }
}

class _AuthBinding {
  const _AuthBinding(this.repository, this.owner);
  final AuthRepository repository;
  final Object owner;
}

void configureAuthDio(Dio client, {String? Function()? csrfProvider}) {
  credentials.configureCredentials(client);
  client.options.headers['X-Sera-Client'] = kIsWeb ? 'web' : 'native';
  client.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final csrf = options.extra[_bindingKey] is _AuthBinding
            ? null
            : csrfProvider?.call();
        if (csrf != null &&
            csrf.isNotEmpty &&
            !options.headers.containsKey('X-CSRF-Token')) {
          options.headers['X-CSRF-Token'] = csrf;
        }
        handler.next(options);
      },
    ),
  );
}

class AuthRepository extends ChangeNotifier {
  AuthRepository({
    required this.apiBaseUrl,
    Dio? client,
    SharedPreferencesAsync? preferences,
    AuthSessionStorage? storage,
    AccountEventChannel? accountEvents,
    this.onPeerAccountChange,
  }) : _client =
           client ??
           Dio(
             BaseOptions(
               baseUrl: apiBaseUrl.replaceFirst(RegExp(r'/+$'), ''),
               connectTimeout: const Duration(seconds: 8),
               receiveTimeout: const Duration(seconds: 65),
             ),
           ),
       _accountEvents = accountEvents ?? createAccountEventChannel(),
       _storage =
           storage ??
           (preferences == null
               ? defaultAuthStorage()
               : PreferencesSessionStorage(preferences)) {
    configureAuthDio(_client, csrfProvider: () => csrfToken);
    _client.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final binding = options.extra[_bindingKey];
          if (binding is _AuthBinding &&
              identical(binding.repository, this) &&
              binding.owner != _owner) {
            handler.reject(_staleRequest(options));
          } else {
            handler.next(options);
          }
        },
        onResponse: (response, handler) {
          final binding = response.requestOptions.extra[_bindingKey];
          if (binding is _AuthBinding &&
              identical(binding.repository, this) &&
              binding.owner != _owner) {
            handler.reject(_staleRequest(response.requestOptions));
          } else {
            handler.next(response);
          }
        },
      ),
    );
    _accountSubscription = _accountEvents.events.listen(_onAccountEvent);
  }
  final String apiBaseUrl;
  final Dio _client;
  final AuthSessionStorage _storage;
  final AccountEventChannel _accountEvents;
  late final StreamSubscription<AccountEvent> _accountSubscription;
  final VoidCallback? onPeerAccountChange;
  bool _disposed = false;
  Future<void> _sessionPersistenceTail = Future<void>.value();
  Future<T> _persistSession<T>(Future<T> Function() action) {
    final next = _sessionPersistenceTail.then((_) => action());
    _sessionPersistenceTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  bool _followingPeer = false;
  AuthSession? session;
  int _sessionEpoch = 0;
  Object get _owner => (
    _sessionEpoch,
    session?.user.id,
    session?.sessionId,
    session?.token,
    session?.csrfToken,
  );
  DioException _staleRequest(RequestOptions options) => DioException(
    requestOptions: options,
    type: DioExceptionType.cancel,
    error: const RepositoryException('账号会话已变化，原操作已停止。'),
  );
  String? deletedUserId;
  String? lastSessionExitReason;
  String? logoutWarning;
  CancelToken? _transcriptionCancel;
  void cancelTranscription() {
    _transcriptionCancel?.cancel('User cancelled transcription');
  }

  Future<void> invalidateSession() async {
    final boundOwner = _owner;
    final cookie = session?.cookieSession == true;
    final removed = await _deleteMatchingSession(session, boundOwner);
    if (boundOwner != _owner) return;
    if (!removed && cookie) {
      _onAccountEvent(AccountEvent(apiBaseUrl: apiBaseUrl, loggedIn: true));
      return;
    }
    session = null;
    _sessionEpoch++;
    _followingPeer = false;
    loading = false;
    notifyListeners();
  }

  bool loading = false;
  String? error;
  bool get signedIn =>
      session != null && session!.expiresAt.isAfter(DateTime.now());
  String? get token =>
      signedIn && !session!.cookieSession ? session!.token : null;
  String get csrfToken => session?.csrfToken ?? '';
  bool get onlineVerified => session?.onlineVerified ?? false;
  bool get followingPeerAccount => _followingPeer;

  /// Opaque generation used by independent identity flows to reject late work.
  Object get sessionOwner => _owner;
  String get _storageKey => 'sera.auth.session.$apiBaseUrl';
  bool _owns(Object owner) => !_disposed && owner == _owner;

  void _publishAccount(bool loggedIn) {
    if (!_disposed) {
      _accountEvents.publish(
        AccountEvent(
          apiBaseUrl: apiBaseUrl.replaceFirst(RegExp(r'/+$'), ''),
          loggedIn: loggedIn,
        ),
      );
    }
  }

  void _onAccountEvent(AccountEvent event) {
    if (_disposed ||
        event.apiBaseUrl.replaceFirst(RegExp(r'/+$'), '') !=
            apiBaseUrl.replaceFirst(RegExp(r'/+$'), '')) {
      return;
    }
    cancelTranscription();
    onPeerAccountChange?.call();
    // Do not emit an intermediate signed-out scope: a peer may already have
    // bound the shared Service Worker to the new account.
    session = null;
    _sessionEpoch++;
    _followingPeer = true;
    loading = true;
    error = null;
    deletedUserId = null;
    lastSessionExitReason = null;
    if (!event.loggedIn) {
      // Logout is authoritative even if the peer's tombstone has not reached
      // this renderer yet. A still-valid offline cookie must not restore it.
      _followingPeer = false;
      loading = false;
      notifyListeners();
      return;
    }
    final owner = _owner;
    unawaited(_restoreAfterPeerEvent(owner));
  }

  Future<void> _restoreAfterPeerEvent(Object owner) async {
    Object? restoredOwner;
    try {
      restoredOwner = await _restore(owner, forceCookie: true);
    } catch (_) {
      if (_owns(owner)) error = '其他标签页已更改账号，暂时无法确认当前会话，请重新登录。';
    } finally {
      if (_owns(restoredOwner ?? owner)) {
        _followingPeer = false;
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> _sessionStorageMatches(
    AuthSession? expected,
    Object owner,
  ) async {
    final raw = await _storage.read(_storageKey);
    if (!_owns(owner)) return false;
    if (raw == null) return true;
    if (expected == null) return false;
    try {
      final stored = AuthSession.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
      return stored.user.id == expected.user.id &&
          stored.sessionId == expected.sessionId;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _deleteMatchingSession(
    AuthSession? expected,
    Object owner,
  ) async {
    if (!await _sessionStorageMatches(expected, owner)) return false;
    if (!_owns(owner)) return false;
    await _storage.delete(_storageKey);
    return _owns(owner);
  }

  Future<T> _run<T>(Future<T> Function() action, {Object? boundOwner}) async {
    loading = true;
    error = null;
    if (!_followingPeer) notifyListeners();
    try {
      return await action();
    } on DioException catch (e) {
      final failureBody = e.response?.data;
      final code = failureBody is Map ? failureBody['code'] : null;
      if (e.response?.statusCode == 401 &&
          (code == 'session_expired' ||
              code == 'authentication_required' ||
              code == 'account_changed') &&
          ((session?.cookieSession == true &&
                  e.requestOptions.headers['X-CSRF-Token'] == csrfToken) ||
              e.requestOptions.headers['Authorization'] ==
                  'Bearer ${session?.token}')) {
        await invalidateSession();
      }
      final body = e.response?.data;
      final failure = RepositoryException(
        e.error is RepositoryException
            ? (e.error as RepositoryException).message
            : e.type == DioExceptionType.cancel
            ? '语音识别已取消。'
            : body is Map && body['error'] is String
            ? body['error'] as String
            : '无法连接账号或语音服务，请检查后端地址与网络。',
        details: {
          if (body is Map && body['details'] is Map)
            ...Map<String, dynamic>.from(body['details'] as Map),
          if (body is Map && body['code'] is String) 'code': body['code'],
        },
      );
      if (!_followingPeer && (boundOwner == null || boundOwner == _owner)) {
        error = failure.message;
      }
      throw failure;
    } catch (e) {
      final failure = e is RepositoryException
          ? e
          : const RepositoryException('服务返回内容无效，请重试。');
      if (!_followingPeer && (boundOwner == null || boundOwner == _owner)) {
        error = failure.message;
      }
      throw failure;
    } finally {
      if (!_followingPeer &&
          !_disposed &&
          (boundOwner == null || boundOwner == _owner)) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Options get _authenticated => Options(
    headers: {
      if (token != null) 'Authorization': 'Bearer $token',
      if (csrfToken.isNotEmpty) 'X-CSRF-Token': csrfToken,
    },
    extra: {_bindingKey: _AuthBinding(this, _owner)},
  );

  Future<Json> authenticatedRequest(
    String method,
    String path, {
    Object? data,
    String? contentType,
    String? idempotencyKey,
  }) {
    final bound = _authenticated;
    final options = bound.copyWith(
      method: method,
      contentType: contentType,
      headers: {...?bound.headers, 'Idempotency-Key': ?idempotencyKey},
    );
    final binding = options.extra![_bindingKey] as _AuthBinding;
    return _run(() async {
      final response = await _client.request<dynamic>(
        path,
        data: data,
        options: options,
      );
      if (binding.owner != _owner) {
        throw const RepositoryException('账号会话已变化，原操作结果已忽略。');
      }
      if (response.data is! Map) {
        throw const RepositoryException('接口响应不是 JSON 对象。');
      }
      return Map<String, dynamic>.from(response.data as Map);
    }, boundOwner: binding.owner);
  }

  Future<AuthMailDelivery> requestEmailVerification() async {
    return AuthMailDelivery.fromJson(
      await authenticatedRequest(
        'POST',
        '/api/v1/auth/email/verification/request',
        data: <String, dynamic>{},
      ),
    );
  }

  Future<DevelopmentVerificationMailbox>
  developmentVerificationMailbox() async =>
      DevelopmentVerificationMailbox.fromJson(
        await authenticatedRequest(
          'GET',
          '/api/v1/auth/development-mailbox?purpose=verify-email',
        ),
      );

  Future<void> refreshCurrentUser() async {
    final current = session;
    if (current == null) return;
    final owner = _owner;
    final body = await authenticatedRequest('GET', '/api/v1/auth/me');
    if (!_owns(owner)) return;
    final user = body['user'];
    if (user is! Map ||
        user['id'] != current.user.id ||
        (body['sessionId'] != null && body['sessionId'] != current.sessionId)) {
      throw const RepositoryException('账号会话已变化，请重新打开账户页。');
    }
    await _storeRestored({
      ...current.toJson(),
      ...body,
      'token': current.token,
      'onlineVerified': true,
    }, owner);
    if (_owns(owner)) notifyListeners();
  }

  Future<void> confirmEmailVerification(String actionToken) async {
    final body = await authenticatedRequest(
      'POST',
      '/api/v1/auth/email/verification/confirm',
      data: {'token': _emailActionToken(actionToken, '/verify-email')},
    );
    if (body['verified'] != true) {
      throw const RepositoryException('服务端未确认邮箱验证成功，请重试。');
    }
    await refreshCurrentUser();
    if (session != null && !session!.user.emailVerified) {
      throw const RepositoryException('验证已提交，但账户状态尚未确认，请刷新验证状态。');
    }
  }

  Future<AuthMailDelivery> requestPasswordReset(String email) async {
    return AuthMailDelivery.fromJson(
      await authenticatedRequest(
        'POST',
        '/api/v1/auth/password/reset/request',
        data: {'email': email.trim()},
      ),
    );
  }

  Future<void> resetPassword({
    required String token,
    required String password,
  }) async {
    final body = await authenticatedRequest(
      'POST',
      '/api/v1/auth/password/reset/confirm',
      data: {
        'token': _emailActionToken(token, '/reset-password'),
        'password': password,
      },
    );
    if (body['reset'] != true) {
      throw const RepositoryException('服务端未确认密码重置成功，请重试。');
    }
    final owner = _owner;
    if (!await _sessionStorageMatches(session, owner)) {
      _onAccountEvent(AccountEvent(apiBaseUrl: apiBaseUrl, loggedIn: true));
      return;
    }
    if (!_owns(owner)) return;
    await _storage.write('$_storageKey.signed-out', 'true');
    if (!_owns(owner)) return;
    await _deleteMatchingSession(session, owner);
    if (!_owns(owner)) return;
    session = null;
    _sessionEpoch++;
    _followingPeer = false;
    lastSessionExitReason = 'password_reset';
    logoutWarning = null;
    _publishAccount(false);
    notifyListeners();
  }

  Future<Json> createAsrTicket() => authenticatedRequest(
    'POST',
    '/api/v1/asr/tickets',
    data: {'sampleRate': 16000},
  );
  Future<void> _accept(
    dynamic body, {
    Object? expectedOwner,
    bool Function()? isCurrent,
  }) async {
    final accepted = AuthSession.fromJson(
      Map<String, dynamic>.from(body as Map),
    );
    if ((!accepted.cookieSession && accepted.token.isEmpty) ||
        !accepted.expiresAt.isAfter(DateTime.now())) {
      throw const RepositoryException('服务端会话无效，请重新登录。');
    }
    await _persistSession(() async {
      if (expectedOwner != null && !_owns(expectedOwner) ||
          isCurrent?.call() == false) {
        throw const RepositoryException('账号会话已变化，原登录结果已忽略。');
      }
      final previous = session;
      final guarded = expectedOwner != null || isCurrent != null;
      final previousMarker = guarded
          ? await _storage.read('$_storageKey.signed-out')
          : null;
      if (expectedOwner != null && !_owns(expectedOwner) ||
          isCurrent?.call() == false) {
        throw const RepositoryException('账号会话已变化，原登录结果已忽略。');
      }
      Future<void> restoreUnchangedOwner() async {
        if (expectedOwner != null && _owns(expectedOwner)) {
          if (previous == null) {
            await _storage.delete(_storageKey);
          } else {
            await _storage.write(_storageKey, jsonEncode(previous.toJson()));
          }
          if (previousMarker == null) {
            await _storage.delete('$_storageKey.signed-out');
          } else {
            await _storage.write('$_storageKey.signed-out', previousMarker);
          }
        }
      }

      await _storage.write(_storageKey, jsonEncode(accepted.toJson()));
      if (expectedOwner != null && !_owns(expectedOwner) ||
          isCurrent?.call() == false) {
        // A page may close while secure storage is writing. Restore the
        // unchanged local owner before leaving this serialized write slot.
        await restoreUnchangedOwner();
        throw const RepositoryException('账号会话已变化，原登录结果已忽略。');
      }
      await _storage.delete('$_storageKey.signed-out');
      if (expectedOwner != null && !_owns(expectedOwner) ||
          isCurrent?.call() == false) {
        await restoreUnchangedOwner();
        throw const RepositoryException('账号会话已变化，原登录结果已忽略。');
      }
      session = accepted;
      _sessionEpoch++;
      _followingPeer = false;
      deletedUserId = null;
      lastSessionExitReason = null;
      logoutWarning = null;
    });
  }

  Future<void> initialize() async {
    final owner = _owner;
    Object? restoredOwner;
    loading = true;
    error = null;
    notifyListeners();
    try {
      restoredOwner = await _restore(owner);
    } catch (failure) {
      if (_owns(owner)) error = '无法恢复账号会话，请检查网络后重试。';
      throw failure is RepositoryException
          ? failure
          : const RepositoryException('无法恢复账号会话，请检查网络后重试。');
    } finally {
      if (_owns(restoredOwner ?? owner)) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<Object?> _restore(Object owner, {bool forceCookie = false}) async {
    if (forceCookie) {
      // BroadcastChannel can arrive before another renderer's localStorage
      // updates (observed in Edge). The current HttpOnly cookie is authoritative;
      // do not gate an explicit peer login on stale signed-out/candidate data.
      final response = await _client.get<dynamic>(
        '/api/v1/auth/me',
        options: Options(extra: {_bindingKey: _AuthBinding(this, owner)}),
      );
      if (!_owns(owner)) return null;
      return _storeRestored(
        Map<String, dynamic>.from(response.data as Map),
        owner,
      );
    }
    final signedOut = await _storage.read('$_storageKey.signed-out');
    if (!_owns(owner) || signedOut == 'true') return null;
    final raw = await _storage.read(_storageKey);
    if (!_owns(owner)) return null;
    if (raw == null) {
      if (kIsWeb || forceCookie) {
        try {
          final response = await _client.get<dynamic>(
            '/api/v1/auth/me',
            options: Options(extra: {_bindingKey: _AuthBinding(this, owner)}),
          );
          if (!_owns(owner)) return null;
          return await _storeRestored(
            Map<String, dynamic>.from(response.data as Map),
            owner,
          );
        } on DioException catch (failure) {
          if (failure.response?.statusCode != 401 && failure.response != null) {
            rethrow;
          }
        }
      }
      return null;
    }
    AuthSession candidate;
    try {
      candidate = AuthSession.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return null;
    }
    if (!candidate.expiresAt.isAfter(DateTime.now())) {
      await _deleteMatchingSession(candidate, owner);
      return null;
    }
    try {
      final body =
          (await _client.get<dynamic>(
                '/api/v1/auth/me',
                options: Options(
                  headers: {
                    if (!forceCookie &&
                        !candidate.cookieSession &&
                        candidate.token.isNotEmpty)
                      'Authorization': 'Bearer ${candidate.token}',
                  },
                  extra: {_bindingKey: _AuthBinding(this, owner)},
                ),
              )).data
              as Map;
      if (!_owns(owner)) return null;
      return await _storeRestored({
        ...candidate.toJson(),
        ...Map<String, dynamic>.from(body),
        'token': forceCookie ? '' : candidate.token,
        'onlineVerified': true,
      }, owner);
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        await _deleteMatchingSession(candidate, owner);
        if (_owns(owner)) {
          session = null;
          return _owner;
        }
        return null;
      }
      if (e.response == null) {
        if (!_owns(owner)) return null;
        session = AuthSession.fromJson({
          ...candidate.toJson(),
          'onlineVerified': false,
        });
        return _owner;
      }
      rethrow;
    }
  }

  Future<Object?> _storeRestored(Json body, Object owner) async {
    final restored = AuthSession.fromJson(body);
    if ((!restored.cookieSession && restored.token.isEmpty) ||
        !restored.expiresAt.isAfter(DateTime.now())) {
      throw const RepositoryException('服务端会话无效，请重新登录。');
    }
    return _persistSession(() async {
      if (!_owns(owner)) return null;
      await _storage.write(_storageKey, jsonEncode(restored.toJson()));
      if (!_owns(owner)) return null;
      session = restored;
      return _owner;
    });
  }

  Future<void> register({
    required String username,
    required String email,
    required String password,
  }) => _run(() async {
    await _accept(
      (await _client.post<dynamic>(
        '/api/v1/auth/register',
        data: {
          'username': username.trim(),
          'email': email.trim(),
          'password': password,
        },
      )).data,
    );
    _publishAccount(true);
  });
  Future<void> login({required String identifier, required String password}) =>
      _run(() async {
        await _accept(
          (await _client.post<dynamic>(
            '/api/v1/auth/login',
            data: {'identifier': identifier.trim(), 'password': password},
          )).data,
        );
        _publishAccount(true);
      });

  /// Uses the existing Cookie/CSRF transport and native secure session storage.
  /// Identity providers never persist credentials in a separate repository.
  Future<Json> authenticateSession(
    String path, {
    required Json data,
    required Object expectedOwner,
    bool Function()? isCurrent,
  }) async {
    if (!_owns(expectedOwner) || isCurrent?.call() == false) {
      throw const RepositoryException('账号会话已变化，请重新开始登录。');
    }
    Object? adoptedOwner;
    final result = await _run(() async {
      final options = _authenticated;
      final response = await _client.post<dynamic>(
        path,
        data: data,
        options: options,
      );
      if (!_owns(expectedOwner) ||
          isCurrent?.call() == false ||
          response.data is! Map) {
        throw const RepositoryException('账号会话已变化或登录响应无效。');
      }
      final body = Map<String, dynamic>.from(response.data as Map);
      await _accept(body, expectedOwner: expectedOwner, isCurrent: isCurrent);
      adoptedOwner = _owner;
      _publishAccount(true);
      return body;
    }, boundOwner: expectedOwner);
    final completedOwner = adoptedOwner;
    if (completedOwner != null && _owns(completedOwner) && !_followingPeer) {
      loading = false;
      notifyListeners();
    }
    return result;
  }

  Future<void> logout() => _run(() async {
    final boundOwner = _owner;
    deletedUserId = null;
    logoutWarning = null;
    try {
      await _client.post<dynamic>(
        '/api/v1/auth/logout',
        data: <String, dynamic>{},
        options: _authenticated,
      );
    } on DioException catch (failure) {
      if (failure.response?.statusCode != 401) {
        logoutWarning = '本机已退出；服务器会话撤销尚未确认，原会话将于到期后失效。';
      }
    }
    if (_owner == boundOwner) {
      if (!await _sessionStorageMatches(session, boundOwner)) {
        _onAccountEvent(AccountEvent(apiBaseUrl: apiBaseUrl, loggedIn: true));
        return;
      }
      if (!_owns(boundOwner)) return;
      await _storage.write('$_storageKey.signed-out', 'true');
      if (_owner != boundOwner) return;
      await _deleteMatchingSession(session, boundOwner);
      if (_owner != boundOwner) return;
      session = null;
      _sessionEpoch++;
      _followingPeer = false;
      lastSessionExitReason = 'logout';
      _publishAccount(false);
    }
  });
  Future<Json> exportAccount() => _run(
    () async => Map<String, dynamic>.from(
      (await _client.get<dynamic>(
            '/api/v1/account/export',
            options: _authenticated,
          )).data
          as Map,
    ),
  );
  Future<void> deleteAccount(String password, {String? phoneProof}) => _run(
    () async {
      final boundOwner = _owner;
      final boundUser = session?.user.id;
      await _client.delete<dynamic>(
        '/api/v1/account',
        data: {'password': password, 'phoneProof': ?phoneProof},
        options: _authenticated,
      );
      if (_owner == boundOwner) {
        if (!await _sessionStorageMatches(session, boundOwner)) {
          _onAccountEvent(AccountEvent(apiBaseUrl: apiBaseUrl, loggedIn: true));
          return;
        }
        if (!_owns(boundOwner)) return;
        deletedUserId = boundUser;
        lastSessionExitReason = 'deleted';
        await _storage.write('$_storageKey.signed-out', 'true');
        if (!_owns(boundOwner)) return;
        await _deleteMatchingSession(session, boundOwner);
        if (_owner != boundOwner) return;
        session = null;
        _sessionEpoch++;
        _followingPeer = false;
        _publishAccount(false);
      }
    },
  );
  Future<Workspace?> readLegacyGuest() => _run(() async {
    final body =
        (await _client.get<dynamic>(
              '/api/v1/guest-workspace',
              options: _authenticated,
            )).data
            as Map;
    return body['workspace'] is Map
        ? Workspace.fromJson(
            Map<String, dynamic>.from(body['workspace'] as Map),
          )
        : null;
  });
  Future<Workspace> importGuest(
    Workspace workspace, {
    required int expectedRevision,
  }) => _run(() async {
    final body =
        (await _client.post<dynamic>(
              '/api/v1/workspace/import-guest',
              options: _authenticated,
              data: {
                'workspace': workspace.toJson(),
                'expectedRevision': expectedRevision,
              },
            )).data
            as Map;
    return Workspace.fromJson(
      Map<String, dynamic>.from(body['workspace'] as Map),
    );
  });
  Future<String> transcribeAudio(
    Uint8List bytes, {
    required String filename,
    required String mimeType,
    int? durationMilliseconds,
  }) => _run(() async {
    if (bytes.isEmpty ||
        bytes.length > 10 * 1024 * 1024 ||
        (durationMilliseconds ?? 1) > 60000) {
      throw const RepositoryException('录音需在 60 秒和 10 MiB 以内。');
    }
    _transcriptionCancel?.cancel('Superseded by another recording');
    final cancellation = CancelToken();
    _transcriptionCancel = cancellation;
    final body = (await _client.post<dynamic>(
      '/api/v1/ai/transcribe',
      options: _authenticated,
      cancelToken: cancellation,
      data: FormData.fromMap({
        'file': MultipartFile.fromBytes(
          bytes,
          filename: filename,
          contentType: DioMediaType.parse(mimeType),
        ),
      }),
    )).data;
    if (body is! Map ||
        body['text'] is! String ||
        (body['text'] as String).trim().isEmpty ||
        body['source'] != 'siliconflow') {
      throw const RepositoryException('没有识别到语音内容，请重新录制。');
    }
    return (body['text'] as String).trim();
  });

  @override
  void dispose() {
    _disposed = true;
    _sessionEpoch++;
    cancelTranscription();
    unawaited(_accountSubscription.cancel());
    _accountEvents.dispose();
    super.dispose();
  }
}
