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
import 'package:sera_flutter/ui/screens/main_screens.dart';
import 'package:sera_flutter/ui/screens/task_screens.dart';

class _Store implements WorkspaceRepository {
  _Store(this.value);
  Workspace? value;
  @override
  String get mode => 'list-search-undo-test';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async => value = null;
  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    if (value?.revision != expectedRevision) {
      throw const RepositoryException('版本冲突', conflict: true);
    }
    return value = Workspace.fromJson(
      next.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }
}

class _Harness {
  const _Harness(this.controller, this.router);
  final SeraController controller;
  final GoRouter router;
}

const _target = SeraTask(
  id: 'target',
  title: '采购清单',
  status: 'in_progress',
  checklist: ['牛奶', '面包'],
  completedChecks: ['牛奶'],
);

List<SeraTask> _longList() => [
  for (var i = 0; i < 299; i++) SeraTask(id: 'task-$i', title: '日常事项 $i'),
  _target,
];

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
}

Future<_Harness> _mount(
  WidgetTester tester, {
  required String location,
  required List<SeraTask> tasks,
  double width = 390,
  double bottomPadding = 0,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 844);
  tester.view.padding = FakeViewPadding(bottom: bottomPadding);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewInsets);
  final store = _Store(
    Workspace(
      revision: 1,
      tasks: location == '/04'
          ? tasks
                .map((task) => task.copyWith(dueAt: DateTime(2026, 11, 1, 12)))
                .toList()
          : tasks,
    ),
  );
  final controller = SeraController(
    repository: store,
    today: DateTime(2026, 11, 1),
    accountId: 'list-search-test',
  );
  await controller.initialize();
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/:screen',
        pageBuilder: (context, state) => SeraMotion.page<void>(
          context: context,
          state: state,
          child: state.pathParameters['screen'] == '04'
              ? const TodayScreen()
              : buildTaskScreen(
                  state.pathParameters['screen']!,
                  taskId: state.uri.queryParameters['taskId'],
                ),
        ),
      ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
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
  return _Harness(controller, router);
}

Finder get _targetRow => find.byWidgetPredicate(
  (widget) => widget is SeraTodoRow && widget.task.id == _target.id,
);
Finder get _targetCheckbox =>
    find.descendant(of: _targetRow, matching: find.byType(Checkbox));
Finder get _undo => find.widgetWithText(TextButton, '撤销完成');
SeraScaffold _screen(WidgetTester tester) =>
    tester.widget<SeraScaffold>(find.byType(SeraScaffold));

void main() {
  testWidgets(
    'completing the last of 300 todos exposes undo without scrolling',
    (tester) async {
      final h = await _mount(
        tester,
        location: '/17?filter=todo&focusTaskId=target',
        tasks: _longList(),
        width: 320,
      );
      expect(_screen(tester).footer, isNull);
      await tester.ensureVisible(_targetCheckbox);
      await _frames(tester);
      await tester.tap(_targetCheckbox);
      await _frames(tester);

      expect(h.controller.task(_target.id)!.done, isTrue);
      expect(_targetRow, findsNothing);
      expect(_undo, findsOneWidget);
      expect(tester.getRect(_undo).top, greaterThan(56));
      expect(tester.getRect(_undo).bottom, lessThanOrEqualTo(844));
      // Deliberately no ensureVisible/scroll before undo: it must be on screen.
      await tester.tap(_undo);
      await _frames(tester);

      expect(h.controller.task(_target.id)!.status, 'in_progress');
      expect(h.controller.task(_target.id)!.completedChecks, ['牛奶']);
      expect(h.controller.data.tasks, hasLength(300));
      expect(_targetRow, findsOneWidget);
      expect(_screen(tester).footer, isNull);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'today completion undo stays above navigation and leaves no footer',
    (tester) async {
      final h = await _mount(
        tester,
        location: '/04',
        tasks: _longList(),
        bottomPadding: 24,
      );
      await _frames(tester);
      await tester.ensureVisible(_targetCheckbox);
      await _frames(tester);
      await tester.tap(_targetCheckbox);
      await _frames(tester);

      expect(h.controller.task(_target.id)!.done, isTrue);
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      final navigation = find.byWidget(scaffold.bottomNavigationBar!);
      expect(
        tester.getRect(_undo).bottom,
        lessThan(tester.getRect(navigation).top),
      );
      await tester.tap(_undo);
      await _frames(tester);

      expect(h.controller.task(_target.id)!.completedChecks, ['牛奶']);
      expect(h.controller.task(_target.id)!.status, 'in_progress');
      expect(_screen(tester).footer, isNull);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'focused task link preserves long-list position, detail return and completion undo',
    (tester) async {
      final h = await _mount(
        tester,
        location: '/17?filter=todo&focusTaskId=target',
        tasks: [
          ..._longList(),
          const SeraTask(id: 'completed', title: '采购清单旧记录', status: 'done'),
        ],
      );
      final position = Scrollable.of(tester.element(_targetRow)).position;
      final offset = position.pixels;
      expect(offset, greaterThan(0));
      expect(_targetRow.hitTestable(), findsOneWidget);
      expect(find.byType(SeraTodoRow).evaluate().length, lessThan(30));
      expect(
        h.controller.data.tasks.where((task) => task.active),
        hasLength(300),
      );
      expect(find.text('采购清单旧记录'), findsNothing);
      expect(h.router.state.uri.queryParameters['filter'], 'todo');

      await tester.tap(find.text(_target.title));
      await _frames(tester);
      expect(h.router.state.uri.path, '/18-task-detail');
      await tester.tap(find.byTooltip('返回'));
      await _frames(tester);
      expect(h.router.state.uri.queryParameters['filter'], 'todo');
      expect(position.pixels, closeTo(offset, 1));
      expect(h.router.state.uri.queryParameters['focusTaskId'], 'target');

      // A constrained viewport still exposes the fixed undo after completion.
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await _frames(tester);
      await tester.scrollUntilVisible(
        _targetCheckbox,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await _frames(tester);
      await tester.tap(_targetCheckbox);
      await _frames(tester);
      expect(h.controller.task(_target.id)!.done, isTrue);
      expect(_targetRow, findsNothing);
      expect(
        h.controller.data.tasks.where((task) => task.active),
        hasLength(299),
      );
      expect(tester.getRect(_undo).bottom, lessThanOrEqualTo(844 - 280));
      await tester.tap(_undo);
      await _frames(tester);
      expect(h.controller.task(_target.id)!.status, 'in_progress');
      expect(h.controller.task(_target.id)!.completedChecks, ['牛奶']);
      expect(
        h.controller.data.tasks.where((task) => task.active),
        hasLength(300),
      );
      expect(h.router.state.uri.queryParameters['filter'], 'todo');
      expect(_screen(tester).footer, isNull);

      expect(find.byType(TextField), findsNothing);
      expect(h.controller.task('completed')!.done, isTrue);
      expect(h.router.state.uri.queryParameters['filter'], 'todo');
      expect(tester.takeException(), isNull);
    },
  );
}
