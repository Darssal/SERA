import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/data/repositories.dart';
import 'package:sera_flutter/domain/models.dart';

void main() {
  test('planning context uses loaded and synced user timezone without a ticking input', () async {
    final dio = Dio();
    var zone = 'America/New_York';
    final inputs = <Map<String, dynamic>>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          dynamic body;
          if (options.path == '/api/v1/jobs') {
            inputs.add(
              Map<String, dynamic>.from((options.data as Map)['input'] as Map),
            );
            body = {
              'job': {
                'id': 'job',
                'kind': 'plan',
                'status': 'succeeded',
                'result': {
                  'source': 'siliconflow',
                  'model': 'test-model',
                  'tasks': [
                    {
                      'title': '复习',
                      'notes': '',
                      'estimatedMinutes': 30,
                      'checklist': <String>[],
                    },
                  ],
                },
              },
            };
          } else {
            body = {
              'workspace': Workspace(
                preferences: SeraPreferences(timeZone: zone),
              ).toJson(),
            };
          }
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: body,
            ),
          );
        },
      ),
    );
    final repository = HttpWorkspaceRepository(
      baseUrl: 'http://localhost',
      client: dio,
    );
    addTearDown(repository.dispose);
    await repository.load();
    Future<void> generate(String id) async {
      await repository.generateTaskBreakdown(
        title: '复习',
        deadline: DateTime.utc(2026, 12, 1),
        dailyBudget: 90,
        requestId: id,
      );
    }

    await generate('stable');
    await generate('stable');
    expect(inputs.first['timeZone'], 'America/New_York');
    expect(inputs.first, inputs[1]);
    expect(inputs.first.containsKey('referenceNow'), isFalse);
    zone = 'Europe/London';
    await repository.syncOperations({'operations': []});
    await generate('after-sync');
    expect(inputs.last['timeZone'], 'Europe/London');
  });
  test('phase windows survive workspace JSON, copy and legacy data', () {
    final start = DateTime.parse('2026-11-09T08:00:00+08:00');
    final end = DateTime.parse('2026-11-16T00:00:00+08:00');
    final task = SeraTask(
      id: 't',
      title: '树与图练习',
      phase: '专题强化',
      notBefore: start,
      dueAt: end,
    );
    final restored = Workspace.fromJson(Workspace(tasks: [task]).toJson())
        .tasks
        .single
        .copyWith(title: '调整名称');
    expect(restored.phase, '专题强化');
    expect(restored.notBefore!.isAtSameMomentAs(start), isTrue);
    expect(restored.deadline!.isAtSameMomentAs(end), isTrue);
    expect(restored.copyWith(clearNotBefore: true).notBefore, isNull);
    final legacy = SeraTask.fromJson({'id': 'old', 'title': '旧任务'});
    expect(legacy.phase, isEmpty);
    expect(legacy.notBefore, isNull);
  });

  for (final invalid in [false, true]) {
    test('HTTP plan decodes phase windows (invalid=$invalid)', () async {
      final dio = Dio();
      final requestBodies = <Object?>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requestBodies.add(options.data);
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'job': {
                    'id': 'plan-test',
                    'kind': 'plan',
                    'status': 'succeeded',
                    'result': {
                      'source': 'siliconflow',
                      'model': 'test-model',
                      'tasks': [
                        {
                          'title': '树与图练习',
                          'notes': '完成题组并订正',
                          'estimatedMinutes': 60,
                          'checklist': ['检查错误'],
                          'phase': '专题强化',
                          'notBefore': invalid
                              ? '下周'
                              : '2026-11-09T00:00:00+08:00',
                          'deadline': '2026-11-16T00:00:00+08:00',
                        },
                      ],
                    },
                  },
                },
              ),
            );
          },
        ),
      );
      final repository = HttpWorkspaceRepository(
        baseUrl: 'http://localhost',
        client: dio,
      );
      addTearDown(repository.dispose);
      final future = repository.generateTaskBreakdown(
        title: '数据结构复习',
        deadline: DateTime.utc(2026, 12, 1),
        dailyBudget: 180,
        requestId: 'stable-long-plan',
      );
      if (invalid) {
        await expectLater(future, throwsA(isA<RepositoryException>()));
      } else {
        final result = await future;
        expect(result.tasks.single.phase, '专题强化');
        expect(result.tasks.single.notBefore, DateTime.utc(2026, 11, 8, 16));
        expect(result.tasks.single.deadline, DateTime.utc(2026, 11, 15, 16));
        expect(requestBodies, hasLength(1));
      }
    });
  }
}
