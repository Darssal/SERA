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

const _failure = '隔离测试：操作未完成，请保留输入后重试。';
const _keyboard = 260.0;

void main() {
  for (final scenario in [
    ('login', '登录', '请输入邮箱或用户名。'),
    ('register', '创建账户并开始', '用户名需要 3–40 个中文、字母、数字、下划线或连字符。'),
    ('forgot-password', '发送重置邮件', '请输入有效的电子邮箱。'),
    ('reset-password', '保存新密码', '请粘贴邮件中的完整链接。'),
    ('verify-email', '确认验证邮箱', '请粘贴邮件中的完整链接。'),
  ]) {
    testWidgets(
      '${scenario.$1} exposes its action and first error at 320px, large text and keyboard',
      (tester) async {
        final h = _Harness();
        await _pump(tester, h, '/${scenario.$1}');
        final field = find.byType(TextFormField).first;
        await tester.ensureVisible(field);
        await tester.tap(field);
        await _frames(tester);
        await _tap(tester, scenario.$2);
        // Do not scroll to the error in the test: the form must reveal it.
        _visible(tester, find.text(scenario.$3));
        expect(
          h.requests,
          isEmpty,
          reason: 'Local validation must not call an API.',
        );
        _scrolls(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final binding in [false, true]) {
    testWidgets(
      '${binding ? 'bind-phone' : 'phone-login'} keeps verification and its failure reachable with large text and keyboard',
      (tester) async {
        final h = _Harness();
        await _pump(
          tester,
          h,
          binding ? '/bind-phone' : '/phone-login',
          session: binding ? _session(phone: null, hasPassword: true) : null,
        );
        await _fill(
          tester,
          find.byKey(const ValueKey('phone-number')),
          '13800138000',
        );
        if (binding) {
          await _fill(
            tester,
            find.byKey(const ValueKey('phone-current-password')),
            'synthetic-current-password',
          );
        }
        await _tap(tester, '获取短信验证码');
        await _fill(tester, find.byKey(const ValueKey('phone-code')), '451236');
        await _tap(tester, binding ? '确认绑定手机号' : '验证并登录');
        _visible(tester, find.text(_failure));
        expect(
          _fieldText(tester, find.byKey(const ValueKey('phone-code'))),
          '451236',
        );
        expect(
          h.requests.where((request) => request.path.endsWith('/challenge')),
          hasLength(1),
        );
        expect(
          h.requests.where(
            (request) => request.path.endsWith(binding ? '/bind' : '/login'),
          ),
          hasLength(1),
        );
        _scrolls(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'phone-identity email action reveals its missing-proof error without sending mail',
    (tester) async {
      final h = _Harness();
      await _pump(tester, h, '/phone-identity', session: _session(email: ''));
      await _fill(tester, _input('待绑定电子邮箱'), 'candidate@example.test');
      await _tap(tester, '发送绑定邮箱邮件');
      _visible(tester, find.text('请先验证当前手机号，再完成本次操作。'));
      expect(_fieldText(tester, _input('待绑定电子邮箱')), 'candidate@example.test');
      expect(h.requests.every((request) => request.method == 'GET'), isTrue);
      _scrolls(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'phone-email confirmation retains its link and exposes failure above the keyboard',
    (tester) async {
      final h = _Harness();
      await _pump(
        tester,
        h,
        '/phone-email?token=synthetic-binding-token',
        session: _session(email: ''),
      );
      await _tap(tester, '确认绑定电子邮箱');
      _visible(tester, find.text(_failure));
      expect(_fieldText(tester, _input('邮件中的绑定链接')), 'synthetic-binding-token');
      expect(
        h.requests
            .where((request) => request.method == 'POST')
            .map((request) => request.path),
        ['/api/v1/auth/email/bind/confirm'],
      );
      _scrolls(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'phone-identity password editor keeps both values and reveals mismatch after actual proof flow',
    (tester) async {
      final h = _Harness();
      await _pump(
        tester,
        h,
        '/phone-identity',
        session: _session(hasPassword: true),
      );
      await _tap(tester, '获取短信验证码');
      await _fill(tester, find.byKey(const ValueKey('phone-code')), '451236');
      await _tap(tester, '验证当前手机号');
      final password = find.byKey(const ValueKey('identity-new-password'));
      final confirmation = find.byKey(
        const ValueKey('identity-confirm-password'),
      );
      await _fill(tester, password, 'synthetic-new-password');
      await _fill(tester, confirmation, 'different-new-password');
      await _tap(tester, '重设账户密码');
      _visible(tester, find.text('两次输入的密码不一致。'));
      expect(_fieldText(tester, password), 'synthetic-new-password');
      expect(_fieldText(tester, confirmation), 'different-new-password');
      expect(
        h.requests.where(
          (request) => request.path.endsWith('/verify-sensitive'),
        ),
        hasLength(1),
      );
      expect(
        h.requests.where((request) => request.path.endsWith('/password/set')),
        isEmpty,
      );
      expect(find.textContaining('synthetic-sensitive-proof'), findsNothing);
      _scrolls(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account export action and failure are reachable below long identity content',
    (tester) async {
      final h = _Harness();
      await _pump(tester, h, '/account', session: _session(hasPassword: true));
      await _tap(tester, '准备账户备份');
      _visible(tester, find.text(_failure));
      expect(h.requests.map((request) => request.path), [
        '/api/v1/account/export',
      ]);
      expect(h.auth.signedIn, isTrue);
      _scrolls(tester);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  _Harness h,
  String location, {
  AuthSession? session,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 568);
  tester.view.viewInsets = const FakeViewPadding(bottom: _keyboard);
  tester.platformDispatcher.textScaleFactorTestValue = 1.5;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  if (session != null) h.adopt(session);
  final router = GoRouter(
    initialLocation: location,
    routes: [
      for (final name in [
        'login',
        'register',
        'account',
        'verify-email',
        'forgot-password',
        'reset-password',
        'phone-login',
        'bind-phone',
        'phone-identity',
        'phone-email',
      ])
        GoRoute(
          path: '/$name',
          builder: (_, state) => buildAccountScreen(
            name,
            token: state.uri.queryParameters['token'],
          ),
        ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    h.auth.dispose();
    h.client.close(force: true);
    expect(h.unexpected, isEmpty);
  });
  await tester.pumpWidget(
    ChangeNotifierProvider<AuthRepository>.value(
      value: h.auth,
      child: MaterialApp.router(theme: seraTheme(), routerConfig: router),
    ),
  );
  await _frames(tester);
  final context = tester.element(find.byType(Scaffold));
  expect(MediaQuery.textScalerOf(context).scale(10), 15);
  expect(MediaQuery.viewInsetsOf(context).bottom, _keyboard);
  expect(tester.takeException(), isNull);
}

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder _input(String label) => find.descendant(
  of: find.widgetWithText(SeraInput, label),
  matching: find.byType(TextFormField),
);

String _fieldText(WidgetTester tester, Finder field) =>
    tester.widget<TextFormField>(field).controller!.text;

Future<void> _fill(WidgetTester tester, Finder field, String value) async {
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await _frames(tester);
}

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.pump();
  final action = find.widgetWithText(SeraButton, label);
  final button = action.evaluate().isEmpty
      ? find.widgetWithText(ListTile, label)
      : action;
  expect(button, findsOneWidget);
  await tester.ensureVisible(button);
  await _frames(tester);
  _visible(tester, button);
  final widget = tester.widget(button);
  expect(
    widget is SeraButton ? widget.onPressed : (widget as ListTile).onTap,
    isNotNull,
  );
  await tester.tap(button);
  await _frames(tester);
}

void _visible(WidgetTester tester, Finder target) {
  expect(target, findsOneWidget);
  expect(target.hitTestable(), findsOneWidget);
  final bounds = tester.getRect(target);
  final viewport = tester.getRect(find.byType(SingleChildScrollView).first);
  expect(bounds.top, greaterThanOrEqualTo(viewport.top - 1));
  expect(bounds.bottom, lessThanOrEqualTo(568 - _keyboard + 1));
  expect(bounds.left, greaterThanOrEqualTo(0));
  expect(bounds.right, lessThanOrEqualTo(320));
}

void _scrolls(WidgetTester tester) {
  final scrollable = find
      .descendant(
        of: find.byType(SingleChildScrollView).first,
        matching: find.byType(Scrollable),
      )
      .first;
  expect(
    tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
    greaterThan(0),
  );
}

AuthSession _session({
  String? phone = '13800138000',
  String email = 'layout-owner@example.test',
  bool hasPassword = false,
}) => AuthSession(
  token: 'synthetic-layout-session',
  sessionId: 'layout-session',
  expiresAt: DateTime.now().add(const Duration(days: 1)),
  user: AuthUser(
    id: 'layout-owner',
    username: '窄屏账户测试用户',
    email: email,
    emailVerified: email.isNotEmpty,
    phone: phone,
    hasPassword: hasPassword,
  ),
);

class _Harness {
  _Harness() {
    client.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          Map<String, dynamic>? body;
          if (options.path.endsWith('/capabilities')) {
            body = {
              'enabled': true,
              'message': '隔离测试短信能力',
              'codeLength': 6,
              'cooldownSeconds': 60,
            };
          } else if (options.path.endsWith('/challenge')) {
            body = {
              'challengeId': 'synthetic-challenge',
              'maskedPhone': '138****8000',
              'expiresAt': DateTime.now()
                  .add(const Duration(minutes: 5))
                  .toUtc()
                  .toIso8601String(),
              'resendAt': DateTime.now()
                  .add(const Duration(minutes: 1))
                  .toUtc()
                  .toIso8601String(),
              'deliveryStatus': 'submitted',
              'message': '隔离测试发送回执，无真实短信。',
            };
          } else if (options.path.endsWith('/verify-sensitive')) {
            body = {
              'phoneProof': 'synthetic-sensitive-proof',
              'expiresIn': 300,
            };
          }
          if (body != null) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: body,
              ),
            );
            return;
          }
          if (!const {
            '/api/v1/auth/phone/login',
            '/api/v1/auth/phone/bind',
            '/api/v1/auth/email/bind/confirm',
            '/api/v1/account/export',
          }.contains(options.path)) {
            unexpected.add('${options.method} ${options.path}');
          }
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response: Response<dynamic>(
                requestOptions: options,
                statusCode: 400,
                data: {'error': _failure},
              ),
            ),
          );
        },
      ),
    );
    auth = AuthRepository(
      apiBaseUrl: 'http://account-layout.invalid',
      client: client,
      storage: storage,
      accountEvents: _Events(),
    );
  }
  final client = Dio();
  final requests = <RequestOptions>[];
  final unexpected = <String>[];
  final storage = _Storage();
  late final AuthRepository auth;

  void adopt(AuthSession session) {
    auth.session = session;
    storage.values['sera.auth.session.http://account-layout.invalid'] =
        jsonEncode(session.toJson());
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
  final _events = StreamController<AccountEvent>.broadcast();
  @override
  Stream<AccountEvent> get events => _events.stream;
  @override
  void publish(AccountEvent event) {}
  @override
  void dispose() {
    unawaited(_events.close());
  }
}
