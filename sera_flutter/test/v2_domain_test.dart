import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/repositories.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/domain/planning_service.dart';

class Store implements WorkspaceRepository {
  Workspace value = const Workspace(revision: 1);
  @override
  String get mode => 'test';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async => value = const Workspace();
  @override
  Future<Workspace> save(Workspace w, {required int expectedRevision}) async {
    if (expectedRevision != value.revision) {
      throw const RepositoryException('stale', conflict: true);
    }
    return value = w.copyWith(revision: expectedRevision + 1);
  }
}

void main() {
  final monday = DateTime(2026, 11, 2, 9);
  Future<SeraController> setup() async {
    final c = SeraController(
      repository: Store(),
      today: monday,
      seedDemo: false,
    );
    await c.initialize();
    return c;
  }

  test('v1 migration and status compatibility retain existing data', () {
    final w = Workspace.fromJson({
      'schemaVersion': 1,
      'tasks': [
        {'id': 't', 'title': '旧任务', 'done': true},
      ],
      'goals': [],
    });
    expect(w.tasks.single.status, 'done');
    expect(w.toJson()['schemaVersion'], 2);
    expect(w.tasks.single.copyWith(done: false).status, 'todo');
    expect(Workspace.fromJson(w.toJson()).tasks.single.done, isTrue);
  });
  test(
    'dependencies reject cycles and starting before predecessor completes',
    () async {
      final c = await setup();
      await c.saveTask(const SeraTask(id: 'a', title: '前置'));
      await c.saveTask(
        const SeraTask(id: 'b', title: '后置', dependencyIds: ['a']),
      );
      await expectLater(
        c.saveTask(c.task('a')!.copyWith(dependencyIds: ['b'])),
        throwsA(isA<RepositoryException>()),
      );
      await expectLater(c.startFocus('b'), throwsA(isA<RepositoryException>()));
      await c.setDone('a', true);
      await c.startFocus('b');
      expect(c.data.focusSession!.taskId, 'b');
    },
  );
  test('external overlapping cross-day busy is kept separately and constrains planning', () async {
    final c = await setup();
    final start = DateTime(2026, 11, 1, 20), end = DateTime(2026, 11, 2, 16);
    await c.setExternalBusyEntries([
      CalendarEntry(id: 'x', title: '跨日', start: start, end: end),
      CalendarEntry(id: 'y', title: '同时', start: start, end: end),
    ], source: 'device-calendar');
    expect(c.data.entries, isEmpty);
    expect(c.data.externalBusyEntries, hasLength(2));
    final draft = await c.generatePlan(
      title: '新目标',
      deadline: DateTime(2026, 11, 10, 18),
      dailyBudget: 90,
    );
    expect(draft.items.first.entry!.start.isBefore(end), isFalse);
  });
  test('same task accepts multiple blocks and completion cancels only future blocks', () async {
    final c = await setup();
    await c.saveTask(
      const SeraTask(
        id: 't',
        title: '可拆任务',
        splittable: true,
        estimatedMinutes: 60,
      ),
    );
    for (var i = 0; i < 2; i++) {
      final start = monday.add(Duration(hours: 5 + i));
      await c.saveEntry(
        CalendarEntry(
          id: 'b$i',
          title: '任务',
          taskId: 't',
          start: start,
          end: start.add(const Duration(minutes: 30)),
        ),
      );
    }
    expect(c.entriesForTask('t'), hasLength(2));
    expect(c.schedulingState('t'), 'planned');
    await c.setDone('t', true);
    expect(c.entriesForTask('t'), isEmpty);
    expect(c.data.focusRecords, isEmpty);
  });
  test(
    'splitting uses available fragments without allocating partial failure',
    () {
      final p = const SeraPreferences(
        dailyBudget: 60,
        startMinute: 840,
        endMinute: 1020,
        bufferMinutes: 0,
      );
      final busy = CalendarEntry(
        id: 'm',
        title: '会议',
        start: DateTime(2026, 11, 2, 14, 30),
        end: DateTime(2026, 11, 2, 16, 30),
      );
      final w = Workspace(preferences: p, externalBusyEntries: [busy]);
      var id = 0;
      final blocks = const PlanningService().findSlots(
        workspace: w,
        today: monday,
        deadline: DateTime(2026, 11, 2, 17),
        task: const SeraTask(
          id: 't',
          title: '任务',
          estimatedMinutes: 60,
          splittable: true,
          minBlockMinutes: 30,
        ),
        dailyBudget: 60,
        occupied: [busy],
        newId: (p) => '$p-${id++}',
      );
      expect(blocks.map((e) => e.minutes), [30, 30]);
    },
  );
  test(
    'focus survives repository reload and ends once without completing task',
    () async {
      final c = await setup();
      await c.saveTask(const SeraTask(id: 't', title: '执行'));
      final store = c.repository as Store;
      final started = DateTime.now().subtract(const Duration(seconds: 11));
      store.value = store.value.copyWith(
        focusSession: FocusSession(
          id: 'running',
          taskId: 't',
          startedAt: started,
          lastResumedAt: started,
        ),
      );
      await c.refresh();
      await c.pauseFocus();
      expect(c.data.focusSession!.accumulatedSeconds, greaterThanOrEqualTo(11));
      final reloaded = SeraController(repository: store, seedDemo: false);
      await reloaded.initialize();
      final seconds = await reloaded.finishFocus();
      expect(seconds, greaterThanOrEqualTo(11));
      expect(await reloaded.finishFocus(), 0);
      expect(reloaded.task('t')!.done, isFalse);
      expect(reloaded.data.focusRecords, hasLength(1));
    },
  );
  test(
    'planning input persistence does not consume business undo history',
    () async {
      final c = await setup();
      await c.saveTask(const SeraTask(id: 't', title: '任务'));
      final before = c.data.history.length;
      await c.savePlanningSession(
        PlanningSession(id: 'input', updatedAt: DateTime.now(), prompt: '尚未提交'),
      );
      expect(c.data.history, hasLength(before));
      expect(await c.undoLast(), isTrue);
      expect(c.data.planningSessions.single.prompt, '尚未提交');
      expect(c.data.tasks, isEmpty);
    },
  );
  test(
    'editing existing goal commits updates rather than duplicate tasks',
    () async {
      final c = await setup();
      final plan = await c.generatePlan(
        title: '目标',
        deadline: DateTime(2026, 11, 15, 18),
        dailyBudget: 90,
      );
      // The API accepts at most 256 characters for its optimistic calendar key.
      expect(plan.calendarFingerprint.length, lessThanOrEqualTo(256));
      await c.commitDraft(plan.id);
      final ids = c.data.tasks.map((e) => e.id).toSet();
      final edit = await c.editGoalPlan(c.data.goals.single.id);
      await c.updateDraftItem(
        edit.id,
        PlannedTask(
          task: edit.items.first.task.copyWith(title: '修订标题'),
          entry: edit.items.first.entry,
        ),
      );
      await c.commitDraft(edit.id);
      expect(c.data.goals, hasLength(1));
      expect(c.data.tasks.map((e) => e.id).toSet(), ids);
      expect(c.task(edit.items.first.task.id)!.title, '修订标题');
    },
  );
  test('date-only deadline retains its original timezone while workspace displays another', () {
    final w = Workspace.fromJson({
      'preferences': {'timeZone': 'America/New_York'},
      'tasks': [
        {
          'id': 'date',
          'title': '日期',
          'dueDate': '2026-11-02',
          'timeZone': 'Asia/Hong_Kong',
        },
      ],
      'entries': [
        {
          'id': 'block',
          'title': '时刻',
          'start': '2026-11-02T14:00:00.000Z',
          'end': '2026-11-02T15:00:00.000Z',
        },
      ],
    });
    expect(w.entries.single.start.hour, 9);
    expect(w.tasks.single.deadline!.toUtc(), DateTime.utc(2026, 11, 2, 15, 59));
    expect(Workspace.fromJson(w.toJson()).tasks.single.dueDate, '2026-11-02');
  });
  test('calendar day and workspace restoration handle DST and plan blocks consistently', () {
    final day = inTimeZone(
      DateTime(2026, 11, 1),
      'America/New_York',
      wallClock: true,
    );
    expect(calendarDay(day, 1).difference(day).inHours, 25);
    final w = Workspace.fromJson({
      'preferences': {'timeZone': 'America/New_York'},
      'planningSessions': [
        {'id': 'input', 'deadline': '2026-11-02T14:00:00Z'},
      ],
      'reviews': [
        {'id': 'review', 'day': '2026-11-02'},
      ],
      'drafts': [
        {
          'id': 'draft',
          'goal': {
            'id': 'goal',
            'title': '目标',
            'deadline': '2026-11-02T14:00:00Z',
          },
          'items': [
            {
              'task': {'id': 'task', 'title': '任务'},
              'entry': {
                'id': 'block',
                'title': '时间',
                'start': '2026-11-02T14:00:00Z',
                'end': '2026-11-02T15:00:00Z',
              },
            },
          ],
        },
      ],
    });
    expect(w.drafts.single.items.single.entry!.start.hour, 9);
    expect(w.planningSessions.single.deadline!.hour, 9);
    expect(w.reviews.single.day.hour, 0);
    expect(w.reviews.single.day.timeZoneOffset.inHours, -5);
  });
  test(
    'cross-day fixed events accepted but task blocks cannot span over 24 hours',
    () {
      final e = CalendarEntry(
        id: 'cross',
        title: '跨日',
        start: monday,
        end: monday.add(const Duration(days: 2)),
        locked: true,
      );
      PlanningService.validatePlacement(e, const Workspace());
      expect(
        () => PlanningService.validatePlacement(
          CalendarEntry(
            id: e.id,
            title: e.title,
            start: e.start,
            end: e.end,
            taskId: 't',
          ),
          const Workspace(),
        ),
        throwsA(isA<RepositoryException>()),
      );
    },
  );
  test(
    'acknowledgement binds to the specific block reminder time and followup',
    () async {
      final c = await setup();
      await c.saveTask(
        const SeraTask(id: 't', title: '提醒任务', reminderMinutes: 10),
      );
      final block = CalendarEntry(
        id: 'b',
        title: '安排',
        taskId: 't',
        start: monday.add(const Duration(hours: 5)),
        end: monday.add(const Duration(hours: 5, minutes: 30)),
      );
      await c.saveEntry(block);
      await c.saveReminderState('b:start', 'ack');
      expect(
        c.data.reminderStates['b:start']['scheduledAt'],
        block.start
            .subtract(const Duration(minutes: 10))
            .toUtc()
            .toIso8601String(),
      );
      await c.saveReminderState('b:followup', 'snoozed');
      expect(
        c.data.reminderStates['b:followup']['scheduledAt'],
        block.end.add(const Duration(minutes: 5)).toUtc().toIso8601String(),
      );
      expect(c.data.reminderStates['b:followup']['snoozeUntil'], isNotNull);
    },
  );
  test('all-day dates stay on the same calendar date after timezone changes and DST', () {
    final entry = CalendarEntry(
      id: 'day',
      title: '全天',
      allDay: true,
      timeZone: 'Asia/Hong_Kong',
      start: inTimeZone(
        DateTime(2026, 11, 1),
        'Asia/Hong_Kong',
        wallClock: true,
      ),
      end: inTimeZone(DateTime(2026, 11, 2), 'Asia/Hong_Kong', wallClock: true),
    );
    final json = entry.toJson();
    final displayed = CalendarEntry.fromJson(
      json,
      displayZone: 'America/New_York',
    );
    expect(calendarDateString(displayed.start), '2026-11-01');
    expect(calendarDateString(displayed.end), '2026-11-02');
    expect(displayed.minutes, 25 * 60);
    expect(displayed.toJson()['start'], json['start']);
    expect(displayed.toJson()['startDate'], '2026-11-01');
    final legacy = Map<String, dynamic>.from(json)
      ..remove('startDate')
      ..remove('endDate');
    expect(
      calendarDateString(
        CalendarEntry.fromJson(legacy, displayZone: 'America/New_York').start,
      ),
      '2026-11-01',
    );
  });
  test('focus and history preserve UTC instants while displaying in the user timezone', () {
    final instant = DateTime.utc(2026, 11, 2, 2);
    final w = Workspace.fromJson(
      Workspace(
        preferences: const SeraPreferences(timeZone: 'America/New_York'),
        focusRecords: [
          FocusRecord(
            id: 'focus',
            taskId: 't',
            startedAt: instant,
            seconds: 12,
          ),
        ],
        history: [ChangeRecord(id: 'change', label: '修改', at: instant)],
      ).toJson(),
    );
    expect(w.focusRecords.single.startedAt.day, 1);
    expect(w.focusRecords.single.startedAt.hour, 21);
    expect(w.history.single.at.hour, 21);
    expect(
      w.toJson()['focusRecords'][0]['startedAt'],
      '2026-11-02T02:00:00.000Z',
    );
    expect(w.toJson()['history'][0]['at'], '2026-11-02T02:00:00.000Z');
  });
}
