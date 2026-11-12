import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';

final _now = readZoned('2026-11-02T09:00:00+08:00', 'Asia/Hong_Kong')!;
DateTime _at(int day, int minute) => atMinute(calendarDay(_now, day), minute);
const _preferences = SeraPreferences(
  startMinute: 9 * 60,
  endMinute: 17 * 60,
  dailyBudget: 90,
  bufferMinutes: 15,
);

class _WindowStore implements WorkspaceRepository {
  _WindowStore(this.value);
  Workspace value;
  int saves = 0;
  @override
  String get mode => 'planning-window-test';
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
    saves++;
    return value = Workspace.fromJson(
      workspace.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }
}

SeraTask _task() => SeraTask(
  id: 'task',
  title: '阶段内的任务',
  phase: '后续阶段',
  notBefore: _at(7, 9 * 60),
  dueAt: _at(7, 17 * 60),
  estimatedMinutes: 30,
);

CalendarEntry _block(SeraTask task, int day, {int minute = 9 * 60}) =>
    CalendarEntry(
      id: 'block',
      taskId: task.id,
      title: task.title,
      start: _at(day, minute),
      end: _at(day, minute + task.estimatedMinutes),
    );

Future<(SeraController, _WindowStore)> _controller(Workspace workspace) async {
  final store = _WindowStore(workspace);
  final controller = SeraController(
    repository: store,
    today: _now,
    seedDemo: false,
  );
  await controller.initialize();
  addTearDown(controller.dispose);
  return (controller, store);
}

PlanDraft _draft({required int blockDay, bool split = false}) {
  final task = _task().copyWith(
    goalId: 'goal',
    estimatedMinutes: split ? 120 : 30,
    splittable: split,
    notBefore: split ? _now : _at(7, 9 * 60),
    dueAt: split ? _at(2, 17 * 60) : _at(7, 17 * 60),
  );
  return PlanDraft(
    id: 'draft',
    goal: SeraGoal(id: 'goal', title: '长期目标', deadline: _at(14, 17 * 60)),
    source: 'siliconflow',
    items: [
      PlannedTask(
        task: task,
        entry: split
            ? _block(task.copyWith(estimatedMinutes: 60), blockDay)
            : _block(task, blockDay),
        additionalEntries: split
            ? [
                CalendarEntry(
                  id: 'second-block',
                  taskId: task.id,
                  title: task.title,
                  start: _at(blockDay, 10 * 60 + 15),
                  end: _at(blockDay, 11 * 60 + 15),
                ),
              ]
            : const [],
      ),
    ],
  );
}

Workspace _workspace({
  List<SeraTask> tasks = const [],
  List<PlanDraft> drafts = const [],
}) => Workspace(
  revision: 1,
  preferences: _preferences,
  tasks: tasks,
  drafts: drafts,
);

void main() {
  test(
    'direct slot suggestions preserve the release and default deadline',
    () async {
      final (controller, _) = await _controller(_workspace(tasks: [_task()]));
      final suggestion = controller.findAvailableSlot(
        'task',
        from: _now,
        deadlineOverride: _at(20, 17 * 60),
      );
      expect(suggestion, isNotNull);
      expect(suggestion!.start, _at(7, 9 * 60));
      expect(suggestion.end.isAfter(_task().deadline!), isFalse);
      expect(
        controller.findAvailableSlot('task', deadlineOverride: _at(6, 17 * 60)),
        isNull,
      );
      expect(
        controller.findAvailableSlot('task', from: _at(8, 9 * 60)),
        isNull,
      );
    },
  );

  test('an explicit candidate extension requires the edited task deadline before save', () async {
    final task = _task();
    final (controller, _) = await _controller(_workspace(tasks: [task]));
    final extended = _at(9, 17 * 60);
    final candidate = controller.findAvailableSlot(
      task.id,
      from: _at(8, 9 * 60),
      deadlineOverride: extended,
    );
    expect(candidate, isNotNull);
    await expectLater(
      controller.saveTask(task, entry: candidate),
      throwsA(isA<RepositoryException>()),
    );
    await controller.saveTask(task.copyWith(dueAt: extended), entry: candidate);
    expect(controller.task(task.id)!.deadline, extended);
    expect(controller.entryForTask(task.id)!.start, _at(8, 9 * 60));
    expect(controller.task(task.id)!.notBefore, task.notBefore);
  });

  test(
    'applyReplan rejects a manually supplied time before the stage starts',
    () async {
      final (controller, store) = await _controller(
        _workspace(tasks: [_task()]),
      );
      final before = store.value.toJson();
      final saves = store.saves;
      await expectLater(
        controller.applyReplan('task', _at(0, 10 * 60)),
        throwsA(isA<RepositoryException>()),
      );
      expect(store.saves, saves);
      expect(store.value.toJson(), before);
    },
  );

  test('manual task blocks cannot bypass a persisted stage window', () async {
    final task = _task();
    final (controller, store) = await _controller(_workspace(tasks: [task]));
    final saves = store.saves;
    await expectLater(
      controller.saveEntry(_block(task, 0)),
      throwsA(isA<RepositoryException>()),
    );
    expect(store.saves, saves);
    expect(controller.data.entries, isEmpty);
  });

  test('editing a draft cannot move a valid block before the phase', () async {
    final draft = _draft(blockDay: 7);
    final (controller, store) = await _controller(_workspace(drafts: [draft]));
    final saves = store.saves;
    await expectLater(
      controller.updateDraftItem(
        draft.id,
        PlannedTask(
          task: draft.items.single.task,
          entry: _block(draft.items.single.task, 0),
        ),
      ),
      throwsA(isA<RepositoryException>()),
    );
    expect(store.saves, saves);
    expect(
      controller.data.drafts.single.items.single.entry!.start,
      _at(7, 9 * 60),
    );
  });

  test(
    'commit rejects a restored draft whose block is before its phase',
    () async {
      final draft = _draft(blockDay: 0);
      final (controller, store) = await _controller(
        _workspace(drafts: [draft]),
      );
      final saves = store.saves;
      await expectLater(
        controller.commitDraft(draft.id),
        throwsA(isA<RepositoryException>()),
      );
      expect(store.saves, saves);
      expect(controller.data.tasks, isEmpty);
      expect(controller.data.entries, isEmpty);
      expect(controller.data.drafts.single.status, 'draft');
    },
  );

  test('revalidating a restored draft moves early blocks into the real phase window', () async {
    final draft = _draft(blockDay: 0);
    final (controller, _) = await _controller(_workspace(drafts: [draft]));
    await controller.revalidateDraft(draft.id);
    final item = controller.data.drafts.single.items.single;
    expect(item.entry!.start, _at(7, 9 * 60));
    expect(item.entry!.end.isAfter(item.task.deadline!), isFalse);
    expect(item.task.phase, '后续阶段');
    expect(controller.data.tasks, isEmpty);
  });

  test(
    'revalidation checks sibling blocks together against the daily cap',
    () async {
      final draft = _draft(blockDay: 0, split: true);
      final (controller, _) = await _controller(_workspace(drafts: [draft]));
      await controller.revalidateDraft(draft.id);
      final item = controller.data.drafts.single.items.single;
      expect(
        item.blocks.fold<int>(0, (sum, block) => sum + block.minutes),
        120,
      );
      expect(item.blocks.first.start, _now);
      expect(item.blocks.last.start, _at(1, 9 * 60));
      final perDay = <DateTime, int>{};
      for (final block in item.blocks) {
        final day = dateOnly(block.start);
        perDay[day] = (perDay[day] ?? 0) + block.minutes;
      }
      expect(perDay.values, everyElement(lessThanOrEqualTo(90)));
    },
  );
}
