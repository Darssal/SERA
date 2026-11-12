import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/domain/todo_queries.dart';
import 'package:sera_flutter/ui/core/sera_todo_row.dart';
import 'package:sera_flutter/ui/core/sera_motion.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:sera_flutter/ui/screens/task_screens.dart';

class _Store implements WorkspaceRepository {
  _Store(this.value);
  Workspace? value;
  int writes = 0;
  bool reject = false;
  @override
  String get mode => 'task-event-polish-test';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async => value = null;
  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    if (reject) throw const RepositoryException('测试保存失败，输入仍可编辑。');
    if (value?.revision != expectedRevision) {
      throw const RepositoryException('版本冲突', conflict: true);
    }
    writes++;
    return value = Workspace.fromJson(
      next.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }
}

class _Harness {
  _Harness(this.store, this.controller, this.router);
  final _Store store;
  final SeraController controller;
  final GoRouter router;
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
}

Future<_Harness> _mount(
  WidgetTester tester,
  Workspace workspace,
  String path,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final store = _Store(workspace);
  final c = SeraController(
    repository: store,
    today: DateTime(2026, 10, 31),
    accountId: 'polish-account',
  );
  await c.initialize();
  final router = GoRouter(
    initialLocation: path,
    routes: [
      GoRoute(
        path: '/origin',
        builder: (_, _) => const Scaffold(body: Text('origin page')),
      ),
      GoRoute(
        path: '/12',
        builder: (_, _) => const Scaffold(body: Text('calendar list')),
      ),
      GoRoute(
        path: '/08',
        builder: (_, state) => Scaffold(
          body: Text('draft list ${state.uri.queryParameters['draftId']}'),
        ),
      ),
      GoRoute(
        path: '/:screen',
        pageBuilder: (context, state) => SeraMotion.page<void>(
          context: context,
          state: state,
          child: buildTaskScreen(
            state.pathParameters['screen']!,
            taskId: state.uri.queryParameters['taskId'],
            eventId: state.uri.queryParameters['eventId'],
            draftId: state.uri.queryParameters['draftId'],
          ),
        ),
      ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    c.dispose();
    router.dispose();
  });
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: c,
      child: MaterialApp.router(
        theme: seraTheme(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        routerConfig: router,
        builder: (_, child) => SeraMotionScope(child: child!),
      ),
    ),
  );
  await _frames(tester);
  return _Harness(store, c, router);
}

Finder _button(String label) => find.widgetWithText(SeraButton, label);
Finder _input(String label) => find.descendant(
  of: find.widgetWithText(SeraInput, label),
  matching: find.byType(TextFormField),
);
String _text(WidgetTester tester, String label) =>
    tester.widget<TextFormField>(_input(label)).controller!.text;
Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await _frames(tester);
}

DateTime _at(int day, int hour, [int minute = 0]) => inTimeZone(
  DateTime(2026, 11, day, hour, minute),
  'Asia/Hong_Kong',
  wallClock: true,
);
void main() {
  testWidgets(
    'a completed list row can be restored without finding another list',
    (tester) async {
      final h = await _mount(
        tester,
        const Workspace(
          revision: 1,
          tasks: [
            SeraTask(
              id: 'list',
              title: '采购清单',
              status: 'in_progress',
              checklist: ['牛奶', '面包'],
              completedChecks: ['牛奶'],
            ),
          ],
        ),
        '/17?filter=todo',
      );
      await _tap(tester, find.byType(Checkbox));
      expect(h.controller.task('list')!.done, isTrue);
      expect(find.byType(SeraTodoRow), findsNothing);
      expect(find.widgetWithText(TextButton, '撤销完成'), findsOneWidget);
      await _tap(tester, find.widgetWithText(TextButton, '撤销完成'));
      expect(h.controller.task('list')!.status, 'in_progress');
      expect(h.controller.task('list')!.completedChecks, ['牛奶']);
      expect(h.controller.data.tasks, hasLength(1));
      expect(find.byType(SeraTodoRow), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('completion undo never replaces a later task edit', (
    tester,
  ) async {
    final h = await _mount(
      tester,
      const Workspace(
        revision: 1,
        tasks: [SeraTask(id: 'list', title: '采购清单')],
      ),
      '/17?filter=todo',
    );
    await _tap(tester, find.byType(Checkbox));
    await h.controller.saveTask(
      h.controller.task('list')!.copyWith(title: '后来改名'),
    );
    await _frames(tester);
    expect(find.widgetWithText(TextButton, '撤销完成'), findsNothing);
    expect(h.controller.task('list')!.title, '后来改名');
    expect(h.controller.task('list')!.done, isTrue);
  });

  testWidgets(
    'list completion undo restores scheduled blocks and reports occupancy conflicts inline',
    (tester) async {
      final block = CalendarEntry(
        id: 'scheduled',
        title: '明天整理资料',
        taskId: 'list',
        start: _at(2, 14),
        end: _at(2, 15),
      );
      final h = await _mount(
        tester,
        Workspace(
          revision: 1,
          tasks: const [
            SeraTask(id: 'list', title: '明天整理资料', estimatedMinutes: 60),
          ],
          entries: [block],
        ),
        '/17?filter=todo',
      );
      await _tap(tester, find.byType(Checkbox));
      expect(h.controller.entry(block.id), isNull);
      await _tap(tester, find.widgetWithText(TextButton, '撤销完成'));
      expect(h.controller.entry(block.id)!.start, block.start);
      expect(h.controller.task('list')!.done, isFalse);
      await _tap(tester, find.byType(Checkbox));
      await h.controller.saveEntry(
        CalendarEntry(
          id: 'meeting',
          title: '新会议',
          start: block.start,
          end: block.end,
          locked: true,
        ),
      );
      await _frames(tester);
      await _tap(tester, find.widgetWithText(TextButton, '撤销完成'));
      expect(h.controller.task('list')!.done, isTrue);
      expect(h.controller.entry(block.id), isNull);
      expect(find.textContaining('原时段现在无法恢复'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'adding subitems keeps input on failure and merges the newest task',
    (tester) async {
      final h = await _mount(
        tester,
        const Workspace(
          revision: 1,
          tasks: [
            SeraTask(
              id: 'list',
              title: '采购清单',
              notes: '原备注',
              checklist: ['牛奶', '面包'],
              completedChecks: ['牛奶'],
            ),
          ],
        ),
        '/18?taskId=list',
      );
      await _tap(tester, find.widgetWithText(TextButton, '添加子项'));
      final input = find.byKey(const ValueKey('add-task-checks-input'));
      expect(
        tester
            .widget<EditableText>(
              find.descendant(of: input, matching: find.byType(EditableText)),
            )
            .focusNode
            .hasFocus,
        isTrue,
      );
      await tester.enterText(input, '面包\n水果');
      h.store.reject = true;
      await _tap(tester, find.widgetWithText(FilledButton, '保存子项'));
      expect(tester.widget<TextFormField>(input).controller!.text, '面包\n水果');
      expect(find.text('测试保存失败，输入仍可编辑。'), findsOneWidget);
      h.store.reject = false;
      await h.controller.saveTask(
        h.controller.task('list')!.copyWith(notes: '后来更新的备注'),
      );
      await _frames(tester);
      await _tap(tester, find.widgetWithText(FilledButton, '保存子项'));
      expect(find.byType(AlertDialog), findsNothing);
      final saved = h.controller.task('list')!;
      expect(saved.checklist, ['牛奶', '面包', '水果']);
      expect(saved.completedChecks, ['牛奶']);
      expect(saved.notes, '后来更新的备注');
      expect(h.controller.data.tasks, hasLength(1));
      expect(h.router.state.uri.path, '/18');
      expect(tester.takeException(), isNull);
    },
  );

  test('today includes scheduled or due tasks and leaves unplanned work in the task library', () {
    final day = _at(2, 0);
    final tasks = [
      const SeraTask(id: 'plain', title: '随时继续'),
      const SeraTask(id: 'long', title: '长期待办', dueDate: '2026-12-31'),
      SeraTask(id: 'not-yet', title: '以后阶段', notBefore: _at(3, 0)),
      SeraTask(id: 'starts-today', title: '今天阶段', notBefore: _at(2, 15)),
      const SeraTask(id: 'future', title: '明天安排'),
      const SeraTask(id: 'overdue', title: '已到截止', dueDate: '2026-11-01'),
      const SeraTask(id: 'past', title: '昨天没做完'),
      const SeraTask(id: 'today', title: '今天做'),
      const SeraTask(id: 'rescheduled', title: '已改到明天'),
      const SeraTask(id: 'done', title: '已完成', status: 'done'),
      const SeraTask(id: 'canceled', title: '已取消', status: 'canceled'),
    ];
    CalendarEntry block(String taskId, int startDay, int hour, [int? endDay]) =>
        CalendarEntry(
          id: '$taskId-$startDay',
          title: taskId,
          taskId: taskId,
          start: _at(startDay, hour),
          end: endDay == null ? _at(startDay, hour + 1) : _at(endDay, 0),
        );
    final entries = [
      block('future', 3, 14),
      block('overdue', 3, 14),
      block('past', 1, 23, 2),
      block('today', 2, 14),
      block('rescheduled', 1, 14),
      block('rescheduled', 3, 14),
    ];
    final result = todayTodoTasks(
      tasks: tasks,
      entries: entries,
      day: day,
    ).map((task) => task.id);
    expect(result, ['overdue', 'today']);
    expect(pendingTodoTasks(tasks), hasLength(9));
    expect(
      todayTodoTasks(tasks: [tasks.first], entries: const [], day: _at(20, 0)),
      isEmpty,
    );
  });

  testWidgets(
    'a single todo needs only a title and opens the persistent todo list',
    (tester) async {
      final h = await _mount(
        tester,
        const Workspace(revision: 1),
        '/19?mode=todo',
      );
      expect(find.text('添加任务'), findsOneWidget);
      expect(find.text('预计用时（分钟）'), findsNothing);
      await tester.enterText(_input('要做什么？'), '买一把雨伞');
      await _tap(tester, _button('保存任务'));
      final saved = h.controller.data.tasks.single;
      expect(saved.title, '买一把雨伞');
      expect(saved.goalId, isNull);
      expect(saved.deadline, isNull);
      expect(saved.checklist, isEmpty);
      expect(h.controller.data.entries, isEmpty);
      expect(h.router.state.uri.queryParameters['filter'], 'todo');
      expect(find.byType(SeraTodoRow), findsOneWidget);
      expect(find.textContaining('待安排'), findsNothing);
      expect(h.store.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'goal-linked multi-item todo saves checkmarks without completing the parent',
    (tester) async {
      final goal = SeraGoal(id: 'study', title: '学期复习', deadline: _at(30, 18));
      final h = await _mount(
        tester,
        Workspace(revision: 1, goals: [goal]),
        '/19?mode=todo',
      );
      await tester.enterText(_input('要做什么？'), '复习清单');
      await _tap(tester, find.widgetWithText(TextButton, '添加子项'));
      await tester.enterText(_input('子项（每行一项）'), '复习第一章\n完成练习\n复习第一章');
      await _tap(tester, find.byType(DropdownButtonFormField<String>));
      await _tap(tester, find.text('学期复习').last);
      await _tap(tester, _button('保存任务'));
      final task = h.controller.data.tasks.single;
      expect(task.goalId, 'study');
      expect(task.checklist, ['复习第一章', '完成练习']);
      await _tap(tester, find.text(task.title));
      await _tap(tester, find.widgetWithText(CheckboxListTile, '复习第一章'));
      expect(h.controller.task(task.id)!.completedChecks, ['复习第一章']);
      expect(h.controller.task(task.id)!.done, isFalse);
      expect(h.router.state.uri.path.split('-').first, '/18');
      await _tap(tester, _button('完成'));
      expect(h.controller.task(task.id)!.done, isTrue);
      expect(h.router.state.uri.path, '/17');
      expect(h.router.state.uri.queryParameters['filter'], 'todo');
      expect(h.router.canPop(), isFalse);
      expect(_button('设为未完成'), findsNothing);
      await _tap(tester, find.widgetWithText(SnackBarAction, '撤销'));
      expect(h.controller.task(task.id)!.done, isFalse);
      expect(find.byType(SeraTodoRow), findsOneWidget);
      expect(h.controller.task(task.id)!.completedChecks, ['复习第一章']);
      expect(h.controller.data.focusRecords, isEmpty);
      expect(
        Workspace.fromJson(h.store.value!.toJson())
            .tasks
            .single
            .completedChecks,
        ['复习第一章'],
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'lightweight editing preserves scheduling constraints and completed subitems',
    (tester) async {
      final task = SeraTask(
        id: 'continued',
        title: '长期资料清单',
        notes: '重要备注',
        phase: '准备',
        notBefore: _at(1, 0),
        dueDate: '2026-11-30',
        estimatedMinutes: 90,
        checklist: const ['已有资料', '补齐资料'],
        completedChecks: const ['已有资料'],
      );
      final h = await _mount(
        tester,
        Workspace(revision: 1, tasks: [task]),
        '/origin',
      );
      unawaited(h.router.push('/18?taskId=${task.id}'));
      await _frames(tester);
      await _tap(tester, find.widgetWithText(TextButton, '编辑'));
      expect(find.text('编辑任务'), findsOneWidget);
      await tester.enterText(_input('要做什么？'), '修改后的资料清单');
      await tester.enterText(_input('子项（每行一项）'), '已有资料\n最后核对');
      await _tap(tester, _button('保存任务'));
      final saved = h.controller.task(task.id)!;
      expect(saved.notes, task.notes);
      expect(saved.phase, task.phase);
      expect(saved.notBefore, task.notBefore);
      expect(saved.dueDate, task.dueDate);
      expect(saved.estimatedMinutes, task.estimatedMinutes);
      expect(saved.completedChecks, ['已有资料']);
      expect(h.controller.data.entries, isEmpty);
      expect(h.router.state.uri.path, '/18');
      await _tap(tester, find.byTooltip('返回'));
      expect(find.text('origin page'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'todo detail keeps checklist prominent and secondary information accessible at large text',
    (tester) async {
      final task = SeraTask(
        id: 'light',
        title: '整理需要长期持续推进的资料清单',
        notes: '低频说明',
        checklist: const ['核对资料', '整理归档'],
      );
      await _mount(
        tester,
        Workspace(revision: 1, tasks: [task]),
        '/18?taskId=light',
      );
      tester.view.physicalSize = const Size(320, 844);
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _frames(tester);
      expect(find.text('核对资料'), findsOneWidget);
      expect(find.text('低频说明'), findsNothing);
      expect(find.text('预计用时'), findsNothing);
      expect(find.text('开始专注').hitTestable(), findsOneWidget);
      await _tap(tester, find.text('更多任务信息'));
      expect(find.text('低频说明'), findsOneWidget);
      expect(find.text('开始专注'), findsOneWidget);
      expect(find.text('设置提醒'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'todo save failure retains optional deadline and retry creates only one task',
    (tester) async {
      final h = await _mount(
        tester,
        const Workspace(revision: 1),
        '/19?mode=todo&dueDate=2026-11-30',
      );
      await tester.enterText(_input('要做什么？'), '失败后继续完成');
      h.store.reject = true;
      await _tap(tester, _button('保存任务'));
      expect(_text(tester, '要做什么？'), '失败后继续完成');
      expect(h.router.state.uri.path, '/19');
      expect(h.store.writes, 0);
      expect(find.text('测试保存失败，输入仍可编辑。').hitTestable(), findsOneWidget);
      expect(_button('保存任务').hitTestable(), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      await _tap(tester, find.byTooltip('清除截止日期'));
      h.store.reject = false;
      await _tap(tester, _button('保存任务'));
      expect(h.controller.data.tasks.single.deadline, isNull);
      expect(h.controller.data.tasks.single.title, '失败后继续完成');
      expect(h.store.writes, 1);
      expect(h.router.state.uri.queryParameters['filter'], 'todo');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'more scheduling options retain the lightweight draft without scheduling automatically',
    (tester) async {
      final h = await _mount(
        tester,
        const Workspace(revision: 1),
        '/19?mode=todo',
      );
      await tester.enterText(_input('要做什么？'), '保留同一份待办');
      await _tap(tester, find.widgetWithText(TextButton, '添加子项'));
      await tester.enterText(_input('子项（每行一项）'), '第一步\n第二步');
      await _tap(tester, find.text('安排时间'));
      expect(_text(tester, '要做什么？'), '保留同一份待办');
      await _tap(tester, _button('保存任务'));
      expect(h.controller.data.tasks.single.checklist, ['第一步', '第二步']);
      expect(h.controller.data.entries, isEmpty);
      expect(h.store.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
