import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/domain/seed_data.dart';
import 'package:sera_flutter/ui/core/screen_names.dart';
import 'package:sera_flutter/ui/core/sera_todo_row.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _MemoryRepository implements WorkspaceRepository {
  _MemoryRepository(this.value);
  Workspace? value;
  @override
  String get mode => 'widget-test';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async {
    value = null;
  }

  @override
  Future<Workspace> save(
    Workspace workspace, {
    required int expectedRevision,
  }) async {
    if ((value?.revision ?? 0) != expectedRevision) {
      throw const RepositoryException('工作区已被其他操作修改', conflict: true);
    }
    value = Workspace.fromJson(
      workspace.copyWith(revision: expectedRevision + 1).toJson(),
    );
    return value!;
  }
}

final _today = DateTime(2026, 10, 28);

Future<SeraController> _controller({
  bool draft = false,
  bool empty = false,
}) async {
  final controller = SeraController(
    today: _today,
    repository: _MemoryRepository(
      empty
          ? const Workspace(revision: 1)
          : createSeedWorkspace(_today).copyWith(revision: 1),
    ),
  );
  await controller.initialize();
  if (draft) {
    await controller.generatePlan(
      title: '准备课程项目展示',
      deadline: _today.add(const Duration(days: 14)),
      dailyBudget: 90,
    );
  }
  return controller;
}

Future<void> _pump(
  WidgetTester tester,
  SeraController c,
  String location,
) async {
  await tester.pumpWidget(
    SeraApp(key: UniqueKey(), controller: c, initialLocation: location),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _tapButton(WidgetTester tester, String label) async {
  final target = label == '撤销完成'
      ? find.widgetWithText(TextButton, label)
      : find.widgetWithText(SeraButton, label);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(seconds: 5));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets('core forms remain usable at 320 px with 150 percent text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 844);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final c = await _controller(draft: true);
    for (final id in [
      '02',
      '06',
      '08',
      '18',
      '21',
      '31',
      '32',
      '33',
      '34',
      '50',
    ]) {
      await _pump(tester, c, '/$id');
      expect(tester.takeException(), isNull, reason: 'Page $id at 150% text');
      final scroll = find.byType(Scrollable).first;
      await tester.drag(scroll, const Offset(0, -2000));
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason: 'Page $id bottom at 150% text',
      );
    }
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('month navigation clamps short months without skipping a month', (
    tester,
  ) async {
    final c = await _controller();
    c.setSelectedDate(DateTime(2026, 10, 31));
    await _pump(tester, c, '/14');
    await tester.tap(find.byTooltip('下个月'));
    await tester.pump();
    expect(c.selectedDate, DateTime(2026, 11, 30));
    c.setSelectedDate(DateTime(2026, 1, 31));
    await tester.pump();
    await tester.tap(find.byTooltip('下个月'));
    await tester.pump();
    expect(c.selectedDate, DateTime(2026, 2, 28));
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  for (final width in [320.0, 360.0, 390.0, 430.0]) {
    testWidgets('55 routes render with real seed data at ${width.toInt()} px', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final id in screenNames.keys) {
        final c = await _controller(draft: true);
        final draft = c.data.drafts.first;
        final query = Uri(
          queryParameters: {
            'taskId': id == '09' || id == '43'
                ? draft.items.first.task.id
                : 'task-1',
            'eventId': 'meeting-1',
            'draftId': draft.id,
          },
        ).query;
        await _pump(tester, c, '/$id?$query');
        expect(tester.takeException(), isNull, reason: 'Page $id at $width px');
        expect(
          find.byType(Scaffold),
          findsWidgets,
          reason: 'Page $id must display a native page',
        );
        if (find.byType(ModalBarrier).evaluate().isEmpty) {
          final scroll = find.byType(SingleChildScrollView).last;
          await tester.drag(scroll, const Offset(0, -1600));
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(
          tester.takeException(),
          isNull,
          reason: 'Page $id bottom content at $width px',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        c.dispose();
      }
    });
  }

  testWidgets(
    'empty inbox create, complete and undo preserve task data and actual focus',
    (tester) async {
      final c = await _controller(empty: true);
      await _pump(tester, c, '/19');
      await _tapButton(tester, '保存任务');
      expect(find.text('请写下一个可以行动的任务'), findsOneWidget);
      expect(c.data.tasks, isEmpty);
      await tester.enterText(find.byType(TextFormField).at(0), '完成课程 H5 对照验收');
      await tester.enterText(
        find.byType(TextFormField).at(1),
        '逐项检查视觉与交互，再提交课程成果。',
      );
      await tester.enterText(find.byType(TextFormField).at(2), '35');
      await _tapButton(tester, '保存任务');
      expect(c.data.tasks, hasLength(1));
      final task = c.data.tasks.single;
      expect(task.title, '完成课程 H5 对照验收');
      expect(task.estimatedMinutes, 35);
      expect(
        c.entryForTask(task.id),
        isNull,
        reason: 'Inbox tasks must not reserve calendar time',
      );
      expect(find.widgetWithText(AppBar, '计划'), findsOneWidget);
      expect(find.text('未安排'), findsOneWidget);
      expect(find.byType(SeraTodoRow), findsOneWidget);
      await tester.tap(find.text(task.title));
      await tester.pumpAndSettle();
      await _tapButton(tester, '完成');
      expect(c.task(task.id)!.done, isTrue);
      expect(
        c.task(task.id)!.actualSeconds,
        0,
        reason: 'Completing a task must not invent focus minutes',
      );
      final router = GoRouter.of(tester.element(find.byType(SeraScaffold)));
      expect(router.state.uri.path, '/17');
      expect(router.state.uri.queryParameters['filter'], 'inbox');
      expect(router.canPop(), isFalse);
      expect(find.widgetWithText(AppBar, '任务详情'), findsNothing);
      await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
      await tester.pumpAndSettle();
      expect(c.task(task.id)!.done, isFalse);
      expect(c.task(task.id)!.notes, contains('逐项检查'));
      expect(c.task(task.id)!.actualSeconds, 0);
      expect(find.text(task.title), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  testWidgets(
    'inbox filters and native reminder sheet operate on the selected task',
    (tester) async {
      final c = await _controller();
      await _pump(tester, c, '/17');
      expect(find.text('梳理方案框架'), findsOneWidget);
      expect(
        tester
            .widgetList<SeraTodoRow>(find.byType(SeraTodoRow))
            .every((row) => row.task.active),
        isTrue,
      );
      await tester.scrollUntilVisible(
        find.text('整理十月报销单'),
        400,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 30,
      );
      await tester.pumpAndSettle();
      expect(find.text('整理十月报销单').hitTestable(), findsOneWidget);
      final router = GoRouter.of(tester.element(find.byType(SeraScaffold)));
      router.go('/17?filter=inbox');
      await tester.pumpAndSettle();
      expect(find.text('整理十月报销单'), findsOneWidget);
      expect(find.text('梳理方案框架'), findsNothing);
      router.go('/17?filter=all');
      await tester.pumpAndSettle();
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.text('梳理方案框架'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('更多任务信息'));
      await tester.tap(find.text('更多任务信息'));
      await tester.pumpAndSettle();
      await _tapButton(tester, '设置提醒');
      expect(find.text('什么时候提醒你？'), findsOneWidget);
      await tester.tap(find.text('开始前 30 分钟').last);
      await _tapButton(tester, '保存提醒');
      expect(c.task('task-1')!.reminderMinutes, 30);
      expect(c.task('task-2')!.reminderMinutes, 10);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  testWidgets('task detail keeps notes once and secondary fields accessible', (
    tester,
  ) async {
    final c = await _controller();
    await _pump(tester, c, '/18?taskId=task-1');
    expect(find.text(c.task('task-1')!.notes), findsNothing);
    expect(find.text('预计用时'), findsNothing);
    expect(find.textContaining('截止 '), findsOneWidget);
    expect(find.text('明确评审的核心问题'), findsOneWidget);
    expect(find.text('实际投入'), findsNothing);
    final disclosure = find.text('更多任务信息');
    await tester.ensureVisible(disclosure);
    await tester.tap(disclosure);
    await tester.pumpAndSettle();
    expect(find.text(c.task('task-1')!.notes), findsOneWidget);
    expect(find.text('实际投入'), findsOneWidget);
    expect(find.text('预计用时'), findsOneWidget);
    expect(find.text('关联目标'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();

    final emptyNotes = await _controller();
    await _pump(tester, emptyNotes, '/18?taskId=task-inbox-2');
    expect(find.text('完成的标准'), findsNothing);
    expect(find.text('从一个问题开始'), findsNothing);
    expect(find.widgetWithText(SeraButton, '完成'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    emptyNotes.dispose();
  });

  testWidgets('task deletion removes its calendar entry and can be undone', (
    tester,
  ) async {
    final c = await _controller();
    await _pump(tester, c, '/18?taskId=task-1');
    await tester.ensureVisible(find.text('更多任务信息'));
    await tester.tap(find.text('更多任务信息'));
    await tester.pumpAndSettle();
    await _tapButton(tester, '删除任务');
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('确认删除'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.task('task-1'), isNull);
    expect(c.entryForTask('task-1'), isNull);
    await c.undoLast();
    await tester.pump();
    expect(c.task('task-1'), isNotNull);
    expect(c.entryForTask('task-1'), isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets(
    'primary bottom navigation changes screens without losing workspace data',
    (tester) async {
      final c = await _controller();
      await _pump(tester, c, '/04');
      for (final label in ['计划', '日程', '今日']) {
        final bottomLabel = find
            .descendant(
              of: find.byType(Scaffold).first,
              matching: find.text(label),
            )
            .last;
        await tester.tap(bottomLabel);
        await tester.pumpAndSettle();
        final route = GoRouter.of(
          tester.element(find.byType(SeraScaffold).first),
        );
        expect(
          route.routerDelegate.state.uri.path,
          '/${{'今日': '04', '计划': '17', '日程': '12'}[label]}',
        );
        expect(tester.takeException(), isNull, reason: 'Navigation to $label');
      }
      expect(c.data.tasks, hasLength(8));
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  testWidgets(
    'draft task edits update only the draft until explicit confirmation',
    (tester) async {
      final c = await _controller(draft: true);
      final draft = c.data.drafts.single;
      final item = draft.items.first;
      final originalTasks = c.data.tasks.map((t) => t.toJson()).toList();
      final originalEntries = c.data.entries.map((e) => e.toJson()).toList();
      await _pump(tester, c, '/09?draftId=${draft.id}&taskId=${item.task.id}');
      await tester.enterText(find.byType(TextFormField).at(0), '核对课程项目的核心问题');
      await _tapButton(tester, '保存到草案');
      expect(c.draft(draft.id)!.items.first.task.title, '核对课程项目的核心问题');
      expect(c.data.tasks.map((t) => t.toJson()).toList(), originalTasks);
      expect(c.data.entries.map((e) => e.toJson()).toList(), originalEntries);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  testWidgets(
    'focus pause and end store elapsed seconds without completing the task',
    (tester) async {
      final c = await _controller();
      await _pump(tester, c, '/25?taskId=task-1');
      await tester.tap(find.byTooltip('暂停专注'));
      await tester.pump();
      expect(find.textContaining('已暂停'), findsOneWidget);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1100)),
      );
      await tester.tap(find.byTooltip('继续专注'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1100)),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byTooltip('结束并保存专注'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(c.data.focusRecords, hasLength(1));
      expect(c.data.focusRecords.single.seconds, inInclusiveRange(1, 4));
      expect(
        c.task('task-1')!.actualSeconds,
        c.data.focusRecords.single.seconds,
      );
      expect(c.task('task-1')!.done, isFalse);
      expect(find.text('专注结束'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  testWidgets('missing task and event deep links offer a safe continuation', (
    tester,
  ) async {
    for (final id in [
      '09',
      '15',
      '16',
      '18',
      '25',
      '26',
      '43',
      '45',
      '46',
      '47',
    ]) {
      final c = await _controller(empty: true);
      await _pump(tester, c, '/$id?taskId=missing&eventId=missing');
      expect(
        find.text('添加一项任务'),
        findsOneWidget,
        reason: 'Missing item route $id',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    }
  });
}
