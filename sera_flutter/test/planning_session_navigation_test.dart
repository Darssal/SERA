import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/data/planning_ai_provider.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/sera_motion.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:sera_flutter/ui/screens/planning_screens.dart';

final _today = DateTime(2026, 10, 31);
const _preferences = SeraPreferences(
  weekdays: [1, 2, 3, 4, 5, 6, 7],
  dailyBudget: 480,
  startMinute: 480,
  endMinute: 1200,
  bufferMinutes: 10,
  restStart: 0,
  restEnd: 0,
);

class _NavigationStore
    implements WorkspaceRepository, InputUnderstandingProvider {
  _NavigationStore(this.value);
  Workspace value;
  int writes = 0, requests = 0;
  final inputs = <Json>[];
  @override
  String get mode => 'planning-navigation-isolated-fixture';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async {}
  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    if (value.revision != expectedRevision) {
      throw const RepositoryException('合成版本冲突', conflict: true);
    }
    writes++;
    return value = Workspace.fromJson(
      next.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }

  @override
  Future<AiUnderstanding> understandInput({
    required Json input,
    required String requestId,
    void Function(String stage)? onStage,
  }) async {
    requests++;
    inputs.add(input);
    return const AiUnderstanding(
      intent: 'task',
      title: '保留的待核对任务',
      summary: '合成理解结果',
      outcome: '',
      model: 'isolated-fixture',
      estimatedMinutes: 30,
    );
  }
}

class _NavigationHarness {
  _NavigationHarness(this.c, String initialLocation) {
    router = GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(
          path: '/origin',
          builder: (context, _) => Scaffold(
            body: TextButton(
              onPressed: () => context.push('/08?draftId=draft'),
              child: const Text('打开草案'),
            ),
          ),
        ),
        GoRoute(
          path: '/:screen',
          builder: (_, state) {
            final id = state.pathParameters['screen']!.split('-').first;
            if (const ['18', '15', '19', '16'].contains(id)) {
              return SeraScaffold(
                title: '实际事项入口',
                body: Text('目标路径:${state.uri}'),
              );
            }
            return buildPlanningScreen(
              id,
              draftId: state.uri.queryParameters['draftId'],
              taskId: state.uri.queryParameters['taskId'],
            );
          },
        ),
      ],
    );
  }
  final SeraController c;
  late final GoRouter router;
  Uri get uri => router.routerDelegate.state.uri;
  String get screen => uri.pathSegments.first.split('-').first;
  Widget get widget => MultiProvider(
    providers: [
      ChangeNotifierProvider<SeraController>.value(value: c),
      Provider<AuthRepository?>.value(value: null),
    ],
    child: MaterialApp.router(
      routerConfig: router,
      theme: seraTheme(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (_, child) => SeraMotionScope(child: child!),
    ),
  );
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<_NavigationHarness> _mount(
  WidgetTester tester,
  _NavigationStore store,
  String path,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final c = SeraController(repository: store, today: _today, seedDemo: false);
  await c.initialize();
  final harness = _NavigationHarness(c, path);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    harness.router.dispose();
    c.dispose();
  });
  await tester.pumpWidget(harness.widget);
  await _frames(tester);
  return harness;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await _frames(tester);
}

Workspace _replanFixture() {
  const future = SeraTask(id: 'future', title: '未来任务');
  const split = SeraTask(
    id: 'split',
    title: '今日分段任务',
    estimatedMinutes: 60,
    splittable: true,
  );
  const other = SeraTask(id: 'other', title: '今日另一项任务');
  const done = SeraTask(id: 'done', title: '已完成任务', done: true);
  CalendarEntry block(String id, SeraTask task, int day, int hour) =>
      CalendarEntry(
        id: id,
        taskId: task.id,
        title: task.title,
        start: DateTime(2026, 10, day, hour),
        end: DateTime(2026, 10, day, hour, 30),
      );
  return Workspace(
    revision: 1,
    preferences: _preferences,
    tasks: [future, split, other, done],
    entries: [
      block('future-block', future, 32, 10),
      block('split-future', split, 32, 14),
      block('split-today', split, 31, 14),
      block('other-today', other, 31, 16),
      block('done-today', done, 31, 18),
      CalendarEntry(
        id: 'fixed',
        title: '固定日程',
        start: DateTime(2026, 10, 31, 9),
        end: DateTime(2026, 10, 31, 9, 30),
        locked: true,
      ),
    ],
  );
}

PlanDraft _draft({bool committed = false}) {
  const task = SeraTask(id: 'draft-task', title: '整理实际资料', goalId: 'goal');
  return PlanDraft(
    id: 'draft',
    goal: SeraGoal(
      id: 'goal',
      title: '课程设计',
      deadline: DateTime(2026, 11, 7, 18),
      taskIds: [task.id],
    ),
    items: const [PlannedTask(task: task)],
    status: committed ? 'committed' : 'draft',
  );
}

void main() {
  for (final screen in ['22', '23']) {
    testWidgets(
      '$screen without an available slot offers recovery without showing a change result',
      (tester) async {
        final original = _replanFixture();
        final store = _NavigationStore(
          original.copyWith(preferences: _preferences.copyWith(weekdays: [])),
        );
        final h = await _mount(
          tester,
          store,
          '/$screen?taskId=split&entryId=split-today',
        );
        expect(find.widgetWithText(AppBar, '暂无可用时段'), findsOneWidget);
        expect(find.text('今日分段任务'), findsOneWidget);
        expect(find.textContaining('当前安排 · '), findsOneWidget);
        expect(find.text('移动时间'), findsNothing);
        expect(find.text('新增任务'), findsNothing);
        expect(find.text('删除任务'), findsNothing);
        expect(find.text('只调整这项任务的时间。'), findsNothing);
        expect(find.text('只调整选中的这段安排，其他安排不变。'), findsNothing);
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Text &&
                widget.style?.decoration == TextDecoration.lineThrough,
          ),
          findsNothing,
        );
        expect(find.widgetWithText(SeraButton, '确认调整 1 项任务'), findsNothing);
        final recovery = find.widgetWithText(SeraButton, '修改规划偏好');
        expect(tester.widget<SeraButton>(recovery).onPressed, isNotNull);
        final manual = find.widgetWithText(SeraButton, '手动调整任务');
        expect(tester.widget<SeraButton>(manual).onPressed, isNotNull);
        expect(
          h.c.data.entries.map((e) => e.toJson()).toList(),
          original.entries.map((e) => e.toJson()).toList(),
        );
        expect(store.writes, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'today chooses the selected current-day block and preserves all siblings',
    (tester) async {
      final store = _NavigationStore(_replanFixture());
      final h = await _mount(tester, store, '/22?scope=today');
      expect(find.text('选择要调整的安排'), findsOneWidget);
      expect(find.text('今日分段任务'), findsOneWidget);
      expect(find.text('今日另一项任务'), findsOneWidget);
      expect(find.text('未来任务'), findsNothing);
      expect(find.text('已完成任务'), findsNothing);
      expect(find.text('固定日程'), findsNothing);
      final before = {
        for (final entry in h.c.data.entries) entry.id: entry.toJson(),
      };
      await _tap(tester, find.text('今日分段任务'));
      await _tap(tester, find.widgetWithText(SeraButton, '查看变更并确认'));
      expect(h.screen, '23');
      expect(h.uri.queryParameters['taskId'], 'split');
      expect(h.uri.queryParameters['entryId'], 'split-today');
      expect(h.uri.queryParameters['scope'], 'today');
      expect(find.text('只调整选中的这段安排，其他安排不变。'), findsOneWidget);
      await _tap(tester, find.widgetWithText(SeraButton, '确认调整 1 项任务'));
      expect(h.screen, '12');
      expect(find.text('安排已调整'), findsOneWidget);
      expect(
        h.c.entry('split-today')!.start,
        isNot(DateTime(2026, 10, 31, 14)),
      );
      for (final id in before.keys.where((id) => id != 'split-today')) {
        expect(h.c.entry(id)!.toJson(), before[id]);
      }
      expect(store.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an empty today scope never falls back to the first future task',
    (tester) async {
      final base = _replanFixture();
      final store = _NavigationStore(
        base.copyWith(
          entries: base.entries.where((e) => e.start.day == 1).toList(),
        ),
      );
      final h = await _mount(tester, store, '/22?scope=today');
      expect(find.text('这一天没有可调整的任务安排'), findsOneWidget);
      expect(find.text('未来任务'), findsNothing);
      expect(find.widgetWithText(SeraButton, '查看变更并确认'), findsNothing);
      expect(h.c.data.entries, hasLength(2));
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an explicit calendar date selects only that date across the month boundary',
    (tester) async {
      final store = _NavigationStore(_replanFixture());
      final h = await _mount(tester, store, '/22?date=2026-11-01');
      expect(find.text('未来任务'), findsOneWidget);
      expect(find.text('今日分段任务'), findsOneWidget);
      expect(find.text('今日另一项任务'), findsNothing);
      await _tap(tester, find.text('未来任务'));
      await _tap(tester, find.widgetWithText(SeraButton, '查看变更并确认'));
      expect(h.uri.queryParameters['entryId'], 'future-block');
      expect(h.uri.queryParameters['date'], '2026-11-01');
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'invalid calendar dates do not silently select an unrelated task',
    (tester) async {
      final h = await _mount(
        tester,
        _NavigationStore(_replanFixture()),
        '/22?date=2026-02-31',
      );
      expect(find.text('日期无效'), findsOneWidget);
      expect(find.widgetWithText(SeraButton, '查看变更并确认'), findsNothing);
      expect(h.screen, '22');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit taskId remains compatible with the direct replan route',
    (tester) async {
      final h = await _mount(
        tester,
        _NavigationStore(_replanFixture()),
        '/22?taskId=future',
      );
      expect(find.text('选择要调整的安排'), findsNothing);
      await _tap(tester, find.widgetWithText(SeraButton, '查看变更并确认'));
      expect(h.uri.queryParameters['taskId'], 'future');
      expect(h.uri.queryParameters['entryId'], 'future-block');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'three leave and resume cycles preserve an unconfirmed draft and stack depth',
    (tester) async {
      final draft = _draft();
      final store = _NavigationStore(Workspace(revision: 1, drafts: [draft]));
      final h = await _mount(tester, store, '/origin');
      await _tap(tester, find.text('打开草案'));
      int depth() =>
          tester.widget<Navigator>(find.byType(Navigator).first).pages.length;
      expect(depth(), 2);
      for (var i = 0; i < 3; i++) {
        await _tap(tester, find.byTooltip('返回'));
        expect(h.screen, '44');
        expect(depth(), 3);
        await _tap(tester, find.widgetWithText(SeraButton, '继续编辑'));
        expect(h.screen, '08');
        expect(depth(), 2);
      }
      await tester.binding.handlePopRoute();
      await _frames(tester);
      expect(h.screen, '44');
      await _tap(tester, find.widgetWithText(SeraButton, '继续编辑'));
      expect(h.screen, '08');
      expect(depth(), 2);
      expect(h.c.draft(draft.id)!.toJson(), draft.toJson());
      expect(store.writes, 0);
      expect(h.c.data.tasks, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'committed draft edit entry opens its real task without a draft editor',
    (tester) async {
      final draft = _draft(committed: true);
      final store = _NavigationStore(
        Workspace(
          revision: 1,
          drafts: [draft],
          goals: [draft.goal],
          tasks: [draft.items.single.task],
        ),
      );
      final h = await _mount(tester, store, '/08?draftId=draft');
      expect(find.text('查看任务'), findsOneWidget);
      expect(find.text('编辑'), findsNothing);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      expect(find.text('保存'), findsNothing);
      await _tap(tester, find.text('查看任务'));
      expect(h.screen, '18');
      expect(h.uri.queryParameters['taskId'], 'draft-task');
      expect(h.uri.queryParameters.containsKey('draftId'), isFalse);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final kind in ['task', 'event']) {
    testWidgets(
      'completed $kind history opens the same result id without a new editor',
      (tester) async {
        final result = PlanningResultRef(kind: kind, id: 'actual-$kind');
        final session = PlanningSession(
          id: 'history-source',
          title: '已保存的会话',
          prompt: '保留原文',
          stage: 'confirmed',
          resultEntity: result,
          updatedAt: _today,
        );
        final store = _NavigationStore(
          Workspace(
            revision: 1,
            planningSessions: [session],
            tasks: kind == 'task'
                ? [SeraTask(id: result.id, title: '实际任务')]
                : [],
            entries: kind == 'event'
                ? [
                    CalendarEntry(
                      id: result.id,
                      title: '实际日程',
                      start: DateTime(2026, 11, 1, 15),
                      end: DateTime(2026, 11, 1, 15, 30),
                      locked: true,
                    ),
                  ]
                : [],
          ),
        );
        final h = await _mount(tester, store, '/34');
        expect(
          find.textContaining(kind == 'task' ? '任务已保存' : '日程已保存'),
          findsOneWidget,
        );
        await _tap(tester, find.text('已保存的会话'));
        expect(h.screen, kind == 'task' ? '18' : '15');
        expect(
          h.uri.queryParameters[kind == 'task' ? 'taskId' : 'eventId'],
          result.id,
        );
        expect(h.uri.queryParameters.containsKey('sessionId'), isFalse);
        expect(store.writes, 0);
        expect(store.requests, 0);
        expect(h.c.planningSession(session.id)!.resultEntity!.id, result.id);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'canceling an editor preserves the pending session and manual URL contains no business text',
    (tester) async {
      final session = PlanningSession(
        id: 'pending',
        prompt: '不能丢失的原始输入',
        notes: '需要保留的补充',
        updatedAt: _today,
        stage: 'understood',
        understanding: (const AiUnderstanding(
          intent: 'task',
          title: '保留的待核对任务',
          summary: '',
          outcome: '',
          model: 'fixture',
        )).toJson(),
      );
      final store = _NavigationStore(
        Workspace(revision: 1, planningSessions: [session]),
      );
      final h = await _mount(tester, store, '/34');
      expect(find.textContaining('等待核对'), findsOneWidget);
      await _tap(tester, find.text(session.prompt));
      expect(h.screen, '05');
      expect(store.requests, 0);
      await _tap(tester, find.byTooltip('更多操作'));
      await _tap(tester, find.text('添加任务'));
      expect(h.screen, '19');
      expect(h.uri.queryParameters, {
        'sessionId': session.id,
        'from': 'history',
        'manual': '1',
      });
      h.router.pop();
      await _frames(tester);
      expect(h.screen, '05');
      expect(h.c.planningSession(session.id)!.stage, 'understood');
      expect(h.c.planningSession(session.id)!.notes, session.notes);
      expect(h.c.data.tasks, isEmpty);
      expect(store.requests, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'legacy empty Today capture submits one session and restore never repeats it',
    (tester) async {
      final store = _NavigationStore(const Workspace(revision: 1));
      final h = await _mount(tester, store, '/37');
      const prompt = '明天整理课程材料';
      await _tap(tester, find.byKey(const ValueKey('today-capture')));
      await _tap(tester, find.text('文字输入'));
      await tester.enterText(find.byType(TextField), prompt);
      await _tap(tester, find.widgetWithText(SeraButton, '让 AI 安排'));
      expect(h.screen, '05');
      expect(h.uri.queryParameters['from'], 'today');
      expect(store.requests, 1);
      expect(store.inputs.single['prompt'], prompt);
      expect(h.uri.queryParameters.containsKey('prompt'), isFalse);
      final session = h.c.data.planningSessions.single;
      expect(h.uri.queryParameters['sessionId'], session.id);
      expect(session.stage, 'understood');
      h.router.go(h.uri.toString());
      await _frames(tester);
      expect(store.requests, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final useSystemBack in [false, true]) {
    testWidgets(
      'saving a draft${useSystemBack ? ' from the exit prompt' : ''} returns directly to history without creating objects',
      (tester) async {
        final draft = _draft();
        final store = _NavigationStore(Workspace(revision: 1, drafts: [draft]));
        final h = await _mount(tester, store, '/origin');
        await _tap(tester, find.text('打开草案'));
        expect(h.screen, '08');
        if (useSystemBack) {
          await tester.binding.handlePopRoute();
          await _frames(tester);
          expect(h.screen, '44');
          await _tap(tester, find.widgetWithText(SeraButton, '保留草案并离开'));
        } else {
          await _tap(tester, find.widgetWithText(TextButton, '保存草案'));
        }
        expect(h.screen, '34');
        expect(h.router.canPop(), isFalse);
        expect(h.c.draft(draft.id), isNotNull);
        expect(h.c.data.tasks, isEmpty);
        expect(h.c.data.entries, isEmpty);
        expect(find.text('继续查看草案'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final screen in ['11', '52', '55']) {
    testWidgets('system back leaves result $screen for the main screen', (
      tester,
    ) async {
      final draft = _draft(committed: true);
      final store = _NavigationStore(Workspace(revision: 1, drafts: [draft]));
      final h = await _mount(tester, store, '/origin');
      h.router.push('/$screen?draftId=${draft.id}');
      await _frames(tester);
      await tester.binding.handlePopRoute();
      await _frames(tester);
      expect(h.screen, '04');
      expect(h.router.canPop(), isFalse);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
    });
  }
}
