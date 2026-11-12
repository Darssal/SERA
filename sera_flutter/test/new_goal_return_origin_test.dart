import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/domain/planning_service.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime(2026, 11, 2, 8);

class _Store implements WorkspaceRepository {
  _Store(this.value);
  Workspace value;
  @override
  String get mode => 'new-goal-origin-fixture';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async => value = const Workspace();
  @override
  Future<Workspace> save(
    Workspace workspace, {
    required int expectedRevision,
  }) async {
    if (expectedRevision != value.revision) {
      throw StateError('Unexpected stale save');
    }
    return value = Workspace.fromJson(
      workspace.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }
}

PlanDraft _draft() {
  var next = 0;
  return const PlanningService().generate(
    workspace: const Workspace(),
    today: _now,
    title: '本周整理好书桌',
    deadline: DateTime(2026, 11, 6, 18),
    dailyBudget: 90,
    outlines: const [TaskOutline(title: '收拾桌面', estimatedMinutes: 20)],
    newId: (prefix) => '$prefix-origin-${next++}',
  );
}

Future<({SeraController controller, GoRouter router, PlanDraft draft})> _mount(
  WidgetTester tester,
  String Function(PlanDraft draft) location,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final draft = _draft();
  final store = _Store(Workspace(revision: 1, drafts: [draft]));
  final controller = SeraController(
    repository: store,
    today: _now,
    seedDemo: false,
  );
  await controller.initialize();
  await tester.pumpWidget(
    SeraApp(controller: controller, initialLocation: location(draft)),
  );
  await tester.pumpAndSettle();
  final router = GoRouter.of(tester.element(find.byType(SeraScaffold).first));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  return (controller: controller, router: router, draft: draft);
}

Future<void> _tap(WidgetTester tester, String label) async {
  final button = find.widgetWithText(SeraButton, label);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _confirm(WidgetTester tester) async {
  await _tap(tester, '确认创建 1 项任务与安排');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final example in <(String?, String)>[
    ('today', '/04'),
    ('tasks', '/17'),
    ('goals', '/20'),
    ('history', '/34'),
    (null, '/20'),
    ('https://invalid.example', '/20'),
  ]) {
    testWidgets(
      'new goal returns to ${example.$1 ?? 'legacy fallback'} and clears the editor stack',
      (tester) async {
        final mounted = await _mount(
          tester,
          (draft) => Uri(
            path: '/08',
            queryParameters: {
              'draftId': draft.id,
              if (example.$1 != null) 'from': example.$1!,
            },
          ).toString(),
        );
        await _confirm(tester);
        expect(mounted.router.state.uri.path, example.$2);
        if (example.$1 == 'tasks') {
          expect(mounted.router.state.uri.queryParameters['filter'], 'todo');
          expect(find.widgetWithText(AppBar, '计划'), findsOneWidget);
        }
        expect(mounted.router.canPop(), isFalse);
        expect(find.widgetWithText(AppBar, '目标详情'), findsNothing);
        expect(find.widgetWithText(AppBar, '确认安排'), findsNothing);
        expect(mounted.controller.data.goals, hasLength(1));
        expect(mounted.controller.data.tasks, hasLength(1));
        expect(mounted.controller.data.entries, hasLength(1));
        expect(mounted.controller.data.drafts.single.status, 'committed');
        expect(find.text('目标已创建'), findsOneWidget);
        await mounted.controller.commitDraft(mounted.draft.id);
        expect(mounted.controller.data.tasks, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'three draft edits preserve the Today origin and one draft before creating',
    (tester) async {
      final mounted = await _mount(
        tester,
        (draft) => '/08?draftId=${draft.id}&from=today',
      );
      for (var round = 0; round < 3; round++) {
        final title =
            mounted.controller.data.drafts.single.items.single.task.title;
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
        expect(mounted.router.state.uri.path, '/09-edit-plan-task');
        await tester.enterText(
          find.byType(TextFormField).first,
          '整理书桌第${round + 1}次修改',
        );
        await _tap(tester, '保存到草案');
        expect(mounted.router.state.uri.queryParameters['from'], 'today');
        expect(mounted.router.canPop(), isFalse);
        expect(mounted.controller.data.drafts, hasLength(1));
        expect(mounted.controller.data.tasks, isEmpty);
      }
      await _confirm(tester);
      expect(mounted.router.state.uri.path, '/04');
      expect(mounted.controller.data.tasks.single.title, '整理书桌第3次修改');
      expect(mounted.router.canPop(), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  for (final example in [
    ('today', '/04'),
    ('tasks', '/17'),
    ('history', '/34'),
  ]) {
    testWidgets(
      'keeping a draft returns to ${example.$1} without creating objects',
      (tester) async {
        final mounted = await _mount(
          tester,
          (draft) => '/08?draftId=${draft.id}&from=${example.$1}',
        );
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        await _tap(tester, '保留草案并离开');
        expect(mounted.router.state.uri.path, example.$2);
        if (example.$1 == 'tasks') {
          expect(mounted.router.state.uri.queryParameters['filter'], 'todo');
        }
        expect(mounted.router.canPop(), isFalse);
        expect(mounted.controller.data.drafts.single.status, 'draft');
        expect(mounted.controller.data.goals, isEmpty);
        expect(mounted.controller.data.tasks, isEmpty);
        expect(mounted.controller.data.entries, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final origin in ['today', 'tasks']) {
    testWidgets('saved draft exit labels and returns to $origin', (
      tester,
    ) async {
      final mounted = await _mount(
        tester,
        (draft) => '/55?draftId=${draft.id}&from=$origin',
      );
      final before = mounted.controller.data.toJson();
      await _tap(tester, origin == 'today' ? '返回今日' : '返回计划');
      expect(mounted.router.state.uri.path, origin == 'today' ? '/04' : '/17');
      expect(
        find.widgetWithText(AppBar, origin == 'today' ? '今日' : '计划'),
        findsOneWidget,
      );
      expect(mounted.router.canPop(), isFalse);
      expect(mounted.controller.data.toJson(), before);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'a direct draft editor keeps its History origin through the save fallback',
    (tester) async {
      final mounted = await _mount(
        tester,
        (draft) => Uri(
          path: '/09',
          queryParameters: {
            'draftId': draft.id,
            'taskId': draft.items.single.task.id,
            'from': 'history',
          },
        ).toString(),
      );
      await tester.enterText(find.byType(TextFormField).first, '编辑后完成桌面收纳');
      await _tap(tester, '保存到草案');
      expect(mounted.router.state.uri.queryParameters['from'], 'history');
      await _confirm(tester);
      expect(mounted.router.state.uri.path, '/34');
      expect(mounted.router.canPop(), isFalse);
      expect(mounted.controller.data.tasks.single.title, '编辑后完成桌面收纳');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('opening a draft from History returns there after creation', (
    tester,
  ) async {
    final mounted = await _mount(tester, (_) => '/34');
    await tester.tap(find.text('草案'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(mounted.draft.goal.title));
    await tester.pumpAndSettle();
    expect(mounted.router.state.uri.queryParameters['from'], 'history');
    await _confirm(tester);
    expect(mounted.router.state.uri.path, '/34');
    expect(mounted.router.canPop(), isFalse);
    expect(mounted.controller.data.goals, hasLength(1));
    expect(mounted.controller.data.tasks, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
