import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/sera_motion.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:sera_flutter/ui/screens/planning_screens.dart';

const _draftId = 'menu-draft';

class _MenuStore implements WorkspaceRepository {
  _MenuStore() {
    final tasks = [
      for (final id in ['a', 'b', 'c'])
        SeraTask(id: id, title: '任务$id', estimatedMinutes: 30),
    ];
    value = Workspace(
      revision: 1,
      drafts: [
        PlanDraft(
          id: _draftId,
          goal: SeraGoal(
            id: 'menu-goal',
            title: '菜单身份测试',
            deadline: DateTime(2026, 11, 7, 18),
          ),
          items: [for (final task in tasks) PlannedTask(task: task)],
        ),
      ],
    );
  }
  late Workspace value;
  int writes = 0;
  @override
  String get mode => 'planning-menu-identity-fixture';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async {}
  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    if (value.revision != expectedRevision) {
      throw const RepositoryException(
        'Fixture revision mismatch',
        conflict: true,
      );
    }
    writes++;
    return value = next.copyWith(revision: expectedRevision + 1);
  }
}

class _MenuHarness {
  _MenuHarness(this.controller) {
    router = GoRouter(
      initialLocation: '/08?draftId=$_draftId',
      routes: [
        GoRoute(
          path: '/08',
          builder: (_, state) => buildPlanningScreen(
            '08-plan',
            draftId: state.uri.queryParameters['draftId'],
          ),
        ),
        GoRoute(
          path: '/09-edit-plan-task',
          builder: (_, state) => Scaffold(
            body: Text('编辑原任务:${state.uri.queryParameters['taskId']}'),
          ),
        ),
      ],
    );
  }
  final SeraController controller;
  late final GoRouter router;
  Widget get widget => MultiProvider(
    providers: [
      ChangeNotifierProvider<SeraController>.value(value: controller),
      Provider<AuthRepository?>.value(value: null),
    ],
    child: MaterialApp.router(
      routerConfig: router,
      theme: seraTheme(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (_, child) => SeraMotionScope(child: child!),
    ),
  );
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 70));
  }
}

Future<_MenuHarness> _mount(WidgetTester tester, _MenuStore store) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final controller = SeraController(
    repository: store,
    today: DateTime(2026, 10, 31),
  );
  await controller.initialize();
  final harness = _MenuHarness(controller);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    harness.router.dispose();
    controller.dispose();
  });
  await tester.pumpWidget(harness.widget);
  await _frames(tester);
  return harness;
}

Future<void> _openB(WidgetTester tester) async {
  final menu = find.byKey(const ValueKey('draft-menu:menu-draft:b'));
  expect(menu, findsOneWidget);
  expect(find.byKey(const ValueKey('draft-row:menu-draft:b')), findsOneWidget);
  await tester.ensureVisible(menu);
  await tester.tap(menu);
  await _frames(tester);
  expect(find.widgetWithText(PopupMenuItem<String>, '编辑任务'), findsOneWidget);
}

Future<void> _select(WidgetTester tester, String label) async {
  final entry = find.widgetWithText(PopupMenuItem<String>, label);
  expect(entry, findsOneWidget);
  await tester.tap(entry);
  await _frames(tester);
}

List<String> _ids(_MenuHarness harness) => harness.controller
    .draft(_draftId)!
    .items
    .map((item) => item.task.id)
    .toList();

void main() {
  testWidgets(
    'open draft menu edits the original task after an external reorder',
    (tester) async {
      final harness = await _mount(tester, _MenuStore());
      await _openB(tester);
      await harness.controller.reorderDraftItems(_draftId, ['b', 'a', 'c']);
      await _frames(tester);
      await _select(tester, '编辑任务');
      final top = harness.router.routerDelegate.state.uri;
      expect(top.path, '/09-edit-plan-task');
      expect(top.queryParameters['draftId'], _draftId);
      expect(top.queryParameters['taskId'], 'b');
      expect(find.text('编辑原任务:b'), findsOneWidget);
      expect(_ids(harness), ['b', 'a', 'c']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'open draft menu moves its original task using the current index',
    (tester) async {
      final store = _MenuStore();
      final harness = await _mount(tester, store);
      await _openB(tester);
      await harness.controller.reorderDraftItems(_draftId, ['b', 'a', 'c']);
      await _frames(tester);
      final before = store.writes;
      await _select(tester, '向后一步');
      expect(_ids(harness), ['a', 'b', 'c']);
      expect(store.writes, before + 1);
      expect(harness.router.routerDelegate.state.uri.path, '/08');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'open draft menu ignores a move that is no longer within bounds',
    (tester) async {
      final store = _MenuStore();
      final harness = await _mount(tester, store);
      await _openB(tester);
      await harness.controller.reorderDraftItems(_draftId, ['a', 'c', 'b']);
      await _frames(tester);
      final before = store.writes;
      await _select(tester, '向后一步');
      expect(_ids(harness), ['a', 'c', 'b']);
      expect(store.writes, before);
      expect(harness.router.routerDelegate.state.uri.path, '/08');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'open draft menu cannot edit a different task after its task is deleted',
    (tester) async {
      final store = _MenuStore();
      final harness = await _mount(tester, store);
      await _openB(tester);
      await harness.controller.deleteDraftItem(_draftId, 'b');
      await _frames(tester);
      final before = store.writes;
      await _select(tester, '编辑任务');
      expect(_ids(harness), ['a', 'c']);
      expect(store.writes, before);
      expect(harness.router.routerDelegate.state.uri.path, '/08');
      expect(find.text('编辑原任务:c'), findsNothing);
      expect(find.text('编辑原任务:b'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
