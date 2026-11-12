import 'dart:ui' show CheckedState, SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';

DateTime _at(int day, int hour, [int minute = 0]) => readZoned(
  '2026-11-${day.toString().padLeft(2, '0')}T${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}:00+08:00',
  'Asia/Hong_Kong',
)!;

const _task = SeraTask(id: 'split-task', title: '整理考试范围', estimatedMinutes: 75);
CalendarEntry _block(String id, int day, int hour, int minutes) =>
    CalendarEntry(
      id: id,
      taskId: _task.id,
      title: _task.title,
      start: _at(day, hour),
      end: _at(day, hour).add(Duration(minutes: minutes)),
    );

class _Store implements WorkspaceRepository {
  _Store(this.value);
  Workspace value;
  int writes = 0;
  @override
  String get mode => 'focus-target-accessibility-test';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async => value = const Workspace();
  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    if (value.revision != expectedRevision) {
      throw const RepositoryException('版本冲突', conflict: true);
    }
    writes++;
    return value = Workspace.fromJson(
      next.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }
}

/// The persistence acknowledgment is authoritative if another accepted state
/// is returned while this page is awaiting the start operation.
class _AcceptedFocusStore extends _Store {
  _AcceptedFocusStore(super.value);

  @override
  Future<Workspace> save(Workspace next, {required int expectedRevision}) {
    final incoming = next.focusSession;
    final accepted = incoming == null
        ? next
        : next.copyWith(
            focusSession: FocusSession(
              id: incoming.id,
              taskId: incoming.taskId,
              startedAt: incoming.startedAt,
              isRunning: false,
              accumulatedSeconds: 73,
              targetMinutes: 30,
            ),
          );
    return super.save(accepted, expectedRevision: expectedRevision);
  }
}

Future<SeraController> _controller(_Store store, {DateTime? now}) async {
  final controller = SeraController(
    repository: store,
    today: now ?? _at(2, 9),
    seedDemo: false,
  );
  await controller.initialize();
  addTearDown(controller.dispose);
  return controller;
}

Future<void> _mount(
  WidgetTester tester,
  SeraController controller,
  String location,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  await tester.pumpWidget(
    SeraApp(controller: controller, initialLocation: location),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('current block takes priority over later blocks and completed earlier blocks', () async {
    final store = _Store(
      Workspace(
        revision: 1,
        tasks: const [_task],
        entries: [
          _block('past', 2, 8, 10),
          _block('current', 2, 9, 15),
          _block('later', 2, 10, 30),
          _block('tomorrow', 3, 9, 60),
        ],
      ),
    );
    final controller = await _controller(store, now: _at(2, 9, 5));
    expect(controller.focusTargetMinutes(_task.id), 15);
    await controller.startFocus(_task.id);
    expect(controller.data.focusSession!.targetMinutes, 15);
    expect(controller.task(_task.id)!.estimatedMinutes, 75);
    expect(controller.data.entries, hasLength(4));
    expect(store.writes, 1);
  });

  test('upcoming block is capped by remaining work; absent valid blocks use remaining work', () async {
    final task = _task.copyWith(remainingMinutes: 25);
    final store = _Store(
      Workspace(
        revision: 1,
        tasks: [task],
        entries: [
          _block('past', 2, 8, 10),
          _block('next', 2, 10, 30),
          _block('tomorrow', 3, 9, 60),
        ],
      ),
    );
    final controller = await _controller(store);
    expect(controller.focusTargetMinutes(task.id), 25);
    controller.data = controller.data.copyWith(
      entries: [_block('tomorrow', 3, 9, 60)],
    );
    expect(controller.focusTargetMinutes(task.id), 25);
    expect(controller.task(task.id)!.estimatedMinutes, 75);
    expect(store.writes, 0);
  });

  test('saved target survives pause reload cross-day changes and resume without completing task', () async {
    final store = _Store(
      Workspace(
        revision: 1,
        tasks: const [_task],
        entries: [_block('first', 2, 9, 15)],
      ),
    );
    final controller = await _controller(store);
    await controller.startFocus(_task.id);
    final id = controller.data.focusSession!.id;
    await controller.pauseFocus();
    expect(controller.data.focusSession!.targetMinutes, 15);
    final paused = controller.data.focusSession!;
    store.value = Workspace.fromJson(
      store.value
          .copyWith(
            entries: [],
            tasks: [_task.copyWith(remainingMinutes: 60)],
            focusSession: FocusSession(
              id: paused.id,
              taskId: paused.taskId,
              startedAt: paused.startedAt,
              accumulatedSeconds: 73,
              isRunning: false,
              targetMinutes: paused.targetMinutes,
            ),
          )
          .toJson(),
    );
    final reopened = await _controller(store, now: _at(3, 9));
    expect(reopened.focusTargetMinutes(_task.id), 15);
    await reopened.startFocus(_task.id, targetMinutes: 60);
    expect(reopened.data.focusSession!.id, id);
    expect(reopened.data.focusSession!.targetMinutes, 15);
    await reopened.resumeFocus();
    expect(reopened.data.focusSession!.targetMinutes, 15);
    await reopened.pauseFocus();
    expect(reopened.data.focusSession!.targetMinutes, 15);
    final seconds = await reopened.finishFocus();
    expect(seconds, greaterThanOrEqualTo(73));
    expect(reopened.task(_task.id)!.estimatedMinutes, 75);
    expect(reopened.task(_task.id)!.done, isFalse);
    expect(reopened.data.focusRecords.single.seconds, seconds);
  });

  test('legacy focus target uses its original day and invalid target values are rejected', () async {
    final legacy = FocusSession(
      id: 'legacy',
      taskId: _task.id,
      startedAt: _at(2, 9, 5),
      isRunning: false,
      accumulatedSeconds: 73,
    );
    final store = _Store(
      Workspace(
        revision: 1,
        tasks: const [_task],
        entries: [
          _block('original-day', 2, 9, 15),
          _block('current-day', 3, 9, 60),
        ],
        focusSession: legacy,
      ),
    );
    final controller = await _controller(store, now: _at(3, 9));
    expect(controller.focusTargetMinutes(_task.id), 15);
    final json = legacy.toJson()..remove('targetMinutes');
    expect(FocusSession.fromJson(json).targetMinutes, isNull);
    expect(
      FocusSession.fromJson({...json, 'targetMinutes': null}).targetMinutes,
      isNull,
    );
    expect(
      FocusSession.fromJson({...json, 'targetMinutes': 15}).targetMinutes,
      15,
    );
    for (final invalid in [0, 1441, -1, true, 15.5, '15']) {
      expect(
        () => FocusSession.fromJson({...json, 'targetMinutes': invalid}),
        throwsA(isA<FormatException>()),
      );
    }
    expect(store.writes, 0);
  });

  testWidgets(
    'detail and countdown use one 15-minute block while task estimate stays 75',
    (tester) async {
      final store = _Store(
        Workspace(
          revision: 1,
          tasks: const [_task],
          entries: [
            for (var day = 2; day <= 6; day++) _block('block-$day', day, 9, 15),
          ],
        ),
      );
      final controller = await _controller(store);
      await _mount(tester, controller, '/18?taskId=${_task.id}');
      final action = find.widgetWithText(SeraButton, '开始专注');
      expect(action, findsOneWidget);
      expect(controller.focusTargetMinutes(_task.id), 15);
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.text('目标 15分钟 · 已开始'), findsOneWidget);
      expect(controller.data.focusSession!.targetMinutes, 15);
      expect(find.textContaining(RegExp(r'^(15:00|14:5\d)$')), findsOneWidget);
      expect(controller.task(_task.id)!.estimatedMinutes, 75);
      expect(controller.data.entries, hasLength(5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reopened countdown uses saved target and actual accumulated seconds',
    (tester) async {
      final store = _Store(
        Workspace(
          revision: 1,
          tasks: const [_task],
          focusSession: FocusSession(
            id: 'saved-focus',
            taskId: _task.id,
            startedAt: _at(2, 9),
            accumulatedSeconds: 73,
            isRunning: false,
            targetMinutes: 15,
          ),
        ),
      );
      final controller = await _controller(store, now: _at(3, 9));
      await _mount(tester, controller, '/25?taskId=${_task.id}');
      expect(find.text('目标 15分钟 · 已暂停'), findsOneWidget);
      expect(find.text('13:47'), findsOneWidget);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'start uses the session target actually accepted by persistence',
    (tester) async {
      final store = _AcceptedFocusStore(
        Workspace(
          revision: 1,
          tasks: const [_task],
          entries: [_block('original-default', 2, 9, 15)],
        ),
      );
      final controller = await _controller(store);
      await _mount(tester, controller, '/25?taskId=${_task.id}');
      expect(controller.data.focusSession!.id, isNotEmpty);
      expect(controller.data.focusSession!.targetMinutes, 30);
      expect(find.text('目标 30分钟 · 已暂停'), findsOneWidget);
      expect(find.text('28:47'), findsOneWidget);
      expect(store.writes, 1);
      expect(controller.task(_task.id)!.estimatedMinutes, 75);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'search exposes an enabled opening button without a disabled completion checkbox',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final store = _Store(
          Workspace(
            revision: 1,
            tasks: const [_task],
            entries: [_block('search-entry', 2, 9, 15)],
          ),
        );
        final controller = await _controller(store);
        await _mount(tester, controller, '/35');
        await tester.enterText(find.byType(TextField), _task.title);
        await tester.pumpAndSettle();
        final row = find.byKey(const ValueKey('task-row-open:split-task'));
        expect(row, findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(SeraTaskRow),
            matching: find.byType(Checkbox),
          ),
          findsNothing,
        );
        final node = tester.getSemantics(row);
        final data = node.getSemanticsData();
        expect(data.flagsCollection.isButton, isTrue);
        expect(data.flagsCollection.isEnabled, Tristate.isTrue);
        expect(data.flagsCollection.isChecked, CheckedState.none);
        expect(data.hasAction(SemanticsAction.tap), isTrue);
        expect(data.label, contains(_task.title));
        expect(data.label, contains('09:00'));
        node.owner!.performAction(node.id, SemanticsAction.tap);
        await tester.pumpAndSettle();
        expect(find.widgetWithText(AppBar, '任务详情'), findsOneWidget);
        expect(controller.task(_task.id)!.done, isFalse);
        expect(store.writes, 0);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );
}
