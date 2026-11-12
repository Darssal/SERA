import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/sera_motion.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _offlineStatus = '离线 · 2 项待同步';

class _OfflineStore
    implements WorkspaceRepository, SynchronizingWorkspaceRepository {
  final value = Workspace(
    revision: 7,
    tasks: const [
      SeraTask(id: 'pending-task', title: '待同步的合成任务', estimatedMinutes: 30),
    ],
    entries: [
      CalendarEntry(
        id: 'pending-entry',
        taskId: 'pending-task',
        title: '待同步的合成任务',
        start: DateTime(2026, 10, 31, 10),
        end: DateTime(2026, 10, 31, 10, 30),
      ),
    ],
  );
  int reads = 0, writes = 0, clears = 0, syncs = 0, resolutions = 0;

  @override
  String get mode => _offlineStatus;
  @override
  int get pendingCount => 2;
  @override
  bool get isOffline => true;
  @override
  Json? get syncConflict => null;

  @override
  Future<Workspace?> load() async {
    reads++;
    return value;
  }

  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    writes++;
    throw StateError('Navigation must not save the isolated workspace.');
  }

  @override
  Future<void> clear() async {
    clears++;
    throw StateError('Navigation must not clear the isolated workspace.');
  }

  @override
  Future<Workspace?> synchronize() async {
    syncs++;
    return value;
  }

  @override
  Future<Workspace?> resolveConflict({required bool keepLocal}) async {
    resolutions++;
    return value;
  }
}

Future<SeraController> _mount(
  WidgetTester tester,
  _OfflineStore store,
  String route,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = SeraController(
    repository: store,
    today: DateTime(2026, 10, 31),
    seedDemo: false,
  );
  await controller.initialize();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  await tester.pumpWidget(
    SeraApp(controller: controller, initialLocation: route),
  );
  await tester.pumpAndSettle();
  return controller;
}

void _expectNoNavigationWrites(_OfflineStore store) {
  expect(store.reads, 1);
  expect(store.writes, 0);
  expect(store.clears, 0);
  expect(store.syncs, 0);
  expect(store.resolutions, 0);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets(
    'offline banner opens one sync status and returns without a workspace mutation',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final store = _OfflineStore();
        final controller = await _mount(tester, store, '/04');
        final before = controller.data.toJson();
        final banner = find.byType(SeraBannerTransition);
        final status = find.text(_offlineStatus).hitTestable();
        expect(tester.widget<SeraBannerTransition>(banner).visible, isTrue);
        expect(status, findsOneWidget);
        expect(
          tester.semantics.simulatedAccessibilityTraversal().any(
            (node) => node.getSemanticsData().label == _offlineStatus,
          ),
          isTrue,
        );
        final router = GoRouter.of(
          tester.element(find.byType(SeraScaffold).first),
        );

        await tester.tap(status);
        await tester.pumpAndSettle();
        expect(router.routeInformationProvider.value.uri.path, '/40');
        expect(find.widgetWithText(AppBar, '保存与同步'), findsOneWidget);
        expect(tester.widget<SeraBannerTransition>(banner).visible, isFalse);
        expect(status, findsOneWidget);
        expect(
          find
              .descendant(of: banner, matching: find.text(_offlineStatus))
              .hitTestable(),
          findsNothing,
        );
        expect(find.text('当前连接'), findsNothing);
        expect(find.text('待同步修改'), findsNothing);
        expect(controller.data.toJson(), before);
        _expectNoNavigationWrites(store);

        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        expect(router.routeInformationProvider.value.uri.path, '/04');
        expect(tester.widget<SeraBannerTransition>(banner).visible, isTrue);
        expect(status, findsOneWidget);
        expect(
          find
              .descendant(of: banner, matching: find.text(_offlineStatus))
              .hitTestable(),
          findsOneWidget,
        );
        expect(controller.data.toJson(), before);
        _expectNoNavigationWrites(store);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'the named offline route also presents the body status without a duplicate banner',
    (tester) async {
      final store = _OfflineStore();
      final controller = await _mount(tester, store, '/40-offline');
      final banner = find.byType(SeraBannerTransition);
      expect(find.widgetWithText(AppBar, '保存与同步'), findsOneWidget);
      expect(tester.widget<SeraBannerTransition>(banner).visible, isFalse);
      expect(find.text(_offlineStatus).hitTestable(), findsOneWidget);
      expect(
        find
            .descendant(of: banner, matching: find.text(_offlineStatus))
            .hitTestable(),
        findsNothing,
      );
      expect(controller.data.toJson(), store.value.toJson());
      _expectNoNavigationWrites(store);
      expect(tester.takeException(), isNull);
    },
  );
}
