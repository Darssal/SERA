import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/change_history.dart';
import 'package:sera_flutter/domain/models.dart';

final _day = readZoned('2026-11-02T09:00:00+08:00', 'Asia/Hong_Kong')!;

class _Store implements WorkspaceRepository {
  _Store(this.value, {this.reverseEntities = false});
  Workspace value;
  final bool reverseEntities;
  @override
  String get mode => 'compact-history-test';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async {}
  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    if (expectedRevision != value.revision) {
      throw const RepositoryException('已有新版本', conflict: true);
    }
    final saved = next.copyWith(
      revision: expectedRevision + 1,
      tasks: reverseEntities ? next.tasks.reversed.toList() : null,
      entries: reverseEntities ? next.entries.reversed.toList() : null,
    );
    return value = Workspace.fromJson(saved.toJson());
  }
}

Future<SeraController> _controller(_Store store) async {
  final c = SeraController(repository: store, today: _day, seedDemo: false);
  await c.initialize();
  addTearDown(c.dispose);
  return c;
}

Workspace _small() => Workspace(
  revision: 1,
  tasks: const [
    SeraTask(id: 'a', title: '旧待办', checklist: ['准备', '完成']),
    SeraTask(id: 'b', title: '其他待办'),
  ],
);

Matcher get _conflict => isA<RepositoryException>().having(
  (error) => error.conflict,
  'conflict',
  true,
);

void main() {
  test(
    'sparse add/edit/delete history restores complete business state and order',
    () async {
      final store = _Store(_small());
      final c = await _controller(store);
      final initial = historySnapshot(c.data);
      await c.saveTask(const SeraTask(id: 'new', title: '新待办'));
      var record = c.data.history.last;
      expect(record.isDelta, isTrue);
      expect(record.before['tasks'], isEmpty);
      expect(record.after['tasks'], hasLength(1));
      expect(record.after['entries'], isEmpty);
      expect(await c.undoLast(), isTrue);
      expect(historySnapshot(c.data), initial);

      await c.saveTask(c.task('a')!.copyWith(title: '修改原任务'));
      record = c.data.history.last;
      expect(record.before['tasks'], hasLength(1));
      expect(record.after['tasks'], hasLength(1));
      expect(await c.undoLast(), isTrue);
      expect(historySnapshot(c.data), initial);

      await c.deleteTask('a');
      expect(c.data.history.last.after['tasks'], isEmpty);
      expect(await c.undoLast(), isTrue);
      expect(historySnapshot(c.data), initial);
      expect(c.data.tasks.map((t) => t.id), ['a', 'b']);
    },
  );

  test('cascading delete undo retains goal links, dependencies, calendar and focus', () async {
    final initial = _small().copyWith(
      tasks: const [
        SeraTask(id: 'a', title: '原任务', goalId: 'goal', actualSeconds: 20),
        SeraTask(id: 'b', title: '后续任务', dependencyIds: ['a']),
      ],
      goals: [
        SeraGoal(
          id: 'goal',
          title: '目标',
          deadline: _day.add(const Duration(days: 7)),
          taskIds: const ['a'],
        ),
      ],
      entries: [
        CalendarEntry(
          id: 'entry',
          title: '原任务',
          taskId: 'a',
          start: _day,
          end: _day.add(const Duration(minutes: 30)),
        ),
      ],
      focusRecords: [
        FocusRecord(id: 'focus', taskId: 'a', startedAt: _day, seconds: 20),
      ],
    );
    final c = await _controller(_Store(initial));
    await c.deleteTask('a');
    final record = c.data.history.last;
    expect(record.before['tasks'], hasLength(2));
    expect(record.before['entries'], hasLength(1));
    expect(record.before['focusRecords'], hasLength(1));
    expect(record.before['goals'], hasLength(1));
    expect(await c.undoLast(), isTrue);
    expect(historySnapshot(c.data), historySnapshot(initial));
  });

  test(
    'preferences are a scalar replacement without copying unchanged tasks',
    () async {
      final c = await _controller(_Store(_small()));
      final before = historySnapshot(c.data);
      await c.savePreferences(c.data.preferences.copyWith(dailyBudget: 120));
      expect(c.data.history.single.before['tasks'], isEmpty);
      expect(c.data.history.single.before, contains('preferences'));
      expect(await c.undoLast(), isTrue);
      expect(historySnapshot(c.data), before);
    },
  );

  test(
    'generic undo remains conservative after an unrecorded unrelated edit',
    () async {
      final store = _Store(_small());
      final c = await _controller(store);
      await c.saveTask(c.task('a')!.copyWith(title: '本次修改'));
      store.value = store.value.copyWith(
        revision: store.value.revision + 1,
        tasks: [
          for (final t in store.value.tasks)
            t.id == 'b' ? t.copyWith(title: '其他客户端修改', revision: 2) : t,
        ],
      );
      await c.refresh();
      final current = c.data.toJson();
      await expectLater(c.undoLast(), throwsA(_conflict));
      expect(c.data.toJson(), current);
    },
  );

  test(
    'entity order from repository does not invalidate after digest',
    () async {
      final store = _Store(_small(), reverseEntities: true);
      final c = await _controller(store);
      await c.saveTask(c.task('a')!.copyWith(title: '修改'));
      expect(historyMatchesAfter(c.data.history.single, c.data), isTrue);
      expect(await c.undoLast(), isTrue);
      expect(c.task('a')!.title, '旧待办');
      expect(c.task('b')!.title, '其他待办');
    },
  );

  test(
    'digest treats entity order as a set while preserving checklist order',
    () {
      final first = _small();
      final reordered = first.copyWith(tasks: first.tasks.reversed.toList());
      expect(
        historySnapshotDigest(historySnapshot(first)),
        historySnapshotDigest(historySnapshot(reordered)),
      );
      final changed = first.copyWith(
        tasks: [
          first.tasks.first.copyWith(checklist: ['完成', '准备']),
          first.tasks.last,
        ],
      );
      expect(
        historySnapshotDigest(historySnapshot(first)),
        isNot(historySnapshotDigest(historySnapshot(changed))),
      );
    },
  );

  test('legacy full history is readable then compacts on save with repeated undo intact', () async {
    const empty = Workspace(revision: 1);
    final after = empty.copyWith(
      tasks: const [SeraTask(id: 'a', title: '旧记录建立的任务')],
    );
    final legacy = ChangeRecord(
      id: 'legacy',
      label: '保存任务',
      at: _day,
      before: historySnapshot(empty),
      after: historySnapshot(after),
    );
    final store = _Store(after.copyWith(history: [legacy]));
    final c = await _controller(store);
    expect(
      store.value.history.single.format,
      isNull,
      reason: 'Reading must not rewrite history.',
    );
    await c.saveTask(const SeraTask(id: 'b', title: '新版本创建'));
    expect(c.data.history.map((r) => r.id), contains('legacy'));
    expect(c.data.history.every((r) => r.isDelta), isTrue);
    final reloaded = await _controller(store);
    expect(await reloaded.undoLast(), isTrue);
    expect(reloaded.data.tasks.map((t) => t.id), ['a']);
    expect(await reloaded.undoLast(), isTrue);
    expect(reloaded.data.tasks, isEmpty);
    expect(reloaded.data.history.every((r) => r.undone), isTrue);
  });

  test('legacy full record can still be undone without migration', () async {
    const empty = Workspace(revision: 1);
    final after = empty.copyWith(
      tasks: const [SeraTask(id: 'a', title: '旧任务')],
    );
    final record = ChangeRecord(
      id: 'legacy',
      label: '保存任务',
      at: _day,
      before: historySnapshot(empty),
      after: historySnapshot(after),
    );
    final c = await _controller(_Store(after.copyWith(history: [record])));
    expect(await c.undoLast(), isTrue);
    expect(c.data.tasks, isEmpty);
    expect(c.data.history.single.format, isNull);
  });

  test(
    'legacy compaction preserves record identity, timestamp and undone state',
    () {
      final old = ChangeRecord(
        id: 'already-undone',
        label: '保存任务',
        at: _day,
        before: historySnapshot(const Workspace()),
        after: historySnapshot(_small()),
        undone: true,
      );
      final compact = compactLegacyChange(old);
      expect(compact.isDelta, isTrue);
      expect(compact.id, old.id);
      expect(compact.at, old.at);
      expect(compact.undone, isTrue);
    },
  );

  test('2.0.7 full-snapshot guard rejects delta before it could replace workspace', () {
    final current = _small();
    final record = createCompactChange(
      id: 'new-format',
      label: '保存任务',
      at: _day,
      before: const Workspace(),
      after: current,
    );
    // The deployed 2.0.7 undo compared complete business JSON with record.after
    // before Workspace.fromJson(record.before). A delta can never pass it:
    // it deliberately lacks the full schema/preferences snapshot keys.
    expect(
      jsonEncode(historySnapshot(current)) == jsonEncode(record.after),
      isFalse,
    );
    expect(record.after.containsKey('schemaVersion'), isFalse);
    expect(record.after.containsKey('preferences'), isFalse);
  });

  test('format metadata survives mark-undone and JSON reload', () {
    final record = createCompactChange(
      id: 'change',
      label: '保存任务',
      at: _day,
      before: _small(),
      after: _small().copyWith(tasks: const []),
    );
    final decoded = ChangeRecord.fromJson(
      record.copyWith(undone: true).toJson(),
    );
    expect(decoded.format, record.format);
    expect(decoded.afterDigest, record.afterDigest);
    expect(decoded.beforeOrder, record.beforeOrder);
    expect(decoded.undone, isTrue);
    expect(decoded.before, record.before);
  });

  test(
    'unknown format and missing order cannot be interpreted as full workspace',
    () async {
      final record = createCompactChange(
        id: 'change',
        label: '保存任务',
        at: _day,
        before: const Workspace(),
        after: _small(),
      );
      expect(
        () => ChangeRecord.fromJson({
          ...record.toJson(),
          'format': 'future-delta',
        }),
        throwsFormatException,
      );
      final missingOrder = ChangeRecord.fromJson({
        ...record.toJson(),
        'beforeOrder': {},
      });
      expect(
        () => restoreHistoryBefore(missingOrder, _small()),
        throwsFormatException,
      );
      final invalid = ChangeRecord(
        id: 'future',
        label: '保存任务',
        at: _day,
        format: 'future-delta',
        before: {},
        after: {},
      );
      final c = await _controller(
        _Store(_small().copyWith(history: [invalid])),
      );
      final before = c.data.tasks.map((t) => t.toJson()).toList();
      await expectLater(c.undoLast(), throwsA(_conflict));
      expect(c.data.tasks.map((t) => t.toJson()).toList(), before);
    },
  );

  test(
    'completion delta keeps unchanged past blocks in its compact read set',
    () async {
      final past = CalendarEntry(
        id: 'past',
        title: '旧待办',
        taskId: 'a',
        start: _day.subtract(const Duration(days: 1)),
        end: _day
            .subtract(const Duration(days: 1))
            .add(const Duration(minutes: 30)),
      );
      final future = CalendarEntry(
        id: 'future',
        title: '旧待办',
        taskId: 'a',
        start: _day.add(const Duration(hours: 1)),
        end: _day.add(const Duration(hours: 2)),
      );
      final c = await _controller(
        _Store(_small().copyWith(entries: [past, future])),
      );
      final id = await c.completeTaskWithUndo('a');
      final record = c.data.history.single;
      expect(record.before['entries'], hasLength(1));
      expect(record.after['entries'], isEmpty);
      expect(record.afterTaskEntries['a'], {
        'past': historyEntityDigest(past.toJson()),
      });
      await c.saveTask(c.task('b')!.copyWith(notes: '保留后续修改'));
      expect(await c.undoTaskCompletion(id), isTrue);
      expect(c.entry('past')!.toJson(), past.toJson());
      expect(c.entry('future'), isNotNull);
      expect(c.task('b')!.notes, '保留后续修改');
      expect(c.data.history.first.afterTaskEntries, record.afterTaskEntries);
    },
  );

  test('thirty daily-data edits keep thirty undo records without whole workspace duplication', () async {
    final initial = Workspace(
      revision: 1,
      tasks: [
        for (var i = 0; i < 300; i++)
          SeraTask(
            id: 'task-$i',
            title: '日常待办 $i',
            notes: '这条内容在别的任务保存时不应被重复存入历史。',
          ),
      ],
      entries: [
        for (var i = 0; i < 200; i++)
          CalendarEntry(
            id: 'entry-$i',
            title: '日常日程 $i',
            start: _day.add(Duration(days: i)),
            end: _day.add(Duration(days: i, minutes: 30)),
          ),
      ],
      goals: [
        for (var i = 0; i < 30; i++)
          SeraGoal(
            id: 'goal-$i',
            title: '日常目标 $i',
            deadline: _day.add(const Duration(days: 100)),
          ),
      ],
    );
    final c = await _controller(_Store(initial));
    for (var i = 0; i < 30; i++) {
      await c.saveTask(SeraTask(id: 'new-$i', title: '连续新增 $i'));
    }
    expect(c.data.history, hasLength(30));
    expect(c.data.history.every((r) => r.isDelta), isTrue);
    final bytes = utf8
        .encode(jsonEncode(c.data.history.map((r) => r.toJson()).toList()))
        .length;
    final oldBaseline =
        utf8.encode(jsonEncode(historySnapshot(initial))).length * 60;
    // ignore: avoid_print
    print(
      jsonEncode({
        'case': 'daily-history-30',
        'tasks': 300,
        'entries': 200,
        'goals': 30,
        'records': 30,
        'deltaBytes': bytes,
        'legacyFullSnapshotLowerBoundBytes': oldBaseline,
      }),
    );
    expect(bytes, lessThan(500000));
    expect(bytes, lessThan(oldBaseline ~/ 10));
    final reloaded = await _controller(_Store(c.data));
    for (var i = 0; i < 30; i++) {
      expect(await reloaded.undoLast(), isTrue);
    }
    expect(historySnapshot(reloaded.data), historySnapshot(initial));
    expect(reloaded.data.history, hasLength(30));
  });
}
