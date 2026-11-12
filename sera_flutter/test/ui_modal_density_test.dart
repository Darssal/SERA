import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/domain/seed_data.dart';
import 'package:sera_flutter/ui/core/sera_motion.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:sera_flutter/ui/screens/main_screens.dart';
import 'package:sera_flutter/ui/screens/platform_screens.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _channel = MethodChannel('com.sera/platform');
final _today = DateTime(2026, 10, 31);

class _ModalStore implements WorkspaceRepository {
  Workspace value = createSeedWorkspace(_today).copyWith(revision: 1);
  Completer<void>? saveGate;
  int saves = 0;

  @override
  String get mode => 'modal-ownership-fixture';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async {}
  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    saves++;
    await saveGate?.future;
    if (value.revision != expectedRevision) {
      throw const RepositoryException('工作区已有修改', conflict: true);
    }
    return value = Workspace.fromJson(
      next.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }
}

class _Harness {
  _Harness(this.controller, String location) {
    router = GoRouter(
      initialLocation: location,
      routes: [
        GoRoute(
          path: '/goal',
          builder: (_, _) =>
              const GoalsScreen(detail: true, goalId: 'goal-review'),
        ),
        GoRoute(
          path: '/platform',
          builder: (_, _) => const PlatformSettingsScreen(mode: '32'),
        ),
        GoRoute(
          path: '/preferences',
          builder: (_, _) => const PreferencesScreen(),
        ),
        GoRoute(
          path: '/elsewhere',
          builder: (_, _) => const Scaffold(body: Text('另一个页面')),
        ),
        GoRoute(
          path: '/42',
          builder: (_, _) => const Scaffold(body: Text('同步结果页面')),
        ),
        GoRoute(
          path: '/08',
          builder: (_, _) => const Scaffold(body: Text('规划草案页面')),
        ),
      ],
    );
  }
  final SeraController controller;
  late final GoRouter router;
  Widget get widget => MultiProvider(
    providers: [
      ChangeNotifierProvider<SeraController>.value(value: controller),
      Provider<AuthRepository?>.value(value: null),
    ],
    child: MaterialApp.router(
      routerConfig: router,
      theme: seraTheme(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => SeraMotionScope(child: child!),
    ),
  );
}

// Bounded frame advances also work while a deliberately gated save or a busy
// LinearProgressIndicator is pending. Never await the pending callback itself.
Future<void> _frames(WidgetTester tester, [int count = 5]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 40 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
  expect(
    ready(),
    isTrue,
    reason: 'Expected fixture event within 40 bounded pumps',
  );
}

Future<_Harness> _mount(
  WidgetTester tester,
  _ModalStore store,
  String location,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = SeraController(repository: store, today: _today);
  await controller.initialize();
  final harness = _Harness(controller, location);
  addTearDown(() async {
    if (store.saveGate?.isCompleted == false) store.saveGate!.complete();
    await tester.pumpWidget(const SizedBox.shrink());
    harness.router.dispose();
    controller.dispose();
  });
  await tester.pumpWidget(harness.widget);
  await _frames(tester);
  return harness;
}

Future<void> _openGoal(WidgetTester tester) async {
  final button = find.widgetWithText(SeraSettingRow, '修改目标信息');
  await tester.ensureVisible(button);
  await tester.tap(button);
  await _frames(tester);
  expect(find.byType(AlertDialog), findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String>[];
  Completer<List<Map<String, dynamic>>>? syncGate;
  Completer<Map<String, dynamic>>? capabilitiesGate;
  const capabilities = {
    'platform': 'android',
    'calendarSupported': true,
    'notificationsSupported': false,
    'backgroundNotifications': false,
    'recordingSupported': false,
    'calendarPermission': 'granted',
    'notificationPermission': 'denied',
    'microphonePermission': 'denied',
    'exactAlarmsSupported': true,
  };
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    calls.clear();
    syncGate = null;
    capabilitiesGate = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'capabilities':
              return capabilitiesGate == null
                  ? capabilities
                  : await capabilitiesGate!.future;
            case 'listCalendars':
              return [
                {
                  'id': 'work',
                  'name': '工作日历',
                  'account': 'fixture',
                  'isSera': false,
                },
              ];
            case 'readBusyEvents':
              return <Map<String, dynamic>>[];
            case 'ensureSeraCalendar':
              return {
                'id': 'sera',
                'name': '序日',
                'account': 'fixture',
                'isSera': true,
              };
            case 'syncCalendarEntries':
              return syncGate == null
                  ? <Map<String, dynamic>>[]
                  : await syncGate!.future;
            default:
              return null;
          }
        });
  });
  tearDown(() {
    if (syncGate?.isCompleted == false) syncGate!.complete([]);
    if (capabilitiesGate?.isCompleted == false) {
      capabilitiesGate!.complete(capabilities);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  testWidgets(
    'goal modal deduplicates saves and blocks cancellation until the owned save completes',
    (tester) async {
      final store = _ModalStore();
      final harness = await _mount(tester, store, '/goal');
      await _openGoal(tester);
      await tester.enterText(find.byType(TextFormField).first, '重新核对目标');
      final gate = store.saveGate = Completer<void>();
      final saves = store.saves;
      final callback = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '保存'))
          .onPressed!;
      callback();
      callback();
      await _until(tester, () => store.saves == saves + 1);
      await _frames(tester, 2);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
            .onPressed,
        isNull,
      );
      await tester.binding.handlePopRoute();
      await _frames(tester, 2);
      expect(find.byType(AlertDialog), findsOneWidget);
      gate.complete();
      await _frames(tester, 1);
      callback(); // The pre-rebuild callback is also inert during reverse motion.
      await _frames(tester);
      expect(store.saves, saves + 1);
      expect(harness.controller.goal('goal-review')!.title, '重新核对目标');
      expect(find.byType(AlertDialog), findsNothing);
      expect(harness.router.routerDelegate.state.uri.path, '/goal');
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('goal save error retains reviewed fields and permits one retry', (
    tester,
  ) async {
    final store = _ModalStore();
    await _mount(tester, store, '/goal');
    await _openGoal(tester);
    await tester.enterText(find.byType(TextFormField).first, '保留未完成的输入');
    final gate = store.saveGate = Completer<void>();
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await _until(tester, () => store.saves == 1);
    gate.completeError(const RepositoryException('测试保存失败，请重试'));
    await _frames(tester);
    expect(find.text('测试保存失败，请重试'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(find.byType(TextFormField).first)
          .controller!
          .text,
      '保留未完成的输入',
    );
    store.saveGate = null;
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await _frames(tester);
    expect(store.saves, 2);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('late goal save cannot pop the route that replaced its owner', (
    tester,
  ) async {
    final store = _ModalStore();
    final harness = await _mount(tester, store, '/goal');
    await _openGoal(tester);
    await tester.enterText(find.byType(TextFormField).first, '保存到原目标');
    final gate = store.saveGate = Completer<void>();
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await _until(tester, () => store.saves == 1);
    harness.router.go('/elsewhere');
    await _frames(tester);
    gate.complete();
    await _frames(tester);
    expect(harness.router.routerDelegate.state.uri.path, '/elsewhere');
    expect(find.text('另一个页面'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'late goal-plan preparation cannot open a draft over a newer route',
    (tester) async {
      final store = _ModalStore();
      final harness = await _mount(tester, store, '/goal');
      final gate = store.saveGate = Completer<void>();
      await tester.tap(find.widgetWithText(SeraButton, '编辑目标计划'));
      await _until(tester, () => store.saves == 1);
      unawaited(harness.router.push<void>('/elsewhere'));
      await _frames(tester);
      expect(find.text('另一个页面'), findsOneWidget);
      expect(harness.router.routerDelegate.state.uri.path, '/elsewhere');
      gate.complete();
      await _frames(tester);
      expect(harness.controller.data.drafts, hasLength(1));
      expect(harness.router.routerDelegate.state.uri.path, '/elsewhere');
      expect(find.text('另一个页面'), findsOneWidget);
      expect(find.text('规划草案页面'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'goal modal actions remain reachable with long content, large text and keyboard',
    (tester) async {
      final store = _ModalStore();
      await _mount(tester, store, '/goal');
      await _openGoal(tester);
      tester.view.physicalSize = const Size(320, 844);
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(tester.view.resetViewInsets);
      await tester.enterText(
        find.byType(TextFormField).at(1),
        List.filled(30, '保留完整的目标验收说明').join('，'),
      );
      await _frames(tester);
      final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
      expect(dialog.scrollable, isTrue);
      final cancel = find.widgetWithText(TextButton, '取消');
      await tester.ensureVisible(cancel);
      expect(tester.getRect(cancel).bottom, lessThanOrEqualTo(564));
      await tester.tap(cancel);
      await _frames(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(store.saves, 0);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('calendar sync failure cannot open results over a newer route', (
    tester,
  ) async {
    final store = _ModalStore();
    final harness = await _mount(tester, store, '/platform');
    final gate = syncGate = Completer<List<Map<String, dynamic>>>();
    final sync = find.widgetWithText(SeraButton, '同步日历');
    await tester.ensureVisible(sync);
    await tester.tap(sync);
    await _until(tester, () => calls.contains('syncCalendarEntries'));
    unawaited(harness.router.push<void>('/elsewhere'));
    await _frames(tester);
    expect(find.text('另一个页面'), findsOneWidget);
    expect(harness.router.routerDelegate.state.uri.path, '/elsewhere');
    gate.complete([
      {'sourceId': 'fixture-event', 'success': false, 'error': '设备拒绝更新'},
    ]);
    await _frames(tester);
    expect(harness.router.routerDelegate.state.uri.path, '/elsewhere');
    expect(find.text('另一个页面'), findsOneWidget);
    expect(find.text('同步结果页面'), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('late platform capabilities stop after their page is removed', (
    tester,
  ) async {
    final gate = capabilitiesGate = Completer<Map<String, dynamic>>();
    final harness = await _mount(tester, _ModalStore(), '/platform');
    expect(calls, contains('capabilities'));
    harness.router.go('/elsewhere');
    await _frames(tester);
    gate.complete(capabilities);
    await _frames(tester);
    expect(calls.where((method) => method == 'listCalendars'), isEmpty);
    expect(find.text('另一个页面'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'preference picker keeps native input mode and cancel preserves values',
    (tester) async {
      final harness = await _mount(tester, _ModalStore(), '/preferences');
      final original = harness.controller.data.preferences.toJson();
      final start = find.text('开始时间');
      await tester.ensureVisible(start);
      await tester.tap(start);
      await _frames(tester);
      expect(
        tester
            .widget<TimePickerDialog>(find.byType(TimePickerDialog))
            .initialEntryMode,
        TimePickerEntryMode.input,
      );
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await _frames(tester);
      expect(harness.controller.data.preferences.toJson(), original);
      expect(find.byType(TimePickerDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
