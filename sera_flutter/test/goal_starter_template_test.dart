import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/planning_ai_provider.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';

import 'fixtures/legacy_goal_template_fixture.dart';

final _now = readZoned('2026-11-02T09:00:00+08:00', 'Asia/Hong_Kong')!;
const _preferences = SeraPreferences(
  weekdays: [1, 2, 3, 4, 5, 6, 7],
  startMinute: 9 * 60,
  endMinute: 17 * 60,
  dailyBudget: 120,
  bufferMinutes: 5,
);

class _StarterStore implements WorkspaceRepository, PlanningAiProvider {
  _StarterStore([Workspace? value])
    : value = value ?? const Workspace(preferences: _preferences);

  Workspace value;
  int saves = 0;
  int aiCalls = 0;
  bool failNextSave = false;

  @override
  String get mode => 'starter-test';

  @override
  Future<Workspace?> load() async => value;

  @override
  Future<void> clear() async => value = const Workspace();

  @override
  Future<Workspace> save(
    Workspace workspace, {
    required int expectedRevision,
  }) async {
    if (failNextSave) {
      failNextSave = false;
      throw const RepositoryException('测试保存失败');
    }
    if (expectedRevision != value.revision) {
      throw const RepositoryException('版本冲突', conflict: true);
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
  }) async {
    aiCalls++;
    throw StateError(
      'Reading or confirming a saved draft must not request AI.',
    );
  }
}

Future<SeraController> _controller(
  _StarterStore store, {
  DateTime? now,
  Future<Workspace> Function(Workspace, DateTime)? onBeforePlanning,
}) async {
  final controller = SeraController(
    repository: store,
    today: now ?? _now,
    seedDemo: false,
    onBeforePlanning: onBeforePlanning,
  );
  await controller.initialize();
  addTearDown(controller.dispose);
  return controller;
}

PlanDraft _seedLegacy(_StarterStore store, {DateTime? now}) {
  final draft = legacyGoalDraft(store.value, now ?? _now);
  store.value = Workspace.fromJson(
    store.value.copyWith(drafts: [...store.value.drafts, draft]).toJson(),
  );
  return store.value.drafts.last;
}

void main() {
  test(
    'historical drafts reload without formal records, writes or AI requests',
    () async {
      final store = _StarterStore();
      final draft = _seedLegacy(store);
      final controller = await _controller(store);
      final reopened = await _controller(store);
      for (final current in [controller, reopened]) {
        expect(current.draft(draft.id)!.toJson(), draft.toJson());
        expect(current.draft(draft.id)!.source, 'local-template');
        expect(current.data.tasks, isEmpty);
        expect(current.data.entries, isEmpty);
        expect(current.data.goals, isEmpty);
        expect(current.data.preferences.toJson(), _preferences.toJson());
      }
      expect(store.saves, 0);
      expect(store.aiCalls, 0);
    },
  );

  test(
    'concurrent confirmation and restored retry create one set of records',
    () async {
      final store = _StarterStore();
      final draft = _seedLegacy(store);
      final controller = await _controller(store);
      await Future.wait([
        controller.commitDraft(draft.id),
        controller.commitDraft(draft.id),
      ]);
      final committed = controller.data.toJson();
      final savedCount = store.saves;
      final reopened = await _controller(store, now: calendarDay(_now, 1));
      await reopened.commitDraft(draft.id);
      expect(reopened.data.toJson(), committed);
      expect(store.saves, savedCount);
      expect(reopened.data.goals, hasLength(1));
      expect(reopened.data.tasks, hasLength(draft.items.length));
      expect(
        reopened.data.entries,
        hasLength(draft.items.expand((item) => item.blocks).length),
      );
      expect(reopened.data.drafts.single.status, 'committed');
      expect(store.aiCalls, 0);
    },
  );

  test(
    'confirmation appends linked objects and preserves all existing work',
    () async {
      final oldTask = SeraTask(
        id: 'existing-task',
        goalId: 'existing-goal',
        title: '原有任务',
        dueAt: atMinute(_now, 17 * 60),
        notes: '保留原有内容',
      );
      final oldEntry = CalendarEntry(
        id: 'existing-entry',
        taskId: oldTask.id,
        title: oldTask.title,
        start: _now,
        end: _now.add(const Duration(minutes: 30)),
      );
      final oldGoal = SeraGoal(
        id: 'existing-goal',
        title: '原有目标',
        deadline: atMinute(calendarDay(_now, 14), 1439),
        taskIds: [oldTask.id],
      );
      final store = _StarterStore(
        Workspace(
          preferences: _preferences,
          tasks: [oldTask],
          entries: [oldEntry],
          goals: [oldGoal],
        ),
      );
      final draft = _seedLegacy(store);
      final controller = await _controller(store);
      final reviewed = draft.items.first;
      await controller.updateDraftItem(
        draft.id,
        PlannedTask(
          task: reviewed.task.copyWith(notes: '我修改的第一步'),
          entry: reviewed.entry,
          additionalEntries: reviewed.additionalEntries,
        ),
      );
      await controller.commitDraft(draft.id);
      final committed = controller.data.toJson();
      await controller.commitDraft(draft.id);
      expect(controller.data.toJson(), committed);
      expect(controller.task(oldTask.id)!.toJson(), oldTask.toJson());
      expect(controller.entry(oldEntry.id)!.toJson(), oldEntry.toJson());
      expect(controller.goal(oldGoal.id)!.toJson(), oldGoal.toJson());
      final createdGoal = controller.goal(draft.goal.id)!;
      expect(controller.tasksForGoal(createdGoal.id), hasLength(5));
      expect(
        createdGoal.taskIds.toSet(),
        draft.items.map((item) => item.task.id).toSet(),
      );
      expect(controller.task(reviewed.task.id)!.notes, '我修改的第一步');
      for (final item in draft.items) {
        expect(controller.task(item.task.id)!.goalId, createdGoal.id);
        expect(
          controller.entriesForTask(item.task.id).map((entry) => entry.id),
          item.blocks.map((entry) => entry.id),
        );
      }
      expect(controller.data.preferences.toJson(), _preferences.toJson());
      expect(controller.draft(draft.id)!.status, 'committed');
      expect(controller.data.tasks, hasLength(6));
      expect(store.aiCalls, 0);
    },
  );

  test(
    'historical draft deadlines and slots survive confirmation across DST',
    () async {
      final now = readZoned('2026-10-31T16:20:00-04:00', 'America/New_York')!;
      const preferences = SeraPreferences(
        weekdays: [1, 3, 5],
        startMinute: 9 * 60,
        endMinute: 11 * 60,
        dailyBudget: 60,
        bufferMinutes: 5,
        timeZone: 'America/New_York',
      );
      final store = _StarterStore(const Workspace(preferences: preferences));
      final draft = _seedLegacy(store, now: now);
      final controller = await _controller(store, now: now);
      await controller.commitDraft(draft.id);
      final reopened = await _controller(store, now: now);
      final deadline = reopened.goal(draft.goal.id)!.deadline;
      expect(calendarDateString(deadline), '2026-11-07');
      expect(deadline.hour, 23);
      expect(deadline.minute, 59);
      expect(deadline.timeZoneOffset, const Duration(hours: -5));
      expect(draft.needsPlanningConfirmation, isFalse);
      final minutesByDay = <String, int>{};
      for (final block in draft.items.expand((item) => item.blocks)) {
        expect(reopened.entry(block.id)!.start, block.start);
        expect(reopened.entry(block.id)!.end, block.end);
        expect([1, 3, 5], contains(block.start.weekday));
        expect(block.start.isBefore(now), isFalse);
        expect(block.end.isAfter(deadline), isFalse);
        expect(block.start.hour, greaterThanOrEqualTo(9));
        expect(block.end.hour, lessThanOrEqualTo(11));
        final day = calendarDateString(block.start);
        minutesByDay[day] = (minutesByDay[day] ?? 0) + block.minutes;
      }
      expect(minutesByDay, isNotEmpty);
      expect(minutesByDay.values.every((minutes) => minutes <= 60), isTrue);
      expect(controller.data.preferences.toJson(), preferences.toJson());
    },
  );

  test(
    'unavailable time remains a soft confirmation with all tasks retained',
    () async {
      const preferences = SeraPreferences(
        weekdays: [1, 2, 3, 4, 5, 6, 7],
        startMinute: 9 * 60,
        endMinute: 10 * 60,
        bufferMinutes: 0,
        dailyBudget: 60,
      );
      final busy = List.generate(
        8,
        (day) => CalendarEntry(
          id: 'busy-$day',
          title: '已有安排',
          start: atMinute(calendarDay(_now, day), 9 * 60),
          end: atMinute(calendarDay(_now, day), 10 * 60),
        ),
      );
      final store = _StarterStore(
        Workspace(preferences: preferences, entries: busy),
      );
      final draft = _seedLegacy(store);
      final controller = await _controller(store);
      expect(draft.items, hasLength(5));
      expect(draft.needsCapacityConfirmation, isTrue);
      expect(draft.items.every((item) => item.blocks.isEmpty), isTrue);
      await expectLater(
        controller.commitDraft(draft.id),
        throwsA(isA<RepositoryException>()),
      );
      expect(controller.data.tasks, isEmpty);
      await controller.confirmDraftPlanningLimits(draft.id);
      await controller.commitDraft(draft.id);
      expect(controller.data.tasks, hasLength(5));
      expect(
        controller.data.entries.map((entry) => entry.toJson()),
        busy.map((entry) => entry.toJson()),
      );
      expect(controller.data.preferences.toJson(), preferences.toJson());
      expect(store.aiCalls, 0);
    },
  );

  test('failed confirmation preserves the draft and retries without partial records', () async {
    final store = _StarterStore();
    final draft = _seedLegacy(store);
    final controller = await _controller(store);
    store.failNextSave = true;
    await expectLater(
      controller.commitDraft(draft.id),
      throwsA(isA<RepositoryException>()),
    );
    expect(store.value.drafts.single.toJson(), draft.toJson());
    expect(controller.data.tasks, isEmpty);
    expect(controller.data.entries, isEmpty);
    expect(controller.data.goals, isEmpty);
    final reopened = await _controller(store);
    await reopened.commitDraft(draft.id);
    await reopened.commitDraft(draft.id);
    expect(store.saves, 1);
    expect(reopened.data.goals, hasLength(1));
    expect(reopened.data.tasks, hasLength(draft.items.length));
    expect(reopened.data.drafts.single.status, 'committed');
    expect(store.aiCalls, 0);
  });

  test(
    'closing the owner during revalidation cannot commit a saved draft',
    () async {
      final store = _StarterStore();
      final draft = _seedLegacy(store);
      final entered = Completer<void>();
      final resume = Completer<Workspace>();
      final controller = SeraController(
        repository: store,
        today: _now,
        seedDemo: false,
        onBeforePlanning: (workspace, deadline) {
          entered.complete();
          return resume.future;
        },
      );
      await controller.initialize();
      final pending = controller.commitDraft(draft.id);
      final rejected = expectLater(
        pending,
        throwsA(isA<RepositoryException>()),
      );
      await entered.future;
      controller.dispose();
      resume.complete(store.value);
      await rejected;
      expect(store.saves, 0);
      expect(store.value.drafts.single.status, 'draft');
      expect(store.value.tasks, isEmpty);
      expect(store.value.goals, isEmpty);
      expect(store.aiCalls, 0);
    },
  );
}
