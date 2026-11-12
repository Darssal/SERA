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

final _now = DateTime(2026, 10, 31, 16);
const _prompt = '我想利用通勤提升英语表达，先不设截止，也不要套备考模板。';

class _UnderstandingStore
    implements
        WorkspaceRepository,
        InputUnderstandingProvider,
        CancellableInputUnderstandingProvider {
  Workspace value = const Workspace(revision: 1);
  final calls = <({Json input, String requestId})>[];
  final responses = <Future<AiUnderstanding> Function()>[];
  int cancellations = 0;

  @override
  String get mode => 'understanding-ui-test';

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
      throw const RepositoryException('测试工作区版本已改变', conflict: true);
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
  }) {
    calls.add((input: input, requestId: requestId));
    onStage?.call('模型正在理解你的输入');
    return responses.removeAt(0)();
  }

  @override
  void cancelUnderstanding() => cancellations++;
}

class _UnderstandingPlanningStore extends _UnderstandingStore
    implements PlanningAiProvider {
  final planningDeadlines = <DateTime>[];

  @override
  Future<AiPlanResult> generateTaskBreakdown({
    required String title,
    required DateTime deadline,
    required int dailyBudget,
    String notes = '',
    String prompt = '',
    String? requestId,
  }) async {
    planningDeadlines.add(deadline);
    return const AiPlanResult(
      model: 'date-only-planning-test-model',
      tasks: [TaskOutline(title: '整理课程展示的核心论点', estimatedMinutes: 15)],
    );
  }
}

AiUnderstanding _goal({
  DateTime? deadline,
  List<AiQuestion> questions = const [],
}) => AiUnderstanding(
  intent: 'goal',
  title: '在通勤中练习英语表达',
  summary: '把通勤时间用于日常英语表达练习，暂不设截止日期。',
  outcome: '能复述通勤中听到的日常对话',
  model: 'semantic-understanding-test-model',
  dailyBudget: 20,
  deadline: deadline,
  questions: questions,
);

Finder _input(String label) => find.byWidgetPredicate(
  (widget) => widget is SeraInput && widget.label == label,
);

Future<void> _enter(WidgetTester tester, String label, String text) async {
  final field = find.descendant(
    of: _input(label),
    matching: find.byType(TextFormField),
  );
  await tester.ensureVisible(field);
  await tester.enterText(field, text);
  await tester.pump();
}

String _value(WidgetTester tester, String label) => label == '这次想处理什么？'
    ? tester
          .widget<Text>(find.byKey(const ValueKey('planning-original-message')))
          .data!
    : tester.widget<SeraInput>(_input(label)).controller.text;

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(
    find.byKey(const ValueKey('planning-chat-composer')),
    text,
  );
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('planning-chat-send')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _pump(
  WidgetTester tester,
  SeraController controller,
  String location,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    SeraApp(
      key: UniqueKey(),
      controller: controller,
      initialLocation: location,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _tap(WidgetTester tester, String label) async {
  var button = find.widgetWithText(SeraButton, label);
  if (button.evaluate().isEmpty) {
    button = find.widgetWithText(TextButton, label);
  }
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _dispose(WidgetTester tester, SeraController controller) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
}

void _expectNoBusinessWrites(SeraController controller) {
  expect(controller.data.goals, isEmpty);
  expect(controller.data.tasks, isEmpty);
  expect(controller.data.entries, isEmpty);
  expect(controller.data.drafts, isEmpty);
}

Finder _displayTime(String value) {
  String withoutSpacing(String text) => text.replaceAll(RegExp(r'\s+'), '');
  return find.byWidgetPredicate(
    (widget) =>
        widget is Text &&
        widget.data != null &&
        withoutSpacing(widget.data!) == withoutSpacing(value),
  );
}

void _expectUnderstandingTemplate({
  required WidgetTester tester,
  required String time,
  required String title,
  required String summary,
  bool hasQuestions = false,
  bool hasOutcome = true,
}) {
  expect(find.text('待核对'), findsOneWidget);
  expect(find.text('规划时间'), findsOneWidget);
  expect(_displayTime(time), findsOneWidget);
  expect(find.text(title), findsOneWidget);
  expect(find.text(summary), findsOneWidget);
  expect(find.text('补充信息'), findsNothing);
  expect(find.text('无'), findsNothing);
  expect(find.text('预期结果'), hasOutcome ? findsOneWidget : findsNothing);
  expect(find.text('以上为待核对建议，尚未创建事项。'), findsNothing);
  expect(
    tester.getTopLeft(find.text('规划时间')).dy,
    lessThan(tester.getTopLeft(find.text(title)).dy),
  );
  if (hasQuestions) {
    expect(
      tester.getTopLeft(find.text(title)).dy,
      lessThan(tester.getTopLeft(find.text('通勤时方便开口练习，还是只方便听？')).dy),
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets(
    'understanding is explicitly requested and an unknown deadline stays unknown through confirmation',
    (tester) async {
      final store = _UnderstandingStore();
      final gate = Completer<AiUnderstanding>();
      store.responses.add(() => gate.future);
      final controller = SeraController(repository: store, today: _now);
      await controller.initialize();
      await _pump(
        tester,
        controller,
        '/05?prompt=${Uri.encodeComponent(_prompt)}',
      );
      expect(store.calls, isEmpty);
      expect(find.text(_prompt), findsOneWidget);
      await _tap(tester, '理解这段输入');
      expect(controller.understanding, isTrue);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('模型正在理解你的输入'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '取消理解'), findsOneWidget);
      expect(store.calls.single.input['prompt'], _prompt);
      expect(store.calls.single.input['referenceNow'], endsWith('+08:00'));
      expect(store.calls.single.input['timeZone'], 'Asia/Hong_Kong');
      _expectNoBusinessWrites(controller);

      gate.complete(_goal());
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      _expectUnderstandingTemplate(
        tester: tester,
        time: '未确定',
        title: _goal().title,
        summary: _goal().summary,
      );
      expect(controller.planningSession()!.deadline, isNull);
      await _tap(tester, '核对目标并规划');
      expect(find.widgetWithText(AppBar, '确认目标'), findsOneWidget);
      expect(find.text('尚未设置截止日期'), findsOneWidget);
      expect(find.textContaining('15:00'), findsNothing);
      await _tap(tester, '生成可执行的计划');
      expect(find.widgetWithText(AppBar, '确认目标'), findsOneWidget);
      expect(find.text('请选择目标截止日期，再生成计划。'), findsOneWidget);
      expect(controller.planningSession()!.deadline, isNull);
      _expectNoBusinessWrites(controller);
      expect(tester.takeException(), isNull);
      await _dispose(tester, controller);
    },
  );

  testWidgets(
    'model questions and answers are retained and sent as clarification context',
    (tester) async {
      const question = AiQuestion(
        id: 'commute_mode',
        question: '通勤时方便开口练习，还是只方便听？',
      );
      final store = _UnderstandingStore();
      final gate = Completer<AiUnderstanding>();
      store.responses.addAll([
        () async => _goal(questions: [question]),
        () => gate.future,
      ]);
      final controller = SeraController(repository: store, today: _now);
      await controller.initialize();
      await _pump(
        tester,
        controller,
        '/05?prompt=${Uri.encodeComponent(_prompt)}',
      );
      await _tap(tester, '理解这段输入');
      await tester.pumpAndSettle();
      expect(find.text(question.question), findsOneWidget);
      _expectUnderstandingTemplate(
        tester: tester,
        time: '未确定',
        title: _goal().title,
        summary: _goal().summary,
        hasQuestions: true,
      );
      await _send(tester, '在地铁上只能戴耳机听，下车后可以复述。');
      expect(controller.understanding, isTrue);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('模型正在理解你的输入'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '取消理解'), findsOneWidget);
      expect(_value(tester, '这次想处理什么？'), _prompt);
      expect(find.text('在地铁上只能戴耳机听，下车后可以复述。'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('planning-chat-send')),
            )
            .onPressed,
        isNull,
      );
      expect(find.text(_goal().summary), findsOneWidget);
      gate.complete(_goal());
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(store.calls, hasLength(2));
      expect(store.calls.last.input['prompt'], _prompt);
      final previous = store.calls.last.input['previous'] as Map;
      expect(store.calls.last.input['notes'], '在地铁上只能戴耳机听，下车后可以复述。');
      expect(store.calls.last.requestId, isNot(store.calls.first.requestId));
      final saved = controller.planningSession()!;
      expect(saved.prompt, _prompt);
      expect(saved.notes, contains('地铁'));
      expect(previous['questions'], isNotEmpty);
      expect(saved.messages.map((m) => m.role), [
        'user',
        'assistant',
        'user',
        'assistant',
      ]);
      expect(saved.deadline, isNull);
      _expectNoBusinessWrites(controller);
      expect(tester.takeException(), isNull);
      await _dispose(tester, controller);
    },
  );

  testWidgets(
    'reduced motion keeps understanding progress static and cancelable',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(reduceMotion: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final store = _UnderstandingStore();
      final gate = Completer<AiUnderstanding>();
      store.responses.add(() => gate.future);
      final controller = SeraController(repository: store, today: _now);
      await controller.initialize();
      await _pump(
        tester,
        controller,
        '/05?prompt=${Uri.encodeComponent(_prompt)}',
      );
      await _tap(tester, '理解这段输入');
      final progress = find.byType(LinearProgressIndicator);
      expect(progress, findsOneWidget);
      expect(tester.widget<LinearProgressIndicator>(progress).value, isNull);
      expect(TickerMode.valuesOf(tester.element(progress)).enabled, isFalse);
      await tester.pumpAndSettle();
      expect(controller.understanding, isTrue);
      expect(find.text('模型正在理解你的输入'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await _tap(tester, '取消理解');
      expect(store.cancellations, 1);
      expect(controller.understanding, isFalse);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      gate.complete(_goal());
      await tester.pumpAndSettle();
      expect(find.text(_goal().summary), findsNothing);
      expect(_value(tester, '这次想处理什么？'), _prompt);
      _expectNoBusinessWrites(controller);
      expect(tester.takeException(), isNull);
      await _dispose(tester, controller);
    },
  );

  testWidgets(
    'editing the prompt clears previous answers even when the next question reuses its id',
    (tester) async {
      const firstQuestion = AiQuestion(
        id: 'practice_mode',
        question: '通勤时方便开口练习，还是只方便听？',
      );
      const nextQuestion = AiQuestion(
        id: 'practice_mode',
        question: '你想先练习哪一道菜？',
      );
      const nextPrompt = '我现在想学习做菜，先从一道适合下班后做的家常菜开始。';
      final store = _UnderstandingStore();
      store.responses.addAll([
        () async => _goal(questions: [firstQuestion]),
        () async => const AiUnderstanding(
          intent: 'goal',
          title: '学习制作家常菜',
          summary: '从一道适合下班后制作的家常菜开始练习。',
          outcome: '独立做好一道家常菜',
          model: 'semantic-understanding-test-model',
          questions: [nextQuestion],
        ),
      ]);
      final controller = SeraController(repository: store, today: _now);
      await controller.initialize();
      await _pump(
        tester,
        controller,
        '/05?prompt=${Uri.encodeComponent(_prompt)}',
      );
      await _tap(tester, '理解这段输入');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('planning-edit-original')));
      await tester.pumpAndSettle();
      await _enter(tester, '这次想处理什么？', nextPrompt);
      await _tap(tester, '保存并重新理解');
      await tester.pumpAndSettle();
      expect(find.text(firstQuestion.question), findsNothing);
      expect(store.calls, hasLength(2));
      expect(store.calls.last.input['prompt'], nextPrompt);
      expect(store.calls.last.input['previous'], isNull);
      expect(find.text(nextQuestion.question), findsOneWidget);
      expect(controller.planningSession()!.clarificationAnswers, isEmpty);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('planning-chat-composer')),
            )
            .controller!
            .text,
        isEmpty,
      );
      _expectNoBusinessWrites(controller);
      expect(tester.takeException(), isNull);
      await _dispose(tester, controller);
    },
  );

  testWidgets(
    'a date-only goal hides midnight and passes the end of that date to planning',
    (tester) async {
      final store = _UnderstandingPlanningStore();
      store.responses.add(
        () async => AiUnderstanding(
          intent: 'goal',
          title: '准备课程展示',
          summary: '在十一月六日结束前完成课程展示准备。',
          outcome: '完成课程展示的讲稿和材料',
          model: 'semantic-understanding-test-model',
          deadline: DateTime.parse('2026-11-06T00:00:00+08:00'),
          deadlineIsDateOnly: true,
          dailyBudget: 90,
        ),
      );
      final controller = SeraController(repository: store, today: _now);
      await controller.initialize();
      await _pump(
        tester,
        controller,
        '/05?prompt=${Uri.encodeComponent('十一月六日之前准备好课程展示，只定日期。')}',
      );
      await _tap(tester, '理解这段输入');
      await tester.pumpAndSettle();
      _expectUnderstandingTemplate(
        tester: tester,
        time: '截至 11月6日 周五（当天结束前）',
        title: '准备课程展示',
        summary: '在十一月六日结束前完成课程展示准备。',
      );
      await _tap(tester, '修改要求');
      expect(find.widgetWithText(AppBar, '确认目标'), findsOneWidget);
      expect(find.text('11月6日 周五（当天结束前）'), findsOneWidget);
      expect(find.textContaining('00:00'), findsNothing);
      expect(controller.planningSession()!.deadlineIsDateOnly, isTrue);
      expect(store.planningDeadlines, isEmpty);
      await _tap(tester, '生成可执行的计划');
      await tester.pumpAndSettle();
      expect(store.planningDeadlines, hasLength(1));
      expect(
        store.planningDeadlines.single.toUtc(),
        DateTime.parse('2026-11-06T15:59:00Z'),
      );
      expect(find.widgetWithText(AppBar, '计划草案'), findsOneWidget);
      expect(
        controller.data.drafts.single.goal.deadline.toUtc(),
        DateTime.parse('2026-11-06T15:59:00Z'),
      );
      expect(controller.data.tasks, isEmpty);
      expect(controller.data.entries, isEmpty);
      expect(tester.takeException(), isNull);
      await _dispose(tester, controller);
    },
  );

  testWidgets(
    'a persisted semantic result reopens without charging another request',
    (tester) async {
      final store = _UnderstandingStore();
      store.responses.add(() async => _goal());
      final first = SeraController(repository: store, today: _now);
      await first.initialize();
      await _pump(tester, first, '/05?prompt=${Uri.encodeComponent(_prompt)}');
      await _tap(tester, '理解这段输入');
      await tester.pumpAndSettle();
      final sessionId = first.planningSession()!.id;
      await _dispose(tester, first);

      final reopened = SeraController(repository: store, today: _now);
      await reopened.initialize();
      await _pump(tester, reopened, '/05?sessionId=$sessionId');
      expect(find.text(_goal().summary), findsOneWidget);
      expect(find.text(_prompt), findsOneWidget);
      expect(store.calls, hasLength(1));
      expect(reopened.planningSession(sessionId)!.deadline, isNull);
      _expectNoBusinessWrites(reopened);
      expect(tester.takeException(), isNull);
      await _dispose(tester, reopened);
    },
  );

  testWidgets(
    'a task proposal reaches an editable form and saves only the confirmed edits',
    (tester) async {
      final store = _UnderstandingStore();
      store.responses.add(
        () async => AiUnderstanding(
          intent: 'task',
          title: '整理采访录音',
          summary: '先完成一项录音整理任务，暂不排具体时段。',
          outcome: '整理成有说话人标注的文字稿',
          model: 'semantic-understanding-test-model',
          estimatedMinutes: 35,
          deadline: DateTime.parse('2026-11-03T23:59:00+08:00'),
          deadlineIsDateOnly: true,
        ),
      );
      final controller = SeraController(repository: store, today: _now);
      await controller.initialize();
      await _pump(
        tester,
        controller,
        '/05?prompt=${Uri.encodeComponent('周二之前整理录音，约三十五分钟，先放收件箱。')}',
      );
      await _tap(tester, '理解这段输入');
      await tester.pumpAndSettle();
      _expectUnderstandingTemplate(
        tester: tester,
        time: '截至 11月3日 周二（当天结束前）',
        title: '整理采访录音',
        summary: '先完成一项录音整理任务，暂不排具体时段。',
      );
      await _tap(tester, '编辑任务');
      expect(find.widgetWithText(AppBar, '添加任务'), findsOneWidget);
      expect(_value(tester, '要做什么？'), '整理采访录音');
      expect(_value(tester, '预计用时（分钟）'), '35');
      expect(find.text('来自AI的建议，请核对后保存'), findsOneWidget);
      _expectNoBusinessWrites(controller);
      await _enter(tester, '要做什么？', '整理访谈录音并标注说话人');
      await _tap(tester, '保存任务');
      await tester.pumpAndSettle();
      expect(controller.data.tasks.single.title, '整理访谈录音并标注说话人');
      expect(controller.data.tasks.single.estimatedMinutes, 35);
      expect(controller.data.tasks.single.dueAt, isNull);
      expect(controller.data.tasks.single.dueDate, '2026-11-03');
      expect(controller.data.entries, isEmpty);
      expect(controller.data.goals, isEmpty);
      expect(tester.takeException(), isNull);
      await _dispose(tester, controller);
    },
  );

  testWidgets(
    'an event proposal passes real start and end into editable confirmation before saving',
    (tester) async {
      final store = _UnderstandingStore();
      store.responses.add(
        () async => AiUnderstanding(
          intent: 'event',
          title: '与同学讨论课程目标',
          summary: '明晚七点和同学讨论半小时，未设置目标截止。',
          outcome: '沟通课程目标和后续分工',
          model: 'semantic-understanding-test-model',
          start: DateTime.parse('2026-11-01T19:00:00+08:00'),
          end: DateTime.parse('2026-11-01T19:30:00+08:00'),
        ),
      );
      final controller = SeraController(repository: store, today: _now);
      await controller.initialize();
      await _pump(
        tester,
        controller,
        '/05?prompt=${Uri.encodeComponent('明天不是截止日，明晚七点和同学聊课程目标，半小时。')}',
      );
      await _tap(tester, '理解这段输入');
      await tester.pumpAndSettle();
      _expectUnderstandingTemplate(
        tester: tester,
        time: '11月1日 周日 19:00–19:30',
        title: '与同学讨论课程目标',
        summary: '明晚七点和同学讨论半小时，未设置目标截止。',
      );
      await _tap(tester, '编辑固定事项');
      expect(_value(tester, '日程名称'), '与同学讨论课程目标');
      expect(find.textContaining('19:00'), findsOneWidget);
      expect(find.textContaining('19:30'), findsOneWidget);
      expect(find.text('来自AI的建议，请核对后保存'), findsOneWidget);
      _expectNoBusinessWrites(controller);
      await _enter(tester, '日程名称', '与同学讨论课程目标及分工');
      await _tap(tester, '保存日程');
      await tester.pumpAndSettle();
      final event = controller.data.entries.single;
      expect(event.title, '与同学讨论课程目标及分工');
      expect(event.start.toUtc(), DateTime.parse('2026-11-01T11:00:00Z'));
      expect(event.end.toUtc(), DateTime.parse('2026-11-01T11:30:00Z'));
      expect(controller.data.tasks, isEmpty);
      expect(controller.data.goals, isEmpty);
      expect(tester.takeException(), isNull);
      await _dispose(tester, controller);
    },
  );

  testWidgets(
    'a complete event reply saves the same suggestion directly into its calendar date',
    (tester) async {
      final store = _UnderstandingStore();
      store.responses.add(
        () async => AiUnderstanding(
          intent: 'event',
          title: '项目会议',
          summary: '明晚九点讨论半小时',
          outcome: '',
          model: 'test',
          start: DateTime.parse('2026-11-01T21:00:00+08:00'),
          end: DateTime.parse('2026-11-01T21:30:00+08:00'),
        ),
      );
      final controller = SeraController(repository: store, today: _now);
      await controller.initialize();
      await _pump(
        tester,
        controller,
        '/05?prompt=${Uri.encodeComponent('明天九点开会半小时')}',
      );
      await _tap(tester, '理解这段输入');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextButton, '编辑固定事项'), findsOneWidget);
      expect(controller.data.entries, isEmpty);
      await _tap(tester, '保存日程');
      await tester.pumpAndSettle();
      final event = controller.data.entries.single;
      final session = controller.data.planningSessions.single;
      expect(event.start.toUtc(), DateTime.parse('2026-11-01T13:00:00Z'));
      expect(event.end.toUtc(), DateTime.parse('2026-11-01T13:30:00Z'));
      expect(event.notes, contains('原始输入：明天九点开会半小时'));
      expect(session.resultEntity!.id, event.id);
      expect(session.stage, 'confirmed');
      expect(controller.selectedDate.day, 1);
      expect(find.widgetWithText(AppBar, '日程'), findsOneWidget);
      expect(store.calls, hasLength(1));
      await controller.saveEntry(event, sourceSessionId: session.id);
      expect(controller.data.entries, hasLength(1));
      expect(tester.takeException(), isNull);
      await _dispose(tester, controller);
    },
  );

  for (final sample
      in <({String name, String? start, String? end, String display})>[
        (
          name: 'only a start',
          start: '2026-11-01T19:00:00+08:00',
          end: null,
          display: '11月1日 周日 19:00 起，结束未确定',
        ),
        (
          name: 'only an end',
          start: null,
          end: '2026-11-01T19:30:00+08:00',
          display: '开始未确定，至 11月1日 周日 19:30',
        ),
        (
          name: 'an interval across midnight',
          start: '2026-11-01T19:00:00+08:00',
          end: '2026-11-02T00:30:00+08:00',
          display: '11月1日 周日 19:00 — 11月2日 周一 00:30',
        ),
      ]) {
    testWidgets(
      'the review template preserves ${sample.name} without inventing missing times',
      (tester) async {
        final store = _UnderstandingStore();
        store.responses.add(
          () async => AiUnderstanding(
            intent: 'event',
            title: '夜间资料讨论',
            summary: '先核对目前已明确的活动时间。',
            outcome: '',
            model: 'semantic-understanding-test-model',
            start: sample.start == null ? null : DateTime.parse(sample.start!),
            end: sample.end == null ? null : DateTime.parse(sample.end!),
          ),
        );
        final controller = SeraController(repository: store, today: _now);
        await controller.initialize();
        await _pump(
          tester,
          controller,
          '/05?prompt=${Uri.encodeComponent('我们要进行一次夜间讨论，先记录已经确认的时间。')}',
        );
        await _tap(tester, '理解这段输入');
        await tester.pumpAndSettle();
        _expectUnderstandingTemplate(
          tester: tester,
          time: sample.display,
          title: '夜间资料讨论',
          summary: '先核对目前已明确的活动时间。',
          hasOutcome: false,
        );
        final saved = AiUnderstanding.fromJson(
          controller.planningSession()!.understanding!,
        );
        expect(
          saved.start,
          sample.start == null ? isNull : DateTime.parse(sample.start!),
        );
        expect(
          saved.end,
          sample.end == null ? isNull : DateTime.parse(sample.end!),
        );
        expect(saved.deadline, isNull);
        _expectNoBusinessWrites(controller);
        expect(tester.takeException(), isNull);
        await _dispose(tester, controller);
      },
    );
  }

  testWidgets(
    'other intent displays the actual model reply without creating an action',
    (tester) async {
      const reply = '听起来你想先梳理最近的压力，可以从最困扰你的一件事说起。';
      final store = _UnderstandingStore();
      store.responses.add(
        () async => const AiUnderstanding(
          intent: 'other',
          title: '梳理最近的压力',
          summary: reply,
          outcome: '',
          model: 'semantic-understanding-test-model',
        ),
      );
      final controller = SeraController(repository: store, today: _now);
      await controller.initialize();
      await _pump(
        tester,
        controller,
        '/05?prompt=${Uri.encodeComponent('最近事情很多，我想先聊聊。')}',
      );
      await _tap(tester, '理解这段输入');
      await tester.pumpAndSettle();
      _expectUnderstandingTemplate(
        tester: tester,
        time: '未确定',
        title: '梳理最近的压力',
        summary: reply,
        hasOutcome: false,
      );
      expect(find.widgetWithText(SeraButton, '核对目标并规划'), findsNothing);
      expect(find.widgetWithText(SeraButton, '编辑任务'), findsNothing);
      expect(find.widgetWithText(SeraButton, '编辑固定事项'), findsNothing);
      _expectNoBusinessWrites(controller);
      expect(tester.takeException(), isNull);
      await _dispose(tester, controller);
    },
  );

  testWidgets(
    'a failed understanding retains the input and retries without a fabricated result',
    (tester) async {
      final store = _UnderstandingStore();
      store.responses.addAll([
        () => Future.error(const RepositoryException('在线理解服务暂时不可用，请重试。')),
        () async => _goal(),
      ]);
      final controller = SeraController(repository: store, today: _now);
      await controller.initialize();
      await _pump(
        tester,
        controller,
        '/05?prompt=${Uri.encodeComponent(_prompt)}',
      );
      await _tap(tester, '理解这段输入');
      await tester.pumpAndSettle();
      expect(find.text('在线理解服务暂时不可用，请重试。'), findsOneWidget);
      expect(_value(tester, '这次想处理什么？'), _prompt);
      expect(controller.planningSession()!.understanding, isNull);
      expect(find.widgetWithText(SeraButton, '核对目标并规划'), findsNothing);
      _expectNoBusinessWrites(controller);
      await _tap(tester, '重新理解');
      await tester.pumpAndSettle();
      expect(store.calls, hasLength(2));
      expect(store.calls.last.requestId, isNot(store.calls.first.requestId));
      expect(store.calls.last.input['prompt'], _prompt);
      expect(find.text(_goal().summary), findsOneWidget);
      _expectNoBusinessWrites(controller);
      expect(tester.takeException(), isNull);
      await _dispose(tester, controller);
    },
  );

  testWidgets(
    'canceling understanding preserves the session and ignores a late provider result',
    (tester) async {
      final store = _UnderstandingStore();
      final gate = Completer<AiUnderstanding>();
      store.responses.add(() => gate.future);
      final controller = SeraController(repository: store, today: _now);
      await controller.initialize();
      await _pump(
        tester,
        controller,
        '/05?prompt=${Uri.encodeComponent(_prompt)}',
      );
      await _tap(tester, '理解这段输入');
      expect(controller.understanding, isTrue);
      await _tap(tester, '取消理解');
      expect(store.cancellations, 1);
      expect(controller.understanding, isFalse);
      expect(controller.planningSession()!.stage, 'understanding_canceled');
      gate.complete(_goal());
      await tester.pumpAndSettle();
      expect(find.text(_goal().summary), findsNothing);
      expect(_value(tester, '这次想处理什么？'), _prompt);
      expect(controller.planningSession()!.understanding, isNull);
      expect(controller.planningSession()!.understandingRequestId, isNull);
      _expectNoBusinessWrites(controller);
      expect(tester.takeException(), isNull);
      await _dispose(tester, controller);
    },
  );

  testWidgets(
    'a pending durable request resumes only on explicit action with the exact saved payload',
    (tester) async {
      final store = _UnderstandingStore();
      store.responses.add(() async => _goal());
      final controller = SeraController(repository: store, today: _now);
      await controller.initialize();
      final frozenInput = <String, dynamic>{
        'prompt': _prompt,
        'notes': '保留上次已确认的补充',
        'referenceNow': '2026-10-30T20:31:00+08:00',
        'timeZone': 'Asia/Hong_Kong',
        'dailyBudget': 25,
      };
      await controller.savePlanningSession(
        PlanningSession(
          id: 'pending-understanding',
          prompt: _prompt,
          updatedAt: _now,
          stage: 'understanding',
          understandingRequestId: 'frozen-understanding-job',
          understandingInput: frozenInput,
        ),
      );
      await _pump(tester, controller, '/05?sessionId=pending-understanding');
      expect(store.calls, isEmpty);
      expect(find.widgetWithText(TextButton, '继续理解'), findsOneWidget);
      await _tap(tester, '继续理解');
      await tester.pumpAndSettle();
      expect(store.calls.single.requestId, 'frozen-understanding-job');
      expect(store.calls.single.input, frozenInput);
      expect(find.text(_goal().summary), findsOneWidget);
      _expectNoBusinessWrites(controller);
      expect(tester.takeException(), isNull);
      await _dispose(tester, controller);
    },
  );

  testWidgets(
    'editing recovered notes starts a new request with the current reference time',
    (tester) async {
      final store = _UnderstandingStore();
      store.responses.add(() async => _goal());
      final controller = SeraController(repository: store, today: _now);
      await controller.initialize();
      final frozenInput = <String, dynamic>{
        'prompt': _prompt,
        'notes': '上一轮每天二十五分钟',
        'referenceNow': '2026-10-30T20:31:00+08:00',
        'timeZone': 'Asia/Hong_Kong',
        'dailyBudget': 25,
      };
      await controller.savePlanningSession(
        PlanningSession(
          id: 'edited-understanding',
          prompt: _prompt,
          notes: '上一轮每天二十五分钟',
          updatedAt: _now,
          stage: 'understanding',
          understandingRequestId: 'outdated-understanding-job',
          understandingInput: frozenInput,
        ),
      );
      await _pump(tester, controller, '/05?sessionId=edited-understanding');
      expect(store.calls, isEmpty);
      expect(find.widgetWithText(TextButton, '继续理解'), findsOneWidget);
      await _send(tester, '改为每天二十分钟，周末不练习。');
      await tester.pumpAndSettle();
      expect(store.calls, hasLength(1));
      expect(store.calls.single.requestId, isNot('outdated-understanding-job'));
      expect(store.calls.single.input['prompt'], _prompt);
      expect(
        store.calls.single.input['notes'],
        '上一轮每天二十五分钟\n\n改为每天二十分钟，周末不练习。',
      );
      expect(
        DateTime.parse(store.calls.single.input['referenceNow'] as String)
            .toUtc(),
        DateTime.parse('2026-10-31T08:00:00Z'),
      );
      expect(
        store.calls.single.input['referenceNow'],
        isNot(frozenInput['referenceNow']),
      );
      expect(find.text(_goal().summary), findsOneWidget);
      expect(controller.planningSession()!.notes, contains('周末不练习'));
      _expectNoBusinessWrites(controller);
      expect(tester.takeException(), isNull);
      await _dispose(tester, controller);
    },
  );

  testWidgets(
    'manual goal entry preserves literal input and never infers a deadline',
    (tester) async {
      final store = _UnderstandingStore();
      final controller = SeraController(repository: store, today: _now);
      await controller.initialize();
      await _pump(
        tester,
        controller,
        '/05?prompt=${Uri.encodeComponent(_prompt)}',
      );
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建目标'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '确认目标'), findsOneWidget);
      final title = tester.widget<TextFormField>(
        find.byType(TextFormField).first,
      );
      expect(title.controller!.text, _prompt);
      expect(find.text('尚未设置截止日期'), findsOneWidget);
      expect(store.calls, isEmpty);
      _expectNoBusinessWrites(controller);
      expect(tester.takeException(), isNull);
      await _dispose(tester, controller);
    },
  );

  testWidgets(
    'supplement row sends one new paragraph with prior context and no business writes',
    (tester) async {
      final store = _UnderstandingStore();
      final gate = Completer<AiUnderstanding>();
      store.responses.add(() => gate.future);
      final controller = SeraController(repository: store, today: _now);
      await controller.initialize();
      await controller.savePlanningSession(
        PlanningSession(
          id: 'conversation',
          prompt: _prompt,
          notes: '周一到周五在地铁上练习。',
          stage: 'understood',
          understanding: _goal().toJson(),
          clarificationAnswers: const {'commute_mode': '只能听'},
          updatedAt: _now,
        ),
      );
      await _pump(tester, controller, '/05?sessionId=conversation');
      expect(find.text('补充条件与手动填写'), findsNothing);
      final send = find.byKey(const ValueKey('planning-chat-send'));
      expect(tester.getSize(send).height, greaterThanOrEqualTo(48));
      expect(tester.widget<IconButton>(send).onPressed, isNull);
      expect(store.calls, isEmpty);
      await _send(tester, '  周末改为在家开口复述。  ');
      expect(store.calls, hasLength(1));
      final input = store.calls.single.input;
      expect(input['prompt'], _prompt);
      expect(input['notes'], '周一到周五在地铁上练习。\n\n周末改为在家开口复述。');
      expect((input['previous'] as Map)['title'], _goal().title);
      expect((input['previous'] as Map)['clarificationAnswers'], {
        'commute_mode': '只能听',
      });
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('planning-chat-composer')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(controller.planningSession()!.notes, input['notes']);
      _expectNoBusinessWrites(controller);
      gate.complete(_goal());
      await tester.pumpAndSettle();
      expect(store.calls, hasLength(1));
      expect(find.text('请先补充至少一项回答。'), findsNothing);
      expect(tester.takeException(), isNull);
      await _dispose(tester, controller);
    },
  );

  testWidgets(
    'manual goal uses the unsent first message without an AI request',
    (tester) async {
      final store = _UnderstandingStore();
      final controller = SeraController(repository: store, today: _now);
      await controller.initialize();
      await _pump(tester, controller, '/05?new=1');
      await tester.enterText(
        find.byKey(const ValueKey('planning-chat-composer')),
        _prompt,
      );
      await tester.pump();
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建目标'));
      await tester.pumpAndSettle();
      expect(_value(tester, '目标名称'), _prompt);
      expect(controller.planningSession()!.prompt, _prompt);
      expect(controller.planningSession()!.composerDraft, isEmpty);
      expect(store.calls, isEmpty);
      _expectNoBusinessWrites(controller);
      expect(tester.takeException(), isNull);
      await _dispose(tester, controller);
    },
  );

  testWidgets(
    'unsent chat draft survives leaving and reopening without an AI request',
    (tester) async {
      final store = _UnderstandingStore();
      store.responses.add(() async => _goal());
      final controller = SeraController(repository: store, today: _now);
      await controller.initialize();
      await _pump(
        tester,
        controller,
        '/05?prompt=${Uri.encodeComponent(_prompt)}',
      );
      await tester.enterText(
        find.byKey(const ValueKey('planning-chat-composer')),
        '先保留，还没发送。',
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(store.calls, isEmpty);
      final session = controller.planningSession()!;
      expect(session.composerDraft, '先保留，还没发送。');
      expect(session.notes, isEmpty);
      _expectNoBusinessWrites(controller);
      await _pump(tester, controller, '/05?sessionId=${session.id}');
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('planning-chat-composer')),
            )
            .controller!
            .text,
        '先保留，还没发送。',
      );
      expect(store.calls, isEmpty);
      await _send(tester, '先保留，还没发送。');
      await tester.pumpAndSettle();
      expect(store.calls, hasLength(1));
      expect(store.calls.single.input['notes'], '先保留，还没发送。');
      expect(controller.planningSession()!.composerDraft, isEmpty);
      expect(tester.takeException(), isNull);
      await _dispose(tester, controller);
    },
  );

  testWidgets(
    'failed supplement retry does not append twice and the next paragraph gets a new request',
    (tester) async {
      final store = _UnderstandingStore();
      store.responses.addAll([
        () async => throw const RepositoryException('网络中断', offline: true),
        () async => _goal(),
        () async => _goal(),
      ]);
      final controller = SeraController(repository: store, today: _now);
      await controller.initialize();
      await controller.savePlanningSession(
        PlanningSession(
          id: 'retry-conversation',
          prompt: _prompt,
          stage: 'understood',
          understanding: _goal().toJson(),
          updatedAt: _now,
        ),
      );
      await _pump(tester, controller, '/05?sessionId=retry-conversation');
      Future<void> send(String text) async {
        await _send(tester, text);
        await tester.pumpAndSettle();
      }

      await send('周末休息。');
      expect(find.text('上次理解'), findsOneWidget);
      expect(controller.planningSession()!.notes, '周末休息。');
      await _tap(tester, '继续理解');
      await tester.pumpAndSettle();
      expect(store.calls, hasLength(2));
      expect(store.calls[1].requestId, store.calls[0].requestId);
      expect(store.calls[1].input, store.calls[0].input);
      expect(controller.planningSession()!.notes, '周末休息。');
      await send('每天最多十五分钟。');
      expect(store.calls, hasLength(3));
      expect(store.calls.last.requestId, isNot(store.calls.first.requestId));
      expect(store.calls.last.input['notes'], '周末休息。\n\n每天最多十五分钟。');
      _expectNoBusinessWrites(controller);
      expect(tester.takeException(), isNull);
      await _dispose(tester, controller);
    },
  );
}
