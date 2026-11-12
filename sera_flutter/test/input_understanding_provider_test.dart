import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/data/planning_ai_provider.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';

Json _result() => {
  'intent': 'goal',
  'title': '练习英语口语',
  'summary': '想更自然地与同事用英语交流',
  'outcome': '能独立完成日常工作沟通',
  'deadline': null,
  'deadlineIsDateOnly': false,
  'dailyBudget': null,
  'estimatedMinutes': null,
  'start': null,
  'end': null,
  'questions': [
    {'id': 'deadline', 'question': '你希望何时达到这个目标？'},
  ],
  'source': 'siliconflow',
  'model': 'contract-test-model',
};

void main() {
  test('all model intents preserve unknown dates and durations as null', () {
    for (final intent in ['goal', 'task', 'event', 'other']) {
      final interpretation = AiUnderstanding.fromJson({
        ..._result(),
        'intent': intent,
      });
      expect(interpretation.intent, intent);
      expect(interpretation.deadline, isNull);
      expect(interpretation.start, isNull);
      expect(interpretation.end, isNull);
      expect(interpretation.dailyBudget, isNull);
      expect(interpretation.estimatedMinutes, isNull);
      expect(interpretation.toJson()['deadline'], isNull);
      expect(interpretation.questions.single.id, 'deadline');
    }
  });

  test('explicit dates retain their instant and date-only precision', () {
    final interpretation = AiUnderstanding.fromJson({
      ..._result(),
      'deadline': '2026-11-06T23:59:00+08:00',
      'deadlineIsDateOnly': true,
      'dailyBudget': 60,
    });
    final reopened = AiUnderstanding.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(jsonEncode(interpretation.toJson())) as Map,
      ),
    );
    expect(reopened.deadline, DateTime.utc(2026, 11, 6, 15, 59));
    expect(reopened.deadlineIsDateOnly, isTrue);
    expect(reopened.dailyBudget, 60);
  });

  test(
    'untrusted source, empty title or model and oversized text are rejected',
    () {
      for (final change in <Json>[
        {'source': 'local-template'},
        {'source': null},
        {'intent': 'keyword-guess'},
        {'title': '  '},
        {'model': '  '},
        {'title': '名' * 201},
        {'summary': '摘' * 1001},
        {'outcome': '果' * 2001},
      ]) {
        expect(
          () => AiUnderstanding.fromJson({..._result(), ...change}),
          throwsA(isA<RepositoryException>()),
          reason: '$change',
        );
      }
    },
  );

  test('timestamps require a real calendar date, valid clock and timezone', () {
    for (final invalid in [
      '2026-11-06',
      '2026-11-06T15:00:00',
      '2026-02-29T15:00:00Z',
      '2026-02-31T15:00:00+08:00',
      '2026-13-01T15:00:00Z',
      '2026-11-06T24:00:00Z',
      '2026-11-06T15:60:00Z',
      '2026-11-06T15:00:60Z',
      '2026-11-06T15:00:00+24:00',
      '2026-11-06T15:00:00+08:60',
      '0000-11-06T15:00:00Z',
    ]) {
      expect(
        () => AiUnderstanding.fromJson({..._result(), 'deadline': invalid}),
        throwsA(isA<RepositoryException>()),
        reason: invalid,
      );
    }
    expect(
      AiUnderstanding.fromJson({
        ..._result(),
        'deadline': '2028-02-29T10:30:00.123456-05:30',
      }).deadline,
      DateTime.utc(2028, 2, 29, 16, 0, 0, 123, 456),
    );
  });

  test('date precision, event ordering and time budgets follow the server contract', () {
    for (final change in <Json>[
      {'deadlineIsDateOnly': true},
      {'deadlineIsDateOnly': 'true'},
      {'start': '2026-11-06T12:00:00Z', 'end': '2026-11-06T12:00:00Z'},
      {'start': '2026-11-06T12:00:00Z', 'end': '2026-11-06T11:00:00Z'},
      {'dailyBudget': 14},
      {'dailyBudget': 481},
      {'dailyBudget': 60.5},
      {'estimatedMinutes': 4},
      {'estimatedMinutes': 481},
    ]) {
      expect(
        () => AiUnderstanding.fromJson({..._result(), ...change}),
        throwsA(isA<RepositoryException>()),
        reason: '$change',
      );
    }
    final partialEvent = AiUnderstanding.fromJson({
      ..._result(),
      'intent': 'event',
      'start': '2026-11-06T12:00:00Z',
      'end': null,
    });
    expect(partialEvent.start, isNotNull);
    expect(partialEvent.end, isNull);
  });

  test(
    'clarification questions must be bounded, nonempty and uniquely identified',
    () {
      for (final questions in [
        [
          {'id': 'date', 'question': '日期？'},
          {'id': 'date', 'question': '再次日期？'},
        ],
        [
          {'id': 'bad id', 'question': '日期？'},
        ],
        [
          {'id': 'date', 'question': '  '},
        ],
        [
          {'id': 'date', 'question': '问' * 301},
        ],
        [
          for (var i = 0; i < 4; i++) {'id': 'q$i', 'question': '问题$i'},
        ],
      ]) {
        expect(
          () =>
              AiUnderstanding.fromJson({..._result(), 'questions': questions}),
          throwsA(isA<RepositoryException>()),
        );
      }
    },
  );

  test('session persistence keeps original input, frozen request and clarification answers', () {
    const prompt = '  想把英语口语练好\n还没想好截止日  ';
    final input = <String, dynamic>{
      'prompt': prompt.trim(),
      'referenceNow': '2026-10-31T21:15:00+08:00',
      'timeZone': 'Asia/Hong_Kong',
      'dailyBudget': 90,
      'previous': {
        'understanding': _result(),
        'clarificationAnswers': {'deadline': '不设截止日'},
      },
    };
    final workspace = Workspace(
      planningSessions: [
        PlanningSession(
          id: 'session-a',
          updatedAt: DateTime.utc(2026, 10, 31, 13, 15),
          prompt: prompt,
          stage: 'understanding',
          understanding: _result(),
          understandingRequestId: 'stable-understanding-request',
          understandingInput: input,
          clarificationAnswers: const {'deadline': '不设截止日'},
        ),
      ],
    );
    final reopened = Workspace.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(jsonEncode(workspace.toJson())) as Map,
      ),
    ).planningSessions.single;
    expect(reopened.prompt, prompt);
    expect(reopened.deadline, isNull);
    expect(reopened.understandingRequestId, 'stable-understanding-request');
    expect(reopened.understandingInput, input);
    expect(reopened.clarificationAnswers, {'deadline': '不设截止日'});
    expect(reopened.understanding, _result());
    final canceled = reopened.copyWith(
      stage: 'canceled',
      clearUnderstandingRequest: true,
    );
    expect(canceled.understandingRequestId, isNull);
    expect(canceled.understandingInput, isNull);
    expect(canceled.prompt, prompt);
    expect(canceled.clarificationAnswers, reopened.clarificationAnswers);
  });

  test('a revised interpretation can clear a previously known deadline', () {
    final session = PlanningSession(
      id: 's',
      updatedAt: DateTime.utc(2026, 10, 31),
      deadline: DateTime.utc(2026, 11, 6),
      deadlineIsDateOnly: true,
    );
    final revised = session.copyWith(clearDeadline: true);
    expect(revised.deadline, isNull);
    expect(revised.deadlineIsDateOnly, isFalse);
    expect(session.deadline, isNotNull);
  });
}
