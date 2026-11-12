import 'dart:convert';
import 'dart:io';

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

import '../scripts/task_list_benchmark.dart';

class _Store implements WorkspaceRepository {
  _Store(this.value);
  Workspace value;
  int writes = 0;
  @override
  String get mode => 'scale-test';
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

void main() {
  final measurements = <Map<String, Object>>[];
  for (final count in [100, 300, 1000]) {
    testWidgets('$count tasks remain lazy, reachable and unchanged on read', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final workspace = taskBenchmarkWorkspace(count);
      final store = _Store(workspace);
      final controller = SeraController(
        repository: store,
        today: DateTime(2026, 11, 8),
      );
      await controller.initialize();
      final reference = legacyTaskList(
        tasks: workspace.tasks,
        entries: workspace.entries,
        day: controller.today,
        filter: 'all',
      );
      final eagerWatch = Stopwatch()..start();
      await tester.pumpWidget(
        MaterialApp(
          home: SeraScaffold(
            title: '计划',
            body: Column(
              children: [
                for (final task in reference.tasks)
                  SeraTodoRow(task, entry: reference.firstEntries[task.id]),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      eagerWatch.stop();
      final eagerRows = find.byType(SeraTodoRow).evaluate().length;
      expect(eagerRows, count);
      await tester.pumpWidget(const SizedBox.shrink());
      final router = GoRouter(
        initialLocation: '/17?filter=all',
        routes: [
          GoRoute(
            path: '/:screen',
            builder: (_, state) => buildTaskScreen(
              state.pathParameters['screen']!,
              taskId: state.uri.queryParameters['taskId'],
            ),
          ),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        router.dispose();
      });
      final lazyWatch = Stopwatch()..start();
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
      await tester.pumpAndSettle();
      lazyWatch.stop();
      final lazyRows = find.byType(SeraTodoRow).evaluate().length;
      expect(lazyRows, greaterThan(0));
      expect(lazyRows, lessThan(30));
      expect(controller.data.tasks, hasLength(count));
      final listBefore = tester.widget<SliverList>(find.byType(SliverList));
      controller.setSelectedDate(DateTime(2026, 11, 10));
      await tester.pumpAndSettle();
      expect(
        identical(
          tester.widget<SliverList>(find.byType(SliverList)),
          listBefore,
        ),
        isTrue,
        reason: 'calendar-only changes must not rebuild the task query/list',
      );

      // Navigate to an unbuilt, variably sized row near the end without walking
      // the list screen by screen. Read and navigation must not write data.
      final target = workspace.tasks.lastWhere((task) => task.active);
      final finder = find.byKey(ValueKey('task-list-row:${target.id}'));
      expect(finder, findsNothing);
      final revealWatch = Stopwatch()..start();
      router.go('/17?filter=all&focusTaskId=${target.id}');
      await tester.pumpAndSettle();
      revealWatch.stop();
      expect(finder.hitTestable(), findsOneWidget);
      expect(find.byType(SeraTodoRow).evaluate().length, lessThan(30));
      final scroll = Scrollable.of(tester.element(finder)).position;
      final offset = scroll.pixels;
      await tester.tap(
        find.descendant(of: finder, matching: find.text(target.title)),
      );
      await tester.pumpAndSettle();
      expect(router.state.uri.queryParameters['taskId'], target.id);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(scroll.pixels, closeTo(offset, 1));
      expect(finder.hitTestable(), findsOneWidget);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
      measurements.add({
        'tasks': count,
        'eagerBuiltRows': eagerRows,
        'lazyBuiltRows': lazyRows,
        'eagerHarnessMicroseconds': eagerWatch.elapsedMicroseconds,
        'lazyHarnessMicroseconds': lazyWatch.elapsedMicroseconds,
        'farIdRevealHarnessMicroseconds': revealWatch.elapsedMicroseconds,
      });
    });
  }
  tearDownAll(() {
    final output = File('.local/minimal-engineering-list-benchmark.json');
    final report = output.existsSync()
        ? jsonDecode(output.readAsStringSync()) as Map<String, dynamic>
        : <String, dynamic>{};
    report['widgetHarnessNote'] = 'Flutter widget test/debug harness, 390x844; eager reference only renders rows, production lazy includes navigation/filter headers. Times are diagnostic, not profile/device frame performance or a controlled speed ratio.';
    report['widgetResults'] = measurements;
    output.parent.createSync(recursive: true);
    output.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(report),
    );
  });
}
