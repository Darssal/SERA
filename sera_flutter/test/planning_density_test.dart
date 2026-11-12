import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _DensityRepository implements WorkspaceRepository {
  Workspace? value = const Workspace(revision: 1);

  @override
  String get mode => 'density-test';

  @override
  Future<Workspace?> load() async => value;

  @override
  Future<void> clear() async => value = null;

  @override
  Future<Workspace> save(
    Workspace workspace, {
    required int expectedRevision,
  }) async {
    if (value?.revision != expectedRevision) {
      throw const RepositoryException('工作区已有后续修改', conflict: true);
    }
    value = workspace.copyWith(revision: expectedRevision + 1);
    return value!;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  for (final screen in ['08', '10']) {
    testWidgets(
      '$screen keeps reviewed content and primary actions visible without explanatory panels',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final today = DateTime(2026, 10, 28);
        final controller = SeraController(
          repository: _DensityRepository(),
          today: today,
        );
        await controller.initialize();
        final draft = await controller.generatePlan(
          title: '准备课程项目展示',
          deadline: today.add(const Duration(days: 14)),
          dailyBudget: 90,
        );
        final savedDraft = draft.toJson();
        await tester.pumpWidget(
          SeraApp(
            controller: controller,
            initialLocation: '/$screen?draftId=${draft.id}',
          ),
        );
        await tester.pumpAndSettle();

        final firstTask = find.textContaining('梳理目标与方案框架');
        final content = firstTask;
        expect(content, findsOneWidget);
        final viewport = tester.getRect(
          find.byType(SingleChildScrollView).first,
        );
        final contentRect = tester.getRect(content);
        expect(contentRect.top, greaterThanOrEqualTo(viewport.top));
        expect(contentRect.bottom, lessThanOrEqualTo(viewport.bottom));
        expect(find.text('规划依据'), findsNothing);
        expect(find.text('规划来源'), findsNothing);
        expect(find.text(draft.items.first.task.title), findsNothing);
        expect(find.text(draft.goal.title), findsOneWidget);
        expect(find.text('第一步，从这里开始'), findsNothing);
        expect(
          find.textContaining('创建 1 个目标、${draft.items.length} 项任务'),
          findsOneWidget,
        );
        await tester.ensureVisible(
          find.widgetWithText(SeraButton, '确认创建 6 项任务与安排'),
        );
        expect(controller.draft(draft.id)!.toJson(), savedDraft);
        expect(controller.data.tasks, isEmpty);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      },
    );
  }
  for (final budget in [15, 300, 480]) {
    testWidgets(
      'onboarding preserves restored budget $budget and real rest times at320px',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 568);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final preferences = SeraPreferences(
          dailyBudget: budget,
          bufferMinutes: 0,
          restStart: 750,
          restEnd: 825,
        );
        final store = _DensityRepository()
          ..value = Workspace(revision: 1, preferences: preferences);
        final controller = SeraController(
          repository: store,
          today: DateTime(2026, 10, 31),
        );
        await controller.initialize();
        await tester.pumpWidget(
          SeraApp(controller: controller, initialLocation: '/02'),
        );
        await tester.pumpAndSettle();
        final slider = tester.widget<Slider>(find.byType(Slider));
        expect(slider.value, budget.toDouble());
        expect(slider.min, lessThanOrEqualTo(budget));
        expect(slider.max, greaterThanOrEqualTo(budget));
        expect(find.text('12:30–13:45'), findsOneWidget);
        expect(
          tester
              .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '0 分钟'))
              .selected,
          isTrue,
        );
        final day = find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.label == '周一',
        );
        await tester.ensureVisible(day);
        expect(tester.getSize(day).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(day).height, greaterThanOrEqualTo(48));
        final wasSelected = tester.widget<Semantics>(day).properties.selected;
        await tester.tap(day);
        await tester.pumpAndSettle();
        expect(
          tester.widget<Semantics>(day).properties.selected,
          !wasSelected!,
        );
        expect(controller.data.preferences.toJson(), preferences.toJson());
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      },
    );
  }
}
