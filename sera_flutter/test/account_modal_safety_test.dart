import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:sera_flutter/ui/screens/account_screens.dart';

void main() {
  testWidgets(
    'registration reveals the first invalid field on a short viewport',
    (tester) async {
      final harness = _Harness((options, handler) {
        fail('Invalid registration must not contact the API.');
      });
      await _pump(
        tester,
        harness,
        location: '/register',
        size: const Size(320, 568),
      );
      await _tap(tester, '创建账户并开始');
      final firstError = find.text('用户名需要 3–40 个中文、字母、数字、下划线或连字符。');
      expect(firstError, findsOneWidget);
      final bounds = tester.getRect(firstError);
      expect(bounds.top, greaterThanOrEqualTo(0));
      expect(bounds.bottom, lessThanOrEqualTo(568));
      expect(harness.requests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final switchAccount in [false, true]) {
    testWidgets(
      'late deletion ${switchAccount ? 'preserves a newer account' : 'does not leave a covering route'}',
      (tester) async {
        final entered = Completer<void>(), release = Completer<void>();
        final harness = _Harness((options, handler) async {
          expect(options.method, 'DELETE');
          expect(options.path, '/api/v1/account');
          entered.complete();
          await release.future;
          _reply(options, handler, {'deleted': true});
        });
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        harness.adopt(_session());
        final router = await _pump(tester, harness);
        final heading = find
            .descendant(
              of: find.widgetWithText(SeraDisclosure, '删除账户与数据'),
              matching: find.text('删除账户与数据'),
            )
            .first;
        await tester.ensureVisible(heading);
        await tester.tap(heading);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField), 'current-password');
        await _tap(tester, '删除账户与数据');
        await tester.tap(find.widgetWithText(TextButton, '确认删除'));
        await _waitFor(tester, entered);
        if (switchAccount) {
          harness.adopt(_session(id: 'new-account'));
        } else {
          unawaited(router.push<void>('/covered'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
        }
        release.complete();
        await tester.pumpAndSettle();
        expect(
          router.routerDelegate.state.uri.path,
          switchAccount ? '/account' : '/covered',
        );
        if (switchAccount) {
          expect(harness.auth.session!.user.id, 'new-account');
          expect(harness.auth.deletedUserId, isNull);
          expect(harness.storage.values.values.single, contains('new-account'));
        } else {
          expect(harness.auth.session, isNull);
          expect(harness.auth.deletedUserId, 'account-user');
          expect(find.byKey(const ValueKey('covered-page')), findsOneWidget);
        }
        expect(harness.requests, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'late logout ${switchAccount ? 'keeps a newer session' : 'does not navigate a covered account page'}',
      (tester) async {
        final entered = Completer<void>(), release = Completer<void>();
        final harness = _Harness((options, handler) async {
          expect(options.path, '/api/v1/auth/logout');
          entered.complete();
          await release.future;
          _reply(options, handler, {});
        });
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        harness.adopt(_session());
        final router = await _pump(tester, harness);
        await _tap(tester, '退出登录', settle: false);
        await _waitFor(tester, entered);
        if (switchAccount) {
          harness.adopt(_session(id: 'new-account'));
        } else {
          unawaited(router.push<void>('/covered'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
        }
        release.complete();
        await tester.pumpAndSettle();
        expect(
          router.routerDelegate.state.uri.path,
          switchAccount ? '/account' : '/covered',
        );
        if (switchAccount) {
          expect(harness.auth.session!.user.id, 'new-account');
          expect(harness.storage.values.values.single, contains('new-account'));
        } else {
          expect(harness.auth.session, isNull);
          expect(find.byKey(const ValueKey('covered-page')), findsOneWidget);
        }
        expect(harness.requests, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<GoRouter> _pump(
  WidgetTester tester,
  _Harness harness, {
  String location = '/account',
  Size size = const Size(390, 844),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: location,
    routes: [
      for (final mode in ['account', 'register', 'login'])
        GoRoute(
          path: '/$mode',
          builder: (_, _) => AccountScreen(mode: mode),
        ),
      GoRoute(
        path: '/covered',
        builder: (_, _) => const Scaffold(
          body: Text('covered', key: ValueKey('covered-page')),
        ),
      ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    router.dispose();
    harness.auth.dispose();
  });
  await tester.pumpWidget(
    ChangeNotifierProvider<AuthRepository>.value(
      value: harness.auth,
      child: MaterialApp.router(theme: seraTheme(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

Future<void> _tap(
  WidgetTester tester,
  String label, {
  bool settle = true,
}) async {
  await tester.pump();
  final action = find.widgetWithText(SeraButton, label);
  final button = action.evaluate().isEmpty
      ? find.widgetWithText(ListTile, label)
      : action;
  await tester.ensureVisible(button);
  await tester.pump();
  final widget = tester.widget(button);
  expect(
    widget is SeraButton ? widget.onPressed : (widget as ListTile).onTap,
    isNotNull,
  );
  await tester.tap(button);
  await tester.pump();
  if (settle) await tester.pumpAndSettle();
}

Future<void> _waitFor(WidgetTester tester, Completer<void> entered) async {
  for (var i = 0; i < 50 && !entered.isCompleted; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(entered.isCompleted, isTrue);
}

AuthSession _session({String id = 'account-user'}) => AuthSession(
  token: 'session-$id',
  sessionId: 'id-$id',
  expiresAt: DateTime.now().add(const Duration(days: 1)),
  user: AuthUser(
    id: id,
    username: id,
    email: '$id@example.test',
    emailVerified: true,
    hasPassword: true,
  ),
);

class _Harness {
  _Harness(
    FutureOr<void> Function(RequestOptions, RequestInterceptorHandler) handle,
  ) {
    final client = Dio();
    addTearDown(() => expect(interceptorErrors, isEmpty));
    client.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          requests.add(options);
          try {
            await handle(options, handler);
          } catch (error, stackTrace) {
            interceptorErrors.add(error);
            if (!handler.isCompleted) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  error: error,
                  stackTrace: stackTrace,
                ),
              );
            }
          }
        },
      ),
    );
    auth = AuthRepository(
      apiBaseUrl: 'http://account-polish.test',
      client: client,
      storage: storage,
      accountEvents: _Events(),
    );
  }
  final requests = <RequestOptions>[];
  final interceptorErrors = <Object>[];
  final storage = _Storage();
  late final AuthRepository auth;
  void adopt(AuthSession session) {
    auth.session = session;
    storage.values['sera.auth.session.http://account-polish.test'] = jsonEncode(
      session.toJson(),
    );
  }
}

class _Storage implements AuthSessionStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _Events implements AccountEventChannel {
  final controller = StreamController<AccountEvent>.broadcast();
  @override
  Stream<AccountEvent> get events => controller.stream;
  @override
  void publish(AccountEvent event) {}
  @override
  void dispose() {
    unawaited(controller.close());
  }
}

void _reply(
  RequestOptions options,
  RequestInterceptorHandler handler,
  Map<String, dynamic> body,
) => handler.resolve(
  Response<dynamic>(requestOptions: options, statusCode: 200, data: body),
);
