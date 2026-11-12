import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/planning_ai_provider.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
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
CalendarEntry _event({DateTime? start, DateTime? end, bool allDay = false}) =>
    CalendarEntry(
      id: 'event-a',
      title: '核对材料',
      start: start ?? _at(3, 15),
      end: end ?? _at(3, 15, 30),
      notes: '原始备注',
      allDay: allDay,
    );
Future<void> _toggleAllDay(WidgetTester tester) =>
    _tap(tester, find.widgetWithText(SwitchListTile, '全天安排'));

void main() {
  testWidgets('new event save returns to its date with no stale return stack', (
    tester,
  ) async {
    final h = await _mount(tester, const Workspace(revision: 1), '/origin');
    unawaited(h.router.push('/16'));
    await _frames(tester);
    await tester.enterText(_input('日程名称'), '新日程');
    await _tap(tester, _button('保存日程'));
    expect(find.text('calendar list'), findsOneWidget);
    expect(h.store.writes, 1);
    expect(h.router.state.uri.path, '/12');
    expect(h.router.canPop(), isFalse);
    expect(
      h.controller.selectedDate,
      dateOnly(h.controller.data.entries.single.start),
    );
    expect(find.byType(TextFormField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('existing event save keeps its detail and origin context', (
    tester,
  ) async {
    final entry = _event();
    final h = await _mount(
      tester,
      Workspace(revision: 1, entries: [entry]),
      '/origin',
    );
    unawaited(h.router.push('/15?eventId=${entry.id}'));
    await _frames(tester);
    unawaited(h.router.push('/16?eventId=${entry.id}'));
    await _frames(tester);
    await tester.enterText(_input('日程名称'), '更新后的日程');
    await _tap(tester, _button('保存日程'));
    expect(find.widgetWithText(AppBar, '日程详情'), findsOneWidget);
    expect(h.router.state.uri.queryParameters['eventId'], entry.id);
    expect(h.store.writes, 1);
    await _tap(tester, find.byTooltip('返回'));
    expect(find.text('origin page'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final kind in ['task', 'event', 'draft']) {
    testWidgets('$kind edit and save cycles reuse the original page', (
      tester,
    ) async {
      final task = SeraTask(
        id: 'cycle-task',
        title: '待修改任务',
        goalId: kind == 'draft' ? 'cycle-goal' : null,
      );
      final event = _event();
      final draft = PlanDraft(
        id: 'cycle-draft',
        goal: SeraGoal(id: 'cycle-goal', title: '草案', deadline: _at(8, 18)),
        items: [PlannedTask(task: task)],
      );
      final h = await _mount(
        tester,
        Workspace(
          revision: 1,
          tasks: kind == 'task' ? [task] : [],
          entries: kind == 'event' ? [event] : [],
          drafts: kind == 'draft' ? [draft] : [],
        ),
        '/origin',
      );
      final origin = kind == 'event'
          ? '/15?eventId=${event.id}'
          : kind == 'draft'
          ? '/08?draftId=${draft.id}'
          : '/18?taskId=${task.id}';
      final editor = kind == 'event'
          ? '/16?eventId=${event.id}'
          : '/09?taskId=${task.id}${kind == 'draft' ? '&draftId=${draft.id}' : ''}';
      unawaited(h.router.push(origin));
      await _frames(tester);
      int depth() =>
          tester.widget<Navigator>(find.byType(Navigator).first).pages.length;
      expect(depth(), 2);
      for (var i = 0; i < 3; i++) {
        if (kind == 'draft') {
          unawaited(
            h.router.push(editor, extra: const {'replaceHistoryOnExit': true}),
          );
          await _frames(tester);
        } else {
          await _tap(tester, find.widgetWithText(TextButton, '编辑'));
        }
        expect(h.router.state.extra, const {'replaceHistoryOnExit': true});
        expect(depth(), 3);
        await tester.enterText(
          _input(
            kind == 'event'
                ? '日程名称'
                : kind == 'task'
                ? '要做什么？'
                : '任务名称',
          ),
          '第${i + 1}次修改',
        );
        await _tap(
          tester,
          _button(
            kind == 'event'
                ? '保存日程'
                : kind == 'draft'
                ? '保存到草案'
                : '保存任务',
          ),
        );
        expect(h.router.state.uri, Uri.parse(origin));
        expect(depth(), 2);
      }
      expect(h.store.writes, 3);
      h.router.pop();
      await _frames(tester);
      expect(find.text('origin page'), findsOneWidget);
      expect(h.router.canPop(), isFalse);
      expect(find.byType(TextFormField), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$kind direct edit saves to an effective root destination', (
      tester,
    ) async {
      final task = SeraTask(
        id: 'direct-task',
        title: '直接编辑任务',
        goalId: kind == 'draft' ? 'direct-goal' : null,
      );
      final event = _event();
      final draft = PlanDraft(
        id: 'direct-draft',
        goal: SeraGoal(id: 'direct-goal', title: '草案', deadline: _at(8, 18)),
        items: [PlannedTask(task: task)],
      );
      final h = await _mount(
        tester,
        Workspace(
          revision: 1,
          tasks: kind == 'task' ? [task] : [],
          entries: kind == 'event' ? [event] : [],
          drafts: kind == 'draft' ? [draft] : [],
        ),
        kind == 'event'
            ? '/16?eventId=${event.id}'
            : '/09?taskId=${task.id}${kind == 'draft' ? '&draftId=${draft.id}' : ''}',
      );
      await tester.enterText(
        _input(kind == 'event' ? '日程名称' : '任务名称'),
        '直接保存的修改',
      );
      await _tap(
        tester,
        _button(
          kind == 'event'
              ? '保存日程'
              : kind == 'draft'
              ? '保存到草案'
              : '保存任务',
        ),
      );
      expect(
        h.router.state.uri.path.split('-').first,
        kind == 'event'
            ? '/15'
            : kind == 'draft'
            ? '/08'
            : '/18',
      );
      expect(h.router.canPop(), isFalse);
      expect(find.byType(TextFormField), findsNothing);
      expect(h.store.writes, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'unchanged event system back leaves without a discard dialog or write',
    (tester) async {
      final entry = _event();
      final h = await _mount(
        tester,
        Workspace(revision: 1, entries: [entry]),
        '/origin',
      );
      unawaited(h.router.push('/16?eventId=${entry.id}'));
      await _frames(tester);
      await Navigator.of(tester.element(_input('日程名称'))).maybePop();
      await _frames(tester);
      expect(find.text('origin page'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(h.store.writes, 0);
      expect(h.controller.entry(entry.id)!.toJson(), entry.toJson());
    },
  );
  for (final label in ['日程名称', '地点', '备注']) {
    testWidgets(
      'event dirty $label survives continue and discard never writes',
      (tester) async {
        final entry = _event();
        final h = await _mount(
          tester,
          Workspace(revision: 1, entries: [entry]),
          '/origin',
        );
        unawaited(h.router.push('/16?eventId=${entry.id}'));
        await _frames(tester);
        await tester.enterText(_input(label), '尚未保存的输入');
        await Navigator.of(tester.element(_input(label))).maybePop();
        await _frames(tester);
        expect(find.text('放弃尚未保存的修改？'), findsOneWidget);
        await _tap(tester, find.widgetWithText(TextButton, '继续编辑'));
        expect(_text(tester, label), '尚未保存的输入');
        await _tap(tester, find.byTooltip('返回'));
        await _tap(tester, find.widgetWithText(TextButton, '放弃修改'));
        expect(find.text('origin page'), findsOneWidget);
        expect(h.store.writes, 0);
        expect(h.controller.entry(entry.id)!.toJson(), entry.toJson());
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final range in [
    (_at(3, 15), _at(3, 15, 30)),
    (_at(3, 23, 30), _at(4, 1)),
    (_at(3, 23), _at(4, 0)),
  ]) {
    testWidgets('all-day round trip preserves exact timed range $range', (
      tester,
    ) async {
      final entry = _event(start: range.$1, end: range.$2);
      final h = await _mount(
        tester,
        Workspace(revision: 1, entries: [entry]),
        '/16?eventId=${entry.id}',
      );
      await _toggleAllDay(tester);
      await _toggleAllDay(tester);
      await _tap(tester, _button('保存日程'));
      final saved = h.controller.entry(entry.id)!;
      expect(saved.start, range.$1);
      expect(saved.end, range.$2);
      expect(saved.allDay, isFalse);
      expect(h.store.writes, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'all-day date edit restores remembered clocks on the chosen date',
    (tester) async {
      final entry = _event();
      final h = await _mount(
        tester,
        Workspace(revision: 1, entries: [entry]),
        '/16?eventId=${entry.id}',
      );
      await _toggleAllDay(tester);
      await _tap(tester, find.widgetWithText(SeraField, '开始'));
      final dialog = find.byType(DatePickerDialog);
      final l = MaterialLocalizations.of(tester.element(dialog));
      await _tap(tester, find.byTooltip(l.inputDateModeButtonLabel));
      await tester.enterText(
        find.descendant(of: dialog, matching: find.byType(TextFormField)),
        l.formatCompactDate(_at(5, 0)),
      );
      await _tap(tester, find.widgetWithText(TextButton, '下一步'));
      await _toggleAllDay(tester);
      await _tap(tester, _button('保存日程'));
      expect(h.controller.entry(entry.id)!.start, _at(5, 15));
      expect(h.controller.entry(entry.id)!.end, _at(5, 15, 30));
      expect(tester.takeException(), isNull);
    },
  );

  for (final days in [1, 3]) {
    testWidgets('all-day detail shows $days calendar days with exclusive end', (
      tester,
    ) async {
      final entry = _event(
        start: _at(3, 0),
        end: _at(3 + days, 0),
        allDay: true,
      );
      await _mount(
        tester,
        Workspace(revision: 1, entries: [entry]),
        '/15?eventId=${entry.id}',
      );
      final subtitle = tester
          .widget<SeraIntro>(find.byType(SeraIntro))
          .subtitle!;
      expect(subtitle, contains('全天'));
      expect(subtitle, contains(formatDate(_at(3, 0))));
      if (days > 1) expect(subtitle, contains(formatDate(_at(2 + days, 0))));
      expect(subtitle, isNot(contains(formatDate(_at(3 + days, 0)))));
      expect(find.widgetWithText(SeraField, '$days 天'), findsOneWidget);
    });
  }
  testWidgets('timed detail includes both dates across a year boundary', (
    tester,
  ) async {
    final entry = _event(
      start: inTimeZone(
        DateTime(2026, 12, 31, 23),
        'Asia/Hong_Kong',
        wallClock: true,
      ),
      end: inTimeZone(
        DateTime(2027, 1, 1, 1),
        'Asia/Hong_Kong',
        wallClock: true,
      ),
    );
    await _mount(
      tester,
      Workspace(revision: 1, entries: [entry]),
      '/15?eventId=${entry.id}',
    );
    final subtitle = tester.widget<SeraIntro>(find.byType(SeraIntro)).subtitle!;
    for (final text in ['2026年', '2027年', '23:00', '01:00']) {
      expect(subtitle, contains(text));
    }
  });

  for (final kind in ['task', 'event', 'draft']) {
    testWidgets(
      'deleting $kind removes the deleted object from the return stack',
      (tester) async {
        const task = SeraTask(id: 'task-a', title: '可删除任务');
        final entry = _event();
        final plan = PlanDraft(
          id: 'draft-a',
          goal: SeraGoal(id: 'goal-a', title: '草案目标', deadline: _at(8, 18)),
          items: const [PlannedTask(task: task)],
        );
        final h = await _mount(
          tester,
          Workspace(
            revision: 1,
            tasks: kind == 'task' ? [task] : [],
            entries: kind == 'event' ? [entry] : [],
            drafts: kind == 'draft' ? [plan] : [],
          ),
          '/origin',
        );
        unawaited(
          h.router.push(
            kind == 'event'
                ? '/15?eventId=${entry.id}'
                : '/18?taskId=${task.id}',
          ),
        );
        await _frames(tester);
        final suffix = kind == 'draft' ? '&draftId=${plan.id}' : '';
        unawaited(
          h.router.push(
            kind == 'event'
                ? '/16?eventId=${entry.id}'
                : '/09?taskId=${task.id}$suffix',
          ),
        );
        await _frames(tester);
        await _tap(
          tester,
          _button(
            kind == 'event'
                ? '删除日程'
                : kind == 'draft'
                ? '删除这项草案任务'
                : '删除这项任务',
          ),
        );
        await _tap(tester, find.widgetWithText(TextButton, '确认删除'));
        expect(h.router.canPop(), isFalse);
        expect(
          h.router.state.uri.path,
          kind == 'event'
              ? '/12'
              : kind == 'draft'
              ? '/08'
              : '/17',
        );
        expect(h.store.writes, 1);
        if (kind == 'event') expect(h.controller.entry(entry.id), isNull);
        if (kind == 'task') expect(h.controller.task(task.id), isNull);
        if (kind == 'draft') {
          expect(h.controller.draft(plan.id)!.items, isEmpty);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('failed focus start cannot finish or show success', (
    tester,
  ) async {
    const prerequisite = SeraTask(id: 'before', title: '尚未完成前置事项');
    const task = SeraTask(
      id: 'blocked',
      title: '等待前置事项',
      dependencyIds: ['before'],
    );
    final h = await _mount(
      tester,
      const Workspace(revision: 1, tasks: [prerequisite, task]),
      '/25?taskId=blocked',
    );
    expect(find.text('请先完成前置任务。'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '结束并保存专注',
            ),
          )
          .onPressed,
      isNull,
    );
    expect(h.controller.data.focusSession, isNull);
    expect(h.controller.data.focusRecords, isEmpty);
    await _tap(tester, find.byTooltip('返回'));
    expect(h.router.state.uri.path, '/18');
    expect(find.widgetWithText(AppBar, '专注结束'), findsNothing);
    expect(h.store.writes, 0);
  });
  for (final notes in ['', '检查项已完成，保留这条实际备注']) {
    testWidgets(
      'focus target and completed checklist use actual remaining work "$notes"',
      (tester) async {
        final task = SeraTask(
          id: 'focus-a',
          title: '专注任务',
          estimatedMinutes: 60,
          remainingMinutes: 15,
          checklist: const ['已经完成'],
          completedChecks: const ['已经完成'],
          notes: notes,
        );
        final h = await _mount(
          tester,
          Workspace(
            revision: 1,
            tasks: [task],
            focusSession: FocusSession(
              id: 'focus-session',
              taskId: task.id,
              startedAt: DateTime.now(),
              isRunning: false,
              accumulatedSeconds: 73,
            ),
          ),
          '/25?taskId=${task.id}',
        );
        expect(find.text('目标 15分钟 · 已暂停'), findsOneWidget);
        expect(find.text('13:47'), findsOneWidget);
        expect(
          find.text('这次先做到'),
          notes.isEmpty ? findsNothing : findsOneWidget,
        );
        if (notes.isNotEmpty) expect(find.text(notes), findsOneWidget);
        expect(h.store.writes, 0);
      },
    );
  }

  for (final kind in ['task', 'event']) {
    testWidgets(
      'transactional $kind cancel keeps one origin and its pending session',
      (tester) async {
        final session = PlanningSession(
          id: 'transactional-$kind',
          prompt: '保留原始记录',
          notes: '保留补充信息',
          updatedAt: DateTime(2026, 10, 31),
        );
        final h = await _mount(
          tester,
          Workspace(revision: 1, planningSessions: [session]),
          '/origin',
        );
        unawaited(
          h.router.push(
            '/${kind == 'task' ? '19' : '16'}?sessionId=${session.id}&manual=1',
            extra: const {'replaceHistoryOnExit': true},
          ),
        );
        await _frames(tester);
        expect(
          _text(tester, kind == 'task' ? '要做什么？' : '日程名称'),
          session.prompt,
        );
        await _tap(tester, find.byTooltip('返回'));
        await _tap(tester, find.widgetWithText(TextButton, '放弃修改'));
        expect(find.text('origin page'), findsOneWidget);
        expect(h.router.canPop(), isFalse);
        expect(
          h.controller.planningSession(session.id)!.toJson(),
          session.toJson(),
        );
        expect(h.controller.data.tasks, isEmpty);
        expect(h.controller.data.entries, isEmpty);
        expect(h.store.writes, 0);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'session $kind saves once, reopens its returned ID and never recreates a deleted result',
      (tester) async {
        final interpretation = AiUnderstanding(
          intent: kind,
          title: '理解后的标题',
          summary: '结构摘要',
          outcome: '完成标准',
          model: 'fixture',
          estimatedMinutes: 15,
          start: kind == 'event' ? _at(3, 15) : null,
          end: kind == 'event' ? _at(3, 15, 30) : null,
        );
        final session = PlanningSession(
          id: 'input-$kind',
          updatedAt: DateTime(2026, 10, 31),
          prompt: '原始输入保持在会话',
          notes: '用户补充',
          stage: 'understood',
          understanding: interpretation.toJson(),
          clarificationAnswers: const {'材料': '带纸质版'},
        );
        final path =
            '/${kind == 'task' ? '19' : '16'}?sessionId=${session.id}&fromAi=1';
        final h = await _mount(
          tester,
          Workspace(revision: 1, planningSessions: [session]),
          path,
        );
        expect(_text(tester, kind == 'task' ? '要做什么？' : '日程名称'), '理解后的标题');
        final notes = _text(tester, kind == 'task' ? '补充说明' : '备注');
        for (final text in ['结构摘要', '完成标准', '用户补充', '带纸质版', '原始输入保持在会话']) {
          expect(notes, contains(text));
        }
        await _tap(tester, _button(kind == 'task' ? '保存任务' : '保存日程'));
        final savedSession = h.controller.planningSession(session.id)!;
        final ref = savedSession.resultEntity!;
        final key = kind == 'task' ? 'taskId' : 'eventId';
        expect(savedSession.stage, 'confirmed');
        expect(ref.kind, kind);
        expect(h.controller.hasPlanningResult(ref), isTrue);
        expect(h.router.state.uri.path, kind == 'task' ? '/17' : '/12');
        expect(h.router.canPop(), isFalse);
        if (kind == 'task') {
          expect(h.router.state.uri.queryParameters['filter'], 'inbox');
          expect(find.text('理解后的标题'), findsOneWidget);
        } else {
          expect(h.controller.selectedDate, dateOnly(_at(3, 15)));
        }
        expect(h.store.writes, 1);
        h.router.go(path);
        await _frames(tester);
        expect(h.router.state.uri.queryParameters[key], ref.id);
        expect(h.store.writes, 1);
        if (kind == 'task') {
          await h.controller.deleteTask(ref.id);
        } else {
          await h.controller.deleteEntry(ref.id);
        }
        h.router.go(path);
        await _frames(tester);
        expect(find.textContaining('已删除，请开始新的输入。'), findsOneWidget);
        expect(_button(kind == 'task' ? '保存任务' : '保存日程'), findsNothing);
        expect(h.store.writes, 2);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'manual session $kind preserves raw input and cancellation never confirms',
      (tester) async {
        final session = PlanningSession(
          id: 'manual-$kind',
          updatedAt: DateTime(2026, 10, 31),
          prompt: '手动记录事项',
          notes: '真实补充',
          stage: 'understood',
          understanding: const AiUnderstanding(
            intent: 'goal',
            title: 'AI判为目标',
            summary: '模型摘要',
            outcome: '',
            model: 'fixture',
          ).toJson(),
        );
        final h = await _mount(
          tester,
          Workspace(revision: 1, planningSessions: [session]),
          '/origin',
        );
        unawaited(
          h.router.push(
            '/${kind == 'task' ? '19' : '16'}?sessionId=${session.id}&manual=1',
          ),
        );
        await _frames(tester);
        expect(_text(tester, kind == 'task' ? '要做什么？' : '日程名称'), '手动记录事项');
        expect(find.text('来自AI的建议，请核对后保存'), findsNothing);
        expect(_text(tester, kind == 'task' ? '补充说明' : '备注'), contains('真实补充'));
        await _tap(tester, find.byTooltip('返回'));
        await _tap(tester, find.widgetWithText(TextButton, '放弃修改'));
        expect(find.text('origin page'), findsOneWidget);
        expect(
          h.controller.planningSession(session.id)!.toJson(),
          session.toJson(),
        );
        expect(h.store.writes, 0);
      },
    );
  }
  testWidgets(
    'inbox query opens unscheduled tasks while an absent filter shows all unfinished tasks',
    (tester) async {
      const inbox = SeraTask(id: 'inbox-only', title: '尚未安排');
      const scheduled = SeraTask(id: 'today-only', title: '只在今天');
      final h = await _mount(
        tester,
        Workspace(
          revision: 1,
          tasks: [inbox, scheduled],
          entries: [
            CalendarEntry(
              id: 'today-entry',
              title: scheduled.title,
              taskId: scheduled.id,
              start: inTimeZone(
                DateTime(2026, 10, 31, 15),
                'Asia/Hong_Kong',
                wallClock: true,
              ),
              end: inTimeZone(
                DateTime(2026, 10, 31, 15, 30),
                'Asia/Hong_Kong',
                wallClock: true,
              ),
            ),
          ],
        ),
        '/17?filter=inbox',
      );
      expect(find.text(inbox.title), findsOneWidget);
      expect(find.text(scheduled.title), findsNothing);
      h.router.go('/17');
      await _frames(tester);
      expect(find.text(scheduled.title), findsOneWidget);
      expect(find.text(inbox.title), findsOneWidget);
      expect(h.store.writes, 0);
    },
  );
  for (final event in [false, true]) {
    testWidgets(
      '${event ? 'event' : 'task'} reveals its first invalid field and failed save retains input',
      (tester) async {
        final h = await _mount(
          tester,
          const Workspace(revision: 1),
          event ? '/16' : '/19',
        );
        tester.view.physicalSize = const Size(320, 844);
        tester.view.viewInsets = const FakeViewPadding(bottom: 290);
        addTearDown(tester.view.resetViewInsets);
        await tester.pump();
        final save = _button(event ? '保存日程' : '保存任务');
        await _tap(tester, save);
        final title = _input(event ? '日程名称' : '要做什么？');
        expect(title.hitTestable(), findsOneWidget);
        expect(h.store.writes, 0);
        await tester.enterText(title, '失败后仍然保留');
        h.store.reject = true;
        await _tap(tester, save);
        expect(_text(tester, event ? '日程名称' : '要做什么？'), '失败后仍然保留');
        expect(find.text('测试保存失败，输入仍可编辑。'), findsOneWidget);
        expect(find.text('测试保存失败，输入仍可编辑。').hitTestable(), findsOneWidget);
        expect(h.router.state.uri.path, event ? '/16' : '/19');
        expect(h.store.writes, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'invalid execution fields reopen the disclosure and scroll into view',
    (tester) async {
      final h = await _mount(tester, const Workspace(revision: 1), '/19');
      await tester.enterText(_input('要做什么？'), '保留有效标题');
      await _tap(tester, find.text('执行方式与前置条件'));
      final remaining = _input('还需用时（分钟）');
      await tester.enterText(remaining, '999');
      await _tap(tester, find.text('执行方式与前置条件'));
      await _tap(tester, _button('保存任务'));
      expect(remaining.hitTestable(), findsOneWidget);
      expect(find.text('请输入 0–480 分钟。'), findsOneWidget);
      expect(_text(tester, '要做什么？'), '保留有效标题');
      expect(h.store.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
