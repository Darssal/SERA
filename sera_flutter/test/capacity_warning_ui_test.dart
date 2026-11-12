import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/planning_ai_provider.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/domain/planning_service.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';

final _now = readZoned('2026-11-02T09:00:00+08:00', 'Asia/Hong_Kong')!;
final _deadline = atMinute(_now, 10 * 60);
const _title = '今天的复习清单';
const _preferences = SeraPreferences(
  dailyBudget: 60,
  startMinute: 9 * 60,
  endMinute: 10 * 60,
  bufferMinutes: 0,
  restStart: 0,
  restEnd: 0,
);

class _JourneyStore
    implements
        WorkspaceRepository,
        InputUnderstandingProvider,
        PlanningAiProvider {
  _JourneyStore({bool fullyBusy = false})
    : value = Workspace(
        preferences: _preferences,
        entries: fullyBusy
            ? [
                CalendarEntry(
                  id: 'existing-meeting',
                  title: '已有会议',
                  start: _now,
                  end: _deadline,
                  locked: true,
                ),
              ]
            : const [],
      );

  Workspace value;
  int understandings = 0;
  int generations = 0;
  bool failGeneration = false;

  @override
  String get mode => 'capacity-journey-isolated';

  @override
  Future<Workspace?> load() async => value;

  @override
  Future<void> clear() async => value = const Workspace();

  @override
  Future<Workspace> save(
    Workspace workspace, {
    required int expectedRevision,
  }) async {
    if (value.revision != expectedRevision) {
      throw const RepositoryException('版本已变化', conflict: true);
    }
    return value = Workspace.fromJson(
      workspace.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }

  @override
  Future<AiUnderstanding> understandInput({
    required Json input,
    required String requestId,
    void Function(String stage)? onStage,
  }) async {
    understandings++;
    return AiUnderstanding(
      intent: 'goal',
      title: _title,
      summary: '整理概念、完成习题并复盘。',
      outcome: '',
      model: 'capacity-fixture',
      deadline: _deadline,
      dailyBudget: 60,
    );
  }

  @override
  Future<AiPlanResult> generateTaskBreakdown({
    required String title,
    required DateTime deadline,
    required int dailyBudget,
    String notes = '',
    String prompt = '',
    String? requestId,
  }) async {
    generations++;
    if (failGeneration) throw const RepositoryException('测试服务暂不可用');
    return const AiPlanResult(
      model: 'capacity-fixture',
      tasks: [
        TaskOutline(title: '整理概念', estimatedMinutes: 60),
        TaskOutline(title: '完成习题', estimatedMinutes: 60),
        TaskOutline(title: '回顾错题', estimatedMinutes: 60),
      ],
    );
  }
}

Future<SeraController> _controller(_JourneyStore store) async {
  final c = SeraController(repository: store, today: _now, seedDemo: false);
  await c.initialize();
  addTearDown(c.dispose);
  return c;
}

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 10; frame++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _mount(
  WidgetTester tester,
  SeraController c, {
  String location = '/04',
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(SeraApp(controller: c, initialLocation: location));
  await _frames(tester);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await _frames(tester);
}

Finder _button(String label) => find.widgetWithText(SeraButton, label);

GoRouter _router(WidgetTester tester) =>
    GoRouter.of(tester.element(find.byType(SeraScaffold).first));

Uri _location(WidgetTester tester) =>
    _router(tester).routeInformationProvider.value.uri;

Future<void> _fromTodayToGeneration(WidgetTester tester) async {
  await _tap(tester, find.byKey(const ValueKey('today-capture')));
  await _tap(tester, find.text('文字输入'));
  await tester.enterText(find.byType(TextField).first, '帮我安排今天的复习清单');
  await tester.pump();
  await _tap(tester, _button('让 AI 安排'));
  await _tap(tester, _button('生成计划'));
}

Future<PlanDraft> _savedCandidate(SeraController c) async {
  final draft = await c.generatePlan(
    title: _title,
    deadline: _deadline,
    dailyBudget: 60,
    requestId: 'saved-capacity-request',
  );
  await c.savePlanningSession(
    PlanningSession(
      id: 'saved-capacity-session',
      updatedAt: _now,
      prompt: '帮我安排今天的复习清单',
      title: _title,
      deadline: _deadline,
      dailyBudget: 60,
      stage: 'draft',
      draftId: draft.id,
      aiRequestId: 'saved-capacity-request',
    ),
  );
  return draft;
}

void main() {
  testWidgets(
    'today input continues through capacity consent and returns directly to today',
    (tester) async {
      final store = _JourneyStore();
      final c = await _controller(store);
      await _mount(tester, c);
      await _fromTodayToGeneration(tester);

      expect(find.text('部分任务待安排'), findsOneWidget);
      expect(find.text('当前时段放不下全部任务，2 项先保留为待安排。'), findsOneWidget);
      expect(find.text('这次没能完成规划'), findsNothing);
      expect(store.understandings, 1);
      expect(store.generations, 1);
      final draft = c.data.drafts.single;
      expect(draft.needsCapacityConfirmation, isTrue);
      expect(c.data.tasks, isEmpty);

      await _tap(tester, _button('保留计划并继续'));
      expect(c.draft(draft.id)!.capacityConfirmed, isTrue);
      expect(c.data.tasks, isEmpty);
      expect(find.textContaining('1 段日程安排 · 2 项待安排'), findsOneWidget);
      await _tap(tester, _button('确认保存 3 项任务'));

      expect(_location(tester).path, '/04');
      expect(find.widgetWithText(AppBar, '今日'), findsOneWidget);
      expect(_router(tester).canPop(), isFalse);
      expect(find.text('目标已创建'), findsOneWidget);
      expect(find.textContaining('已保存到应用内日历'), findsNothing);
      expect(c.data.goals, hasLength(1));
      expect(c.data.tasks, hasLength(3));
      expect(c.data.entries.where((entry) => entry.isTask), hasLength(1));
      expect(store.generations, 1);

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).last);
      await _tap(
        tester,
        find.descendant(
          of: find.byWidget(scaffold.bottomNavigationBar!),
          matching: find.text('计划'),
        ),
      );
      await _tap(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('plan-switcher')),
          matching: find.text('目标'),
        ),
      );
      expect(find.widgetWithText(AppBar, '计划'), findsOneWidget);
      expect(find.text(_title), findsOneWidget);
      await _tap(tester, find.text(_title));
      expect(find.widgetWithText(AppBar, '目标详情'), findsOneWidget);
      expect(find.text('整理概念'), findsOneWidget);
      expect(find.text('完成习题'), findsOneWidget);
      expect(find.text('回顾错题'), findsOneWidget);
      await _tap(tester, find.byTooltip('返回'));
      expect(find.widgetWithText(AppBar, '计划'), findsOneWidget);
      expect(find.text(_title), findsOneWidget);
      expect(find.widgetWithText(AppBar, '计划已保存'), findsNothing);
      expect(find.widgetWithText(AppBar, '确认安排'), findsNothing);
      expect(c.data.tasks, hasLength(3));
      expect(c.data.goals, hasLength(1));
      expect(c.data.drafts, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'history recovery can cancel the pending consent then save the same candidate',
    (tester) async {
      final store = _JourneyStore();
      final c = await _controller(store);
      final draft = await _savedCandidate(c);
      await _mount(tester, c, location: '/34');
      await _tap(tester, find.text(_title).first);
      await _tap(tester, _button('确认保存 3 项任务'));
      expect(find.widgetWithText(AlertDialog, '部分任务待安排'), findsOneWidget);
      await _tap(tester, find.widgetWithText(TextButton, '返回修改'));
      expect(c.draft(draft.id)!.needsCapacityConfirmation, isTrue);
      expect(c.data.tasks, isEmpty);
      expect(c.data.entries, isEmpty);
      expect(find.widgetWithText(AppBar, '计划草案'), findsOneWidget);

      await _tap(tester, _button('确认保存 3 项任务'));
      await _tap(tester, find.widgetWithText(FilledButton, '保留计划并继续'));
      expect(c.draft(draft.id)!.capacityConfirmed, isTrue);
      expect(c.data.tasks, hasLength(3));
      expect(store.generations, 1);
      expect(store.understandings, 0);
      expect(_location(tester).path, '/34');
      expect(find.widgetWithText(AppBar, '规划记录'), findsOneWidget);
      expect(_router(tester).canPop(), isFalse);
      expect(c.data.goals, hasLength(1));
      expect(c.data.drafts.single.id, draft.id);
      expect(c.data.drafts.single.status, 'committed');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a direct write link still requests consent and reports an entirely unscheduled plan honestly',
    (tester) async {
      final store = _JourneyStore(fullyBusy: true);
      final c = await _controller(store);
      final draft = await _savedCandidate(c);
      await _mount(tester, c, location: '/51?draftId=${draft.id}');
      expect(find.widgetWithText(AlertDialog, '部分任务待安排'), findsOneWidget);
      expect(find.text('当前时段放不下全部任务，3 项先保留为待安排。'), findsOneWidget);
      expect(c.data.tasks, isEmpty);
      await _tap(tester, find.widgetWithText(FilledButton, '保留计划并继续'));
      expect(c.data.tasks, hasLength(3));
      expect(c.data.entries, hasLength(1));
      expect(c.data.entries.single.id, 'existing-meeting');
      expect(_location(tester).path, '/20');
      expect(find.widgetWithText(AppBar, '计划'), findsOneWidget);
      expect(_router(tester).canPop(), isFalse);
      expect(c.data.goals, hasLength(1));
      expect(c.data.drafts.single.id, draft.id);
      expect(c.data.drafts.single.status, 'committed');
      await _tap(tester, find.text(_title));
      expect(find.widgetWithText(AppBar, '目标详情'), findsOneWidget);
      expect(find.text('整理概念'), findsOneWidget);
      expect(find.text('完成习题'), findsOneWidget);
      expect(find.text('回顾错题'), findsOneWidget);
      expect(_button('查看日程'), findsNothing);
      expect(store.generations, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a real provider failure remains a recoverable error', (
    tester,
  ) async {
    final store = _JourneyStore()..failGeneration = true;
    final c = await _controller(store);
    await _mount(tester, c);
    await _fromTodayToGeneration(tester);
    expect(find.text('这次没能完成规划'), findsOneWidget);
    expect(_button('保留计划并继续'), findsNothing);
    expect(c.data.drafts, isEmpty);
    expect(c.data.tasks, isEmpty);
    expect(store.generations, 1);
    expect(tester.takeException(), isNull);
  });
}
