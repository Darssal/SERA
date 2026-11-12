import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/planning_ai_provider.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/domain/seed_data.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';

class _Store implements WorkspaceRepository {
  _Store(this.value);
  Workspace? value;
  @override
  String get mode => 'test';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async => value = null;
  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    if ((value?.revision ?? 0) != expectedRevision) {
      throw const RepositoryException('版本冲突', conflict: true);
    }
    return value = Workspace.fromJson(
      next.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }
}

class _SyncStore extends _Store implements SynchronizingWorkspaceRepository {
  _SyncStore(super.value, this.syncConflict);
  @override
  int pendingCount = 1;
  @override
  bool isOffline = false;
  @override
  Json? syncConflict;
  bool? resolvedLocal;
  @override
  Future<Workspace?> synchronize() async => value;
  @override
  Future<Workspace?> resolveConflict({required bool keepLocal}) async {
    resolvedLocal = keepLocal;
    pendingCount = 0;
    syncConflict = null;
    if (!keepLocal) {
      value = value!.copyWith(
        tasks: [value!.tasks.single.copyWith(title: '云端更新的阅读任务')],
      );
    }
    return value;
  }
}

class _SemanticStore extends _Store implements InputUnderstandingProvider {
  _SemanticStore(super.value);

  @override
  Future<AiUnderstanding> understandInput({
    required Json input,
    required String requestId,
    void Function(String stage)? onStage,
  }) async => AiUnderstanding(
    intent: 'goal',
    title: input['prompt'] as String,
    summary: '按用户输入准备分步推进的目标，截止时间需要在下一页核对。',
    outcome: '完成输入中描述的目标',
    model: 'persistence-semantic-test-model',
    deadline: DateTime.parse('2026-11-06T18:00:00+08:00'),
    dailyBudget: 90,
  );
}

Future<void> _pump(WidgetTester tester, SeraController c, String path) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    SeraApp(key: UniqueKey(), controller: c, initialLocation: path),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String text) async {
  var button = find.widgetWithText(SeraButton, text);
  if (button.evaluate().isEmpty) {
    button = find.widgetWithText(TextButton, text);
  }
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  final today = DateTime(2026, 10, 28);
  testWidgets(
    'Today capture and fast system back retain the edited planning session',
    (tester) async {
      final store = _SemanticStore(const Workspace(revision: 1));
      final c = SeraController(repository: store, today: today);
      await c.initialize();
      await _pump(tester, c, '/04');
      expect(find.widgetWithText(AppBar, '今日'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byKey(const ValueKey('today-capture')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('文字输入'));
      await tester.pumpAndSettle();
      final composer = find.byType(TextField).first;
      expect(tester.widget<TextField>(composer).controller!.text, isEmpty);
      await tester.enterText(composer, '下周五完成视频剪辑');
      await _tap(tester, '让 AI 安排');
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('planning-original-message')),
            )
            .data,
        '下周五完成视频剪辑',
      );
      expect(store.value!.planningSessions.single.understanding, isNotNull);
      await _tap(tester, '修改要求');
      await tester.enterText(find.byType(TextFormField).first, '完成旅行视频剪辑');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(store.value!.planningSessions.single.title, '完成旅行视频剪辑');
      await _tap(tester, '修改要求');
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller!
            .text,
        '完成旅行视频剪辑',
      );
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'new calendar event preserves existing events and uses account wall time',
    (tester) async {
      final old = CalendarEntry(
        id: 'existing-event',
        title: '已有会议',
        start: inTimeZone(
          DateTime(2026, 10, 29, 9),
          'America/New_York',
          wallClock: true,
        ),
        end: inTimeZone(
          DateTime(2026, 10, 29, 10),
          'America/New_York',
          wallClock: true,
        ),
        timeZone: 'America/New_York',
      );
      final store = _Store(
        Workspace(
          revision: 1,
          entries: [old],
          preferences: const SeraPreferences(timeZone: 'America/New_York'),
        ),
      );
      final c = SeraController(repository: store, today: today);
      await c.initialize();
      await _pump(tester, c, '/16');
      expect(find.widgetWithText(AppBar, '添加日程'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).first, '新增讨论安排');
      await _tap(tester, '保存日程');
      expect(c.data.entries, hasLength(2));
      expect(c.entry(old.id)!.title, '已有会议');
      final saved = c.data.entries.singleWhere((e) => e.id != old.id);
      expect(saved.start.hour, 14);
      expect(saved.timeZone, 'America/New_York');
      expect(saved.start.toUtc().hour, 18);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'sync conflict shows both contents and requires an explicit choice',
    (tester) async {
      const task = SeraTask(id: 'sync-task', title: '本机修改的阅读任务');
      final store = _SyncStore(const Workspace(revision: 1, tasks: [task]), {
        'conflicts': [
          {
            'entityType': 'tasks',
            'entityId': task.id,
            'serverValue': task.copyWith(title: '云端更新的阅读任务').toJson(),
          },
        ],
      });
      final c = SeraController(repository: store, today: today);
      await c.initialize();
      await _pump(tester, c, '/40');
      expect(find.textContaining('本机修改的阅读任务'), findsOneWidget);
      expect(find.textContaining('云端更新的阅读任务'), findsOneWidget);
      await _tap(tester, '采用云端内容');
      expect(store.resolvedLocal, isNull);
      expect(find.textContaining('这台设备尚未同步的修改将被放弃'), findsOneWidget);
      await tester.tap(find.text('确认处理'));
      await tester.pumpAndSettle();
      expect(store.resolvedLocal, isFalse);
      expect(c.pendingSyncCount, 0);
      expect(c.syncConflict, isNull);
      expect(c.task(task.id)!.title, '云端更新的阅读任务');
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets('acknowledging a reminder persists its exact schedule identity', (
    tester,
  ) async {
    final start = DateTime.now().add(const Duration(hours: 1));
    const task = SeraTask(id: 'reminder-task', title: '准备阅读笔记');
    final entry = CalendarEntry(
      id: 'reminder-entry',
      title: task.title,
      taskId: task.id,
      start: start,
      end: start.add(const Duration(minutes: 30)),
    );
    final store = _Store(
      Workspace(revision: 1, tasks: [task], entries: [entry]),
    );
    final c = SeraController(repository: store, today: today);
    await c.initialize();
    await _pump(tester, c, '/27');
    final ack = find.widgetWithText(TextButton, '已了解').first;
    await tester.ensureVisible(ack);
    await tester.tap(ack);
    await tester.pumpAndSettle();
    final state = c.data.reminderStates['${entry.id}:start'] as Map;
    expect(state['status'], 'ack');
    expect(
      DateTime.parse(state['scheduledAt'] as String),
      entry.start.subtract(const Duration(minutes: 10)).toUtc(),
    );
    expect(store.value!.reminderStates['${entry.id}:start'], state);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets(
    'date-only deadline and extended task fields survive a title edit',
    (tester) async {
      final task = SeraTask(
        id: 'date-task',
        title: '完成课程阅读',
        dueDate: '2026-11-06',
        timeZone: 'Asia/Hong_Kong',
        priority: 'high',
        splittable: true,
        minBlockMinutes: 15,
        remainingMinutes: 45,
        estimatedMinutes: 60,
        checklist: ['读完章节', '记录要点'],
      );
      final store = _Store(Workspace(revision: 1, tasks: [task]));
      final c = SeraController(repository: store, today: today);
      await c.initialize();
      await _pump(tester, c, '/09?taskId=date-task');
      expect(find.text('截止只指定日期'), findsOneWidget);
      expect(find.textContaining('23:59'), findsNothing);
      await tester.enterText(find.byType(TextFormField).first, '完成课程第二章阅读');
      await _tap(tester, '保存任务');
      final saved = c.task(task.id)!;
      expect(saved.title, '完成课程第二章阅读');
      expect(saved.dueAt, isNull);
      expect(saved.dueDate, '2026-11-06');
      expect(saved.priority, 'high');
      expect(saved.remainingMinutes, 45);
      expect(saved.checklist, task.checklist);
      expect(saved.splittable, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets(
    'editing a split task saves all blocks atomically and keeps partial planning',
    (tester) async {
      final task = SeraTask(
        id: 'split-task',
        title: '练习英语对话',
        estimatedMinutes: 60,
        splittable: true,
        minBlockMinutes: 15,
        dueAt: DateTime(2026, 10, 29, 18),
      );
      final blocks = [
        for (final pair in [('part-1', 14), ('part-2', 15)])
          CalendarEntry(
            id: pair.$1,
            title: task.title,
            taskId: task.id,
            start: DateTime(2026, 10, 28, pair.$2),
            end: DateTime(2026, 10, 28, pair.$2, 30),
          ),
      ];
      final store = _Store(
        Workspace(revision: 1, tasks: [task], entries: blocks),
      );
      final c = SeraController(repository: store, today: today);
      await c.initialize();
      await _pump(tester, c, '/09?taskId=split-task');
      final length = find.descendant(
        of: find.widgetWithText(SeraInput, '第一段用时（分钟）'),
        matching: find.byType(TextFormField),
      );
      await tester.ensureVisible(length);
      await tester.enterText(length, '20');
      await _tap(tester, '保存任务');
      expect(c.entriesForTask(task.id), hasLength(2));
      expect(c.entriesForTask(task.id).first.minutes, 20);
      expect(c.entriesForTask(task.id).last.minutes, 30);
      expect(c.schedulingState(task.id), 'partial');
      expect(store.value!.entries, hasLength(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'planning resumes persisted inputs and a fresh account starts empty',
    (tester) async {
      final store = _SemanticStore(const Workspace(revision: 1));
      final c = SeraController(
        repository: store,
        today: today,
        accountId: 'user-a',
      );
      await c.initialize();
      await _pump(
        tester,
        c,
        '/05?prompt=${Uri.encodeComponent('下周五完成英语对话练习')}',
      );
      await _tap(tester, '理解这段输入');
      await _tap(tester, '修改要求');
      await tester.enterText(
        find.byType(TextFormField).last,
        '每天练习20分钟，周末做一次复习。',
      );
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      expect(store.value!.planningSessions.single.notes, contains('周末'));
      final session = store.value!.planningSessions.single;
      expect(session.deadline!.toUtc(), DateTime.parse('2026-11-06T10:00:00Z'));
      expect(
        session.understanding!['model'],
        'persistence-semantic-test-model',
      );
      final restored = SeraController(
        repository: store,
        today: today,
        accountId: 'user-a',
      );
      await restored.initialize();
      await _pump(tester, restored, '/06?sessionId=${session.id}');
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller!
            .text,
        '下周五完成英语对话练习',
      );
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).last)
            .controller!
            .text,
        contains('周末'),
      );
      final other = SeraController(
        repository: _Store(const Workspace(revision: 1)),
        today: today,
        accountId: 'user-b',
      );
      await other.initialize();
      await _pump(tester, other, '/06');
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller!
            .text,
        isEmpty,
      );
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).last)
            .controller!
            .text,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      restored.dispose();
      other.dispose();
    },
  );

  testWidgets(
    'editing a goal updates its existing tasks instead of creating another goal',
    (tester) async {
      final seed = createSeedWorkspace(today);
      final store = _Store(
        seed.copyWith(
          revision: 1,
          preferences: seed.preferences.copyWith(
            weekdays: [1, 2, 3, 4, 5, 6, 7],
          ),
        ),
      );
      final c = SeraController(repository: store, today: today);
      await c.initialize();
      final goal = c.data.goals.first;
      final goalCount = c.data.goals.length, taskCount = c.data.tasks.length;
      await _pump(tester, c, '/21?goalId=${goal.id}');
      await _tap(tester, '编辑目标计划');
      final draft = c.data.drafts.last;
      expect(draft.targetGoalId, goal.id);
      await c.revalidateDraft(draft.id);
      await _tap(tester, '确认更新目标计划');
      expect(find.widgetWithText(AppBar, '目标详情'), findsOneWidget);
      expect(c.data.goals.length, goalCount);
      expect(c.data.tasks.length, taskCount);
      expect(c.data.goals.where((g) => g.id == goal.id), hasLength(1));
      expect(c.data.drafts.last.status, 'committed');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );

  testWidgets(
    'paused focus survives rebuilding and finishing stores the accumulated duration',
    (tester) async {
      final seed = createSeedWorkspace(today);
      final task = seed.tasks.first;
      final store = _Store(
        seed.copyWith(
          revision: 1,
          focusSession: FocusSession(
            id: 'focus-resume',
            taskId: task.id,
            startedAt: DateTime.now().subtract(const Duration(minutes: 2)),
            accumulatedSeconds: 73,
            isRunning: false,
          ),
        ),
      );
      final c = SeraController(repository: store, today: today);
      await c.initialize();
      await _pump(tester, c, '/25?taskId=${task.id}');
      expect(c.data.focusSession!.isRunning, isFalse);
      expect(find.textContaining('已暂停'), findsOneWidget);
      final c2 = SeraController(repository: store, today: today);
      await c2.initialize();
      await _pump(tester, c2, '/25?taskId=${task.id}');
      expect(c2.data.focusSession!.accumulatedSeconds, 73);
      final recordCount = c2.data.focusRecords.length;
      await tester.tap(find.byTooltip('结束并保存专注'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(c2.data.focusSession, isNull);
      expect(c2.data.focusRecords, hasLength(recordCount + 1));
      expect(c2.data.focusRecords.last.seconds, 73);
      expect(c2.task(task.id)!.actualSeconds, task.actualSeconds + 73);
      expect(find.widgetWithText(AppBar, '专注结束'), findsOneWidget);
      // Finishing the timer records actual time and still lets the user
      // decide completion. Only that explicit choice ends this task journey.
      expect(c2.task(task.id)!.done, task.done);
      await _tap(tester, '已完成，更新任务进度');
      final router = GoRouter.of(tester.element(find.byType(SeraScaffold)));
      expect(router.state.uri.path, '/17');
      expect(router.state.uri.queryParameters['filter'], 'done');
      expect(router.canPop(), isFalse);
      expect(c2.task(task.id)!.done, isTrue);
      expect(find.widgetWithText(AppBar, '专注结束'), findsNothing);
      await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
      await tester.pumpAndSettle();
      expect(c2.task(task.id)!.done, isFalse);
      expect(c2.task(task.id)!.actualSeconds, task.actualSeconds + 73);
      expect(c2.data.focusRecords.last.seconds, 73);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      c2.dispose();
    },
  );

  testWidgets(
    'review is saved in the account workspace and restored into the form',
    (tester) async {
      final store = _Store(createSeedWorkspace(today).copyWith(revision: 1));
      final c = SeraController(
        repository: store,
        today: today,
        accountId: 'review-a',
      );
      await c.initialize();
      await _pump(tester, c, '/28');
      await tester.enterText(find.byType(TextFormField), '今天先处理了最重要的准备工作。');
      await _tap(tester, '保存回顾');
      final review = c.data.reviews.single;
      expect(jsonDecode(review.feedback)['note'], contains('准备工作'));
      await _pump(tester, c, '/28');
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        contains('准备工作'),
      );
      expect(store.value!.reviews.single.id, review.id);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}
