import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/sera_todo_row.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = readZoned('2026-11-09T09:00:00+08:00', 'Asia/Hong_Kong')!;
const _taskId = 'inline-task';
const _goalId = 'inline-goal';
const _title = '准备评审材料';
const _firstCheck = '收集资料';
const _secondCheck = '核对数字';
const _surfaces = <String, String>{
  'today': '/04',
  'plan': '/17?filter=todo',
  'goal': '/21?goalId=$_goalId',
};

class _Store implements WorkspaceRepository {
  _Store(this.value);

  Workspace value;
  int attempts = 0;
  int writes = 0;
  bool failNextSave = false;
  Completer<void>? saveGate;

  @override
  String get mode => 'inline-checklist-fixture';

  @override
  Future<Workspace?> load() async => value;

  @override
  Future<void> clear() async => value = const Workspace();

  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    attempts++;
    if (saveGate case final gate?) await gate.future;
    if (failNextSave) {
      failNextSave = false;
      throw const RepositoryException('保存失败，请重试');
    }
    if (value.revision != expectedRevision) {
      throw const RepositoryException('版本冲突', conflict: true);
    }
    writes++;
    return value = Workspace.fromJson(
      next.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }
}

Workspace _workspace({
  bool scheduled = false,
  List<String> checklist = const [_firstCheck, _secondCheck],
}) => Workspace(
  revision: 1,
  tasks: [
    SeraTask(
      id: _taskId,
      title: _title,
      goalId: _goalId,
      status: 'in_progress',
      dueAt: atMinute(_now, 18 * 60),
      checklist: checklist,
    ),
  ],
  goals: [
    SeraGoal(
      id: _goalId,
      title: '完成评审准备',
      deadline: calendarDay(_now, 7),
      taskIds: const [_taskId],
    ),
  ],
  entries: scheduled
      ? [
          CalendarEntry(
            id: 'inline-arrangement',
            taskId: _taskId,
            title: _title,
            start: atMinute(_now, 14 * 60),
            end: atMinute(_now, 14 * 60 + 30),
          ),
        ]
      : const [],
);

SeraController _controller(_Store store) => SeraController(
  repository: store,
  today: _now,
  accountId: 'inline-checklist-account',
  seedDemo: false,
);

class _Harness {
  _Harness(this.store, this.controller);
  final _Store store;
  SeraController controller;

  Future<void> reload(WidgetTester tester, String path) async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    controller = _controller(store);
    await controller.initialize();
    await tester.pumpWidget(
      SeraApp(key: UniqueKey(), controller: controller, initialLocation: path),
    );
    await tester.pumpAndSettle();
  }
}

Future<_Harness> _mount(
  WidgetTester tester,
  String path, {
  Workspace? workspace,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final store = _Store(workspace ?? _workspace());
  final c = _controller(store);
  await c.initialize();
  final harness = _Harness(store, c);
  await tester.pumpWidget(SeraApp(controller: c, initialLocation: path));
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    harness.controller.dispose();
  });
  return harness;
}

Finder _row() => find.byWidgetPredicate(
  (widget) => widget is SeraTodoRow && widget.task.id == _taskId,
);

Finder _rowTooltip(String tooltip) =>
    find.descendant(of: _row(), matching: find.byTooltip(tooltip));

Finder _check(String check) =>
    find.byKey(ValueKey('todo-check:$_taskId:$check'));

Finder _parentCheckbox() => find.descendant(
  of: _row(),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is Checkbox && widget.semanticLabel?.endsWith(_title) == true,
  ),
);

GoRouter _router(WidgetTester tester) =>
    GoRouter.of(tester.element(find.byType(SeraScaffold).first));

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _expand(WidgetTester tester) async {
  if (_rowTooltip('展开子项').evaluate().isNotEmpty) {
    await _tap(tester, _rowTooltip('展开子项'));
  }
}

void _expectChecks(
  WidgetTester tester, {
  required bool first,
  required bool second,
}) {
  expect(tester.widget<CheckboxListTile>(_check(_firstCheck)).value, first);
  expect(tester.widget<CheckboxListTile>(_check(_secondCheck)).value, second);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final surface in _surfaces.entries) {
    testWidgets(
      '${surface.key} expands without writing and saves subitems without completing the task',
      (tester) async {
        final h = await _mount(tester, surface.value);
        final router = _router(tester);
        final location = router.routeInformationProvider.value.uri;
        expect(_row(), findsOneWidget);
        expect(
          find.byKey(const ValueKey('todo-checklist:$_taskId')),
          findsNothing,
        );

        await _expand(tester);
        _expectChecks(tester, first: false, second: false);
        expect(router.routeInformationProvider.value.uri, location);
        expect(h.store.attempts, 0);
        expect(h.controller.data.history, isEmpty);

        await _tap(tester, _check(_firstCheck));
        expect(h.controller.task(_taskId)!.completedChecks, [_firstCheck]);
        expect(h.store.value.tasks.single.completedChecks, [_firstCheck]);
        expect(h.store.writes, 1);
        expect(
          find.descendant(of: _row(), matching: find.textContaining('1/2 项')),
          findsOneWidget,
        );
        _expectChecks(tester, first: true, second: false);

        await _tap(tester, _rowTooltip('收起子项'));
        expect(_check(_firstCheck), findsNothing);
        await _expand(tester);
        _expectChecks(tester, first: true, second: false);
        expect(h.store.attempts, 1);

        await _tap(tester, _check(_secondCheck));
        _expectChecks(tester, first: true, second: true);
        expect(
          find.descendant(of: _row(), matching: find.textContaining('2/2 项')),
          findsOneWidget,
        );
        expect(h.store.value.tasks.single.completedChecks, [
          _firstCheck,
          _secondCheck,
        ]);
        expect(h.controller.task(_taskId)!.status, 'in_progress');
        expect(h.store.value.tasks.single.done, isFalse);
        expect(h.controller.goal(_goalId)!.status, 'active');
        expect(
          h.controller.data.history.where((item) => item.label == '完成任务'),
          isEmpty,
        );
        expect(h.store.writes, 2);
        expect(router.routeInformationProvider.value.uri, location);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${surface.key} parent completion and undo preserve checked subitems and scheduled work',
      (tester) async {
        final h = await _mount(
          tester,
          surface.value,
          workspace: _workspace(scheduled: true),
        );
        final originalEntry = h.controller.data.entries.single.toJson();
        final location = _router(tester).routeInformationProvider.value.uri;
        await _expand(tester);
        await _tap(tester, _check(_firstCheck));
        await _tap(tester, _parentCheckbox());

        expect(h.controller.task(_taskId)!.done, isTrue);
        expect(h.store.value.tasks.single.completedChecks, [_firstCheck]);
        expect(h.controller.data.entries, isEmpty);
        expect(h.store.writes, 2);

        if (surface.key == 'plan') {
          expect(_row(), findsNothing);
          await _tap(tester, find.widgetWithText(FilterChip, '已完成'));
        }
        if (surface.key != 'today') {
          await _expand(tester);
          _expectChecks(tester, first: true, second: false);
          expect(
            tester.widget<CheckboxListTile>(_check(_firstCheck)).onChanged,
            isNull,
          );
          expect(
            tester.widget<CheckboxListTile>(_check(_secondCheck)).onChanged,
            isNull,
          );
          await _tap(tester, _check(_secondCheck));
          expect(h.store.attempts, 2);
          expect(h.controller.task(_taskId)!.completedChecks, [_firstCheck]);
        } else {
          expect(_row(), findsNothing);
        }

        await _tap(tester, find.widgetWithText(TextButton, '撤销完成'));
        expect(h.controller.task(_taskId)!.status, 'in_progress');
        expect(h.store.value.tasks.single.completedChecks, [_firstCheck]);
        expect(h.controller.data.entries.single.id, originalEntry['id']);
        expect(
          h.controller.data.entries.single.start,
          readZoned(originalEntry['start'], 'Asia/Hong_Kong'),
        );
        expect(
          h.controller.data.entries.single.end,
          readZoned(originalEntry['end'], 'Asia/Hong_Kong'),
        );
        expect(h.controller.data.entries.single.taskId, _taskId);
        expect(h.store.writes, 3);
        if (surface.key == 'plan') {
          await _tap(tester, find.widgetWithText(FilterChip, '未完成'));
        }
        await _expand(tester);
        _expectChecks(tester, first: true, second: false);
        expect(
          tester.widget<CheckboxListTile>(_check(_secondCheck)).onChanged,
          isNotNull,
        );
        expect(find.widgetWithText(TextButton, '撤销完成'), findsNothing);
        expect(_router(tester).routeInformationProvider.value.uri, location);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'inline and detail checklists share saved state across navigation and reload',
    (tester) async {
      final h = await _mount(tester, '/04');
      await _expand(tester);
      await _tap(tester, _check(_firstCheck));
      await _tap(
        tester,
        find.descendant(of: _row(), matching: find.text(_title)),
      );
      expect(
        _router(tester)
            .routeInformationProvider
            .value
            .uri
            .queryParameters['taskId'],
        _taskId,
      );
      final firstDetail = find.widgetWithText(CheckboxListTile, _firstCheck);
      final secondDetail = find.widgetWithText(CheckboxListTile, _secondCheck);
      expect(tester.widget<CheckboxListTile>(firstDetail).value, isTrue);
      expect(tester.widget<CheckboxListTile>(secondDetail).value, isFalse);
      expect(h.store.writes, 1);
      await _tap(tester, secondDetail);
      expect(h.controller.task(_taskId)!.completedChecks, [
        _firstCheck,
        _secondCheck,
      ]);
      await _tap(tester, find.byTooltip('返回'));
      await _expand(tester);
      _expectChecks(tester, first: true, second: true);
      expect(h.store.writes, 2);

      await h.reload(tester, '/04');
      await _expand(tester);
      _expectChecks(tester, first: true, second: true);
      expect(h.controller.task(_taskId)!.status, 'in_progress');
      expect(h.store.writes, 2);
      await _tap(tester, _check(_firstCheck));
      expect(h.controller.task(_taskId)!.completedChecks, [_secondCheck]);
      expect(h.store.value.tasks.single.completedChecks, [_secondCheck]);
      expect(h.store.writes, 3);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed inline saves keep the old value and allow a real retry', (
    tester,
  ) async {
    final h = await _mount(tester, '/04');
    final before = h.controller.task(_taskId)!.toJson();
    final location = _router(tester).routeInformationProvider.value.uri;
    await _expand(tester);
    h.store.failNextSave = true;
    await _tap(tester, _check(_firstCheck));
    _expectChecks(tester, first: false, second: false);
    expect(h.controller.task(_taskId)!.toJson(), before);
    expect(h.store.value.tasks.single.toJson(), before);
    expect(h.controller.data.history, isEmpty);
    expect(h.store.attempts, 1);
    expect(h.store.writes, 0);
    expect(find.byType(SnackBar), findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byType(SeraScaffold)))
        .clearSnackBars();
    await tester.pumpAndSettle();

    await _tap(tester, _check(_firstCheck));
    _expectChecks(tester, first: true, second: false);
    expect(h.store.attempts, 2);
    expect(h.store.writes, 1);
    expect(h.store.value.tasks.single.completedChecks, [_firstCheck]);
    expect(h.controller.task(_taskId)!.status, 'in_progress');
    expect(_router(tester).routeInformationProvider.value.uri, location);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pending saves disable task and subitem writes until persistence finishes',
    (tester) async {
      final h = await _mount(tester, '/17?filter=todo');
      await _expand(tester);
      final gate = Completer<void>();
      h.store.saveGate = gate;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await _tap(tester, _check(_firstCheck));
      expect(h.controller.busy, isTrue);
      expect(h.store.attempts, 1);
      expect(h.store.writes, 0);
      _expectChecks(tester, first: false, second: false);
      expect(
        tester.widget<CheckboxListTile>(_check(_firstCheck)).onChanged,
        isNull,
      );
      expect(
        tester.widget<CheckboxListTile>(_check(_secondCheck)).onChanged,
        isNull,
      );
      expect(tester.widget<Checkbox>(_parentCheckbox()).onChanged, isNull);
      await _tap(tester, _check(_secondCheck));
      expect(h.store.attempts, 1);

      gate.complete();
      await tester.pumpAndSettle();
      expect(h.controller.busy, isFalse);
      _expectChecks(tester, first: true, second: false);
      expect(h.store.value.tasks.single.completedChecks, [_firstCheck]);
      expect(h.store.writes, 1);
      expect(
        tester.widget<CheckboxListTile>(_check(_secondCheck)).onChanged,
        isNotNull,
      );
      expect(tester.widget<Checkbox>(_parentCheckbox()).onChanged, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a task without subitems opens its detail without an empty disclosure or write',
    (tester) async {
      final h = await _mount(
        tester,
        '/04',
        workspace: _workspace(checklist: const []),
      );
      expect(_row(), findsOneWidget);
      expect(_rowTooltip('展开子项'), findsNothing);
      expect(_rowTooltip('收起子项'), findsNothing);
      await _tap(
        tester,
        find.descendant(of: _row(), matching: find.text(_title)),
      );
      expect(
        _router(tester)
            .routeInformationProvider
            .value
            .uri
            .queryParameters['taskId'],
        _taskId,
      );
      expect(h.store.attempts, 0);
      expect(h.controller.task(_taskId)!.checklist, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
