import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/domain/seed_data.dart';
import 'package:sera_flutter/ui/core/sera_motion.dart';
import 'package:sera_flutter/ui/core/sera_plan_switcher.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _MotionStore implements WorkspaceRepository {
  _MotionStore(this.value);
  Workspace? value;
  int writes = 0;

  @override
  String get mode => 'motion-test';

  @override
  Future<Workspace?> load() async => value;

  @override
  Future<void> clear() async => value = null;

  @override
  Future<Workspace> save(
    Workspace workspace, {
    required int expectedRevision,
  }) async {
    writes++;
    return value = workspace.copyWith(revision: expectedRevision + 1);
  }
}

Future<({SeraController controller, _MotionStore store, GoRouter router})>
_mount(WidgetTester tester, String location) async {
  final store = _MotionStore(
    createSeedWorkspace(DateTime(2026, 10, 31)).copyWith(revision: 1),
  );
  final controller = SeraController(
    repository: store,
    today: DateTime(2026, 10, 31),
  );
  await controller.initialize();
  await tester.pumpWidget(
    SeraApp(controller: controller, initialLocation: location),
  );
  await tester.pumpAndSettle();
  final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  return (controller: controller, store: store, router: router);
}

String _title(WidgetTester tester) => tester
    .widget<TextFormField>(find.byType(TextFormField).first)
    .controller!
    .text;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  for (final location in ['/04', '/17?filter=todo', '/20', '/37']) {
    testWidgets(
      'today and plan sections preserve their own identity and detail return: $location',
      (tester) async {
        final app = await _mount(tester, location);
        final before = app.controller.data.toJson();
        final writes = app.store.writes;
        final plan = location.startsWith('/17') || location == '/20';
        expect(find.widgetWithText(AppBar, plan ? '计划' : '今日'), findsOneWidget);
        expect(
          tester.widget<SeraScaffold>(find.byType(SeraScaffold)).navIndex,
          plan ? 1 : 0,
        );
        expect(find.text('我的'), findsNothing);
        expect(
          find.byType(SeraPlanSwitcher),
          plan ? findsOneWidget : findsNothing,
        );
        if (plan) {
          expect(
            tester
                .widget<SeraPlanSwitcher>(find.byType(SeraPlanSwitcher))
                .goals,
            location == '/20',
          );
        }
        if (location != '/20') {
          expect(find.text(app.controller.task('task-1')!.title), findsWidgets);
        }

        app.router.push<void>('/18?taskId=task-1');
        await tester.pumpAndSettle();
        expect(find.widgetWithText(AppBar, '任务详情'), findsOneWidget);
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        expect(
          app.router.routeInformationProvider.value.uri.toString(),
          location,
        );
        expect(find.widgetWithText(AppBar, plan ? '计划' : '今日'), findsOneWidget);
        expect(app.controller.data.toJson(), before);
        expect(app.store.writes, writes);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final width in [320.0, 360.0, 390.0, 430.0, 1024.0]) {
    testWidgets('real editor identities and clipped frames at $width px', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = await _mount(tester, '/09?taskId=task-1');
      final writes = app.store.writes;
      expect(_title(tester), app.controller.task('task-1')!.title);

      app.router.go('/09?taskId=task-2');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byType(SeraRouteTransition), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(_title(tester), app.controller.task('task-2')!.title);
      expect(
        app.router.routeInformationProvider.value.uri.toString(),
        '/09?taskId=task-2',
      );

      app.router.go('/16?eventId=meeting-1');
      await tester.pumpAndSettle();
      expect(_title(tester), '产品周会');
      app.router.go('/16?title=First&fromAi=1&requiresTimeConfirmation=1');
      await tester.pumpAndSettle();
      expect(_title(tester), 'First');
      app.router.go('/16?title=Second&fromAi=1&requiresTimeConfirmation=1');
      await tester.pumpAndSettle();
      expect(_title(tester), 'Second');

      app.router.go('/19?title=NewA&estimatedMinutes=20');
      await tester.pumpAndSettle();
      expect(_title(tester), 'NewA');
      app.router.go('/19?title=NewB&estimatedMinutes=35');
      await tester.pumpAndSettle();
      expect(_title(tester), 'NewB');
      expect(
        app.store.writes,
        writes,
        reason: 'A transition or a new prefill must never submit a form',
      );
      final viewport = tester.getSize(find.byType(Scaffold).first);
      expect(viewport.width, width.clamp(0, 430));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('existing object ignores new-form prefill without losing edits', (
    tester,
  ) async {
    final app = await _mount(tester, '/09?taskId=task-1');
    final writes = app.store.writes;
    final title = find.byType(TextFormField).first;
    final originalState = tester.state(title);
    await tester.enterText(title, 'Synthetic unsaved edit');
    app.router.go('/09?title=ignored&taskId=task-1');
    await tester.pumpAndSettle();
    expect(_title(tester), 'Synthetic unsaved edit');
    expect(tester.state(find.byType(TextFormField).first), same(originalState));
    expect(app.store.writes, writes);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'capture draft survives dismissal and browser-style back interruption',
    (tester) async {
      final app = await _mount(tester, '/04');
      final writes = app.store.writes;
      final capture = find.byKey(const ValueKey('today-capture'));
      await tester.tap(capture);
      await tester.pumpAndSettle();
      await tester.tap(find.text('文字输入'));
      await tester.pumpAndSettle();
      final prompt = find.byType(TextField).first;
      await tester.enterText(prompt, 'Synthetic unsent motion draft');
      Navigator.of(tester.element(prompt)).pop();
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      // Model a browser/system back during the destination's entering frames.
      app.router.push<void>('/35');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(app.router.canPop(), isTrue);
      app.router.pop();
      await tester.pumpAndSettle();
      expect(app.router.canPop(), isFalse);
      await tester.tap(capture);
      await tester.pumpAndSettle();
      if (find.text('文字输入').evaluate().isNotEmpty) {
        await tester.tap(find.text('文字输入'));
        await tester.pumpAndSettle();
      }
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'Synthetic unsent motion draft',
      );
      expect(app.store.writes, writes);
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.byType(TextField).first)).pop();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('replace editor with detail keeps the existing stack depth', (
    tester,
  ) async {
    final app = await _mount(tester, '/17');
    app.router.push<void>('/09?taskId=task-1');
    await tester.pumpAndSettle();
    app.router.replace<void>('/18?taskId=task-2');
    await tester.pumpAndSettle();
    expect(find.text(app.controller.task('task-2')!.title), findsWidgets);
    expect(app.router.canPop(), isTrue);
    app.router.pop();
    await tester.pumpAndSettle();
    expect(app.router.canPop(), isFalse);
    expect(find.byType(TextFormField), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
