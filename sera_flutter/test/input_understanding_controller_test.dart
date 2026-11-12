import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/planning_ai_provider.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';

class _UnderstandingStore
    implements
        WorkspaceRepository,
        InputUnderstandingProvider,
        CancellableInputUnderstandingProvider,
        CancellablePlanningAiProvider {
  Workspace value = const Workspace(revision: 1);
  final requests = <Json>[];
  final requestIds = <String>[];
  final stages = <void Function(String)?>[];
  final responses = <Completer<AiUnderstanding>>[];
  Completer<void>? saveGate;
  int understandingCancellations = 0;
  int planningCancellations = 0;
  @override
  String get mode => 'understanding-test';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async => value = const Workspace();
  @override
  Future<Workspace> save(
    Workspace workspace, {
    required int expectedRevision,
  }) async {
    final gate = saveGate;
    saveGate = null;
    await gate?.future;
    if (expectedRevision != value.revision) {
      throw const RepositoryException('测试版本冲突', conflict: true);
    }
    return value = Workspace.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(
          jsonEncode(
            workspace.copyWith(revision: expectedRevision + 1).toJson(),
          ),
        ) as Map,
      ),
    );
  }

  @override
  Future<AiUnderstanding> understandInput({
    required Json input,
    required String requestId,
    void Function(String)? onStage,
  }) {
    requests.add(input);
    requestIds.add(requestId);
    stages.add(onStage);
    final result = Completer<AiUnderstanding>();
    responses.add(result);
    return result.future;
  }

  @override
  void cancelUnderstanding() => understandingCancellations++;
  @override
  void cancelPlanning() => planningCancellations++;
}

const _answer = AiUnderstanding(
  intent: 'goal',
  title: '准备方案评审',
  summary: '需要安排准备工作；截止日期尚未确定。',
  outcome: '带着完成的方案参加评审',
  model: 'test-online-model',
  questions: [AiQuestion(id: 'deadline', question: '评审的具体日期是哪一天？')],
);

final _now = DateTime(2026, 10, 31, 10, 25);

Future<SeraController> _controller(
  _UnderstandingStore repository, {
  String accountId = 'account-a',
}) async {
  final controller = SeraController(
    repository: repository,
    today: _now,
    accountId: accountId,
    seedDemo: false,
  );
  await controller.initialize();
  return controller;
}

Matcher get _canceled => isA<RepositoryException>().having(
  (failure) => failure.details['jobStatus'],
  'jobStatus',
  'canceled',
);

void main() {
  test('context keeps original input, selected timezone and clarification snapshot', () async {
    final repository = _UnderstandingStore();
    final controller = await _controller(repository);
    addTearDown(controller.dispose);
    final answers = <String, String>{'deadline': '还没决定'};
    final previous = <String, dynamic>{
      ..._answer.toJson(),
      'clarificationAnswers': answers,
    };
    final input = controller.createUnderstandingInput(
      prompt: '  想准备方案评审\n还没定时间  ',
      notes: '保留这段原始说明',
      previous: previous,
    );
    answers['deadline'] = '下周五';
    expect(input['prompt'], '  想准备方案评审\n还没定时间  ');
    expect(input['timeZone'], 'Asia/Hong_Kong');
    expect(input['referenceNow'], '2026-10-31T10:25:00.000+08:00');
    expect(input['dailyBudget'], controller.data.preferences.dailyBudget);
    expect((input['previous'] as Map)['clarificationAnswers'], {
      'deadline': '还没决定',
    });
    expect(
      DateTime.parse(input['referenceNow'] as String),
      DateTime.utc(2026, 10, 31, 2, 25),
    );
  });

  test(
    'understanding is a proposal and never invents a deadline or saves objects',
    () async {
      final repository = _UnderstandingStore();
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      final input = controller.createUnderstandingInput(prompt: '有空时准备方案评审');
      final pending = controller.understandInput(
        input: input,
        requestId: 'proposal-1',
      );
      repository.stages.single?.call('模型正在理解');
      expect(controller.understandingStage, '模型正在理解');
      repository.responses.single.complete(_answer);
      final result = await pending;
      expect(result, same(_answer));
      expect(result.deadline, isNull);
      expect(result.questions.single.question, '评审的具体日期是哪一天？');
      expect(controller.data.tasks, isEmpty);
      expect(controller.data.entries, isEmpty);
      expect(controller.data.goals, isEmpty);
      expect(controller.data.drafts, isEmpty);
      expect(repository.value.revision, 1);
      expect(controller.understanding, isFalse);
      expect(controller.understandingStage, isEmpty);
    },
  );

  test(
    'dispatch snapshots nested JSON while the editor continues changing',
    () async {
      final repository = _UnderstandingStore();
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      final input = controller.createUnderstandingInput(
        prompt: '原描述',
        previous: {
          'clarificationAnswers': {'date': '待定'},
        },
      );
      final pending = controller.understandInput(
        input: input,
        requestId: 'snapshot-1',
      );
      input['prompt'] = '后来改写';
      ((input['previous'] as Map)['clarificationAnswers'] as Map)['date'] =
          '明天';
      expect(repository.requests.single['prompt'], '原描述');
      expect(
        (repository.requests.single['previous'] as Map)['clarificationAnswers'],
        {'date': '待定'},
      );
      repository.responses.single.complete(_answer);
      await pending;
    },
  );

  test(
    'malformed context fails locally with no request or stuck loading state',
    () async {
      final repository = _UnderstandingStore();
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      final valid = controller.createUnderstandingInput(prompt: '准备评审');
      for (final invalid in <Json>[
        {...valid, 'prompt': 42},
        {...valid, 'prompt': '   '},
        {...valid, 'notes': 42},
        {...valid, 'referenceNow': '2026-10-31T10:25:00'},
        {...valid, 'timeZone': 'No/Such_Zone'},
        {...valid, 'dailyBudget': 0},
        {...valid, 'previous': []},
      ]) {
        await expectLater(
          controller.understandInput(input: invalid, requestId: 'invalid-1'),
          throwsA(isA<RepositoryException>()),
        );
      }
      await expectLater(
        controller.understandInput(input: valid, requestId: ' '),
        throwsA(isA<RepositoryException>()),
      );
      expect(repository.requests, isEmpty);
      expect(controller.understanding, isFalse);
      expect(controller.understandingStage, isEmpty);
    },
  );

  test(
    'cancel ignores late result and stage without stopping a newer request',
    () async {
      final repository = _UnderstandingStore();
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      final input = controller.createUnderstandingInput(prompt: '准备方案');
      final old = controller.understandInput(
        input: input,
        requestId: 'old-request',
      );
      final oldFailure = expectLater(old, throwsA(_canceled));
      controller.cancelUnderstanding();
      expect(repository.understandingCancellations, 1);
      expect(repository.planningCancellations, 0);
      final current = controller.understandInput(
        input: input,
        requestId: 'new-request',
      );
      repository.stages.last?.call('当前请求');
      repository.stages.first?.call('迟到的旧状态');
      repository.responses.first.complete(_answer);
      await oldFailure;
      expect(controller.understanding, isTrue);
      expect(controller.understandingStage, '当前请求');
      repository.responses.last.complete(_answer);
      expect(await current, same(_answer));
      expect(controller.understanding, isFalse);
    },
  );

  test(
    'a network failure arriving after cancellation remains cancellation',
    () async {
      final repository = _UnderstandingStore();
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      final pending = controller.understandInput(
        input: controller.createUnderstandingInput(prompt: '准备方案'),
        requestId: 'cancel-network',
      );
      final failure = expectLater(pending, throwsA(_canceled));
      controller.cancelUnderstanding();
      repository.responses.single.completeError(
        const RepositoryException('网络已断开', offline: true),
      );
      await failure;
      expect(controller.understanding, isFalse);
    },
  );

  test('provider failure stays visible and retry keeps the persisted request identity', () async {
    final repository = _UnderstandingStore();
    final first = await _controller(repository);
    final input = first.createUnderstandingInput(
      prompt: '原始输入：下周要评审',
      notes: '原始说明',
      previous: {
        ..._answer.toJson(),
        'clarificationAnswers': {'deadline': '还没确定'},
      },
    );
    await first.savePlanningSession(
      PlanningSession(
        id: 'saved-session',
        updatedAt: _now,
        prompt: input['prompt'] as String,
        notes: input['notes'] as String,
        stage: 'understanding',
        understandingInput: input,
        understandingRequestId: 'persisted-request',
        clarificationAnswers: const {'deadline': '还没确定'},
      ),
    );
    first.dispose();
    final reopened = await _controller(repository);
    addTearDown(reopened.dispose);
    final session = reopened.planningSession('saved-session')!;
    expect(session.prompt, '原始输入：下周要评审');
    expect(session.deadline, isNull);
    expect(session.clarificationAnswers, {'deadline': '还没确定'});
    final failed = reopened.understandInput(
      input: session.understandingInput!,
      requestId: session.understandingRequestId!,
    );
    final failure = expectLater(
      failed,
      throwsA(
        isA<RepositoryException>().having(
          (e) => e.message,
          'message',
          '服务暂不可用',
        ),
      ),
    );
    repository.responses.single.completeError(
      const RepositoryException('服务暂不可用'),
    );
    await failure;
    expect(reopened.understanding, isFalse);
    expect(reopened.planningSession('saved-session')!.prompt, session.prompt);
    final retried = reopened.understandInput(
      input: session.understandingInput!,
      requestId: session.understandingRequestId!,
    );
    expect(repository.requestIds, ['persisted-request', 'persisted-request']);
    expect(repository.requests.first, repository.requests.last);
    repository.responses.last.complete(_answer);
    await retried;
  });

  test(
    'disposed account cannot deliver its result into the next account',
    () async {
      final oldRepository = _UnderstandingStore();
      final old = await _controller(oldRepository);
      final pending = old.understandInput(
        input: old.createUnderstandingInput(prompt: '账户 A 私有输入'),
        requestId: 'same-request-id',
      );
      final canceled = expectLater(pending, throwsA(_canceled));
      old.dispose();
      final newRepository = _UnderstandingStore();
      final current = await _controller(newRepository, accountId: 'account-b');
      addTearDown(current.dispose);
      final next = current.understandInput(
        input: current.createUnderstandingInput(prompt: '账户 B 私有输入'),
        requestId: 'same-request-id',
      );
      oldRepository.stages.single?.call('A 迟到的状态');
      oldRepository.responses.single.complete(_answer);
      await canceled;
      expect(current.understanding, isTrue);
      expect(newRepository.requests.single['prompt'], '账户 B 私有输入');
      expect(current.data.planningSessions, isEmpty);
      expect(current.data.tasks, isEmpty);
      newRepository.responses.single.complete(_answer);
      await next;
      await expectLater(
        old.understandInput(
          input: oldRepository.requests.single,
          requestId: 'closed',
        ),
        throwsA(isA<RepositoryException>()),
      );
      expect(oldRepository.requests, hasLength(1));
    },
  );

  test('clearing history cancels pending understanding and prevents result delivery', () async {
    final repository = _UnderstandingStore();
    final controller = await _controller(repository);
    addTearDown(controller.dispose);
    await controller.savePlanningSession(
      PlanningSession(id: 'old', updatedAt: _now, prompt: '旧输入'),
    );
    final pending = controller.understandInput(
      input: controller.createUnderstandingInput(prompt: '旧输入'),
      requestId: 'history-clear',
    );
    final canceled = expectLater(pending, throwsA(_canceled));
    await controller.clearPlanningHistory();
    repository.responses.single.complete(_answer);
    await canceled;
    expect(repository.value.planningSessions, isEmpty);
    expect(controller.data.planningSessions, isEmpty);
    expect(controller.understanding, isFalse);
  });

  test('queued session save preserves answers and request before caller edits maps', () async {
    final repository = _UnderstandingStore();
    final controller = await _controller(repository);
    addTearDown(controller.dispose);
    final gate = Completer<void>();
    repository.saveGate = gate;
    final answers = <String, String>{'date': '待定'};
    final input = controller.createUnderstandingInput(prompt: '原始输入');
    final pending = controller.savePlanningSession(
      PlanningSession(
        id: 'queued-session',
        updatedAt: _now,
        prompt: '原始输入',
        clarificationAnswers: answers,
        understandingInput: input,
        understandingRequestId: 'queued-request',
      ),
    );
    answers['date'] = '后来更改';
    input['prompt'] = '后来更改';
    gate.complete();
    await pending;
    final saved = repository.value.planningSessions.single;
    expect(saved.clarificationAnswers, {'date': '待定'});
    expect(saved.understandingInput!['prompt'], '原始输入');
    expect(saved.deadline, isNull);
  });
}
