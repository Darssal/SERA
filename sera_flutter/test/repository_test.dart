import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sera_flutter/data/repositories.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/auth_repository.dart';

void main() {
  const integrationUrl = String.fromEnvironment('API_INTEGRATION_URL');
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test(
    'optional live Python SQLite API roundtrip, planning and undo',
    () async {
      final auth = AuthRepository(
        apiBaseUrl: integrationUrl,
        preferences: SharedPreferencesAsync(),
      );
      final unique = DateTime.now().microsecondsSinceEpoch;
      const testPassword = 'QaIsolatedPassword123';
      await auth.register(
        username: 'qa-$unique',
        email: 'qa-$unique@example.test',
        password: testPassword,
      );
      addTearDown(() async {
        if (auth.signedIn) await auth.deleteAccount(testPassword);
      });
      final repository = HttpWorkspaceRepository(
        baseUrl: integrationUrl,
        tokenProvider: () => auth.token,
      );
      final controller = SeraController(
        repository: repository,
        today: DateTime(2026, 11, 2),
        accountId: auth.session!.user.id,
        seedDemo: false,
      );
      await controller.initialize();
      expect(controller.data.tasks, isEmpty);
      final draft = await controller.generatePlan(
        title: '准备 Flutter 课程项目的五分钟答辩演示',
        notes: '总投入不超过180分钟，拆成四个各30分钟以内的小任务，包含功能演示和演示稿。',
        deadline: DateTime(2026, 11, 20, 18),
        dailyBudget: 90,
      );
      await controller.commitDraft(draft.id);
      expect(controller.data.tasks, hasLength(draft.items.length));
      expect(draft.source, 'siliconflow');
      expect(draft.model, isNotEmpty);
      // Only the opt-in integration test prints its non-sensitive sample result.
      // Provider credentials never enter the Flutter process.
      // ignore: avoid_print
      print(
        'AI smoke: ${jsonEncode({'source': draft.source, 'model': draft.model, 'taskCount': draft.items.length, 'totalMinutes': draft.totalMinutes, 'titles': draft.items.map((e) => e.task.title).toList()})}',
      );
      await controller.recordFocus(draft.items.first.task.id, 9);
      await controller.deleteTask(draft.items.first.task.id);
      expect(await controller.undoLast(), isTrue);
      expect(controller.task(draft.items.first.task.id)!.actualSeconds, 9);
      final reopened = SeraController(
        repository: HttpWorkspaceRepository(
          baseUrl: integrationUrl,
          tokenProvider: () => auth.token,
        ),
        accountId: auth.session!.user.id,
        seedDemo: false,
      );
      await reopened.initialize();
      expect(reopened.data.tasks, hasLength(draft.items.length));
      expect(reopened.task(draft.items.first.task.id)!.actualSeconds, 9);
      await repository.clear();
    },
    skip: integrationUrl.isEmpty
        ? 'Set API_INTEGRATION_URL to an isolated reference API to run the live contract test.'
        : false,
  );

  test('local async repository roundtrips across instances and rejects stale writes', () async {
    final first = LocalWorkspaceRepository();
    expect(await first.load(), isNull);
    final saved = await first.save(
      const Workspace(
        tasks: [SeraTask(id: 't', title: '持久任务')],
      ),
      expectedRevision: 0,
    );
    expect(saved.revision, 1);
    final second = LocalWorkspaceRepository();
    expect((await second.load())!.tasks.single.title, '持久任务');
    await expectLater(
      second.save(const Workspace(), expectedRevision: 0),
      throwsA(
        isA<RepositoryException>().having((e) => e.conflict, 'conflict', true),
      ),
    );
    expect((await first.load())!.tasks, hasLength(1));
    await second.clear();
    expect(await first.load(), isNull);
  });

  test(
    'corrupt local data fails visibly instead of silently resetting data',
    () async {
      await SharedPreferencesAsync().setString('sera.workspace.v1', '{broken');
      await expectLater(
        LocalWorkspaceRepository().load(),
        throwsA(isA<RepositoryException>()),
      );
    },
  );

  test('local repository serializes concurrent saves with the same expected version', () async {
    final repository = LocalWorkspaceRepository();
    final outcomes = await Future.wait([
      for (var i = 0; i < 4; i++)
        repository
            .save(const Workspace(), expectedRevision: 0)
            .then<Object>((value) => value)
            .catchError((Object e) => e),
    ]);
    expect(outcomes.whereType<Workspace>(), hasLength(1));
    expect(outcomes.whereType<RepositoryException>(), hasLength(3));
    expect((await repository.load())!.revision, 1);
  });

  test(
    'Dio repository sends real REST requests and exposes conflict responses',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      Workspace? stored;
      final methods = <String>[];
      server.listen((request) async {
        methods.add(request.method);
        request.response.headers.contentType = ContentType.json;
        expect(request.uri.path, '/api/v1/workspace');
        if (request.method == 'PUT') {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Json;
          final expected = body['expectedRevision'] as int;
          final sent = Workspace.fromJson(
            Map<String, dynamic>.from(body['workspace'] as Map),
          );
          expect(sent.revision, expected);
          if ((stored?.revision ?? 0) != expected) {
            request.response.statusCode = 409;
            request.response.write(
              jsonEncode({'error': 'stale', 'code': 'revision_conflict'}),
            );
            await request.response.close();
            return;
          }
          stored = sent.copyWith(revision: expected + 1);
        } else if (request.method == 'DELETE') {
          stored = null;
        }
        request.response.write(jsonEncode({'workspace': stored?.toJson()}));
        await request.response.close();
      });
      final repository = HttpWorkspaceRepository(
        baseUrl: 'http://127.0.0.1:${server.port}/',
      );
      expect(await repository.load(), isNull);
      final saved = await repository.save(
        const Workspace(),
        expectedRevision: 0,
      );
      expect(saved.revision, 1);
      await expectLater(
        repository.save(const Workspace(), expectedRevision: 0),
        throwsA(
          isA<RepositoryException>().having(
            (e) => e.conflict,
            'conflict',
            true,
          ),
        ),
      );
      // Undo/reset snapshots carry an old revision; the request uses expectedRevision.
      expect(
        (await repository.save(
          const Workspace(),
          expectedRevision: 1,
        )).revision,
        2,
      );
      expect((await repository.load())!.revision, 2);
      await repository.clear();
      expect(await repository.load(), isNull);
      expect(methods, ['GET', 'PUT', 'PUT', 'PUT', 'GET', 'DELETE', 'GET']);
    },
  );

  test(
    'malformed response and timeout cannot become successful writes',
    () async {
      final bad = Dio();
      bad.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                data: {'wrong': true},
                statusCode: 200,
              ),
            );
          },
        ),
      );
      await expectLater(
        HttpWorkspaceRepository(
          baseUrl: 'http://localhost',
          client: bad,
        ).load(),
        throwsA(isA<RepositoryException>()),
      );
      final timeout = Dio();
      timeout.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.receiveTimeout,
              ),
            );
          },
        ),
      );
      await expectLater(
        HttpWorkspaceRepository(
          baseUrl: 'http://localhost',
          client: timeout,
        ).save(const Workspace(), expectedRevision: 0),
        throwsA(
          isA<RepositoryException>().having(
            (e) => e.message,
            'message',
            contains('超时'),
          ),
        ),
      );
    },
  );
}
