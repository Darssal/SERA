import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/data/repositories.dart';
import 'package:sera_flutter/domain/models.dart';

// Deterministic local HTTP workers verify transport and persistence without
// supplier credentials, billable requests or a real user's workspace.
Json _input() => {
  'prompt': '想把英语口语练好，截止时间还没想好',
  'referenceNow': '2026-10-31T21:00:00+08:00',
  'timeZone': 'Asia/Hong_Kong',
  'dailyBudget': 90,
  'notes': '',
};

Json _meaning({String title = '练习英语口语'}) => {
  'intent': 'goal',
  'title': title,
  'summary': '希望提高工作交流能力',
  'outcome': '能够自然交流',
  'deadline': null,
  'deadlineIsDateOnly': false,
  'dailyBudget': null,
  'estimatedMinutes': null,
  'start': null,
  'end': null,
  'questions': [
    {'id': 'deadline', 'question': '你希望何时完成？'},
  ],
  'source': 'siliconflow',
  'model': 'deterministic-contract-worker',
};

Json _job(
  String id,
  String kind, {
  String status = 'succeeded',
  dynamic result,
}) => {
  'job': {
    'id': id,
    'kind': kind,
    'status': status,
    'result': result,
    'error': null,
  },
};

Future<HttpServer> _server(Future<Json> Function(HttpRequest) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    final body = await handler(request);
    try {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
      await request.response.close();
    } on SocketException {
      // Expected when an account switch cancels an in-flight status read.
    } on HttpException {
      // The client can already have closed an intentionally canceled request.
    }
  });
  return server;
}

String _url(HttpServer server) => 'http://127.0.0.1:${server.port}';
Future<Json> _body(HttpRequest request) async => Map<String, dynamic>.from(
  jsonDecode(await utf8.decoder.bind(request).join()) as Map,
);

Future<Object> _outcome<T>(Future<T> future) => future.then<Object>(
  (value) => value as Object,
  onError: (Object error) => error,
);

void main() {
  test(
    'an empty-answer job preserves its reason without automatic resubmission',
    () async {
      var submissions = 0;
      final server = await _server((request) async {
        submissions++;
        return {
          'job': {
            'id': 'empty-answer',
            'kind': 'understand',
            'status': 'failed',
            'result': null,
            'error': 'AI 未返回内容，请重试。',
            'errorCode': 'ai_empty_response',
          },
        };
      });
      final repository = HttpWorkspaceRepository(baseUrl: _url(server));
      addTearDown(repository.dispose);
      await expectLater(
        repository.understandInput(
          input: _input(),
          requestId: 'empty-answer-fixture',
        ),
        throwsA(
          isA<RepositoryException>()
              .having((error) => error.message, 'message', 'AI 未返回内容，请重试。')
              .having(
                (error) => error.details['code'],
                'code',
                'ai_empty_response',
              )
              .having(
                (error) => error.details['planningJobTerminal'],
                'terminal',
                true,
              ),
        ),
      );
      expect(submissions, 1);
    },
  );

  test('understanding resumes the frozen payload and same durable job after transport failure', () async {
    var ready = false, executions = 0;
    final submissions = <Json>[];
    final jobs = <String>{};
    final server = await _server((request) async {
      if (request.method == 'POST') {
        final payload = await _body(request);
        submissions.add(payload);
        if (jobs.add(payload['requestId'] as String)) executions++;
        return _job(
          'understanding-one',
          'understand',
          status: ready ? 'succeeded' : 'running',
          result: ready ? _meaning() : null,
        );
      }
      request.response.statusCode = 503;
      return {'error': 'status temporarily unavailable'};
    });
    final first = HttpWorkspaceRepository(baseUrl: _url(server));
    await expectLater(
      first.understandInput(input: _input(), requestId: 'frozen-request'),
      throwsA(
        isA<RepositoryException>().having(
          (error) => error.details['planningJobRecoverable'],
          'recoverable',
          true,
        ),
      ),
    );
    first.dispose();
    ready = true;
    final reopened = HttpWorkspaceRepository(baseUrl: _url(server));
    addTearDown(reopened.dispose);
    final meaning = await reopened.understandInput(
      input: _input(),
      requestId: 'frozen-request',
    );
    expect(meaning.title, '练习英语口语');
    expect(meaning.deadline, isNull);
    expect(meaning.questions.single.id, 'deadline');
    expect(executions, 1);
    expect(submissions, hasLength(2));
    expect(submissions.first, submissions.last);
    expect(submissions.first['kind'], 'understand');
  });

  test(
    'canceling understanding cancels its server job while planning can finish',
    () async {
      final understandingQueued = Completer<void>();
      final serverCanceled = Completer<String>();
      final server = await _server((request) async {
        if (request.uri.path.endsWith('/cancel')) {
          serverCanceled.complete(request.uri.path);
          return _job('understand-job', 'understand', status: 'canceled');
        }
        if (request.method == 'POST') {
          final payload = await _body(request);
          final kind = payload['kind'] as String;
          return _job('$kind-job', kind, status: 'queued');
        }
        return _job(
          'plan-job',
          'plan',
          result: {
            'source': 'siliconflow',
            'model': 'test-plan-worker',
            'tasks': [
              {
                'title': '实际任务',
                'notes': '完成标准',
                'estimatedMinutes': 30,
                'checklist': <String>[],
              },
            ],
          },
        );
      });
      final repository = HttpWorkspaceRepository(baseUrl: _url(server));
      addTearDown(repository.dispose);
      final plan = repository.generateTaskBreakdown(
        title: '目标',
        deadline: DateTime.utc(2026, 11, 20),
        dailyBudget: 90,
      );
      // Plan has no stage callback; wait for understanding's stage after both
      // submissions were issued, and let plan polling independently finish.
      final understanding = _outcome(
        repository.understandInput(
          input: _input(),
          requestId: 'cancel-only-understanding',
          onStage: (stage) {
            if (stage == '等待模型处理' && !understandingQueued.isCompleted) {
              understandingQueued.complete();
            }
          },
        ),
      );
      await understandingQueued.future;
      repository.cancelUnderstanding();
      expect(
        await understanding,
        isA<RepositoryException>().having(
          (error) => error.details['jobStatus'],
          'canceled',
          'canceled',
        ),
      );
      expect(await serverCanceled.future, '/api/v1/jobs/understand-job/cancel');
      expect((await plan).tasks.single.title, '实际任务');
      // Keep both cancellation APIs callable after completion.
      repository.cancelPlanning();
    },
  );

  test(
    'a canceled request cannot clear or publish over an immediate replacement',
    () async {
      final queued = Completer<void>();
      final cancellation = Completer<void>();
      final cancellations = <String>[];
      final server = await _server((request) async {
        if (request.uri.path.endsWith('/cancel')) {
          cancellations.add(request.uri.path);
          cancellation.complete();
          return _job('old-job', 'understand', status: 'canceled');
        }
        final payload = await _body(request);
        if (payload['requestId'] == 'first-request') {
          return _job('old-job', 'understand', status: 'queued');
        }
        return _job(
          'new-job',
          'understand',
          result: _meaning(title: '用户重新提交的结果'),
        );
      });
      final repository = HttpWorkspaceRepository(baseUrl: _url(server));
      addTearDown(repository.dispose);
      final first = _outcome(
        repository.understandInput(
          input: _input(),
          requestId: 'first-request',
          onStage: (stage) {
            if (stage == '等待模型处理' && !queued.isCompleted) queued.complete();
          },
        ),
      );
      await queued.future;
      repository.cancelUnderstanding();
      final second = repository.understandInput(
        input: _input(),
        requestId: 'replacement-request',
      );
      expect(await first, isA<RepositoryException>());
      expect((await second).title, '用户重新提交的结果');
      await cancellation.future;
      expect(cancellations, ['/api/v1/jobs/old-job/cancel']);
    },
  );

  test('a changed account cannot poll or cancel the previous account job', () async {
    var token = 'account-a';
    final queued = Completer<void>();
    final requests = <String>[];
    final server = await _server((request) async {
      requests.add(
        '${request.method} ${request.uri.path} ${request.headers.value('Authorization')}',
      );
      return _job('account-a-job', 'understand', status: 'running');
    });
    final repository = HttpWorkspaceRepository(
      baseUrl: _url(server),
      tokenProvider: () => token,
    );
    addTearDown(repository.dispose);
    final result = _outcome(
      repository.understandInput(
        input: _input(),
        requestId: 'same-request',
        onStage: (stage) {
          if (stage == '模型正在理解你的描述' && !queued.isCompleted) queued.complete();
        },
      ),
    );
    await queued.future;
    token = 'account-b';
    expect(
      await result,
      isA<RepositoryException>().having(
        (error) => error.details['jobStatus'],
        'canceled',
        'canceled',
      ),
    );
    expect(requests, ['POST /api/v1/jobs Bearer account-a']);
  });

  test('late unauthorized response from an old account does not log out the active account', () async {
    var token = 'account-a', unauthorizedCalls = 0;
    final reading = Completer<void>(), release = Completer<void>();
    final server = await _server((request) async {
      if (request.method == 'POST') {
        return _job('old-account', 'understand', status: 'running');
      }
      reading.complete();
      await release.future;
      request.response.statusCode = 401;
      return {'error': 'old session expired'};
    });
    final repository = HttpWorkspaceRepository(
      baseUrl: _url(server),
      tokenProvider: () => token,
      onUnauthorized: () async {
        unauthorizedCalls++;
      },
    );
    addTearDown(repository.dispose);
    final result = _outcome(
      repository.understandInput(input: _input(), requestId: 'old-request'),
    );
    await reading.future;
    token = 'account-b';
    release.complete();
    expect(
      await result,
      isA<RepositoryException>().having(
        (error) => error.details['jobStatus'],
        'canceled',
        'canceled',
      ),
    );
    expect(unauthorizedCalls, 0);
  });

  test('dispose drops delayed understanding and the new account starts its own job', () async {
    final reading = Completer<void>(), release = Completer<void>();
    final owners = <String>[];
    final server = await _server((request) async {
      final owner = request.headers.value('Authorization')!;
      owners.add(owner);
      if (owner == 'Bearer account-b') {
        return _job('job-b', 'understand', result: _meaning(title: '账号B自己的结果'));
      }
      if (request.uri.path.endsWith('/cancel')) {
        return _job('job-a', 'understand', status: 'canceled');
      }
      if (request.method == 'POST') {
        return _job('job-a', 'understand', status: 'running');
      }
      reading.complete();
      await release.future;
      return _job('job-a', 'understand', result: _meaning(title: '账号A的迟到结果'));
    });
    final old = HttpWorkspaceRepository(
      baseUrl: _url(server),
      tokenProvider: () => 'account-a',
    );
    final late = _outcome(
      old.understandInput(input: _input(), requestId: 'same-persisted-id'),
    );
    await reading.future;
    old.dispose();
    expect(
      await late,
      isA<RepositoryException>().having(
        (error) => error.details['jobStatus'],
        'canceled',
        'canceled',
      ),
    );
    final current = HttpWorkspaceRepository(
      baseUrl: _url(server),
      tokenProvider: () => 'account-b',
    );
    addTearDown(current.dispose);
    final fresh = await current.understandInput(
      input: _input(),
      requestId: 'same-persisted-id',
    );
    release.complete();
    expect(fresh.title, '账号B自己的结果');
    expect(owners.where((owner) => owner == 'Bearer account-b'), hasLength(1));
    await expectLater(
      old.understandInput(input: _input(), requestId: 'closed'),
      throwsA(isA<RepositoryException>()),
    );
  });

  test('malformed job kind, state or identity never becomes a successful interpretation', () async {
    var mode = 'kind';
    final server = await _server((request) async {
      return _job(
        'job-one',
        mode == 'kind' ? 'plan' : 'understand',
        status: mode == 'state' ? 'mystery' : 'succeeded',
        result: _meaning(),
      );
    });
    final repository = HttpWorkspaceRepository(baseUrl: _url(server));
    addTearDown(repository.dispose);
    for (final value in ['kind', 'state']) {
      mode = value;
      await expectLater(
        repository.understandInput(input: _input(), requestId: 'bad-$mode'),
        throwsA(
          isA<RepositoryException>().having(
            (error) => error.details['planningJobRecoverable'],
            'recoverable',
            true,
          ),
        ),
      );
    }
  });
}
