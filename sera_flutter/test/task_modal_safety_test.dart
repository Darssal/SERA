import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/sera_motion.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:sera_flutter/ui/screens/task_screens.dart';

void _safetyTest(String description, WidgetTesterCallback callback) {
  testWidgets(
    description,
    callback,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

class _GateStore implements WorkspaceRepository {
  _GateStore(this.value);
  Workspace? value;
  Completer<void>? _gate;
  int writes = 0;

  void hold() => _gate = Completer<void>();

  void release() {
    final gate = _gate;
    _gate = null;
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  @override
  String get mode => 'modal-safety-test';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async => value = null;
  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    writes++;
    final gate = _gate;
    await gate?.future;
    if (value?.revision != expectedRevision) {
      throw const RepositoryException('版本冲突', conflict: true);
    }
    return value = Workspace.fromJson(
      next.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }
}

class _Harness {
  _Harness(this.store, this.controller, this.router);
  final _GateStore store;
  final SeraController controller;
  final GoRouter router;
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

Future<_Harness> _pump(
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
  final store = _GateStore(workspace);
  final controller = SeraController(
    repository: store,
    today: DateTime(2026, 10, 31),
    accountId: 'modal-account',
  );
  await controller.initialize();
  final router = GoRouter(
    initialLocation: path,
    routes: [
      GoRoute(
        path: '/04',
        builder: (_, _) => const Scaffold(body: Text('stable home')),
      ),
      GoRoute(
        path: '/destination',
        builder: (_, _) => const Scaffold(body: Text('stable destination')),
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
          ),
        ),
      ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    store.release();
    await tester.pump();
    controller.dispose();
    router.dispose();
  });
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: controller,
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
  return _Harness(store, controller, router);
}

Finder _button(String label) => find.widgetWithText(SeraButton, label);
Finder _input(String label) => find.descendant(
  of: find.widgetWithText(SeraInput, label),
  matching: find.byType(TextFormField),
);

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await _frames(tester);
}

void _keyboard(WidgetTester tester) {
  tester.view.viewInsets = const FakeViewPadding(bottom: 290);
  addTearDown(tester.view.resetViewInsets);
}

void main() {
  _safetyTest(
    'reminder sheet scrolls at 320px with keyboard and late save cannot pop its page',
    (tester) async {
      final task = SeraTask(
        id: 'long-reminder',
        title: List.filled(12, '核对课程设计展示材料与设备').join('，'),
      );
      final h = await _pump(
        tester,
        Workspace(revision: 1, tasks: [task]),
        '/04',
        narrow: true,
      );
      unawaited(h.router.push('/45?taskId=${task.id}'));
      await _frames(tester);
      _keyboard(tester);
      await tester.pump();
      await _tap(tester, _button('设置任务提醒'));
      await _tap(tester, find.text('开始前 30 分钟'));
      final save = _button('保存提醒');
      await tester.ensureVisible(save);
      await tester.pump();
      expect(save.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);

      final callback = tester.widget<SeraButton>(save).onPressed!;
      final sheetContext = tester.element(save);
      h.store.hold();
      callback();
      callback();
      await tester.pump();
      expect(h.store.writes, 1);
      // Finish while the dismissed sheet is still mounted in reverse motion.
      Navigator.of(sheetContext).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      h.store.release();
      await _frames(tester);
      expect(find.widgetWithText(AppBar, '任务提醒'), findsOneWidget);
      expect(find.text('stable home'), findsNothing);
      expect(h.controller.task(task.id)!.reminderMinutes, 30);
      expect(h.store.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final event in [false, true]) {
    _safetyTest(
      '${event ? 'event' : 'task'} save is deduplicated and cannot replace a later route',
      (tester) async {
        final h = await _pump(
          tester,
          const Workspace(revision: 1),
          event ? '/16' : '/19',
        );
        await tester.enterText(
          _input(event ? '日程名称' : '要做什么？'),
          event ? '待核对的固定事项' : '待核对的任务',
        );
        final callback = tester
            .widget<SeraButton>(_button(event ? '保存日程' : '保存任务'))
            .onPressed!;
        h.store.hold();
        callback();
        callback();
        await tester.pump();
        expect(h.store.writes, 1);
        unawaited(h.router.push('/destination'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 30));
        h.store.release();
        await _frames(tester);
        expect(find.text('stable destination'), findsOneWidget);
        expect(h.store.writes, 1);
        expect(
          event
              ? h.controller.data.entries.length
              : h.controller.data.tasks.length,
          1,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  _safetyTest('late task completion cannot open a result over the next page', (
    tester,
  ) async {
    const task = SeraTask(id: 'complete-task', title: '核对设计说明');
    final h = await _pump(
      tester,
      const Workspace(revision: 1, tasks: [task]),
      '/24?taskId=${task.id}',
    );
    h.store.hold();
    await _tap(tester, _button('完成任务'));
    expect(h.store.writes, 1);
    unawaited(h.router.push('/destination'));
    await tester.pump();
    h.store.release();
    await _frames(tester);
    expect(h.controller.task(task.id)!.done, isTrue);
    expect(find.text('stable destination'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  _safetyTest('late blocking feedback cannot start planning after leaving', (
    tester,
  ) async {
    const task = SeraTask(id: 'refine-task', title: '补充课程资料');
    final h = await _pump(
      tester,
      const Workspace(revision: 1, tasks: [task]),
      '/24?taskId=${task.id}',
    );
    await _tap(tester, _button('卡住了，记录原因并调整'));
    await tester.enterText(_input('记录阻碍和需要的帮助'), '需要先确认设计范围');
    h.store.hold();
    await _tap(tester, find.widgetWithText(TextButton, '记录并生成拆解建议'));
    expect(h.store.writes, 1);
    unawaited(h.router.push('/destination'));
    await tester.pump();
    h.store.release();
    await _frames(tester);
    expect(h.controller.task(task.id)!.status, 'blocked');
    expect(h.controller.data.planningSessions, isEmpty);
    expect(find.text('stable destination'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  _safetyTest(
    'editor exit post-frame callback cannot pop a newer destination',
    (tester) async {
      final h = await _pump(tester, const Workspace(revision: 1), '/19');
      tester.widget<SeraScaffold>(find.byType(SeraScaffold)).onBack!();
      unawaited(h.router.push('/destination'));
      await _frames(tester);
      expect(find.text('stable destination'), findsOneWidget);
      expect(h.store.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  _safetyTest(
    'long event deletion remains reachable and completion cannot steal a later route',
    (tester) async {
      final entry = CalendarEntry(
        id: 'delete-event',
        title: List.filled(15, '完整的课程讨论事项').join('，'),
        start: DateTime(2026, 11, 1, 15),
        end: DateTime(2026, 11, 1, 15, 30),
      );
      final h = await _pump(
        tester,
        Workspace(revision: 1, entries: [entry]),
        '/16?eventId=${entry.id}',
        narrow: true,
      );
      _keyboard(tester);
      await tester.pump();
      final callback = tester.widget<SeraButton>(_button('删除日程')).onPressed!;
      callback();
      callback();
      await _frames(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      final confirm = find.widgetWithText(TextButton, '确认删除');
      await tester.ensureVisible(confirm);
      expect(confirm.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      h.store.hold();
      await _tap(tester, confirm);
      expect(h.store.writes, 1);
      unawaited(h.router.push('/destination'));
      await tester.pump();
      h.store.release();
      await _frames(tester);
      expect(find.text('stable destination'), findsOneWidget);
      expect(h.controller.data.entries, isEmpty);
      expect(h.store.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  _safetyTest(
    'cancelled focus exit ignores a late pause without popping or navigating',
    (tester) async {
      const task = SeraTask(id: 'focus-task', title: '整理课程展示材料');
      final started = DateTime.now().subtract(const Duration(minutes: 1));
      final h = await _pump(
        tester,
        Workspace(
          revision: 1,
          tasks: [task],
          focusSession: FocusSession(
            id: 'ongoing-focus',
            taskId: task.id,
            startedAt: started,
            lastResumedAt: started,
          ),
        ),
        '/25?taskId=${task.id}',
      );
      await _tap(tester, find.byTooltip('返回'));
      final pause = find.widgetWithText(TextButton, '暂停并稍后继续');
      final callback = tester.widget<TextButton>(pause).onPressed!;
      h.store.hold();
      callback();
      callback();
      await tester.pump();
      expect(h.store.writes, 1);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '正在暂停…'))
            .onPressed,
        isNull,
      );
      // Cancellation is intentionally allowed while the accepted save runs.
      await tester.tap(find.widgetWithText(TextButton, '继续专注'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      h.store.release();
      await _frames(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.widgetWithText(AppBar, '专注一下'), findsOneWidget);
      expect(find.text('stable home'), findsNothing);
      expect(h.controller.data.focusSession!.isRunning, isFalse);
      expect(h.store.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  _safetyTest(
    'explicit focus finish saves once without another confirmation and leaves task progress for the user',
    (tester) async {
      const task = SeraTask(id: 'direct-stop', title: '整理需要继续的资料');
      final h = await _pump(
        tester,
        Workspace(
          revision: 1,
          tasks: [task],
          focusSession: FocusSession(
            id: 'paused-direct-stop',
            taskId: task.id,
            startedAt: DateTime.now().subtract(const Duration(minutes: 2)),
            accumulatedSeconds: 73,
            isRunning: false,
          ),
        ),
        '/25?taskId=${task.id}',
      );
      final stop = tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '结束并保存专注',
            ),
          )
          .onPressed!;
      h.store.hold();
      stop();
      stop();
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(h.store.writes, 1);
      h.store.release();
      await _frames(tester);
      expect(h.controller.data.focusSession, isNull);
      expect(h.controller.data.focusRecords, hasLength(1));
      expect(h.controller.data.focusRecords.single.seconds, 73);
      expect(h.controller.task(task.id)!.actualSeconds, 73);
      expect(h.controller.task(task.id)!.done, isFalse);
      expect(find.widgetWithText(AppBar, '专注结束'), findsOneWidget);
      expect(_button('已完成，更新任务进度'), findsOneWidget);
      expect(_button('还差一点，安排剩余时间'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(h.store.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  _safetyTest(
    'blocking input stays editable and cancellable with large text and keyboard',
    (tester) async {
      const task = SeraTask(id: 'blocked-task', title: '准备设计讲解');
      final h = await _pump(
        tester,
        const Workspace(revision: 1, tasks: [task]),
        '/24?taskId=${task.id}',
        narrow: true,
      );
      await _tap(tester, _button('卡住了，记录原因并调整'));
      _keyboard(tester);
      await tester.pump();
      final field = _input('记录阻碍和需要的帮助');
      await tester.ensureVisible(field);
      await tester.enterText(field, List.filled(30, '需要补充完整的设计依据。').join());
      await tester.pump();
      final cancel = find.widgetWithText(TextButton, '稍后记录');
      await tester.ensureVisible(cancel);
      expect(cancel.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _tap(tester, cancel);
      expect(h.store.writes, 0);
      expect(h.controller.task(task.id)!.status, 'todo');
      expect(tester.takeException(), isNull);
    },
  );

  _safetyTest('long task deletion can be cancelled without losing content', (
    tester,
  ) async {
    final task = SeraTask(
      id: 'delete-task',
      title: List.filled(15, '需要完整保留的任务名称').join('，'),
      checklist: const ['核对说明', '核对设备'],
    );
    final h = await _pump(
      tester,
      Workspace(revision: 1, tasks: [task]),
      '/43?taskId=${task.id}',
      narrow: true,
    );
    _keyboard(tester);
    await tester.pump();
    // /43 is already the confirmation surface; keeping the task must not
    // require opening and cancelling a second copy of the same confirmation.
    final cancel = _button('保留任务');
    await tester.ensureVisible(cancel);
    expect(cancel.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _tap(tester, cancel);
    expect(h.store.writes, 0);
    expect(h.controller.task(task.id)!.toJson(), task.toJson());
    unawaited(h.router.push('/43?taskId=${task.id}'));
    await _frames(tester);
    await _tap(tester, _button('确认删除'));
    expect(find.byType(AlertDialog), findsNothing);
    expect(h.store.writes, 1);
    expect(h.controller.task(task.id), isNull);
    expect(tester.takeException(), isNull);
  });

  _safetyTest(
    'existing event dates outside the default picker window can be cancelled',
    (tester) async {
      final entry = CalendarEntry(
        id: 'future-event',
        title: '已有远期安排',
        start: DateTime(2042, 5, 10, 9),
        end: DateTime(2042, 5, 10, 10),
      );
      final h = await _pump(
        tester,
        Workspace(revision: 1, entries: [entry]),
        '/16?eventId=${entry.id}',
      );
      final startField = find.byWidgetPredicate(
        (widget) => widget is SeraField && widget.label == '开始',
      );
      final displayed = tester.widget<SeraField>(startField).value;
      await _tap(tester, startField);
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await _tap(tester, find.widgetWithText(TextButton, '取消'));
      expect(tester.widget<SeraField>(startField).value, displayed);
      await _tap(tester, startField);
      await _tap(tester, find.widgetWithText(TextButton, '下一步'));
      expect(find.byType(TimePickerDialog), findsOneWidget);
      await _tap(tester, find.widgetWithText(TextButton, '取消'));
      expect(tester.widget<SeraField>(startField).value, displayed);
      expect(h.store.writes, 0);
      expect(h.controller.entry(entry.id)!.toJson(), entry.toJson());
      expect(tester.takeException(), isNull);
    },
  );
}
