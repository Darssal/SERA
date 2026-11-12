import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:sera_flutter/data/offline_repository.dart';
import 'package:sera_flutter/data/repositories.dart';
import 'package:sera_flutter/domain/models.dart';

import 'offline_repository_test.dart' show Remote;

// Gates suspend a real repository operation until the test deliberately releases
// it. The one-second timeout detects coupling/deadlock, not a performance claim.
class _HeldRemote extends Remote {
  Completer<void>? readGate;
  Completer<void>? readStarted;
  final syncGates = <Completer<void>>[];
  final syncStarted = <Completer<void>>[];
  final requests = <Json>[];
  RepositoryException? rejection;
  bool addPeerTask = false;

  @override
  Future<Workspace?> load() async {
    final snapshot = await super.load();
    readStarted?.complete();
    await readGate?.future;
    return snapshot;
  }

  @override
  Future<Json> syncOperations(Json body) async {
    final index = requests.length;
    requests.add(jsonDecode(jsonEncode(body)) as Json);
    if (index < syncStarted.length) syncStarted[index].complete();
    if (rejection != null) throw rejection!;
    if (addPeerTask) {
      addPeerTask = false;
      workspace = workspace!.copyWith(
        tasks: [
          ...workspace!.tasks,
          const SeraTask(id: 'peer', title: '另一台设备'),
        ],
        entityVersions: {...workspace!.entityVersions, 'tasks/peer': 1},
      );
    }
    final response = await super.syncOperations(body);
    if (index < syncGates.length) await syncGates[index].future;
    return response;
  }
}

Future<(OfflineWorkspaceRepository, Database, _HeldRemote)> _fixture(
  String name,
) async {
  final db = await databaseFactoryMemory.openDatabase(name);
  final remote = _HeldRemote();
  final repository = OfflineWorkspaceRepository(
    remote: remote,
    accountId: name,
    database: db,
  );
  addTearDown(repository.dispose);
  await repository.load();
  return (repository, db, remote);
}

void main() {
  test(
    'a stale GET cannot replace edits already synced by another tab',
    () async {
      final (first, db, remote) = await _fixture('peer-get-race');
      final second = OfflineWorkspaceRepository(
        remote: remote,
        accountId: 'peer-get-race',
        database: db,
      );
      addTearDown(second.dispose);
      remote.readGate = Completer<void>();
      remote.readStarted = Completer<void>();
      final refresh = first.load();
      await remote.readStarted!.future;
      final original = (await second.loadLocal())!;
      await second.save(
        original.copyWith(
          tasks: [const SeraTask(id: 'peer', title: '另一个标签页的新输入')],
        ),
        expectedRevision: original.revision,
      );
      await second.synchronize();
      expect(second.pendingCount, 0);
      remote.readGate!.complete();
      expect((await refresh)!.tasks.single.title, '另一个标签页的新输入');
      expect((await first.loadLocal())!.tasks.single.title, '另一个标签页的新输入');
    },
  );

  test('conflict resolution rejects a stale choice when the local journal changed during its GET', () async {
    final (repository, _, remote) = await _fixture('resolve-write-race');
    final initial = (await repository.loadLocal())!;
    remote.offline = true;
    final local = await repository.save(
      initial.copyWith(
        tasks: [const SeraTask(id: 't', title: '本机原输入')],
      ),
      expectedRevision: initial.revision,
    );
    await repository.synchronize();
    remote.offline = false;
    remote.workspace = remote.workspace!.copyWith(
      tasks: [const SeraTask(id: 't', title: '云端输入')],
      entityVersions: {...remote.workspace!.entityVersions, 'tasks/t': 1},
    );
    await repository.synchronize();
    expect(repository.syncConflict, isNotNull);
    remote.readGate = Completer<void>();
    remote.readStarted = Completer<void>();
    final resolution = repository.resolveConflict(keepLocal: false);
    final rejected = expectLater(
      resolution,
      throwsA(
        isA<RepositoryException>().having(
          (error) => error.message,
          'retry choice',
          contains('请重新选择'),
        ),
      ),
    );
    await remote.readStarted!.future;
    final next = await repository
        .save(
          local.copyWith(
            tasks: [local.tasks.single.copyWith(title: '处理期间的新输入')],
          ),
          expectedRevision: local.revision,
        )
        .timeout(const Duration(seconds: 1));
    remote.readGate!.complete();
    await rejected;
    await repository.synchronize();
    expect((await repository.loadLocal())!.toJson(), next.toJson());
    expect(repository.syncConflict, isNotNull);
  });

  test('local edits finish while an earlier acknowledgement is held and both reach the cloud', () async {
    final (repository, db, remote) = await _fixture('held-ack');
    final gate = Completer<void>();
    final started = Completer<void>();
    remote.syncGates.add(gate);
    remote.syncStarted.add(started);
    final initial = (await repository.loadLocal())!;
    final first = await repository
        .save(
          initial.copyWith(
            tasks: [const SeraTask(id: 't', title: '第一版')],
          ),
          expectedRevision: initial.revision,
        )
        .timeout(const Duration(seconds: 1));
    await started.future;
    final second = await repository
        .save(
          first.copyWith(
            tasks: [
              first.tasks.single.copyWith(title: '第二版'),
              const SeraTask(id: 'next', title: '下一件事'),
            ],
          ),
          expectedRevision: first.revision,
        )
        .timeout(const Duration(seconds: 1));
    final state = (await stringMapStoreFactory
        .store('workspace')
        .record('state')
        .get(db))!;
    final persisted = Workspace.fromJson(
      Map<String, dynamic>.from(state['local'] as Map),
    );
    expect(persisted.toJson(), second.toJson());
    expect((state['batches'] as List), hasLength(2));
    expect(repository.pendingCount, 3);
    expect(remote.requests, hasLength(1));
    final flush = repository.synchronize();
    expect(identical(flush, repository.synchronize()), isTrue);
    gate.complete();
    await flush;
    final latest = (await repository.loadLocal())!;
    expect(
      {for (final task in latest.tasks) task.id: task.title},
      {'t': '第二版', 'next': '下一件事'},
    );
    expect(latest.revision, second.revision);
    expect(remote.workspace!.tasks.map((task) => task.title).toSet(), {
      '第二版',
      '下一件事',
    });
    expect(remote.writes, 3);
    expect(repository.pendingCount, 0);
  });

  test('an in-flight refresh does not block a local save or replace it with the old GET', () async {
    final (repository, _, remote) = await _fixture('held-get');
    final initial = (await repository.loadLocal())!;
    remote.readGate = Completer<void>();
    remote.readStarted = Completer<void>();
    final refresh = repository.load();
    await remote.readStarted!.future;
    final saved = await repository
        .save(
          initial.copyWith(
            tasks: [const SeraTask(id: 'new', title: '读取期间的输入')],
          ),
          expectedRevision: initial.revision,
        )
        .timeout(const Duration(seconds: 1));
    expect((await repository.loadLocal())!.toJson(), saved.toJson());
    remote.readGate!.complete();
    expect((await refresh)!.tasks.single.title, '读取期间的输入');
    await repository.synchronize();
    expect(remote.workspace!.tasks.single.title, '读取期间的输入');
  });

  test('new remote content advances local CAS so an older UI cannot delete unseen peer edits', () async {
    final (repository, _, remote) = await _fixture('peer-cas');
    final initial = (await repository.loadLocal())!;
    remote.addPeerTask = true;
    final saved = await repository.save(
      initial.copyWith(
        tasks: [const SeraTask(id: 'mine', title: '本机输入')],
      ),
      expectedRevision: initial.revision,
    );
    await repository.synchronize();
    final merged = (await repository.loadLocal())!;
    expect(merged.tasks.map((task) => task.id).toSet(), {'mine', 'peer'});
    expect(merged.revision, greaterThan(saved.revision));
    await expectLater(
      repository.save(
        saved.copyWith(tasks: []),
        expectedRevision: saved.revision,
      ),
      throwsA(
        isA<RepositoryException>().having(
          (error) => error.conflict,
          'CAS conflict',
          isTrue,
        ),
      ),
    );
    expect((await repository.loadLocal())!.toJson(), merged.toJson());
  });

  test('unknown outcome retries the same durable operation rather than creating a second task', () async {
    final (repository, _, remote) = await _fixture('unknown-ack');
    final initial = (await repository.loadLocal())!;
    remote.loseResponse = true;
    await repository.save(
      initial.copyWith(
        tasks: [const SeraTask(id: 'one', title: '只保存一次')],
      ),
      expectedRevision: initial.revision,
    );
    await repository.synchronize();
    expect(repository.pendingCount, 1);
    expect(remote.writes, 1);
    await repository.synchronize();
    expect(remote.requests, hasLength(2));
    expect(remote.requests.first, remote.requests.last);
    expect(remote.writes, 1);
    expect(repository.pendingCount, 0);
  });

  test('background rejection keeps durable input and a visible error until explicit retry succeeds', () async {
    final (repository, db, remote) = await _fixture('visible-rejection');
    final notifications = <int>[];
    final listener = repository.localChanges.listen(
      (_) => notifications.add(repository.pendingCount),
    );
    addTearDown(listener.cancel);
    final initial = (await repository.loadLocal())!;
    remote.rejection = const RepositoryException('服务暂不可用');
    final saved = await repository.save(
      initial.copyWith(
        tasks: [const SeraTask(id: 'saved', title: '输入仍保留')],
      ),
      expectedRevision: initial.revision,
    );
    await expectLater(
      repository.synchronize(),
      throwsA(isA<RepositoryException>()),
    );
    expect((await repository.loadLocal())!.toJson(), saved.toJson());
    expect(repository.mode, contains('服务暂不可用'));
    final state = (await stringMapStoreFactory
        .store('workspace')
        .record('state')
        .get(db))!;
    expect(state['syncError'], '服务暂不可用');
    expect(repository.pendingCount, 1);
    expect(notifications, isNotEmpty);
    remote.rejection = null;
    await repository.synchronize();
    expect(repository.pendingCount, 0);
    expect(repository.mode, '云端同步');
    expect(remote.requests.first, remote.requests.last);
  });

  test('a late response after disposal cannot update a different account or touch its cache', () async {
    final (first, _, remote) = await _fixture('disposed-a');
    final (second, _, _) = await _fixture('active-b');
    final gate = Completer<void>();
    final started = Completer<void>();
    remote.syncGates.add(gate);
    remote.syncStarted.add(started);
    final initial = (await first.loadLocal())!;
    await first.save(
      initial.copyWith(
        tasks: [const SeraTask(id: 'private-a', title: '账户 A 输入')],
      ),
      expectedRevision: initial.revision,
    );
    await started.future;
    final pending = first.synchronize();
    final failed = expectLater(pending, throwsA(isA<RepositoryException>()));
    await first.dispose().timeout(const Duration(seconds: 1));
    final b = (await second.loadLocal())!;
    await second.save(
      b.copyWith(
        tasks: [const SeraTask(id: 'b', title: '账户 B 输入')],
      ),
      expectedRevision: b.revision,
    );
    gate.complete();
    await failed;
    await second.synchronize();
    expect((await second.loadLocal())!.tasks.single.id, 'b');
  });

  test(
    'an already-acknowledged peer batch cannot roll back a later local edit',
    () async {
      final (first, db, remote) = await _fixture('peer-ack-race');
      final second = OfflineWorkspaceRepository(
        remote: remote,
        accountId: 'peer-ack-race',
        database: db,
      );
      addTearDown(second.dispose);
      final gate = Completer<void>();
      final started = Completer<void>();
      remote.syncGates.add(gate);
      remote.syncStarted.add(started);
      final initial = (await first.loadLocal())!;
      await first.save(
        initial.copyWith(
          tasks: [const SeraTask(id: 't', title: '原始标题')],
        ),
        expectedRevision: initial.revision,
      );
      await started.future;
      await second.synchronize();
      final acknowledged = (await second.loadLocal())!;
      await second.save(
        acknowledged.copyWith(
          tasks: [acknowledged.tasks.single.copyWith(title: '后续修改')],
        ),
        expectedRevision: acknowledged.revision,
      );
      await second.synchronize();
      gate.complete();
      await first.synchronize();
      expect((await first.loadLocal())!.tasks.single.title, '后续修改');
      expect(remote.workspace!.tasks.single.title, '后续修改');
      expect(remote.writes, 2);
      expect(first.pendingCount, 0);
    },
  );
}
