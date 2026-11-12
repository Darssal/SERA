import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';

final _day = readZoned('2026-11-02T09:00:00+08:00', 'Asia/Hong_Kong')!;
DateTime _at(int minute) => atMinute(_day, minute);

Workspace _workspace() => Workspace(
  revision: 1,
  preferences: const SeraPreferences(
    dailyBudget: 120,
    startMinute: 540,
    endMinute: 1080,
    bufferMinutes: 0,
    restStart: 0,
    restEnd: 0,
  ),
  tasks: const [
    SeraTask(
      id: 'task',
      title: '复习第一章',
      estimatedMinutes: 30,
      splittable: true,
      minBlockMinutes: 15,
    ),
    SeraTask(id: 'unrelated', title: '采购清单', checklist: ['鸡蛋', '水果']),
  ],
  entries: [
    CalendarEntry(
      id: 'block',
      taskId: 'task',
      title: '复习第一章',
      start: _at(540),
      end: _at(555),
    ),
    CalendarEntry(
      id: 'sibling',
      taskId: 'task',
      title: '复习第一章',
      start: _at(600),
      end: _at(615),
    ),
  ],
);

class _Store implements WorkspaceRepository {
  Workspace value = _workspace();
  int writes = 0;
  bool failNext = false;
  Completer<void>? gate;
  @override
  String get mode => 'selective-replan-undo';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async {}
  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    final wait = gate;
    gate = null;
    if (wait != null) await wait.future;
    if (expectedRevision != value.revision) {
      throw const RepositoryException('工作区已有其他修改。', conflict: true);
    }
    if (failNext) {
      failNext = false;
      throw const RepositoryException('本地保存失败。');
    }
    writes++;
    return value = Workspace.fromJson(
      next.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }
}

Future<SeraController> _controller(_Store store) async {
  final c = SeraController(repository: store, today: _day, seedDemo: false);
  await c.initialize();
  addTearDown(c.dispose);
  return c;
}

Future<String> _adjust(SeraController c) =>
    c.applyReplan('task', _at(570), entryId: 'block', expectedEntryRevision: 1);

Matcher get _conflict => isA<RepositoryException>().having(
  (error) => error.conflict,
  'conflict',
  true,
);

Json _otherContent(Workspace value) => value.toJson()
  ..remove('entries')
  ..remove('history')
  ..remove('revision');

void main() {
  test(
    'F13 restores only the adjusted block after unrelated later edits',
    () async {
      final store = _Store();
      final c = await _controller(store);
      final original = c.entry('block')!;
      final sibling = c.entry('sibling')!.toJson();
      final recordId = await _adjust(c);
      await c.saveTask(c.task('unrelated')!.copyWith(title: '明天的采购清单'));
      await c.setCheck('unrelated', '鸡蛋', true);
      await c.recordFocus('unrelated', 23);
      await c.savePlanningSession(
        PlanningSession(
          id: 'later-conversation',
          prompt: '保留这次未完成输入',
          updatedAt: _day,
        ),
      );
      final expectedOther = _otherContent(c.data);
      final laterRecords = c.data.history
          .skip(1)
          .map((r) => r.toJson())
          .toList();
      expect(c.canUndoReplan(recordId), isTrue);
      expect(c.replanUndoConflict(recordId), isNull);

      expect(await c.undoReplan(recordId), isTrue);

      expect(
        c.entry('block')!.toJson(),
        original.copyWith(revision: 3).toJson(),
      );
      expect(c.entry('sibling')!.toJson(), sibling);
      expect(_otherContent(c.data), expectedOther);
      expect(c.data.history.first.undone, isTrue);
      expect(
        c.data.history.skip(1).map((r) => r.toJson()).toList(),
        laterRecords,
      );
      expect(c.task('unrelated')!.title, '明天的采购清单');
      expect(c.task('unrelated')!.completedChecks, ['鸡蛋']);
      expect(store.value.toJson(), c.data.toJson());
    },
  );

  test(
    'same task notes remain when its time blocks were not changed',
    () async {
      final c = await _controller(_Store());
      final id = await _adjust(c);
      await c.saveTask(c.task('task')!.copyWith(notes: '撤销时间不应删除这段笔记'));
      final task = c.task('task')!.toJson();
      expect(c.canUndoReplan(id), isTrue);
      expect(await c.undoReplan(id), isTrue);
      expect(c.task('task')!.toJson(), task);
      expect(c.entry('block')!.start, _at(540));
    },
  );

  test(
    'an unrelated later calendar edit is preserved by the inverse patch',
    () async {
      final c = await _controller(_Store());
      final id = await _adjust(c);
      await c.saveEntry(
        CalendarEntry(
          id: 'other-event',
          title: '晚上看电影',
          start: _at(1200),
          end: _at(1290),
          locked: true,
        ),
      );
      final other = c.entry('other-event')!.toJson();
      expect(c.canUndoReplan(id), isTrue);
      expect(await c.undoReplan(id), isTrue);
      expect(c.entry('other-event')!.toJson(), other);
      expect(c.entry('block')!.start, _at(540));
    },
  );

  test(
    'later changes to the affected entry reject both visible and stale actions',
    () async {
      final store = _Store();
      final c = await _controller(store);
      final id = await _adjust(c);
      await c.saveEntry(c.entry('block')!.copyWith(notes: '后来补充的日程信息'));
      final current = c.data.toJson();
      final writes = store.writes;
      expect(c.canUndoReplan(id), isFalse);
      expect(c.replanUndoConflict(id), contains('新修改'));
      await expectLater(c.undoReplan(id), throwsA(_conflict));
      expect(c.data.toJson(), current);
      expect(store.writes, writes);
    },
  );

  test('an entry version change alone prevents stale undo', () async {
    final store = _Store();
    final c = await _controller(store);
    final id = await _adjust(c);
    final current = c.entry('block')!;
    store.value = store.value.copyWith(
      revision: store.value.revision + 1,
      entries: [
        for (final item in store.value.entries)
          item.id == current.id
              ? item.copyWith(revision: item.revision + 1)
              : item,
      ],
    );
    await c.refresh();
    expect(c.canUndoReplan(id), isFalse);
    await expectLater(c.undoReplan(id), throwsA(_conflict));
    expect(c.entry('block')!.start, _at(570));
    expect(c.data.history.single.undone, isFalse);
  });

  test('deleting the adjusted entry does not resurrect it on undo', () async {
    final c = await _controller(_Store());
    final id = await _adjust(c);
    await c.deleteEntry('block');
    final current = c.data.toJson();
    expect(c.canUndoReplan(id), isFalse);
    await expectLater(c.undoReplan(id), throwsA(_conflict));
    expect(c.entry('block'), isNull);
    expect(c.data.toJson(), current);
  });

  test(
    'completing the linked task cannot restore its removed schedule',
    () async {
      final c = await _controller(_Store());
      final id = await _adjust(c);
      await c.setDone('task', true);
      final current = c.data.toJson();
      expect(c.canUndoReplan(id), isFalse);
      await expectLater(c.undoReplan(id), throwsA(_conflict));
      expect(c.data.toJson(), current);
      expect(c.task('task')!.done, isTrue);
    },
  );

  test('new occupancy of the original slot blocks undo without losing either event', () async {
    final c = await _controller(_Store());
    final id = await _adjust(c);
    await c.saveEntry(
      CalendarEntry(
        id: 'new-meeting',
        title: '后来确认的会议',
        start: _at(540),
        end: _at(555),
        locked: true,
      ),
    );
    final current = c.data.toJson();
    expect(c.canUndoReplan(id), isFalse);
    expect(c.replanUndoConflict(id), contains('原时段'));
    await expectLater(c.undoReplan(id), throwsA(_conflict));
    expect(c.data.toJson(), current);
  });

  test('repeated and queued exact undo cannot undo another record', () async {
    final store = _Store();
    final c = await _controller(store);
    final id = await _adjust(c);
    await c.saveTask(c.task('unrelated')!.copyWith(notes: '必须保留'));
    final writes = store.writes;
    final results = await Future.wait([c.undoReplan(id), c.undoReplan(id)]);
    expect(results, [true, false]);
    expect(store.writes, writes + 1);
    expect(c.data.history.first.undone, isTrue);
    expect(c.data.history.last.undone, isFalse);
    expect(c.task('unrelated')!.notes, '必须保留');
    expect(c.canUndoReplan(id), isFalse);
    expect(await c.undoLast(expectedRecordId: id), isFalse);
    expect(store.writes, writes + 1);
  });

  test(
    'queued undo checks affected entry again after a preceding save',
    () async {
      final store = _Store();
      final c = await _controller(store);
      final id = await _adjust(c);
      expect(c.canUndoReplan(id), isTrue);
      final update = c.saveEntry(c.entry('block')!.copyWith(notes: '排队中的新备注'));
      final undo = c.undoReplan(id);
      final rejected = expectLater(undo, throwsA(_conflict));
      await update;
      await rejected;
      expect(c.entry('block')!.notes, '排队中的新备注');
      expect(c.entry('block')!.start, _at(570));
      expect(c.data.history.every((record) => !record.undone), isTrue);
      expect(store.writes, 2);
    },
  );

  test(
    'a repository conflict while undo is saving keeps the newer workspace',
    () async {
      final store = _Store();
      final c = await _controller(store);
      final id = await _adjust(c);
      final local = c.data.toJson();
      final gate = Completer<void>();
      store.gate = gate;
      final undo = c.undoReplan(id);
      final rejected = expectLater(undo, throwsA(_conflict));
      await Future<void>.delayed(Duration.zero);
      store.value = store.value.copyWith(
        revision: store.value.revision + 1,
        tasks: [
          for (final task in store.value.tasks)
            task.id == 'unrelated'
                ? task.copyWith(title: '另一客户端新标题', revision: task.revision + 1)
                : task,
        ],
      );
      final remote = store.value.toJson();
      gate.complete();
      await rejected;
      expect(c.data.toJson(), local);
      expect(store.value.toJson(), remote);
      expect(store.value.history.single.undone, isFalse);
    },
  );

  test(
    'failed local undo leaves history untouched and can safely retry',
    () async {
      final store = _Store();
      final c = await _controller(store);
      final id = await _adjust(c);
      final before = c.data.toJson();
      store.failNext = true;
      await expectLater(c.undoReplan(id), throwsA(isA<RepositoryException>()));
      expect(c.data.toJson(), before);
      expect(store.value.toJson(), before);
      expect(c.canUndoReplan(id), isTrue);
      expect(await c.undoReplan(id), isTrue);
      expect(c.entry('block')!.start, _at(540));
    },
  );

  test('non-adjustment record cannot gain selective undo by ID', () async {
    final c = await _controller(_Store());
    await c.saveTask(c.task('unrelated')!.copyWith(title: '普通任务修改'));
    final id = c.data.history.single.id;
    expect(c.canUndoReplan(id), isFalse);
    await expectLater(c.undoReplan(id), throwsA(_conflict));
    // The existing generic undo contract remains available for ordinary edits.
    expect(await c.undoLast(), isTrue);
    expect(c.task('unrelated')!.title, '采购清单');
  });
}
