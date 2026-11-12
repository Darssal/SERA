@TestOn('browser')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/data/offline_repository.dart';
import 'package:sera_flutter/domain/models.dart';

import 'offline_repository_test.dart' show Remote;

class _RecordedRemote extends Remote {
  final requests = <Json>[];

  @override
  Future<Json> syncOperations(Json body) {
    requests.add(jsonDecode(jsonEncode(body)) as Json);
    return super.syncOperations(body);
  }
}

int _sequence = 0;

OfflineWorkspaceRepository _repository(_RecordedRemote remote, String label) {
  final repository = OfflineWorkspaceRepository(
    remote: remote,
    accountId:
        'isolated-browser-$label-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}',
  );
  // Exercise the actual browser IndexedDB adapter, then remove only this
  // uniquely named synthetic account database after the test.
  addTearDown(repository.purge);
  return repository;
}

void main() {
  test('browser repository constructs and persists unique operation IDs with stable retry IDs', () async {
    final remote = _RecordedRemote();
    final repository = _repository(remote, 'identifiers');
    final initial = (await repository.load())!;
    remote.offline = true;
    final first = await repository.save(
      initial.copyWith(
        tasks: [const SeraTask(id: 'one', title: '浏览器本地输入')],
      ),
      expectedRevision: initial.revision,
    );
    await repository.synchronize();
    expect(repository.pendingCount, 1);
    expect((await repository.loadLocal())!.toJson(), first.toJson());
    final original = remote.requests.first;
    final id = ((original['operations'] as List).single as Map)['id'] as String;
    expect(id, matches(RegExp(r'^op-0-[0-9a-f]{32}-\d+$')));
    expect(original['batchId'], matches(RegExp(r'^batch-[0-9a-f]{32}-\d+$')));
    remote.offline = false;
    await repository.synchronize();
    expect(remote.requests.last, original);
    expect(remote.writes, 1);
    final latest = (await repository.loadLocal())!;
    await repository.save(
      latest.copyWith(
        tasks: [
          latest.tasks.single.copyWith(title: '继续修改'),
          const SeraTask(id: 'two', title: '紧接着新增'),
        ],
      ),
      expectedRevision: latest.revision,
    );
    await repository.synchronize();
    final next = remote.requests.last;
    final nextIds = (next['operations'] as List)
        .map((op) => (op as Map)['id'])
        .toSet();
    expect(nextIds, hasLength(2));
    expect(nextIds, isNot(contains(id)));
    expect(next['batchId'], isNot(original['batchId']));
    expect(repository.pendingCount, 0);
    expect(remote.workspace!.tasks.map((task) => task.title).toSet(), {
      '继续修改',
      '紧接着新增',
    });
  });

  test(
    'browser account caches and instance ID prefixes remain independent',
    () async {
      final firstRemote = _RecordedRemote(), secondRemote = _RecordedRemote();
      final first = _repository(firstRemote, 'a');
      final second = _repository(secondRemote, 'b');
      final a = (await first.load())!;
      final b = (await second.load())!;
      await first.save(
        a.copyWith(
          tasks: [const SeraTask(id: 'a', title: '账户 A')],
        ),
        expectedRevision: a.revision,
      );
      await first.synchronize();
      expect((await second.loadLocal())!.tasks, isEmpty);
      await second.save(
        b.copyWith(
          tasks: [const SeraTask(id: 'b', title: '账户 B')],
        ),
        expectedRevision: b.revision,
      );
      await second.synchronize();
      expect((await first.loadLocal())!.tasks.single.id, 'a');
      expect((await second.loadLocal())!.tasks.single.id, 'b');
      final firstBatch = firstRemote.requests.single['batchId'] as String;
      final secondBatch = secondRemote.requests.single['batchId'] as String;
      expect(firstBatch.split('-')[1], isNot(secondBatch.split('-')[1]));
    },
  );
}
