import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/device_workspace_repository.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';

class _AiTransport implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final result = {
      'intent': 'task',
      'title': '买牛奶',
      'summary': '买牛奶',
      'outcome': '',
      'deadline': null,
      'deadlineIsDateOnly': false,
      'dailyBudget': null,
      'estimatedMinutes': 5,
      'start': null,
      'end': null,
      'questions': [],
      'source': 'siliconflow',
      'model': 'isolated-device-fixture',
    };
    return ResponseBody.fromString(
      jsonEncode({
        'job': {
          'id': 'device-job',
          'kind': 'understand',
          'status': 'succeeded',
          'result': result,
        },
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });
  test(
    'device startup is empty and durably saves without any remote request',
    () async {
      final db = await databaseFactoryMemory.openDatabase('device-empty');
      final adapter = _AiTransport();
      final dio = Dio(BaseOptions(baseUrl: 'http://device.invalid'))
        ..httpClientAdapter = adapter;
      final repo = DeviceWorkspaceRepository(
        apiBaseUrl: 'http://device.invalid',
        database: db,
        aiClient: dio,
        migrateLegacy: false,
      );
      final c = SeraController(
        repository: repo,
        accountId: DeviceWorkspaceRepository.scope,
        seedDemo: false,
      );
      await c.initialize();
      expect(c.data.tasks, isEmpty);
      expect(c.data.revision, 1);
      await c.saveTask(
        const SeraTask(id: 'local-task', title: '本机记录', estimatedMinutes: 15),
      );
      expect((await repo.load())!.tasks.single.id, 'local-task');
      expect(adapter.requests, isEmpty);
      c.dispose();
      await repo.dispose();
    },
  );
  test('independent device repository instances reject stale concurrent writes atomically', () async {
    final db = await databaseFactoryMemory.openDatabase('device-cas');
    final a = DeviceWorkspaceRepository(
      apiBaseUrl: 'http://device.invalid',
      database: db,
      migrateLegacy: false,
    );
    final b = DeviceWorkspaceRepository(
      apiBaseUrl: 'http://device.invalid',
      database: db,
      migrateLegacy: false,
    );
    final attempts = await Future.wait(
      [a, b].map((repo) async {
        try {
          await repo.save(
            const Workspace(
              tasks: [SeraTask(id: 'one', title: '一项', estimatedMinutes: 5)],
            ),
            expectedRevision: 0,
          );
          return true;
        } on RepositoryException catch (error) {
          expect(error.conflict, isTrue);
          return false;
        }
      }),
    );
    expect(attempts.where((value) => value).length, 1);
    expect((await a.load())!.tasks.single.id, 'one');
    await a.dispose();
    await b.dispose();
  });
  test(
    'device capability and receipts stay local and survive repository reopen',
    () async {
      final db = await databaseFactoryMemory.openDatabase('device-scope');
      final a = DeviceWorkspaceRepository(
        apiBaseUrl: 'http://device.invalid',
        database: db,
        migrateLegacy: false,
      );
      final token = await a.deviceToken();
      expect(RegExp(r'^[a-f0-9]{64}$').hasMatch(token), isTrue);
      await a.save(const Workspace(), expectedRevision: 0);
      await a.saveCloudReceipt('account-a', {'inputFingerprint': 'receipt-a'});
      final b = DeviceWorkspaceRepository(
        apiBaseUrl: 'http://device.invalid',
        database: db,
        migrateLegacy: false,
      );
      expect(await b.deviceToken(), token);
      expect(
        (await b.cloudReceipt('account-a'))!['inputFingerprint'],
        'receipt-a',
      );
      expect(await b.cloudReceipt('account-b'), isNull);
      expect(jsonEncode((await b.load())!.toJson()), isNot(contains(token)));
      await b.saveCloudReceipt('account-b', {'inputFingerprint': 'receipt-b'});
      await a.forgetCloudReceipt('account-a');
      expect(await b.cloudReceipt('account-a'), isNull);
      expect(
        (await b.cloudReceipt('account-b'))!['inputFingerprint'],
        'receipt-b',
      );
      expect(await b.load(), isNotNull);
      await a.dispose();
      await b.dispose();
    },
  );
  test(
    'explicit anonymous AI uses device jobs only and never uploads workspace',
    () async {
      final db = await databaseFactoryMemory.openDatabase('device-ai');
      final adapter = _AiTransport();
      final dio = Dio(BaseOptions(baseUrl: 'http://device.invalid'))
        ..httpClientAdapter = adapter;
      final repo = DeviceWorkspaceRepository(
        apiBaseUrl: 'http://device.invalid',
        database: db,
        aiClient: dio,
        migrateLegacy: false,
      );
      final result = await repo.understandInput(
        input: {'prompt': '买牛奶'},
        requestId: 'understand-one',
      );
      expect(result.title, '买牛奶');
      expect(result.model, 'isolated-device-fixture');
      expect(adapter.requests.single.path, '/api/v1/device/jobs');
      expect(
        adapter.requests.single.headers['X-Sera-Device'],
        await repo.deviceToken(),
      );
      expect(
        adapter.requests.single.headers.containsKey('Authorization'),
        isFalse,
      );
      expect(
        (adapter.requests.single.data as Map).containsKey('workspace'),
        isFalse,
      );
      expect(await repo.load(), isNull);
      await repo.dispose();
    },
  );
  test('clearing device workspace preserves no secret in workspace export and blocks stale saves', () async {
    final db = await databaseFactoryMemory.openDatabase('device-clear');
    final repo = DeviceWorkspaceRepository(
      apiBaseUrl: 'http://device.invalid',
      database: db,
      migrateLegacy: false,
    );
    await repo.save(const Workspace(), expectedRevision: 0);
    final token = await repo.deviceToken();
    await repo.clear();
    expect(await repo.load(), isNull);
    expect(await repo.deviceToken(), token);
    await repo.dispose();
    await expectLater(
      repo.save(const Workspace(), expectedRevision: 0),
      throwsA(isA<RepositoryException>()),
    );
  });
}
