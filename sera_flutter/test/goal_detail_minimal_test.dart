import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/sera_todo_row.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = readZoned('2026-11-08T09:00:00+08:00', 'Asia/Hong_Kong')!;

class _GoalStore implements WorkspaceRepository {
  _GoalStore(this.value);
  Workspace value;
  bool failNextSave = false;
  int writes = 0;
  @override
  String get mode => 'goal-detail-fixture';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async => value = const Workspace();
  @override
  Future<Workspace> save(
    Workspace workspace, {
    required int expectedRevision,
  }) async {
    if (failNextSave) {
      failNextSave = false;
      throw const RepositoryException('保存失败，请重试');
    }
    if (value.revision != expectedRevision) {
      throw const RepositoryException('版本冲突', conflict: true);
    }
    writes++;
    return value = Workspace.fromJson(
      workspace.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }
}

Workspace _workspace({int count = 1, bool scheduled = false}) {
  final tasks = List.generate(
    count,
    (index) => SeraTask(
      id: 'goal-task-$index',
      title: '目标任务 $index',
      goalId: 'goal',
      status: 'in_progress',
      estimatedMinutes: scheduled ? 120 : 30,
      actualSeconds: scheduled ? 30 : 0,
      splittable: scheduled,
    ),
  );
  return Workspace(
    revision: 1,
    goals: [
      SeraGoal(
        id: 'goal',
        title: '完成一个真实目标',
        outcome: '留下可查看的成果，并核对所有要求。',
        deadline: calendarDay(_now, 30),
        taskIds: tasks.map((task) => task.id).toList(),
      ),
    ],
    tasks: tasks,
    entries: scheduled
        ? List.generate(
            2,
            (index) => CalendarEntry(
              id: 'goal-block-$index',
              taskId: tasks.first.id,
              title: tasks.first.title,
              start: atMinute(calendarDay(_now, index + 1), 14 * 60),
              end: atMinute(calendarDay(_now, index + 1), 15 * 60),
            ),
          )
        : const [],
    focusSession: scheduled
        ? FocusSession(
            id: 'paused-focus',
            taskId: tasks.first.id,
            startedAt: _now,
            accumulatedSeconds: 73,
            isRunning: false,
          )
        : null,
  );
}

Future<SeraController> _mount(WidgetTester tester, _GoalStore store) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final c = SeraController(repository: store, today: _now, seedDemo: false);
  await c.initialize();
  await tester.pumpWidget(
    SeraApp(controller: c, initialLocation: '/21?goalId=goal'),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
  return c;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _editStatus(
  WidgetTester tester,
  String status, {
  bool save = true,
}) async {
  await _tap(tester, find.widgetWithText(SeraSettingRow, '修改目标信息'));
  await _tap(tester, find.byType(DropdownButtonFormField<String>));
  await _tap(tester, find.text(status).last);
  await _tap(tester, find.widgetWithText(TextButton, save ? '保存' : '取消'));
}

Finder _checkbox(String id) => find.descendant(
  of: find.byKey(ValueKey('goal-task:$id')),
  matching: find.byType(Checkbox),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'goal status edits are deliberate, cancellable and preserve linked work',
    (tester) async {
      final store = _GoalStore(_workspace());
      final c = await _mount(tester, store);
      final taskBefore = c.data.tasks.single.toJson();
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.widgetWithText(TextButton, '验收完成'), findsNothing);
      await _editStatus(tester, '暂停');
      expect(c.goal('goal')!.status, 'paused');
      await _editStatus(tester, '进行中', save: false);
      expect(c.goal('goal')!.status, 'paused');
      await _editStatus(tester, '进行中');
      expect(c.goal('goal')!.status, 'active');
      await _editStatus(tester, '归档');
      expect(c.goal('goal')!.status, 'archived');
      expect(c.data.tasks.single.toJson(), taskBefore);
      expect(store.value.goals.single.taskIds, ['goal-task-0']);
      final reopened = SeraController(
        repository: store,
        today: _now,
        seedDemo: false,
      );
      await reopened.initialize();
      expect(reopened.goal('goal')!.status, 'archived');
      reopened.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'goal task completion and undo restore future blocks without losing focus history',
    (tester) async {
      final store = _GoalStore(_workspace(scheduled: true));
      final c = await _mount(tester, store);
      final originalBlocks = c.data.entries.toList();
      await _tap(tester, _checkbox('goal-task-0'));
      expect(c.task('goal-task-0')!.done, isTrue);
      expect(c.data.entries, isEmpty);
      expect(c.data.focusSession, isNull);
      expect(c.data.focusRecords.single.seconds, 73);
      expect(c.goal('goal')!.status, 'active');
      await _tap(tester, find.widgetWithText(TextButton, '撤销完成'));
      expect(c.task('goal-task-0')!.status, 'in_progress');
      expect(c.task('goal-task-0')!.actualSeconds, 103);
      expect(c.data.focusRecords.single.seconds, 73);
      expect(c.data.focusSession, isNull);
      expect(c.data.entries, hasLength(2));
      for (final block in originalBlocks) {
        expect(c.entry(block.id)!.start, block.start);
        expect(c.entry(block.id)!.end, block.end);
        expect(c.entry(block.id)!.taskId, block.taskId);
      }
      expect(store.value.tasks.single.status, 'in_progress');
      expect(find.widgetWithText(TextButton, '撤销完成'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'finishing tasks does not accept the goal until the user confirms its outcome',
    (tester) async {
      final store = _GoalStore(_workspace());
      final c = await _mount(tester, store);
      await _tap(tester, _checkbox('goal-task-0'));
      expect(c.goal('goal')!.status, 'active');
      await _tap(tester, find.widgetWithText(TextButton, '验收完成'));
      expect(
        find.widgetWithText(AlertDialog, c.goal('goal')!.outcome),
        findsOneWidget,
      );
      await _tap(tester, find.widgetWithText(TextButton, '再看看'));
      expect(c.goal('goal')!.status, 'active');
      await _tap(tester, find.widgetWithText(TextButton, '验收完成'));
      await _tap(tester, find.widgetWithText(TextButton, '确认完成'));
      expect(c.goal('goal')!.status, 'completed');
      expect(store.value.goals.single.status, 'completed');
      expect(c.data.tasks, hasLength(1));
      expect(find.widgetWithText(TextButton, '验收完成'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a rejected goal completion remains retryable and never offers a false undo',
    (tester) async {
      final store = _GoalStore(_workspace(scheduled: true));
      final c = await _mount(tester, store);
      store.failNextSave = true;
      await _tap(tester, _checkbox('goal-task-0'));
      expect(c.task('goal-task-0')!.done, isFalse);
      expect(c.data.entries, hasLength(2));
      expect(c.data.focusSession, isNotNull);
      expect(find.widgetWithText(TextButton, '撤销完成'), findsNothing);
      ScaffoldMessenger.of(tester.element(find.byType(SeraScaffold)))
          .clearSnackBars();
      await tester.pumpAndSettle();
      await _tap(tester, _checkbox('goal-task-0'));
      expect(c.task('goal-task-0')!.done, isTrue);
      expect(c.data.focusRecords, hasLength(1));
      expect(c.data.entries, isEmpty);
      expect(find.widgetWithText(TextButton, '撤销完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large goal lists build visible rows and preserve object and scroll context after detail',
    (tester) async {
      final store = _GoalStore(_workspace(count: 240));
      final c = await _mount(tester, store);
      expect(find.byType(SeraTodoRow).evaluate().length, lessThan(30));
      final target = find.byKey(const ValueKey('goal-task:goal-task-80'));
      final scrollable = find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        target,
        500,
        scrollable: scrollable,
        maxScrolls: 40,
      );
      await tester.pumpAndSettle();
      final title = find.descendant(of: target, matching: find.text('目标任务 80'));
      // The title is inset within its row. Align it before measuring the
      // departure position so the tap helper does not introduce another scroll.
      await tester.ensureVisible(title);
      await tester.pumpAndSettle();
      final offset = tester.state<ScrollableState>(scrollable).position.pixels;
      expect(offset, greaterThan(0));
      await tester.tap(title);
      await tester.pumpAndSettle();
      final router = GoRouter.of(
        tester.element(find.byType(SeraScaffold).first),
      );
      expect(
        router.routeInformationProvider.value.uri.queryParameters['taskId'],
        'goal-task-80',
      );
      await _tap(tester, find.byTooltip('返回'));
      expect(
        router.routeInformationProvider.value.uri.queryParameters['goalId'],
        'goal',
      );
      expect(
        tester.state<ScrollableState>(scrollable).position.pixels,
        closeTo(offset, 1),
      );
      await _tap(tester, _checkbox('goal-task-80'));
      expect(c.task('goal-task-80')!.done, isTrue);
      expect(c.task('goal-task-79')!.done, isFalse);
      expect(c.task('goal-task-81')!.done, isFalse);
      expect(find.byType(SeraTodoRow).evaluate().length, lessThan(30));
      expect(tester.takeException(), isNull);
    },
  );
}
