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

class _Store implements WorkspaceRepository {
  _Store({SeraPreferences? preferences})
    : value = createSeedWorkspace(_today)
          .copyWith(revision: 1, preferences: preferences);
  Workspace value;
  int saves = 0;

  @override
  String get mode => 'preferences-platform-polish-fixture';
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
        GoRoute(path: '/30', builder: (_, _) => const ProfileScreen()),
        GoRoute(
          path: '/preferences',
          builder: (_, _) => const PreferencesScreen(),
        ),
        GoRoute(
          path: '/notifications',
          builder: (_, _) => const PlatformSettingsScreen(mode: '33'),
        ),
        GoRoute(
          path: '/sync',
          builder: (_, _) => const PlatformSettingsScreen(mode: '42'),
        ),
        GoRoute(
          path: '/elsewhere',
          builder: (_, _) => const Scaffold(body: Text('另一个页面')),
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

Future<void> _frames(WidgetTester tester, [int count = 8]) async {
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
    reason: 'Expected fixture result within bounded frames',
  );
}

Future<_Harness> _mount(
  WidgetTester tester,
  _Store store,
  String location,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 640);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = SeraController(repository: store, today: _today);
  await controller.initialize();
  final harness = _Harness(controller, location);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    harness.router.dispose();
    controller.dispose();
  });
  await tester.pumpWidget(harness.widget);
  await _frames(tester);
  return harness;
}

Finder _choice(String label) => find.descendant(
  of: find.byKey(const ValueKey('preferences-budget-options')),
  matching: find.widgetWithText(ChoiceChip, label),
);
Finder _bufferChoice(String label) => find.descendant(
  of: find.byKey(const ValueKey('preferences-buffer-options')),
  matching: find.widgetWithText(ChoiceChip, label),
);
Finder _saveNotifications() => find.widgetWithText(SeraButton, '保存设置');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String>[];
  Completer<String>? permissionGate;
  const capabilities = {
    'platform': 'android',
    'calendarSupported': false,
    'notificationsSupported': true,
    'backgroundNotifications': false,
    'recordingSupported': false,
    'calendarPermission': 'denied',
    'notificationPermission': 'denied',
    'microphonePermission': 'denied',
    'exactAlarmsSupported': true,
  };
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    calls.clear();
    permissionGate = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'capabilities':
              return capabilities;
            case 'scheduledNotifications':
              return <Map<String, dynamic>>[];
            case 'requestPermission':
              expect((call.arguments as Map)['kind'], 'notifications');
              return permissionGate == null
                  ? 'denied'
                  : await permissionGate!.future;
            case 'cancelNotifications':
              return null;
            default:
              throw PlatformException(
                code: 'unexpected_fixture_call',
                message: call.method,
              );
          }
        });
  });
  tearDown(() {
    if (permissionGate?.isCompleted == false) {
      permissionGate!.complete('denied');
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  for (final values in [(240, 5), (480, 120)]) {
    testWidgets(
      'preferences retain and select current ${values.$1}/${values.$2} values',
      (tester) async {
        final initial = SeraPreferences(
          dailyBudget: values.$1,
          bufferMinutes: values.$2,
        );
        final store = _Store(preferences: initial);
        final harness = await _mount(tester, store, '/preferences');
        final budgetLabel = '${values.$1} 分钟';
        final bufferLabel = '${values.$2} 分钟';
        expect(
          tester.widget<ChoiceChip>(_choice(budgetLabel)).selected,
          isTrue,
        );
        expect(
          tester.widget<ChoiceChip>(_bufferChoice(bufferLabel)).selected,
          isTrue,
        );
        expect(store.saves, 0);
        // Editing a preset must not make the saved non-preset choice disappear.
        await tester.ensureVisible(_choice('90 分钟'));
        await tester.tap(_choice('90 分钟'));
        await _frames(tester, 2);
        expect(_choice(budgetLabel), findsOneWidget);
        expect(
          tester.widget<ChoiceChip>(_choice(budgetLabel)).selected,
          isFalse,
        );
        await tester.ensureVisible(_choice(budgetLabel));
        await tester.tap(_choice(budgetLabel));
        await _frames(tester, 2);
        expect(
          tester.widget<ChoiceChip>(_choice(budgetLabel)).selected,
          isTrue,
        );
        // Budget options wrap on this 320px viewport; rows retain a visible gap.
        final labels = [30, 60, 90, 120, 180, values.$1]..sort();
        var rowBreaks = 0;
        for (var i = 1; i < labels.length; i++) {
          final previous = tester.getRect(_choice('${labels[i - 1]} 分钟'));
          final next = tester.getRect(_choice('${labels[i]} 分钟'));
          if (next.top > previous.top) {
            rowBreaks++;
            expect(next.top - previous.bottom, greaterThanOrEqualTo(6));
          }
        }
        expect(rowBreaks, greaterThan(0));
        await tester.tap(find.widgetWithText(SeraButton, '保存偏好'));
        await _until(tester, () => store.saves == 1);
        await _frames(tester);
        expect(store.value.preferences.dailyBudget, values.$1);
        expect(store.value.preferences.bufferMinutes, values.$2);
        expect(harness.router.state.uri.path, '/30');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'calendar without a sync run shows its empty state without zero statistics',
    (tester) async {
      await _mount(tester, _Store(), '/sync');
      expect(find.text('尚无同步记录'), findsOneWidget);
      expect(find.text('最近一次同步'), findsNothing);
      expect(find.text('已读取的日程'), findsNothing);
      expect(find.widgetWithText(SeraField, '同步结果'), findsNothing);
      expect(calls, isNot(contains('requestPermission')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'notification details keep one permission entry and show cross-midnight time',
    (tester) async {
      await _mount(tester, _Store(), '/notifications');
      expect(find.text('开启通知权限'), findsOneWidget);
      expect(find.text('次日08:00'), findsOneWidget);
      final details = find.text('提醒状态与测试');
      await tester.ensureVisible(details);
      await tester.tap(details);
      await _frames(tester);
      expect(find.text('开启或重新请求通知权限'), findsNothing);
      expect(find.text('已安排的提醒'), findsOneWidget);
      expect(find.textContaining('条已安排'), findsNothing);
      expect(calls, isNot(contains('requestPermission')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'notification save merges only notification fields into refreshed preferences',
    (tester) async {
      final store = _Store();
      final original = store.value.preferences;
      final harness = await _mount(tester, store, '/notifications');
      await tester.tap(find.widgetWithText(SwitchListTile, '启用任务提醒'));
      await _frames(tester, 2);
      await tester.tap(find.widgetWithText(SwitchListTile, '未开始时再提醒'));
      await _frames(tester, 2);
      // A background refresh changes the planning settings while this page keeps
      // its in-progress notification edits. No remote service is used.
      final remote = original.copyWith(
        dailyBudget: 240,
        bufferMinutes: 5,
        weekdays: [2, 4],
        startMinute: 540,
        endMinute: 1080,
        restStart: 780,
        restEnd: 840,
        timeZone: 'Asia/Tokyo',
        useAiContext: true,
        quietStart: 1200,
        quietEnd: 420,
      );
      store.value = store.value.copyWith(
        revision: store.value.revision + 1,
        preferences: remote,
      );
      await harness.controller.refresh();
      await _frames(tester);
      await tester.tap(_saveNotifications());
      await _until(tester, () => calls.contains('cancelNotifications'));
      await _frames(tester);
      expect(store.saves, 1);
      expect(
        store.value.preferences.toJson(),
        remote
            .copyWith(
              notifications: false,
              followUp: false,
              quietStart: original.quietStart,
              quietEnd: original.quietEnd,
            )
            .toJson(),
      );
      expect(calls.where((call) => call == 'requestPermission'), isEmpty);
      expect(find.text('操作结果'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'save failure scrolls its single live status into the current viewport',
    (tester) async {
      final store = _Store();
      await _mount(tester, store, '/notifications');
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -1600),
      );
      await _frames(tester);
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(scrollable.position.pixels, greaterThan(0));
      await tester.tap(_saveNotifications());
      final error = find.text('偏好已保存；请开启通知权限后重试。');
      await _until(tester, () => error.evaluate().isNotEmpty);
      await _frames(tester);
      expect(store.saves, 1);
      expect(find.text('这次操作没有完成'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      final rect = tester.getRect(error);
      expect(rect.top, greaterThanOrEqualTo(kToolbarHeight));
      expect(rect.bottom, lessThan(tester.getTopLeft(_saveNotifications()).dy));
      expect(
        find.ancestor(
          of: error,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics && widget.properties.liveRegion == true,
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late operation failure does not expose a banner over another current route',
    (tester) async {
      final harness = await _mount(tester, _Store(), '/notifications');
      final gate = permissionGate = Completer<String>();
      await tester.tap(_saveNotifications());
      await _until(tester, () => calls.contains('requestPermission'));
      unawaited(harness.router.push<void>('/elsewhere'));
      await _frames(tester);
      gate.complete('denied');
      await _frames(tester);
      expect(harness.router.routerDelegate.state.uri.path, '/elsewhere');
      expect(find.text('另一个页面'), findsOneWidget);
      expect(find.text('这次操作没有完成'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
