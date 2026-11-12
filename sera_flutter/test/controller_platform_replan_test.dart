import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';

class _ReplanStore implements WorkspaceRepository {
  _ReplanStore(this.value);
  Workspace value;
  Completer<void>? loadGate;
  final loadEntered = Completer<void>();
  int saves = 0;
  @override
  String get mode => 'platform-replan-test';
  @override
  Future<Workspace?> load() async {
    if (!loadEntered.isCompleted) loadEntered.complete();
    await loadGate?.future;
    return value;
  }

  @override
  Future<void> clear() async => value = const Workspace();
  @override
  Future<Workspace> save(
    Workspace workspace, {
    required int expectedRevision,
  }) async {
    if (expectedRevision != value.revision) {
      throw const RepositoryException('测试版本冲突', conflict: true);
    }
    saves++;
    return value = Workspace.fromJson(
      workspace.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }
}

DateTime _at(int hour, [int minute = 0]) => readZoned(
  '2026-11-02T${hour.toString().padLeft(2, '0')}:'
      '${minute.toString().padLeft(2, '0')}:00+08:00',
  'Asia/Hong_Kong',
)!;

Workspace _workspace({bool split = false, int dailyBudget = 90}) => Workspace(
  revision: 1,
  preferences: SeraPreferences(
    weekdays: const [1, 2, 3, 4, 5],
    startMinute: 9 * 60,
    endMinute: 18 * 60,
    restStart: 12 * 60,
    restEnd: 13 * 60,
    bufferMinutes: 10,
    dailyBudget: dailyBudget,
  ),
  tasks: [
    SeraTask(
      id: 'task',
      title: '需要重排的任务',
      estimatedMinutes: split ? 60 : 30,
      splittable: split,
      dueAt: _at(18),
    ),
  ],
  entries: [
    CalendarEntry(
      id: 'block-a',
      taskId: 'task',
      title: '需要重排的任务',
      start: _at(9),
      end: _at(9, 30),
      locked: true,
      notes: '保留原块说明',
    ),
    if (split)
      CalendarEntry(
        id: 'block-b',
        taskId: 'task',
        title: '需要重排的任务',
        start: _at(9, 40),
        end: _at(10, 10),
        locked: true,
      ),
  ],
);

SeraController _controller(
  _ReplanStore repository, {
  String accountId = 'account-a',
  Future<void> Function(Workspace)? reconcile,
  Future<Workspace> Function(Workspace, DateTime)? readBusy,
}) => SeraController(
  repository: repository,
  accountId: accountId,
  today: _at(8),
  seedDemo: false,
  onWorkspaceSaved: reconcile,
  onBeforePlanning: readBusy,
);

void main() {
  test('initialize restores platform state and refresh reconciles only changed data', () async {
    final repository = _ReplanStore(_workspace());
    final observed = <Workspace>[];
    final controller = _controller(
      repository,
      reconcile: (w) async => observed.add(w),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(observed, hasLength(1));
    expect(observed.single.entries.single.id, 'block-a');
    expect(repository.saves, 0);
    await controller.refresh();
    expect(observed, hasLength(1));
    repository.value = repository.value.copyWith(
      revision: 2,
      tasks: [repository.value.tasks.single.copyWith(done: true)],
      entries: [],
    );
    await controller.refresh();
    expect(observed, hasLength(2));
    expect(observed.last.tasks.single.done, isTrue);
    expect(observed.last.entries, isEmpty);
    await controller.refresh();
    expect(observed, hasLength(2));
    expect(repository.saves, 0);
  });

  test(
    'platform failure does not fail load and identical refresh can retry it',
    () async {
      final repository = _ReplanStore(_workspace());
      var attempts = 0;
      final controller = _controller(
        repository,
        reconcile: (_) async {
          if (++attempts == 1) {
            throw StateError('permission temporarily unavailable');
          }
        },
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.loading, isFalse);
      expect(controller.data.tasks, hasLength(1));
      expect(controller.platformError, isNotNull);
      expect(controller.error, isNull);
      await controller.refresh();
      expect(attempts, 2);
      expect(controller.platformError, isNull);
      await controller.refresh();
      expect(attempts, 2);
    },
  );

  test(
    'disposed account loading cannot invoke platform work for the next account',
    () async {
      final oldRepository = _ReplanStore(_workspace())
        ..loadGate = Completer<void>();
      final accounts = <String>[];
      final old = _controller(
        oldRepository,
        reconcile: (_) async => accounts.add('account-a'),
      );
      final oldLoad = expectLater(
        old.initialize(),
        throwsA(isA<RepositoryException>()),
      );
      await oldRepository.loadEntered.future;
      old.dispose();
      final current = _controller(
        _ReplanStore(const Workspace(revision: 1)),
        accountId: 'account-b',
        reconcile: (_) async => accounts.add('account-b'),
      );
      addTearDown(current.dispose);
      await current.initialize();
      oldRepository.loadGate!.complete();
      await oldLoad;
      expect(accounts, ['account-b']);
      expect(oldRepository.saves, 0);
      expect(current.data.tasks, isEmpty);
    },
  );

  test(
    'late platform callback failure leaves a disposed controller untouched',
    () async {
      final entered = Completer<void>();
      final completed = Completer<void>();
      final controller = _controller(
        _ReplanStore(_workspace()),
        reconcile: (_) async {
          entered.complete();
          await completed.future;
        },
      );
      final initialization = controller.initialize();
      await entered.future;
      controller.dispose();
      completed.completeError(StateError('old platform result'));
      await initialization;
      expect(controller.platformError, isNull);
    },
  );

  test('single-block candidate keeps sibling buffer, budget and locked block unchanged', () async {
    final repository = _ReplanStore(_workspace(split: true, dailyBudget: 60));
    final controller = _controller(repository);
    addTearDown(controller.dispose);
    await controller.initialize();
    final sibling = controller.entry('block-b')!.toJson();
    final suggestion = controller.findAvailableSlot('task', from: _at(9, 10))!;
    expect(suggestion.start, _at(10, 20));
    expect(suggestion.end, _at(10, 50));
    await controller.applyReplan('task', suggestion.start);
    expect(controller.entry('block-a')!.start, suggestion.start);
    expect(controller.entry('block-a')!.locked, isTrue);
    expect(controller.entry('block-a')!.notes, '保留原块说明');
    expect(controller.entry('block-b')!.toJson(), sibling);
  });

  test(
    'sibling allocation can exhaust the remaining daily replan budget',
    () async {
      final repository = _ReplanStore(_workspace(split: true, dailyBudget: 45));
      final controller = _controller(repository);
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.findAvailableSlot('task', from: _at(9, 10)), isNull);
      expect(repository.saves, 0);
    },
  );

  test(
    'replan refreshes external calendar and refuses a newly occupied candidate',
    () async {
      final repository = _ReplanStore(_workspace());
      var reads = 0;
      final controller = _controller(
        repository,
        readBusy: (w, deadline) async {
          reads++;
          expect(deadline, _at(18));
          return w.copyWith(
            externalBusyEntries: [
              CalendarEntry(
                id: 'external:new',
                title: '刚加入的外部会议',
                start: _at(9, 55),
                end: _at(10, 40),
                source: 'device-calendar',
                locked: true,
              ),
            ],
          );
        },
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await expectLater(
        controller.applyReplan('task', _at(10)),
        throwsA(
          isA<RepositoryException>().having(
            (e) => e.message,
            'message',
            contains('重叠'),
          ),
        ),
      );
      expect(reads, 1);
      expect(controller.entry('block-a')!.start, _at(9));
      expect(repository.value.entries.single.start, _at(9));
      expect(controller.data.externalBusyEntries.single.title, '刚加入的外部会议');
      expect(controller.data.history, isEmpty);
    },
  );

  test(
    'unchanged external snapshot allows candidate save in one durable write',
    () async {
      final repository = _ReplanStore(_workspace());
      var reads = 0;
      final controller = _controller(
        repository,
        readBusy: (w, _) async {
          reads++;
          return w;
        },
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.applyReplan('task', _at(10));
      expect(reads, 1);
      expect(repository.saves, 1);
      expect(controller.entry('block-a')!.start, _at(10));
      expect(controller.entry('block-a')!.locked, isTrue);
      expect(controller.data.history.single.label, '调整任务时间');
    },
  );

  test(
    'failed calendar read blocks confirmation without silently using old cache',
    () async {
      final repository = _ReplanStore(_workspace());
      final controller = _controller(
        repository,
        readBusy: (_, _) async {
          throw const RepositoryException('设备日历读取失败');
        },
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await expectLater(
        controller.applyReplan('task', _at(10)),
        throwsA(isA<RepositoryException>()),
      );
      expect(repository.saves, 0);
      expect(controller.entry('block-a')!.start, _at(9));
    },
  );

  test('sign-out during external read prevents a late replan write', () async {
    final repository = _ReplanStore(_workspace());
    final entered = Completer<void>();
    final completed = Completer<Workspace>();
    final controller = _controller(
      repository,
      readBusy: (_, _) {
        entered.complete();
        return completed.future;
      },
    );
    await controller.initialize();
    final pending = expectLater(
      controller.applyReplan('task', _at(10)),
      throwsA(isA<RepositoryException>()),
    );
    await entered.future;
    controller.dispose();
    completed.complete(repository.value);
    await pending;
    expect(repository.saves, 0);
    expect(repository.value.entries.single.start, _at(9));
  });
}
