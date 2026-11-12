import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
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
  String get mode => 'flow-return-context-fixture';
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

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<({SeraController controller, GoRouter router, _Store store})> _mount(
  WidgetTester tester, {
  required String location,
  Workspace workspace = const Workspace(revision: 1),
  DateTime? selectedDate,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final store = _Store(workspace);
  final controller = SeraController(
    repository: store,
    today: DateTime(2026, 11, 8),
    seedDemo: false,
  );
  await controller.initialize();
  if (selectedDate != null) controller.setSelectedDate(selectedDate);
  await tester.pumpWidget(
    SeraApp(controller: controller, initialLocation: location),
  );
  await _frames(tester);
  final router = GoRouter.of(tester.element(find.byType(SeraScaffold).last));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    controller.dispose();
  });
  return (controller: controller, router: router, store: store);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await _frames(tester);
}

Finder _button(String label) => find.widgetWithText(SeraButton, label);

Future<void> _textCapture(WidgetTester tester) async {
  await _tap(tester, find.byKey(const ValueKey('today-capture')));
  if (find.text('文字输入').evaluate().isNotEmpty) {
    await _tap(tester, find.text('文字输入'));
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets(
    'Today capture returns to the same Today and permits the next creation',
    (tester) async {
      final h = await _mount(tester, location: '/04');
      await _textCapture(tester);
      await tester.enterText(find.byType(TextField).first, '周末整理材料');
      await _tap(tester, find.text('手动添加任务'));
      expect(h.router.state.uri.path.split('-').first, '/19');
      expect(h.controller.data.tasks, isEmpty);
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller!
            .text,
        '周末整理材料',
      );
      await _tap(tester, _button('保存任务'));
      expect(h.router.state.uri.path, '/04');
      expect(h.router.canPop(), isFalse);
      expect(find.byType(TextField), findsNothing);
      expect(h.controller.data.tasks.single.title, '周末整理材料');
      expect(h.controller.data.tasks.single.notes, contains('周末整理材料'));

      // This goes through the capture entry's awaited push. Restoring a page without
      // completing its removed push future leaves _opening true and blocks it.
      await _textCapture(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.enterText(find.byType(TextField).first, '明天寄材料');
      await _tap(tester, find.text('手动添加任务'));
      expect(h.router.state.uri.path.split('-').first, '/19');
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller!
            .text,
        '明天寄材料',
      );
      await _tap(tester, _button('保存任务'));
      expect(h.router.state.uri.path, '/04');
      expect(h.router.canPop(), isFalse);
      expect(h.controller.data.tasks.map((task) => task.title), [
        '周末整理材料',
        '明天寄材料',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  for (final location in ['/17?filter=todo&focusTaskId=matching']) {
    testWidgets(
      'adding through an editor link retains its focused list, filter and scroll: $location',
      (tester) async {
        final h = await _mount(
          tester,
          location: location,
          workspace: Workspace(
            revision: 1,
            tasks: [
              for (var i = 0; i < 30; i++)
                SeraTask(id: 'preceding-$i', title: '待完成事项 $i'),
              const SeraTask(id: 'matching', title: '准备材料'),
              const SeraTask(id: 'completed', title: '已处理材料', status: 'done'),
            ],
          ),
        );
        final pageElement = tester.element(find.byType(SeraScaffold));
        final position = Scrollable.of(tester.element(find.text('准备材料')))
            .position;
        final offset = position.pixels;
        expect(offset, greaterThan(0));
        expect(find.text('准备材料').hitTestable(), findsOneWidget);
        expect(find.text('已处理材料'), findsNothing);
        unawaited(h.router.push<void>('/19?mode=todo'));
        await _frames(tester);
        await tester.enterText(find.byType(TextFormField).first, '补交材料');
        await _tap(tester, _button('保存任务'));
        expect(h.router.state.uri.toString(), location);
        expect(h.router.canPop(), isFalse);
        expect(tester.element(find.byType(SeraScaffold)), same(pageElement));
        expect(position.pixels, closeTo(offset, 1));
        // The lazy header is built only when it is in/near the viewport.
        position.jumpTo(0);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilterChip>(find.widgetWithText(FilterChip, '未完成'))
              .selected,
          isTrue,
        );
        position.jumpTo(offset);
        await tester.pumpAndSettle();
        expect(find.text('准备材料'), findsOneWidget);
        expect(find.text('补交材料'), findsOneWidget);
        expect(find.text('已处理材料'), findsNothing);
        expect(h.controller.data.tasks, hasLength(33));
        expect(
          h.controller.data.tasks.where((task) => task.title == '补交材料'),
          hasLength(1),
        );
        expect(h.store.writes, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'adding a calendar event returns to its workweek and selected date',
    (tester) async {
      final day = DateTime(2026, 11, 11);
      final h = await _mount(tester, location: '/13', selectedDate: day);
      await _tap(tester, find.byTooltip('添加日程'));
      await tester.enterText(find.byType(TextFormField).first, '周三讨论');
      await _tap(tester, _button('保存日程'));
      expect(h.router.state.uri.path, '/13');
      expect(h.router.canPop(), isFalse);
      expect(calendarDateString(h.controller.selectedDate), '2026-11-11');
      expect(
        tester
            .widget<SegmentedButton<String>>(
              find.byType(SegmentedButton<String>),
            )
            .selected,
        {'13'},
      );
      expect(h.controller.data.entries.single.title, '周三讨论');
      expect(
        calendarDateString(h.controller.data.entries.single.start),
        '2026-11-11',
      );
      expect(h.store.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('saving outside the original filter offers an optional view', (
    tester,
  ) async {
    final h = await _mount(tester, location: '/17?filter=done');
    unawaited(h.router.push<void>('/19?mode=todo'));
    await _frames(tester);
    await tester.enterText(find.byType(TextFormField).first, '新记录的材料');
    await _tap(tester, _button('保存任务'));
    expect(h.router.state.uri.path, '/17');
    expect(h.router.state.uri.queryParameters['filter'], 'done');
    expect(h.controller.data.tasks.single.title, '新记录的材料');
    expect(find.text('已添加：新记录的材料'), findsOneWidget);
    await _tap(tester, find.widgetWithText(SnackBarAction, '查看'));
    expect(h.router.state.uri.path, '/18');
    expect(find.text('新记录的材料'), findsOneWidget);
    await _tap(tester, find.byTooltip('返回'));
    expect(h.router.state.uri.path, '/17');
    expect(h.router.state.uri.queryParameters['filter'], 'done');
    expect(h.store.writes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'deleting through Search detail and editor skips the removed object and retains the search',
    (tester) async {
      final h = await _mount(
        tester,
        location: '/35',
        workspace: const Workspace(
          revision: 1,
          tasks: [
            SeraTask(id: 'delete-me', title: '材料初稿'),
            SeraTask(id: 'keep-me', title: '材料复核'),
            SeraTask(id: 'other', title: '散步'),
          ],
        ),
      );
      await tester.enterText(find.byType(TextField), '材料');
      await _frames(tester);
      final searchElement = tester.element(find.byType(TextField));
      await _tap(tester, find.text('材料初稿'));
      await _tap(tester, find.widgetWithText(TextButton, '编辑'));
      await _tap(tester, _button('删除这项任务'));
      await _tap(tester, find.widgetWithText(TextButton, '确认删除'));
      expect(h.controller.task('delete-me'), isNull);
      expect(h.controller.task('keep-me'), isNotNull);
      expect(h.router.state.uri.path, '/35');
      expect(h.router.canPop(), isFalse);
      expect(tester.element(find.byType(TextField)), same(searchElement));
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '材料',
      );
      expect(find.text('材料复核'), findsOneWidget);
      expect(find.text('材料初稿'), findsNothing);
      expect(find.text('散步'), findsNothing);
      expect(find.text('这里还没有任务'), findsNothing);
      expect(h.store.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'completing from Todo detail returns to the original list with a usable undo',
    (tester) async {
      final h = await _mount(
        tester,
        location: '/17?filter=todo',
        workspace: const Workspace(
          revision: 1,
          tasks: [
            SeraTask(id: 'finish-me', title: '核对材料'),
            SeraTask(id: 'next', title: '寄出材料'),
          ],
        ),
      );
      await _tap(tester, find.text('核对材料'));
      await _tap(tester, _button('完成'));
      expect(h.controller.task('finish-me')!.done, isTrue);
      expect(h.router.state.uri.path, '/17');
      expect(h.router.canPop(), isFalse);
      expect(find.text('核对材料'), findsNothing);
      expect(find.text('寄出材料'), findsOneWidget);
      await _tap(tester, find.widgetWithText(SnackBarAction, '撤销'));
      expect(h.controller.task('finish-me')!.done, isFalse);
      expect(h.router.state.uri.path, '/17');
      expect(find.text('核对材料'), findsOneWidget);
      expect(find.text('寄出材料'), findsOneWidget);
      expect(h.store.writes, 2);
      expect(tester.takeException(), isNull);
    },
  );

  for (final weekly in [false, true]) {
    testWidgets(
      '${weekly ? 'weekly' : 'daily'} review saves to its origin without building a return loop',
      (tester) async {
        const location = '/04';
        final h = await _mount(tester, location: location);
        for (var attempt = 0; attempt < 2; attempt++) {
          await _tap(tester, find.byTooltip('今日更多'));
          await _tap(tester, find.text(weekly ? '本周回顾' : '今日回顾'));
          expect(
            h.router.state.uri.path.split('-').first,
            weekly ? '/29' : '/28',
          );
          if (attempt > 0) {
            expect(
              tester
                  .widget<TextFormField>(find.byType(TextFormField))
                  .controller!
                  .text,
              '第 ${attempt - 1} 次回顾',
            );
          }
          await tester.enterText(find.byType(TextFormField), '第 $attempt 次回顾');
          await _tap(tester, _button(weekly ? '保存本周回顾' : '保存回顾'));
          expect(h.router.state.uri.path, location);
          expect(h.router.canPop(), isFalse);
          expect(find.byType(TextFormField), findsNothing);
          expect(h.controller.data.reviews, hasLength(1));
          final record = h.controller.data.reviews.single;
          expect(record.kind, weekly ? 'weekly' : 'daily');
          expect(
            (jsonDecode(record.feedback) as Map)['note'],
            '第 $attempt 次回顾',
          );
        }
        expect(h.store.writes, 2);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('My preferences save returns to My and remains usable again', (
    tester,
  ) async {
    final h = await _mount(tester, location: '/30');
    final profileElement = tester.element(find.byType(SeraScaffold));
    for (final budget in [90, 120]) {
      await _tap(tester, find.text('AI 与规划偏好'));
      expect(h.router.state.uri.path.split('-').first, '/31');
      await _tap(tester, find.widgetWithText(ChoiceChip, '$budget 分钟'));
      await _tap(tester, _button('保存偏好'));
      expect(h.controller.data.preferences.dailyBudget, budget);
      expect(h.router.state.uri.path, '/30');
      expect(h.router.canPop(), isFalse);
      expect(tester.element(find.byType(SeraScaffold)), same(profileElement));
    }
    expect(h.store.writes, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Calendar replan returns to the same calendar, undoes, and starts a fresh adjustment',
    (tester) async {
      final start = inTimeZone(
        DateTime(2026, 11, 8, 14),
        'Asia/Hong_Kong',
        wallClock: true,
      );
      final h = await _mount(
        tester,
        location: '/12',
        workspace: Workspace(
          revision: 1,
          preferences: const SeraPreferences(weekdays: [1, 2, 3, 4, 5, 6, 7]),
          tasks: const [SeraTask(id: 'adjust-me', title: '本日材料整理')],
          entries: [
            CalendarEntry(
              id: 'adjust-block',
              taskId: 'adjust-me',
              title: '本日材料整理',
              start: start,
              end: start.add(const Duration(minutes: 30)),
            ),
          ],
        ),
      );
      for (var attempt = 0; attempt < 2; attempt++) {
        await _tap(tester, find.byTooltip('调整安排'));
        expect(h.router.state.uri.path.split('-').first, '/22');
        await _tap(tester, _button('查看变更并确认'));
        expect(h.router.state.uri.path.split('-').first, '/23');
        await _tap(tester, _button('确认调整 1 项任务'));
        expect(h.router.state.uri.path, '/12');
        expect(h.router.canPop(), isFalse);
        expect(h.controller.entry('adjust-block')!.start, isNot(start));
        expect(h.controller.task('adjust-me')!.done, isFalse);
        expect(find.text('本日材料整理'), findsOneWidget);
        await _tap(tester, find.widgetWithText(SnackBarAction, '撤销'));
        expect(h.controller.entry('adjust-block')!.start, start);
        expect(h.router.state.uri.path, '/12');
        expect(h.router.canPop(), isFalse);
      }
      expect(h.store.writes, 4);
      expect(tester.takeException(), isNull);
    },
  );
}
