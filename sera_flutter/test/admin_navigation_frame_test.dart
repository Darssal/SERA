import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/community_controller.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/data/community_repository.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/community_models.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/screens/admin_screens.dart';

class _Workspace implements WorkspaceRepository {
  _Workspace({this.fail = false});
  final bool fail;
  @override
  String get mode => 'admin-navigation-fixture';
  @override
  Future<Workspace?> load() async {
    if (fail) throw const RepositoryException('本机记录暂时不可用');
    return const Workspace(revision: 1);
  }

  @override
  Future<void> clear() async {}
  @override
  Future<Workspace> save(
    Workspace value, {
    required int expectedRevision,
  }) async => value;
}

class _Community extends CommunityRepository {
  _Community() : super(apiBaseUrl: 'https://admin-navigation.test');
  @override
  Future<CommunityFeed> list({String filter = 'all', String? cursor}) async =>
      CommunityFeed(posts: const [], viewer: const CommunityViewer());
}

Future<SeraController> _mount(WidgetTester tester, {bool fail = false}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1536, 1024);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final auth = AuthRepository(apiBaseUrl: 'https://admin-navigation.test');
  final controller = SeraController(
    repository: _Workspace(fail: fail),
    seedDemo: false,
  );
  final community = CommunityController(repository: _Community());
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    community.dispose();
    controller.dispose();
    auth.dispose();
  });
  await tester.pumpWidget(
    ChangeNotifierProvider<AuthRepository>.value(
      value: auth,
      child: SeraApp(
        controller: controller,
        communityController: community,
        auth: auth,
        initialLocation: '/admin/posts',
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets(
    'admin uses the full viewport and its login returns through the narrow account form',
    (tester) async {
      await _mount(tester);
      final screen = find.byType(AdminConsoleScreen);
      expect(
        tester.getSize(find.byKey(const ValueKey('admin-console'))).width,
        1536,
      );
      final router = GoRouter.of(tester.element(screen));
      await tester.tap(find.widgetWithText(FilledButton, '登录'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/login');
      expect(router.state.uri.queryParameters['returnTo'], '/admin/posts');
      expect(tester.getSize(find.byType(Scaffold).first).width, 430);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'changing admin sections preserves the console state and leaving restores the phone frame',
    (tester) async {
      await _mount(tester);
      final screen = find.byType(AdminConsoleScreen);
      final initial = tester.state(screen);
      final router = GoRouter.of(tester.element(screen));
      router.go('/admin/users');
      await tester.pumpAndSettle();
      expect(identical(tester.state(screen), initial), isTrue);
      expect(
        tester.getSize(find.byKey(const ValueKey('admin-console'))).width,
        1536,
      );
      router.go('/community');
      await tester.pumpAndSettle();
      expect(find.byType(AdminConsoleScreen), findsNothing);
      expect(tester.getSize(find.byType(Scaffold).first).width, 430);
      expect(router.state.uri.path, '/community');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a personal workspace failure does not replace the independent admin entry',
    (tester) async {
      final controller = await _mount(tester, fail: true);
      expect(controller.error, isNotNull);
      expect(find.byKey(const ValueKey('admin-console')), findsOneWidget);
      expect(find.text('SERA 管理后台'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
