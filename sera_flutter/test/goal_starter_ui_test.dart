import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/planning_ai_provider.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/legacy_goal_template_fixture.dart';

class _StarterStore
    implements
        WorkspaceRepository,
        PlanningAiProvider,
        InputUnderstandingProvider {
  Workspace value = const Workspace(revision: 1);
  int saves = 0;
  int aiRequests = 0;
  final inputs = <Json>[];

  @override
  String get mode => 'goal-entry-and-legacy-draft-fixture';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async => value = const Workspace();
  @override
  Future<Workspace> save(
    Workspace workspace, {
    required int expectedRevision,
  }) async {
    if (value.revision != expectedRevision) {
      throw StateError('Unexpected stale save');
    }
    saves++;
    return value = Workspace.fromJson(
      workspace.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }

  @override
  Future<AiPlanResult> generateTaskBreakdown({
    required String title,
    required DateTime deadline,
    required int dailyBudget,
    String notes = '',
    String prompt = '',
    String? requestId,
  }) async => throw StateError(
    'Opening a goal or legacy draft must not generate a plan',
  );

  @override
  Future<AiUnderstanding> understandInput({
    required Json input,
    required String requestId,
    void Function(String stage)? onStage,
  }) async {
    aiRequests++;
    inputs.add(input);
    return const AiUnderstanding(
      intent: 'goal',
      title: '筹办个人摄影展',
      summary: '先确认展览的规模，再按你的目标制定计划。',
      outcome: '完成自己的摄影展',
      model: 'fixture-online-understanding',
      questions: [AiQuestion(id: 'scope', question: '你希望展出多少张作品？')],
    );
  }
}

Uri _location(WidgetTester tester) =>
    GoRouter.of(tester.element(find.byType(SeraScaffold).first))
        .routeInformationProvider
        .value
        .uri;

Future<SeraController> _mount(
  WidgetTester tester,
  _StarterStore store, {
  bool narrow = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = narrow
      ? const Size(320, 844)
      : const Size(390, 844);
  if (narrow) tester.platformDispatcher.textScaleFactorTestValue = 1.5;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final c = SeraController(
    repository: store,
    today: DateTime(2026, 11, 8, 10),
    seedDemo: false,
  );
  await c.initialize();
  await tester.pumpWidget(SeraApp(controller: c, initialLocation: '/20'));
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
  return c;
}

// Build a durable draft from the old template format, then reload it through
// the regular app. Removing the offer must not remove existing user plans.
Future<PlanDraft> _legacyDraft(_StarterStore store) async {
  final draft = legacyGoalDraft(
    store.value,
    readZoned('2026-11-08T10:00:00+08:00', 'Asia/Hong_Kong')!,
    title: '七天整理好我的书桌',
    outcome: '桌面只留下每天使用的物品，拍一张收尾照片。',
    requestId: 'legacy-template-fixture',
  );
  store.value = Workspace.fromJson(
    store.value.copyWith(drafts: [...store.value.drafts, draft]).toJson(),
  );
  return draft;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _openDraft(WidgetTester tester, PlanDraft draft) =>
    _tap(tester, find.widgetWithText(SeraSettingRow, draft.goal.title));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'empty goals offer one AI entry without template or automatic writes',
    (tester) async {
      final store = _StarterStore();
      final c = await _mount(tester, store);
      expect(find.text('还没有目标，点击＋创建'), findsOneWidget);
      expect(find.text('入门模板'), findsNothing);
      expect(find.widgetWithText(SeraButton, '使用这个方案'), findsNothing);
      expect(find.byTooltip('创建目标'), findsOneWidget);
      await _tap(tester, find.byTooltip('创建目标'));
      expect(_location(tester).path, '/05');
      expect(_location(tester).queryParameters['new'], '1');
      expect(_location(tester).queryParameters['from'], 'goals');
      expect(
        find.byKey(const ValueKey('planning-chat-composer')),
        findsOneWidget,
      );
      expect(c.data.goals, isEmpty);
      expect(c.data.tasks, isEmpty);
      expect(c.data.entries, isEmpty);
      expect(c.data.drafts, isEmpty);
      expect(store.saves, 0);
      expect(store.aiRequests, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'leaving an empty AI input returns to goals without creating data',
    (tester) async {
      final store = _StarterStore();
      final c = await _mount(tester, store);
      await _tap(tester, find.byTooltip('创建目标'));
      await _tap(tester, find.byTooltip('返回'));
      expect(_location(tester).path, '/20');
      expect(c.data.drafts, isEmpty);
      expect(c.data.planningSessions, isEmpty);
      expect(c.data.goals, isEmpty);
      expect(c.data.tasks, isEmpty);
      expect(c.data.entries, isEmpty);
      expect(store.saves, 0);
      expect(store.aiRequests, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a reloaded legacy draft can still be confirmed exactly once', (
    tester,
  ) async {
    final store = _StarterStore();
    final draft = await _legacyDraft(store);
    final initialSaves = store.saves;
    final c = await _mount(tester, store);
    await _openDraft(tester, draft);
    expect(_location(tester).path, '/08');
    expect(_location(tester).queryParameters['draftId'], draft.id);
    expect(c.data.drafts.single.toJson(), draft.toJson());
    expect(store.saves, initialSaves);
    expect(c.data.tasks, isEmpty);
    expect(c.data.goals, isEmpty);
    expect(c.data.entries, isEmpty);
    await _tap(tester, find.widgetWithText(SeraButton, '确认创建 5 项任务与安排'));
    expect(_location(tester).path, '/20');
    expect(c.data.goals.single.title, draft.goal.title);
    expect(c.data.goals.single.outcome, draft.goal.outcome);
    expect(c.data.tasks, hasLength(5));
    expect(c.data.entries, hasLength(5));
    expect(c.data.drafts.single.id, draft.id);
    expect(c.data.drafts.single.status, 'committed');
    expect(find.text('目标已创建'), findsOneWidget);
    final router = GoRouter.of(tester.element(find.byType(SeraScaffold).first));
    expect(router.canPop(), isFalse);
    await _tap(tester, find.text(draft.goal.title));
    expect(_location(tester).path, '/21');
    expect(find.text('已完成 0 / 5 项任务'), findsOneWidget);
    await _tap(tester, find.byTooltip('返回'));
    expect(_location(tester).path, '/20');
    await c.commitDraft(draft.id);
    expect(c.data.goals, hasLength(1));
    expect(c.data.tasks, hasLength(5));
    expect(c.data.entries, hasLength(5));
    expect(c.data.drafts, hasLength(1));
    expect(store.aiRequests, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'keeping an old draft preserves edits and returns to the same saved draft',
    (tester) async {
      final store = _StarterStore();
      final draft = await _legacyDraft(store);
      final c = await _mount(tester, store);
      await _openDraft(tester, draft);
      await _tap(tester, find.text(draft.items.first.task.title));
      await tester.enterText(find.byType(TextFormField).first, '先清理桌面上的旧文件');
      await _tap(tester, find.widgetWithText(SeraButton, '保存到草案'));
      await _tap(tester, find.byTooltip('返回'));
      await _tap(tester, find.widgetWithText(SeraButton, '保留草案并离开'));
      expect(_location(tester).path, '/20');
      expect(c.data.goals, isEmpty);
      expect(c.data.tasks, isEmpty);
      expect(c.data.entries, isEmpty);
      await _openDraft(tester, draft);
      expect(_location(tester).path, '/08');
      expect(_location(tester).queryParameters['draftId'], draft.id);
      expect(c.data.drafts, hasLength(1));
      expect(c.data.drafts.single.items.first.task.title, '先清理桌面上的旧文件');
      expect(find.text('先清理桌面上的旧文件'), findsOneWidget);
      expect(store.aiRequests, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an existing draft remains reachable without another offer', (
    tester,
  ) async {
    final store = _StarterStore();
    final draft = await _legacyDraft(store);
    final beforeSaves = store.saves;
    final c = await _mount(tester, store);
    expect(find.text('入门模板'), findsNothing);
    expect(find.byTooltip('创建目标'), findsOneWidget);
    await _openDraft(tester, draft);
    expect(_location(tester).path, '/08');
    expect(_location(tester).queryParameters['draftId'], draft.id);
    expect(c.data.drafts.single.toJson(), draft.toJson());
    expect(store.saves, beforeSaves);
    expect(store.aiRequests, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'narrow goal entry sends the personal request for model understanding',
    (tester) async {
      final store = _StarterStore();
      final c = await _mount(tester, store, narrow: true);
      await _tap(tester, find.byTooltip('创建目标'));
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      final input = find.byKey(const ValueKey('planning-chat-composer'));
      const prompt = '我想办一场个人摄影展，先帮我理清需要做的事情';
      await tester.enterText(input, prompt);
      await tester.pumpAndSettle();
      final send = find.byKey(const ValueKey('planning-chat-send'));
      await tester.ensureVisible(send);
      expect(send.hitTestable(), findsOneWidget);
      expect(tester.getRect(send).bottom, lessThanOrEqualTo(564));
      await _tap(tester, send);
      expect(store.aiRequests, 1);
      expect(store.inputs.single['prompt'], prompt);
      expect(c.data.planningSessions.single.prompt, prompt);
      expect(
        c.data.planningSessions.single.understanding?['model'],
        'fixture-online-understanding',
      );
      expect(c.data.planningSessions.single.understanding?['intent'], 'goal');
      expect(c.data.drafts, isEmpty);
      expect(c.data.goals, isEmpty);
      expect(c.data.tasks, isEmpty);
      expect(c.data.entries, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
