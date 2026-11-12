import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/repositories.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/domain/planning_service.dart';

final _now = readZoned('2026-11-02T09:00:00+08:00', 'Asia/Hong_Kong')!;
final _deadline = readZoned('2026-11-15T23:59:00+08:00', 'Asia/Hong_Kong')!;
const _preferences = SeraPreferences(
  dailyBudget: 180,
  startMinute: 9 * 60,
  endMinute: 11 * 60,
  bufferMinutes: 15,
);

List<TaskOutline> _phasedOutlines() => List.generate(8, (index) {
  final firstPhase = index < 4;
  return TaskOutline(
    title: '执行步骤 ${index + 1}',
    estimatedMinutes: index % 4 == 3 ? 195 : 210,
    phase: firstPhase ? '第一周' : '第二周',
    notBefore: readZoned(
      firstPhase ? '2026-11-02T00:00:00+08:00' : '2026-11-09T00:00:00+08:00',
      'Asia/Hong_Kong',
    ),
    deadline: readZoned(
      firstPhase ? '2026-11-06T23:59:00+08:00' : '2026-11-15T23:59:00+08:00',
      'Asia/Hong_Kong',
    ),
    notes: '完成步骤 ${index + 1} 的实际产出',
    checklist: ['核对步骤 ${index + 1}'],
  );
});

class _CapacityStore implements WorkspaceRepository, PlanningAiProvider {
  _CapacityStore({Workspace? value, List<TaskOutline>? definitions})
    : value = value ?? const Workspace(preferences: _preferences),
      definitions = definitions ?? _phasedOutlines();

  Workspace value;
  List<TaskOutline> definitions;
  int calls = 0;
  int writes = 0;

  @override
  String get mode => 'capacity-test';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async => value = const Workspace();
  @override
  Future<Workspace> save(
    Workspace workspace, {
    required int expectedRevision,
  }) async {
    if (value.revision != expectedRevision) {
      throw const RepositoryException('工作区已有新修改', conflict: true);
    }
    writes++;
    return value = Workspace.fromJson(
      workspace.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }

  @override
  Future<AiPlanResult> generateTaskBreakdown({
    required String title,
    required DateTime deadline,
    required int dailyBudget,
    String notes = '',
    String prompt = '',
    String? requestId,
  }) async {
    calls++;
    return AiPlanResult(model: 'capacity-fixture', tasks: definitions);
  }
}

Future<SeraController> _controller(_CapacityStore store) async {
  final controller = SeraController(
    repository: store,
    today: _now,
    seedDemo: false,
  );
  await controller.initialize();
  addTearDown(controller.dispose);
  return controller;
}

Future<PlanDraft> _generate(SeraController controller) =>
    controller.generatePlan(
      title: '15 天完整计划',
      deadline: _deadline,
      dailyBudget: 480,
      requestId: 'capacity-request',
    );

CalendarEntry _entireWindowBusy() => CalendarEntry(
  id: 'external-busy',
  title: '已占用的可用时间',
  start: _now,
  end: _deadline,
  source: 'capacity-fixture',
  locked: true,
);

void _expectCompletePlan(PlanDraft draft) {
  expect(draft.items, hasLength(8));
  expect(draft.totalMinutes, 1650);
  expect(
    draft.items
        .where((item) => item.task.phase == '第一周')
        .fold<int>(0, (sum, item) => sum + item.task.estimatedMinutes),
    825,
  );
  expect(
    draft.items
        .where((item) => item.task.phase == '第二周')
        .fold<int>(0, (sum, item) => sum + item.task.estimatedMinutes),
    825,
  );
  for (var index = 0; index < draft.items.length; index++) {
    final item = draft.items[index];
    final definition = _phasedOutlines()[index];
    expect(item.task.title, definition.title);
    expect(item.task.estimatedMinutes, definition.estimatedMinutes);
    expect(item.task.phase, definition.phase);
    expect(item.task.notBefore, definition.notBefore);
    expect(item.task.deadline, definition.deadline);
    expect(item.task.checklist, definition.checklist);
  }
}

void main() {
  test('1650-minute phased result becomes complete tasks with a valid scheduled prefix', () async {
    final store = _CapacityStore();
    final controller = await _controller(store);
    final draft = await _generate(controller);
    _expectCompletePlan(draft);
    expect(draft.capacityLimited, isTrue);
    expect(draft.needsCapacityConfirmation, isTrue);
    expect(draft.needsPlanningConfirmation, isTrue);
    expect(draft.originalDailyBudget, isNull);
    expect(draft.suggestedDailyBudget, isNull);
    expect(store.calls, 1);
    expect(controller.data.tasks, isEmpty);
    expect(controller.data.entries, isEmpty);
    final scheduled = draft.items
        .where((item) => item.blocks.isNotEmpty)
        .toList();
    expect(scheduled, isNotEmpty);
    expect(scheduled.length, lessThan(draft.items.length));
    var reachedUnscheduled = false;
    final checked = <CalendarEntry>[];
    for (final item in draft.items) {
      if (item.blocks.isEmpty) {
        reachedUnscheduled = true;
        continue;
      }
      expect(reachedUnscheduled, isFalse);
      expect(
        item.blocks.fold<int>(0, (sum, block) => sum + block.minutes),
        item.task.estimatedMinutes,
      );
      for (final block in item.blocks) {
        expect(block.taskId, item.task.id);
        expect(block.start.isBefore(item.task.notBefore!), isFalse);
        expect(block.end.isAfter(item.task.deadline!), isFalse);
        expect(block.end.isAfter(_deadline), isFalse);
        expect(block.start.isBefore(_now), isFalse);
        PlanningService.validatePlacement(
          block,
          controller.data,
          occupied: checked,
          applyPreferences: true,
        );
        if (checked.isNotEmpty) {
          expect(block.start.isBefore(checked.last.end), isFalse);
        }
        checked.add(block);
      }
    }
  });

  test(
    'no actual free window keeps every task unscheduled and can be confirmed',
    () async {
      final store = _CapacityStore(
        value: Workspace(
          preferences: _preferences,
          externalBusyEntries: [_entireWindowBusy()],
        ),
      );
      final controller = await _controller(store);
      final draft = await _generate(controller);
      _expectCompletePlan(draft);
      expect(draft.unscheduledItems, hasLength(8));
      expect(draft.items.expand((item) => item.blocks), isEmpty);
      await expectLater(
        controller.commitDraft(draft.id),
        throwsA(isA<RepositoryException>()),
      );
      expect(controller.data.tasks, isEmpty);
      await controller.confirmDraftPlanningLimits(draft.id);
      await controller.commitDraft(draft.id);
      expect(controller.data.tasks, hasLength(8));
      expect(controller.data.entries, isEmpty);
      expect(controller.data.externalBusyEntries, hasLength(1));
      expect(controller.data.preferences.toJson(), _preferences.toJson());
    },
  );

  test('pending consent survives reopen and commit stays idempotent without another AI call', () async {
    final store = _CapacityStore();
    final controller = await _controller(store);
    final draft = await _generate(controller);
    final taskIds = draft.items.map((item) => item.task.id).toList();
    final entryIds = draft.items
        .expand((item) => item.blocks)
        .map((block) => block.id)
        .toList();
    await expectLater(
      controller.commitDraft(draft.id),
      throwsA(isA<RepositoryException>()),
    );
    expect(controller.data.goals, isEmpty);
    expect(controller.data.tasks, isEmpty);
    final reopened = await _controller(store);
    expect(reopened.draft(draft.id)!.needsCapacityConfirmation, isTrue);
    expect((await _generate(reopened)).id, draft.id);
    expect(store.calls, 1);
    await reopened.confirmDraftPlanningLimits(draft.id);
    final approved = await _controller(store);
    expect(approved.draft(draft.id)!.capacityConfirmed, isTrue);
    await approved.commitDraft(draft.id);
    final writes = store.writes;
    await approved.commitDraft(draft.id);
    expect(store.writes, writes);
    expect(approved.data.tasks.map((task) => task.id), taskIds);
    expect(approved.data.entries.map((entry) => entry.id), entryIds);
    expect(approved.data.goals.single.id, draft.goal.id);
    expect(approved.draft(draft.id)!.status, 'committed');
    expect((await _generate(approved)).id, draft.id);
    expect(store.calls, 1);
  });

  test('calendar changes turn the scheduled prefix into unscheduled work and reset consent', () async {
    final store = _CapacityStore();
    final controller = await _controller(store);
    final draft = await _generate(controller);
    await controller.confirmDraftPlanningLimits(draft.id);
    expect(controller.draft(draft.id)!.capacityConfirmed, isTrue);
    await controller.setExternalBusyEntries([
      _entireWindowBusy(),
    ], source: 'test');
    await expectLater(
      controller.commitDraft(draft.id),
      throwsA(
        isA<RepositoryException>().having(
          (error) => error.conflict,
          'conflict',
          isTrue,
        ),
      ),
    );
    await controller.revalidateDraft(draft.id);
    final revised = controller.draft(draft.id)!;
    _expectCompletePlan(revised);
    expect(revised.unscheduledItems, hasLength(8));
    expect(revised.needsCapacityConfirmation, isTrue);
    expect(revised.capacityConfirmed, isFalse);
    expect(controller.data.tasks, isEmpty);
    await expectLater(
      controller.commitDraft(draft.id),
      throwsA(isA<RepositoryException>()),
    );
    await controller.confirmDraftPlanningLimits(draft.id);
    await controller.commitDraft(draft.id);
    expect(controller.data.tasks, hasLength(8));
    expect(controller.data.entries, isEmpty);
    expect(store.calls, 1);
  });

  test('a formerly complete draft also becomes a soft capacity candidate after new occupation', () async {
    final store = _CapacityStore(
      definitions: const [TaskOutline(title: '一小时准备', estimatedMinutes: 60)],
    );
    final controller = await _controller(store);
    final draft = await _generate(controller);
    expect(draft.capacityLimited, isFalse);
    expect(draft.items.single.blocks, isNotEmpty);
    await controller.setExternalBusyEntries([
      _entireWindowBusy(),
    ], source: 'test');
    await controller.revalidateDraft(draft.id);
    final revised = controller.draft(draft.id)!;
    expect(revised.items.single.task.id, draft.items.single.task.id);
    expect(revised.items.single.task.estimatedMinutes, 60);
    expect(revised.items.single.blocks, isEmpty);
    expect(revised.needsCapacityConfirmation, isTrue);
    await expectLater(
      controller.commitDraft(draft.id),
      throwsA(isA<RepositoryException>()),
    );
    await controller.confirmDraftPlanningLimits(draft.id);
    await controller.commitDraft(draft.id);
    expect(controller.data.tasks, hasLength(1));
    expect(controller.data.entries, isEmpty);
    expect(store.calls, 1);
  });

  test('notes preserve consent but changed unscheduled work requires a fresh confirmation', () async {
    final store = _CapacityStore();
    final controller = await _controller(store);
    final draft = await _generate(controller);
    await controller.confirmDraftPlanningLimits(draft.id);
    final waiting = controller.draft(draft.id)!.unscheduledItems.first;
    await controller.updateDraftItem(
      draft.id,
      PlannedTask(task: waiting.task.copyWith(notes: '只补充完成标准')),
    );
    expect(controller.draft(draft.id)!.capacityConfirmed, isTrue);
    final changed = controller
        .draft(draft.id)!
        .items
        .firstWhere((item) => item.task.id == waiting.task.id);
    await controller.updateDraftItem(
      draft.id,
      PlannedTask(task: changed.task.copyWith(estimatedMinutes: 215)),
    );
    expect(controller.draft(draft.id)!.needsCapacityConfirmation, isTrue);
    expect(controller.draft(draft.id)!.capacityConfirmed, isFalse);
    await expectLater(
      controller.commitDraft(draft.id),
      throwsA(isA<RepositoryException>()),
    );
    await controller.confirmDraftPlanningLimits(draft.id);
    await controller.commitDraft(draft.id);
    expect(controller.task(waiting.task.id)!.notes, '只补充完成标准');
    expect(controller.task(waiting.task.id)!.estimatedMinutes, 215);
  });

  test('existing goal edit inherits applicable capacity consent and preserves task identities', () async {
    final store = _CapacityStore();
    final controller = await _controller(store);
    final original = await _generate(controller);
    await controller.confirmDraftPlanningLimits(original.id);
    await controller.commitDraft(original.id);
    final taskIds = controller.data.tasks.map((task) => task.id).toSet();
    final entryIds = controller.data.entries.map((entry) => entry.id).toSet();
    final edit = await controller.editGoalPlan(original.goal.id);
    expect(edit.capacityLimited, isTrue);
    expect(edit.capacityConfirmed, isTrue);
    expect(edit.needsPlanningConfirmation, isFalse);
    expect(edit.unscheduledItems.length, original.unscheduledItems.length);
    await controller.commitDraft(edit.id);
    expect(controller.data.tasks.map((task) => task.id).toSet(), taskIds);
    expect(controller.data.entries.map((entry) => entry.id).toSet(), entryIds);
    expect(controller.data.goals, hasLength(1));
    expect(store.calls, 1);
  });

  test('capacity fallback never swallows a malformed later phase', () async {
    final definitions = [
      TaskOutline(
        title: '首先无法安排的任务',
        estimatedMinutes: 60,
        phase: '第一阶段',
        notBefore: _now,
        deadline: atMinute(_now, 9 * 60 + 30),
      ),
      const TaskOutline(
        title: '缺少窗口的后续阶段',
        estimatedMinutes: 30,
        phase: '第二阶段',
      ),
    ];
    final store = _CapacityStore(definitions: definitions);
    final controller = await _controller(store);
    await expectLater(
      _generate(controller),
      throwsA(
        isA<RepositoryException>().having(
          (error) => error.message,
          'message',
          contains('阶段'),
        ),
      ),
    );
    expect(controller.data.drafts, isEmpty);
    expect(controller.data.tasks, isEmpty);
    expect(store.calls, 1);
  });

  test('strict PlanningService.generate still fails unless soft capacity is requested', () {
    var serial = 0;
    expect(
      () => const PlanningService().generate(
        workspace: const Workspace(preferences: _preferences),
        today: _now,
        title: '15 天完整计划',
        deadline: _deadline,
        dailyBudget: 480,
        outlines: _phasedOutlines(),
        newId: (prefix) => '$prefix-${serial++}',
      ),
      throwsA(isA<RepositoryException>()),
    );
  });

  test('capacity fields remain legacy compatible and reject malformed or unconfirmed committed data', () async {
    final controller = await _controller(_CapacityStore());
    final draft = await _generate(controller);
    final json = draft.toJson();
    final legacy = Map<String, dynamic>.from(json)
      ..remove('capacityLimited')
      ..remove('capacityConfirmed');
    expect(PlanDraft.fromJson(legacy).needsCapacityConfirmation, isFalse);
    for (final change in <Json>[
      {'capacityLimited': null},
      {'capacityConfirmed': null},
      {'capacityLimited': 1},
      {'capacityConfirmed': 'yes'},
      {'capacityLimited': false, 'capacityConfirmed': true},
      {'status': 'committed'},
    ]) {
      expect(
        () => PlanDraft.fromJson({...json, ...change}),
        throwsA(isA<FormatException>()),
      );
    }
  });
}
