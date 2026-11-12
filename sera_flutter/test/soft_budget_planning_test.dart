import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/repositories.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/domain/planning_service.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';

final _now = readZoned('2026-11-02T09:00:00+08:00', 'Asia/Hong_Kong')!;
final _deadline = atMinute(_now, 12 * 60);
const _preferences = SeraPreferences(
  dailyBudget: 15,
  startMinute: 9 * 60,
  endMinute: 12 * 60,
  bufferMinutes: 15,
);

class _BudgetStore implements WorkspaceRepository, PlanningAiProvider {
  _BudgetStore({Workspace? value})
    : value = value ?? const Workspace(preferences: _preferences);
  Workspace value;
  int calls = 0;
  List<TaskOutline> definitions = const [
    TaskOutline(title: '完成复习清单', estimatedMinutes: 60),
  ];
  @override
  String get mode => 'budget-test';
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
      throw const RepositoryException('版本冲突', conflict: true);
    }
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
  }) async {
    calls++;
    return AiPlanResult(model: 'budget-fixture', tasks: definitions);
  }
}

Future<SeraController> _controller(_BudgetStore store) async {
  final c = SeraController(repository: store, today: _now, seedDemo: false);
  await c.initialize();
  addTearDown(c.dispose);
  return c;
}

Future<PlanDraft> _generate(SeraController c) => c.generatePlan(
  title: '复习目标',
  deadline: _deadline,
  dailyBudget: 15,
  requestId: 'one-budget-request',
);

Future<void> _open(
  WidgetTester tester,
  SeraController c,
  String location,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(SeraApp(controller: c, initialLocation: location));
  if (location.startsWith('/51')) {
    // The writing page continues animating behind the approval dialog.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  } else {
    await tester.pumpAndSettle();
  }
}

void main() {
  test('one model result yields a recoverable finite suggestion; approval survives edit and commit', () async {
    final store = _BudgetStore();
    final c = await _controller(store);
    final draft = await _generate(c);
    expect(store.calls, 1);
    expect(draft.originalDailyBudget, 15);
    expect(draft.suggestedDailyBudget, 60);
    expect(draft.needsBudgetConfirmation, isTrue);
    expect(c.data.tasks, isEmpty);
    expect(c.data.entries, isEmpty);
    expect((await _generate(c)).id, draft.id);
    expect(store.calls, 1);
    await expectLater(
      c.commitDraft(draft.id),
      throwsA(isA<RepositoryException>()),
    );
    expect(c.data.tasks, isEmpty);

    final reopened = await _controller(store);
    expect(reopened.draft(draft.id)!.needsBudgetConfirmation, isTrue);
    final item = reopened.draft(draft.id)!.items.single;
    await reopened.updateDraftItem(
      draft.id,
      PlannedTask(
        task: item.task.copyWith(notes: '保留用户修改'),
        entry: item.entry,
        additionalEntries: item.additionalEntries,
      ),
    );
    await reopened.revalidateDraft(draft.id);
    expect(reopened.draft(draft.id)!.needsBudgetConfirmation, isTrue);
    await expectLater(
      reopened.commitDraft(draft.id),
      throwsA(isA<RepositoryException>()),
    );
    expect(reopened.data.tasks, isEmpty);
    await reopened.confirmDraftDailyBudget(draft.id);
    final approvedItem = reopened.draft(draft.id)!.items.single;
    await reopened.updateDraftItem(
      draft.id,
      PlannedTask(
        task: approvedItem.task.copyWith(notes: '确认后继续编辑'),
        entry: approvedItem.entry,
        additionalEntries: approvedItem.additionalEntries,
      ),
    );
    await reopened.commitDraft(draft.id);
    await reopened.commitDraft(draft.id);
    expect(reopened.data.tasks.single.notes, '确认后继续编辑');
    expect(reopened.data.entries, hasLength(1));
    expect(reopened.data.preferences.dailyBudget, 15);
    expect(store.calls, 1);
    final goalEdit = await reopened.editGoalPlan(draft.goal.id);
    expect(goalEdit.confirmedDailyBudget, 60);
    await reopened.commitDraft(goalEdit.id);
    expect(reopened.data.tasks, hasLength(1));
  });

  test(
    'confirmed daily cap is finite and does not bypass overlap or deadline',
    () async {
      final c = await _controller(_BudgetStore());
      final draft = await _generate(c);
      await c.confirmDraftDailyBudget(draft.id);
      final item = c.draft(draft.id)!.items.single;
      await expectLater(
        c.updateDraftItem(
          draft.id,
          PlannedTask(
            task: item.task.copyWith(estimatedMinutes: 65),
            entry: item.entry,
          ),
        ),
        throwsA(isA<RepositoryException>()),
      );
      expect(c.draft(draft.id)!.items.single.task.estimatedMinutes, 60);
      await expectLater(
        c.updateDraftItem(
          draft.id,
          PlannedTask(
            task: item.task,
            entry: item.entry!.copyWith(
              start: atMinute(_now, 11 * 60 + 30),
              end: atMinute(_now, 12 * 60 + 30),
            ),
          ),
        ),
        throwsA(isA<RepositoryException>()),
      );
    },
  );

  test('busy time and short phase windows keep complete tasks as capacity candidates', () async {
    final busy = CalendarEntry(
      id: 'busy',
      title: '已有会议',
      start: _now,
      end: _deadline,
    );
    final store = _BudgetStore(
      value: Workspace(preferences: _preferences, entries: [busy]),
    );
    final c = await _controller(store);
    final busyDraft = await _generate(c);
    expect(busyDraft.needsCapacityConfirmation, isTrue);
    expect(busyDraft.items.single.task.estimatedMinutes, 60);
    expect(busyDraft.items.single.blocks, isEmpty);
    expect(busyDraft.suggestedDailyBudget, isNull);
    expect(c.data.tasks, isEmpty);
    expect(c.data.entries.map((entry) => entry.id), [busy.id]);
    expect(store.calls, 1);
    final phaseStore = _BudgetStore()
      ..definitions = [
        TaskOutline(
          title: '阶段任务',
          estimatedMinutes: 60,
          phase: '第一阶段',
          notBefore: _now,
          deadline: atMinute(_now, 9 * 60 + 30),
        ),
      ];
    final phaseController = await _controller(phaseStore);
    final phaseDraft = await _generate(phaseController);
    expect(phaseDraft.needsCapacityConfirmation, isTrue);
    expect(phaseDraft.items.single.blocks, isEmpty);
    expect(phaseDraft.items.single.task.estimatedMinutes, 60);
    expect(phaseDraft.items.single.task.phase, '第一阶段');
    expect(phaseDraft.items.single.task.deadline, atMinute(_now, 9 * 60 + 30));
    expect(phaseController.data.tasks, isEmpty);
  });

  test('legacy drafts stay compatible and malformed confirmation fields are rejected', () async {
    final c = await _controller(_BudgetStore());
    final json = (await _generate(c)).toJson();
    final legacy = Map<String, dynamic>.from(json)
      ..remove('originalDailyBudget')
      ..remove('suggestedDailyBudget')
      ..remove('budgetOverrideConfirmed');
    expect(PlanDraft.fromJson(legacy).needsBudgetConfirmation, isFalse);
    for (final change in <Map<String, dynamic>>[
      {'suggestedDailyBudget': 15},
      {'suggestedDailyBudget': 1441},
      {'originalDailyBudget': null},
      {'budgetOverrideConfirmed': 'yes'},
    ]) {
      expect(
        () => PlanDraft.fromJson({...json, ...change}),
        throwsA(isA<FormatException>()),
      );
    }
  });

  testWidgets(
    'generation opens a saved budget candidate rather than an AI failure',
    (tester) async {
      final store = _BudgetStore();
      final c = await _controller(store);
      await c.savePlanningSession(
        PlanningSession(
          id: 'budget-session',
          updatedAt: _now,
          prompt: '今天完成复习',
          title: '复习目标',
          deadline: _deadline,
          dailyBudget: 15,
          stage: 'generating',
          aiRequestId: 'one-budget-request',
        ),
      );
      await _open(tester, c, '/07?sessionId=budget-session');
      await tester.tap(find.widgetWithText(SeraButton, '继续这次生成'));
      await tester.pumpAndSettle();
      expect(find.text('需要多一点时间'), findsOneWidget);
      expect(c.data.drafts.single.needsBudgetConfirmation, isTrue);
      expect(c.data.planningSessions.single.draftId, c.data.drafts.single.id);
      expect(c.data.tasks, isEmpty);
      expect(store.calls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'budget confirmation is concise and uses the saved plan without another AI call',
    (tester) async {
      final store = _BudgetStore();
      final c = await _controller(store);
      final draft = await _generate(c);
      await _open(tester, c, '/39?draftId=${draft.id}');
      expect(find.text('需要多一点时间'), findsOneWidget);
      expect(find.text('这次没能完成规划'), findsNothing);
      expect(find.text('部分日期需最多 60 分钟，超过每日目标 15 分钟。'), findsOneWidget);
      await tester.tap(find.widgetWithText(SeraButton, '仍按此计划继续'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '计划草案'), findsOneWidget);
      expect(c.draft(draft.id)!.budgetOverrideConfirmed, isTrue);
      expect(c.data.tasks, isEmpty);
      expect(store.calls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'canceling a reopened pending plan confirmation creates no tasks',
    (tester) async {
      final store = _BudgetStore();
      final c = await _controller(store);
      final draft = await _generate(c);
      await _open(tester, c, '/51?draftId=${draft.id}');
      expect(find.widgetWithText(AlertDialog, '需要多一点时间'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '返回修改'));
      await tester.pumpAndSettle();
      expect(c.draft(draft.id)!.needsBudgetConfirmation, isTrue);
      expect(c.data.tasks, isEmpty);
      expect(c.data.entries, isEmpty);
      expect(find.widgetWithText(AppBar, '计划草案'), findsOneWidget);
      expect(store.calls, 1);
    },
  );
}
