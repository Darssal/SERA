import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';

final _now = DateTime(2026, 10, 31);

class _ResultStore implements WorkspaceRepository {
  _ResultStore(this.value);
  Workspace value;
  bool failNext = false;
  final accepted = <Workspace>[];
  @override
  String get mode => 'planning-result-memory-fixture';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async {}
  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    if (failNext) {
      failNext = false;
      throw const RepositoryException('合成保存失败');
    }
    if (value.revision != expectedRevision) {
      throw const RepositoryException('合成版本冲突', conflict: true);
    }
    value = Workspace.fromJson(
      next.copyWith(revision: expectedRevision + 1).toJson(),
    );
    accepted.add(value);
    return value;
  }
}

PlanningSession _session(String id) => PlanningSession(
  id: id,
  updatedAt: _now,
  prompt: '保留原始输入',
  notes: '保留用户补充',
  stage: 'understood',
);

Future<SeraController> _controller(_ResultStore store) async {
  final result = SeraController(repository: store, today: _now);
  await result.initialize();
  addTearDown(result.dispose);
  return result;
}

void main() {
  test('legacy sessions and result references round-trip without reusing refinement fields', () {
    final legacy = PlanningSession.fromJson({
      'id': 'old',
      'updatedAt': _now.toIso8601String(),
    });
    expect(legacy.resultEntity, isNull);
    final ref = const PlanningResultRef(kind: 'task', id: 'stored-task');
    final saved = legacy.copyWith(stage: 'confirmed', resultEntity: ref);
    final restored = PlanningSession.fromJson(saved.toJson());
    expect(restored.resultEntity!.toJson(), ref.toJson());
    expect(restored.targetTaskId, isNull);
    expect(restored.copyWith(notes: '更新展示字段').resultEntity!.id, ref.id);
    expect(
      () =>
          PlanningSession.fromJson({...saved.toJson(), 'resultEntity': 'bad'}),
      throwsFormatException,
    );
    expect(
      () => PlanningResultRef.fromJson({'kind': 'goal', 'id': 'bad'}),
      throwsFormatException,
    );
  });

  test('task and confirmed session commit once and stale autosave cannot downgrade them', () async {
    final source = _session('task-source');
    final store = _ResultStore(
      Workspace(revision: 1, planningSessions: [source]),
    );
    final c = await _controller(store);
    final first = c.saveTask(
      const SeraTask(id: 'caller-id', title: '原任务'),
      sourceSessionId: source.id,
    );
    final replay = c.saveTask(
      const SeraTask(id: 'another-id', title: '迟到旧表单'),
      sourceSessionId: source.id,
    );
    final results = await Future.wait([first, replay]);
    expect(results[0].toJson(), results[1].toJson());
    expect(store.accepted, hasLength(1));
    final transaction = store.accepted.single;
    expect(transaction.tasks.single.id, results.first.id);
    expect(transaction.tasks.single.title, '原任务');
    expect(transaction.planningSessions.single.stage, 'confirmed');
    expect(
      transaction.planningSessions.single.resultEntity!.id,
      results.first.id,
    );
    await c.savePlanningSession(source.copyWith(stage: 'input', notes: '迟到快照'));
    expect(store.accepted, hasLength(1));
    expect(c.planningSession(source.id)!.stage, 'confirmed');
    expect(c.planningSession(source.id)!.notes, source.notes);
  });

  test(
    'event result survives reload and replay returns the same existing entity',
    () async {
      final source = _session('event-source');
      final store = _ResultStore(
        Workspace(revision: 1, planningSessions: [source]),
      );
      final c = await _controller(store);
      final event = CalendarEntry(
        id: 'temporary',
        title: '课程讨论',
        start: DateTime(2026, 11, 1, 15),
        end: DateTime(2026, 11, 1, 15, 30),
        locked: true,
      );
      final result = await c.saveEntry(event, sourceSessionId: source.id);
      final restored = await _controller(store);
      final replay = await restored.saveEntry(
        event.copyWith(title: '过期输入'),
        sourceSessionId: source.id,
      );
      expect(result.toJson(), replay.toJson());
      expect(restored.entry(result.id)!.title, '课程讨论');
      expect(restored.planningSession(source.id)!.resultEntity!.kind, 'event');
      expect(store.accepted, hasLength(1));
    },
  );

  for (final kind in ['task', 'event']) {
    test(
      'deleted $kind result is not recreated by its original source',
      () async {
        final source = _session('deleted-$kind');
        final store = _ResultStore(
          Workspace(revision: 1, planningSessions: [source]),
        );
        final c = await _controller(store);
        final event = CalendarEntry(
          id: 'temporary-event',
          title: '原日程',
          start: DateTime(2026, 11, 1, 15),
          end: DateTime(2026, 11, 1, 15, 30),
          locked: true,
        );
        final task = const SeraTask(id: 'temporary-task', title: '原任务');
        final result = kind == 'task'
            ? await c.saveTask(task, sourceSessionId: source.id)
            : await c.saveEntry(event, sourceSessionId: source.id);
        if (kind == 'task') {
          await c.deleteTask(result.id);
        } else {
          await c.deleteEntry(result.id);
        }
        final count = store.accepted.length;
        await expectLater(
          kind == 'task'
              ? c.saveTask(task, sourceSessionId: source.id)
              : c.saveEntry(event, sourceSessionId: source.id),
          throwsA(
            isA<RepositoryException>().having(
              (error) => error.message,
              'message',
              contains('已删除'),
            ),
          ),
        );
        expect(store.accepted, hasLength(count));
        expect(c.hasPlanningResult(result), isFalse);
        expect(c.planningSession(source.id)!.resultEntity!.id, result.id);
      },
    );
  }

  test('failed atomic save leaves no entity or confirmation and retry uses the stable id', () async {
    final source = _session('retry-source');
    final store = _ResultStore(
      Workspace(revision: 1, planningSessions: [source]),
    );
    final c = await _controller(store);
    final expected = c.planningResultFor(source.id, 'task');
    store.failNext = true;
    const task = SeraTask(id: 'arbitrary', title: '重试任务');
    await expectLater(
      c.saveTask(task, sourceSessionId: source.id),
      throwsA(isA<RepositoryException>()),
    );
    expect(c.data.tasks, isEmpty);
    expect(c.planningSession(source.id)!.resultEntity, isNull);
    expect(c.planningSession(source.id)!.stage, 'understood');
    expect(store.accepted, isEmpty);
    final result = await c.saveTask(task, sourceSessionId: source.id);
    expect(result.id, expected.id);
    expect(store.accepted, hasLength(1));
  });

  test('completed source cannot change kind and ordinary saves retain their existing id', () async {
    final source = _session('kind-source');
    final c = await _controller(
      _ResultStore(Workspace(revision: 1, planningSessions: [source])),
    );
    const task = SeraTask(id: 'normal-task', title: '直接添加');
    final ordinary = await c.saveTask(task);
    expect(ordinary.id, task.id);
    await c.saveTask(
      const SeraTask(id: 'source-task', title: '会话任务'),
      sourceSessionId: source.id,
    );
    expect(
      () => c.planningResultFor(source.id, 'event'),
      throwsA(isA<RepositoryException>()),
    );
    expect(
      () => c.planningResultFor('missing-source', 'task'),
      throwsA(isA<RepositoryException>()),
    );
  });

  test('replanning an explicit time block preserves siblings and rejects stale revision', () async {
    const task = SeraTask(
      id: 'split',
      title: '分段任务',
      estimatedMinutes: 60,
      splittable: true,
    );
    final first = CalendarEntry(
      id: 'first',
      taskId: task.id,
      title: task.title,
      start: DateTime(2026, 11, 1, 14),
      end: DateTime(2026, 11, 1, 14, 30),
    );
    final second = CalendarEntry(
      id: 'second',
      taskId: task.id,
      title: task.title,
      start: DateTime(2026, 10, 31, 14),
      end: DateTime(2026, 10, 31, 14, 30),
    );
    final c = await _controller(
      _ResultStore(
        Workspace(
          revision: 1,
          tasks: [task],
          entries: [first, second],
          preferences: const SeraPreferences(
            weekdays: [1, 2, 3, 4, 5, 6, 7],
            dailyBudget: 480,
            bufferMinutes: 0,
            startMinute: 480,
            endMinute: 1200,
            restStart: 0,
            restEnd: 0,
          ),
        ),
      ),
    );
    await c.applyReplan(
      task.id,
      DateTime(2026, 10, 31, 15),
      entryId: second.id,
      expectedEntryRevision: second.revision,
    );
    expect(c.entry(first.id)!.toJson(), first.toJson());
    expect(c.entry(second.id)!.start.hour, 15);
    await expectLater(
      c.applyReplan(
        task.id,
        DateTime(2026, 10, 31, 16),
        entryId: second.id,
        expectedEntryRevision: second.revision,
      ),
      throwsA(
        isA<RepositoryException>().having(
          (error) => error.conflict,
          'conflict',
          isTrue,
        ),
      ),
    );
    expect(c.entry(second.id)!.start.hour, 15);
  });
}
