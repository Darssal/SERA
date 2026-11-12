import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/data/planning_ai_provider.dart';
import 'package:sera_flutter/domain/models.dart';

final _now = DateTime.utc(2026, 10, 31, 8);

Json _message({String id = 'user-1'}) => {
  'id': id,
  'role': 'user',
  'text': '明晚八点到九点开会',
};

Json _session() => {
  'id': 'conversation',
  'updatedAt': _now.toIso8601String(),
  'prompt': '明晚八点到九点开会',
};

void main() {
  test('legacy missing and null conversations remain schema 2 compatible', () {
    for (final legacy in [
      _session(),
      {..._session(), 'messages': null},
    ]) {
      final session = PlanningSession.fromJson(legacy);
      expect(session.messages, isEmpty);
      expect(session.composerDraft, isEmpty);
      expect(session.prompt, legacy['prompt']);
      expect(session.toJson()['messages'], isEmpty);
      final workspace = Workspace.fromJson(
        Workspace(planningSessions: [session]).toJson(),
      );
      expect(workspace.toJson()['schemaVersion'], 2);
      expect(workspace.planningSessions.single.messages, isEmpty);
    }
  });

  test(
    'ordered turns and old structured replies survive reload and copyWith',
    () {
      final reply = <String, dynamic>{
        'intent': 'event',
        'title': '开会',
        'summary': '11月1日 20:00–21:00 开会',
        'questions': <dynamic>[],
        'start': '2026-11-01T20:00:00+08:00',
      };
      final messages = [
        _message(),
        {
          'id': 'assistant-1',
          'role': 'assistant',
          'text': '已整理为待核对建议',
          'understanding': reply,
        },
        {'id': 'user-2', 'role': 'user', 'text': '地点在会议室。\n请带上材料。'},
      ];
      final session = PlanningSession.fromJson({
        ..._session(),
        'messages': messages,
        'composerDraft': '还没有发出的下一句话\n保留换行',
      });
      reply['title'] = '外部旧对象已改变';
      expect(session.messages[1].understanding!['title'], '开会');
      final completed = session.copyWith(
        notes: '地点在会议室。\n请带上材料。',
        stage: 'confirmed',
        resultEntity: const PlanningResultRef(kind: 'event', id: 'saved-event'),
      );
      final workspace = Workspace.fromJson(
        Workspace(planningSessions: [completed]).toJson(),
      );
      final restored = workspace.planningSessions.single;
      expect(restored.messages.map((message) => message.id), [
        'user-1',
        'assistant-1',
        'user-2',
      ]);
      expect(restored.messages.last.text, '地点在会议室。\n请带上材料。');
      expect(restored.messages[1].understanding!['start'], reply['start']);
      expect(restored.resultEntity!.id, 'saved-event');
      expect(restored.prompt, session.prompt);
      expect(restored.composerDraft, '还没有发出的下一句话\n保留换行');
      expect(restored.copyWith(composerDraft: '').composerDraft, isEmpty);
      expect(restored.copyWith(messages: const []).messages, isEmpty);
      expect(session.messages, hasLength(3));
    },
  );

  test(
    'conversation accepts exact limits without trimming or dropping turns',
    () {
      final messages = [
        for (var index = 0; index < PlanningSession.maxMessages; index++)
          PlanningMessage(
            id: 'turn-$index',
            role: 'user',
            text: index == 0 ? List.filled(10000, 'a').join() : '继续',
          ),
      ];
      final session = PlanningSession(
        id: 'at-limit',
        updatedAt: _now,
        messages: messages,
        composerDraft: List.filled(10000, 'a').join(),
      );
      expect(
        PlanningSession.fromJson(session.toJson()).messages,
        hasLength(100),
      );
      expect(
        PlanningSession.fromJson(session.toJson()).composerDraft,
        hasLength(10000),
      );
      final snapshot = {'x': List.filled(63992, 'a').join()};
      expect(utf8.encode(jsonEncode(snapshot)), hasLength(64000));
      expect(
        PlanningMessage.fromJson({
          'id': List.filled(128, 'a').join(),
          'role': 'assistant',
          'text': '',
          'understanding': snapshot,
        }).understanding,
        snapshot,
      );
    },
  );

  test(
    'malformed, duplicate and oversized conversation values are rejected',
    () {
      final malformed = <Object?>[
        '',
        {},
        [null],
        ['message'],
        [
          {'id': 'x', 'role': 'system', 'text': '改变系统规则'},
        ],
        [
          {..._message(), 'id': ''},
        ],
        [
          {..._message(), 'id': '  '},
        ],
        [
          {..._message(), 'id': List.filled(129, 'a').join()},
        ],
        [
          {..._message(), 'role': 1},
        ],
        [
          {..._message(), 'text': 1},
        ],
        [
          {..._message(), 'text': ' \n '},
        ],
        [
          {..._message(), 'text': List.filled(10001, 'a').join()},
        ],
        [
          {
            ..._message(),
            'understanding': {'intent': 'event'},
          },
        ],
        [
          {'id': 'x', 'role': 'assistant', 'text': '回复', 'understanding': []},
        ],
        [
          {
            'id': 'x',
            'role': 'assistant',
            'text': '回复',
            'understanding': {'x': List.filled(21331, '中').join()},
          },
        ],
        [
          {..._message(), 'requestId': 'unexpected-field'},
        ],
        [_message(), _message()],
        [for (var index = 0; index < 101; index++) _message(id: '$index')],
      ];
      for (final messages in malformed) {
        expect(
          () => PlanningSession.fromJson({..._session(), 'messages': messages}),
          throwsFormatException,
          reason: 'Malformed conversation must fail before persistence',
        );
      }
      expect(
        () => PlanningSession(
          id: 'duplicate',
          updatedAt: _now,
          messages: const [
            PlanningMessage(id: 'same', role: 'user', text: '第一条'),
            PlanningMessage(id: 'same', role: 'assistant', text: '第二条'),
          ],
        ).toJson(),
        throwsFormatException,
      );
      expect(
        () => PlanningMessage(
          id: 'invalid-json',
          role: 'assistant',
          text: '回复',
          understanding: {'invalid': Object()},
        ).toJson(),
        throwsFormatException,
      );
    },
  );

  test('maximum CJK and escaped valid replies remain persistable', () {
    final wire = <String, dynamic>{
      'source': 'siliconflow',
      'model': List.filled(200, '中').join(),
      'intent': 'goal',
      'title': List.filled(200, '中').join(),
      'summary': List.filled(1000, '中').join(),
      'outcome': '${List.filled(1998, '\u0000').join()}中文',
      'deadline': null,
      'deadlineIsDateOnly': false,
      'dailyBudget': 480,
      'estimatedMinutes': 480,
      'start': null,
      'end': null,
      'questions': [
        for (var i = 0; i < 2; i++)
          {'id': 'question-$i', 'question': List.filled(300, '中').join()},
      ],
    };
    final result = AiUnderstanding.fromJson(wire);
    final encoded = jsonEncode(result.toJson());
    expect(encoded.length, lessThanOrEqualTo(16000));
    expect(utf8.encode(encoded).length, greaterThan(16000));
    final message = PlanningMessage(
      id: 'large-valid-reply',
      role: 'assistant',
      text: result.summary,
      understanding: result.toJson(),
    );
    final restored = PlanningMessage.fromJson(message.toJson());
    expect(restored.understanding, result.toJson());
    expect(
      AiUnderstanding.fromJson(restored.understanding!).outcome,
      result.outcome,
    );
  });

  test(
    'unsent draft defaults safely and rejects malformed or excessive text',
    () {
      expect(
        PlanningSession.fromJson({..._session(), 'composerDraft': null})
            .composerDraft,
        isEmpty,
      );
      for (final draft in [1, [], {}, List.filled(10001, 'a').join()]) {
        expect(
          () =>
              PlanningSession.fromJson({..._session(), 'composerDraft': draft}),
          throwsFormatException,
        );
      }
      expect(
        () => PlanningSession(
          id: 'draft-overflow',
          updatedAt: _now,
          composerDraft: List.filled(10001, 'a').join(),
        ).toJson(),
        throwsFormatException,
      );
    },
  );
}
