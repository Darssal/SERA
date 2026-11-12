import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:sera_flutter/ui/screens/account_screens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets(
    'a pending confirmation cannot clear the token from a newer verification link',
    (tester) async {
      final client = Dio();
      final auth = _auth(client, signedIn: false);
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      var confirmations = 0;
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            expect(options.path, '/api/v1/auth/email/verification/confirm');
            confirmations++;
            if (confirmations == 1) {
              expect(options.data, {'token': 'old-pending-token'});
              entered.complete();
              await release.future;
            } else {
              expect(options.data, {'token': 'new-query-token'});
            }
            _respond(options, handler, {'verified': true});
          },
        ),
      );
      final router = await _pumpAccount(
        tester,
        auth,
        '/verify-email?token=old-pending-token',
      );
      await _tap(tester, '确认验证邮箱', settle: false);
      for (var attempt = 0; attempt < 100 && !entered.isCompleted; attempt++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(
        entered.isCompleted,
        isTrue,
        reason: 'The confirmation request must enter the interceptor before switching links.',
      );
      router.go('/verify-email?token=new-query-token');
      await tester.pumpAndSettle();
      expect(_fieldText(tester), 'new-query-token');
      release.complete();
      await tester.pumpAndSettle();
      expect(
        _fieldText(tester),
        'new-query-token',
        reason: 'Only the generation that submitted the token may clear it.',
      );
      expect(find.text('邮箱已验证，请登录账户查看。'), findsNothing);
      expect(tester.widget<SeraButton>(_button('确认验证邮箱')).onPressed, isNotNull);
      await _tap(tester, '确认验证邮箱');
      expect(confirmations, 2);
      expect(find.text('邮箱已验证，请登录账户查看。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local verification follows the displayed link and refreshes the account',
    (tester) async {
      final client = Dio();
      final auth = _auth(client);
      final requests = <RequestOptions>[];
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            switch (options.path) {
              case '/api/v1/auth/email/verification/request':
                _respond(options, handler, _localDelivery());
              case '/api/v1/auth/development-mailbox?purpose=verify-email':
                _respond(options, handler, _mailbox('local-token-a'));
              case '/api/v1/auth/email/verification/confirm':
                expect(options.data, {'token': 'local-token-a'});
                _respond(options, handler, {'verified': true});
              case '/api/v1/auth/me':
                _respond(options, handler, _session(verified: true).toJson());
              default:
                fail('Unexpected request: ${options.path}');
            }
          },
        ),
      );
      await _pumpAccount(tester, auth, '/verify-email');
      expect(find.text('测试验证邮件'), findsNothing);
      await _tap(tester, '发送验证邮件');
      expect(find.text('SERA 本地验证邮件'), findsOneWidget);
      expect(find.textContaining('未发送到外部收件箱'), findsWidgets);
      expect(
        find.text('http://localhost:8787/#/verify-email?token=local-token-a'),
        findsOneWidget,
      );
      expect(find.textContaining('有效期至'), findsOneWidget);
      await _tap(tester, '使用此链接验证邮箱');
      expect(auth.session!.user.emailVerified, isTrue);
      expect(auth.token, 'native-session');
      expect(find.text('邮箱验证成功。'), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      expect(_button('重新发送验证邮件'), findsNothing);
      expect(_button('刷新验证状态'), findsNothing);
      expect(requests.map((e) => e.path), [
        '/api/v1/auth/email/verification/request',
        '/api/v1/auth/development-mailbox?purpose=verify-email',
        '/api/v1/auth/email/verification/confirm',
        '/api/v1/auth/me',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'resending local verification replaces the old link with the newest token',
    (tester) async {
      final client = Dio();
      final auth = _auth(client);
      var sends = 0;
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.endsWith('/request')) {
              sends++;
              _respond(options, handler, _localDelivery());
            } else if (options.path.contains('/development-mailbox')) {
              _respond(options, handler, _mailbox('local-token-$sends'));
            } else if (options.path.endsWith('/confirm')) {
              expect(options.data, {'token': 'local-token-2'});
              _respond(options, handler, {'verified': true});
            } else {
              expect(options.path, '/api/v1/auth/me');
              _respond(options, handler, _session(verified: true).toJson());
            }
          },
        ),
      );
      await _pumpAccount(tester, auth, '/verify-email');
      await _tap(tester, '发送验证邮件');
      expect(find.textContaining('token=local-token-1'), findsOneWidget);
      await _tap(tester, '重新发送验证邮件');
      expect(sends, 2);
      expect(find.textContaining('token=local-token-1'), findsNothing);
      expect(find.textContaining('token=local-token-2'), findsOneWidget);
      await _tap(tester, '使用此链接验证邮箱');
      expect(auth.session!.user.emailVerified, isTrue);
    },
  );

  testWidgets(
    'SMTP status is displayed honestly and the development mailbox is never fetched automatically',
    (tester) async {
      final client = Dio();
      final auth = _auth(client);
      var mailboxRequests = 0;
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.contains('/development-mailbox')) {
              mailboxRequests++;
              _reject(options, handler, 403, '当前邮件模式不提供开发邮箱。');
            } else {
              expect(options.path, '/api/v1/auth/email/verification/request');
              _respond(options, handler, {
                'deliveryMode': 'smtp',
                'deliveryStatus': 'smtp_accepted',
                'developmentPreview': false,
                'message': '邮件服务器已接受验证邮件，请检查收件箱和垃圾邮件。',
              });
            }
          },
        ),
      );
      await _pumpAccount(tester, auth, '/verify-email');
      await _tap(tester, '发送验证邮件');
      expect(find.text('邮件服务器已接受验证邮件，请检查收件箱和垃圾邮件。'), findsOneWidget);
      expect(find.textContaining('已发送到邮箱'), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
      expect(mailboxRequests, 0);
      expect(find.text('测试验证邮件'), findsNothing);
      expect(_button('查看测试验证邮件'), findsNothing);
      expect(mailboxRequests, 0);
      expect(find.byType(SelectableText), findsNothing);
    },
  );

  testWidgets(
    'verification delivery failure preserves a pasted token and allows retry',
    (tester) async {
      final client = Dio();
      final auth = _auth(client);
      var attempts = 0;
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.path, '/api/v1/auth/email/verification/request');
            if (++attempts == 1) {
              _reject(options, handler, 503, 'SMTP 暂时不可用，请稍后重试。');
            } else {
              _respond(options, handler, {
                'deliveryMode': 'smtp',
                'deliveryStatus': 'smtp_accepted',
                'developmentPreview': false,
                'message': '邮件服务器已接受请求。',
              });
            }
          },
        ),
      );
      await _pumpAccount(tester, auth, '/verify-email?token=keep-pasted-token');
      await _tap(tester, '发送验证邮件');
      expect(find.textContaining('SMTP 暂时不可用'), findsOneWidget);
      expect(_fieldText(tester), 'keep-pasted-token');
      expect(auth.session!.user.emailVerified, isFalse);
      await _tap(tester, '发送验证邮件');
      expect(attempts, 2);
      expect(find.text('邮件服务器已接受请求。'), findsOneWidget);
      expect(find.textContaining('SMTP 暂时不可用'), findsNothing);
      expect(_fieldText(tester), 'keep-pasted-token');
    },
  );

  testWidgets(
    'confirmed verification can recover from me failure with refresh without consuming the token twice',
    (tester) async {
      final client = Dio();
      final auth = _auth(client);
      var confirmations = 0;
      var refreshes = 0;
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.endsWith('/confirm')) {
              confirmations++;
              _respond(options, handler, {'verified': true});
            } else {
              expect(options.path, '/api/v1/auth/me');
              if (++refreshes == 1) {
                _reject(options, handler, 503, '账户状态暂时无法刷新。');
              } else {
                _respond(options, handler, _session(verified: true).toJson());
              }
            }
          },
        ),
      );
      await _pumpAccount(tester, auth, '/verify-email?token=single-use-token');
      await _tap(tester, '确认验证邮箱');
      expect(find.textContaining('账户状态暂时无法刷新'), findsOneWidget);
      expect(_fieldText(tester), 'single-use-token');
      expect(auth.session!.user.emailVerified, isFalse);
      await _tap(tester, '刷新验证状态');
      expect(confirmations, 1);
      expect(refreshes, 2);
      expect(auth.session!.user.emailVerified, isTrue);
      expect(find.text('邮箱验证成功。'), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
    },
  );

  for (final failure in [
    '验证链接已过期，请重新发送。',
    '此验证链接属于另一个账户。',
    '验证链接已使用，请刷新账户状态。',
  ]) {
    testWidgets('$failure retains the token and does not show success', (
      tester,
    ) async {
      final client = Dio();
      final auth = _auth(client);
      var requests = 0;
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests++;
            expect(options.path, '/api/v1/auth/email/verification/confirm');
            _reject(options, handler, 400, failure);
          },
        ),
      );
      await _pumpAccount(tester, auth, '/verify-email?token=recoverable-token');
      await _tap(tester, '确认验证邮箱');
      expect(find.text(failure), findsOneWidget);
      expect(find.text('邮箱验证成功。'), findsNothing);
      expect(_fieldText(tester), 'recoverable-token');
      expect(auth.session!.user.emailVerified, isFalse);
      expect(requests, 1);
      expect(_button('发送验证邮件'), findsOneWidget);
    });
  }

  testWidgets(
    'anonymous verification uses an updated query token and exposes no mailbox or resend action',
    (tester) async {
      final client = Dio();
      final auth = _auth(client, signedIn: false);
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.path, '/api/v1/auth/email/verification/confirm');
            expect(options.data, {'token': 'new-query-token'});
            expect(options.headers.containsKey('Authorization'), isFalse);
            _respond(options, handler, {'verified': true});
          },
        ),
      );
      final router = await _pumpAccount(
        tester,
        auth,
        '/verify-email?token=old-query-token',
      );
      expect(_fieldText(tester), 'old-query-token');
      expect(_button('发送验证邮件'), findsNothing);
      expect(find.text('测试验证邮件'), findsNothing);
      router.go('/verify-email?token=new-query-token');
      await tester.pumpAndSettle();
      expect(_fieldText(tester), 'new-query-token');
      await _tap(tester, '确认验证邮箱');
      expect(find.text('邮箱已验证，请登录账户查看。'), findsOneWidget);
      expect(auth.signedIn, isFalse);
    },
  );

  testWidgets(
    'local forgotten-password responses explain non-delivery without publishing reset tokens',
    (tester) async {
      final client = Dio();
      final auth = _auth(client, signedIn: false);
      final emails = <String>[];
      const message = '如果邮箱已注册，我们会按当前邮件配置处理重置请求。';
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.path, '/api/v1/auth/password/reset/request');
            emails.add((options.data as Map)['email'] as String);
            _respond(options, handler, {
              'accepted': true,
              'deliveryMode': 'local',
              'deliveryStatus': 'request_accepted',
              'developmentPreview': false,
              'message': message,
            });
          },
        ),
      );
      await _pumpAccount(tester, auth, '/forgot-password');
      await tester.enterText(
        find.byType(TextFormField),
        ' nobody@example.test ',
      );
      await _tap(tester, '发送重置邮件');
      expect(find.text(message), findsOneWidget);
      expect(find.text('测试邮件模式'), findsOneWidget);
      expect(find.textContaining('邮件不会发送到你的邮箱'), findsOneWidget);
      expect(find.textContaining('请联系应用管理员取得重置链接'), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
      expect(find.byType(TextFormField), findsOneWidget);
      await tester.enterText(
        find.byType(TextFormField),
        'registered@example.test',
      );
      await _tap(tester, '发送重置邮件');
      expect(emails, ['nobody@example.test', 'registered@example.test']);
      expect(find.text(message), findsOneWidget);
      expect(auth.signedIn, isFalse);
    },
  );

  testWidgets(
    'reset request errors preserve email and allow retry without showing a receipt',
    (tester) async {
      final client = Dio();
      final auth = _auth(client, signedIn: false);
      var attempts = 0;
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.path, '/api/v1/auth/password/reset/request');
            if (++attempts == 1) {
              _reject(options, handler, 429, '请求过于频繁，请稍后重试。');
            } else {
              _respond(options, handler, {
                'deliveryMode': 'smtp',
                'deliveryStatus': 'request_accepted',
                'developmentPreview': false,
                'message': '重置申请已受理。',
              });
            }
          },
        ),
      );
      await _pumpAccount(tester, auth, '/forgot-password');
      await tester.enterText(find.byType(TextFormField), 'retry@example.test');
      await _tap(tester, '发送重置邮件');
      expect(find.textContaining('请求过于频繁'), findsOneWidget);
      expect(find.text('处理结果'), findsNothing);
      expect(_fieldText(tester), 'retry@example.test');
      await _tap(tester, '发送重置邮件');
      expect(attempts, 2);
      expect(find.text('重置申请已受理。'), findsOneWidget);
      expect(find.text('测试邮件模式'), findsNothing);
    },
  );

  testWidgets(
    'reset failure keeps the entered fields and a successful retry clears the session and shows login guidance',
    (tester) async {
      final client = Dio();
      final auth = _auth(client);
      var attempts = 0;
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            expect(options.path, '/api/v1/auth/password/reset/confirm');
            expect(options.data, {
              'token': 'reset-from-mail',
              'password': 'Strong-new-password',
            });
            if (++attempts == 1) {
              _reject(options, handler, 410, '重置链接已过期，请重新申请。');
            } else {
              _respond(options, handler, {'reset': true});
            }
          },
        ),
      );
      await _pumpAccount(tester, auth, '/reset-password?token=reset-from-mail');
      await tester.enterText(
        find.byType(TextFormField).at(1),
        'Strong-new-password',
      );
      await tester.enterText(
        find.byType(TextFormField).at(2),
        'Strong-new-password',
      );
      await _tap(tester, '保存新密码');
      expect(find.textContaining('重置链接已过期'), findsOneWidget);
      expect(_fieldText(tester), 'reset-from-mail');
      expect(_fieldText(tester, 1), 'Strong-new-password');
      expect(_fieldText(tester, 2), 'Strong-new-password');
      expect(auth.signedIn, isTrue);
      await _tap(tester, '保存新密码');
      expect(attempts, 2);
      expect(auth.signedIn, isFalse);
      expect(auth.lastSessionExitReason, 'password_reset');
      expect(find.text('新密码已保存，请使用新密码登录。'), findsOneWidget);
      expect(_fieldText(tester), isEmpty);
      expect(_fieldText(tester, 1), isEmpty);
      expect(_fieldText(tester, 2), isEmpty);
      await _tap(tester, '返回登录');
      expect(find.text('密码已重置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

AuthRepository _auth(Dio client, {bool signedIn = true}) {
  final auth = AuthRepository(
    apiBaseUrl: 'http://recovery-ui.test',
    client: client,
    preferences: SharedPreferencesAsync(),
  );
  if (signedIn) auth.session = _session();
  addTearDown(auth.dispose);
  return auth;
}

AuthSession _session({bool verified = false}) => AuthSession(
  token: 'native-session',
  sessionId: 'session-ui-a',
  expiresAt: DateTime.now().add(const Duration(days: 1)),
  user: AuthUser(
    id: 'user-ui-a',
    username: '账户测试',
    email: 'owner@example.test',
    emailVerified: verified,
  ),
);

Map<String, dynamic> _localDelivery() => {
  'accepted': true,
  'deliveryMode': 'local',
  'deliveryStatus': 'local_preview',
  'developmentPreview': true,
  'message': '验证邮件已保存在本地开发邮箱，未发送到外部收件箱。',
};

Map<String, dynamic> _mailbox(String token) => {
  'deliveryMode': 'local',
  'message': '仅显示当前账户的有效验证邮件。',
  'mail': {
    'subject': 'SERA 本地验证邮件',
    'verificationUrl': 'http://localhost:8787/#/verify-email?token=$token',
    'expiresAt': DateTime.now()
        .add(const Duration(minutes: 20))
        .toUtc()
        .toIso8601String(),
  },
};

void _respond(
  RequestOptions options,
  RequestInterceptorHandler handler,
  Map<String, dynamic> body,
) {
  handler.resolve(
    Response<dynamic>(requestOptions: options, data: body, statusCode: 200),
  );
}

void _reject(
  RequestOptions options,
  RequestInterceptorHandler handler,
  int status,
  String message,
) {
  handler.reject(
    DioException(
      requestOptions: options,
      type: DioExceptionType.badResponse,
      response: Response<dynamic>(
        requestOptions: options,
        statusCode: status,
        data: {'error': message, 'code': 'recovery_failure'},
      ),
    ),
  );
}

Finder _button(String label) => find.widgetWithText(SeraButton, label);

String _fieldText(WidgetTester tester, [int index = 0]) => tester
    .widget<TextFormField>(find.byType(TextFormField).at(index))
    .controller!
    .text;

Future<void> _tap(
  WidgetTester tester,
  String label, {
  bool settle = true,
}) async {
  final button = _button(label);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
  if (settle) await tester.pumpAndSettle();
}

Future<GoRouter> _pumpAccount(
  WidgetTester tester,
  AuthRepository auth,
  String location,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: location,
    routes: [
      for (final mode in [
        'login',
        'register',
        'account',
        'verify-email',
        'forgot-password',
        'reset-password',
      ])
        GoRoute(
          path: '/$mode',
          builder: (_, state) => AccountScreen(
            key: ValueKey(mode),
            mode: mode,
            token: state.uri.queryParameters['token'],
          ),
        ),
      GoRoute(
        path: '/04',
        builder: (_, _) => const Scaffold(body: Text('workspace')),
      ),
      GoRoute(
        path: '/02',
        builder: (_, _) => const Scaffold(body: Text('preferences')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: auth,
      child: MaterialApp.router(theme: seraTheme(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}
