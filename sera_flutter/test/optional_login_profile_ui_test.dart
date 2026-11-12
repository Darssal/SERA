import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/application/device_cloud_sync.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:sera_flutter/ui/screens/account_screens.dart';
import 'package:sera_flutter/ui/screens/main_screens.dart';

class _Store implements WorkspaceRepository {
  Workspace value = const Workspace(revision: 1);
  int writes = 0;
  @override
  String get mode => 'optional-login-profile-fixture';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async {}
  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    if (expectedRevision != value.revision) {
      throw const RepositoryException('版本冲突', conflict: true);
    }
    writes++;
    return value = next.copyWith(revision: expectedRevision + 1);
  }
}

class _Storage implements AuthSessionStorage {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

class _Events implements AccountEventChannel {
  final _controller = StreamController<AccountEvent>.broadcast();
  @override
  Stream<AccountEvent> get events => _controller.stream;
  @override
  void publish(AccountEvent event) {}
  @override
  void dispose() => unawaited(_controller.close());
}

class _Auth extends AuthRepository {
  _Auth()
    : super(
        apiBaseUrl: 'http://optional-login.test',
        storage: _Storage(),
        accountEvents: _Events(),
      );
  int loginCalls = 0, registerCalls = 0, logoutCalls = 0;
  @override
  Future<void> login({
    required String identifier,
    required String password,
  }) async {
    loginCalls++;
    session = _session;
    notifyListeners();
  }

  @override
  Future<void> register({
    required String username,
    required String email,
    required String password,
  }) async {
    registerCalls++;
    session = _session;
    notifyListeners();
  }

  @override
  Future<void> logout() async {
    logoutCalls++;
    session = null;
    notifyListeners();
  }
}

class _DeviceSync extends ChangeNotifier implements DeviceCloudSync {
  @override
  bool hasPending = true;
  @override
  bool busy = false;
  @override
  bool hasConflicts = false;
  @override
  String? message = '本机记录尚未同步';
  @override
  int conflictCount = 0;
  final decisions = <bool?>[];

  @override
  Future<void> synchronize({bool? preferDevice}) async {
    decisions.add(preferDevice);
    if (!hasConflicts || preferDevice != null) {
      hasPending = false;
      notifyListeners();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _session = AuthSession(
  token: 'fixture-token',
  sessionId: 'fixture-session',
  expiresAt: DateTime(2099),
  user: AuthUser(
    id: 'fixture-account',
    username: '个人账户',
    email: 'user@example.test',
    emailVerified: true,
    hasPassword: true,
  ),
);

Future<(_Auth, GoRouter, _Store)> _mount(
  WidgetTester tester, {
  String location = '/30',
  bool signedIn = false,
  bool narrow = false,
  DeviceCloudSync? deviceSync,
  Workspace? workspace,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(narrow ? 320 : 390, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (narrow) {
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  final auth = _Auth();
  if (signedIn) auth.session = _session;
  final store = _Store();
  if (workspace != null) store.value = workspace;
  final controller = SeraController(repository: store, seedDemo: false);
  await controller.initialize();
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(path: '/30', builder: (_, _) => const ProfileScreen()),
      GoRoute(path: '/36', builder: (_, _) => const PrivacyScreen()),
      for (final mode in ['login', 'register', 'account'])
        GoRoute(
          path: '/$mode',
          builder: (_, _) => AccountScreen(mode: mode),
        ),
    ],
  );
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthRepository>.value(value: auth),
        ChangeNotifierProvider<SeraController>.value(value: controller),
        if (deviceSync != null)
          ChangeNotifierProvider<DeviceCloudSync>.value(value: deviceSync),
      ],
      child: MaterialApp.router(
        theme: seraTheme(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
    controller.dispose();
    auth.dispose();
    deviceSync?.dispose();
  });
  return (auth, router, store);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('local My offers optional login without cloud account state', (
    tester,
  ) async {
    final (auth, router, store) = await _mount(tester);
    expect(find.text('记录已保存在此设备'), findsOneWidget);
    expect(find.text('账户与安全'), findsNothing);
    expect(find.text('保存与同步'), findsNothing);
    expect(find.textContaining('项修改尚未同步'), findsNothing);
    await _tap(tester, find.text('登录并同步'));
    expect(router.routerDelegate.state.uri.path, '/login');
    await _tap(tester, find.byTooltip('返回'));
    expect(router.routerDelegate.state.uri.path, '/30');
    expect(auth.loginCalls, 0);
    expect(auth.registerCalls, 0);
    expect(store.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('optional password login returns to My', (tester) async {
    final (auth, router, _) = await _mount(tester, location: '/login');
    await tester.enterText(find.byType(TextFormField).first, 'fixture-user');
    await tester.enterText(find.byType(TextFormField).last, 'fixture-password');
    await _tap(tester, find.widgetWithText(SeraButton, '登录'));
    expect(auth.loginCalls, 1);
    expect(router.routerDelegate.state.uri.path, '/30');
    expect(find.text('个人账户'), findsOneWidget);
    expect(find.text('登录并同步'), findsNothing);
    expect(find.text('账户与安全'), findsOneWidget);
    expect(find.text('保存与同步'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final narrow in [false, true]) {
    testWidgets('one account card opens account controls at narrow=$narrow', (
      tester,
    ) async {
      final (auth, router, store) = await _mount(
        tester,
        signedIn: true,
        narrow: narrow,
      );
      expect(find.widgetWithText(SeraSettingRow, '账户与安全'), findsNothing);
      final account = find.byKey(const ValueKey('profile-account-entry'));
      expect(
        find.descendant(of: account, matching: find.text('账户与安全')),
        findsOneWidget,
      );
      await _tap(tester, account);
      expect(router.routerDelegate.state.uri.path, '/account');
      expect(find.widgetWithText(ListTile, '退出登录'), findsOneWidget);
      await _tap(tester, find.byTooltip('返回'));
      expect(router.routerDelegate.state.uri.path, '/30');
      expect(auth.logoutCalls, 0);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'privacy keeps export and explicit clearing without demo tools at narrow=$narrow',
      (tester) async {
        const workspace = Workspace(
          revision: 1,
          tasks: [SeraTask(id: 'kept-task', title: '保留我的记录')],
        );
        final (_, router, store) = await _mount(
          tester,
          location: '/36',
          narrow: narrow,
          workspace: workspace,
        );
        expect(find.text('当前设备'), findsOneWidget);
        expect(find.text('日历访问与同步'), findsNothing);
        expect(find.text('系统提醒权限'), findsNothing);
        expect(find.text('重置演示数据'), findsNothing);
        await _tap(tester, find.text('查看与复制数据'));
        final exported = tester
            .widget<SelectableText>(find.byType(SelectableText))
            .data!;
        expect(exported, contains('kept-task'));
        expect(exported, contains('保留我的记录'));
        await _tap(tester, find.widgetWithText(TextButton, '关闭'));
        await _tap(tester, find.text('清空安排与记录'));
        expect(find.text('任务、目标、日程、草案和专注记录将全部清空，无法恢复。账户会保留。'), findsOneWidget);
        await _tap(tester, find.widgetWithText(TextButton, '取消'));
        expect(router.routerDelegate.state.uri.path, '/36');
        expect(store.value.toJson(), workspace.toJson());
        expect(store.writes, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('leaving registration does not require an account', (
    tester,
  ) async {
    final (auth, router, store) = await _mount(tester, location: '/register');
    await _tap(tester, find.byTooltip('返回'));
    expect(router.routerDelegate.state.uri.path, '/30');
    expect(auth.registerCalls, 0);
    expect(store.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('optional registration returns to My without repeating setup', (
    tester,
  ) async {
    final (auth, router, store) = await _mount(tester, location: '/register');
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'fixture-user');
    await tester.enterText(fields.at(1), 'user@example.test');
    await tester.enterText(fields.at(2), 'fixture-password');
    await tester.enterText(fields.at(3), 'fixture-password');
    await _tap(tester, find.widgetWithText(SeraButton, '创建账户并开始'));
    expect(auth.registerCalls, 1);
    expect(router.routerDelegate.state.uri.path, '/30');
    expect(find.text('个人账户'), findsOneWidget);
    expect(store.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('logging out returns to local My without a login wall', (
    tester,
  ) async {
    final (auth, router, _) = await _mount(
      tester,
      location: '/account',
      signedIn: true,
    );
    await _tap(tester, find.widgetWithText(ListTile, '退出登录'));
    expect(auth.logoutCalls, 1);
    expect(router.routerDelegate.state.uri.path, '/30');
    expect(find.text('登录并同步'), findsOneWidget);
    expect(find.text('记录已保存在此设备'), findsOneWidget);
    expect(find.text('账户与安全'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local My remains usable at 320 width and 150 percent font', (
    tester,
  ) async {
    final (_, router, _) = await _mount(tester, narrow: true);
    await _tap(tester, find.text('登录并同步'));
    expect(router.routerDelegate.state.uri.path, '/login');
    await _tap(tester, find.byTooltip('返回'));
    expect(router.routerDelegate.state.uri.path, '/30');
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending device records retry in My without another page', (
    tester,
  ) async {
    final sync = _DeviceSync();
    final (_, router, _) = await _mount(
      tester,
      signedIn: true,
      deviceSync: sync,
    );
    await _tap(tester, find.text('同步此设备的记录'));
    expect(sync.decisions, [null]);
    expect(router.routerDelegate.state.uri.path, '/30');
    expect(find.text('同步此设备的记录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('device-cloud differences require a choice and allow cancel', (
    tester,
  ) async {
    final sync = _DeviceSync()
      ..hasConflicts = true
      ..conflictCount = 2;
    await _mount(tester, signedIn: true, deviceSync: sync);
    await _tap(tester, find.text('同步此设备的记录'));
    expect(find.text('此设备与账户中的记录不同'), findsOneWidget);
    expect(sync.decisions, isEmpty);
    await _tap(tester, find.widgetWithText(TextButton, '取消'));
    expect(sync.decisions, isEmpty);
    expect(sync.hasPending, isTrue);
    await _tap(tester, find.text('同步此设备的记录'));
    await _tap(tester, find.widgetWithText(TextButton, '保留此设备的记录'));
    expect(sync.decisions, [true]);
    expect(find.text('同步此设备的记录'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
