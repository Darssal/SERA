import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/offline_repository.dart';
import 'package:sera_flutter/domain/change_history.dart';
import 'package:sera_flutter/domain/models.dart';

import 'offline_repository_test.dart' show Remote;

final _day = DateTime(2026, 11, 2, 9);
final _state = stringMapStoreFactory.store('workspace').record('state');

class _TracingRemote extends Remote {
  final bodies = <String>[];
  @override
  Future<Json> syncOperations(Json body) {
    bodies.add(jsonEncode(body));
    return super.syncOperations(body);
  }
}

Future<void> _saveLegacy(OfflineWorkspaceRepository repository) async {
  final before = (await repository.loadLocal())!;
  final after = before.copyWith(
    tasks: const [SeraTask(id: 'legacy-task', title: '旧客户端离线创建')],
  );
  final record = ChangeRecord(
    id: 'legacy-change',
    label: '保存任务',
    at: _day,
    before: historySnapshot(before),
    after: historySnapshot(after),
  );
  await repository.save(
    after.copyWith(history: [record]),
    expectedRevision: before.revision,
  );
  await repository.synchronize();
}

void main() {
  test('legacy pending payload is unchanged through compaction and lost-response replay', () async {
    final db = await databaseFactoryMemory.openDatabase(
      'history-pending-replay',
    );
    final remote = _TracingRemote();
    final repository = OfflineWorkspaceRepository(
      remote: remote,
      accountId: 'history-pending',
      database: db,
    );
    addTearDown(repository.dispose);
    await repository.load();
    remote.offline = true;
    await _saveLegacy(repository);
    final originalState = (await _state.get(db))!;
    final originalBatch = jsonEncode((originalState['batches'] as List).single);
    final originalOps =
        ((originalState['batches'] as List).single as Map)['operations']
            as List;
    final originalIds = originalOps.map((op) => op['id']).toSet();

    final controller = SeraController(
      repository: repository,
      seedDemo: false,
      today: _day,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.saveTask(
      const SeraTask(id: 'new-task', title: '新客户端继续创建'),
    );
    await repository.synchronize();
    final migratedState = (await _state.get(db))!;
    final pending = migratedState['batches'] as List;
    expect(pending, hasLength(2));
    expect(jsonEncode(pending.first), originalBatch);
    expect(controller.data.history.first.id, 'legacy-change');
    expect(controller.data.history.first.isDelta, isTrue);
    expect(controller.data.history.first.undone, isFalse);

    remote.offline = false;
    remote.loseResponse = true;
    await repository.synchronize();
    expect(originalIds.every(remote.receipts.contains), isTrue);
    await repository.synchronize();
    expect(repository.pendingCount, 0);
    expect(
      remote.bodies.where((body) => body == originalBatch).length,
      greaterThanOrEqualTo(2),
    );
    expect(
      remote.workspace!.history
          .firstWhere((r) => r.id == 'legacy-change')
          .isDelta,
      isTrue,
    );
    expect(remote.workspace!.tasks.map((t) => t.id).toSet(), {
      'legacy-task',
      'new-task',
    });

    await controller.refresh();
    expect(await controller.undoLast(), isTrue);
    await repository.synchronize();
    await controller.refresh();
    expect(await controller.undoLast(), isTrue);
    await repository.synchronize();
    expect(remote.workspace!.tasks, isEmpty);
    expect(remote.workspace!.history, hasLength(2));
    expect(
      remote.workspace!.history.every((r) => r.undone && r.isDelta),
      isTrue,
    );
  });

  test('compacting an already synced history record still respects its object version', () async {
    final db = await databaseFactoryMemory.openDatabase(
      'history-migration-conflict',
    );
    final remote = _TracingRemote();
    final repository = OfflineWorkspaceRepository(
      remote: remote,
      accountId: 'history-conflict',
      database: db,
    );
    addTearDown(repository.dispose);
    await repository.load();
    await _saveLegacy(repository);
    expect(remote.workspace!.history.single.format, isNull);
    remote.offline = true;
    final controller = SeraController(
      repository: repository,
      seedDemo: false,
      today: _day,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.saveTask(const SeraTask(id: 'pending', title: '仍在本机的新任务'));
    await repository.synchronize();
    final server = remote.workspace!;
    remote.workspace = server.copyWith(
      revision: server.revision + 1,
      history: [server.history.single.copyWith(undone: true)],
      entityVersions: {
        ...server.entityVersions,
        'history/legacy-change':
            (server.entityVersions['history/legacy-change'] as int) + 1,
      },
    );
    remote.offline = false;
    await repository.synchronize();
    expect(repository.syncConflict, isNotNull);
    expect(remote.workspace!.history.single.undone, isTrue);
    expect(remote.workspace!.history.single.format, isNull);
    expect(remote.workspace!.tasks.any((t) => t.id == 'pending'), isFalse);
    final local = (await repository.loadLocal())!;
    expect(local.tasks.any((t) => t.id == 'pending'), isTrue);
    expect(
      local.history.firstWhere((r) => r.id == 'legacy-change').isDelta,
      isTrue,
    );
  });
}
