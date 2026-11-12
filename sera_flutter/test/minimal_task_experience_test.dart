import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:sera_flutter/ui/core/sera_todo_row.dart';
import 'package:sera_flutter/ui/core/sera_plan_switcher.dart';

class _Store implements WorkspaceRepository {
  _Store(this.value);
  Workspace? value;
  int writes = 0;
  @override
  String get mode => 'minimal-task-experience';
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
    return value = Workspace.fromJson(
      next.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }
}

Future<(SeraController, _Store)> _mount(
  WidgetTester tester,
  Workspace workspace,
  String path, {
  bool narrow = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(narrow ? 320 : 390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  if (narrow) {
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  final store = _Store(workspace);
  final controller = SeraController(
    repository: store,
    today: DateTime(2026, 10, 31),
    accountId: 'minimal-task-account',
  );
  await controller.initialize();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    controller.dispose();
  });
  await tester.pumpWidget(
    SeraApp(controller: controller, initialLocation: path),
  );
  await tester.pumpAndSettle();
  return (controller, store);
}

Finder _button(String text) => find.widgetWithText(SeraButton, text);
Finder _input(String label) => find.descendant(
  of: find.widgetWithText(SeraInput, label),
  matching: find.byType(TextFormField),
);
Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

DateTime _at(int day, int hour) => inTimeZone(
  DateTime(2026, 10, day, hour),
  'Asia/Hong_Kong',
  wallClock: true,
);
CalendarEntry _entry(SeraTask task, int day) => CalendarEntry(
  id: '${task.id}-entry-$day',
  title: task.title,
  taskId: task.id,
  start: _at(day, 14),
  end: _at(day, 15),
);

void main() {
  testWidgets(
    'time entry edits the same task and preserves hidden fields and unsaved inputs',
    (tester) async {
      final task = SeraTask(
        id: 'time-edit',
        title: '保留任务名称',
        notes: '保留原备注',
        estimatedMinutes: 60,
        dueDate: '2026-11-03',
        checklist: ['原检查项'],
      );
      final (controller, store) = await _mount(
        tester,
        Workspace(revision: 1, tasks: [task], entries: [_entry(task, 31)]),
        '/18?taskId=time-edit',
      );
      await _tap(tester, _button('修改时间'));
      final router = GoRouter.of(tester.element(find.byType(SeraScaffold)));
      expect(router.state.uri.queryParameters['section'], 'time');
      expect(_input('任务名称'), findsNothing);
      await tester.enterText(_input('预计用时（分钟）'), '45');
      await _tap(tester, find.text('编辑其他信息'));
      expect(
        tester.widget<TextFormField>(_input('任务名称')).controller!.text,
        task.title,
      );
      await tester.enterText(_input('任务名称'), '同一表单内修改名称');
      await _tap(tester, find.text('编辑其他信息'));
      expect(
        tester.widget<TextFormField>(_input('预计用时（分钟）')).controller!.text,
        '45',
      );
      await _tap(tester, _button('保存任务'));
      expect(controller.task(task.id)!.title, '同一表单内修改名称');
      expect(controller.task(task.id)!.notes, task.notes);
      expect(controller.task(task.id)!.dueDate, '2026-11-03');
      expect(controller.task(task.id)!.checklist, task.checklist);
      expect(controller.entryForTask(task.id)!.minutes, 45);
      expect(store.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'time editor reveals invalid hidden input then cancels without writing',
    (tester) async {
      const task = SeraTask(id: 'time-cancel', title: '保留原任务');
      final (controller, store) = await _mount(
        tester,
        const Workspace(revision: 1, tasks: [task]),
        '/09?taskId=time-cancel&section=time',
      );
      await _tap(tester, find.text('编辑其他信息'));
      await tester.enterText(_input('任务名称'), '');
      await _tap(tester, find.text('编辑其他信息'));
      await _tap(tester, _button('保存任务'));
      expect(_input('任务名称').hitTestable(), findsOneWidget);
      expect(store.writes, 0);
      await _tap(tester, find.byTooltip('返回'));
      await _tap(tester, find.widgetWithText(TextButton, '放弃修改'));
      expect(controller.task(task.id)!.title, task.title);
      expect(controller.entriesForTask(task.id), isEmpty);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'task navigation defaults to all unfinished tasks with one vocabulary',
    (tester) async {
      const unscheduled = SeraTask(id: 'unscheduled', title: '随时处理的事项');
      const scheduled = SeraTask(id: 'scheduled', title: '已安排的事项');
      const done = SeraTask(id: 'done', title: '完成的事项', status: 'done');
      final (_, store) = await _mount(
        tester,
        Workspace(
          revision: 1,
          tasks: [unscheduled, scheduled, done],
          entries: [_entry(scheduled, 32)],
        ),
        '/17',
      );
      final scaffold = tester.widget<SeraScaffold>(find.byType(SeraScaffold));
      expect(scaffold.title, '计划');
      expect(scaffold.navIndex, 1);
      expect(scaffold.showBack, isFalse);
      expect(
        tester.widget<SeraPlanSwitcher>(find.byType(SeraPlanSwitcher)).goals,
        isFalse,
      );
      expect(find.byType(SeraTodoRow), findsNWidgets(2));
      expect(find.text(unscheduled.title), findsOneWidget);
      expect(find.text(scheduled.title), findsOneWidget);
      expect(find.text(done.title), findsNothing);
      expect(find.text('收件箱 · 待整理'), findsNothing);
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, '未完成'))
            .selected,
        isTrue,
      );

      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('添加任务'), findsNothing);
      expect(find.byKey(const ValueKey('today-capture')), findsNothing);
      expect(find.byTooltip('搜索当前列表'), findsNothing);
      expect(find.byTooltip('任务更多'), findsNothing);
      expect(find.byTooltip('查找与筛选'), findsNothing);
      expect(scaffold.actions, isEmpty);
      expect(find.byTooltip('账户与设置'), findsNothing);
      await _tap(tester, find.widgetWithText(FilterChip, '已完成'));
      expect(find.text(done.title), findsOneWidget);
      expect(find.text(unscheduled.title), findsNothing);
      expect(find.text(scheduled.title), findsNothing);
      await _tap(tester, find.widgetWithText(FilterChip, '未完成'));
      expect(find.text(done.title), findsNothing);
      expect(find.text(unscheduled.title), findsOneWidget);
      expect(find.text(scheduled.title), findsOneWidget);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scheduled in [false, true]) {
    testWidgets(
      'core task actions are visible at 320px and large text when scheduled=$scheduled',
      (tester) async {
        const task = SeraTask(
          id: 'core-actions',
          title: '完成这一项重要任务',
          notes: '只在展开后查看的补充信息',
          checklist: ['准备资料'],
        );
        final (controller, store) = await _mount(
          tester,
          Workspace(
            revision: 1,
            tasks: [task],
            entries: [if (scheduled) _entry(task, 31)],
          ),
          '/18?taskId=${task.id}',
          narrow: true,
        );
        final timing = scheduled ? '修改时间' : '安排时间';
        for (final label in ['开始专注', '完成', timing]) {
          expect(_button(label).hitTestable(), findsOneWidget);
          expect(tester.getRect(_button(label)).left, greaterThanOrEqualTo(0));
          expect(tester.getRect(_button(label)).right, lessThanOrEqualTo(320));
          expect(tester.getRect(_button(label)).bottom, lessThanOrEqualTo(844));
        }
        expect(find.text(task.notes), findsNothing);
        expect(find.text('预计用时'), findsNothing);
        expect(store.writes, 0);
        await _tap(tester, _button(timing));
        expect(find.widgetWithText(AppBar, '编辑任务'), findsOneWidget);
        expect(controller.task(task.id)!.title, task.title);
        expect(store.writes, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'unscheduled task starts a real focus session without opening details',
    (tester) async {
      const task = SeraTask(
        id: 'focus-now',
        title: '现在开始',
        estimatedMinutes: 20,
      );
      final (controller, store) = await _mount(
        tester,
        const Workspace(revision: 1, tasks: [task]),
        '/18?taskId=${task.id}',
      );
      await _tap(tester, _button('开始专注'));
      expect(controller.data.focusSession?.taskId, task.id);
      expect(controller.data.focusSession?.targetMinutes, 20);
      expect(controller.task(task.id)!.status, 'in_progress');
      expect(controller.data.entries, isEmpty);
      expect(store.writes, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'today filter combines scheduled and due work without exposing the whole backlog',
    (tester) async {
      const backlog = SeraTask(id: 'backlog', title: '之后再整理');
      const scheduled = SeraTask(id: 'scheduled', title: '今天安排的一步');
      final due = SeraTask(id: 'due', title: '今天到期', dueAt: _at(31, 18));
      final overdue = SeraTask(
        id: 'overdue',
        title: '已经到期',
        dueAt: _at(30, 18),
      );
      final (_, store) = await _mount(
        tester,
        Workspace(
          revision: 1,
          tasks: [backlog, scheduled, due, overdue],
          entries: [_entry(scheduled, 31)],
        ),
        '/17?filter=today',
      );
      expect(find.text(backlog.title), findsNothing);
      for (final task in [scheduled, due, overdue]) {
        expect(find.text(task.title), findsOneWidget);
      }
      expect(find.widgetWithText(FilterChip, '今天'), findsNothing);
      expect(find.text('今天'), findsOneWidget);
      await _tap(tester, find.widgetWithText(FilterChip, '未完成'));
      expect(find.text(backlog.title), findsOneWidget);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty today keeps unfinished tasks available without a duplicate capture action',
    (tester) async {
      const task = SeraTask(id: 'backlog', title: '还没有安排的事情');
      final (_, store) = await _mount(
        tester,
        const Workspace(revision: 1, tasks: [task]),
        '/17?filter=today',
        narrow: true,
      );
      expect(find.text('今天暂无任务'), findsOneWidget);
      expect(find.byKey(const ValueKey('today-capture')), findsNothing);
      expect(
        find.widgetWithText(FilterChip, '未完成').hitTestable(),
        findsOneWidget,
      );
      expect(find.byType(SeraEmpty), findsNothing);
      expect(_button('查看全部任务'), findsNothing);
      await _tap(tester, find.widgetWithText(FilterChip, '未完成'));
      expect(find.text(task.title), findsOneWidget);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Today resumes the existing paused focus without creating another session',
    (tester) async {
      const task = SeraTask(
        id: 'focus',
        title: '保持当前进度',
        status: 'in_progress',
      );
      final focus = FocusSession(
        id: 'saved-focus',
        taskId: task.id,
        startedAt: _at(31, 9),
        accumulatedSeconds: 90,
        isRunning: false,
        targetMinutes: 20,
      );
      final (controller, store) = await _mount(
        tester,
        Workspace(revision: 1, tasks: [task], focusSession: focus),
        '/04',
      );
      await _tap(tester, find.widgetWithText(SeraSettingRow, '继续专注'));
      expect(controller.data.focusSession!.id, focus.id);
      expect(controller.data.focusSession!.accumulatedSeconds, 90);
      expect(controller.data.focusSession!.isRunning, isFalse);
      expect(find.text('目标 20分钟 · 已暂停'), findsOneWidget);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'completion result stays on this task while undo and completion still update real data',
    (tester) async {
      final goal = SeraGoal(
        id: 'shared-goal',
        title: '不重复展示的目标',
        deadline: _at(31, 18),
      );
      const completed = SeraTask(
        id: 'completed',
        title: '刚完成的任务',
        goalId: 'shared-goal',
        status: 'done',
        actualSeconds: 240,
      );
      const other = SeraTask(
        id: 'other',
        title: '不自动推荐下一项',
        goalId: 'shared-goal',
      );
      final (controller, store) = await _mount(
        tester,
        Workspace(
          revision: 1,
          goals: [goal],
          tasks: [completed, other],
          focusRecords: [
            FocusRecord(
              id: 'history',
              taskId: completed.id,
              startedAt: _at(31, 14),
              seconds: 240,
            ),
          ],
        ),
        '/46?taskId=${completed.id}',
      );
      expect(find.text(completed.title), findsOneWidget);
      expect(find.text('实际专注 4 分钟'), findsOneWidget);
      expect(find.text(other.title), findsNothing);
      expect(find.text(goal.title), findsNothing);
      expect(find.text('下一项'), findsNothing);
      expect(find.text('查看目标进度'), findsNothing);
      expect(find.byType(SeraProgress), findsNothing);
      expect(_button('返回'), findsOneWidget);
      expect(store.writes, 0);
      await _tap(tester, find.widgetWithText(TextButton, '撤销完成'));
      expect(controller.task(completed.id)!.done, isFalse);
      expect(controller.task(completed.id)!.actualSeconds, 240);
      await _tap(tester, _button('确认标记完成'));
      expect(controller.task(completed.id)!.done, isTrue);
      expect(controller.task(other.id)!.done, isFalse);
      expect(controller.data.focusRecords.single.seconds, 240);
      expect(store.writes, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty reminders have one status line and no suggested next action',
    (tester) async {
      final (_, store) = await _mount(
        tester,
        const Workspace(revision: 1),
        '/27',
      );
      expect(find.text('暂时没有待提醒事项'), findsOneWidget);
      expect(find.byType(SeraEmpty), findsNothing);
      expect(_button('查看任务'), findsNothing);
      expect(find.byTooltip('提醒设置'), findsOneWidget);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final direct in [true, false]) {
    testWidgets(
      'reminder app bar preserves the correct return destination for direct=$direct',
      (tester) async {
        const task = SeraTask(
          id: 'reminder-task',
          title: '指定的提醒任务',
          reminderMinutes: 30,
        );
        const other = SeraTask(id: 'other', title: '另一项任务');
        final (_, store) = await _mount(
          tester,
          const Workspace(revision: 1, tasks: [other, task]),
          direct ? '/45?taskId=${task.id}' : '/17?filter=inbox',
        );
        final router = GoRouter.of(tester.element(find.byType(SeraScaffold)));
        Future<void>? returnToOrigin;
        if (!direct) {
          returnToOrigin = router.push<void>('/45?taskId=${task.id}');
          await tester.pumpAndSettle();
        }
        expect(find.text('当前设置：开始前 30 分钟'), findsOneWidget);
        expect(_button('设置任务提醒'), findsOneWidget);
        expect(_button('返回任务详情'), findsNothing);
        await _tap(tester, find.byTooltip('返回'));
        if (returnToOrigin != null) await returnToOrigin;
        expect(router.state.uri.path, direct ? '/18' : '/17');
        expect(
          router.state.uri.queryParameters[direct ? 'taskId' : 'filter'],
          direct ? task.id : 'inbox',
        );
        expect(store.writes, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'deadline precision disappears after clearing without losing task input',
    (tester) async {
      final (controller, store) = await _mount(
        tester,
        const Workspace(revision: 1),
        '/19?dueDate=2026-11-06',
      );
      expect(find.text('截止只指定日期'), findsOneWidget);
      await tester.enterText(_input('要做什么？'), '保留输入与未设置的截止');
      await _tap(tester, find.widgetWithText(TextButton, '清除截止日期'));
      expect(find.text('截止只指定日期'), findsNothing);
      expect(find.text('暂无截止 · 点击设置'), findsOneWidget);
      await _tap(tester, _button('保存任务'));
      final saved = controller.data.tasks.single;
      expect(saved.title, '保留输入与未设置的截止');
      expect(saved.dueDate, isNull);
      expect(saved.dueAt, isNull);
      expect(store.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'no available remaining slot has no proposed update result or write',
    (tester) async {
      final task = SeraTask(
        id: 'no-capacity',
        title: '截止前已无可用时间',
        dueAt: _at(31, 18),
        remainingMinutes: 25,
      );
      final (_, store) = await _mount(
        tester,
        Workspace(revision: 1, tasks: [task]),
        '/47?taskId=${task.id}',
      );
      expect(find.text('暂无可用时段'), findsOneWidget);
      expect(find.text('确认时一起更新'), findsNothing);
      expect(find.text('替换为新的可用时段'), findsNothing);
      expect(find.text('原有截止'), findsOneWidget);
      expect(_button('编辑任务安排'), findsOneWidget);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'weekly review saves text and lists this week dates rather than old task blocks',
    (tester) async {
      const task = SeraTask(
        id: 'week-task',
        title: '本周推进事项',
        estimatedMinutes: 60,
      );
      final unrelatedGoal = SeraGoal(
        id: 'other-week-goal',
        title: '与本周工作无关的目标',
        deadline: _at(31, 18),
      );
      final (controller, store) = await _mount(
        tester,
        Workspace(
          revision: 1,
          tasks: [task],
          goals: [unrelatedGoal],
          entries: [_entry(task, 20), _entry(task, 30)],
          focusRecords: [
            FocusRecord(
              id: 'this-week',
              taskId: task.id,
              startedAt: _at(30, 14),
              seconds: 125,
            ),
            FocusRecord(
              id: 'old-week',
              taskId: task.id,
              startedAt: _at(20, 14),
              seconds: 3600,
            ),
          ],
        ),
        '/29',
      );
      final row = find.byType(SeraTaskRow);
      expect(find.text('本周实际专注'), findsOneWidget);
      expect(find.text('2 分 5 秒'), findsOneWidget);
      expect(find.text('本周计划投入'), findsNothing);
      expect(find.textContaining('已计时'), findsNothing);
      expect(find.byType(SeraProgress), findsNothing);
      expect(find.text('查看完整目标'), findsNothing);
      expect(find.text('下周的准备'), findsNothing);
      expect(find.text(unrelatedGoal.title), findsNothing);
      expect(
        find.descendant(of: row, matching: find.textContaining('10月30日')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.textContaining('10月20日')),
        findsNothing,
      );
      // The optional calendar action remains available before the user ends
      // this review. Back must preserve the unsaved review rather than save it.
      await _tap(tester, find.widgetWithText(TextButton, '查看下周安排'));
      expect(calendarDateString(controller.selectedDate), '2026-11-02');
      expect(store.writes, 0);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '本周回顾'), findsOneWidget);
      await tester.enterText(_input('记录本周的收获与下周调整'), '下周保留午后时间');
      await _tap(tester, _button('保存本周回顾'));
      final review = controller.data.reviews.single;
      expect(review.kind, 'weekly');
      expect((jsonDecode(review.feedback) as Map)['note'], '下周保留午后时间');
      expect(store.writes, 1);
      final router = GoRouter.of(tester.element(find.byType(SeraScaffold)));
      expect(router.state.uri.path, '/04');
      expect(router.canPop(), isFalse);
      expect(find.widgetWithText(AppBar, '本周回顾'), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      expect(store.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'daily review retains actual results and saves feedback without unrelated goal decoration',
    (tester) async {
      final goal = SeraGoal(
        id: 'other-goal',
        title: '与今天任务无关的目标',
        deadline: _at(31, 18),
      );
      const task = SeraTask(id: 'finished', title: '今天完成的工作', status: 'done');
      final (controller, store) = await _mount(
        tester,
        Workspace(
          revision: 1,
          goals: [goal],
          tasks: [task],
          entries: [_entry(task, 31)],
          focusRecords: [
            FocusRecord(
              id: 'today-focus',
              taskId: task.id,
              startedAt: _at(31, 14),
              seconds: 300,
            ),
          ],
        ),
        '/28',
      );
      expect(find.text('1 / 1'), findsOneWidget);
      expect(find.text('5 分钟'), findsOneWidget);
      expect(find.text('今日实际专注'), findsOneWidget);
      expect(find.text(task.title), findsOneWidget);
      expect(find.text(goal.title), findsNothing);
      expect(find.byType(SeraProgress), findsNothing);
      await _tap(tester, find.widgetWithText(ChoiceChip, '有点满'));
      await tester.enterText(_input('留一句给明天的自己'), '明天留出休息时间');
      await _tap(tester, _button('保存回顾'));
      final feedback =
          jsonDecode(controller.data.reviews.single.feedback) as Map;
      expect(feedback['rating'], 'heavy');
      expect(feedback['note'], '明天留出休息时间');
      expect(controller.task(task.id)!.done, isTrue);
      expect(controller.data.focusRecords.single.seconds, 300);
      expect(store.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty daily completion area does not show unrelated goal progress',
    (tester) async {
      final goal = SeraGoal(
        id: 'untouched-goal',
        title: '另一个未推进目标',
        deadline: _at(31, 18),
      );
      final (_, store) = await _mount(
        tester,
        Workspace(revision: 1, goals: [goal]),
        '/28',
      );
      expect(find.text('今天暂无完成任务'), findsOneWidget);
      expect(find.text(goal.title), findsNothing);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'legacy task filter links keep the requested range without adding a filter menu',
    (tester) async {
      const unscheduled = SeraTask(id: 'inbox', title: '尚未安排的任务');
      const today = SeraTask(id: 'today', title: '今日已经安排的任务');
      const future = SeraTask(id: 'future', title: '未来已经安排的任务');
      const done = SeraTask(id: 'done', title: '已经完成的任务', status: 'done');
      const canceled = SeraTask(
        id: 'canceled',
        title: '已经取消的任务',
        status: 'canceled',
      );
      final (_, store) = await _mount(
        tester,
        Workspace(
          revision: 1,
          tasks: [unscheduled, today, future, done, canceled],
          entries: [_entry(today, 31), _entry(future, 32)],
        ),
        '/17?filter=inbox',
      );
      expect(find.byType(FilterChip), findsNWidgets(2));
      expect(_button('请 AI 整理待安排事项'), findsNothing);
      expect(find.text(unscheduled.title), findsOneWidget);
      expect(find.text(today.title), findsNothing);
      expect(find.text(future.title), findsNothing);

      expect(find.text('未安排'), findsOneWidget);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      final router = GoRouter.of(tester.element(find.byType(SeraScaffold)));
      router.go('/17?filter=today');
      await tester.pumpAndSettle();
      expect(find.text(today.title), findsOneWidget);
      expect(find.text(unscheduled.title), findsNothing);
      expect(find.text(future.title), findsNothing);

      router.go('/17?filter=scheduled');
      await tester.pumpAndSettle();
      expect(find.text(today.title), findsOneWidget);
      expect(find.text(future.title), findsOneWidget);
      expect(find.text(unscheduled.title), findsNothing);
      expect(find.text('已安排'), findsOneWidget);

      router.go('/17?filter=all');
      await tester.pumpAndSettle();
      expect(find.text('全部任务'), findsOneWidget);
      for (final task in [unscheduled, today, future, done, canceled]) {
        expect(find.text(task.title), findsOneWidget);
      }

      await _tap(tester, find.widgetWithText(FilterChip, '已完成'));
      expect(find.text(done.title), findsOneWidget);
      expect(find.text(canceled.title), findsNothing);
      expect(find.text(unscheduled.title), findsNothing);
      expect(_button('请 AI 整理待安排事项'), findsNothing);
      await _tap(tester, find.widgetWithText(FilterChip, '未完成'));
      for (final task in [unscheduled, today, future]) {
        expect(find.text(task.title), findsOneWidget);
      }
      expect(find.text(done.title), findsNothing);
      expect(find.text(canceled.title), findsNothing);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'main task filters remain reachable with enlarged text on narrow screens',
    (tester) async {
      const pending = SeraTask(id: 'pending', title: '稍后继续');
      const done = SeraTask(id: 'done', title: '已完成事项', status: 'done');
      final (_, store) = await _mount(
        tester,
        const Workspace(revision: 1, tasks: [pending, done]),
        '/17?filter=all',
        narrow: true,
      );
      final doneFilter = find.widgetWithText(FilterChip, '已完成');
      await _tap(tester, doneFilter);
      expect(find.text(done.title), findsOneWidget);
      expect(find.text(pending.title), findsNothing);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
