import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/data/planning_ai_provider.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/domain/planning_service.dart';

class MemoryRepository implements WorkspaceRepository {
  MemoryRepository([this.value]);
  Workspace? value;
  bool rejectNext = false;
  @override
  String get mode => 'test';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async {
    value = null;
  }

  @override
  Future<Workspace> save(
    Workspace workspace, {
    required int expectedRevision,
  }) async {
    if (rejectNext) {
      rejectNext = false;
      throw const RepositoryException('disk full');
    }
    if ((value?.revision ?? 0) != expectedRevision) {
      throw const RepositoryException('conflict', conflict: true);
    }
    value = Workspace.fromJson(
      jsonDecode(
        jsonEncode(workspace.copyWith(revision: expectedRevision + 1).toJson()),
      ) as Json,
    );
    return value!;
  }
}

class AiMemoryRepository extends MemoryRepository
    implements PlanningAiProvider {
  AiMemoryRepository() : super(const Workspace(revision: 1));
  bool fail = false;
  final requests = <String>[];
  @override
  Future<AiPlanResult> generateTaskBreakdown({
    required String title,
    required DateTime deadline,
    required int dailyBudget,
    String notes = '',
    String prompt = '',
    String? requestId,
  }) async {
    requests.add(title);
    if (fail) throw const RepositoryException('AI 服务暂时不可用');
    return const AiPlanResult(
      model: 'unit-model',
      tasks: [
        TaskOutline(
          title: '收集数据库实验结果',
          notes: '记录查询与索引性能差异',
          estimatedMinutes: 30,
          checklist: ['导出执行计划'],
        ),
        TaskOutline(title: '解释事务隔离级别', estimatedMinutes: 30),
        TaskOutline(title: '排练数据库课程答辩', estimatedMinutes: 30),
      ],
    );
  }
}

void main() {
  final today = DateTime(2026, 11, 2);
  Future<SeraController> empty([MemoryRepository? repository]) async {
    final controller = SeraController(
      repository: repository ?? MemoryRepository(const Workspace(revision: 1)),
      today: today,
    );
    await controller.initialize();
    return controller;
  }

  test(
    'first boot persists realistic seed once; subsequent boot preserves edits',
    () async {
      final repository = MemoryRepository();
      final controller = SeraController(repository: repository, today: today);
      await controller.initialize();
      expect(controller.data.tasks, hasLength(8));
      expect(controller.data.entries, hasLength(7));
      expect(controller.data.tasks.take(6).map((e) => e.estimatedMinutes), [
        45,
        45,
        60,
        60,
        30,
        30,
      ]);
      await controller.setDone('task-1', true);
      final reopened = SeraController(repository: repository, today: today);
      await reopened.initialize();
      expect(reopened.task('task-1')!.done, isTrue);
      expect(reopened.data.revision, 2);
    },
  );

  test(
    'draft generation is isolated; commit is atomic and idempotent',
    () async {
      final c = await empty();
      final plan = await c.generatePlan(
        title: '课程报告',
        deadline: today.add(const Duration(days: 8)),
        dailyBudget: 90,
        prompt: '准备报告',
      );
      expect(c.data.tasks, isEmpty);
      expect(c.data.entries, isEmpty);
      expect(c.data.goals, isEmpty);
      expect(c.data.drafts.single.prompt, '准备报告');
      expect(plan.totalMinutes, 270);
      await c.commitDraft(plan.id);
      expect(c.data.tasks, hasLength(6));
      expect(c.data.entries, hasLength(6));
      expect(c.data.goals.single.taskIds, hasLength(6));
      final revision = c.data.revision;
      await c.commitDraft(plan.id);
      expect(c.data.revision, revision);
      expect(c.data.tasks, hasLength(6));
    },
  );

  test(
    'planner obeys weekdays, budget, time window, buffers and meetings',
    () async {
      final meeting = CalendarEntry(
        id: 'meeting',
        title: '固定会议',
        start: today.add(const Duration(hours: 14)),
        end: today.add(const Duration(hours: 15)),
        locked: true,
      );
      final c = await empty(
        MemoryRepository(
          Workspace(
            revision: 1,
            entries: [meeting],
            preferences: const SeraPreferences(
              weekdays: [1, 3, 5],
              dailyBudget: 90,
              bufferMinutes: 15,
            ),
          ),
        ),
      );
      final plan = await c.generatePlan(
        title: '用户研究',
        deadline: today.add(const Duration(days: 14)),
        dailyBudget: 120,
      );
      final placed = [meeting, ...plan.items.map((e) => e.entry!)];
      for (final entry in placed.skip(1)) {
        expect([1, 3, 5].contains(entry.start.weekday), isTrue);
        expect(entry.start.hour >= 14, isTrue);
        expect(entry.end.hour <= 17, isTrue);
        for (final other in placed.where((e) => e.id != entry.id)) {
          final overlap =
              entry.start.isBefore(
                other.end.add(const Duration(minutes: 15)),
              ) &&
              entry.end.add(const Duration(minutes: 15)).isAfter(other.start);
          expect(overlap, isFalse);
        }
        final allocated = placed
            .where(
              (e) => e.isTask && dateOnly(e.start) == dateOnly(entry.start),
            )
            .fold<int>(0, (sum, e) => sum + e.minutes);
        expect(allocated <= 90, isTrue);
      }
    },
  );

  test(
    'limited capacity preserves a complete draft without creating formal tasks',
    () async {
      final c = await empty();
      final plan = await c.generatePlan(
        title: '今天完成',
        deadline: today.add(const Duration(hours: 17)),
        dailyBudget: 90,
      );
      expect(c.data.tasks, isEmpty);
      expect(c.data.entries, isEmpty);
      expect(plan.items, hasLength(6));
      expect(plan.totalMinutes, 270);
      expect(plan.needsCapacityConfirmation, isTrue);
      expect(c.data.drafts.single.id, plan.id);
      await expectLater(
        c.commitDraft(plan.id),
        throwsA(isA<RepositoryException>()),
      );
      expect(c.data.tasks, isEmpty);
    },
  );

  test(
    'commit rechecks an intervening meeting instead of applying stale slots',
    () async {
      final c = await empty();
      final plan = await c.generatePlan(
        title: '评审准备',
        deadline: today.add(const Duration(days: 10)),
        dailyBudget: 90,
      );
      final slot = plan.items.first.entry!;
      await c.saveEntry(
        CalendarEntry(
          id: 'new-meeting',
          title: '新增会议',
          start: slot.start,
          end: slot.end,
          locked: true,
        ),
      );
      await expectLater(
        c.commitDraft(plan.id),
        throwsA(isA<RepositoryException>()),
      );
      expect(c.data.tasks, isEmpty);
      expect(c.draft(plan.id)!.status, 'draft');
      expect(c.data.entries.single.id, 'new-meeting');
    },
  );

  test('draft edits and removals affect only eventual commit', () async {
    final c = await empty();
    final plan = await c.generatePlan(
      title: '评审准备',
      deadline: today.add(const Duration(days: 10)),
      dailyBudget: 90,
    );
    final first = plan.items.first;
    await c.updateDraftItem(
      plan.id,
      PlannedTask(
        task: first.task.copyWith(title: '自定义第一步'),
        entry: first.entry,
      ),
    );
    await c.deleteDraftItem(plan.id, plan.items.last.task.id);
    await c.commitDraft(plan.id);
    expect(c.data.tasks, hasLength(5));
    expect(c.task(first.task.id)!.title, '自定义第一步');
    expect(c.data.goals.single.taskIds, hasLength(5));
  });

  test(
    'delete removes linked schedule and focus; undo restores complete relation',
    () async {
      final c = SeraController(repository: MemoryRepository(), today: today);
      await c.initialize();
      await c.recordFocus('task-1', 32);
      final before = c.data;
      await c.deleteTask('task-1');
      expect(c.task('task-1'), isNull);
      expect(c.entryForTask('task-1'), isNull);
      expect(c.data.focusRecords, isEmpty);
      expect(await c.undoLast(), isTrue);
      expect(c.task('task-1')!.actualSeconds, 32);
      expect(c.entryForTask('task-1')!.toJson(), before.entries.first.toJson());
      expect(c.goal('goal-review')!.taskIds, contains('task-1'));
    },
  );

  test('stale entity revision cannot overwrite a newer task edit', () async {
    final c = await empty();
    await c.saveTask(const SeraTask(id: 't', title: '原任务'));
    final stale = c.task('t')!;
    await c.setDone('t', true);
    await expectLater(
      c.saveTask(stale.copyWith(title: '过期名称')),
      throwsA(
        isA<RepositoryException>().having((e) => e.conflict, 'conflict', true),
      ),
    );
    expect(c.task('t')!.title, '原任务');
    expect(c.task('t')!.done, isTrue);
  });

  test(
    'failed persistence keeps in-memory state unchanged and exposes failure',
    () async {
      final repository = MemoryRepository(const Workspace(revision: 1));
      final c = await empty(repository);
      repository.rejectNext = true;
      await expectLater(
        c.saveTask(const SeraTask(id: 't', title: '不能丢失')),
        throwsA(isA<RepositoryException>()),
      );
      expect(c.data.tasks, isEmpty);
      expect(c.data.history, isEmpty);
      expect(c.data.revision, 1);
      expect(c.error, 'disk full');
      expect(c.busy, isFalse);
      await c.saveTask(const SeraTask(id: 't', title: '再次保存'));
      expect(c.task('t')!.title, '再次保存');
      expect(c.error, isNull);
    },
  );

  test('concurrent UI actions serialize without losing edits', () async {
    final c = await empty();
    await Future.wait([
      c.saveTask(const SeraTask(id: 'a', title: 'A')),
      c.saveTask(const SeraTask(id: 'b', title: 'B')),
    ]);
    expect(c.data.tasks.map((e) => e.id).toSet(), {'a', 'b'});
    expect(c.data.revision, 3);
  });

  test('undo refuses content changed outside the recorded operation', () async {
    final repository = MemoryRepository(const Workspace(revision: 1));
    final c = await empty(repository);
    await c.saveTask(const SeraTask(id: 't', title: '保存的任务'));
    repository.value = repository.value!.copyWith(
      revision: 3,
      tasks: [const SeraTask(id: 't', title: '其他客户端修改')],
    );
    await c.refresh();
    await expectLater(
      c.undoLast(),
      throwsA(
        isA<RepositoryException>().having((e) => e.conflict, 'conflict', true),
      ),
    );
    expect(c.task('t')!.title, '其他客户端修改');
  });

  test('checklist, reminder and focus values persist without fabricated elapsed time', () async {
    final c = await empty();
    await c.saveTask(
      const SeraTask(id: 't', title: '任务', checklist: ['阅读', '整理']),
    );
    await c.setCheck('t', '阅读', true);
    await c.setReminder('t', 30);
    await c.recordFocus('t', 7);
    expect(c.task('t')!.completedChecks, ['阅读']);
    expect(c.task('t')!.reminderMinutes, 30);
    expect(c.task('t')!.actualSeconds, 7);
    expect(c.data.focusRecords.single.seconds, 7);
    await expectLater(
      c.recordFocus('t', 0),
      throwsA(isA<RepositoryException>()),
    );
  });

  test(
    'available slot can honor explicit extension then save atomically',
    () async {
      final c = await empty();
      final original = SeraTask(
        id: 't',
        title: '明天继续',
        dueAt: today.add(const Duration(hours: 18)),
      );
      await c.saveTask(original);
      final tomorrow = today.add(const Duration(days: 1));
      expect(c.findAvailableSlot('t', from: tomorrow), isNull);
      final extended = tomorrow.add(const Duration(days: 2, hours: 18));
      final slot = c.findAvailableSlot(
        't',
        from: tomorrow,
        deadlineOverride: extended,
      )!;
      await c.saveTask(c.task('t')!.copyWith(dueAt: extended), entry: slot);
      expect(c.entryForTask('t')!.start, slot.start);
      expect(c.task('t')!.dueAt, extended);
    },
  );

  test('invalid preferences and overlapping meetings are rejected', () async {
    final c = await empty();
    await expectLater(
      c.savePreferences(const SeraPreferences(weekdays: [])),
      throwsA(isA<RepositoryException>()),
    );
    final start = today.add(const Duration(hours: 10));
    await c.saveEntry(
      CalendarEntry(
        id: 'a',
        title: 'A',
        start: start,
        end: start.add(const Duration(hours: 1)),
      ),
    );
    await expectLater(
      c.saveEntry(
        CalendarEntry(
          id: 'b',
          title: 'B',
          start: start,
          end: start.add(const Duration(minutes: 30)),
        ),
      ),
      throwsA(isA<RepositoryException>()),
    );
    expect(c.data.entries, hasLength(1));
    expect(
      () => PlanningService.validatePreferences(
        const SeraPreferences(startMinute: 900, endMinute: 800),
      ),
      throwsA(isA<RepositoryException>()),
    );
  });

  test('auto-scheduling creates task and entry in one transaction and rolls back on no capacity', () async {
    final c = await empty();
    await c.saveTask(
      SeraTask(
        id: 'auto',
        title: '一次提交',
        dueAt: today.add(const Duration(days: 1)),
      ),
      autoSchedule: true,
    );
    expect(c.data.revision, 2);
    expect(c.entryForTask('auto'), isNotNull);
    final revision = c.data.revision;
    await expectLater(
      c.saveTask(
        SeraTask(
          id: 'too-long',
          title: '无法安排',
          estimatedMinutes: 120,
          dueAt: today.add(const Duration(hours: 17)),
        ),
        autoSchedule: true,
      ),
      throwsA(isA<RepositoryException>()),
    );
    expect(c.task('too-long'), isNull);
    expect(c.data.revision, revision);
  });

  test('editing task duration also updates linked time block and rechecks conflicts', () async {
    final c = await empty();
    await c.saveTask(const SeraTask(id: 't', title: '原名称'), autoSchedule: true);
    await c.saveTask(c.task('t')!.copyWith(title: '新名称', estimatedMinutes: 45));
    expect(c.entryForTask('t')!.title, '新名称');
    expect(c.entryForTask('t')!.minutes, 45);
    final schedule = c.entryForTask('t')!;
    await c.saveEntry(
      CalendarEntry(
        id: 'm',
        title: '后续会议',
        start: schedule.end,
        end: schedule.end.add(const Duration(hours: 1)),
      ),
    );
    await expectLater(
      c.saveTask(c.task('t')!.copyWith(estimatedMinutes: 60)),
      throwsA(isA<RepositoryException>()),
    );
    expect(c.task('t')!.estimatedMinutes, 45);
    expect(c.entryForTask('t')!.minutes, 45);
  });

  test('API capability uses actual AI semantic outline before constrained planning', () async {
    final repository = AiMemoryRepository();
    final c = await empty(repository);
    final plan = await c.generatePlan(
      title: '数据库课程答辩',
      deadline: today.add(const Duration(days: 4)),
      dailyBudget: 90,
    );
    expect(c.usesRemoteAi, isTrue);
    expect(repository.requests, ['数据库课程答辩']);
    expect(plan.source, 'siliconflow');
    expect(plan.model, 'unit-model');
    expect(plan.items, hasLength(3));
    expect(plan.items.first.task.title, '收集数据库实验结果');
    expect(plan.items.first.task.checklist, ['导出执行计划']);
    expect(plan.totalMinutes, 90);
    expect(c.data.tasks, isEmpty);
    await c.commitDraft(plan.id);
    expect(c.data.tasks, hasLength(3));
    expect(c.data.entries, hasLength(3));
  });

  test('AI failure does not silently produce a template or persist a partial draft', () async {
    final repository = AiMemoryRepository()..fail = true;
    final c = await empty(repository);
    await expectLater(
      c.generatePlan(
        title: '数据库课程答辩',
        deadline: today.add(const Duration(days: 4)),
        dailyBudget: 90,
      ),
      throwsA(isA<RepositoryException>()),
    );
    expect(c.data.drafts, isEmpty);
    expect(c.data.tasks, isEmpty);
    expect(c.data.revision, 1);
    expect(c.error, contains('AI'));
    expect(c.busy, isFalse);
  });

  test(
    'new planning never inserts a time block before the current planning clock',
    () async {
      final clock = DateTime(2026, 11, 2, 16, 30);
      final c = SeraController(
        repository: MemoryRepository(const Workspace(revision: 1)),
        today: clock,
      );
      await c.initialize();
      final draft = await c.generatePlan(
        title: '晚间新增目标',
        deadline: clock.add(const Duration(days: 7)),
        dailyBudget: 90,
      );
      expect(draft.items.every((e) => !e.entry!.start.isBefore(clock)), isTrue);
      expect(dateOnly(draft.items.first.entry!.start), DateTime(2026, 11, 3));
    },
  );

  test(
    'replan clamps an old from time to now and preserves locked state',
    () async {
      final clock = DateTime(2026, 11, 2, 16);
      final start = DateTime(2026, 11, 2, 13);
      final task = SeraTask(
        id: 'locked',
        title: '锁定任务',
        estimatedMinutes: 30,
        dueAt: DateTime(2026, 11, 3, 18),
      );
      final repository = MemoryRepository(
        Workspace(
          revision: 1,
          tasks: [task],
          entries: [
            CalendarEntry(
              id: 'locked-entry',
              taskId: task.id,
              title: task.title,
              start: start,
              end: start.add(const Duration(minutes: 30)),
              locked: true,
            ),
          ],
        ),
      );
      final c = SeraController(repository: repository, today: clock);
      await c.initialize();
      final slot = c.findAvailableSlot(
        task.id,
        from: DateTime(2026, 11, 2, 14, 15),
      )!;
      expect(!slot.start.isBefore(clock), isTrue);
      expect(!c.suggestReplan(task.id)!.isBefore(clock), isTrue);
      await c.applyReplan(task.id, slot.start);
      expect(c.entryForTask(task.id)!.start, slot.start);
      expect(c.entryForTask(task.id)!.locked, isTrue);
    },
  );

  test(
    'locally invalid planning input is rejected before a billable AI request',
    () async {
      final repository = AiMemoryRepository();
      final c = await empty(repository);
      for (final request in <(String, DateTime, int)>[
        ('', today.add(const Duration(days: 7)), 90),
        ('过去截止', today.subtract(const Duration(days: 1)), 90),
        ('超长范围', today.add(const Duration(days: 367)), 90),
        ('无效预算', today.add(const Duration(days: 7)), 0),
      ]) {
        await expectLater(
          c.generatePlan(
            title: request.$1,
            deadline: request.$2,
            dailyBudget: request.$3,
          ),
          throwsA(isA<RepositoryException>()),
        );
      }
      expect(repository.requests, isEmpty);
      expect(c.data.drafts, isEmpty);
      expect(c.data.revision, 1);
    },
  );
}
