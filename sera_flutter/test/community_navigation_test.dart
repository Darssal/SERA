import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/community_login_return.dart';
import 'package:sera_flutter/ui/core/sera_motion.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:sera_flutter/ui/screens/account_screens.dart';

class _Store implements WorkspaceRepository {
  @override
  String get mode => 'navigation-fixture';
  @override
  Future<Workspace?> load() async => const Workspace(revision: 1);
  @override
  Future<void> clear() async {}
  @override
  Future<Workspace> save(
    Workspace value, {
    required int expectedRevision,
  }) async => value;
}

class _Auth extends AuthRepository {
  _Auth() : super(apiBaseUrl: 'https://community.test');
  @override
  Future<void> login({
    required String identifier,
    required String password,
  }) async {}
}

void main() {
  test(
    'community login destinations reject external and malformed redirects',
    () {
      for (final route in [
        '/community',
        '/community/compose',
        '/community/manage',
        '/community/post/a-b_123',
        '/admin',
        '/admin/posts',
        '/admin/users',
        '/admin/team',
      ]) {
        expect(communityLoginReturn(route), route);
        expect(
          Uri.parse(communityAuthLink('/login', route))
              .queryParameters['returnTo'],
          route,
        );
      }
      for (final route in [
        'https://evil.test',
        '//evil.test/community',
        '/30',
        '/community/../account',
        '/community?admin=true',
        '/community#x',
        '/community/post/a%2Fb',
        '/community/post/',
        '/admin/../account',
        '/admin/unknown',
        '/admin/posts?returnTo=https://evil.test',
        '//evil.test/admin/posts',
        'javascript:alert(1)',
      ]) {
        expect(communityLoginReturn(route), isNull);
      }
    },
  );

  test(
    'community destination uses primary motion and composer uses editor motion',
    () {
      expect(
        SeraMotion.motionFor(Uri.parse('/community')),
        SeraRouteMotion.primary,
      );
      expect(
        SeraMotion.motionFor(Uri.parse('/community/compose')),
        SeraRouteMotion.editor,
      );
      expect(
        SeraMotion.motionFor(Uri.parse('/community/post/a')),
        SeraRouteMotion.detail,
      );
    },
  );

  testWidgets(
    'four navigation destinations switch independently at narrow width',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final routes = ['/04', '/17', '/12', '/community'];
      final router = GoRouter(
        initialLocation: '/04',
        routes: [
          for (var i = 0; i < routes.length; i++)
            GoRoute(
              path: routes[i],
              builder: (_, _) => SeraScaffold(
                title: '页面 $i',
                navIndex: i,
                showBack: false,
                body: const SizedBox(),
              ),
            ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(theme: seraTheme(), routerConfig: router),
      );
      for (final label in ['今日', '计划', '日程', '社区']) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(
          router.state.uri.path,
          routes[['今日', '计划', '日程', '社区'].indexOf(label)],
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'optional login carries destination through registration and returns to post',
    (tester) async {
      final auth = _Auth();
      final controller = SeraController(repository: _Store(), seedDemo: false);
      final router = GoRouter(
        initialLocation: communityAuthLink('/login', '/community/post/a'),
        routes: [
          for (final mode in [
            'login',
            'register',
            'forgot-password',
            'reset-password',
          ])
            GoRoute(
              path: '/$mode',
              builder: (_, _) => AccountScreen(mode: mode),
            ),
          GoRoute(
            path: '/community/post/:id',
            builder: (_, _) => const Scaffold(body: Text('帖子内容')),
          ),
        ],
      );
      addTearDown(auth.dispose);
      addTearDown(controller.dispose);
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthRepository>.value(value: auth),
            ChangeNotifierProvider.value(value: controller),
          ],
          child: MaterialApp.router(theme: seraTheme(), routerConfig: router),
        ),
      );
      await tester.tap(find.text('还没有账户，去注册'));
      await tester.pumpAndSettle();
      expect(router.state.uri.queryParameters['returnTo'], '/community/post/a');
      await tester.tap(find.text('已有账户，去登录'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('忘记密码'));
      await tester.tap(find.text('忘记密码'));
      await tester.pumpAndSettle();
      expect(router.state.uri.queryParameters['returnTo'], '/community/post/a');
      await tester.ensureVisible(find.text('已有重置邮件'));
      await tester.tap(find.text('已有重置邮件'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/reset-password');
      expect(router.state.uri.queryParameters['returnTo'], '/community/post/a');
      await tester.ensureVisible(find.text('返回登录'));
      await tester.tap(find.text('返回登录'));
      await tester.pumpAndSettle();
      expect(router.state.uri.queryParameters['returnTo'], '/community/post/a');
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'community-test');
      await tester.enterText(fields.at(1), 'sample-password');
      await tester.tap(find.text('登录', skipOffstage: false).last);
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/community/post/a');
      expect(find.text('帖子内容'), findsOneWidget);
    },
  );
}
