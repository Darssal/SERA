import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';

class _LocalStore
    implements
        WorkspaceRepository,
        LocalWorkspaceCache,
        SynchronizingWorkspaceRepository {
  Workspace value = const Workspace(revision: 1);
  final changes = StreamController<void>.broadcast();
  Completer<void>? networkGate;
  final syncStarted = Completer<void>();
  @override
  String get mode => 'continuity-test';
  @override
  int get pendingCount => 0;
  @override
  bool get isOffline => false;
  @override
  Json? get syncConflict => null;
  @override
  Stream<void> get localChanges => changes.stream;
  @override
  Future<Workspace?> loadLocal() async => value;
  @override
  Future<Workspace?> load() => synchronize();
  @override
  Future<void> clear() async {}
  @override
  Future<Workspace?> synchronize() async {
    if (!syncStarted.isCompleted) syncStarted.complete();
    await networkGate?.future;
    changes.add(null);
    return value;
  }

  @override
  Future<Workspace?> resolveConflict({required bool keepLocal}) async => value;
  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    if (value.revision != expectedRevision) {
      throw const RepositoryException('revision', conflict: true);
    }
    value = next.copyWith(revision: expectedRevision + 1);
    changes.add(null);
    return value;
  }
}

Future<void> _turns() async {
  for (var n = 0; n < 8; n++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'cached startup remains usable while its network refresh is pending',
    () async {
      final store = _LocalStore();
      store.value = store.value.copyWith(
        tasks: [const SeraTask(id: 'cached', title: '之前已保存')],
      );
      store.networkGate = Completer<void>();
      final c = SeraController(repository: store, seedDemo: false);
      await c.initialize().timeout(const Duration(seconds: 1));
      await store.syncStarted.future;
      expect(c.loading, isFalse);
      expect(c.busy, isFalse);
      expect(c.data.tasks.single.id, 'cached');
      await c
          .saveTask(const SeraTask(id: 'next', title: '继续记录'))
          .timeout(const Duration(seconds: 1));
      store.networkGate!.complete();
      await _turns();
      expect(c.data.tasks.length, 2);
      c.dispose();
      await store.changes.close();
    },
  );
  test(
    'background synchronization does not occupy foreground save queue',
    () async {
      final store = _LocalStore();
      final c = SeraController(repository: store, seedDemo: false);
      await c.initialize();
      store.networkGate = Completer<void>();
      final refresh = c.refresh();
      await store.syncStarted.future;
      expect(c.busy, isFalse);
      await c
          .saveTask(const SeraTask(id: 'first', title: '离线先记下来'))
          .timeout(const Duration(seconds: 1));
      await c
          .saveTask(const SeraTask(id: 'second', title: '立刻继续'))
          .timeout(const Duration(seconds: 1));
      expect(store.value.tasks.map((t) => t.id), ['first', 'second']);
      store.networkGate!.complete();
      await refresh;
      expect(c.data.tasks.map((t) => t.id), ['first', 'second']);
      c.dispose();
      await store.changes.close();
    },
  );

  test('slow platform integration is ordered and coalesced without blocking local saves', () async {
    final store = _LocalStore();
    final gate = Completer<void>();
    final calls = <List<String>>[];
    final c = SeraController(
      repository: store,
      seedDemo: false,
      onWorkspaceSaved: (w) async {
        calls.add(w.tasks.map((t) => t.title).toList());
        if (calls.length == 1) await gate.future;
      },
    );
    await c.initialize().timeout(const Duration(seconds: 1));
    await c
        .saveTask(const SeraTask(id: 'one', title: '第一版'))
        .timeout(const Duration(seconds: 1));
    await c
        .saveTask(const SeraTask(id: 'one', title: '最终版'))
        .timeout(const Duration(seconds: 1));
    expect(c.busy, isFalse);
    expect(calls, [<String>[]]);
    gate.complete();
    await _turns();
    expect(calls.last, ['最终版']);
    expect(calls.length, 2);
    expect(c.platformError, isNull);
    c.dispose();
    await store.changes.close();
  });

  test('platform failure is separate from durable task and late result is ignored on dispose', () async {
    final store = _LocalStore();
    var fail = false;
    final late = Completer<void>();
    final c = SeraController(
      repository: store,
      seedDemo: false,
      onWorkspaceSaved: (w) async {
        if (fail) throw StateError('calendar denied');
        if (w.tasks.length == 2) await late.future;
      },
    );
    await c.initialize();
    await _turns();
    fail = true;
    await c.saveTask(const SeraTask(id: 'one', title: '已保存'));
    await _turns();
    expect(store.value.tasks.single.id, 'one');
    expect(c.error, isNull);
    expect(c.platformError, contains('数据已保存'));
    fail = false;
    await c.saveTask(const SeraTask(id: 'two', title: '第二项'));
    c.dispose();
    late.complete();
    await _turns();
    await store.changes.close();
  });

  test('cache notifications read current projection rather than replaying an old snapshot', () async {
    final store = _LocalStore();
    final c = SeraController(repository: store, seedDemo: false);
    await c.initialize();
    store.value = store.value.copyWith(
      revision: 2,
      tasks: [const SeraTask(id: 'remote', title: '远端')],
    );
    store.changes.add(null);
    await _turns();
    expect(c.data.tasks.single.id, 'remote');
    expect(c.busy, isFalse);
    await c.saveTask(const SeraTask(id: 'local', title: '本机'));
    store.changes.add(null);
    store.changes.add(null);
    await _turns();
    expect(c.data.tasks.map((t) => t.id), ['remote', 'local']);
    c.dispose();
    await store.changes.close();
  });
}
