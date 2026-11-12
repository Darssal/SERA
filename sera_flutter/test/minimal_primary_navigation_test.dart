import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sera_flutter/ui/core/sera_plan_switcher.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';

Future<GoRouter> _mount(WidgetTester tester, String initialLocation) async {
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/:screen',
        builder: (context, state) {
          final screen = state.pathParameters['screen'];
          final navIndex = const {'04': 0, '17': 1, '12': 2, '20': 1}[screen];
          return SeraScaffold(
            title: screen == '30' ? '账户设置内容' : '主页面内容',
            navIndex: navIndex,
            showBack: navIndex == null,
            body: Column(
              children: [
                if (screen == '17' || screen == '20')
                  SeraPlanSwitcher(goals: screen == '20'),
                Text('内容 $screen'),
              ],
            ),
          );
        },
      ),
    ],
  );
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
  });
  return router;
}

void main() {
  testWidgets('plan sections remain readable at 320px and share the plan tab', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 844);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final router = await _mount(tester, '/17?filter=done');
    expect(find.text('任务').hitTestable(), findsOneWidget);
    expect(find.text('目标').hitTestable(), findsOneWidget);
    expect(
      tester.widget<SeraPlanSwitcher>(find.byType(SeraPlanSwitcher)).goals,
      isFalse,
    );
    expect(tester.widget<SeraScaffold>(find.byType(SeraScaffold)).navIndex, 1);
    // Re-selecting the current section does not erase an old task filter.
    await tester.tap(find.text('任务'));
    await tester.pumpAndSettle();
    expect(
      router.routeInformationProvider.value.uri.toString(),
      '/17?filter=done',
    );
    await tester.tap(find.text('目标'));
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/20');
    expect(
      tester.widget<SeraPlanSwitcher>(find.byType(SeraPlanSwitcher)).goals,
      isTrue,
    );
    expect(tester.widget<SeraScaffold>(find.byType(SeraScaffold)).navIndex, 1);
    expect(router.canPop(), isFalse);
    // Selecting the already active primary tab retains its goal section.
    await tester.tap(find.text('计划'));
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/20');
    await tester.tap(find.text('任务'));
    await tester.pumpAndSettle();
    expect(
      router.routeInformationProvider.value.uri.toString(),
      '/17?filter=todo',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'primary tabs have stable destinations and only Today owns the account entry',
    (tester) async {
      final router = await _mount(tester, '/04');
      expect(find.text('我的'), findsNothing);
      expect(find.text('今日'), findsOneWidget);
      for (final destination in const [
        ('日程', '/12'),
        ('计划', '/17?filter=todo'),
        ('今日', '/04'),
      ]) {
        await tester.tap(find.text(destination.$1));
        await tester.pumpAndSettle();
        expect(
          router.routeInformationProvider.value.uri.toString(),
          destination.$2,
        );
        expect(router.canPop(), isFalse);
        expect(find.byTooltip('返回'), findsNothing);
        expect(
          find.byTooltip('账户与设置'),
          destination.$2 == '/04' ? findsOneWidget : findsNothing,
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  for (final location in ['/04', '/17?filter=todo', '/12', '/20']) {
    testWidgets(
      'account settings stays reachable through Today from $location',
      (tester) async {
        final router = await _mount(tester, location);
        if (location != '/04') {
          expect(find.byTooltip('账户与设置'), findsNothing);
          await tester.tap(find.text('今日'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byTooltip('账户与设置'));
        await tester.pumpAndSettle();
        // A pushed page has its own route state. The harness does not enable
        // GoRouter's optional imperative browser-URL mirroring used by SeraApp.
        expect(
          GoRouterState.of(tester.element(find.byType(SeraScaffold))).uri.path,
          '/30',
        );
        expect(find.text('内容 30'), findsOneWidget);
        expect(find.byTooltip('账户与设置'), findsNothing);
        expect(find.text('今日'), findsNothing);
        expect(find.text('任务'), findsNothing);
        expect(router.canPop(), isTrue);
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        expect(router.routeInformationProvider.value.uri.path, '/04');
        expect(find.byTooltip('账户与设置'), findsOneWidget);
        expect(router.canPop(), isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'legacy task links retain their filter until another tab is chosen',
    (tester) async {
      final router = await _mount(tester, '/17?filter=done');
      await tester.tap(find.text('计划'));
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.toString(),
        '/17?filter=done',
      );
      await tester.tap(find.text('日程'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('计划'));
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.toString(),
        '/17?filter=todo',
      );
      expect(router.canPop(), isFalse);
    },
  );

  testWidgets('an account deep link can return to today without a parent', (
    tester,
  ) async {
    final router = await _mount(tester, '/30');
    expect(router.canPop(), isFalse);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/04');
    expect(find.byTooltip('账户与设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
