import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/domain/seed_data.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _SuggestionStore implements WorkspaceRepository {
  _SuggestionStore(this.value);
  Workspace? value;
  int writes = 0;
  @override
  String get mode => 'suggestion-test';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async => value = null;
  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    if (value?.revision != expectedRevision) {
      throw const RepositoryException('版本冲突', conflict: true);
    }
    writes++;
    return value = next.copyWith(revision: expectedRevision + 1);
  }
}

Future<void> _pump(
  WidgetTester tester,
  SeraController c,
  String path,
  Map<String, String> suggestion,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    SeraApp(
      key: UniqueKey(),
      controller: c,
      initialLocation: Uri(path: path, queryParameters: suggestion).toString(),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester, String label) async {
  final button = find.widgetWithText(SeraButton, label);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  final today = DateTime(2026, 10, 28);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets(
    'AI task with a date-only deadline stays in the inbox until confirmed',
    (tester) async {
      final store = _SuggestionStore(const Workspace(revision: 1));
      final c = SeraController(repository: store, today: today);
      await c.initialize();
      final initialWrites = store.writes;
      await _pump(tester, c, '/19', {
        'title': '核对课程材料',
        'notes': '确认图表和 API 演示可以运行。',
        'estimatedMinutes': '35',
        'dueDate': '2026-11-02',
      });
      expect(find.text('来自AI的建议，请核对后保存'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller!
            .text,
        '核对课程材料',
      );
      expect(c.data.tasks, isEmpty);
      expect(store.writes, initialWrites);
      await _save(tester, '保存任务');
      final saved = c.data.tasks.single;
      expect(saved.title, '核对课程材料');
      expect(saved.estimatedMinutes, 35);
      expect(saved.dueDate, '2026-11-02');
      expect(saved.dueAt, isNull);
      expect(c.entriesForTask(saved.id), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  testWidgets('AI task time range saves the reviewed wall-clock schedule', (
    tester,
  ) async {
    final store = _SuggestionStore(const Workspace(revision: 1));
    final c = SeraController(repository: store, today: today);
    await c.initialize();
    await _pump(tester, c, '/19', {
      'title': '检查展示流程',
      'estimatedMinutes': '30',
      'start': '2026-11-02T02:00:00Z',
      'end': '2026-11-02T02:45:00Z',
      'dueAt': '2026-11-02T12:00:00+08:00',
    });
    expect(c.data.entries, isEmpty);
    expect(
      tester
          .widget<TextFormField>(find.byType(TextFormField).at(2))
          .controller!
          .text,
      '45',
    );
    await _save(tester, '保存任务');
    final task = c.data.tasks.single;
    final block = c.entriesForTask(task.id).single;
    expect(task.estimatedMinutes, 45);
    expect(block.start.hour, 10);
    expect(block.end.hour, 10);
    expect(block.end.minute, 45);
    expect(block.start.toUtc(), DateTime.utc(2026, 11, 2, 2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets(
    'AI fixed event requires save and preserves supplied dates and notes',
    (tester) async {
      final store = _SuggestionStore(const Workspace(revision: 1));
      final c = SeraController(repository: store, today: today);
      await c.initialize();
      final initialWrites = store.writes;
      await _pump(tester, c, '/16', {
        'title': '课程答辩',
        'notes': '带好 Android 设备。',
        'start': '2026-11-02T09:00:00+08:00',
        'end': '2026-11-02T10:00:00+08:00',
      });
      expect(c.data.entries, isEmpty);
      expect(store.writes, initialWrites);
      expect(find.text('来自AI的建议，请核对后保存'), findsOneWidget);
      await _save(tester, '保存日程');
      final event = c.data.entries.single;
      expect(event.title, '课程答辩');
      expect(event.notes, '带好 Android 设备。');
      expect(event.start.hour, 9);
      expect(event.end.hour, 10);
      expect(event.locked, isTrue);
      expect(event.taskId, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  testWidgets(
    'invalid suggestion values leave editable defaults and never write',
    (tester) async {
      final store = _SuggestionStore(const Workspace(revision: 1));
      final c = SeraController(repository: store, today: today);
      await c.initialize();
      final initialWrites = store.writes;
      await _pump(tester, c, '/19', {
        'title': List.filled(201, '长').join(),
        'notes': List.filled(10001, '长').join(),
        'estimatedMinutes': '9999999',
        'dueDate': '2026-02-30',
        'start': 'javascript:alert(1)',
        'end': '2026-11-02T25:00:00Z',
      });
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller!
            .text,
        isEmpty,
      );
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).at(1))
            .controller!
            .text,
        isEmpty,
      );
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).at(2))
            .controller!
            .text,
        '30',
      );
      await _save(tester, '保存任务');
      expect(find.text('请写下一个可以行动的任务'), findsOneWidget);
      expect(c.data.tasks, isEmpty);
      expect(store.writes, initialWrites);
      await tester.enterText(find.byType(TextFormField).first, '手动补充有效任务');
      await _save(tester, '保存任务');
      expect(c.data.tasks.single.deadline, isNull);
      expect(c.data.entries, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  testWidgets('AI event without complete times requires explicit review', (
    tester,
  ) async {
    final store = _SuggestionStore(const Workspace(revision: 1));
    final c = SeraController(repository: store, today: today);
    await c.initialize();
    final initialWrites = store.writes;
    await _pump(tester, c, '/16', {
      'fromAi': '1',
      'requiresTimeConfirmation': '1',
      'title': '约同学讨论',
    });
    await _save(tester, '保存日程');
    expect(c.data.entries, isEmpty);
    expect(store.writes, initialWrites);
    expect(find.text('请确认起止时间后再保存。'), findsOneWidget);
    final confirmation = find.widgetWithText(CheckboxListTile, '我已核对起止时间');
    await tester.ensureVisible(confirmation);
    await tester.tap(confirmation);
    await tester.pumpAndSettle();
    await _save(tester, '保存日程');
    expect(c.data.entries.single.title, '约同学讨论');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  for (final event in [false, true]) {
    testWidgets(
      'AI query cannot replace an existing ${event ? 'event' : 'task'}',
      (tester) async {
        final original = createSeedWorkspace(today).copyWith(revision: 1);
        final store = _SuggestionStore(original);
        final c = SeraController(repository: store, today: today);
        await c.initialize();
        final initialWrites = store.writes;
        await _pump(tester, c, event ? '/16' : '/09', {
          event ? 'eventId' : 'taskId': event ? 'meeting-1' : 'task-1',
          'title': '不得覆盖原对象',
          'notes': '不得替换原有说明',
          'estimatedMinutes': '99',
          'start': '2026-11-02T14:00:00+08:00',
          'end': '2026-11-02T15:00:00+08:00',
        });
        final expectedTitle = event
            ? c.entry('meeting-1')!.title
            : c.task('task-1')!.title;
        expect(
          tester
              .widget<TextFormField>(find.byType(TextFormField).first)
              .controller!
              .text,
          expectedTitle,
        );
        expect(find.text('来自AI的建议，请核对后保存'), findsNothing);
        expect(store.writes, initialWrites);
        expect(c.data.toJson(), original.toJson());
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
      },
    );
  }
}
