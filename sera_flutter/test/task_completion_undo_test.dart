
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';

DateTime _at(int day, int hour) => readZoned(
  '2026-11-${day.toString().padLeft(2, '0')}T${hour.toString().padLeft(2, '0')}:00:00+08:00',
  'Asia/Hong_Kong',
)!;

class _Store implements WorkspaceRepository {
  _Store(this.value);
  Workspace value;
  bool failNext = false;
  @override
  String get mode => 'completion-undo';
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
      throw const RepositoryException('本地保存失败');
    }
    if (value.revision != expectedRevision) {
      throw const RepositoryException('版本冲突', conflict: true);
    }
    return value = Workspace.fromJson(
      next.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }
}

Workspace _workspace({bool focus = false}) => Workspace(
  revision: 1,
  tasks: const [
    SeraTask(
      id: 'task',
      title: '整理资料',
      status: 'in_progress',
      estimatedMinutes: 120,
      splittable: true,
      actualSeconds: 30,
      checklist: ['收集', '归档'],
      completedChecks: ['收集'],
    ),
    SeraTask(id: 'other', title: '采购清单'),
  ],
  entries: [
    CalendarEntry(
      id: 'block',
      taskId: 'task',
      title: '整理资料',
      start: _at(2, 14),
      end: _at(2, 15),
    ),
    CalendarEntry(
      id: 'block-2',
      taskId: 'task',
      title: '整理资料',
      start: _at(3, 14),
      end: _at(3, 15),
    ),
  ],
  focusSession: focus
      ? FocusSession(
          id: 'focus',
          taskId: 'task',
          startedAt: _at(1, 9),
          accumulatedSeconds: 73,
          isRunning: false,
        )
      : null,
);

Future<SeraController> _controller(_Store store) async {
  final c = SeraController(
    repository: store,
    today: _at(1, 9),
    seedDemo: false,
  );
  await c.initialize();
  addTearDown(c.dispose);
  return c;
}

Matcher get _conflict =>
    isA<RepositoryException>().having((e) => e.conflict, 'conflict', true);

void main() {
  test('completion undo restores removed blocks and preserves later unrelated work', () async {
    final initial = _workspace();
    final c = await _controller(_Store(initial));
    final record = await c.completeTaskWithUndo('task');
    expect(c.data.entries, isEmpty);
    await c.saveTask(c.task('other')!.copyWith(title: '后来修改的采购清单'));
    expect(await c.undoTaskCompletion(record), isTrue);
    expect(c.task('task')!.status, 'in_progress');
    expect(c.task('task')!.completedChecks, ['收集']);
    expect(c.task('other')!.title, '后来修改的采购清单');
    expect(c.data.entries, hasLength(2));
    for (final original in initial.entries) {
      final restored = c.entry(original.id)!;
      expect(
        restored.toJson()..remove('revision'),
        original.toJson()..remove('revision'),
      );
      expect(restored.revision, original.revision + 1);
    }
    expect(c.data.history.firstWhere((r) => r.id == record).undone, isTrue);
  });

  test(
    'completion undo keeps recorded focus time and never restarts focus',
    () async {
      final c = await _controller(_Store(_workspace(focus: true)));
      final record = await c.completeTaskWithUndo('task');
      expect(c.data.focusSession, isNull);
      expect(c.task('task')!.actualSeconds, 103);
      expect(c.data.focusRecords.single.seconds, 73);
      await c.undoTaskCompletion(record);
      expect(c.data.focusSession, isNull);
      expect(c.task('task')!.actualSeconds, 103);
      expect(c.data.focusRecords.single.seconds, 73);
      expect(c.data.entries, hasLength(2));
    },
  );

  test('new occupancy rejects the entire undo without restoring status or any block', () async {
    final c = await _controller(_Store(_workspace()));
    final record = await c.completeTaskWithUndo('task');
    await c.saveEntry(
      CalendarEntry(
        id: 'meeting',
        title: '临时会议',
        start: _at(3, 14),
        end: _at(3, 15),
        locked: true,
      ),
    );
    final before = c.data.toJson();
    await expectLater(c.undoTaskCompletion(record), throwsA(_conflict));
    expect(c.data.toJson(), before);
    expect(c.task('task')!.done, isTrue);
    expect(c.entry('block'), isNull);
  });

  test('external calendar occupancy also prevents restoration', () async {
    final c = await _controller(_Store(_workspace()));
    final record = await c.completeTaskWithUndo('task');
    await c.setExternalBusyEntries([
      CalendarEntry(
        id: 'external',
        title: '外部会议',
        start: _at(2, 14),
        end: _at(2, 15),
      ),
    ], source: 'device');
    await expectLater(c.undoTaskCompletion(record), throwsA(_conflict));
    expect(c.task('task')!.done, isTrue);
    expect(c.data.entries, isEmpty);
  });

  for (final deleteAgain in [false, true]) {
    test(
      'reuse of a removed ID cannot be resurrected, deleted again: $deleteAgain',
      () async {
        final c = await _controller(_Store(_workspace()));
        final record = await c.completeTaskWithUndo('task');
        await c.saveEntry(
          CalendarEntry(
            id: 'block',
            title: '新会议',
            start: _at(5, 14),
            end: _at(5, 15),
            locked: true,
          ),
        );
        if (deleteAgain) await c.deleteEntry('block');
        final before = c.data.toJson();
        await expectLater(c.undoTaskCompletion(record), throwsA(_conflict));
        expect(c.data.toJson(), before);
      },
    );
  }

  test('later edits to the same task prevent stale completion undo', () async {
    final c = await _controller(_Store(_workspace()));
    final record = await c.completeTaskWithUndo('task');
    await c.saveTask(c.task('task')!.copyWith(title: '已修改任务'));
    await expectLater(c.undoTaskCompletion(record), throwsA(_conflict));
    expect(c.task('task')!.done, isTrue);
    expect(c.task('task')!.title, '已修改任务');
  });

  test('failed restoration is retryable and repeated undo never affects another record', () async {
    final store = _Store(_workspace());
    final c = await _controller(store);
    final record = await c.completeTaskWithUndo('task');
    store.failNext = true;
    await expectLater(
      c.undoTaskCompletion(record),
      throwsA(isA<RepositoryException>()),
    );
    expect(c.task('task')!.done, isTrue);
    expect(c.data.entries, isEmpty);
    expect(c.data.history.last.undone, isFalse);
    final results = await Future.wait([
      c.undoTaskCompletion(record),
      c.undoTaskCompletion(record),
    ]);
    expect(results, [true, false]);
    expect(c.data.entries, hasLength(2));
  });
}
