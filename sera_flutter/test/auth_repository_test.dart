import 'dart:convert';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/data/repositories.dart';
import 'package:sera_flutter/domain/models.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });
  Json result() => {
    'token': 'opaque-session',
    'expiresAt': DateTime.now()
        .add(const Duration(days: 1))
        .toUtc()
        .toIso8601String(),
    'user': {
      'id': 'user-a',
      'username': 'alice',
      'email': 'alice@example.test',
    },
  };
  test('registration stores only session; restored session is verified with server', () async {
    final client = Dio();
    final paths = <String>[];
    client.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          paths.add(options.path);
          if (options.path.endsWith('/me')) {
            expect(options.headers['Authorization'], 'Bearer opaque-session');
          }
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              data: result(),
              statusCode: 200,
            ),
          );
        },
      ),
    );
    final auth = AuthRepository(
      preferences: SharedPreferencesAsync(),
      apiBaseUrl: 'http://auth.test',
      client: client,
    );
    await auth.register(
      username: 'alice',
      email: 'alice@example.test',
      password: 'NeverPersistPassword',
    );
    expect(auth.signedIn, isTrue);
    final values = await SharedPreferencesAsync().getAll();
    expect(jsonEncode(values), isNot(contains('NeverPersistPassword')));
    final reopened = AuthRepository(
      preferences: SharedPreferencesAsync(),
      apiBaseUrl: 'http://auth.test',
      client: client,
    );
    await reopened.initialize();
    expect(reopened.session!.user.id, 'user-a');
    expect(paths, ['/api/v1/auth/register', '/api/v1/auth/me']);
  });
  test('bad login cannot fabricate session and offline logout warns before local exit', () async {
    final client = Dio();
    var failing = true;
    client.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (failing) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response<dynamic>(
                  requestOptions: options,
                  statusCode: options.path.endsWith('/logout') ? 503 : 401,
                  data: {'error': 'invalid credentials'},
                ),
              ),
            );
          } else {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: result(),
              ),
            );
          }
        },
      ),
    );
    final auth = AuthRepository(
      preferences: SharedPreferencesAsync(),
      apiBaseUrl: 'http://auth.test',
      client: client,
    );
    await expectLater(
      auth.login(identifier: 'alice', password: 'wrong'),
      throwsA(isA<RepositoryException>()),
    );
    expect(auth.session, isNull);
    failing = false;
    await auth.login(identifier: 'alice', password: 'correct');
    failing = true;
    await auth.logout();
    expect(auth.signedIn, isFalse);
    expect(auth.logoutWarning, contains('尚未确认'));
    failing = false;
    await auth.logout();
    expect(auth.signedIn, isFalse);
  });
  test(
    'cookie session restore never sends an empty Bearer and keeps identity',
    () async {
      final client = Dio();
      final body = {
        ...result(),
        'token': '',
        'cookieSession': true,
        'csrfToken': 'bound-csrf',
        'sessionId': 'stable-cookie-session',
      };
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.endsWith('/me')) {
              expect(options.headers.containsKey('Authorization'), isFalse);
            }
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: body,
              ),
            );
          },
        ),
      );
      final auth = AuthRepository(
        preferences: SharedPreferencesAsync(),
        apiBaseUrl: 'http://cookie.test',
        client: client,
      );
      await auth.login(identifier: 'alice', password: 'correct');
      final reopened = AuthRepository(
        preferences: SharedPreferencesAsync(),
        apiBaseUrl: 'http://cookie.test',
        client: client,
      );
      await reopened.initialize();
      expect(reopened.signedIn, isTrue);
      expect(reopened.token, isNull);
      expect(reopened.session!.sessionId, 'stable-cookie-session');
      expect(reopened.csrfToken, 'bound-csrf');
      expect(reopened.onlineVerified, isTrue);
    },
  );
  test(
    'workspace repository reads current token for every authenticated request',
    () async {
      final client = Dio();
      var token = 'session-a';
      final seen = <String>[];
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            // Token interceptor is appended, so inspect the final response request.
            handler.next(options);
          },
          onResponse: (response, handler) {
            handler.next(response);
          },
        ),
      );
      final repository = HttpWorkspaceRepository(
        baseUrl: 'http://api.test',
        client: client,
        tokenProvider: () => token,
      );
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            seen.add(options.headers['Authorization'] as String);
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                data: {'workspace': null},
                statusCode: 200,
              ),
            );
          },
        ),
      );
      await repository.load();
      token = 'session-b';
      await repository.load();
      expect(seen, ['Bearer session-a', 'Bearer session-b']);
    },
  );
  test('transcription cancellation aborts the actual Dio request', () async {
    final client = Dio();
    CancelToken? pending;
    client.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          pending = options.cancelToken;
          options.cancelToken!.whenCancel.then(handler.reject);
        },
      ),
    );
    final auth = AuthRepository(
      preferences: SharedPreferencesAsync(),
      apiBaseUrl: 'http://api.test',
      client: client,
    );
    final request = auth.transcribeAudio(
      Uint8List.fromList([1, 2]),
      filename: 'voice.wav',
      mimeType: 'audio/wav',
    );
    final assertion = expectLater(
      request,
      throwsA(
        isA<RepositoryException>().having(
          (e) => e.message,
          'message',
          contains('取消'),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    auth.cancelTranscription();
    await assertion;
    expect(pending!.isCancelled, isTrue);
  });

  test('expired workspace session invokes account invalidation', () async {
    var invalidations = 0;
    final client = Dio();
    client.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response: Response<dynamic>(
                requestOptions: options,
                statusCode: 401,
                data: {'error': 'expired'},
              ),
            ),
          );
        },
      ),
    );
    final repository = HttpWorkspaceRepository(
      baseUrl: 'http://api.test',
      client: client,
      tokenProvider: () => 'expired',
      onUnauthorized: () async {
        invalidations++;
      },
    );
    await expectLater(repository.load(), throwsA(isA<RepositoryException>()));
    expect(invalidations, 1);
  });

  test('offline reopen preserves unexpired identity and marks verification unavailable', () async {
    final online = Dio();
    final accepted = result();
    online.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              data: accepted,
              statusCode: 200,
            ),
          );
        },
      ),
    );
    final preferences = SharedPreferencesAsync();
    final first = AuthRepository(
      apiBaseUrl: 'http://offline.test',
      client: online,
      preferences: preferences,
    );
    await first.login(identifier: 'alice', password: 'password');
    final identity = first.session!.sessionId;
    final offline = Dio();
    offline.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
            ),
          );
        },
      ),
    );
    final restored = AuthRepository(
      apiBaseUrl: 'http://offline.test',
      client: offline,
      preferences: preferences,
    );
    await restored.initialize();
    expect(restored.signedIn, isTrue);
    expect(restored.onlineVerified, isFalse);
    expect(restored.session!.sessionId, identity);
    await restored.logout();
    final reopened = AuthRepository(
      apiBaseUrl: 'http://offline.test',
      client: online,
      preferences: preferences,
    );
    await reopened.initialize();
    expect(reopened.signedIn, isFalse);
  });

  test(
    'wrong account deletion password never invalidates a valid session',
    () async {
      final client = Dio();
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.method == 'DELETE') {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.badResponse,
                  response: Response<dynamic>(
                    requestOptions: options,
                    statusCode: 401,
                    data: {
                      'error': 'Wrong password',
                      'code': 'invalid_credentials',
                    },
                  ),
                ),
              );
            } else {
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  data: result(),
                  statusCode: 200,
                ),
              );
            }
          },
        ),
      );
      final auth = AuthRepository(
        apiBaseUrl: 'http://delete.test',
        client: client,
        preferences: SharedPreferencesAsync(),
      );
      await auth.login(identifier: 'alice', password: 'password');
      await expectLater(
        auth.deleteAccount('incorrect'),
        throwsA(isA<RepositoryException>()),
      );
      expect(auth.signedIn, isTrue);
      expect(auth.deletedUserId, isNull);
    },
  );

  for (final cookie in [false, true]) {
    test(
      'queued ${cookie ? 'cookie' : 'native'} request keeps calling credentials and cannot dispatch after account switch',
      () async {
        final client = Dio();
        final entered = Completer<RequestOptions>();
        final release = Completer<void>();
        client.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) async {
              entered.complete(options);
              await release.future;
              handler.next(options);
            },
          ),
        );
        final auth = AuthRepository(
          apiBaseUrl: 'http://bound.test',
          client: client,
          preferences: SharedPreferencesAsync(),
        );
        AuthSession identity(String id) => AuthSession(
          token: cookie ? '' : 'token-$id',
          csrfToken: 'csrf-$id',
          cookieSession: cookie,
          sessionId: 'session-$id',
          expiresAt: DateTime.now().add(const Duration(days: 1)),
          user: AuthUser(id: id, username: id, email: '$id@example.test'),
        );
        auth.session = identity('a');
        var dispatched = 0;
        client.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              dispatched++;
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  data: {'saved': true},
                ),
              );
            },
          ),
        );
        final pending = auth.authenticatedRequest(
          'POST',
          '/api/v1/calendar/ics/preview',
          data: {'content': 'A input'},
        );
        final assertion = expectLater(
          pending,
          throwsA(isA<RepositoryException>()),
        );
        final captured = await entered.future;
        expect(captured.headers['X-CSRF-Token'], 'csrf-a');
        expect(
          captured.headers['Authorization'],
          cookie ? isNull : 'Bearer token-a',
        );
        auth.session = identity('b');
        release.complete();
        await assertion;
        expect(dispatched, 0);
        expect(captured.headers['X-CSRF-Token'], 'csrf-a');
        expect(auth.session!.user.id, 'b');
        expect(auth.error, isNull);
      },
    );
  }
  test(
    'late successful generic response is discarded after account switch',
    () async {
      final client = Dio();
      final entered = Completer<void>();
      final release = Completer<void>();
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            entered.complete();
            await release.future;
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                data: {'private': 'account A'},
              ),
            );
          },
        ),
      );
      final auth = AuthRepository(
        apiBaseUrl: 'http://late.test',
        client: client,
        preferences: SharedPreferencesAsync(),
      );
      AuthSession identity(String id) => AuthSession(
        token: 'token-$id',
        sessionId: id,
        expiresAt: DateTime.now().add(const Duration(days: 1)),
        user: AuthUser(id: id, username: id, email: '$id@example.test'),
      );
      auth.session = identity('a');
      final assertion = expectLater(
        auth.authenticatedRequest('GET', '/api/v1/account/export'),
        throwsA(isA<RepositoryException>()),
      );
      await entered.future;
      auth.session = identity('b');
      release.complete();
      await assertion;
      expect(auth.session!.user.id, 'b');
      expect(auth.error, isNull);
    },
  );

  test('peer tabs follow the shared cookie without stale csrf or an intermediate signed-out scope', () async {
    final hub = _AccountHub();
    final client = Dio();
    Json cookie(String id) => {
      ...result(),
      'token': '',
      'cookieSession': true,
      'sessionId': 'cookie-$id',
      'csrfToken': 'csrf-$id',
      'user': {'id': id, 'username': id, 'email': '$id@example.test'},
    };
    var current = cookie('a');
    var meRequests = 0;
    final mockServer = InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.path.endsWith('/login')) {
          current = cookie((options.data as Map)['identifier'] as String);
        }
        if (options.path.endsWith('/me')) {
          meRequests++;
          expect(options.headers.containsKey('X-CSRF-Token'), isFalse);
          expect(options.headers.containsKey('Authorization'), isFalse);
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: options.path.endsWith('/logout') ? {'ok': true} : current,
          ),
        );
      },
    );
    var microphoneStops = 0;
    final first = AuthRepository(
      apiBaseUrl: 'http://tabs.test',
      client: client,
      preferences: SharedPreferencesAsync(),
      accountEvents: hub.port(),
      onPeerAccountChange: () => microphoneStops++,
    );
    final second = AuthRepository(
      apiBaseUrl: 'http://tabs.test',
      client: client,
      preferences: SharedPreferencesAsync(),
      accountEvents: hub.port(),
    );
    client.interceptors.add(mockServer);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await first.login(identifier: 'a', password: 'password');
    await _eventually(() => second.session?.user.id == 'a');
    final eventCount = hub.published.length;
    await second.initialize();
    expect(
      hub.published.length,
      eventCount,
      reason: 'Restoration must not broadcast loops',
    );
    final scopes = <String?>[];
    first.addListener(() => scopes.add(first.session?.user.id));
    await second.login(identifier: 'b', password: 'password');
    await _eventually(() => first.session?.user.id == 'b');
    expect(scopes, isNotEmpty);
    expect(scopes.every((id) => id == 'b'), isTrue);
    expect(first.csrfToken, 'csrf-b');
    expect(first.session!.sessionId, second.session!.sessionId);
    expect(microphoneStops, 1);
    await second.logout();
    await _eventually(() => first.session == null && !first.loading);
    expect(first.signedIn, isFalse);
    expect(scopes.last, isNull);
    expect(microphoneStops, 2);
    expect(meRequests, greaterThanOrEqualTo(2));
    expect(
      hub.published.every(
        (event) => event.toJson().keys.toSet().difference({
          'apiBaseUrl',
          'event',
        }).isEmpty,
      ),
      isTrue,
    );
    expect(
      jsonEncode(hub.published.map((e) => e.toJson()).toList()),
      isNot(
        anyOf(
          contains('csrf-'),
          contains('cookie-b'),
          contains('@example.test'),
        ),
      ),
    );
  });

  test('a late peer-cookie restore cannot resurrect an account after another tab logs out', () async {
    final hub = _AccountHub();
    final client = Dio();
    final entered = Completer<void>();
    final release = Completer<void>();
    var blockMe = false;
    Json cookie(String id) => {
      ...result(),
      'token': '',
      'cookieSession': true,
      'sessionId': 'cookie-$id',
      'csrfToken': 'csrf-$id',
      'user': {'id': id, 'username': id, 'email': '$id@example.test'},
    };
    var current = cookie('a');
    final mockServer = InterceptorsWrapper(
      onRequest: (options, handler) async {
        if (options.path.endsWith('/login')) {
          current = cookie((options.data as Map)['identifier'] as String);
        }
        final response = current;
        if (options.path.endsWith('/me') && blockMe) {
          entered.complete();
          await release.future;
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: options.path.endsWith('/logout') ? {'ok': true} : response,
          ),
        );
      },
    );
    final first = AuthRepository(
      apiBaseUrl: 'http://late-tabs.test',
      client: client,
      preferences: SharedPreferencesAsync(),
      accountEvents: hub.port(),
    );
    final second = AuthRepository(
      apiBaseUrl: 'http://late-tabs.test',
      client: client,
      preferences: SharedPreferencesAsync(),
      accountEvents: hub.port(),
    );
    client.interceptors.add(mockServer);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await first.login(identifier: 'a', password: 'password');
    await _eventually(() => second.session?.user.id == 'a');
    blockMe = true;
    await second.login(identifier: 'b', password: 'password');
    await entered.future;
    await second.logout();
    await _eventually(() => first.session == null && !first.loading);
    release.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(first.session, isNull);
    expect(first.error, isNull);
    expect(
      await SharedPreferencesAsync().getString(
        'sera.auth.session.http://late-tabs.test',
      ),
      isNull,
    );
    expect(hub.published.length, 3);
  });

  test(
    'stale invalidation preserves metadata written by a newer cookie account',
    () async {
      final client = Dio();
      Json cookie(String id) => {
        ...result(),
        'token': '',
        'cookieSession': true,
        'sessionId': 'cookie-$id',
        'csrfToken': 'csrf-$id',
        'user': {'id': id, 'username': id, 'email': '$id@example.test'},
      };
      var current = cookie('a');
      final auth = AuthRepository(
        apiBaseUrl: 'http://metadata.test',
        client: client,
        preferences: SharedPreferencesAsync(),
      );
      addTearDown(auth.dispose);
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.endsWith('/me')) {
              expect(options.headers.containsKey('X-CSRF-Token'), isFalse);
            }
            handler.resolve(
              Response<dynamic>(requestOptions: options, data: current),
            );
          },
        ),
      );
      await auth.login(identifier: 'a', password: 'password');
      current = cookie('b');
      const key = 'sera.auth.session.http://metadata.test';
      await SharedPreferencesAsync().setString(key, jsonEncode(current));
      final scopes = <String?>[];
      auth.addListener(() => scopes.add(auth.session?.user.id));
      await auth.invalidateSession();
      await _eventually(() => auth.session?.user.id == 'b');
      expect(scopes, ['b']);
      expect(
        jsonDecode(
          (await SharedPreferencesAsync().getString(key))!,
        )['user']['id'],
        'b',
      );
    },
  );
  test('peer login uses the cookie before stale storage propagates; peer logout cannot restore it', () async {
    final hub = _AccountHub();
    final sender = hub.port();
    final client = Dio();
    final preferences = SharedPreferencesAsync();
    const base = 'http://storage-order.test';
    const key = 'sera.auth.session.$base';
    await preferences.setString('$key.signed-out', 'true');
    await preferences.setString(key, 'stale invalid metadata');
    var meRequests = 0, stopped = 0;
    final auth = AuthRepository(
      apiBaseUrl: base,
      client: client,
      preferences: preferences,
      accountEvents: hub.port(),
      onPeerAccountChange: () => stopped++,
    );
    addTearDown(auth.dispose);
    addTearDown(sender.dispose);
    client.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          expect(options.path, '/api/v1/auth/me');
          expect(options.headers.containsKey('Authorization'), isFalse);
          expect(options.headers.containsKey('X-CSRF-Token'), isFalse);
          meRequests++;
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              data: {
                ...result(),
                'token': '',
                'cookieSession': true,
                'sessionId': 'cookie-b',
                'csrfToken': 'csrf-b',
                'user': {'id': 'b', 'username': 'b', 'email': 'b@example.test'},
              },
            ),
          );
        },
      ),
    );
    sender.publish(const AccountEvent(apiBaseUrl: base, loggedIn: true));
    await _eventually(() => auth.session?.user.id == 'b' && !auth.loading);
    expect(meRequests, 1);
    expect(auth.csrfToken, 'csrf-b');
    // The inverse propagation race: no marker is visible and /me would still
    // accept B. An explicit peer logout must not restore that old cookie.
    await preferences.remove('$key.signed-out');
    sender.publish(const AccountEvent(apiBaseUrl: base, loggedIn: false));
    await _eventually(() => auth.session == null && !auth.loading);
    expect(meRequests, 1);
    expect(stopped, 2);
    expect(hub.published.length, 2);
  });
  _authRecoveryTests();
}

void _authRecoveryTests() {
  group('account recovery', () {
    for (final purpose in ['verify-email', 'reset-password']) {
      test('$purpose extracts a token from complete HTTP and HTTPS email links', () async {
        final client = Dio();
        final auth = _recoveryAuth(client);
        final receivedTokens = <String>[];
        client.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              expect(options.method, 'POST');
              expect(
                options.path,
                purpose == 'verify-email'
                    ? '/api/v1/auth/email/verification/confirm'
                    : '/api/v1/auth/password/reset/confirm',
              );
              final body = options.data as Map;
              receivedTokens.add(body['token'] as String);
              if (purpose == 'reset-password') {
                expect(body['password'], 'new-secret-password');
              }
              _recoveryResolve(
                options,
                handler,
                purpose == 'verify-email'
                    ? {'verified': true}
                    : {'reset': true},
              );
            },
          ),
        );
        for (final scheme in ['http', 'https']) {
          final link =
              ' $scheme://sera.example.test/#/$purpose?token=$scheme%2Dmail%5Ftoken ';
          if (purpose == 'verify-email') {
            await auth.confirmEmailVerification(link);
          } else {
            await auth.resetPassword(
              token: link,
              password: 'new-secret-password',
            );
          }
        }
        expect(receivedTokens, ['http-mail_token', 'https-mail_token']);
        expect(auth.signedIn, isFalse);
      });

      test(
        '$purpose rejects a complete link for another purpose without sending it',
        () async {
          final client = Dio();
          final auth = _recoveryAuth(client)..session = _recoverySession();
          var requests = 0;
          client.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                requests++;
                _recoveryResolve(options, handler, {
                  'verified': true,
                  'reset': true,
                });
              },
            ),
          );
          final wrongPurpose = purpose == 'verify-email'
              ? 'reset-password'
              : 'verify-email';
          final link =
              'https://sera.example.test/#/$wrongPurpose?token=other-purpose-token';
          final attempt = purpose == 'verify-email'
              ? auth.confirmEmailVerification(link)
              : auth.resetPassword(
                  token: link,
                  password: 'new-secret-password',
                );
          await expectLater(attempt, throwsA(isA<RepositoryException>()));
          expect(
            requests,
            0,
            reason: 'A link must never cross email action purposes.',
          );
          expect(auth.token, 'token-a');
          expect(auth.session!.user.emailVerified, isFalse);
        },
      );
    }

    test('a slow persisted me refresh cannot overwrite a later login', () async {
      final storage = _SlowAuthSessionStorage();
      final client = Dio();
      final auth = AuthRepository(
        apiBaseUrl: 'http://recovery.test',
        client: client,
        storage: storage,
      )..session = _recoverySession();
      addTearDown(auth.dispose);
      storage.values[_SlowAuthSessionStorage.sessionKey] = jsonEncode(
        auth.session!.toJson(),
      );
      final loginEntered = Completer<void>();
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.endsWith('/me')) {
              _recoveryResolve(
                options,
                handler,
                _recoverySession(verified: true).toJson(),
              );
            } else {
              expect(options.path, '/api/v1/auth/login');
              loginEntered.complete();
              _recoveryResolve(
                options,
                handler,
                _recoverySession(id: 'b').toJson(),
              );
            }
          },
        ),
      );
      final refresh = auth.refreshCurrentUser();
      await storage.refreshWriteEntered.future;
      final login = auth.login(
        identifier: 'b',
        password: 'new-account-password',
      );
      await loginEntered.future;
      // Let the new login reach its storage operation while the old write is
      // paused. Correct serialization may keep the login pending until release.
      await Future<void>.delayed(Duration.zero);
      storage.releaseRefreshWrite.complete();
      await Future.wait([refresh, login]);
      expect(auth.session!.user.id, 'b');
      expect(auth.token, 'token-b');
      final persisted = jsonDecode(
        storage.values[_SlowAuthSessionStorage.sessionKey]!,
      ) as Map;
      expect(
        (persisted['user'] as Map)['id'],
        'b',
        reason: 'The old refresh must not remain as the restored account.',
      );
      expect(persisted['token'], 'token-b');
      final reopenedClient = Dio();
      final reopened = AuthRepository(
        apiBaseUrl: 'http://recovery.test',
        client: reopenedClient,
        storage: storage,
      );
      addTearDown(reopened.dispose);
      // The stored native credentials are the important recovery boundary;
      // loading them must target B rather than the stale A account.
      reopenedClient.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.path, '/api/v1/auth/me');
            expect(options.headers['Authorization'], 'Bearer token-b');
            _recoveryResolve(
              options,
              handler,
              _recoverySession(id: 'b').toJson(),
            );
          },
        ),
      );
      await reopened.initialize();
      expect(reopened.session!.user.id, 'b');
    });

    for (final mode in ['local', 'mailpit', 'smtp']) {
      test('$mode verification delivery preserves the server status', () async {
        final client = Dio();
        final auth = _recoveryAuth(client)..session = _recoverySession();
        client.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              expect(options.method, 'POST');
              expect(options.path, '/api/v1/auth/email/verification/request');
              expect(options.headers['Authorization'], 'Bearer token-a');
              _recoveryResolve(options, handler, {
                'accepted': true,
                'deliveryMode': mode,
                'deliveryStatus': mode == 'local'
                    ? 'local_preview'
                    : 'smtp_accepted',
                'developmentPreview': true,
                'message': '$mode delivery report',
              });
            },
          ),
        );
        final delivery = await auth.requestEmailVerification();
        expect(delivery.mode, mode);
        expect(
          delivery.status,
          mode == 'local' ? 'local_preview' : 'smtp_accepted',
        );
        expect(delivery.message, '$mode delivery report');
        expect(delivery.isLocal, mode == 'local');
        expect(delivery.developmentPreview, mode == 'local');
      });
    }

    for (final invalid in <Json>[
      {},
      {'deliveryMode': 'smtp', 'message': 'sent'},
      {'deliveryMode': 'smtp', 'deliveryStatus': '', 'message': 'sent'},
      {
        'deliveryMode': 'smtp',
        'deliveryStatus': 'smtp_accepted',
        'message': ' ',
      },
      {'deliveryMode': 'unknown', 'deliveryStatus': 'sent', 'message': 'sent'},
    ]) {
      test(
        'verification does not invent a delivery status for $invalid',
        () async {
          final client = Dio();
          final auth = _recoveryAuth(client)..session = _recoverySession();
          client.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                _recoveryResolve(options, handler, invalid);
              },
            ),
          );
          await expectLater(
            auth.requestEmailVerification(),
            throwsA(isA<RepositoryException>()),
          );
          expect(auth.session!.user.emailVerified, isFalse);
        },
      );
    }

    test(
      'anonymous password reset retains generic status and trims email',
      () async {
        final client = Dio();
        final auth = _recoveryAuth(client);
        client.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              expect(options.path, '/api/v1/auth/password/reset/request');
              expect(options.data, {'email': 'nobody@example.test'});
              expect(options.headers.containsKey('Authorization'), isFalse);
              _recoveryResolve(options, handler, {
                'accepted': true,
                'deliveryMode': 'local',
                'deliveryStatus': 'request_accepted',
                'developmentPreview': false,
                'message': '若邮箱存在将生成重置邮件；当前本地模式不会投递至外部邮箱。',
              });
            },
          ),
        );
        final delivery = await auth.requestPasswordReset(
          ' nobody@example.test ',
        );
        expect(delivery.status, 'request_accepted');
        expect(delivery.developmentPreview, isFalse);
        expect(delivery.message, contains('不会投递'));
        expect(auth.signedIn, isFalse);
      },
    );

    test('development mailbox requests only current authenticated verification mail', () async {
      final client = Dio();
      final auth = _recoveryAuth(client)..session = _recoverySession();
      final expiresAt = DateTime.now().add(const Duration(minutes: 10)).toUtc();
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.method, 'GET');
            expect(
              Uri.parse(options.path).path,
              '/api/v1/auth/development-mailbox',
            );
            expect(Uri.parse(options.path).queryParameters, {
              'purpose': 'verify-email',
            });
            expect(options.headers['Authorization'], 'Bearer token-a');
            expect(options.headers['X-CSRF-Token'], 'csrf-a');
            _recoveryResolve(options, handler, {
              'deliveryMode': 'local',
              'message': '仅显示当前账号的有效验证邮件。',
              'mail': {
                'subject': '验证 SERA 邮箱',
                'verificationUrl':
                    'http://localhost:8787/#/verify-email?token=one-use-a',
                'expiresAt': expiresAt.toIso8601String(),
              },
            });
          },
        ),
      );
      final mailbox = await auth.developmentVerificationMailbox();
      expect(mailbox.message, contains('当前账号'));
      expect(mailbox.mail!.subject, '验证 SERA 邮箱');
      expect(mailbox.mail!.token, 'one-use-a');
      expect(mailbox.mail!.expiresAt, expiresAt);
      expect(mailbox.mail!.verificationUrl, contains('/verify-email?'));
    });

    test(
      'development mailbox can be empty without fabricating a token',
      () async {
        final client = Dio();
        final auth = _recoveryAuth(client)..session = _recoverySession();
        client.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              _recoveryResolve(options, handler, {
                'deliveryMode': 'local',
                'message': '没有有效验证邮件。',
                'mail': null,
              });
            },
          ),
        );
        final mailbox = await auth.developmentVerificationMailbox();
        expect(mailbox.mail, isNull);
      },
    );

    test(
      'anonymous development mailbox denial is surfaced without exposing mail',
      () async {
        final client = Dio();
        final auth = _recoveryAuth(client);
        client.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              expect(options.headers.containsKey('Authorization'), isFalse);
              _recoveryReject(
                options,
                handler,
                401,
                '请先登录。',
                'authentication_required',
              );
            },
          ),
        );
        await expectLater(
          auth.developmentVerificationMailbox(),
          throwsA(
            isA<RepositoryException>().having(
              (e) => e.message,
              'message',
              '请先登录。',
            ),
          ),
        );
        expect(auth.signedIn, isFalse);
      },
    );

    for (final url in [
      'http://localhost:8787/#/reset-password?token=secret-reset',
      'http://localhost:8787/#/verify-email',
      'javascript:alert(1)',
    ]) {
      test(
        'development mailbox rejects an invalid verification link: $url',
        () async {
          final client = Dio();
          final auth = _recoveryAuth(client)..session = _recoverySession();
          client.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                _recoveryResolve(options, handler, {
                  'deliveryMode': 'local',
                  'message': 'local mail',
                  'mail': {
                    'subject': 'mail',
                    'verificationUrl': url,
                    'expiresAt': DateTime.now().toUtc().toIso8601String(),
                  },
                });
              },
            ),
          );
          await expectLater(
            auth.developmentVerificationMailbox(),
            throwsA(isA<RepositoryException>()),
          );
        },
      );
    }

    for (final cookie in [false, true]) {
      test(
        '${cookie ? 'cookie' : 'native'} email verification refreshes and persists me without losing credentials',
        () async {
          final client = Dio();
          final preferences = SharedPreferencesAsync();
          final auth = _recoveryAuth(client, preferences: preferences)
            ..session = _recoverySession(cookie: cookie);
          final paths = <String>[];
          client.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                paths.add(options.path);
                expect(
                  options.headers['Authorization'],
                  cookie ? isNull : 'Bearer token-a',
                );
                expect(options.headers['X-CSRF-Token'], 'csrf-a');
                if (options.path.endsWith('/confirm')) {
                  expect(options.data, {'token': 'one-use-a'});
                  _recoveryResolve(options, handler, {'verified': true});
                } else {
                  expect(options.path, '/api/v1/auth/me');
                  final body = _recoverySession(
                    cookie: cookie,
                    verified: true,
                  ).toJson()..remove('token');
                  _recoveryResolve(options, handler, body);
                }
              },
            ),
          );
          await auth.confirmEmailVerification('one-use-a');
          expect(paths, [
            '/api/v1/auth/email/verification/confirm',
            '/api/v1/auth/me',
          ]);
          expect(auth.session!.user.emailVerified, isTrue);
          expect(auth.session!.sessionId, 'session-a');
          expect(auth.session!.cookieSession, cookie);
          expect(auth.token, cookie ? isNull : 'token-a');
          expect(auth.csrfToken, 'csrf-a');
          expect(auth.onlineVerified, isTrue);
          final stored = jsonDecode(
            (await preferences.getString(
              'sera.auth.session.http://recovery.test',
            ))!,
          ) as Map;
          expect((stored['user'] as Map)['emailVerified'], isTrue);
          expect(stored['token'], cookie ? '' : 'token-a');
          expect(stored['sessionId'], 'session-a');
        },
      );
    }

    test('verification can retry me after a confirmed token and temporary refresh failure', () async {
      final client = Dio();
      final auth = _recoveryAuth(client)..session = _recoverySession();
      var confirmations = 0;
      var meRequests = 0;
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.endsWith('/confirm')) {
              confirmations++;
              _recoveryResolve(options, handler, {'verified': true});
            } else if (++meRequests == 1) {
              _recoveryReject(
                options,
                handler,
                503,
                '账号资料暂时无法刷新。',
                'unavailable',
              );
            } else {
              _recoveryResolve(
                options,
                handler,
                _recoverySession(verified: true).toJson(),
              );
            }
          },
        ),
      );
      await expectLater(
        auth.confirmEmailVerification('one-use-a'),
        throwsA(isA<RepositoryException>()),
      );
      expect(auth.signedIn, isTrue);
      expect(auth.session!.user.emailVerified, isFalse);
      await auth.refreshCurrentUser();
      expect(auth.session!.user.emailVerified, isTrue);
      expect(auth.error, isNull);
      expect(
        confirmations,
        1,
        reason: 'An already consumed token need not be reused.',
      );
      expect(meRequests, 2);
    });

    test(
      'late me from account A never overwrites account B or its storage',
      () async {
        final client = Dio();
        final preferences = SharedPreferencesAsync();
        final auth = _recoveryAuth(client, preferences: preferences)
          ..session = _recoverySession();
        final entered = Completer<void>();
        final release = Completer<void>();
        client.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) async {
              entered.complete();
              await release.future;
              _recoveryResolve(
                options,
                handler,
                _recoverySession(verified: true).toJson(),
              );
            },
          ),
        );
        final pending = expectLater(
          auth.refreshCurrentUser(),
          throwsA(isA<RepositoryException>()),
        );
        await entered.future;
        final next = _recoverySession(id: 'b');
        auth.session = next;
        await preferences.setString(
          'sera.auth.session.http://recovery.test',
          jsonEncode(next.toJson()),
        );
        release.complete();
        await pending;
        expect(auth.session!.user.id, 'b');
        expect(auth.session!.user.emailVerified, isFalse);
        final stored = jsonDecode(
          (await preferences.getString(
            'sera.auth.session.http://recovery.test',
          ))!,
        ) as Map;
        expect((stored['user'] as Map)['id'], 'b');
        expect(auth.error, isNull);
      },
    );

    for (final differentSession in [false, true]) {
      test(
        'refresh refuses ${differentSession ? 'another session' : 'another account'} from me',
        () async {
          final client = Dio();
          final auth = _recoveryAuth(client)..session = _recoverySession();
          client.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                final body = _recoverySession(
                  id: differentSession ? 'a' : 'b',
                  verified: true,
                ).toJson();
                if (differentSession) body['sessionId'] = 'unexpected-session';
                _recoveryResolve(options, handler, body);
              },
            ),
          );
          await expectLater(
            auth.refreshCurrentUser(),
            throwsA(isA<RepositoryException>()),
          );
          expect(auth.session!.user.id, 'a');
          expect(auth.session!.sessionId, 'session-a');
          expect(auth.session!.user.emailVerified, isFalse);
        },
      );
    }

    for (final code in ['token_expired', 'token_used', 'wrong_account']) {
      test(
        '$code verification failure cannot mark the email verified',
        () async {
          final client = Dio();
          final auth = _recoveryAuth(client)..session = _recoverySession();
          var requests = 0;
          client.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                requests++;
                expect(options.path, '/api/v1/auth/email/verification/confirm');
                _recoveryReject(options, handler, 400, '链接无效，请重新发送。', code);
              },
            ),
          );
          await expectLater(
            auth.confirmEmailVerification('bad-token'),
            throwsA(
              isA<RepositoryException>().having(
                (e) => e.message,
                'message',
                contains('链接无效'),
              ),
            ),
          );
          expect(requests, 1);
          expect(auth.signedIn, isTrue);
          expect(auth.session!.user.emailVerified, isFalse);
        },
      );
    }

    for (final body in <Json>[
      {},
      {'verified': false},
    ]) {
      test('verification rejects an unconfirmed success body $body', () async {
        final client = Dio();
        final auth = _recoveryAuth(client)..session = _recoverySession();
        var requests = 0;
        client.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests++;
              _recoveryResolve(options, handler, body);
            },
          ),
        );
        await expectLater(
          auth.confirmEmailVerification('token'),
          throwsA(isA<RepositoryException>()),
        );
        expect(requests, 1);
        expect(auth.session!.user.emailVerified, isFalse);
      });
    }

    test('successful password reset clears the session and persists signed-out state', () async {
      final client = Dio();
      final preferences = SharedPreferencesAsync();
      final auth = _recoveryAuth(client, preferences: preferences)
        ..session = _recoverySession();
      const key = 'sera.auth.session.http://recovery.test';
      await preferences.setString(key, jsonEncode(auth.session!.toJson()));
      var requests = 0;
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests++;
            expect(options.path, '/api/v1/auth/password/reset/confirm');
            expect(options.data, {
              'token': 'reset-a',
              'password': 'new-secret-password',
            });
            _recoveryResolve(options, handler, {'reset': true});
          },
        ),
      );
      await auth.resetPassword(
        token: 'reset-a',
        password: 'new-secret-password',
      );
      expect(auth.signedIn, isFalse);
      expect(auth.token, isNull);
      expect(await preferences.getString(key), isNull);
      expect(await preferences.getString('$key.signed-out'), 'true');
      final reopened = _recoveryAuth(client, preferences: preferences);
      await reopened.initialize();
      expect(reopened.signedIn, isFalse);
      expect(
        requests,
        1,
        reason: 'A reset session must not be restored from cached metadata.',
      );
      expect(
        jsonEncode(await preferences.getAll()),
        isNot(contains('new-secret-password')),
      );
    });

    for (final body in <Json>[
      {},
      {'reset': false},
    ]) {
      test(
        'password reset does not clear a session for an unconfirmed response $body',
        () async {
          final client = Dio();
          final auth = _recoveryAuth(client)..session = _recoverySession();
          client.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                _recoveryResolve(options, handler, body);
              },
            ),
          );
          await expectLater(
            auth.resetPassword(
              token: 'reset-a',
              password: 'new-secret-password',
            ),
            throwsA(isA<RepositoryException>()),
          );
          expect(auth.token, 'token-a');
          expect(auth.session!.user.id, 'a');
        },
      );
    }

    for (final status in [400, 410, 429, 503]) {
      test(
        'password reset HTTP $status preserves the session for recovery',
        () async {
          final client = Dio();
          final auth = _recoveryAuth(client)..session = _recoverySession();
          client.interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                _recoveryReject(
                  options,
                  handler,
                  status,
                  '重置未完成，请重试。',
                  'reset_failed',
                );
              },
            ),
          );
          await expectLater(
            auth.resetPassword(
              token: 'reset-a',
              password: 'new-secret-password',
            ),
            throwsA(
              isA<RepositoryException>().having(
                (e) => e.message,
                'message',
                contains('重置未完成'),
              ),
            ),
          );
          expect(auth.token, 'token-a');
        },
      );
    }
  });
}

class _SlowAuthSessionStorage implements AuthSessionStorage {
  static const sessionKey = 'sera.auth.session.http://recovery.test';
  final values = <String, String>{};
  final refreshWriteEntered = Completer<void>();
  final releaseRefreshWrite = Completer<void>();
  bool _delayedRefresh = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (key == sessionKey && !_delayedRefresh) {
      final body = jsonDecode(value) as Map;
      final user = body['user'] as Map;
      if (user['id'] == 'a' && user['emailVerified'] == true) {
        _delayedRefresh = true;
        refreshWriteEntered.complete();
        await releaseRefreshWrite.future;
      }
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

AuthRepository _recoveryAuth(
  Dio client, {
  SharedPreferencesAsync? preferences,
}) {
  final auth = AuthRepository(
    apiBaseUrl: 'http://recovery.test',
    client: client,
    preferences: preferences ?? SharedPreferencesAsync(),
  );
  addTearDown(auth.dispose);
  return auth;
}

AuthSession _recoverySession({
  String id = 'a',
  bool cookie = false,
  bool verified = false,
}) => AuthSession(
  token: cookie ? '' : 'token-$id',
  csrfToken: 'csrf-$id',
  cookieSession: cookie,
  sessionId: 'session-$id',
  expiresAt: DateTime.now().add(const Duration(days: 1)),
  user: AuthUser(
    id: id,
    username: id,
    email: '$id@example.test',
    emailVerified: verified,
  ),
);

void _recoveryResolve(
  RequestOptions options,
  RequestInterceptorHandler handler,
  Json body,
) {
  handler.resolve(
    Response<dynamic>(requestOptions: options, data: body, statusCode: 200),
  );
}

void _recoveryReject(
  RequestOptions options,
  RequestInterceptorHandler handler,
  int status,
  String message,
  String code,
) {
  handler.reject(
    DioException(
      requestOptions: options,
      type: DioExceptionType.badResponse,
      response: Response<dynamic>(
        requestOptions: options,
        statusCode: status,
        data: {'error': message, 'code': code},
      ),
    ),
  );
}

Future<void> _eventually(bool Function() predicate) async {
  for (var attempt = 0; attempt < 200 && !predicate(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(predicate(), isTrue);
}

class _AccountHub {
  final ports = <_AccountPort>[];
  final published = <AccountEvent>[];
  AccountEventChannel port() {
    final value = _AccountPort(this);
    ports.add(value);
    return value;
  }
}

class _AccountPort implements AccountEventChannel {
  _AccountPort(this.hub);
  final _AccountHub hub;
  final controller = StreamController<AccountEvent>.broadcast(sync: true);
  @override
  Stream<AccountEvent> get events => controller.stream;
  @override
  void publish(AccountEvent event) {
    hub.published.add(event);
    for (final peer in hub.ports) {
      if (!identical(peer, this) && !peer.controller.isClosed) {
        peer.controller.add(event);
      }
    }
  }

  @override
  void dispose() {
    unawaited(controller.close());
  }
}
