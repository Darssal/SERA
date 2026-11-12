import 'dart:async';

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
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _Store implements WorkspaceRepository {
  _Store(this.value);
  Workspace? value;
  int writes = 0;
  @override
  String get mode => 'save-completion-test';
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
    writes++;
    return value = Workspace.fromJson(
      next.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }
}

DateTime _at(int day, int hour) => inTimeZone(
  DateTime(2026, 11, day, hour),
  'Asia/Hong_Kong',
  wallClock: true,
);

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<GoRouter> _mount(
  WidgetTester tester,
  SeraController controller, {
  String? initialLocation,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    SeraApp(
      controller: controller,
      initialLocation: initialLocation ?? '/17?filter=todo',
    ),
  );
  await _frames(tester);
  final router = GoRouter.of(tester.element(find.byType(SeraScaffold).last));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    controller.dispose();
  });
  return router;
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await _frames(tester);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets(
    'event deletion returns to Plans and clears feedback before the next form',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final store = _Store(
        Workspace(
          revision: 1,
          entries: [
            CalendarEntry(
              id: 'remove-me',
              title: '取消的会议',
              start: _at(3, 14),
              end: _at(3, 15),
            ),
          ],
        ),
      );
      final controller = SeraController(
        repository: store,
        today: DateTime(2026, 10, 31),
      );
      await controller.initialize();
      final router = await _mount(tester, controller);
      unawaited(router.push('/16?eventId=remove-me'));
      await _frames(tester);
      await _tap(tester, find.widgetWithText(SeraButton, '删除日程'));
      await _tap(tester, find.widgetWithText(TextButton, '确认删除'));
      expect(controller.data.entries, isEmpty);
      expect(router.state.uri.path, '/17');
      expect(router.canPop(), isFalse);
      expect(find.byType(SnackBar), findsNothing);
      unawaited(router.push<void>('/19?mode=todo'));
      await _frames(tester);
      expect(find.byType(SnackBar), findsNothing);
      await tester.enterText(find.byType(TextFormField).first, '接着记录的待办');
      await _frames(tester);
      await _tap(tester, find.widgetWithText(SeraButton, '保存任务'));
      expect(controller.data.tasks.single.title, '接着记录的待办');
      expect(router.state.uri.path, '/17');
      expect(router.canPop(), isFalse);
      expect(find.text('已添加：接着记录的待办'), findsOneWidget);
      expect(store.writes, 2);
      expect(tester.takeException(), isNull);
    },
  );

  for (final kind in ['task', 'event']) {
    for (final fromAi in [false, true]) {
      testWidgets(
        '${fromAi ? 'AI' : 'manual'} new $kind returns to Plans and leaves the saved object reachable once',
        (tester) async {
          final title =
              '${fromAi ? '核对' : '手动'}${kind == 'task' ? '材料' : '会议'}';
          final session = PlanningSession(
            id: 'source-$kind',
            prompt: '下周二下午两点$title',
            updatedAt: _at(1, 9),
            stage: 'understood',
            understanding: AiUnderstanding(
              intent: kind,
              title: title,
              summary: '',
              outcome: '',
              model: 'fixture',
              start: kind == 'event' ? _at(3, 14) : null,
              end: kind == 'event' ? _at(3, 15) : null,
            ).toJson(),
          );
          final store = _Store(
            Workspace(revision: 1, planningSessions: fromAi ? [session] : []),
          );
          final controller = SeraController(
            repository: store,
            today: DateTime(2026, 10, 31),
          );
          await controller.initialize();
          final router = await _mount(tester, controller);
          if (fromAi) {
            unawaited(router.push('/05?sessionId=${session.id}'));
            await _frames(tester);
          }
          unawaited(
            router.push(
              '/${kind == 'task' ? '19' : '16'}${fromAi ? '?sessionId=${session.id}' : ''}',
            ),
          );
          await _frames(tester);
          if (!fromAi) {
            await tester.enterText(find.byType(TextFormField).first, title);
          }
          await _tap(
            tester,
            find.widgetWithText(SeraButton, kind == 'task' ? '保存任务' : '保存日程'),
          );
          final savedId = kind == 'task'
              ? controller.data.tasks.single.id
              : controller.data.entries.single.id;
          expect(store.writes, 1);
          expect(router.state.uri.path, '/17');
          expect(router.canPop(), isFalse);
          expect(find.byType(TextFormField), findsNothing);
          expect(find.text('已完成的输入'), findsNothing);
          expect(find.text('查看已保存事项'), findsNothing);
          if (kind == 'event') {
            final saved = controller.entry(savedId)!;
            // Saving from Plans must not move the user's separate calendar
            // selection just to reveal a future object.
            expect(controller.selectedDate, controller.today);
            expect(find.text(title), findsNothing);
            router.go('/12');
            await _frames(tester);
            if (fromAi) {
              expect(calendarDateString(saved.start), '2026-11-03');
              for (var next = 0; next < 3; next++) {
                await _tap(tester, find.byTooltip('后一天'));
              }
            }
          }
          expect(find.text(title), findsOneWidget);
          if (fromAi) {
            final savedSession = controller.planningSession(session.id)!;
            expect(savedSession.stage, 'confirmed');
            expect(savedSession.resultEntity!.kind, kind);
            expect(savedSession.resultEntity!.id, savedId);
          }
          final returnLocation = kind == 'task' ? '/17' : '/12';
          // A detail is opened only when the user chooses the saved item.
          await _tap(tester, find.text(title));
          expect(
            router.state.uri.path.split('-').first,
            kind == 'task' ? '/18' : '/15',
          );
          expect(
            router.state.uri.queryParameters[kind == 'task'
                ? 'taskId'
                : 'eventId'],
            savedId,
          );
          await _tap(tester, find.byTooltip('返回'));
          expect(router.state.uri.path, returnLocation);
          expect(router.canPop(), isFalse);
          expect(find.byType(TextFormField), findsNothing);
          expect(store.writes, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final day in [31, 3]) {
    testWidgets(
      'scheduled new task returns to Plans and stays reachable for ${day == 31 ? 'today' : 'a future date'}',
      (tester) async {
        final store = _Store(const Workspace(revision: 1));
        final controller = SeraController(
          repository: store,
          today: DateTime(2026, 10, 31),
        );
        await controller.initialize();
        final router = await _mount(tester, controller);
        final start = day == 31
            ? DateTime(2026, 10, 31, 14)
            : DateTime(2026, 11, 3, 14);
        unawaited(
          router.push(
            Uri(
              path: '/19',
              queryParameters: {
                'title': '需要安排的任务',
                'start': start.toIso8601String(),
                'end': start.add(const Duration(minutes: 30)).toIso8601String(),
              },
            ).toString(),
          ),
        );
        await _frames(tester);
        await _tap(tester, find.widgetWithText(SeraButton, '保存任务'));
        expect(router.state.uri.path, '/17');
        expect(router.canPop(), isFalse);
        final task = controller.data.tasks.single;
        final savedEntry = controller.entryForTask(task.id)!;
        expect(savedEntry.start.hour, 14);
        expect(
          calendarDateString(savedEntry.start),
          day == 31 ? '2026-10-31' : '2026-11-03',
        );
        expect(find.text('需要安排的任务'), findsOneWidget);
        router.go('/17?filter=today');
        await _frames(tester);
        expect(find.text('需要安排的任务'), day == 31 ? findsOneWidget : findsNothing);
        await _tap(tester, find.widgetWithText(FilterChip, '未完成'));
        expect(router.state.uri.path, '/17');
        expect(
          tester
              .widget<FilterChip>(find.widgetWithText(FilterChip, '未完成'))
              .selected,
          isTrue,
        );
        expect(find.text('需要安排的任务'), findsOneWidget);
        expect(store.writes, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'checking a task complete returns directly to Plans without a return loop',
    (tester) async {
      const task = SeraTask(id: 'finished-task', title: '完成的材料检查');
      final store = _Store(const Workspace(revision: 1, tasks: [task]));
      final controller = SeraController(
        repository: store,
        today: DateTime(2026, 10, 31),
      );
      await controller.initialize();
      final router = await _mount(tester, controller);
      unawaited(router.push('/18?taskId=${task.id}'));
      await _frames(tester);
      await _tap(tester, find.widgetWithText(SeraButton, '完成'));
      expect(router.state.uri.path, '/17');
      expect(router.canPop(), isFalse);
      expect(find.widgetWithText(AppBar, '任务详情'), findsNothing);
      expect(find.widgetWithText(SnackBarAction, '撤销'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await _frames(tester);
      expect(router.state.uri.path, '/17');
      expect(controller.task(task.id)!.done, isTrue);
      expect(find.text('设为未完成'), findsNothing);
      expect(store.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a saved late event is immediately reachable and does not force later scrolling',
    (tester) async {
      final store = _Store(
        Workspace(
          revision: 1,
          entries: List.generate(
            12,
            (index) => CalendarEntry(
              id: 'earlier-$index',
              title: '较早的安排 $index',
              start: _at(3, 8).add(Duration(minutes: index * 30)),
              end: _at(3, 8).add(Duration(minutes: index * 30 + 20)),
            ),
          ),
        ),
      );
      final controller = SeraController(
        repository: store,
        today: DateTime(2026, 10, 31),
      );
      await controller.initialize();
      // A cold editor link has no business origin to resume, so the list
      // fallback must still reveal a late saved event rather than lose it.
      final router = await _mount(
        tester,
        controller,
        initialLocation: Uri(
          path: '/16',
          queryParameters: {
            'title': '晚上九点的会议',
            'start': _at(3, 21).toUtc().toIso8601String(),
            'end': _at(3, 22).toUtc().toIso8601String(),
          },
        ).toString(),
      );
      await _tap(tester, find.widgetWithText(SeraButton, '保存日程'));
      final saved = controller.data.entries.singleWhere(
        (entry) => entry.title == '晚上九点的会议',
      );
      expect(router.state.uri.path, '/12');
      expect(router.state.uri.queryParameters['focusEntryId'], saved.id);
      expect(calendarDateString(controller.selectedDate), '2026-11-03');
      final item = find.byKey(ValueKey('calendar-event:${saved.id}:1260'));
      expect(item.hitTestable(), findsOneWidget);
      expect(find.text(saved.title).hitTestable(), findsOneWidget);
      await tester.tap(item);
      await _frames(tester);
      await _tap(tester, find.byTooltip('返回'));
      expect(item.hitTestable(), findsOneWidget);
      final scroll = tester
          .state<ScrollableState>(
            find
                .byWidgetPredicate(
                  (widget) =>
                      widget is Scrollable &&
                      widget.axisDirection == AxisDirection.down,
                )
                .first,
          )
          .position;
      scroll.jumpTo(0);
      await _frames(tester);
      expect(item.hitTestable(), findsNothing);
      unawaited(router.push('/15?eventId=${saved.id}'));
      await _frames(tester);
      router.pop();
      await _frames(tester);
      expect(scroll.pixels, 0);
      expect(item.hitTestable(), findsNothing);
      expect(store.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a new task after many inbox rows is revealed once without reordering',
    (tester) async {
      final existing = List.generate(
        35,
        (index) => SeraTask(id: 'existing-$index', title: '已有材料 $index'),
      );
      final store = _Store(Workspace(revision: 1, tasks: existing));
      final controller = SeraController(
        repository: store,
        today: DateTime(2026, 10, 31),
      );
      await controller.initialize();
      // With no valid business origin, a cold task form uses its existing
      // inbox fallback and keeps the newly saved row accessible.
      final router = await _mount(tester, controller, initialLocation: '/19');
      await tester.enterText(find.byType(TextFormField).first, '刚记录的任务');
      await _tap(tester, find.widgetWithText(SeraButton, '保存任务'));
      final saved = controller.data.tasks.last;
      expect(router.state.uri.path, '/17');
      expect(router.state.uri.queryParameters['filter'], 'inbox');
      expect(router.state.uri.queryParameters['focusTaskId'], saved.id);
      final item = find.text('刚记录的任务');
      expect(item.hitTestable(), findsOneWidget);
      expect(
        controller.data.tasks.take(existing.length).map((task) => task.id),
        existing.map((task) => task.id),
      );
      await tester.tap(item);
      await _frames(tester);
      await _tap(tester, find.byTooltip('返回'));
      expect(item.hitTestable(), findsOneWidget);
      final scroll = tester
          .state<ScrollableState>(
            find
                .byWidgetPredicate(
                  (widget) =>
                      widget is Scrollable &&
                      widget.axisDirection == AxisDirection.down,
                )
                .first,
          )
          .position;
      scroll.jumpTo(0);
      await _frames(tester);
      expect(item.hitTestable(), findsNothing);
      unawaited(router.push('/18?taskId=${saved.id}'));
      await _frames(tester);
      router.pop();
      await _frames(tester);
      expect(scroll.pixels, 0);
      expect(item.hitTestable(), findsNothing);
      expect(store.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
