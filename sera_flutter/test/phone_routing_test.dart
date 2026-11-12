import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/sera_motion.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:sera_flutter/ui/screens/phone_auth_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _channel = MethodChannel('com.sera/platform');

class _RoutingAuth extends AuthRepository {
  _RoutingAuth()
    : super(
        apiBaseUrl: 'http://phone-routing.invalid',
        preferences: SharedPreferencesAsync(),
      );

  final requests = <String>[];

  @override
  Future<Json> authenticatedRequest(
    String method,
    String path, {
    Object? data,
    String? contentType,
    String? idempotencyKey,
  }) async {
    requests.add('$method $path');
    if (method == 'GET' && path == '/api/v1/auth/phone/capabilities') {
      return {
        'enabled': false,
        'message': '路由测试不发送短信。',
        'codeLength': 6,
        'cooldownSeconds': 60,
      };
    }
    throw const RepositoryException('路由测试不得提交账户或短信操作。');
  }
}

class _RoutingWorkspace implements WorkspaceRepository {
  _RoutingWorkspace(this.value);
  final Workspace value;

  @override
  String get mode => 'phone-routing-test';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async {
    throw const RepositoryException('路由测试不得清空工作区。');
  }

  @override
  Future<Workspace> save(
    Workspace workspace, {
    required int expectedRevision,
  }) async {
    throw const RepositoryException('路由测试不得保存业务数据。');
  }
}

Future<_RoutingAuth> _pump(
  WidgetTester tester,
  String location, {
  bool signedIn = false,
  bool onboardingComplete = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final auth = _RoutingAuth();
  if (signedIn) {
    auth.session = AuthSession(
      token: 'routing-test-session',
      sessionId: 'routing-test-session-id',
      expiresAt: DateTime.now().add(const Duration(days: 1)),
      user: const AuthUser(
        id: 'routing-user',
        username: 'routing-user',
        email: '',
        phone: '13800138000',
        hasPassword: false,
      ),
    );
  }
  final controller = SeraController(
    repository: _RoutingWorkspace(
      Workspace(
        revision: 1,
        platformSettings: {'onboardingComplete': onboardingComplete},
      ),
    ),
    today: DateTime(2026, 10, 31),
    accountId: signedIn ? 'routing-user' : 'signed-out',
    seedDemo: false,
  );
  await controller.initialize();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    auth.dispose();
  });
  await tester.pumpWidget(
    ChangeNotifierProvider<AuthRepository>.value(
      value: auth,
      child: SeraApp(
        controller: controller,
        auth: auth,
        initialLocation: location,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
  return auth;
}

Uri _currentUri(WidgetTester tester) =>
    GoRouter.of(tester.element(find.byType(SeraScaffold).first))
        .routerDelegate
        .state
        .uri;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  testWidgets('anonymous phone login is routed to the real phone screen', (
    tester,
  ) async {
    final auth = await _pump(tester, '/phone-login');
    expect(_currentUri(tester).path, '/phone-login');
    expect(
      tester.widget<PhoneAuthScreen>(find.byType(PhoneAuthScreen)).mode,
      PhoneAuthMode.login,
    );
    expect(find.widgetWithText(SeraButton, '使用邮箱或用户名登录'), findsOneWidget);
    expect(auth.requests, ['GET /api/v1/auth/phone/capabilities']);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(_currentUri(tester).path, '/30');
    expect(find.text('登录并同步'), findsOneWidget);
    expect(auth.requests, ['GET /api/v1/auth/phone/capabilities']);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets(
    'email login inputs survive phone login fallback with the original route stack',
    (tester) async {
      final auth = await _pump(tester, '/login');
      const identifier = 'qa-retain@example.test';
      const password = 'qa-retain-only-password';
      final identifierField = find.descendant(
        of: find.widgetWithText(SeraInput, '邮箱或用户名'),
        matching: find.byType(TextFormField),
      );
      final passwordField = find.ancestor(
        of: find.byWidgetPredicate(
          (widget) => widget is TextField && widget.obscureText,
        ),
        matching: find.byType(TextFormField),
      );
      final identifierController = tester
          .widget<TextFormField>(identifierField)
          .controller;
      final passwordController = tester
          .widget<TextFormField>(passwordField)
          .controller;
      final router = GoRouter.of(
        tester.element(find.byType(SeraScaffold).first),
      );
      expect(router.canPop(), isFalse);
      await tester.enterText(identifierField, identifier);
      await tester.enterText(passwordField, password);
      final phoneLogin = find.widgetWithText(SeraButton, '使用手机号验证码登录');
      await tester.ensureVisible(phoneLogin);
      await tester.tap(phoneLogin);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(_currentUri(tester).path, '/phone-login');
      expect(router.canPop(), isTrue);
      expect(find.text('短信登录暂未启用'), findsOneWidget);
      final emailLogin = find.widgetWithText(SeraButton, '使用邮箱或用户名登录');
      await tester.ensureVisible(emailLogin);
      await tester.tap(emailLogin);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(_currentUri(tester).path, '/login');
      expect(router.canPop(), isFalse);
      expect(find.byType(PhoneAuthScreen), findsNothing);
      final restoredIdentifier = tester
          .widget<TextFormField>(identifierField)
          .controller!;
      final restoredPassword = tester
          .widget<TextFormField>(passwordField)
          .controller!;
      expect(restoredIdentifier, same(identifierController));
      expect(restoredPassword, same(passwordController));
      expect(restoredIdentifier.text, identifier);
      expect(restoredPassword.text, password);
      expect(auth.requests, ['GET /api/v1/auth/phone/capabilities']);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'anonymous phone email link requires login without consuming its token',
    (tester) async {
      const token = 'private-phone-email-routing-token';
      final auth = await _pump(tester, '/phone-email?token=$token');
      expect(_currentUri(tester).path, '/login');
      expect(_currentUri(tester).queryParameters.containsKey('token'), isFalse);
      expect(find.byType(PhoneAuthScreen), findsNothing);
      expect(find.widgetWithText(SeraButton, '登录'), findsOneWidget);
      expect(auth.requests, isEmpty);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  for (final path in ['bind-phone', 'phone-identity']) {
    testWidgets(
      'anonymous $path requires login before showing identity controls',
      (tester) async {
        final auth = await _pump(tester, '/$path');
        expect(_currentUri(tester).path, '/login');
        expect(find.byType(PhoneAuthScreen), findsNothing);
        expect(find.widgetWithText(SeraButton, '登录'), findsOneWidget);
        expect(auth.requests, isEmpty);
        expect(tester.takeException(), isNull);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }

  for (final complete in [false, true]) {
    testWidgets(
      'signed-in phone login returns to profile with onboarding=$complete',
      (tester) async {
        final auth = await _pump(
          tester,
          '/phone-login',
          signedIn: true,
          onboardingComplete: complete,
        );
        expect(_currentUri(tester).path, '/30');
        expect(find.byType(PhoneAuthScreen), findsNothing);
        expect(find.text('账户与安全'), findsOneWidget);
        expect(auth.requests, isEmpty);
        expect(tester.takeException(), isNull);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }

  for (final path in ['bind-phone', 'phone-identity', 'phone-email']) {
    testWidgets('signed-in $path remains accessible without a login redirect', (
      tester,
    ) async {
      final auth = await _pump(
        tester,
        '/$path?token=private-route-token',
        signedIn: true,
      );
      expect(_currentUri(tester).path, '/$path');
      expect(find.byType(PhoneAuthScreen), findsOneWidget);
      expect(
        auth.requests.every(
          (request) => request == 'GET /api/v1/auth/phone/capabilities',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  testWidgets(
    'signed-in email link replacement updates the real token form without exposing page keys',
    (tester) async {
      const firstToken = 'private-phone-email-state-one';
      const secondToken = 'private-phone-email-state-two';
      final auth = await _pump(
        tester,
        '/phone-email?token=$firstToken',
        signedIn: true,
      );
      final screen = find.byType(PhoneAuthScreen);
      final firstState = tester.state(screen);
      final router = GoRouter.of(tester.element(screen));
      final tokenField = find.descendant(
        of: find.widgetWithText(SeraInput, '邮件中的绑定链接'),
        matching: find.byType(TextFormField),
      );
      expect(
        tester.widget<TextFormField>(tokenField).controller!.text,
        firstToken,
      );
      final firstPage =
          ModalRoute.of(tester.element(screen))!.settings as Page<dynamic>;
      expect(
        firstPage.key.toString(),
        isNot(contains('private-phone-email-state')),
      );

      router.go('/phone-email?token=$secondToken');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(_currentUri(tester).path, '/phone-email');
      expect(tester.widget<PhoneAuthScreen>(screen).token, secondToken);
      expect(
        tester.widget<TextFormField>(tokenField).controller!.text,
        secondToken,
      );
      expect(tester.state(screen), isNot(same(firstState)));
      expect(firstState.mounted, isFalse);
      final secondPage =
          ModalRoute.of(tester.element(screen))!.settings as Page<dynamic>;
      expect(secondPage.key, isNot(firstPage.key));
      for (final key in [firstPage.key, secondPage.key]) {
        expect(key.toString(), isNot(contains('private-phone-email-state')));
        expect(key.toString(), isNot(contains('token=')));
        expect(key.toString(), isNot(contains('?')));
      }
      expect(
        auth.requests.every(
          (request) => request == 'GET /api/v1/auth/phone/capabilities',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'phone account motion is immediate and email token identity stays private',
    () {
      for (final path in [
        'phone-login',
        'bind-phone',
        'phone-identity',
        'phone-email',
      ]) {
        expect(SeraMotion.motionFor(Uri.parse('/$path')), SeraRouteMotion.none);
      }
      LocalKey key(String token) => SeraMotion.routeKey(
        routerKey: const ValueKey('phone-email-slot'),
        uri: Uri(path: '/phone-email', queryParameters: {'token': token}),
      );
      const first = 'private-phone-mail-token-one';
      const second = 'private-phone-mail-token-two';
      expect(key(first), key(first));
      expect(key(first), isNot(key(second)));
      for (final value in [key(first), key(second)]) {
        expect(value.toString(), isNot(contains('private-phone-mail')));
        expect(value.toString(), isNot(contains('token=')));
        expect(value.toString(), isNot(contains('?')));
      }
    },
  );
}
