import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/sera_motion.dart';
import 'package:sera_flutter/ui/core/sera_todo_row.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:sera_flutter/ui/screens/task_screens.dart';

class _Store implements WorkspaceRepository {
  _Store(this.value);
  Workspace value;
  int writes = 0;

  @override
  String get mode => 'inline-scroll-test';
  @override
  Future<Workspace> load() async => value;
  @override
  Future<void> clear() async => value = const Workspace();
  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    expect(value.revision, expectedRevision);
    writes++;
    return value = next.copyWith(revision: expectedRevision + 1);
  }
}

Future<({GoRouter router, _Store store})> _mount(
  WidgetTester tester,
  List<SeraTask> tasks, {
  double width = 390,
  double textScale = 1,
  bool reduceMotion = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final store = _Store(Workspace(revision: 1, tasks: tasks));
  final controller = SeraController(
    repository: store,
    today: DateTime(2026, 11, 9),
    seedDemo: false,
  );
  await controller.initialize();
  final router = GoRouter(
    initialLocation: '/17?filter=todo',
    routes: [
      GoRoute(
        path: '/:screen',
        pageBuilder: (context, state) => SeraMotion.page<void>(
          context: context,
          state: state,
          child: buildTaskScreen(
            state.pathParameters['screen']!,
            taskId: state.uri.queryParameters['taskId'],
          ),
        ),
      ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
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
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: reduceMotion,
          ),
          child: SeraMotionScope(child: child!),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (router: router, store: store);
}

List<SeraTask> _tasks(int count) => List.generate(
  count,
  (index) => SeraTask(
    id: 'scroll-task-$index',
    title: index % 3 == 0 ? '任务 $index：整理会议资料并核对需要提交的内容' : '任务 $index',
    checklist: ['任务 $index 的资料', '任务 $index 的核对结果'],
  ),
);

Finder _row(String id) => find.byKey(ValueKey('task-list-row:$id'));
Finder _checks(String id) => find.byKey(ValueKey('todo-checklist:$id'));
Finder _toggle(String id, {bool expanded = false}) => find.descendant(
  of: _row(id),
  matching: find.byTooltip(expanded ? '收起子项' : '展开子项'),
);

void main() {
  testWidgets(
    '320px large text checklist wraps and collapses with reduced motion',
    (tester) async {
      const task = SeraTask(
        id: 'long-checks',
        title: '整理下周项目会议的材料并确认各项准备工作',
        checklist: [
          '收集各组的最新进展、待解决的问题和需要其他同事协助的事项，整理成会前阅读材料。',
          '核对材料中的日期、负责人和关键数字，确认每项内容都有清楚的来源，再发给参会同事。',
        ],
      );
      final harness = await _mount(
        tester,
        [task],
        width: 320,
        textScale: 1.5,
        reduceMotion: true,
      );
      final collapsedHeight = tester.getSize(_row(task.id)).height;
      await tester.tap(_toggle(task.id));
      await tester.pumpAndSettle();
      expect(_checks(task.id), findsOneWidget);
      expect(
        tester.getSize(_row(task.id)).height,
        greaterThan(collapsedHeight),
      );
      for (final check in task.checklist) {
        final text = find.descendant(
          of: _checks(task.id),
          matching: find.text(check),
        );
        await tester.ensureVisible(text);
        await tester.pumpAndSettle();
        expect(text.hitTestable(), findsOneWidget);
        final bounds = tester.getRect(text);
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(320));
        expect(bounds.height, greaterThan(40), reason: 'long items must wrap');
        expect(tester.takeException(), isNull);
      }
      await tester.ensureVisible(_toggle(task.id, expanded: true));
      await tester.pumpAndSettle();
      await tester.tap(_toggle(task.id, expanded: true));
      // No animation time is advanced: reduced motion must finish the collapse.
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(_checks(task.id), findsNothing);
      expect(tester.getSize(_row(task.id)).height, closeTo(collapsedHeight, 1));
      expect(_toggle(task.id).hitTestable(), findsOneWidget);
      expect(harness.router.state.uri.path, '/17');
      expect(harness.store.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'expanded lazy row survives scrolling and detail return with its own identity',
    (tester) async {
      final tasks = _tasks(100);
      final harness = await _mount(tester, tasks);
      final target = tasks[1];
      await tester.tap(_toggle(target.id));
      await tester.pumpAndSettle();
      final scroll = Scrollable.of(tester.element(_row(target.id))).position;
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1800));
      await tester.pumpAndSettle();
      expect(scroll.pixels, greaterThan(1000));
      expect(_row(target.id).hitTestable(), findsNothing);
      expect(find.byType(SeraTodoRow).evaluate().length, lessThan(30));

      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(_checks(target.id), findsOneWidget);
      expect(_checks(tasks[0].id), findsNothing);
      expect(_checks(tasks[2].id), findsNothing);
      final title = find.descendant(
        of: _row(target.id),
        matching: find.text(target.title),
      );
      await tester.ensureVisible(title);
      await tester.pumpAndSettle();
      final offsetBeforeOpen = scroll.pixels;
      await tester.tap(title);
      await tester.pumpAndSettle();
      expect(harness.router.state.uri.queryParameters['taskId'], target.id);
      expect(find.text('任务详情'), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(scroll.pixels, closeTo(offsetBeforeOpen, 1));
      expect(_row(target.id).hitTestable(), findsOneWidget);
      expect(_checks(target.id), findsOneWidget);
      expect(
        tester
            .widget<SeraTodoRow>(
              find.descendant(
                of: _row(target.id),
                matching: find.byType(SeraTodoRow),
              ),
            )
            .task
            .id,
        target.id,
      );
      expect(_checks(tasks[2].id), findsNothing);
      expect(harness.store.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'far ID reveal remains accurate with an expanded variable-height row',
    (tester) async {
      final tasks = _tasks(300);
      final harness = await _mount(tester, tasks);
      final first = tasks.first;
      final last = tasks.last;
      await tester.tap(_toggle(first.id));
      await tester.pumpAndSettle();
      expect(_checks(first.id), findsOneWidget);
      expect(_row(last.id), findsNothing);

      harness.router.go('/17?filter=todo&focusTaskId=${last.id}');
      await tester.pumpAndSettle();
      expect(_row(last.id).hitTestable(), findsOneWidget);
      expect(_checks(last.id), findsNothing);
      expect(_toggle(last.id).hitTestable(), findsOneWidget);
      expect(find.byType(SeraTodoRow).evaluate().length, lessThan(30));

      harness.router.go('/17?filter=todo&focusTaskId=${first.id}');
      await tester.pumpAndSettle();
      expect(_row(first.id).hitTestable(), findsOneWidget);
      expect(_checks(first.id), findsOneWidget);
      expect(_toggle(first.id, expanded: true).hitTestable(), findsOneWidget);
      expect(_checks(tasks[1].id), findsNothing);
      expect(harness.store.value.tasks, hasLength(300));
      expect(harness.store.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
