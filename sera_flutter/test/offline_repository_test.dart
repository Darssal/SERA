import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:sera_flutter/data/offline_repository.dart';
import 'package:sera_flutter/data/repositories.dart';
import 'package:sera_flutter/domain/models.dart';

class Remote extends HttpWorkspaceRepository {
  Remote() : super(baseUrl: 'http://isolated.invalid');
  Workspace? workspace;
  bool offline = false, loseResponse = false;
  final receipts = <String>{};
  int writes = 0;
  @override
  Future<Workspace?> load() async {
    if (offline) throw const RepositoryException('offline', offline: true);
    return workspace;
  }

  @override
  Future<Workspace> save(Workspace w, {required int expectedRevision}) async =>
      workspace = w.copyWith(
        revision: expectedRevision + 1,
        entityVersions: {
          for (final key in [
            'preferences',
            'focusSession',
            'reminderStates',
            'platformSettings',
          ])
            '$key/singleton': 1,
        },
      );
  @override
  Future<Json> syncOperations(Json body) async {
    if (offline) throw const RepositoryException('offline', offline: true);
    final json = workspace!.toJson();
    final versions = Map<String, dynamic>.from(workspace!.entityVersions);
    final operations = (body['operations'] as List).cast<Json>();
    for (final op in operations) {
      if (receipts.contains(op['id'])) continue;
      final key = '${op['entityType']}/${op['entityId']}';
      if ((versions[key] ?? 0) != op['expectedVersion']) {
        throw RepositoryException(
          'conflict',
          conflict: true,
          details: {
            'conflicts': [
              {'entityType': op['entityType'], 'entityId': op['entityId']},
            ],
            'serverWorkspace': workspace!.toJson(),
          },
        );
      }
    }
    for (final op in operations) {
      if (!receipts.add(op['id'] as String)) continue;
      final type = op['entityType'] as String, id = op['entityId'] as String;
      if (json[type] is List) {
        final values = List<dynamic>.from(json[type] as List)
          ..removeWhere((e) => e['id'] == id);
        if (op['action'] == 'upsert') values.add(op['value']);
        json[type] = values;
      } else {
        json[type] = op['value'];
      }
      versions['$type/$id'] = (op['expectedVersion'] as int) + 1;
      writes++;
    }
    json['entityVersions'] = versions;
    json['revision'] = workspace!.revision + 1;
    workspace = Workspace.fromJson(json);
    if (loseResponse) {
      loseResponse = false;
      throw const RepositoryException('unknown outcome', offline: true);
    }
    return {'workspace': workspace!.toJson()};
  }
}

class RacingCreationRemote extends Remote {
  final bothReadEmpty = Completer<void>();
  int initialReads = 0, creationAttempts = 0, conflicts = 0;
  @override
  Future<Workspace?> load() async {
    if (initialReads < 2 && workspace == null) {
      initialReads++;
      if (initialReads == 2) bothReadEmpty.complete();
      await bothReadEmpty.future;
      return null;
    }
    return super.load();
  }

  @override
  Future<Workspace> save(
    Workspace value, {
    required int expectedRevision,
  }) async {
    creationAttempts++;
    if (workspace != null) {
      conflicts++;
      throw const RepositoryException(
        'already created by peer',
        conflict: true,
      );
    }
    return super.save(value, expectedRevision: expectedRevision);
  }
}

class UnderstandingRemote extends Remote {
  Json? input;
  String? requestId;
  int canceled = 0;
  @override
  Future<AiUnderstanding> understandInput({
    required Json input,
    required String requestId,
    void Function(String stage)? onStage,
  }) async {
    this.input = input;
    this.requestId = requestId;
    onStage?.call('真实远端请求');
    return const AiUnderstanding(
      intent: 'goal',
      title: '在线理解',
      summary: '模型摘要',
      outcome: '模型结果',
      model: 'isolated-worker',
    );
  }

  @override
  void cancelUnderstanding() {
    canceled++;
  }
}

void main() {
  test('cached offline mode still forwards explicit understanding and independent cancellation', () async {
    final db = await databaseFactoryMemory.openDatabase(
      'understanding-forward',
    );
    addTearDown(db.close);
    final remote = UnderstandingRemote();
    final repository = OfflineWorkspaceRepository(
      remote: remote,
      accountId: 'understanding-a',
      database: db,
    );
    await repository.load();
    remote.offline = true;
    await repository.load();
    expect(repository.isOffline, isTrue);
    final input = <String, dynamic>{
      'prompt': '原始描述',
      'referenceNow': '2026-10-31T21:00:00+08:00',
    };
    final stages = <String>[];
    final result = await repository.understandInput(
      input: input,
      requestId: 'persistent-understanding',
      onStage: stages.add,
    );
    expect(result.title, '在线理解');
    expect(result.deadline, isNull);
    expect(remote.input, input);
    expect(remote.requestId, 'persistent-understanding');
    expect(stages, ['真实远端请求']);
    repository.cancelUnderstanding();
    expect(remote.canceled, 1);
    expect(repository.pendingCount, 0);
  });

  test('closed workspace cannot dispatch understanding through a still-referenced repository', () async {
    final db = await databaseFactoryMemory.openDatabase('understanding-closed');
    final remote = UnderstandingRemote();
    final repository = OfflineWorkspaceRepository(
      remote: remote,
      accountId: 'closed-account',
      database: db,
    );
    await repository.dispose();
    expect(
      () => repository.understandInput(
        input: {'prompt': '旧账号描述'},
        requestId: 'late',
      ),
      throwsA(isA<RepositoryException>()),
    );
    expect(remote.input, isNull);
  });

  test('understanding sessions and clarification inputs stay in their account cache', () async {
    final firstDb = await databaseFactoryMemory.openDatabase(
      'understanding-account-a',
    );
    final secondDb = await databaseFactoryMemory.openDatabase(
      'understanding-account-b',
    );
    addTearDown(firstDb.close);
    addTearDown(secondDb.close);
    final remoteA = Remote(), remoteB = Remote();
    final first = OfflineWorkspaceRepository(
      remote: remoteA,
      accountId: 'A',
      database: firstDb,
    );
    final second = OfflineWorkspaceRepository(
      remote: remoteB,
      accountId: 'B',
      database: secondDb,
    );
    final a = (await first.load())!;
    await second.load();
    remoteA.offline = true;
    await first.save(
      a.copyWith(
        planningSessions: [
          PlanningSession(
            id: 'a-understanding',
            updatedAt: DateTime.utc(2026, 10, 31),
            prompt: '账号A原始描述',
            stage: 'understanding',
            understandingRequestId: 'same-local-request-id',
            understandingInput: const {
              'prompt': '账号A原始描述',
              'referenceNow': '2026-10-31T21:00:00+08:00',
            },
            clarificationAnswers: const {'deadline': '还不确定'},
          ),
        ],
      ),
      expectedRevision: a.revision,
    );
    await first.synchronize();
    expect((await second.load())!.planningSessions, isEmpty);
    final reopened = OfflineWorkspaceRepository(
      remote: remoteA,
      accountId: 'A',
      database: firstDb,
    );
    final session = (await reopened.load())!.planningSessions.single;
    expect(session.prompt, '账号A原始描述');
    expect(session.deadline, isNull);
    expect(session.understandingRequestId, 'same-local-request-id');
    expect(session.clarificationAnswers, {'deadline': '还不确定'});
    expect(remoteB.workspace!.planningSessions, isEmpty);
  });

  test('two new-account readers recover an initialization conflict without another empty write', () async {
    final firstDb = await databaseFactoryMemory.openDatabase('first-create-a');
    final secondDb = await databaseFactoryMemory.openDatabase('first-create-b');
    addTearDown(firstDb.close);
    addTearDown(secondDb.close);
    final remote = RacingCreationRemote();
    final first = OfflineWorkspaceRepository(
      remote: remote,
      accountId: 'same-new-account',
      database: firstDb,
    );
    final second = OfflineWorkspaceRepository(
      remote: remote,
      accountId: 'same-new-account',
      database: secondDb,
    );
    final values = await Future.wait([first.load(), second.load()]);
    expect(remote.creationAttempts, 2);
    expect(remote.conflicts, 1);
    expect(values.every((value) => value != null), isTrue);
    expect(
      jsonEncode(values.first!.toJson()),
      jsonEncode(values.last!.toJson()),
    );
    expect(values.first!.revision, 1);
    expect(first.syncConflict, isNull);
    expect(second.syncConflict, isNull);
    expect(first.pendingCount + second.pendingCount, 0);
  });
  test('offline edits survive reopen and unknown server outcome retries same operation', () async {
    final db = await databaseFactoryMemory.openDatabase(
      'offline-${DateTime.now().microsecondsSinceEpoch}',
    );
    addTearDown(db.close);
    final remote = Remote();
    final repo = OfflineWorkspaceRepository(
      remote: remote,
      accountId: 'A',
      database: db,
    );
    final initial = (await repo.load())!;
    remote.offline = true;
    final changed = await repo.save(
      initial.copyWith(
        tasks: [const SeraTask(id: 't', title: '离线任务')],
      ),
      expectedRevision: initial.revision,
    );
    await repo.synchronize();
    expect(changed.tasks.single.title, '离线任务');
    expect(repo.pendingCount, 1);
    final reopened = OfflineWorkspaceRepository(
      remote: remote,
      accountId: 'A',
      database: db,
    );
    expect((await reopened.load())!.tasks.single.id, 't');
    remote.offline = false;
    remote.loseResponse = true;
    await reopened.synchronize();
    expect(remote.writes, 1);
    expect(reopened.pendingCount, 1);
    await reopened.synchronize();
    expect(remote.writes, 1);
    expect(reopened.pendingCount, 0);
    expect(remote.workspace!.tasks, hasLength(1));
  });
  test('conflict keeps both inputs and explicit local resolution preserves unrelated remote objects', () async {
    final db = await databaseFactoryMemory.openDatabase(
      'conflict-${DateTime.now().microsecondsSinceEpoch}',
    );
    addTearDown(db.close);
    final remote = Remote();
    final repo = OfflineWorkspaceRepository(
      remote: remote,
      accountId: 'A',
      database: db,
    );
    var state = (await repo.load())!;
    state = await repo.save(
      state.copyWith(
        tasks: [const SeraTask(id: 't', title: '初始')],
      ),
      expectedRevision: state.revision,
    );
    await repo.synchronize();
    remote.offline = true;
    state = await repo.save(
      state.copyWith(tasks: [state.tasks.single.copyWith(title: '本机修改')]),
      expectedRevision: state.revision,
    );
    await repo.synchronize();
    remote.workspace = remote.workspace!.copyWith(
      tasks: [
        const SeraTask(id: 't', title: '远端修改', revision: 2),
        const SeraTask(id: 'other', title: '远端新增'),
      ],
      entityVersions: {
        ...remote.workspace!.entityVersions,
        'tasks/t': 2,
        'tasks/other': 1,
      },
    );
    remote.offline = false;
    await repo.synchronize();
    expect(repo.syncConflict, isNotNull);
    expect((await repo.load())!.tasks.single.title, '本机修改');
    final resolved = (await repo.resolveConflict(keepLocal: true))!;
    expect(resolved.tasks.map((e) => e.title).toSet(), {'本机修改', '远端新增'});
    expect(repo.syncConflict, isNull);
  });
  test(
    'local CAS prevents stale writer from replacing queued changes',
    () async {
      final db = await databaseFactoryMemory.openDatabase(
        'stale-${DateTime.now().microsecondsSinceEpoch}',
      );
      addTearDown(db.close);
      final remote = Remote();
      final repo = OfflineWorkspaceRepository(
        remote: remote,
        accountId: 'A',
        database: db,
      );
      final initial = (await repo.load())!;
      remote.offline = true;
      await repo.save(
        initial.copyWith(
          tasks: [const SeraTask(id: 'a', title: 'A')],
        ),
        expectedRevision: initial.revision,
      );
      await repo.synchronize();
      await expectLater(
        repo.save(
          initial.copyWith(
            tasks: [const SeraTask(id: 'b', title: 'B')],
          ),
          expectedRevision: initial.revision,
        ),
        throwsA(
          isA<RepositoryException>().having(
            (e) => e.conflict,
            'conflict',
            true,
          ),
        ),
      );
      expect(
        jsonEncode((await repo.load())!.toJson()),
        contains('"title":"A"'),
      );
    },
  );
}
