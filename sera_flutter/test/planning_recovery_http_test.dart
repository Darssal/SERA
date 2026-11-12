import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/data/repositories.dart';
import 'package:sera_flutter/domain/planning_service.dart';

// Keep real HTTP transport tests outside a testWidgets suite: initializing
// TestWidgetsFlutterBinding intentionally overrides HttpClient with HTTP 400.
final _deadline = DateTime(2026, 11, 20, 15);
const _outcome = AiPlanResult(
  model: 'recovery-test-model',
  tasks: [
    TaskOutline(title: '完成英语口语自测', estimatedMinutes: 30),
    TaskOutline(title: '整理口语练习记录', estimatedMinutes: 30),
  ],
);

void main() {
  test(
    'HTTP resume reuses the same durable job after a failed status read',
    () async {
      // This is a real local HTTP transport with a deterministic fake worker.
      // No supplier request, API key or billable AI operation is involved.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final jobs = <String, Map<String, dynamic>>{};
      final submissions = <Map<String, dynamic>>[];
      var workerReady = false;
      var providerExecutions = 0;
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.method == 'POST' && request.uri.path == '/api/v1/jobs') {
          final payload = Map<String, dynamic>.from(
            jsonDecode(await utf8.decoder.bind(request).join()) as Map,
          );
          submissions.add(payload);
          final id = payload['requestId'] as String;
          final job = jobs.putIfAbsent(id, () {
            providerExecutions++;
            return {
              'id': 'job-${jobs.length + 1}',
              'kind': 'plan',
              'status': 'running',
              'result': null,
              'error': null,
            };
          });
          if (workerReady) {
            job['status'] = 'succeeded';
            job['result'] = {
              'source': 'siliconflow',
              'model': _outcome.model,
              'tasks': [
                for (final task in _outcome.tasks)
                  {
                    'title': task.title,
                    'notes': task.notes,
                    'estimatedMinutes': task.estimatedMinutes,
                    'checklist': task.checklist,
                  },
              ],
            };
          }
          request.response.statusCode = 202;
          request.response.write(jsonEncode({'job': job}));
        } else if (request.method == 'GET' &&
            request.uri.path.startsWith('/api/v1/jobs/')) {
          request.response.statusCode = 503;
          request.response.write(jsonEncode({'error': '状态接口暂时不可用'}));
        } else {
          request.response.statusCode = 404;
          request.response.write('{}');
        }
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}';
      final first = HttpWorkspaceRepository(baseUrl: url);
      await expectLater(
        first.generateTaskBreakdown(
          title: '英语口语恢复目标',
          deadline: _deadline,
          dailyBudget: 90,
          prompt: '完成口语练习',
          notes: '冻结后的原始上下文',
          requestId: 'persisted-request-1',
        ),
        throwsA(
          isA<RepositoryException>().having(
            (e) => e.details['planningJobRecoverable'],
            'recoverable job',
            true,
          ),
        ),
      );
      // The first process is gone. Its in-memory job ID is not passed along.
      workerReady = true;
      final reopened = HttpWorkspaceRepository(baseUrl: url);
      final result = await reopened.generateTaskBreakdown(
        title: '英语口语恢复目标',
        deadline: _deadline,
        dailyBudget: 90,
        prompt: '完成口语练习',
        notes: '冻结后的原始上下文',
        requestId: 'persisted-request-1',
      );
      expect(result.model, _outcome.model);
      expect(result.tasks, hasLength(2));
      expect(submissions, hasLength(2));
      expect(submissions.first, submissions.last);
      expect(jobs, hasLength(1));
      expect(providerExecutions, 1);
    },
  );
}
