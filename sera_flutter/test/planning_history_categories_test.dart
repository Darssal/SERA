import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';

final _now = readZoned('2026-11-02T09:00:00+08:00', 'Asia/Hong_Kong')!;

PlanDraft _draft(String id, String title, {String status = 'draft'}) =>
    PlanDraft(
      id: id,
      status: status,
      goal: SeraGoal(
        id: 'goal-$id',
        title: title,
        deadline: calendarDay(_now, 20),
        taskIds: ['task-$id'],
      ),
      items: [
        PlannedTask(
          task: SeraTask(
            id: 'task-$id',
            title: '草案任务-$id',
            goalId: 'goal-$id',
            estimatedMinutes: 15,
          ),
        ),
      ],
    );

Workspace _workspace() {
  final committed = _draft('committed', '已经提交的规划', status: 'committed');
  return Workspace(
    revision: 1,
    planningSessions: [
      for (var i = 0; i < 50; i++)
        PlanningSession(
          id: 'session-$i',
          title: '续聊 $i',
          prompt: '保留第 $i 项输入',
          updatedAt: _now.add(Duration(minutes: i)),
        ),
    ],
    drafts: [_draft('pending', '待核对的规划'), committed],
    goals: [committed.goal],
    tasks: [committed.items.single.task],
    entries: [
      CalendarEntry(
        id: 'formal-entry',
        title: '正式日程',
        start: _now,
        end: _now.add(const Duration(minutes: 30)),
      ),
    ],
    history: [
      for (var i = 0; i < 25; i++)
        ChangeRecord(
          id: 'record-$i',
          label: '操作记录 $i',
          at: _now.add(Duration(minutes: i)),
        ),
    ],
  );
}

class _Store implements WorkspaceRepository {
  _Store(this.value);
  Workspace value;
  int writes = 0;
  @override
  String get mode => 'planning-history-categories-test';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async {}
  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    if (expectedRevision != value.revision) {
      throw const RepositoryException('版本冲突', conflict: true);
    }
    writes++;
    return value = Workspace.fromJson(
      next.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<SeraController> _mount(WidgetTester tester, _Store store) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final controller = SeraController(
    repository: store,
    today: _now,
    seedDemo: false,
    accountId: 'history-categories-test',
  );
  await controller.initialize();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    controller.dispose();
  });
  await tester.pumpWidget(
    SeraApp(controller: controller, initialLocation: '/34'),
  );
  await _frames(tester);
  return controller;
}

GoRouter _router(WidgetTester tester) =>
    GoRouter.of(tester.element(find.byType(SeraScaffold).last));
Set<String> _selected(WidgetTester tester) => tester
    .widget<SegmentedButton<String>>(
      find.byKey(const ValueKey('planning-history-tabs')),
    )
    .selected;
Future<void> _tap(WidgetTester tester, Finder target) async {
  // Category controls and the latest operation must be directly reachable.
  expect(tester.getRect(target).top, greaterThanOrEqualTo(0));
  expect(tester.getRect(target).bottom, lessThanOrEqualTo(844));
  await tester.tap(target);
  await _frames(tester);
}

void main() {
  testWidgets('50 conversations do not bury the latest operations or drafts', (
    tester,
  ) async {
    final store = _Store(_workspace());
    final c = await _mount(tester, store);
    final before = c.data.toJson();
    expect(_selected(tester), {'sessions'});
    expect(find.text('续聊 49'), findsOneWidget);
    expect(find.text('操作记录 24'), findsNothing);
    expect(find.text('已经提交的规划'), findsNothing);

    await _tap(tester, find.text('操作'));
    expect(_selected(tester), {'operations'});
    expect(find.text('续聊 49'), findsNothing);
    expect(find.text('操作记录 24'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('操作记录 24')).dy,
      lessThan(tester.getTopLeft(find.text('操作记录 23')).dy),
    );
    expect(find.text('操作记录 4'), findsNothing);
    await _tap(tester, find.text('操作记录 24'));
    expect(find.byType(AlertDialog), findsOneWidget);
    await _tap(tester, find.widgetWithText(TextButton, '关闭'));
    expect(_selected(tester), {'operations'});

    await _tap(tester, find.text('草案'));
    expect(find.text('续聊 49'), findsNothing);
    expect(find.text('操作记录 24'), findsNothing);
    expect(find.text('已经提交的规划'), findsOneWidget);
    expect(find.text('待核对的规划'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('已经提交的规划')).dy,
      lessThan(tester.getTopLeft(find.text('待核对的规划')).dy),
    );
    await _tap(tester, find.text('对话'));
    expect(find.text('续聊 49'), findsOneWidget);
    expect(find.text('已经提交的规划'), findsNothing);
    expect(c.data.toJson(), before);
    expect(store.writes, 0);
    expect(find.byTooltip('清除规划记录'), findsOneWidget);
    expect(find.widgetWithText(AppBar, '规划记录'), findsOneWidget);
    expect(find.text('搜索目标与事项'), findsNothing);
    expect(find.text('管理规划数据'), findsNothing);
    expect(find.widgetWithText(SeraButton, '新对话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'new history entry defaults to conversations and opens original IDs',
    (tester) async {
      final c = await _mount(tester, _Store(_workspace()));
      final router = _router(tester);
      expect(_selected(tester), {'sessions'});
      await _tap(tester, find.text('续聊 49'));
      expect(
        router.routeInformationProvider.value.uri.queryParameters['sessionId'],
        'session-49',
      );
      expect(find.text('保留第 49 项输入'), findsWidgets);
      await _tap(tester, find.byTooltip('返回'));
      expect(_selected(tester), {'sessions'});
      await _tap(tester, find.text('操作'));
      router.go('/04');
      await _frames(tester);
      unawaited(router.push('/34'));
      await _frames(tester);
      expect(_selected(tester), {'sessions'});

      await _tap(tester, find.text('草案'));
      await _tap(tester, find.text('待核对的规划'));
      expect(
        router.routeInformationProvider.value.uri.queryParameters['draftId'],
        'pending',
      );
      expect(c.draft('pending')!.goal.title, '待核对的规划');
      expect(c.data.tasks, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'clearing from operations retains formal objects and committed drafts',
    (tester) async {
      final c = await _mount(tester, _Store(_workspace()));
      final tasks = c.data.tasks.map((x) => x.toJson()).toList();
      final goals = c.data.goals.map((x) => x.toJson()).toList();
      final entries = c.data.entries.map((x) => x.toJson()).toList();
      await _tap(tester, find.text('操作'));
      await _tap(tester, find.byTooltip('清除规划记录'));
      expect(find.text('将清除对话输入和尚未确认的草案。已经创建的目标、任务和日程会保留。'), findsOneWidget);
      await _tap(tester, find.widgetWithText(TextButton, '保留记录'));
      expect(c.data.planningSessions, hasLength(50));
      expect(c.data.drafts, hasLength(2));
      await _tap(tester, find.byTooltip('清除规划记录'));
      await _tap(tester, find.widgetWithText(TextButton, '确认清除'));

      expect(_selected(tester), {'operations'});
      expect(c.data.planningSessions, isEmpty);
      expect(c.data.drafts.map((x) => x.id), ['committed']);
      expect(c.data.tasks.map((x) => x.toJson()).toList(), tasks);
      expect(c.data.goals.map((x) => x.toJson()).toList(), goals);
      expect(c.data.entries.map((x) => x.toJson()).toList(), entries);
      expect(c.data.history.any((x) => x.id == 'record-24'), isTrue);
      await _tap(tester, find.text('对话'));
      expect(find.text('还没有对话记录'), findsOneWidget);
      await _tap(tester, find.text('草案'));
      expect(find.text('已经提交的规划'), findsOneWidget);
      expect(find.text('待核对的规划'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
