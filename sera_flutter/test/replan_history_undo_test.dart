import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';

final _now = readZoned('2026-11-02T09:00:00+08:00', 'Asia/Hong_Kong')!;
DateTime _at(int day, int minute) => atMinute(calendarDay(_now, day), minute);
Workspace _workspace() => Workspace(
  revision: 1,
  preferences: const SeraPreferences(
    dailyBudget: 15,
    startMinute: 540,
    endMinute: 660,
    bufferMinutes: 15,
    restStart: 0,
    restEnd: 0,
  ),
  tasks: const [
    SeraTask(
      id: 'task',
      title: '整理考试范围',
      estimatedMinutes: 30,
      splittable: true,
      minBlockMinutes: 15,
    ),
  ],
  entries: [
    CalendarEntry(
      id: 'today-block',
      taskId: 'task',
      title: '整理考试范围',
      start: _at(0, 540),
      end: _at(0, 555),
    ),
    CalendarEntry(
      id: 'sibling-block',
      taskId: 'task',
      title: '整理考试范围',
      start: _at(1, 540),
      end: _at(1, 555),
    ),
  ],
);

class _Store implements WorkspaceRepository {
  Workspace value = _workspace();
  int writes = 0;
  Completer<void>? nextSaveGate;
  @override
  String get mode => 'replan-history-isolated';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async {}
  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    final gate = nextSaveGate;
    nextSaveGate = null;
    if (gate != null) await gate.future;
    if (expectedRevision != value.revision) {
      throw const RepositoryException('已有后续修改，请刷新。', conflict: true);
    }
    writes++;
    return value = Workspace.fromJson(
      next.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }
}

Finder _button(String label) => find.widgetWithText(SeraButton, label);
Finder _undo() => find.widgetWithText(TextButton, '撤销这次调整');
Finder _undoFeedback() => find.widgetWithText(SnackBarAction, '撤销');
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await _frames(tester);
}

Future<SeraController> _mount(WidgetTester tester, _Store store) async {
  final c = SeraController(repository: store, today: _now, seedDemo: false);
  await c.initialize();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
  await tester.pumpWidget(SeraApp(controller: c, initialLocation: '/04'));
  await _frames(tester);
  return c;
}

Future<void> _applyTodayAdjustment(WidgetTester tester) async {
  await _tap(tester, find.text('日程'));
  await _tap(tester, find.byTooltip('调整安排'));
  await _tap(tester, _button('查看变更并确认'));
  await _tap(tester, _button('确认调整 1 项任务'));
  expect(find.widgetWithText(AppBar, '日程'), findsOneWidget);
  expect(find.widgetWithText(AppBar, '调整完成'), findsNothing);
  expect(find.text('安排已调整'), findsOneWidget);
  expect(_undoFeedback(), findsOneWidget);
}

Future<void> _openOperationHistory(WidgetTester tester) async {
  await _tap(tester, find.text('今日').last);
  await _tap(tester, find.byKey(const ValueKey('today-capture')));
  await _tap(tester, find.text('文字输入'));
  await _tap(tester, _button('让 AI 安排'));
  await _tap(tester, find.byTooltip('规划记录'));
  await _tap(tester, find.text('操作'));
}

Future<void> _applyAndOpenHistory(WidgetTester tester) async {
  await _applyTodayAdjustment(tester);
  await _openOperationHistory(tester);
  await _tap(tester, find.text('调整任务时间'));
  expect(find.byType(AlertDialog), findsOneWidget);
}

List<Json> _entries(SeraController c, {bool includeRevision = true}) => [
  for (final e in ([...c.data.entries]..sort((a, b) => a.id.compareTo(b.id))))
    if (includeRevision) e.toJson() else (e.toJson()..remove('revision')),
];

void main() {
  testWidgets(
    'result deep link cannot pair another task with the latest adjustment record',
    (tester) async {
      final store = _Store();
      store.value = store.value.copyWith(
        preferences: store.value.preferences.copyWith(dailyBudget: 60),
        tasks: [
          ...store.value.tasks,
          const SeraTask(
            id: 'other',
            title: '另一项任务',
            estimatedMinutes: 15,
            minBlockMinutes: 15,
          ),
        ],
        entries: [
          ...store.value.entries,
          CalendarEntry(
            id: 'other-block',
            taskId: 'other',
            title: '另一项任务',
            start: _at(0, 600),
            end: _at(0, 615),
          ),
        ],
      );
      final c = await _mount(tester, store);
      await c.applyReplan(
        'other',
        _at(0, 615),
        entryId: 'other-block',
        expectedEntryRevision: 1,
      );
      final changeId = c.data.history.single.id;
      await tester.pumpWidget(
        SeraApp(
          key: UniqueKey(),
          controller: c,
          initialLocation:
              '/52?taskId=task&entryId=today-block&changeId=$changeId',
        ),
      );
      await _frames(tester);
      expect(find.widgetWithText(AppBar, '调整完成'), findsOneWidget);
      expect(find.text('整理考试范围'), findsOneWidget);
      expect(_button('撤销最近一次调整'), findsNothing);
      expect(c.data.history.single.undone, isFalse);
      expect(c.entry('other-block')!.start, _at(0, 615));
      expect(c.entry('today-block')!.start, _at(0, 540));
      expect(store.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'returned page feedback undoes only its own adjustment on double activation',
    (tester) async {
      final store = _Store();
      final c = await _mount(tester, store);
      await c.saveTask(c.task('task')!.copyWith(notes: '必须保留的先前操作'));
      await _frames(tester);
      await _applyTodayAdjustment(tester);
      final callback = tester.widget<SnackBarAction>(_undoFeedback()).onPressed;
      final gate = Completer<void>();
      store.nextSaveGate = gate;
      final writes = store.writes;
      callback();
      callback();
      await _frames(tester);
      gate.complete();
      await tester.pumpAndSettle();
      expect(store.writes, writes + 1);
      expect(c.data.history.last.undone, isTrue);
      expect(c.data.history.first.undone, isFalse);
      expect(c.task('task')!.notes, '必须保留的先前操作');
      expect(c.entry('today-block')!.start, _at(0, 540));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('returned page undo preserves a newer unrelated task note', (
    tester,
  ) async {
    final store = _Store();
    final c = await _mount(tester, store);
    await _applyTodayAdjustment(tester);
    final callback = tester.widget<SnackBarAction>(_undoFeedback()).onPressed;
    await c.saveTask(c.task('task')!.copyWith(notes: '回到今日后的新操作'));
    await _frames(tester);
    expect(_undoFeedback(), findsOneWidget);
    final writes = store.writes;
    callback();
    await _frames(tester);
    expect(store.writes, writes + 1);
    expect(c.task('task')!.notes, '回到今日后的新操作');
    expect(c.entry('today-block')!.start, _at(0, 540));
    expect(c.entry('today-block')!.revision, 3);
    expect(c.data.history.first.undone, isTrue);
    expect(c.data.history.last.undone, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'captured adjustment feedback cannot undo after a workspace switch',
    (tester) async {
      final store = _Store();
      final c = await _mount(tester, store);
      await _applyTodayAdjustment(tester);
      final callback = tester.widget<SnackBarAction>(_undoFeedback()).onPressed;
      final originalWrites = store.writes;
      final adjustedStart = c.entry('today-block')!.start;
      final nextStore = _Store();
      final nextController = SeraController(
        repository: nextStore,
        today: _now,
        seedDemo: false,
      );
      await nextController.initialize();
      addTearDown(nextController.dispose);
      await tester.pumpWidget(
        SeraApp(
          key: UniqueKey(),
          controller: nextController,
          initialLocation: '/04',
        ),
      );
      await _frames(tester);

      callback();
      await _frames(tester);
      expect(store.writes, originalWrites);
      expect(nextStore.writes, 0);
      expect(c.data.history.single.undone, isFalse);
      expect(c.entry('today-block')!.start, adjustedStart);
      expect(nextController.entry('today-block')!.start, _at(0, 540));
      expect(find.widgetWithText(AppBar, '今日'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'applied adjustment can be undone through history after returning to its origin',
    (tester) async {
      final store = _Store();
      final c = await _mount(tester, store);
      final original = _entries(c, includeRevision: false);
      final tasks = c.data.tasks.map((e) => e.toJson()).toList();
      await _applyAndOpenHistory(tester);
      expect(c.entry('today-block')!.start, isNot(_at(0, 540)));
      expect(find.textContaining('开始：11月2日 周一 09:00'), findsOneWidget);
      expect(find.textContaining('开始：11月2日 周一 09:15'), findsOneWidget);
      expect(
        find.textContaining(RegExp(r'\d{4}-\d{2}-\d{2}T.*Z')),
        findsNothing,
      );
      final summaryScroll = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(SingleChildScrollView),
      );
      expect(tester.getSize(summaryScroll).height, lessThan(420));
      expect(_undo(), findsOneWidget);
      await _tap(tester, _undo());
      expect(_entries(c, includeRevision: false), original);
      expect(c.entry('today-block')!.revision, 3);
      expect(c.entry('sibling-block')!.revision, 1);
      expect(c.data.tasks.map((e) => e.toJson()).toList(), tasks);
      expect(c.data.history.single.undone, isTrue);
      expect(_undo(), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('已撤销'), findsWidgets);
      await _tap(tester, find.text('调整任务时间'));
      expect(_undo(), findsNothing);
      expect(find.textContaining('已撤销'), findsWidgets);
      expect(store.value.history.single.undone, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('history timestamps use workspace local dates across midnight', (
    tester,
  ) async {
    final store = _Store();
    final original = CalendarEntry(
      id: 'midnight',
      title: '跨午夜安排',
      start: DateTime.parse('2026-11-02T15:50:00Z'),
      end: DateTime.parse('2026-11-02T16:05:00Z'),
    );
    final updated = original.copyWith(
      start: DateTime.parse('2026-11-02T16:10:00Z'),
      end: DateTime.parse('2026-11-02T16:25:00Z'),
    );
    store.value = store.value.copyWith(
      entries: [updated],
      history: [
        ChangeRecord(
          id: 'midnight-change',
          label: '保存日程',
          at: DateTime.parse('2026-11-02T16:30:00Z'),
          before: {
            'entries': [original.toJson()],
          },
          after: {
            'entries': [updated.toJson()],
          },
        ),
      ],
    );
    await _mount(tester, store);
    await _openOperationHistory(tester);
    await _tap(tester, find.text('保存日程'));
    expect(find.textContaining('开始：11月2日 周一 23:50'), findsOneWidget);
    expect(find.textContaining('结束：11月3日 周二 00:05'), findsOneWidget);
    expect(find.textContaining('开始：11月3日 周二 00:10'), findsOneWidget);
    expect(find.textContaining('结束：11月3日 周二 00:25'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('11月3日 周二 00:30'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining(RegExp(r'\d{4}-\d{2}-\d{2}T.*Z')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'history undo remains available after a later unrelated write and preserves it',
    (tester) async {
      final store = _Store();
      final c = await _mount(tester, store);
      await _applyAndOpenHistory(tester);
      expect(_undo(), findsOneWidget);
      await c.saveTask(c.task('task')!.copyWith(notes: '后续补充，必须保留'));
      await _frames(tester);
      expect(_undo(), findsOneWidget);
      await _tap(tester, find.widgetWithText(TextButton, '关闭'));
      await _tap(tester, find.text('调整任务时间'));
      expect(_undo(), findsOneWidget);
      await _tap(tester, _undo());
      expect(find.byType(AlertDialog), findsNothing);
      expect(c.entry('today-block')!.start, _at(0, 540));
      expect(c.task('task')!.notes, '后续补充，必须保留');
      expect(c.data.history.first.undone, isTrue);
      expect(c.data.history.last.undone, isFalse);
      await _tap(tester, find.text('保存任务'));
      expect(
        _undo(),
        findsNothing,
        reason: 'Only adjustment records gain this action.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'double activation cannot undo an earlier operation after the adjustment',
    (tester) async {
      final store = _Store();
      final c = await _mount(tester, store);
      await c.saveTask(c.task('task')!.copyWith(notes: '调整前的备注'));
      await _frames(tester);
      await _applyAndOpenHistory(tester);
      final callback = tester.widget<TextButton>(_undo()).onPressed!;
      final gate = Completer<void>();
      store.nextSaveGate = gate;
      final beforeWrites = store.writes;
      // The same rendered callback can be delivered twice before a frame rebuild.
      callback();
      callback();
      await _frames(tester);
      expect(tester.widget<TextButton>(_undo()).onPressed, isNull);
      gate.complete();
      await tester.pumpAndSettle();
      expect(store.writes, beforeWrites + 1);
      expect(c.data.history.last.undone, isTrue);
      expect(c.data.history.first.undone, isFalse);
      expect(c.task('task')!.notes, '调整前的备注');
      expect(c.entry('today-block')!.start, _at(0, 540));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'repository version conflict preserves external changes and shows the error in the record',
    (tester) async {
      final store = _Store();
      final c = await _mount(tester, store);
      await _applyAndOpenHistory(tester);
      final remote = c
          .entry('today-block')!
          .copyWith(start: _at(0, 570), end: _at(0, 585), revision: 3);
      store.value = store.value.copyWith(
        revision: store.value.revision + 1,
        entries: [
          remote,
          ...store.value.entries.where((e) => e.id != remote.id),
        ],
      );
      await _tap(tester, _undo());
      expect(find.text('已有后续修改，请刷新。'), findsOneWidget);
      expect(
        store.value.entries.firstWhere((e) => e.id == remote.id).start,
        remote.start,
      );
      expect(store.value.history.single.undone, isFalse);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a covered record cannot apply a captured undo action', (
    tester,
  ) async {
    final store = _Store();
    final c = await _mount(tester, store);
    await _applyAndOpenHistory(tester);
    final callback = tester.widget<TextButton>(_undo()).onPressed!;
    final dialogContext = tester.element(find.byType(AlertDialog));
    unawaited(
      showDialog<void>(
        context: dialogContext,
        builder: (context) => AlertDialog(
          title: const Text('另一个页面'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('返回记录'),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final writes = store.writes;
    callback();
    await _frames(tester);
    expect(store.writes, writes);
    expect(c.data.history.single.undone, isFalse);
    await _tap(tester, find.widgetWithText(TextButton, '返回记录'));
    expect(_undo(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late successful undo does not dismiss a covering dialog', (
    tester,
  ) async {
    final store = _Store();
    final c = await _mount(tester, store);
    await _applyAndOpenHistory(tester);
    final gate = Completer<void>();
    store.nextSaveGate = gate;
    await _tap(tester, _undo());
    final dialogContext = tester.element(find.byType(AlertDialog));
    unawaited(
      showDialog<void>(
        context: dialogContext,
        builder: (context) => AlertDialog(
          title: const Text('上层页面仍应保留'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('返回记录'),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    gate.complete();
    await tester.pumpAndSettle();
    expect(c.data.history.single.undone, isTrue);
    expect(find.text('上层页面仍应保留'), findsOneWidget);
    await _tap(tester, find.widgetWithText(TextButton, '返回记录'));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('已撤销'), findsWidgets);
    expect(_undo(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
    'queued exact adjustment undo preserves the preceding unrelated write',
    () async {
      final store = _Store();
      final c = SeraController(repository: store, today: _now, seedDemo: false);
      await c.initialize();
      addTearDown(c.dispose);
      await c.applyReplan(
        'task',
        _at(0, 555),
        entryId: 'today-block',
        expectedEntryRevision: 1,
      );
      final recordId = c.data.history.single.id;
      final write = c.saveTask(c.task('task')!.copyWith(notes: '排队中的新操作'));
      final undo = c.undoLast(expectedRecordId: recordId);
      await write;
      expect(await undo, isTrue);
      expect(c.task('task')!.notes, '排队中的新操作');
      expect(c.entry('today-block')!.start, _at(0, 540));
      expect(c.entry('today-block')!.revision, 3);
      expect(c.data.history.first.undone, isTrue);
      expect(c.data.history.last.undone, isFalse);
      expect(store.writes, 3);
    },
  );
}
