import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:sera_flutter/data/offline_repository.dart';
import 'package:sera_flutter/data/repositories.dart';
import 'package:sera_flutter/domain/models.dart';

final _now = DateTime.utc(2026, 10, 31);
final _source = PlanningSession(
  id: 'shared-input',
  updatedAt: _now,
  prompt: '原始输入',
  notes: '原始补充',
  stage: 'understood',
);

PlanningResultRef _result(String kind) => PlanningResultRef(
  kind: kind,
  id: 'planning-$kind-${sha256.convert(utf8.encode(_source.id))}',
);

Workspace _complete(Workspace value, String kind) {
  final result = _result(kind);
  return value.copyWith(
    planningSessions: [
      value.planningSessions.single.copyWith(
        stage: 'confirmed',
        resultEntity: result,
      ),
    ],
    tasks: kind == 'task'
        ? [SeraTask(id: result.id, title: '已确认任务')]
        : value.tasks,
    entries: kind == 'event'
        ? [
            CalendarEntry(
              id: result.id,
              title: '已确认日程',
              start: _now.add(const Duration(days: 1, hours: 7)),
              end: _now.add(const Duration(days: 1, hours: 7, minutes: 30)),
            ),
          ]
        : value.entries,
  );
}

/// In-memory transport with atomic object versions and the server's immutable
/// result rule. Both clients use the real offline queue and Sembast transaction.
class _Remote extends HttpWorkspaceRepository {
  _Remote(Workspace value)
    : workspace = value.copyWith(
        entityVersions: {
          ...value.entityVersions,
          for (final name in [
            'preferences',
            'focusSession',
            'reminderStates',
            'platformSettings',
          ])
            '$name/singleton': value.entityVersions['$name/singleton'] ?? 1,
        },
      ),
      super(baseUrl: 'http://isolated.invalid');
  Workspace workspace;
  bool offline = false;
  int syncCalls = 0, commits = 0;
  final receipts = <String>{};

  @override
  Future<Workspace?> load() async {
    if (offline) throw const RepositoryException('offline', offline: true);
    return Workspace.fromJson(workspace.toJson());
  }

  @override
  Future<Json> syncOperations(Json body) async {
    syncCalls++;
    if (offline) throw const RepositoryException('offline', offline: true);
    final operations = (body['operations'] as List).cast<Json>();
    final versions = Map<String, dynamic>.from(workspace.entityVersions);
    for (final op in operations) {
      if (receipts.contains(op['id'])) continue;
      final key = '${op['entityType']}/${op['entityId']}';
      if ((versions[key] ?? 0) != op['expectedVersion']) {
        throw RepositoryException(
          'object version conflict',
          conflict: true,
          details: {
            'conflicts': [
              {'entityType': op['entityType'], 'entityId': op['entityId']},
            ],
            'serverWorkspace': workspace.toJson(),
          },
        );
      }
    }
    final json = workspace.toJson();
    final applied = <String>[];
    for (final op in operations) {
      if (receipts.contains(op['id'])) continue;
      final type = op['entityType'] as String;
      final id = op['entityId'] as String;
      if (json[type] is List) {
        final values = List<dynamic>.from(json[type] as List)
          ..removeWhere((value) => value['id'] == id);
        if (op['action'] == 'upsert') values.add(op['value']);
        json[type] = values;
      } else {
        json[type] = op['value'];
      }
      versions['$type/$id'] = (op['expectedVersion'] as int) + 1;
      applied.add(op['id'] as String);
    }
    json['entityVersions'] = versions;
    json['revision'] = workspace.revision + 1;
    final candidate = Workspace.fromJson(json);
    final previous = {
      for (final session in workspace.planningSessions) session.id: session,
    };
    for (final session in candidate.planningSessions) {
      final old = previous[session.id]?.resultEntity;
      if (old != null &&
          (session.stage != 'confirmed' ||
              session.resultEntity?.kind != old.kind ||
              session.resultEntity?.id != old.id)) {
        throw const RepositoryException('server rejected result downgrade');
      }
    }
    workspace = candidate;
    receipts.addAll(applied);
    commits++;
    return {'workspace': workspace.toJson()};
  }
}

class _Fixture {
  _Fixture(this.first, this.second, this.remote, this.firstDb);
  final OfflineWorkspaceRepository first, second;
  final _Remote remote;
  final Database firstDb;

  Future<Json> state() async => (await stringMapStoreFactory
      .store('workspace')
      .record('state')
      .get(firstDb))!;
}

Future<_Fixture> _fixture(String name, {Workspace? initial}) async {
  final firstDb = await databaseFactoryMemory.openDatabase('$name-a');
  final secondDb = await databaseFactoryMemory.openDatabase('$name-b');
  final remote = _Remote(
    initial ??
        Workspace(
          revision: 1,
          planningSessions: [_source],
          entityVersions: {'planningSessions/${_source.id}': 1},
        ),
  );
  final first = OfflineWorkspaceRepository(
    remote: remote,
    accountId: 'same-account',
    database: firstDb,
  );
  final second = OfflineWorkspaceRepository(
    remote: remote,
    accountId: 'same-account',
    database: secondDb,
  );
  addTearDown(() async {
    await first.dispose();
    await second.dispose();
  });
  return _Fixture(first, second, remote, firstDb);
}

Future<void> _expectKeepLocalRejected(_Fixture f) async {
  await f.first.synchronize();
  expect(f.first.syncConflict, isNotNull);
  final saved = jsonEncode(await f.state());
  final conflict = jsonEncode(f.first.syncConflict);
  final pending = f.first.pendingCount;
  final calls = f.remote.syncCalls;
  await expectLater(
    f.first.resolveConflict(keepLocal: true),
    throwsA(
      isA<RepositoryException>()
          .having((error) => error.conflict, 'conflict', isTrue)
          .having(
            (error) => error.message,
            'recovery instruction',
            contains('请采用云端内容，本机修改仍保留'),
          ),
    ),
  );
  // Rejection must happen before new operation IDs, cache or conflict writes.
  expect(jsonEncode(await f.state()), saved);
  expect(jsonEncode(f.first.syncConflict), conflict);
  expect(f.first.pendingCount, pending);
  expect(f.remote.syncCalls, calls);
}

void main() {
  for (final kind in ['task', 'event']) {
    test(
      'pending input cannot overwrite a peer-confirmed $kind and cloud recovery stays available',
      () async {
        final f = await _fixture('pending-$kind');
        final a = (await f.first.load())!;
        final b = (await f.second.load())!;
        f.remote.offline = true;
        await f.first.save(
          a.copyWith(planningSessions: [_source.copyWith(notes: '本机尚未确认的文字')]),
          expectedRevision: a.revision,
        );
        await f.first.synchronize();
        f.remote.offline = false;
        final cloud = await f.second.save(
          _complete(b, kind),
          expectedRevision: b.revision,
        );
        await f.second.synchronize();
        await _expectKeepLocalRejected(f);
        final state = await f.state();
        final local = Workspace.fromJson(
          Map<String, dynamic>.from(state['local'] as Map),
        );
        expect(local.planningSessions.single.notes, '本机尚未确认的文字');
        expect(local.planningSessions.single.resultEntity, isNull);
        expect((state['batches'] as List), hasLength(1));
        final recovered = (await f.first.resolveConflict(keepLocal: false))!;
        expect(
          recovered.copyWith(revision: cloud.revision).toJson(),
          cloud.toJson(),
        );
        expect(recovered.planningSessions.single.stage, 'confirmed');
        expect(
          recovered.planningSessions.single.resultEntity!.toJson(),
          _result(kind).toJson(),
        );
        expect(recovered.tasks.length + recovered.entries.length, 1);
        expect(f.first.pendingCount, 0);
        expect(f.first.syncConflict, isNull);
        expect(f.remote.workspace.toJson(), cloud.toJson());
        expect(f.remote.commits, 1);
      },
    );
  }

  test('competing task and event confirmations retain the rejected local result until cloud is chosen', () async {
    final f = await _fixture('competing-kinds');
    final a = (await f.first.load())!;
    final b = (await f.second.load())!;
    f.remote.offline = true;
    await f.first.save(_complete(a, 'task'), expectedRevision: a.revision);
    await f.first.synchronize();
    f.remote.offline = false;
    final cloud = await f.second.save(
      _complete(b, 'event'),
      expectedRevision: b.revision,
    );
    await f.second.synchronize();
    await _expectKeepLocalRejected(f);
    final state = await f.state();
    final local = Workspace.fromJson(
      Map<String, dynamic>.from(state['local'] as Map),
    );
    expect(local.tasks.single.id, _result('task').id);
    expect(local.planningSessions.single.resultEntity!.kind, 'task');
    expect(f.remote.workspace.tasks, isEmpty);
    final recovered = (await f.first.resolveConflict(keepLocal: false))!;
    expect(
      recovered.copyWith(revision: cloud.revision).toJson(),
      cloud.toJson(),
    );
    expect(recovered.tasks, isEmpty);
    expect(recovered.entries.single.id, _result('event').id);
    expect(f.first.pendingCount, 0);
    expect(f.first.syncConflict, isNull);
    expect(f.remote.commits, 1);
  });

  test('matching confirmed reference may retain local session metadata without duplicating its result', () async {
    final initial = _complete(
      Workspace(
        revision: 1,
        planningSessions: [_source],
        entityVersions: {
          'planningSessions/${_source.id}': 1,
          'tasks/${_result('task').id}': 1,
        },
      ),
      'task',
    );
    final f = await _fixture('matching-result', initial: initial);
    final a = (await f.first.load())!;
    final b = (await f.second.load())!;
    f.remote.offline = true;
    await f.first.save(
      a.copyWith(
        planningSessions: [a.planningSessions.single.copyWith(notes: '本机补充')],
      ),
      expectedRevision: a.revision,
    );
    await f.first.synchronize();
    f.remote.offline = false;
    await f.second.save(
      b.copyWith(
        planningSessions: [b.planningSessions.single.copyWith(notes: '云端补充')],
      ),
      expectedRevision: b.revision,
    );
    await f.second.synchronize();
    await f.first.synchronize();
    expect(f.first.syncConflict, isNotNull);
    final resolved = (await f.first.resolveConflict(keepLocal: true))!;
    expect(resolved.planningSessions.single.notes, '本机补充');
    expect(
      resolved.planningSessions.single.resultEntity!.toJson(),
      _result('task').toJson(),
    );
    expect(resolved.tasks.single.id, _result('task').id);
    expect(f.first.syncConflict, isNull);
    expect(f.first.pendingCount, 0);
  });

  test('ordinary task conflict keeps explicit local choice and unrelated remote tasks', () async {
    final initial = Workspace(
      revision: 1,
      tasks: [const SeraTask(id: 'edited', title: '原任务')],
      entityVersions: {'tasks/edited': 1},
    );
    final f = await _fixture('ordinary-task', initial: initial);
    final a = (await f.first.load())!;
    final b = (await f.second.load())!;
    f.remote.offline = true;
    await f.first.save(
      a.copyWith(tasks: [a.tasks.single.copyWith(title: '本机修改')]),
      expectedRevision: a.revision,
    );
    await f.first.synchronize();
    f.remote.offline = false;
    await f.second.save(
      b.copyWith(
        tasks: [
          b.tasks.single.copyWith(title: '云端修改'),
          const SeraTask(id: 'unrelated', title: '云端新增'),
        ],
      ),
      expectedRevision: b.revision,
    );
    await f.second.synchronize();
    await f.first.synchronize();
    expect(f.first.syncConflict, isNotNull);
    final resolved = (await f.first.resolveConflict(keepLocal: true))!;
    expect(
      {for (final task in resolved.tasks) task.id: task.title},
      {'edited': '本机修改', 'unrelated': '云端新增'},
    );
    expect(f.first.pendingCount, 0);
    expect(f.first.syncConflict, isNull);
    expect(f.remote.commits, 2);
  });
}
