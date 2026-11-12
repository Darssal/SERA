import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:sera_flutter/application/device_cloud_sync.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/data/device_workspace_repository.dart';
import 'package:sera_flutter/data/offline_repository.dart';
import 'package:sera_flutter/data/repositories.dart';
import 'package:sera_flutter/domain/models.dart';

class _MemoryDevice extends DeviceWorkspaceRepository {
  _MemoryDevice(this.value)
    : super(apiBaseUrl: 'http://isolated.invalid', migrateLegacy: false);
  Workspace? value;
  final receipts = <String, Json>{};
  int receiptWrites = 0;
  Completer<void>? readGate;
  @override
  Future<Workspace?> load() async {
    await readGate?.future;
    return value;
  }

  @override
  Future<Json?> cloudReceipt(String accountId) async => receipts[accountId];
  @override
  Future<void> saveCloudReceipt(String accountId, Json receipt) async {
    receiptWrites++;
    receipts[accountId] = receipt;
  }
}

class _CloudStore
    implements
        WorkspaceRepository,
        LocalWorkspaceCache,
        SynchronizingWorkspaceRepository {
  _CloudStore(this.value);
  Workspace value;
  int saves = 0, syncs = 0;
  Completer<void>? saveGate;
  final saveEntered = Completer<void>();
  @override
  String get mode => 'test';
  @override
  Stream<void> get localChanges => const Stream.empty();
  @override
  Future<Workspace?> loadLocal() async => value;
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async {}
  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    if (value.revision != expectedRevision) {
      throw const RepositoryException('revision', conflict: true);
    }
    saves++;
    value = next.copyWith(revision: expectedRevision + 1);
    if (!saveEntered.isCompleted) saveEntered.complete();
    await saveGate?.future;
    return value;
  }

  @override
  int get pendingCount => 0;
  @override
  bool get isOffline => false;
  @override
  Json? get syncConflict => null;
  @override
  Future<Workspace?> synchronize() async {
    syncs++;
    return value;
  }

  @override
  Future<Workspace?> resolveConflict({required bool keepLocal}) async => value;
}

class _ResponseLostRemote extends HttpWorkspaceRepository {
  _ResponseLostRemote() : super(baseUrl: 'http://isolated.invalid');
  Workspace value = const Workspace(revision: 1);
  bool loseResponse = true;
  int writes = 0;
  final accepted = <String>{};
  final batches = <String>[];
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<Json> syncOperations(Json request) async {
    batches.add(request['batchId'] as String);
    final json = value.toJson();
    final versions = Map<String, dynamic>.from(value.entityVersions);
    for (final raw in request['operations'] as List) {
      final op = Map<String, dynamic>.from(raw as Map);
      if (!accepted.add(op['id'] as String)) continue;
      final type = op['entityType'] as String, id = op['entityId'] as String;
      final expected = op['expectedVersion'] as int;
      expect(versions['$type/$id'] ?? 0, expected);
      if (json[type] is List) {
        final values = List<dynamic>.from(json[type] as List)
          ..removeWhere((item) => item['id'] == id);
        if (op['action'] == 'upsert') {
          final value = Map<String, dynamic>.from(op['value'] as Map);
          if (value.containsKey('revision')) value['revision'] = expected + 1;
          values.add(value);
        }
        json[type] = values;
      } else {
        json[type] = op['value'];
      }
      versions['$type/$id'] = expected + 1;
      writes++;
    }
    json['revision'] = value.revision + 1;
    json['entityVersions'] = versions;
    value = Workspace.fromJson(json);
    if (loseResponse) {
      throw const RepositoryException('response lost', offline: true);
    }
    return {'workspace': value.toJson()};
  }
}

class _ValidationAuth extends AuthRepository {
  _ValidationAuth() : super(apiBaseUrl: 'http://isolated.invalid');
  Workspace Function() readCloud = () => _cloudData;
  Future<void> Function(Json candidate)? onValidate;
  int validations = 0, stateReads = 0;
  @override
  Future<Json> authenticatedRequest(
    String method,
    String path, {
    Object? data,
    String? contentType,
    String? idempotencyKey,
  }) async {
    if (method == 'GET' && path == '/api/v1/sync/state') {
      stateReads++;
      return {'workspace': readCloud().toJson()};
    }
    expect(method, 'POST');
    expect(path, '/api/v1/workspace/validate-merge');
    validations++;
    final candidate = Map<String, dynamic>.from(data as Map);
    await onValidate?.call(candidate);
    return {'valid': true, 'revision': candidate['expectedRevision']};
  }
}

_ValidationAuth _auth([String id = 'a']) {
  final auth = _ValidationAuth();
  auth.session = _session(id);
  return auth;
}

AuthSession _session(String id) => AuthSession(
  token: 'synthetic-$id',
  expiresAt: DateTime.now().add(const Duration(days: 1)),
  user: AuthUser(id: id, username: id, email: 'user@example.test'),
);

Future<void> _turns() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const _deviceData = Workspace(
  tasks: [SeraTask(id: 'local', title: '本机待办')],
);
const _cloudData = Workspace(
  revision: 1,
  tasks: [SeraTask(id: 'cloud', title: '云端待办')],
);

void main() {
  test(
    'restored session only inspects pending data until explicit sync',
    () async {
      final auth = _auth(), device = _MemoryDevice(_deviceData);
      final store = _CloudStore(_cloudData);
      final controller = SeraController(
        repository: store,
        accountId: 'a',
        seedDemo: false,
      );
      await controller.initialize();
      final sync = DeviceCloudSync(
        device: device,
        controller: controller,
        auth: auth,
        isCurrent: () => true,
      );
      await _turns();
      expect(sync.hasPending, isTrue);
      expect(store.saves, 0);
      expect(store.syncs, 0);
      expect(store.value.tasks.single.id, 'cloud');
      await sync.synchronize();
      expect(store.value.tasks.map((t) => t.id), ['cloud', 'local']);
      expect(store.value.history.single.label, '同步本机记录');
      expect(sync.hasPending, isFalse);
      expect(sync.message, '本机记录已同步到云端。');
      expect(device.value, same(_deviceData));
      final writes = store.saves;
      await sync.synchronize();
      expect(store.saves, writes);
      expect(store.value.history, hasLength(1));
      sync.dispose();
      controller.dispose();
      auth.dispose();
      await device.dispose();
    },
  );

  test(
    'empty device does not write receipt, history or invoke cloud sync',
    () async {
      final auth = _auth(), device = _MemoryDevice(const Workspace());
      final store = _CloudStore(_cloudData);
      final controller = SeraController(
        repository: store,
        accountId: 'a',
        seedDemo: false,
      );
      await controller.initialize();
      final sync = DeviceCloudSync(
        device: device,
        controller: controller,
        auth: auth,
        isCurrent: () => true,
      );
      await _turns();
      expect(sync.hasPending, isFalse);
      await sync.synchronize();
      expect(device.receiptWrites, 0);
      expect(store.saves, 0);
      expect(store.syncs, 0);
      expect(store.value.history, isEmpty);
      sync.dispose();
      controller.dispose();
      auth.dispose();
      await device.dispose();
    },
  );

  test(
    'conflict blocks save and receipt until the user chooses cloud',
    () async {
      final auth = _auth(), device = _MemoryDevice(_deviceData);
      final store = _CloudStore(
        const Workspace(
          revision: 1,
          tasks: [SeraTask(id: 'local', title: '云端同 ID')],
        ),
      );
      final controller = SeraController(
        repository: store,
        accountId: 'a',
        seedDemo: false,
      );
      await controller.initialize();
      final sync = DeviceCloudSync(
        device: device,
        controller: controller,
        auth: auth,
        isCurrent: () => true,
      );
      await sync.synchronize();
      expect(sync.hasConflicts, isTrue);
      expect(sync.conflictCount, 1);
      expect(sync.hasPending, isTrue);
      expect(store.saves, 0);
      expect(device.receipts, isEmpty);
      expect(auth.validations, 0);
      expect(auth.stateReads, 0);
      await sync.synchronize(preferDevice: false);
      expect(sync.hasConflicts, isFalse);
      expect(sync.hasPending, isFalse);
      expect(store.value.tasks.single.title, '云端同 ID');
      expect(store.saves, 0);
      expect(device.receiptWrites, 1);
      sync.dispose();
      controller.dispose();
      auth.dispose();
      await device.dispose();
    },
  );

  test(
    'late device read after account switch cannot merge or create receipt',
    () async {
      final auth = _auth(), device = _MemoryDevice(_deviceData);
      device.readGate = Completer<void>();
      final store = _CloudStore(_cloudData);
      final controller = SeraController(
        repository: store,
        accountId: 'a',
        seedDemo: false,
      );
      await controller.initialize();
      var current = true;
      final sync = DeviceCloudSync(
        device: device,
        controller: controller,
        auth: auth,
        isCurrent: () => current,
      );
      final pending = sync.synchronize();
      auth.session = _session('b');
      current = false;
      device.readGate!.complete();
      await pending;
      await _turns();
      expect(store.saves, 0);
      expect(device.receiptWrites, 0);
      expect(store.value.tasks.single.id, 'cloud');
      sync.dispose();
      controller.dispose();
      auth.dispose();
      await device.dispose();
    },
  );

  test('late old-account save never adopts data or runs platform effects after switch', () async {
    final auth = _auth(), device = _MemoryDevice(_deviceData);
    final store = _CloudStore(_cloudData);
    var platformEffects = 0;
    final controller = SeraController(
      repository: store,
      accountId: 'a',
      seedDemo: false,
      onWorkspaceSaved: (_) async {
        platformEffects++;
      },
    );
    await controller.initialize();
    await _turns();
    platformEffects = 0;
    store.saveGate = Completer<void>();
    var current = true;
    final sync = DeviceCloudSync(
      device: device,
      controller: controller,
      auth: auth,
      isCurrent: () => current,
    );
    final pending = sync.synchronize();
    await store.saveEntered.future;
    auth.session = _session('b');
    current = false;
    store.saveGate!.complete();
    await pending;
    await _turns();
    expect(controller.data.tasks.single.id, 'cloud');
    expect(platformEffects, 0);
    expect(device.receiptWrites, 0);
    expect(store.syncs, 0);
    sync.dispose();
    controller.dispose();
    auth.dispose();
    await device.dispose();
  });

  test('lost remote response retries the existing durable journal without reimport', () async {
    final db = await databaseFactoryMemory.openDatabase(
      'device-cloud-response-lost',
    );
    final remote = _ResponseLostRemote();
    final repository = OfflineWorkspaceRepository(
      remote: remote,
      accountId: 'a',
      database: db,
    );
    final controller = SeraController(
      repository: repository,
      accountId: 'a',
      seedDemo: false,
    );
    await controller.initialize();
    final auth = _auth(), device = _MemoryDevice(_deviceData);
    auth.readCloud = () => remote.value;
    final sync = DeviceCloudSync(
      device: device,
      controller: controller,
      auth: auth,
      isCurrent: () => true,
    );
    await sync.synchronize();
    expect(sync.hasPending, isTrue);
    expect(sync.message, '本机已合并，仍有记录待上传。');
    expect(device.receiptWrites, 1);
    expect(controller.data.tasks.single.id, 'local');
    expect(remote.value.tasks.single.id, 'local');
    final writes = remote.writes;
    final historyId = controller.data.history.single.id;
    remote.loseResponse = false;
    await sync.synchronize();
    await _turns();
    expect(sync.hasPending, isFalse);
    expect(sync.message, '本机记录已同步到云端。');
    expect(remote.writes, writes);
    expect(remote.batches.toSet(), hasLength(1));
    expect(controller.data.tasks, hasLength(1));
    expect(controller.data.history.single.id, historyId);
    expect(device.receiptWrites, 1);
    sync.dispose();
    controller.dispose();
    auth.dispose();
    await repository.dispose();
    await device.dispose();
  });

  test('acknowledged import keeps undo digest valid and preserves unrelated cloud data', () async {
    final db = await databaseFactoryMemory.openDatabase(
      'device-cloud-ack-undo',
    );
    final remote = _ResponseLostRemote()..loseResponse = false;
    remote.value = _cloudData;
    final repository = OfflineWorkspaceRepository(
      remote: remote,
      accountId: 'a',
      database: db,
    );
    final controller = SeraController(
      repository: repository,
      accountId: 'a',
      seedDemo: false,
    );
    await controller.initialize();
    final device = _MemoryDevice(
      Workspace(
        tasks: [const SeraTask(id: 'local', title: '本机多次编辑过的记录', revision: 12)],
      ),
    );
    final auth = _auth()..readCloud = () => remote.value;
    final sync = DeviceCloudSync(
      device: device,
      controller: controller,
      auth: auth,
      isCurrent: () => true,
    );
    await sync.synchronize();
    expect(sync.hasPending, isFalse);
    expect(controller.task('local')!.revision, 1);
    final record = controller.data.history.single;
    expect(await controller.undoLast(expectedRecordId: record.id), isTrue);
    await repository.synchronize();
    await controller.refresh();
    expect(controller.data.tasks.single.id, 'cloud');
    expect(remote.value.tasks.single.id, 'cloud');
    expect(device.value!.tasks.single.id, 'local');
    sync.dispose();
    controller.dispose();
    auth.dispose();
    await repository.dispose();
    await device.dispose();
  });

  for (final offline in [false, true]) {
    test(
      'rejected ${offline ? 'offline' : 'invalid placement'} preflight leaves account journal and receipt untouched',
      () async {
        final db = await databaseFactoryMemory.openDatabase(
          'preflight-reject-$offline',
        );
        final remote = _ResponseLostRemote()..loseResponse = false;
        final repository = OfflineWorkspaceRepository(
          remote: remote,
          accountId: 'a',
          database: db,
        );
        final controller = SeraController(
          repository: repository,
          accountId: 'a',
          seedDemo: false,
        );
        await controller.initialize();
        final original = controller.data.toJson();
        final auth = _auth(), device = _MemoryDevice(_deviceData);
        auth.readCloud = () => remote.value;
        auth.onValidate = (_) async {
          throw RepositoryException(
            offline ? 'offline' : 'Task block overlaps a busy event',
            offline: offline,
          );
        };
        final sync = DeviceCloudSync(
          device: device,
          controller: controller,
          auth: auth,
          isCurrent: () => true,
        );
        await sync.synchronize();
        expect(sync.hasPending, isTrue);
        expect(auth.validations, 1);
        expect(repository.pendingCount, 0);
        expect((await repository.loadLocal())!.toJson(), original);
        expect(controller.data.toJson(), original);
        expect(remote.writes, 0);
        expect(remote.batches, isEmpty);
        expect(device.receiptWrites, 0);
        expect(device.value, same(_deviceData));
        sync.dispose();
        controller.dispose();
        auth.dispose();
        await repository.dispose();
        await device.dispose();
      },
    );
  }

  test('local account edit during preflight invalidates preview before durable save', () async {
    final auth = _auth(), device = _MemoryDevice(_deviceData);
    final store = _CloudStore(_cloudData);
    final controller = SeraController(
      repository: store,
      accountId: 'a',
      seedDemo: false,
    );
    await controller.initialize();
    auth.onValidate = (_) async {
      store.value = store.value.copyWith(
        revision: 2,
        tasks: [const SeraTask(id: 'cloud', title: '预检期间刚改名')],
      );
    };
    final sync = DeviceCloudSync(
      device: device,
      controller: controller,
      auth: auth,
      isCurrent: () => true,
    );
    await sync.synchronize();
    expect(sync.hasPending, isTrue);
    expect(sync.message, '记录已有更新，请重试同步。');
    expect(store.saves, 0);
    expect(store.value.tasks.single.title, '预检期间刚改名');
    expect(device.receiptWrites, 0);
    sync.dispose();
    controller.dispose();
    auth.dispose();
    await device.dispose();
  });

  test(
    'preflight uses remote revision independently from local CAS revision',
    () async {
      final auth = _auth(), device = _MemoryDevice(_deviceData);
      final store = _CloudStore(_cloudData.copyWith(revision: 50));
      auth.readCloud = () => store.value.copyWith(revision: 7);
      auth.onValidate = (request) async {
        expect(request['expectedRevision'], 7);
        expect((request['workspace'] as Map)['revision'], 7);
      };
      final controller = SeraController(
        repository: store,
        accountId: 'a',
        seedDemo: false,
      );
      await controller.initialize();
      final sync = DeviceCloudSync(
        device: device,
        controller: controller,
        auth: auth,
        isCurrent: () => true,
      );
      await sync.synchronize();
      expect(store.saves, 1);
      expect(store.value.revision, 51);
      expect(sync.hasPending, isFalse);
      expect(device.receiptWrites, 1);
      sync.dispose();
      controller.dispose();
      auth.dispose();
      await device.dispose();
    },
  );

  test('device edits arriving during preflight remain pending for the next explicit sync', () async {
    final auth = _auth(), device = _MemoryDevice(_deviceData);
    final store = _CloudStore(_cloudData);
    auth.readCloud = () => store.value;
    auth.onValidate = (_) async {
      device.value = const Workspace(
        tasks: [
          SeraTask(id: 'local', title: '本机待办'),
          SeraTask(id: 'late-device', title: '另一游客页刚新增'),
        ],
      );
    };
    final controller = SeraController(
      repository: store,
      accountId: 'a',
      seedDemo: false,
    );
    await controller.initialize();
    final sync = DeviceCloudSync(
      device: device,
      controller: controller,
      auth: auth,
      isCurrent: () => true,
    );
    await sync.synchronize();
    expect(store.value.tasks.map((e) => e.id), ['cloud', 'local']);
    expect(sync.hasPending, isTrue);
    expect(sync.message, '已有新的本机记录待同步。');
    auth.onValidate = null;
    await sync.synchronize();
    expect(store.value.tasks.map((e) => e.id), [
      'cloud',
      'local',
      'late-device',
    ]);
    expect(sync.hasPending, isFalse);
    sync.dispose();
    controller.dispose();
    auth.dispose();
    await device.dispose();
  });
}
