import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/repositories.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/domain/planning_service.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';

final _today = DateTime(2026, 11, 2);
final _deadline = DateTime(2026, 11, 20, 15);

const _outcome = AiPlanResult(
  model: 'recovery-test-model',
  tasks: [
    TaskOutline(title: '完成英语口语自测', estimatedMinutes: 30),
    TaskOutline(title: '整理口语练习记录', estimatedMinutes: 30),
  ],
);

class _RecoveryStore implements WorkspaceRepository, PlanningAiProvider {
  _RecoveryStore(this.value);
  Workspace value;
  Completer<void>? loadGate;
  final calls = <Map<String, Object?>>[];
  final responses = <Future<AiPlanResult> Function()>[];
  @override
  String get mode => 'recovery-test';
  @override
  Future<Workspace?> load() async {
    await loadGate?.future;
    return value;
  }

  @override
  Future<void> clear() async => value = const Workspace();
  @override
  Future<Workspace> save(
    Workspace workspace, {
    required int expectedRevision,
  }) async {
    if (value.revision != expectedRevision) {
      throw const RepositoryException('测试版本冲突', conflict: true);
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
  }) {
    calls.add({
      'requestId': requestId,
      'title': title,
      'deadline': deadline.toUtc().toIso8601String(),
      'dailyBudget': dailyBudget,
      'notes': notes,
      'prompt': prompt,
    });
    return responses.isEmpty ? Future.value(_outcome) : responses.removeAt(0)();
  }
}

PlanningSession _pendingSession(String id, String requestId) => PlanningSession(
  id: id,
  updatedAt: _today,
  prompt: '下周五完成英语口语练习',
  title: '英语口语恢复目标',
  notes: '按上次确认的条件安排',
  deadline: _deadline,
  dailyBudget: 90,
  stage: 'generating',
  aiRequestId: requestId,
  aiRequestNotes: '按上次确认的条件安排\n用户允许参考的已完成任务：原记录',
);

PlanDraft _draft(String title, {String? requestId}) {
  var sequence = 0;
  return const PlanningService()
      .generate(
        workspace: const Workspace(),
        today: _today,
        title: title,
        deadline: _deadline,
        dailyBudget: 90,
        outlines: _outcome.tasks,
        source: 'siliconflow',
        model: _outcome.model,
        newId: (prefix) => '$title-$prefix-${sequence++}',
      )
      .copyWith(aiRequestId: requestId);
}

Future<void> _pump(
  WidgetTester tester,
  SeraController controller,
  String path,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    SeraApp(controller: controller, initialLocation: path),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _tapButton(WidgetTester tester, String label) async {
  final button = label == '修改目标信息'
      ? find.widgetWithText(SeraSettingRow, label)
      : find.widgetWithText(SeraButton, label);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  test(
    'a saved draft request survives reopen and is not generated twice',
    () async {
      final store = _RecoveryStore(const Workspace(revision: 1));
      final first = SeraController(repository: store, today: _today);
      await first.initialize();
      await first.savePlanningSession(
        _pendingSession('session-one', 'request-one'),
      );
      final original = await first.generatePlan(
        title: '英语口语恢复目标',
        deadline: _deadline,
        dailyBudget: 90,
        requestId: 'request-one',
        requestNotes: '冻结后的原始上下文',
      );
      first.dispose();
      final reopened = SeraController(repository: store, today: _today);
      await reopened.initialize();
      // Even a now-stale deadline cannot trigger a second provider request when
      // the original request has already produced a durable editable draft.
      final found = await reopened.generatePlan(
        title: '英语口语恢复目标',
        deadline: DateTime(2026, 10, 1),
        dailyBudget: 90,
        requestId: 'request-one',
      );
      expect(found.id, original.id);
      expect(found.aiRequestId, 'request-one');
      expect(reopened.data.drafts, hasLength(1));
      expect(store.calls, hasLength(1));
      expect(store.calls.single['notes'], '冻结后的原始上下文');
      final session = reopened.planningSession('session-one')!;
      expect(session.aiRequestId, 'request-one');
      expect(session.aiRequestNotes, contains('原记录'));
      reopened.dispose();
    },
  );

  testWidgets(
    'history resumes the same request rather than an unrelated draft',
    (tester) async {
      final store = _RecoveryStore(
        Workspace(
          revision: 1,
          drafts: [_draft('另一份已经保存的目标')],
          planningSessions: [
            _pendingSession('recover-session', 'recover-request'),
          ],
        ),
      );
      final gate = Completer<AiPlanResult>();
      store.responses.add(() => gate.future);
      final controller = SeraController(repository: store, today: _today);
      await controller.initialize();
      await _pump(tester, controller, '/34');
      final row = find.text('英语口语恢复目标');
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(SeraButton, '继续这次生成'), findsOneWidget);
      expect(find.widgetWithText(SeraButton, '查看这次的计划草案'), findsNothing);
      await _tapButton(tester, '继续这次生成');
      expect(store.calls.single['requestId'], 'recover-request');
      expect(store.calls.single['notes'], contains('原记录'));
      expect(controller.data.tasks, isEmpty);
      gate.complete(_outcome);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '计划草案'), findsOneWidget);
      final restored = controller.data.drafts.singleWhere(
        (d) => d.aiRequestId == 'recover-request',
      );
      expect(controller.data.drafts, hasLength(2));
      expect(
        controller.planningSession('recover-session')!.draftId,
        restored.id,
      );
      expect(controller.planningSession('recover-session')!.stage, 'draft');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'refresh after draft save restores its request before session link',
    (tester) async {
      final saved = _draft('已保存但还没关联会话', requestId: 'saved-request');
      final loadGate = Completer<void>();
      final store = _RecoveryStore(
        Workspace(
          revision: 1,
          drafts: [saved, _draft('更晚但无关的草案')],
          planningSessions: [_pendingSession('saved-session', 'saved-request')],
        ),
      )..loadGate = loadGate;
      final controller = SeraController(repository: store, today: _today);
      // Simulate an actual browser refresh: the first frame precedes disk load.
      await _pump(tester, controller, '/07?sessionId=saved-session');
      expect(controller.loading, isTrue);
      loadGate.complete();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(SeraButton, '查看这次的计划草案'), findsOneWidget);
      await _tapButton(tester, '查看这次的计划草案');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '计划草案'), findsOneWidget);
      expect(store.calls, isEmpty);
      expect(controller.data.drafts, hasLength(2));
      expect(controller.planningSession('saved-session')!.draftId, saved.id);
      expect(controller.planningSession('saved-session')!.stage, 'draft');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'transient resume keeps identity and failed job retry gets a new one',
    (tester) async {
      final store = _RecoveryStore(const Workspace(revision: 1));
      store.responses.addAll([
        () => Future.error(const RepositoryException('连接已中断', offline: true)),
        () => Future.error(
          const RepositoryException(
            '这份作业已经失败',
            details: {'planningJobTerminal': true, 'jobStatus': 'failed'},
          ),
        ),
        () => Future.value(_outcome),
      ]);
      final controller = SeraController(repository: store, today: _today);
      await controller.initialize();
      await controller.savePlanningSession(
        PlanningSession(
          id: 'retry-planning-session',
          updatedAt: _today,
          deadline: _deadline,
          stage: 'clarify',
        ),
      );
      await _pump(tester, controller, '/06?sessionId=retry-planning-session');
      await tester.enterText(find.byType(TextFormField).first, '英语口语恢复目标');
      await _tapButton(tester, '生成可执行的计划');
      await tester.pumpAndSettle();
      expect(find.text('连接已中断'), findsNothing);
      await tester.tap(find.text('查看详情'));
      await tester.pumpAndSettle();
      expect(find.text('连接已中断'), findsOneWidget);
      expect(controller.data.planningSessions.single.stage, 'generating');
      final originalId = store.calls.single['requestId'];
      expect(originalId, isNotNull);
      await controller.savePreferences(
        controller.data.preferences.copyWith(useAiContext: true),
      );
      await _tapButton(tester, '继续这次生成');
      await tester.pumpAndSettle();
      expect(store.calls[1]['requestId'], originalId);
      expect(store.calls[1]['notes'], store.calls.first['notes']);
      if (find.text('这份作业已经失败').evaluate().isEmpty) {
        await tester.tap(find.text('查看详情'));
        await tester.pumpAndSettle();
      }
      expect(find.text('这份作业已经失败'), findsOneWidget);
      expect(controller.data.planningSessions.single.stage, 'failed');
      expect(controller.data.planningSessions.single.aiRequestId, isNull);
      await _tapButton(tester, '重新生成计划');
      await tester.pumpAndSettle();
      expect(store.calls, hasLength(3));
      expect(store.calls.last['requestId'], isNot(originalId));
      expect(
        controller.data.drafts.single.aiRequestId,
        store.calls.last['requestId'],
      );
      expect(controller.data.tasks, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'blocked task UI persists a recoverable refinement before AI starts',
    (tester) async {
      const original = SeraTask(id: 'refine-task', title: '整理英语口语练习');
      final store = _RecoveryStore(
        const Workspace(revision: 1, tasks: [original]),
      );
      final interrupted = Completer<AiPlanResult>();
      store.responses.add(() => interrupted.future);
      final first = SeraController(repository: store, today: _today);
      await first.initialize();
      await _pump(tester, first, '/24?taskId=refine-task');
      await _tapButton(tester, '卡住了，记录原因并调整');
      await tester.enterText(find.byType(TextFormField), '不知道怎样开始练习');
      await tester.tap(find.widgetWithText(TextButton, '记录并生成拆解建议'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.widgetWithText(AppBar, '正在规划'), findsOneWidget);
      expect(store.calls, hasLength(1));
      final saved = store.value.planningSessions.single;
      expect(saved.targetTaskId, original.id);
      expect(saved.baseTaskRevision, first.task(original.id)!.revision);
      expect(saved.aiRequestId, store.calls.single['requestId']);
      expect(saved.aiRequestNotes, store.calls.single['notes']);
      final oldRequest = store.calls.single;
      await tester.pumpWidget(const SizedBox.shrink());
      first.dispose();
      interrupted.complete(_outcome);
      await tester.pumpAndSettle();

      final reopened = SeraController(repository: store, today: _today);
      await reopened.initialize();
      await _pump(tester, reopened, '/07?sessionId=${saved.id}');
      await _tapButton(tester, '继续这次生成');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '调整任务执行步骤'), findsOneWidget);
      expect(store.calls, hasLength(2));
      expect(store.calls.last, oldRequest);
      final plan = reopened.data.drafts.single;
      expect(plan.targetTaskId, original.id);
      expect(plan.aiRequestId, saved.aiRequestId);
      await reopened.commitDraft(plan.id);
      expect(reopened.data.tasks, hasLength(1));
      expect(reopened.task(original.id)!.checklist, hasLength(2));
      expect(reopened.data.goals, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      reopened.dispose();
    },
  );

  testWidgets('changed refinement target requires an explicit new request', (
    tester,
  ) async {
    final pending = _pendingSession(
      'stale-refine',
      'old-refine-request',
    ).copyWith(targetTaskId: 'changed-task', baseTaskRevision: 1);
    const current = SeraTask(
      id: 'changed-task',
      title: '任务内容已经改过',
      revision: 2,
    );
    final store = _RecoveryStore(
      Workspace(
        revision: 1,
        tasks: const [current],
        planningSessions: [pending],
      ),
    );
    final controller = SeraController(repository: store, today: _today);
    await controller.initialize();
    await _pump(tester, controller, '/07?sessionId=${pending.id}');
    expect(find.textContaining('任务内容有变化'), findsOneWidget);
    expect(store.calls, isEmpty);
    await _tapButton(tester, '按当前任务重新生成');
    await tester.pumpAndSettle();
    expect(store.calls.single['requestId'], isNot('old-refine-request'));
    expect(store.calls.single['title'], current.title);
    expect(controller.data.drafts.single.targetTaskId, current.id);
    expect(controller.data.drafts.single.baseTaskVersions[current.id], 2);
    expect(controller.task(current.id)!.title, current.title);
    expect(controller.task(current.id)!.revision, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
    'a deleted refinement target cannot submit or recover an AI job',
    (tester) async {
      final pending = _pendingSession(
        'deleted-refine',
        'deleted-request',
      ).copyWith(targetTaskId: 'deleted-task', baseTaskRevision: 1);
      final store = _RecoveryStore(
        Workspace(revision: 1, planningSessions: [pending]),
      );
      final controller = SeraController(repository: store, today: _today);
      await controller.initialize();
      await _pump(tester, controller, '/07?sessionId=${pending.id}');
      expect(find.widgetWithText(SeraButton, '继续这次生成'), findsNothing);
      await _tapButton(tester, '返回任务列表');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '计划'), findsOneWidget);
      expect(store.calls, isEmpty);
      expect(controller.data.drafts, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'goal editor keeps controllers through save and cancel transitions',
    (tester) async {
      final goal = SeraGoal(
        id: 'dialog-goal',
        title: '原目标',
        deadline: _deadline,
      );
      final store = _RecoveryStore(Workspace(revision: 1, goals: [goal]));
      final controller = SeraController(repository: store, today: _today);
      await controller.initialize();
      await _pump(tester, controller, '/21?goalId=${goal.id}');
      await _tapButton(tester, '修改目标信息');
      await tester.enterText(find.byType(TextFormField).first, '已经核对的新目标');
      await tester.tap(find.widgetWithText(TextButton, '保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(controller.goal(goal.id)!.title, '已经核对的新目标');
      expect(find.byType(AlertDialog), findsNothing);
      await _tapButton(tester, '修改目标信息');
      await tester.enterText(find.byType(TextFormField).first, '取消后不应保存');
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(controller.goal(goal.id)!.title, '已经核对的新目标');
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'extra block duration controller survives its closing animation',
    (tester) async {
      const task = SeraTask(
        id: 'duration-task',
        title: '分段练习任务',
        estimatedMinutes: 60,
        splittable: true,
      );
      final start = DateTime(2026, 11, 3, 14);
      final store = _RecoveryStore(
        Workspace(
          revision: 1,
          tasks: const [task],
          entries: [
            CalendarEntry(
              id: 'duration-first',
              title: task.title,
              taskId: task.id,
              start: start,
              end: start.add(const Duration(minutes: 30)),
            ),
          ],
        ),
      );
      final controller = SeraController(repository: store, today: _today);
      await controller.initialize();
      await _pump(tester, controller, '/09?taskId=${task.id}');
      await _tapButton(tester, '添加一段安排');
      await tester.tap(find.widgetWithText(TextButton, '下一步'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '确定'));
      await tester.pumpAndSettle();
      final duration = find.descendant(
        of: find.widgetWithText(SeraInput, '持续时间（分钟）'),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(duration, '15');
      await tester.tap(find.widgetWithText(TextButton, '保存安排'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byTooltip('移除这段安排'), findsOneWidget);
      expect(controller.data.entries, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}
