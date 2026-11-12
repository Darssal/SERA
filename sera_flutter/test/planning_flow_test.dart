import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/planning_ai_provider.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/domain/planning_service.dart';
import 'package:sera_flutter/domain/seed_data.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _StoredWorkspace implements WorkspaceRepository {
  _StoredWorkspace(this.value);
  Workspace? value;
  Completer<void>? nextSaveGate;
  @override
  String get mode => 'test-persistence';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async => value = null;
  @override
  Future<Workspace> save(
    Workspace workspace, {
    required int expectedRevision,
  }) async {
    final gate = nextSaveGate;
    nextSaveGate = null;
    if (gate != null) await gate.future;
    if ((value?.revision ?? 0) != expectedRevision) {
      throw const RepositoryException('工作区已有后续修改，请刷新。', conflict: true);
    }
    value = Workspace.fromJson(
      workspace.copyWith(revision: expectedRevision + 1).toJson(),
    );
    return value!;
  }
}

class _ScriptedAi extends _StoredWorkspace
    implements PlanningAiProvider, InputUnderstandingProvider {
  _ScriptedAi(super.value);
  final requests = <Map<String, Object>>[];
  final responses = <Future<AiPlanResult> Function()>[];
  final understandingRequests = <Json>[];
  @override
  Future<AiUnderstanding> understandInput({
    required Json input,
    required String requestId,
    void Function(String stage)? onStage,
  }) async {
    understandingRequests.add(input);
    return AiUnderstanding(
      intent: 'goal',
      title: '学习英语',
      summary: '通过自测、练习和回顾提升日常英语对话能力。',
      outcome: '能进行日常英语对话',
      model: 'understanding-test-model',
      deadline: DateTime.parse('2026-11-20T18:00:00+08:00'),
      dailyBudget: 90,
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
    requests.add({
      'title': title,
      'deadline': deadline,
      'dailyBudget': dailyBudget,
      'notes': notes,
      'prompt': prompt,
      'requestId': ?requestId,
    });
    return responses.removeAt(0)();
  }
}

const _aiResult = AiPlanResult(
  model: 'test-model',
  tasks: [
    TaskOutline(
      title: '完成英语基础水平自测',
      estimatedMinutes: 30,
      notes: '记录词汇、听力和口语薄弱点',
      checklist: ['记录测试结果'],
    ),
    TaskOutline(title: '练习一段日常英语对话', estimatedMinutes: 30, notes: '朗读并复述两遍'),
    TaskOutline(title: '回顾学习记录并调整练习', estimatedMinutes: 30, notes: '记录下一次练习重点'),
  ],
);

final _today = DateTime(2026, 10, 28);

Future<void> _pump(
  WidgetTester tester,
  SeraController c,
  String location,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    SeraApp(key: UniqueKey(), controller: c, initialLocation: location),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _tap(WidgetTester tester, String label) async {
  var button = find.widgetWithText(SeraButton, label);
  if (button.evaluate().isEmpty) {
    button = find.widgetWithText(TextButton, label);
  }
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _dispose(WidgetTester tester, SeraController controller) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets(
    'goal input, awaited AI, editable draft and awaited commit form one flow',
    (tester) async {
      final repo = _ScriptedAi(const Workspace(revision: 1));
      final aiGate = Completer<AiPlanResult>();
      repo.responses.add(() => aiGate.future);
      final c = SeraController(repository: repo, today: _today);
      await c.initialize();
      await _pump(
        tester,
        c,
        '/05?prompt=${Uri.encodeComponent('学习英语，提高日常对话能力')}',
      );
      expect(repo.understandingRequests, isEmpty);
      await _tap(tester, '理解这段输入');
      await tester.pumpAndSettle();
      expect(repo.understandingRequests.single['prompt'], '学习英语，提高日常对话能力');
      await _tap(tester, '修改要求');
      expect(find.widgetWithText(AppBar, '确认目标'), findsOneWidget);
      expect(find.text('目标名称'), findsOneWidget);
      final titleField = find.byType(TextFormField).first;
      expect(tester.widget<TextFormField>(titleField).controller!.text, '学习英语');
      await tester.enterText(titleField, '提高英语日常对话能力');
      await _tap(tester, '生成可执行的计划');
      expect(find.widgetWithText(AppBar, '正在规划'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(c.busy, isTrue);
      expect(c.data.drafts, isEmpty);
      expect(c.data.tasks, isEmpty);
      expect(repo.requests.single['prompt'], '学习英语，提高日常对话能力');
      aiGate.complete(_aiResult);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '计划草案'), findsOneWidget);
      expect(c.data.drafts.single.source, 'siliconflow');
      expect(c.data.drafts.single.model, 'test-model');
      expect(c.data.drafts.single.items, hasLength(3));
      expect(
        c.data.tasks,
        isEmpty,
        reason: 'Generation must not create committed tasks.',
      );

      final firstTaskText = find.text('完成英语基础水平自测');
      await tester.ensureVisible(firstTaskText);
      await tester.tap(firstTaskText);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '编辑任务'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).first, '完成英语听说水平自测');
      await _tap(tester, '保存到草案');
      await tester.pumpAndSettle();
      expect(c.data.drafts.single.items.first.task.title, '完成英语听说水平自测');
      expect(c.data.entries, isEmpty);
      expect(find.textContaining('创建 1 个目标、3 项任务'), findsOneWidget);
      expect(find.widgetWithText(AppBar, '计划草案'), findsOneWidget);

      final saveGate = Completer<void>();
      repo.nextSaveGate = saveGate;
      final confirm = find.widgetWithText(SeraButton, '确认创建 3 项任务与安排');
      await tester.ensureVisible(confirm);
      // Two rapid activations before the next frame must still start one save.
      await tester.tap(confirm);
      await tester.tap(confirm);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.widgetWithText(AppBar, '正在安排'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        c.data.tasks,
        isEmpty,
        reason: '51 waits for confirmed repository persistence.',
      );
      saveGate.complete();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '计划'), findsOneWidget);
      expect(find.widgetWithText(AppBar, '目标详情'), findsNothing);
      expect(c.data.tasks, hasLength(3));
      expect(c.data.entries, hasLength(3));
      expect(c.data.goals, hasLength(1));
      expect(c.data.drafts.single.status, 'committed');
      expect(repo.value!.tasks.first.title, '完成英语听说水平自测');
      await c.commitDraft(c.data.drafts.single.id);
      expect(
        c.data.tasks,
        hasLength(3),
        reason: 'A repeated confirmation is idempotent.',
      );
      expect(tester.takeException(), isNull);
      await _dispose(tester, c);
    },
  );

  testWidgets(
    'a changed calendar rechecks the edited draft before a new explicit confirmation',
    (tester) async {
      final repo = _ScriptedAi(const Workspace(revision: 1));
      repo.responses.add(() async => _aiResult);
      final c = SeraController(repository: repo, today: _today);
      await c.initialize();
      final draft = await c.generatePlan(
        title: '英语口语备考草案',
        deadline: DateTime(2026, 11, 20, 18),
        dailyBudget: 90,
      );
      final original = draft.items.first;
      await c.updateDraftItem(
        draft.id,
        PlannedTask(
          task: original.task.copyWith(title: '保留人工修改的自测任务'),
          entry: original.entry,
          additionalEntries: original.additionalEntries,
        ),
      );
      await c.saveEntry(
        CalendarEntry(
          id: 'later-meeting',
          title: '后来添加的会议',
          start: original.entry!.start,
          end: original.entry!.end,
          locked: true,
        ),
      );
      await _pump(tester, c, '/08?draftId=${draft.id}&from=goals');
      await _tap(tester, '确认创建 3 项任务与安排');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '检查草案'), findsOneWidget);
      expect(c.data.goals, isEmpty);
      expect(c.data.tasks, isEmpty);
      expect(c.data.entries.single.id, 'later-meeting');

      await _tap(tester, '保留编辑，重新检查安排');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '计划草案'), findsOneWidget);
      final checked = c.draft(draft.id)!;
      expect(checked.items.first.task.title, '保留人工修改的自测任务');
      expect(checked.items.first.entry!.start, isNot(original.entry!.start));
      expect(checked.status, 'draft');
      expect(
        c.data.tasks,
        isEmpty,
        reason: 'Rechecking never creates the reviewed plan.',
      );
      expect(repo.value!.tasks, isEmpty);

      await _tap(tester, '确认创建 3 项任务与安排');
      await tester.pumpAndSettle();
      expect(c.data.tasks, hasLength(3));
      expect(c.data.goals, hasLength(1));
      expect(c.data.entries, hasLength(4));
      expect(c.task(original.task.id)!.title, '保留人工修改的自测任务');
      expect(c.draft(draft.id)!.status, 'committed');
      expect(repo.requests, hasLength(1));
      expect(tester.takeException(), isNull);
      await _dispose(tester, c);
    },
  );

  testWidgets(
    'AI failure retains inputs and retries without silently falling back',
    (tester) async {
      final repo = _ScriptedAi(const Workspace(revision: 1));
      final retryGate = Completer<AiPlanResult>();
      repo.responses.addAll([
        () => Future.error(const RepositoryException('AI 服务暂时不可用，请重试。')),
        () => retryGate.future,
      ]);
      final c = SeraController(repository: repo, today: _today);
      await c.initialize();
      await c.savePlanningSession(
        PlanningSession(
          id: 'planning-failure',
          updatedAt: _today,
          deadline: DateTime(2026, 11, 20, 18),
          stage: 'clarify',
        ),
      );
      await _pump(tester, c, '/06?sessionId=planning-failure');
      await tester.enterText(find.byType(TextFormField).first, '练习英语口语');
      await _tap(tester, '生成可执行的计划');
      await tester.pumpAndSettle();
      expect(find.text('这次没能完成规划'), findsOneWidget);
      expect(find.text('AI 服务暂时不可用，请重试。'), findsNothing);
      await tester.tap(find.text('查看详情'));
      await tester.pumpAndSettle();
      expect(find.text('AI 服务暂时不可用，请重试。'), findsOneWidget);
      expect(
        c.data.drafts,
        isEmpty,
        reason: 'An AI failure may not create a template draft.',
      );
      expect(c.data.tasks, isEmpty);
      await _tap(tester, '重新生成计划');
      expect(find.widgetWithText(AppBar, '正在规划'), findsOneWidget);
      expect(repo.requests, hasLength(2));
      expect(repo.requests.last['title'], '练习英语口语');
      retryGate.complete(_aiResult);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '计划草案'), findsOneWidget);
      expect(c.data.drafts.single.source, 'siliconflow');
      expect(c.data.drafts.single.items, hasLength(3));
      expect(c.data.tasks, isEmpty);
      expect(tester.takeException(), isNull);
      await _dispose(tester, c);
    },
  );

  testWidgets(
    'Today understanding and generation retain the original page until creation ends',
    (tester) async {
      final repo = _ScriptedAi(const Workspace(revision: 1));
      final aiGate = Completer<AiPlanResult>();
      repo.responses.add(() => aiGate.future);
      final c = SeraController(repository: repo, today: _today);
      await c.initialize();
      await _pump(tester, c, '/04');
      await tester.tap(find.byKey(const ValueKey('today-capture')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('文字输入'));
      await tester.pumpAndSettle();
      final homePrompt = tester
          .widget<TextField>(find.byType(TextField))
          .controller;
      await tester.enterText(find.byType(TextField), '学习英语，提高日常对话能力');
      await _tap(tester, '让 AI 安排');
      expect(repo.understandingRequests, hasLength(1));
      await _tap(tester, '生成计划');
      expect(find.widgetWithText(AppBar, '正在规划'), findsOneWidget);
      expect(repo.requests, hasLength(1));
      expect(c.data.tasks, isEmpty);
      aiGate.complete(_aiResult);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '计划草案'), findsOneWidget);
      await _tap(tester, '确认创建 3 项任务与安排');
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, '今日'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byKey(const ValueKey('today-capture')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('文字输入'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller,
        same(homePrompt),
      );
      expect(homePrompt!.text, isEmpty);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(c.data.goals, hasLength(1));
      expect(c.data.tasks, hasLength(3));
      expect(repo.understandingRequests, hasLength(1));
      expect(repo.requests, hasLength(1));
      expect(find.widgetWithText(AppBar, '目标详情'), findsNothing);
      expect(tester.takeException(), isNull);
      await _dispose(tester, c);
    },
  );

  testWidgets(
    'creating from a History draft retains its selected tab and page instance',
    (tester) async {
      final repo = _ScriptedAi(const Workspace(revision: 1));
      repo.responses.add(() async => _aiResult);
      final c = SeraController(repository: repo, today: _today);
      await c.initialize();
      final draft = await c.generatePlan(
        title: '英语口语备考草案',
        deadline: DateTime(2026, 11, 20, 18),
        dailyBudget: 90,
        prompt: '每天练习英语口语',
      );
      await _pump(tester, c, '/34');
      await tester.tap(find.text('草案'));
      await tester.pumpAndSettle();
      final historyTabs = tester.element(
        find.byKey(const ValueKey('planning-history-tabs')),
      );
      await tester.ensureVisible(find.text(draft.goal.title));
      await tester.tap(find.text(draft.goal.title));
      await tester.pumpAndSettle();
      await _tap(tester, '确认创建 3 项任务与安排');
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, '规划记录'), findsOneWidget);
      expect(
        tester.element(find.byKey(const ValueKey('planning-history-tabs'))),
        same(historyTabs),
      );
      expect(
        tester
            .widget<SegmentedButton<String>>(
              find.byKey(const ValueKey('planning-history-tabs')),
            )
            .selected,
        {'drafts'},
      );
      expect(find.text(draft.goal.title), findsOneWidget);
      expect(c.data.goals, hasLength(1));
      expect(c.data.tasks, hasLength(3));
      expect(tester.takeException(), isNull);
      await _dispose(tester, c);
    },
  );

  testWidgets(
    'creating a searched draft returns to the existing search query',
    (tester) async {
      final repo = _ScriptedAi(const Workspace(revision: 1));
      repo.responses.add(() async => _aiResult);
      final c = SeraController(repository: repo, today: _today);
      await c.initialize();
      final draft = await c.generatePlan(
        title: '英语口语备考草案',
        deadline: DateTime(2026, 11, 20, 18),
        dailyBudget: 90,
        prompt: '每天练习英语口语',
      );
      await _pump(tester, c, '/35');
      final queryController = tester
          .widget<TextField>(find.byType(TextField))
          .controller;
      await tester.enterText(find.byType(TextField), '英语');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(draft.goal.title));
      await tester.tap(find.text(draft.goal.title));
      await tester.pumpAndSettle();
      await _tap(tester, '确认创建 3 项任务与安排');
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, '搜索'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller,
        same(queryController),
      );
      expect(queryController!.text, '英语');
      expect(find.text(draft.goal.title), findsWidgets);
      expect(c.data.goals, hasLength(1));
      expect(c.data.tasks, hasLength(3));
      expect(find.widgetWithText(AppBar, '目标详情'), findsNothing);
      expect(tester.takeException(), isNull);
      await _dispose(tester, c);
    },
  );

  testWidgets(
    'replan confirmation persists a real slot and undo restores the original',
    (tester) async {
      final repo = _StoredWorkspace(
        createSeedWorkspace(_today).copyWith(revision: 1),
      );
      final c = SeraController(repository: repo, today: _today);
      await c.initialize();
      final original = c.entryForTask('task-1')!;
      await _pump(tester, c, '/23?taskId=task-1');
      expect(find.widgetWithText(AppBar, '确认这次调整'), findsOneWidget);
      await _tap(tester, '确认调整 1 项任务');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '日程'), findsOneWidget);
      expect(find.widgetWithText(AppBar, '调整完成'), findsNothing);
      expect(find.text('安排已调整'), findsOneWidget);
      final adjusted = c.entryForTask('task-1')!;
      expect(adjusted.start, isNot(original.start));
      expect(adjusted.minutes, original.minutes);
      expect(
        repo.value!.entries.firstWhere((e) => e.taskId == 'task-1').start,
        adjusted.start,
      );
      await _tap(tester, '撤销');
      await tester.pumpAndSettle();
      expect(c.entryForTask('task-1')!.start, original.start);
      expect(
        repo.value!.entries.firstWhere((e) => e.taskId == 'task-1').start,
        original.start,
      );
      expect(tester.takeException(), isNull);
      await _dispose(tester, c);
    },
  );

  testWidgets(
    'undo conflict preserves later persisted changes and opens comparison',
    (tester) async {
      final repo = _StoredWorkspace(
        createSeedWorkspace(_today).copyWith(revision: 1),
      );
      final c = SeraController(repository: repo, today: _today);
      await c.initialize();
      await _pump(tester, c, '/23?taskId=task-1');
      await _tap(tester, '确认调整 1 项任务');
      await tester.pumpAndSettle();
      final later = c.entryForTask('task-1')!;
      final external = later.copyWith(
        start: later.start.add(const Duration(minutes: 15)),
        end: later.end.add(const Duration(minutes: 15)),
        revision: later.revision + 1,
      );
      repo.value = repo.value!.copyWith(
        revision: repo.value!.revision + 1,
        entries: repo.value!.entries
            .map((e) => e.id == external.id ? external : e)
            .toList(),
      );
      await _tap(tester, '撤销');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '暂时无法撤销'), findsOneWidget);
      expect(
        repo.value!.entries.firstWhere((e) => e.taskId == 'task-1').start,
        external.start,
        reason:
            'A stale client must not overwrite newer server data during undo.',
      );
      expect(c.error, contains('后续修改'));
      expect(tester.takeException(), isNull);
      await _dispose(tester, c);
    },
  );
}
