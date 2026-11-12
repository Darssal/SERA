import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/domain/planning_service.dart';

final _today = readZoned('2026-11-02T09:00:00+08:00', 'Asia/Hong_Kong')!;
const _preferences = SeraPreferences(
  weekdays: [1, 2, 3, 4, 5],
  dailyBudget: 90,
  bufferMinutes: 15,
  startMinute: 9 * 60,
  endMinute: 17 * 60,
  restStart: 12 * 60,
  restEnd: 13 * 60,
);
const _workspace = Workspace(revision: 1, preferences: _preferences);
const _planner = PlanningService();

DateTime _at(int day, int minute) => atMinute(calendarDay(_today, day), minute);

String Function(String) _ids() {
  var sequence = 0;
  return (prefix) => '$prefix-${++sequence}';
}

PlanDraft _generate(
  List<TaskOutline> outlines, {
  Workspace workspace = _workspace,
  DateTime? deadline,
  int dailyBudget = 90,
}) => _planner.generate(
  workspace: workspace,
  today: _today,
  title: '长期项目',
  deadline: deadline ?? _at(42, 17 * 60),
  dailyBudget: dailyBudget,
  newId: _ids(),
  outlines: outlines,
  source: 'siliconflow',
  model: 'model-provided-phase-fixture',
);

RepositoryException _failure(
  List<TaskOutline> outlines, {
  Workspace workspace = _workspace,
  DateTime? deadline,
  int dailyBudget = 90,
}) {
  try {
    _generate(
      outlines,
      workspace: workspace,
      deadline: deadline,
      dailyBudget: dailyBudget,
    );
  } on RepositoryException catch (error) {
    return error;
  }
  throw StateError('Expected a complete placement failure.');
}

void main() {
  test(
    '24 executable tasks retain six model-provided weekly phase windows',
    () {
      final outlines = [
        for (var phase = 0; phase < 6; phase++)
          for (var item = 0; item < 4; item++)
            TaskOutline(
              title: '阶段 ${phase + 1} 的具体任务 ${item + 1}',
              notes: '完成本任务明确的交付项并检查结果。',
              checklist: ['核对交付项'],
              estimatedMinutes: 90,
              phase: '模型给定阶段 ${phase + 1}',
              notBefore: _at(phase * 7, 9 * 60),
              deadline: _at(phase * 7 + 4, 17 * 60),
            ),
      ];

      final draft = _generate(outlines);

      expect(draft.items, hasLength(24));
      expect(draft.totalMinutes, 2160);
      expect(draft.source, 'siliconflow');
      expect(draft.model, 'model-provided-phase-fixture');
      expect(draft.goal.taskIds.toSet(), hasLength(24));
      for (var i = 0; i < outlines.length; i++) {
        final outline = outlines[i];
        final item = draft.items[i];
        expect(item.task.phase, outline.phase);
        expect(item.task.notBefore, outline.notBefore);
        expect(item.task.dueAt, outline.deadline);
        expect(item.task.notes, outline.notes);
        expect(item.task.checklist, outline.checklist);
        expect(item.entry!.start.isBefore(outline.notBefore!), isFalse);
        expect(item.entry!.end.isAfter(outline.deadline!), isFalse);
        expect(item.entry!.minutes, 90);
        if (i > 0) {
          expect(
            item.entry!.start.isBefore(draft.items[i - 1].entry!.end),
            isFalse,
          );
        }
      }
      expect(draft.items.last.entry!.start.isBefore(_at(35, 9 * 60)), isFalse);
      expect(_workspace.tasks, isEmpty);
      expect(_workspace.entries, isEmpty);
      expect(_workspace.drafts, isEmpty);
    },
  );

  test('legacy four-field outlines keep their order and goal deadline', () {
    final deadline = _at(2, 17 * 60);
    final draft = _generate(const [
      TaskOutline(
        title: '整理已给资料',
        notes: '完成分类',
        estimatedMinutes: 30,
        checklist: ['检查来源'],
      ),
      TaskOutline(title: '核对结果', estimatedMinutes: 30),
    ], deadline: deadline);

    expect(draft.items.map((item) => item.task.title), ['整理已给资料', '核对结果']);
    expect(draft.items.first.entry!.start, _today);
    expect(draft.items.last.entry!.start, _at(0, 9 * 60 + 45));
    for (final item in draft.items) {
      expect(item.task.phase, isEmpty);
      expect(item.task.notBefore, isNull);
      expect(item.task.dueAt, deadline);
    }
  });

  for (final bounds in [
    (start: null, end: null),
    (start: null, end: _at(4, 17 * 60)),
    (start: _at(0, 9 * 60), end: null),
    (start: _at(0, 9 * 60), end: _at(0, 9 * 60)),
    (start: _at(4, 9 * 60), end: _at(3, 17 * 60)),
    (start: _at(43, 9 * 60), end: _at(44, 17 * 60)),
  ]) {
    test('unknown or invalid phase window is rejected: $bounds', () {
      expect(
        () => _generate([
          TaskOutline(
            title: '不能擅自填补阶段日期',
            phase: '阶段一',
            notBefore: bounds.start,
            deadline: bounds.end,
            estimatedMinutes: 30,
          ),
        ]),
        throwsA(isA<RepositoryException>()),
      );
    });
  }

  test(
    'task deadlines are capped by the goal and narrower windows are honored',
    () {
      final goalDeadline = _at(10, 17 * 60);
      final firstDeadline = _at(1, 17 * 60);
      final draft = _generate([
        TaskOutline(
          title: '较早交付',
          phase: '第一阶段',
          notBefore: _today,
          deadline: firstDeadline,
          estimatedMinutes: 30,
        ),
        TaskOutline(
          title: '最终交付',
          phase: '第二阶段',
          notBefore: _at(7, 9 * 60),
          deadline: _at(20, 17 * 60),
          estimatedMinutes: 30,
        ),
      ], deadline: goalDeadline);

      expect(draft.items.first.task.dueAt, firstDeadline);
      expect(draft.items.last.task.dueAt, goalDeadline);
      expect(draft.items.last.entry!.start, _at(7, 9 * 60));
      expect(draft.items.last.entry!.end.isAfter(goalDeadline), isFalse);
    },
  );

  test('capacity failure does not truncate tasks or mutate the workspace', () {
    final before = _workspace.toJson();
    expect(
      () => _generate(
        const [
          TaskOutline(title: '第一项可以排入', estimatedMinutes: 30),
          TaskOutline(title: '第二项也必须完整排入', estimatedMinutes: 30),
        ],
        dailyBudget: 30,
        deadline: _at(0, 17 * 60),
      ),
      throwsA(
        isA<RepositoryException>().having(
          (error) => error.message,
          'message',
          contains('没有足够'),
        ),
      ),
    );
    expect(_workspace.toJson(), before);
  });

  test('96 task bound is accepted and 97 tasks are rejected', () {
    final outlines = [
      for (var i = 0; i < 97; i++)
        TaskOutline(title: '明确执行项 $i', estimatedMinutes: 5),
    ];
    expect(_generate(outlines.take(96).toList()).items, hasLength(96));
    expect(() => _generate(outlines), throwsA(isA<RepositoryException>()));
  });

  test('generated tasks use earlier fragments instead of waiting for a whole future slot', () {
    final busy = CalendarEntry(
      id: 'busy',
      title: '固定事项',
      start: _at(0, 14 * 60 + 30),
      end: _at(0, 17 * 60),
      locked: true,
    );
    final workspace = _workspace.copyWith(
      preferences: _preferences.copyWith(
        startMinute: 14 * 60,
        bufferMinutes: 0,
        dailyBudget: 60,
      ),
      externalBusyEntries: [busy],
    );
    final draft = _generate(
      const [TaskOutline(title: '完整保留60分钟工作', estimatedMinutes: 60)],
      workspace: workspace,
      dailyBudget: 60,
      deadline: _at(1, 17 * 60),
    );
    final item = draft.items.single;
    expect(item.task.splittable, isTrue);
    expect(item.task.minBlockMinutes, 15);
    expect(item.blocks.map((block) => block.minutes), [30, 30]);
    expect(item.blocks.first.start, _at(0, 14 * 60));
    expect(item.blocks.last.start, _at(1, 14 * 60));
    expect(item.blocks.fold<int>(0, (sum, block) => sum + block.minutes), 60);
  });

  test('split scheduling fills an early gap before a later whole block on the same day', () {
    final busy = CalendarEntry(
      id: 'busy',
      title: '固定事项',
      start: _at(0, 14 * 60 + 30),
      end: _at(0, 15 * 60 + 30),
      locked: true,
    );
    final workspace = _workspace.copyWith(
      preferences: _preferences.copyWith(
        startMinute: 14 * 60,
        bufferMinutes: 0,
      ),
    );
    final blocks = _planner.findSlots(
      workspace: workspace,
      today: _today,
      deadline: _at(0, 17 * 60),
      task: const SeraTask(
        id: 'split',
        title: '可分任务',
        estimatedMinutes: 60,
        splittable: true,
        minBlockMinutes: 30,
      ),
      dailyBudget: 90,
      occupied: [busy],
      newId: _ids(),
    );
    expect(blocks.map((block) => block.minutes), [30, 30]);
    expect(blocks.first.start, _at(0, 14 * 60));
    expect(blocks.last.end, _at(0, 16 * 60));
  });

  test('explicitly unsplittable existing tasks retain a whole block', () {
    final blocks = _planner.findSlots(
      workspace: _workspace,
      today: _today,
      deadline: _at(1, 17 * 60),
      task: const SeraTask(
        id: 'atomic-task',
        title: '不可分任务',
        estimatedMinutes: 60,
      ),
      dailyBudget: 90,
      occupied: [
        CalendarEntry(
          id: 'busy',
          title: '固定事项',
          start: _at(0, 9 * 60 + 30),
          end: _at(0, 17 * 60),
        ),
      ],
      newId: _ids(),
    );
    expect(blocks, hasLength(1));
    expect(blocks.single.start, _at(1, 9 * 60));
    expect(blocks.single.minutes, 60);
  });

  test('390-minute anonymous course fixture fits 405 remaining minutes without raising the global cap', () {
    final workspace = _fragmentedCourseWorkspace();
    final draft = _generate(
      [
        for (final (index, minutes) in [30, 60, 60, 60, 60, 60, 60].indexed)
          TaskOutline(title: '匿名执行项 $index', estimatedMinutes: minutes),
      ],
      workspace: workspace,
      dailyBudget: 180,
      deadline: _at(8, 23 * 60 + 59),
    );

    expect(draft.items, hasLength(7));
    expect(draft.totalMinutes, 390);
    expect(draft.items.expand((item) => item.blocks), hasLength(10));
    final occupied = [...workspace.entries];
    DateTime? previousEnd;
    for (final item in draft.items) {
      expect(
        item.blocks.fold<int>(0, (sum, block) => sum + block.minutes),
        item.task.estimatedMinutes,
      );
      for (final block in item.blocks) {
        expect(block.minutes, greaterThanOrEqualTo(15));
        expect(block.end.isAfter(draft.goal.deadline), isFalse);
        if (previousEnd != null) {
          expect(block.start.isBefore(previousEnd), isFalse);
        }
        PlanningService.validatePlacement(
          block,
          workspace,
          occupied: occupied,
          applyPreferences: true,
        );
        occupied.add(block);
        previousEnd = block.end;
      }
    }
    expect(workspace.preferences.dailyBudget, 90);
    expect(workspace.tasks, isEmpty);
    expect(workspace.drafts, isEmpty);
  });

  test(
    '420 minutes still fail when the same real global budget leaves only 405',
    () {
      expect(
        () => _generate(
          [
            for (final (index, minutes) in [
              30,
              60,
              60,
              60,
              60,
              60,
              60,
              30,
            ].indexed)
              TaskOutline(title: '匿名执行项 $index', estimatedMinutes: minutes),
          ],
          workspace: _fragmentedCourseWorkspace(),
          dailyBudget: 180,
          deadline: _at(8, 23 * 60 + 59),
        ),
        throwsA(
          isA<RepositoryException>()
              .having(
                (error) => error.message,
                'message',
                contains('当前实际每日预算为 90 分钟'),
              )
              .having(
                (error) => error.details['planningFailureKind'],
                'kind',
                'total_capacity',
              )
              .having(
                (error) => error.details['estimatedCapacityMinutes'],
                'capacity',
                405,
              ),
        ),
      );
    },
  );

  test('21 tasks with one overloaded phase identify its 540/450 window while the whole period has capacity', () {
    final counts = [4, 6, 4, 4, 3];
    final error = _failure([
      for (var phase = 0; phase < counts.length; phase++)
        for (var task = 0; task < counts[phase]; task++)
          TaskOutline(
            title: '阶段执行项 $phase/$task',
            phase: '阶段${phase + 1}',
            estimatedMinutes: 90,
            notBefore: _at(phase * 7, 9 * 60),
            deadline: _at(phase * 7 + 4, 17 * 60),
          ),
    ], dailyBudget: 180);

    expect(error.message, contains('模型给出的「阶段2」'));
    expect(error.message, contains('2026-11-09—2026-11-13'));
    expect(error.message, contains('安排 540 分钟'));
    expect(error.message, contains('最多约 450 分钟'));
    expect(error.message, contains('需要调整该阶段计划'));
    expect(error.message, isNot(contains('全周期容量也不足')));
    expect(error.details['planningFailureKind'], 'phase_capacity');
    expect(error.details['totalRequiredMinutes'], 1890);
    expect(error.details['estimatedTotalCapacityMinutes'], greaterThan(1890));
    expect(error.details['estimatedCapacityMinutes'], 450);
    expect(error.details['capacityIsEstimate'], isTrue);
    expect(_workspace.drafts, isEmpty);
  });

  test('phase diagnostic accounts for rest and an existing busy block with buffers', () {
    final workspace = _workspace.copyWith(
      preferences: _preferences.copyWith(dailyBudget: 480),
      externalBusyEntries: [
        CalendarEntry(
          id: 'busy',
          title: '固定事项',
          start: _at(0, 9 * 60),
          end: _at(0, 10 * 60),
          locked: true,
        ),
      ],
    );
    final error = _failure(
      [
        for (var i = 0; i < 2; i++)
          TaskOutline(
            title: '执行项$i',
            phase: '当日阶段',
            estimatedMinutes: 180,
            notBefore: _today,
            deadline: _at(0, 17 * 60),
          ),
      ],
      workspace: workspace,
      dailyBudget: 480,
    );

    // 10:15–12:00 plus 13:00–17:00 is an upper estimate of 345 minutes.
    expect(error.details['requiredMinutes'], 360);
    expect(error.details['estimatedCapacityMinutes'], 345);
    expect(error.details['planningFailureKind'], 'phase_capacity');
  });

  test(
    'phase diagnostic deducts work already allocated against the daily cap',
    () {
      final error = _failure(
        [
          TaskOutline(
            title: '执行项',
            phase: '当日阶段',
            estimatedMinutes: 60,
            notBefore: _today,
            deadline: _at(0, 17 * 60),
          ),
        ],
        workspace: _workspace.copyWith(
          entries: [
            CalendarEntry(
              id: 'existing',
              taskId: 'existing-task',
              title: '已安排',
              start: _today,
              end: _at(0, 9 * 60 + 45),
            ),
          ],
        ),
        dailyBudget: 180,
      );

      expect(error.details['estimatedCapacityMinutes'], 45);
      expect(error.details['effectiveDailyBudget'], 90);
    },
  );

  test('phase capacity estimate is not treated as a successful minimum-block schedule', () {
    final workspace = _workspace.copyWith(
      preferences: _preferences.copyWith(endMinute: 10 * 60, bufferMinutes: 0),
      externalBusyEntries: [
        for (final minute in [9 * 60 + 10, 9 * 60 + 30, 9 * 60 + 50])
          CalendarEntry(
            id: 'busy-$minute',
            title: '固定事项',
            start: _at(0, minute),
            end: _at(0, minute + 10),
          ),
      ],
    );
    final error = _failure([
      TaskOutline(
        title: '完整30分钟',
        phase: '短窗口阶段',
        estimatedMinutes: 30,
        notBefore: _today,
        deadline: _at(0, 10 * 60),
      ),
    ], workspace: workspace);

    expect(error.details['requiredMinutes'], 30);
    expect(error.details['estimatedCapacityMinutes'], 30);
    expect(error.details['planningFailureKind'], 'phase_window_constraints');
    expect(error.message, contains('最短分段'));
    expect(workspace.drafts, isEmpty);
  });

  for (final budgets in [
    (goal: 90, preference: 30),
    (goal: 30, preference: 90),
  ]) {
    test('a task larger than a day is split within both budgets: $budgets', () {
      final draft = _generate(
        const [TaskOutline(title: '分两天执行', estimatedMinutes: 45)],
        workspace: _workspace.copyWith(
          preferences: _preferences.copyWith(dailyBudget: budgets.preference),
        ),
        dailyBudget: budgets.goal,
      );
      final blocks = draft.items.single.blocks;
      expect(blocks.map((block) => block.minutes), [30, 15]);
      expect(dateOnly(blocks.first.start), dateOnly(_today));
      expect(dateOnly(blocks.last.start), calendarDay(_today, 1));
      expect(blocks.fold<int>(0, (sum, block) => sum + block.minutes), 45);
    });
  }

  test('a 120-minute AI task under a 180-minute goal respects the global 90-minute cap across days', () {
    final draft = _generate(
      const [TaskOutline(title: '完整120分钟工作', estimatedMinutes: 120)],
      dailyBudget: 180,
      deadline: _at(1, 17 * 60),
    );
    final blocks = draft.items.single.blocks;
    expect(draft.items.single.task.estimatedMinutes, 120);
    expect(blocks.map((block) => block.minutes), [90, 30]);
    expect(blocks.first.start, _today);
    expect(blocks.last.start, _at(1, 9 * 60));
    expect(draft.totalMinutes, 120);
  });

  test(
    'phase scheduling retains busy, rest, buffer and daily budget constraints',
    () {
      final existing = CalendarEntry(
        id: 'existing-task-block',
        taskId: 'existing-task',
        title: '已安排任务',
        start: _at(0, 9 * 60),
        end: _at(0, 9 * 60 + 30),
      );
      final external = CalendarEntry(
        id: 'external-meeting',
        title: '外部固定事项',
        source: 'ics',
        locked: true,
        start: _at(0, 9 * 60 + 45),
        end: _at(0, 11 * 60 + 45),
      );
      final workspace = _workspace.copyWith(
        entries: [existing],
        externalBusyEntries: [external],
      );
      final draft = _generate([
        for (var i = 0; i < 3; i++)
          TaskOutline(
            title: '受约束执行项 $i',
            phase: '本周阶段',
            notBefore: _today,
            deadline: _at(4, 17 * 60),
            estimatedMinutes: 30,
          ),
      ], workspace: workspace);

      expect(draft.items.first.entry!.start, _at(0, 13 * 60));
      expect(draft.items[1].entry!.start, _at(0, 13 * 60 + 45));
      expect(draft.items.last.entry!.start, _at(1, 9 * 60));
      final occupied = [existing, external];
      for (final item in draft.items) {
        PlanningService.validatePlacement(
          item.entry!,
          workspace,
          occupied: occupied,
          applyPreferences: true,
          dailyBudget: 90,
        );
        occupied.add(item.entry!);
      }
    },
  );

  test(
    'findSlots keeps split rescheduling inside the persisted task window',
    () {
      final task = SeraTask(
        id: 'long-task',
        title: '分段执行项',
        phase: '后续阶段',
        notBefore: _at(1, 9 * 60),
        dueAt: _at(3, 10 * 60),
        estimatedMinutes: 90,
        splittable: true,
        minBlockMinutes: 15,
      );
      final blocks = _planner.findSlots(
        workspace: _workspace,
        today: _today,
        deadline: _at(20, 17 * 60),
        task: task,
        dailyBudget: 30,
        occupied: [],
        newId: _ids(),
      );

      expect(blocks, hasLength(3));
      expect(blocks.map((block) => block.minutes), everyElement(30));
      expect(blocks.first.start, task.notBefore);
      expect(blocks.last.end, _at(3, 9 * 60 + 30));
      for (final block in blocks) {
        expect(block.start.isBefore(task.notBefore!), isFalse);
        expect(block.end.isAfter(task.deadline!), isFalse);
      }
    },
  );

  test(
    'findSlots cannot use the broader goal deadline to escape a task window',
    () {
      final task = SeraTask(
        id: 'limited-task',
        title: '窗口容量不足',
        notBefore: _at(1, 9 * 60),
        dueAt: _at(1, 10 * 60),
        estimatedMinutes: 90,
        splittable: true,
        minBlockMinutes: 15,
      );
      expect(
        _planner.findSlots(
          workspace: _workspace,
          today: _today,
          deadline: _at(20, 17 * 60),
          task: task,
          dailyBudget: 90,
          occupied: [],
          newId: _ids(),
        ),
        isEmpty,
      );
    },
  );

  test('findSlots respects a later dependency as well as the release date', () {
    const dependency = SeraTask(id: 'dependency', title: '前置任务');
    final task = SeraTask(
      id: 'dependent-task',
      title: '后置执行项',
      notBefore: _at(1, 9 * 60),
      dueAt: _at(3, 17 * 60),
      estimatedMinutes: 30,
      dependencyIds: const ['dependency'],
    );
    final occupied = CalendarEntry(
      id: 'dependency-block',
      taskId: dependency.id,
      title: dependency.title,
      start: _at(2, 10 * 60),
      end: _at(2, 11 * 60),
    );
    final blocks = _planner.findSlots(
      workspace: _workspace.copyWith(tasks: [dependency, task]),
      today: _today,
      deadline: _at(20, 17 * 60),
      task: task,
      dailyBudget: 90,
      occupied: [occupied],
      newId: _ids(),
    );

    expect(blocks, hasLength(1));
    expect(blocks.single.start, _at(2, 11 * 60 + 15));
    expect(blocks.single.start.isBefore(task.notBefore!), isFalse);
  });
}

Workspace _fragmentedCourseWorkspace() => _workspace.copyWith(
  preferences: _preferences.copyWith(startMinute: 14 * 60),
  entries: [
    for (final (index, bounds) in [
      (day: 1, start: 15 * 60 + 15, end: 15 * 60 + 45),
      (day: 2, start: 14 * 60, end: 14 * 60 + 45),
      (day: 3, start: 14 * 60, end: 15 * 60),
      (day: 3, start: 15 * 60 + 15, end: 15 * 60 + 45),
      (day: 4, start: 14 * 60, end: 15 * 60),
    ].indexed)
      CalendarEntry(
        id: 'existing-$index',
        taskId: 'existing-task-$index',
        title: '匿名已安排事项',
        start: _at(bounds.day, bounds.start),
        end: _at(bounds.day, bounds.end),
      ),
  ],
);
