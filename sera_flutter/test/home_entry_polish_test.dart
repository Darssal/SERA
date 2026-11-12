import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/planning_ai_provider.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Store implements WorkspaceRepository, InputUnderstandingProvider {
  _Store([this.value = const Workspace(revision: 1)]);
  Workspace value;
  int requests = 0;
  int writes = 0;
  final inputs = <Json>[];
  @override
  String get mode => 'home-entry-fixture';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async => value = const Workspace();
  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
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
      title: '整理评审材料',
      summary: '准备评审用的资料',
      outcome: '',
      model: 'isolated-fixture',
      estimatedMinutes: 30,
    );
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<SeraController> mount(
    WidgetTester tester,
    _Store store,
    String path,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = SeraController(
      repository: store,
      today: DateTime(2026, 10, 31),
      seedDemo: false,
    );
    await c.initialize();
    await tester.pumpWidget(SeraApp(controller: c, initialLocation: path));
    await tester.pumpAndSettle();
    addTearDown(c.dispose);
    return c;
  }

  Future<void> capture(WidgetTester tester, {bool textMode = true}) async {
    await tester.tap(find.byKey(const ValueKey('today-capture')));
    await tester.pumpAndSettle();
    if (textMode) {
      await tester.tap(find.text('文字输入'));
      await tester.pumpAndSettle();
    }
  }

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.widgetWithText(SeraButton, label));
    await tester.tap(find.widgetWithText(SeraButton, label));
    await tester.pumpAndSettle();
  }

  testWidgets('capture opens with voice first without recording or writing', (
    tester,
  ) async {
    final store = _Store();
    await mount(tester, store, '/04');
    await capture(tester, textMode: false);
    expect(find.byKey(const ValueKey('voice-hold-button')), findsOneWidget);
    expect(find.text('按住说话'), findsOneWidget);
    expect(find.text('文字输入'), findsOneWidget);
    expect(find.byKey(const ValueKey('capture-text-input')), findsNothing);
    expect(find.widgetWithText(SeraButton, '手动添加任务'), findsNothing);
    expect(store.requests, 0);
    expect(store.writes, 0);
    await tester.tap(find.text('文字输入'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '保留输入再切回语音');
    await tester.tap(find.text('语音输入'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller!.text,
      '保留输入再切回语音',
    );
    expect(store.requests, 0);
    expect(store.writes, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('calendar shows adjustment only for movable active task blocks', (
    tester,
  ) async {
    final store = _Store();
    await mount(tester, store, '/12');
    expect(find.text('这一天没有安排'), findsOneWidget);
    expect(find.byType(SeraEmpty), findsNothing);
    expect(find.byTooltip('账户与设置'), findsNothing);
    expect(find.byTooltip('调整安排'), findsNothing);
    expect(find.byTooltip('添加日程'), findsOneWidget);
    final at = DateTime(2026, 10, 31, 10);
    for (final scenario in ['fixed', 'locked', 'done', 'movable']) {
      final task = scenario == 'fixed'
          ? null
          : SeraTask(
              id: 't',
              title: '安排',
              status: scenario == 'done' ? 'done' : 'todo',
            );
      store.value = Workspace(
        revision: 2,
        tasks: [?task],
        entries: [
          CalendarEntry(
            id: 'e',
            taskId: task?.id,
            title: '安排',
            start: at,
            end: at.add(const Duration(minutes: 30)),
            locked: scenario == 'locked',
          ),
        ],
      );
      final replacement = SeraController(
        repository: store,
        today: DateTime(2026, 10, 31),
        seedDemo: false,
      );
      await replacement.initialize();
      await tester.pumpWidget(
        SeraApp(
          key: UniqueKey(),
          controller: replacement,
          initialLocation: '/12',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byTooltip('调整安排'),
        scenario == 'movable' ? findsOneWidget : findsNothing,
      );
      expect(find.byTooltip('添加日程'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      replacement.dispose();
    }
    expect(store.writes, 0);
  });

  testWidgets(
    'capture sends one online understanding request and keeps raw input out of URL',
    (tester) async {
      final store = _Store();
      final c = await mount(tester, store, '/04');
      expect(find.byType(TextField), findsNothing);
      await capture(tester);
      const prompt = '准备下周五的方案评审资料';
      await tester.enterText(find.byType(TextField), prompt);
      await choose(tester, '让 AI 安排');
      expect(store.requests, 1);
      expect(store.inputs.single['prompt'], prompt);
      final session = c.data.planningSessions.single;
      final router = GoRouter.of(
        tester.element(find.byType(SeraScaffold).first),
      );
      expect(
        router.routeInformationProvider.value.uri.queryParameters['sessionId'],
        session.id,
      );
      expect(
        router.routeInformationProvider.value.uri.queryParameters['from'],
        'today',
      );
      expect(
        router.routeInformationProvider.value.uri.queryParameters.containsKey(
          'prompt',
        ),
        isFalse,
      );
      expect(c.data.tasks, isEmpty);
      expect(c.data.entries, isEmpty);
      await tester.pumpWidget(
        SeraApp(
          key: UniqueKey(),
          controller: c,
          initialLocation:
              '/05?sessionId=${Uri.encodeQueryComponent(session.id)}&submit=1',
        ),
      );
      await tester.pumpAndSettle();
      expect(store.requests, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('opening AI without text never sends a request', (tester) async {
    final store = _Store();
    await mount(tester, store, '/04');
    await capture(tester);
    await choose(tester, '让 AI 安排');
    expect(find.widgetWithText(AppBar, 'AI 助手'), findsOneWidget);
    expect(store.requests, 0);
    await tester.pumpWidget(const SizedBox());
  });

  for (final route in ['/04', '/37']) {
    testWidgets('$route capture retains a manual title without an AI request', (
      tester,
    ) async {
      final store = _Store();
      final c = await mount(tester, store, route);
      await capture(tester);
      await tester.enterText(find.byType(TextField), '整理方案评审资料');
      await choose(tester, '手动添加任务');
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller!
            .text,
        '整理方案评审资料',
      );
      expect(c.data.planningSessions.single.prompt, '整理方案评审资料');
      expect(store.requests, 0);
      expect(c.data.tasks, isEmpty);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      if (find.text('放弃修改').evaluate().isNotEmpty) {
        await tester.tap(find.text('放弃修改'));
        await tester.pumpAndSettle();
      }
      await capture(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '整理方案评审资料',
      );
      expect(c.data.tasks, isEmpty);
      expect(c.data.planningSessions.single.resultEntity, isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'empty manual capture opens a blank task form without AI or session writes',
    (tester) async {
      final store = _Store();
      final c = await mount(tester, store, '/04');
      await capture(tester);
      final button = find.widgetWithText(SeraButton, '手动添加任务');
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      await choose(tester, '手动添加任务');
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller!
            .text,
        isEmpty,
      );
      expect(c.data.planningSessions, isEmpty);
      expect(store.requests, 0);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Today stays focused while Plan includes scheduled and unscheduled work',
    (tester) async {
      final store = _Store(
        Workspace(
          revision: 1,
          tasks: const [
            SeraTask(id: 'scheduled', title: '今日已安排'),
            SeraTask(id: 'inbox', title: '尚待安排'),
          ],
          entries: [
            CalendarEntry(
              id: 'block',
              taskId: 'scheduled',
              title: '今日已安排',
              start: DateTime(2026, 10, 31, 10),
              end: DateTime(2026, 10, 31, 11),
            ),
          ],
        ),
      );
      await mount(tester, store, '/04');
      expect(find.widgetWithText(AppBar, '今日'), findsOneWidget);
      expect(find.text('今日已安排'), findsOneWidget);
      expect(find.text('尚待安排'), findsNothing);
      await tester.tap(find.text('计划').last);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '计划'), findsOneWidget);
      expect(find.text('尚待安排'), findsOneWidget);
      expect(find.text('今日已安排'), findsOneWidget);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Today isolates due work and completion while keeping the next fixed event',
    (tester) async {
      final store = _Store(
        Workspace(
          revision: 1,
          tasks: [
            SeraTask(
              id: 'due',
              title: '今日要交的材料',
              dueAt: DateTime(2026, 10, 31, 18),
            ),
            const SeraTask(id: 'unplanned', title: '以后整理的阅读清单'),
            SeraTask(
              id: 'future',
              title: '下周再开始',
              notBefore: DateTime(2026, 11, 2),
            ),
          ],
          entries: [
            CalendarEntry(
              id: 'meeting',
              title: '今日会议',
              start: DateTime(2026, 10, 31, 14),
              end: DateTime(2026, 10, 31, 15),
            ),
          ],
        ),
      );
      final c = await mount(tester, store, '/04');
      expect(find.text('今日要交的材料'), findsOneWidget);
      expect(find.text('以后整理的阅读清单'), findsNothing);
      expect(find.text('下周再开始'), findsNothing);
      expect(find.text('今日会议'), findsOneWidget);
      final row = find.byKey(const ValueKey('today-todo:due'));
      await tester.tap(
        find.descendant(of: row, matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
      expect(c.task('due')!.done, isTrue);
      expect(c.task('unplanned')!.done, isFalse);
      expect(find.text('今日要交的材料'), findsNothing);
      await tester.tap(find.text('计划').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, '已完成'));
      await tester.pumpAndSettle();
      expect(find.text('今日要交的材料'), findsOneWidget);
      expect(c.data.entries.single.id, 'meeting');
      expect(store.requests, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final item in [('今日回顾', '/28'), ('本周回顾', '/29'), ('提醒中心', '/27')]) {
    testWidgets('Today more keeps ${item.$1} reachable without data writes', (
      tester,
    ) async {
      final store = _Store();
      await mount(tester, store, '/04');
      await tester.tap(find.byTooltip('今日更多'));
      await tester.pumpAndSettle();
      expect(find.text('全局搜索'), findsNothing);
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, item.$1));
      await tester.pumpAndSettle();
      final router = GoRouter.of(tester.element(find.byType(SeraScaffold)));
      expect(router.state.uri.path, item.$2);
      expect(store.writes, 0);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, '今日'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'minimal Today and capture fit 320px with large text and keyboard',
    (tester) async {
      await mount(tester, _Store(), '/04');
      tester.view.physicalSize = const Size(320, 844);
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      expect(find.text('今天没有待完成的任务'), findsOneWidget);
      expect(find.widgetWithText(SeraButton, '查看任务'), findsNothing);
      await capture(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '大字键盘下保留的输入');
      await tester.ensureVisible(find.widgetWithText(SeraButton, '让 AI 安排'));
      expect(
        find.widgetWithText(SeraButton, '让 AI 安排').hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
