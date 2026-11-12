import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/planning_ai_provider.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/domain/planning_service.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

final _now = readZoned('2026-10-31T16:00:00+08:00', 'Asia/Hong_Kong')!;
final _deadline = readZoned('2026-11-06T00:00:00+08:00', 'Asia/Hong_Kong')!;
const _prompt = '十一月六日之前准备好课程展示，每天二十分钟。';

AiUnderstanding _goal({
  DateTime? deadline,
  bool unknownDeadline = false,
  List<AiQuestion> questions = const [],
}) => AiUnderstanding(
  intent: 'goal',
  title: '准备课程展示',
  summary: '整理课程重点，准备演示。',
  outcome: '能完整讲解核心论点',
  model: 'direct-goal-isolated-fixture',
  deadline: unknownDeadline ? null : deadline ?? _deadline,
  deadlineIsDateOnly: !unknownDeadline && deadline == null,
  dailyBudget: 20,
  questions: questions,
);

class _JourneyStore
    implements
        WorkspaceRepository,
        InputUnderstandingProvider,
        PlanningAiProvider {
  Workspace value = const Workspace(revision: 1);
  AiUnderstanding understanding = _goal();
  bool failUnderstanding = false;
  int understandings = 0;
  Completer<AiPlanResult>? generationGate;
  final requests = <Json>[];

  @override
  String get mode => 'direct-goal-isolated';
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
      throw const RepositoryException('工作区版本已变化', conflict: true);
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
    if (failUnderstanding) throw const RepositoryException('测试理解服务暂不可用');
    return understanding;
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
    requests.add({
      'title': title,
      'deadline': deadline,
      'dailyBudget': dailyBudget,
      'notes': notes,
      'prompt': prompt,
      'requestId': requestId,
    });
    return generationGate == null ? _plan : await generationGate!.future;
  }
}

const _plan = AiPlanResult(
  model: 'direct-goal-isolated-fixture',
  tasks: [TaskOutline(title: '整理课程重点', estimatedMinutes: 15)],
);

Finder _button(String label) => find.widgetWithText(SeraButton, label);
Finder get _composer => find.byKey(const ValueKey('planning-chat-composer'));

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<SeraController> _mount(
  WidgetTester tester,
  _JourneyStore store, {
  String location = '/04',
}) async {
  final c = SeraController(repository: store, today: _now, seedDemo: false);
  await c.initialize();
  addTearDown(c.dispose);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    SeraApp(key: UniqueKey(), controller: c, initialLocation: location),
  );
  await _frames(tester);
  return c;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await _frames(tester);
}

Future<void> _understandFromToday(WidgetTester tester) async {
  await _tap(tester, find.byKey(const ValueKey('today-capture')));
  await _tap(tester, find.text('文字输入'));
  await tester.enterText(find.byType(TextField).first, _prompt);
  await tester.pump();
  await _tap(tester, find.widgetWithText(SeraButton, '让 AI 安排'));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets(
    'complete goal proceeds from today through one explicit generation with the same context',
    (tester) async {
      final store = _JourneyStore()..generationGate = Completer<AiPlanResult>();
      final c = await _mount(tester, store);
      await _understandFromToday(tester);
      expect(store.understandings, 1);
      expect(store.requests, isEmpty);
      expect(find.text('每日目标'), findsOneWidget);
      expect(find.text('20 分钟'), findsOneWidget);
      expect(find.textContaining('当天结束前'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '修改要求'), findsOneWidget);
      expect(_button('核对目标并规划'), findsNothing);
      final sessionId = c.planningSession()!.id;

      // Rebuilds and restored conversations are not generation consent.
      await _frames(tester);
      expect(store.requests, isEmpty);
      await tester.ensureVisible(_button('生成计划'));
      await tester.tap(_button('生成计划'));
      await tester.tap(_button('生成计划'));
      await _frames(tester);
      expect(find.widgetWithText(AppBar, '正在规划'), findsOneWidget);
      expect(find.widgetWithText(AppBar, '确认目标'), findsNothing);
      expect(store.requests, hasLength(1));
      expect(store.requests.single['title'], '准备课程展示');
      expect(store.requests.single['prompt'], _prompt);
      expect(store.requests.single['dailyBudget'], 20);
      expect(store.requests.single['notes'], contains(_goal().summary));
      expect(store.requests.single['notes'], contains(_goal().outcome));
      expect(
        (store.requests.single['deadline'] as DateTime).toUtc(),
        DateTime.parse('2026-11-06T15:59:00Z'),
      );
      expect(
        store.requests.single['requestId'],
        c.planningSession(sessionId)!.aiRequestId,
      );
      expect(c.data.goals, isEmpty);
      expect(c.data.tasks, isEmpty);

      store.generationGate!.complete(_plan);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '计划草案'), findsOneWidget);
      expect(c.planningSession(sessionId)!.draftId, c.data.drafts.single.id);
      expect(c.data.tasks, isEmpty);
      expect(store.requests, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'modify requirements retains the original confirmation route and edited title on return',
    (tester) async {
      final store = _JourneyStore();
      final c = await _mount(tester, store);
      await _understandFromToday(tester);
      await _tap(tester, find.widgetWithText(TextButton, '修改要求'));
      expect(find.widgetWithText(AppBar, '确认目标'), findsOneWidget);
      expect(find.text('11月6日 周五（当天结束前）'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).first, '准备课程展示和答辩');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('准备课程展示和答辩'), findsOneWidget);
      expect(_button('生成计划'), findsOneWidget);
      expect(c.planningSession()!.title, '准备课程展示和答辩');
      expect(store.requests, isEmpty);
      expect(store.understandings, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'restoring an understood goal does not request or generate again',
    (tester) async {
      final store = _JourneyStore();
      final first = await _mount(tester, store);
      await _understandFromToday(tester);
      final sessionId = first.planningSession()!.id;
      await tester.pumpWidget(const SizedBox.shrink());
      await _mount(tester, store, location: '/05?sessionId=$sessionId');
      expect(_button('生成计划'), findsOneWidget);
      expect(store.understandings, 1);
      expect(store.requests, isEmpty);
      await _tap(tester, _button('生成计划'));
      expect(store.requests, hasLength(1));
      expect(find.widgetWithText(AppBar, '计划草案'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final example in <String, AiUnderstanding>{
    'unknown deadline': _goal(unknownDeadline: true),
    'expired deadline today': _goal(
      deadline: _now.subtract(const Duration(minutes: 1)),
    ),
    'deadline beyond one year': _goal(
      deadline: _now.add(const Duration(days: 368)),
    ),
    'unanswered question': _goal(
      questions: const [AiQuestion(id: 'audience', question: '给谁展示？')],
    ),
  }.entries) {
    testWidgets(
      '${example.key} keeps confirmation without automatically generating',
      (tester) async {
        final store = _JourneyStore()..understanding = example.value;
        await _mount(tester, store);
        await _understandFromToday(tester);
        expect(_button('生成计划'), findsNothing);
        expect(_button('核对目标并规划'), findsOneWidget);
        await _tap(tester, _button('核对目标并规划'));
        expect(find.widgetWithText(AppBar, '确认目标'), findsOneWidget);
        expect(store.requests, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'an unsent supplement immediately prevents using a stale result',
    (tester) async {
      final store = _JourneyStore();
      await _mount(tester, store);
      await _understandFromToday(tester);
      await tester.enterText(_composer, '另外要准备三个例子');
      await tester.pump();
      expect(_button('生成计划'), findsNothing);
      expect(tester.widget<SeraButton>(_button('核对目标并规划')).onPressed, isNull);
      expect(store.understandings, 1);
      expect(store.requests, isEmpty);
      await tester.enterText(_composer, '');
      await tester.pump();
      expect(_button('生成计划'), findsOneWidget);
      expect(store.requests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final example in <String, PlanningSession>{
    'invalid restored budget': PlanningSession(
      id: 'invalid-budget',
      updatedAt: _now,
      prompt: _prompt,
      title: '准备课程展示',
      deadline: _deadline,
      deadlineIsDateOnly: true,
      dailyBudget: 14,
      stage: 'understood',
      understanding: _goal().toJson(),
    ),
    'empty edited title': PlanningSession(
      id: 'empty-title',
      updatedAt: _now,
      prompt: _prompt,
      title: '',
      deadline: _deadline,
      deadlineIsDateOnly: true,
      dailyBudget: 20,
      stage: 'clarify',
      understanding: _goal().toJson(),
    ),
    'existing generation request': PlanningSession(
      id: 'existing-request',
      updatedAt: _now,
      prompt: _prompt,
      title: '准备课程展示',
      deadline: _deadline,
      deadlineIsDateOnly: true,
      dailyBudget: 20,
      stage: 'generating',
      understanding: _goal().toJson(),
      aiRequestId: 'preserved-planning-request',
      aiRequestNotes: '原始已确认上下文',
    ),
  }.entries) {
    testWidgets('${example.key} never offers a fresh direct generation', (
      tester,
    ) async {
      final store = _JourneyStore();
      store.value = store.value.copyWith(planningSessions: [example.value]);
      await _mount(
        tester,
        store,
        location: '/05?sessionId=${example.value.id}',
      );
      expect(_button('生成计划'), findsNothing);
      expect(_button('核对目标并规划'), findsOneWidget);
      expect(store.understandings, 0);
      expect(store.requests, isEmpty);
      expect(
        store.value.planningSessions.single.aiRequestId,
        example.value.aiRequestId,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'failed supplement understanding requires review rather than direct generation',
    (tester) async {
      final store = _JourneyStore();
      await _mount(tester, store);
      await _understandFromToday(tester);
      store.failUnderstanding = true;
      await tester.enterText(_composer, '改成十一月七日');
      await tester.pump();
      await _tap(tester, find.byKey(const ValueKey('planning-chat-send')));
      expect(find.text('理解尚未完成'), findsOneWidget);
      expect(_button('生成计划'), findsNothing);
      expect(_button('核对目标并规划'), findsOneWidget);
      expect(store.requests, isEmpty);
      expect(store.understandings, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
