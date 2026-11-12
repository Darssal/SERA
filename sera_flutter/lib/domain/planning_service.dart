import '../data/workspace_repository.dart';
import 'models.dart';

class TaskOutline {
  const TaskOutline({
    required this.title,
    required this.estimatedMinutes,
    this.notes = '',
    this.checklist = const [],
    this.phase = '',
    this.notBefore,
    this.deadline,
  });
  final String title, notes, phase;
  final int estimatedMinutes;
  final List<String> checklist;
  final DateTime? notBefore, deadline;
}

/// Deterministic, inspectable local planning. No cloud AI or device calendar is
/// called: all constraints are checked against the application's workspace.
class PlanningService {
  const PlanningService();

  PlanDraft generate({
    required Workspace workspace,
    required DateTime today,
    required String title,
    required DateTime deadline,
    required int dailyBudget,
    required String Function(String) newId,
    String notes = '',
    String prompt = '',
    List<TaskOutline>? outlines,
    String source = 'local-template',
    String model = '',
    bool suggestBudgetOverflow = false,
    int? dailyBudgetOverride,
  }) {
    if (title.trim().isEmpty) throw const RepositoryException('请填写目标名称。');
    if (deadline.isBefore(dateOnly(today))) {
      throw const RepositoryException('截止时间不能早于今天。');
    }
    if (deadline.difference(dateOnly(today)).inDays > 366) {
      throw const RepositoryException('请将规划范围控制在一年以内。');
    }
    if (dailyBudget < 15 || dailyBudget > 480) {
      throw const RepositoryException('每日投入需在 15 至 480 分钟之间。');
    }
    if (dailyBudgetOverride != null &&
        (dailyBudgetOverride < 15 || dailyBudgetOverride > 1440)) {
      throw const RepositoryException('本次计划的每日时间无效。');
    }
    validatePreferences(workspace.preferences);
    const steps = [
      '梳理目标与方案框架',
      '整理资料与关键依据',
      '完成核心内容',
      '准备展示与演示',
      '根据反馈调整',
      '检查并完成提交',
    ];
    const durations = [45, 45, 60, 60, 30, 30];
    final definitions =
        outlines ??
        List.generate(
          steps.length,
          (i) => TaskOutline(
            title: '$title · ${steps[i]}',
            estimatedMinutes: durations[i],
            notes: notes.trim(),
          ),
        );
    if (definitions.isEmpty ||
        definitions.length > 96 ||
        definitions.any(
          (e) =>
              e.title.trim().isEmpty ||
              e.title.length > 200 ||
              e.phase.length > 100 ||
              e.estimatedMinutes < 5 ||
              e.estimatedMinutes > 240 ||
              e.estimatedMinutes % 5 != 0 ||
              e.checklist.length > 8 ||
              e.checklist.any((c) => c.trim().isEmpty || c.length > 500),
        )) {
      throw const RepositoryException('规划任务内容无效，请调整目标后重新生成。');
    }
    final goalDeadline = inTimeZone(
      deadline,
      workspace.preferences.timeZone,
      wallClock: true,
    );
    final goalId = newId('goal');
    final occupied = [...workspace.entries, ...workspace.externalBusyEntries];
    final items = <PlannedTask>[];
    var earliest = today;
    var capacityLimited = false;
    for (var i = 0; i < definitions.length; i++) {
      final definition = definitions[i];
      final notBefore = definition.notBefore == null
          ? null
          : inTimeZone(
              definition.notBefore!,
              workspace.preferences.timeZone,
              wallClock: true,
            );
      final requestedDeadline = definition.deadline == null
          ? goalDeadline
          : inTimeZone(
              definition.deadline!,
              workspace.preferences.timeZone,
              wallClock: true,
            );
      final taskDeadline = requestedDeadline.isBefore(goalDeadline)
          ? requestedDeadline
          : goalDeadline;
      if ((definition.phase.trim().isNotEmpty &&
              (notBefore == null || definition.deadline == null)) ||
          (notBefore != null && !taskDeadline.isAfter(notBefore))) {
        throw const RepositoryException('规划阶段的开始与截止时间不完整或无效，请重新生成。');
      }
      final start = notBefore != null && notBefore.isAfter(earliest)
          ? notBefore
          : earliest;
      final task = SeraTask(
        id: newId('task'),
        title: definition.title.trim(),
        goalId: goalId,
        estimatedMinutes: definition.estimatedMinutes,
        dueAt: taskDeadline,
        phase: definition.phase.trim(),
        notBefore: notBefore,
        splittable: outlines != null,
        minBlockMinutes: definition.estimatedMinutes < 15
            ? definition.estimatedMinutes
            : 15,
        notes: definition.notes.trim(),
        checklist: definition.checklist,
      );
      final blocks = capacityLimited
          ? <CalendarEntry>[]
          : findSlots(
              workspace: workspace,
              today: start,
              deadline: taskDeadline,
              task: task,
              dailyBudget: dailyBudget,
              dailyBudgetOverride: dailyBudgetOverride,
              occupied: occupied,
              newId: newId,
            );
      if (blocks.isEmpty && !capacityLimited) {
        if (suggestBudgetOverflow && dailyBudgetOverride == null) {
          final effective = dailyBudget < workspace.preferences.dailyBudget
              ? dailyBudget
              : workspace.preferences.dailyBudget;
          PlanDraft? candidate;
          // Reuse these exact task definitions. Raising only the daily cap must
          // still fit every task inside its real window and around busy time.
          PlanDraft tryBudget(int budget) => generate(
            workspace: workspace,
            today: today,
            title: title,
            deadline: deadline,
            dailyBudget: dailyBudget,
            dailyBudgetOverride: budget,
            newId: newId,
            notes: notes,
            prompt: prompt,
            outlines: outlines,
            source: source,
            model: model,
          );
          try {
            candidate = tryBudget(1440);
          } on RepositoryException {
            // A higher target cannot create actual free time. Preserve the
            // complete task list below and ask before saving unscheduled work.
          }
          if (candidate != null) {
            var low = effective ~/ 5 + 1;
            var high = 1440 ~/ 5;
            while (low < high) {
              final middle = (low + high) ~/ 2;
              try {
                candidate = tryBudget(middle * 5);
                high = middle;
              } on RepositoryException {
                low = middle + 1;
              }
            }
            return candidate!;
          }
          capacityLimited = true;
        }
        if (!capacityLimited) {
          throw _capacityFailure(
            workspace: workspace,
            today: today,
            deadline: goalDeadline,
            dailyBudget: dailyBudget,
            definitions: definitions,
            failedPhase: definition.phase.trim(),
          );
        }
      }
      items.add(
        PlannedTask(
          task: task,
          entry: blocks.firstOrNull,
          additionalEntries: blocks.skip(1).toList(),
        ),
      );
      occupied.addAll(blocks);
      if (blocks.isNotEmpty) earliest = blocks.last.end;
    }
    return PlanDraft(
      id: newId('draft'),
      goal: SeraGoal(
        id: goalId,
        title: title.trim(),
        deadline: deadline,
        outcome: notes.trim(),
        taskIds: items.map((e) => e.task.id).toList(),
      ),
      items: items,
      prompt: prompt,
      baseRevision: workspace.revision,
      source: source,
      model: model,
      originalDailyBudget: dailyBudgetOverride == null
          ? null
          : dailyBudget < workspace.preferences.dailyBudget
          ? dailyBudget
          : workspace.preferences.dailyBudget,
      suggestedDailyBudget: dailyBudgetOverride,
      capacityLimited: capacityLimited,
    );
  }

  RepositoryException _capacityFailure({
    required Workspace workspace,
    required DateTime today,
    required DateTime deadline,
    required int dailyBudget,
    required List<TaskOutline> definitions,
    required String failedPhase,
  }) {
    final zone = workspace.preferences.timeZone;
    final effectiveBudget = dailyBudget < workspace.preferences.dailyBudget
        ? dailyBudget
        : workspace.preferences.dailyBudget;
    final totalRequiredMinutes = definitions.fold<int>(
      0,
      (sum, item) => sum + item.estimatedMinutes,
    );
    final totalCapacity = _estimateCapacity(
      workspace: workspace,
      today: today,
      start: inTimeZone(today, zone),
      end: deadline,
      dailyBudget: effectiveBudget,
    );
    final phases = <String, ({DateTime start, DateTime end, int minutes})>{};
    for (final definition in definitions) {
      final phase = definition.phase.trim();
      if (phase.isEmpty ||
          definition.notBefore == null ||
          definition.deadline == null) {
        continue;
      }
      final start = inTimeZone(definition.notBefore!, zone, wallClock: true);
      final requestedEnd = inTimeZone(
        definition.deadline!,
        zone,
        wallClock: true,
      );
      final end = requestedEnd.isBefore(deadline) ? requestedEnd : deadline;
      final previous = phases[phase];
      phases[phase] = (
        start: previous == null || start.isBefore(previous.start)
            ? start
            : previous.start,
        end: previous == null || end.isAfter(previous.end) ? end : previous.end,
        minutes: (previous?.minutes ?? 0) + definition.estimatedMinutes,
      );
    }
    final capacities = <String, int>{};
    String? overloadedPhase;
    for (final phase in phases.entries) {
      final capacity = _estimateCapacity(
        workspace: workspace,
        today: today,
        start: phase.value.start,
        end: phase.value.end,
        dailyBudget: effectiveBudget,
      );
      capacities[phase.key] = capacity;
      if (overloadedPhase == null && phase.value.minutes > capacity) {
        overloadedPhase = phase.key;
      }
    }
    final selectedPhase =
        overloadedPhase ??
        (phases.containsKey(failedPhase) ? failedPhase : null);
    final phase = phases[selectedPhase];
    final requiredMinutes = phase?.minutes ?? totalRequiredMinutes;
    final start = phase?.start ?? inTimeZone(today, zone);
    final end = phase?.end ?? deadline;
    final capacity = selectedPhase == null
        ? totalCapacity
        : capacities[selectedPhase]!;
    final shortage = requiredMinutes > capacity;
    final budgetMessage =
        '当前实际每日预算为 $effectiveBudget 分钟（本次目标 $dailyBudget 分钟，个人上限 ${workspace.preferences.dailyBudget} 分钟）。';
    final message = phase != null
        ? '模型给出的「$selectedPhase」在 ${calendarDateString(start)}—${calendarDateString(end)} 内安排 $requiredMinutes 分钟，按当前可用条件最多约 $capacity 分钟；'
              '${shortage ? '' : '任务顺序、最短分段与缓冲仍需满足，当前任务未能完整排入，'}需要调整该阶段计划。$budgetMessage'
              '${totalRequiredMinutes > totalCapacity ? '整个计划共需 $totalRequiredMinutes 分钟，截止前最多约 $totalCapacity 分钟，全周期容量也不足。' : ''}'
        : '${shortage ? '截止前没有足够的可用时段。' : '当前任务未能按顺序在截止前完整排入。'}'
              '$budgetMessage计划共需 $requiredMinutes 分钟，按当前可用条件截止前最多约 $capacity 分钟；请核对任务量、可用时间与相关限制。';
    return RepositoryException(
      message,
      details: {
        'planningFailureKind': phase != null
            ? shortage
                  ? 'phase_capacity'
                  : 'phase_window_constraints'
            : shortage
            ? 'total_capacity'
            : 'placement_constraints',
        if (phase != null) 'phase': selectedPhase,
        'windowStart': start.toUtc().toIso8601String(),
        'windowEnd': end.toUtc().toIso8601String(),
        'requiredMinutes': requiredMinutes,
        'estimatedCapacityMinutes': capacity,
        'totalRequiredMinutes': totalRequiredMinutes,
        'estimatedTotalCapacityMinutes': totalCapacity,
        'capacityIsEstimate': true,
        'effectiveDailyBudget': effectiveBudget,
        'selectedDailyBudget': dailyBudget,
        'preferencesDailyBudget': workspace.preferences.dailyBudget,
      },
    );
  }

  // This is an upper estimate for explaining a failed placement, never a
  // substitute for scheduling. New-task buffers, ordering and minimum block
  // sizes can reduce the amount that can actually be placed.
  int _estimateCapacity({
    required Workspace workspace,
    required DateTime today,
    required DateTime start,
    required DateTime end,
    required int dailyBudget,
  }) {
    final p = workspace.preferences;
    today = inTimeZone(today, p.timeZone);
    if (today.isAfter(start)) start = today;
    if (!end.isAfter(start)) return 0;
    final occupied = [...workspace.entries, ...workspace.externalBusyEntries];
    var capacity = 0;
    for (
      var day = dateOnly(start);
      !day.isAfter(dateOnly(end));
      day = calendarDay(day, 1)
    ) {
      if (!p.weekdays.contains(day.weekday)) continue;
      final nextDay = calendarDay(day, 1);
      final entries = occupied
          .where(
            (entry) => entry.start.isBefore(nextDay) && entry.end.isAfter(day),
          )
          .toList();
      final remainingBudget =
          dailyBudget -
          entries
              .where((entry) => entry.isTask)
              .fold<int>(0, (sum, entry) => sum + entry.minutes);
      if (remainingBudget <= 0) continue;
      var lower = atMinute(day, p.startMinute);
      var upper = atMinute(day, p.endMinute);
      if (start.isAfter(lower)) lower = start;
      if (end.isBefore(upper)) upper = end;
      if (!upper.isAfter(lower)) continue;
      final blocked = <({DateTime start, DateTime end})>[
        if (p.restStart < p.restEnd)
          (start: atMinute(day, p.restStart), end: atMinute(day, p.restEnd)),
        for (final entry in entries)
          (
            start: entry.start.subtract(Duration(minutes: p.bufferMinutes)),
            end: entry.end.add(Duration(minutes: p.bufferMinutes)),
          ),
      ]..sort((a, b) => a.start.compareTo(b.start));
      var cursor = lower;
      var available = 0;
      for (final interval in blocked) {
        if (!interval.end.isAfter(cursor) || !interval.start.isBefore(upper)) {
          continue;
        }
        if (interval.start.isAfter(cursor)) {
          available += _gridMinutes(cursor, interval.start);
        }
        if (interval.end.isAfter(cursor)) cursor = interval.end;
        if (!cursor.isBefore(upper)) break;
      }
      if (cursor.isBefore(upper)) available += _gridMinutes(cursor, upper);
      capacity += available < remainingBudget ? available : remainingBudget;
    }
    return capacity;
  }

  int _gridMinutes(DateTime start, DateTime end) {
    if (start.minute % 5 != 0 ||
        start.second != 0 ||
        start.millisecond != 0 ||
        start.microsecond != 0) {
      start = atMinute(start, start.hour * 60 + ((start.minute ~/ 5) + 1) * 5);
    }
    final minutes = end.difference(start).inMinutes;
    return minutes > 0 ? minutes ~/ 5 * 5 : 0;
  }

  CalendarEntry? findSlot({
    required Workspace workspace,
    required DateTime today,
    required DateTime deadline,
    required int minutes,
    required int dailyBudget,
    required List<CalendarEntry> occupied,
    required String taskId,
    required String title,
    required String entryId,
    int? dailyBudgetOverride,
  }) {
    final p = workspace.preferences;
    today = inTimeZone(today, p.timeZone);
    deadline = inTimeZone(deadline, p.timeZone, wallClock: true);
    final budget =
        dailyBudgetOverride ??
        (dailyBudget < p.dailyBudget ? dailyBudget : p.dailyBudget);
    for (
      var day = dateOnly(today);
      !day.isAfter(dateOnly(deadline));
      day = calendarDay(day, 1)
    ) {
      if (!p.weekdays.contains(day.weekday)) continue;
      final nextDay = calendarDay(day, 1);
      final entries = occupied
          .where((e) => e.start.isBefore(nextDay) && e.end.isAfter(day))
          .toList();
      final allocated = entries
          .where((e) => e.isTask)
          .fold<int>(0, (sum, e) => sum + e.minutes);
      if (allocated + minutes > budget) continue;
      final windowStart = atMinute(day, p.startMinute);
      final windowEnd = atMinute(day, p.endMinute);
      var start = today.isAfter(windowStart) ? today : windowStart;
      // Round up to a five-minute boundary for stable, readable schedules.
      if (start.minute % 5 != 0 ||
          start.second != 0 ||
          start.millisecond != 0) {
        start = atMinute(
          start,
          start.hour * 60 + ((start.minute ~/ 5) + 1) * 5,
        );
      }
      while (!start.add(Duration(minutes: minutes)).isAfter(windowEnd) &&
          !start.add(Duration(minutes: minutes)).isAfter(deadline)) {
        final end = start.add(Duration(minutes: minutes));
        final overlaps = entries.any(
          (e) =>
              start.isBefore(e.end.add(Duration(minutes: p.bufferMinutes))) &&
              end.add(Duration(minutes: p.bufferMinutes)).isAfter(e.start),
        );
        final restStart = atMinute(day, p.restStart);
        final restEnd = atMinute(day, p.restEnd);
        final inRest =
            p.restStart < p.restEnd &&
            start.isBefore(restEnd) &&
            end.isAfter(restStart);
        if (!overlaps && !inRest) {
          return CalendarEntry(
            id: entryId,
            taskId: taskId,
            title: title,
            start: start,
            end: end,
          );
        }
        start = start.add(const Duration(minutes: 5));
      }
    }
    return null;
  }

  List<CalendarEntry> findSlots({
    required Workspace workspace,
    required DateTime today,
    required DateTime deadline,
    required SeraTask task,
    required int dailyBudget,
    required List<CalendarEntry> occupied,
    required String Function(String) newId,
    int? dailyBudgetOverride,
  }) {
    if (!task.active || task.status == 'blocked') return [];
    var earliest = today;
    if (task.notBefore != null) {
      final notBefore = inTimeZone(
        task.notBefore!,
        workspace.preferences.timeZone,
        wallClock: true,
      );
      if (notBefore.isAfter(earliest)) earliest = notBefore;
    }
    if (task.deadline != null) {
      final taskDeadline = inTimeZone(
        task.deadline!,
        workspace.preferences.timeZone,
        wallClock: true,
      );
      final requestedDeadline = inTimeZone(
        deadline,
        workspace.preferences.timeZone,
        wallClock: true,
      );
      if (taskDeadline.isBefore(requestedDeadline)) deadline = taskDeadline;
    }
    if (!inTimeZone(
      deadline,
      workspace.preferences.timeZone,
      wallClock: true,
    ).isAfter(earliest)) {
      return [];
    }
    for (final id in task.dependencyIds) {
      SeraTask? dependency;
      for (final t in workspace.tasks) {
        if (t.id == id) dependency = t;
      }
      if (dependency == null) return [];
      if (dependency.done) continue;
      final planned = occupied.where((e) => e.taskId == id).toList();
      if (planned.isEmpty) return [];
      final end = planned
          .map((e) => e.end)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      if (end.isAfter(earliest)) earliest = end;
    }
    var remaining = task.workMinutes;
    if (remaining <= 0) return [];
    final blocks = <CalendarEntry>[];
    while (remaining > 0) {
      CalendarEntry? block;
      var minutes = remaining;
      while (minutes >= (task.splittable ? task.minBlockMinutes : remaining)) {
        if (remaining - minutes > 0 &&
            remaining - minutes < task.minBlockMinutes) {
          minutes -= 5;
          continue;
        }
        final candidate = findSlot(
          workspace: workspace,
          today: earliest,
          deadline: deadline,
          minutes: minutes,
          dailyBudget: dailyBudget,
          dailyBudgetOverride: dailyBudgetOverride,
          occupied: [...occupied, ...blocks],
          taskId: task.id,
          title: task.title,
          entryId: newId('entry'),
        );
        // A whole block later in the week must not skip usable fragments
        // today. Among equal start times the descending sizes keep the largest.
        if (candidate != null &&
            (block == null || candidate.start.isBefore(block.start))) {
          block = candidate;
        }
        if (!task.splittable) break;
        minutes -= 5;
      }
      if (block == null) return [];
      blocks.add(block);
      remaining -= block.minutes;
      earliest = block.end;
    }
    return blocks;
  }

  static void validatePreferences(SeraPreferences p) {
    if (p.weekdays.isEmpty ||
        p.weekdays.any((e) => e < 1 || e > 7) ||
        p.weekdays.toSet().length != p.weekdays.length) {
      throw const RepositoryException('请至少选择一个有效的可用工作日。');
    }
    if (p.dailyBudget < 15 ||
        p.dailyBudget > 480 ||
        p.bufferMinutes < 0 ||
        p.bufferMinutes > 120 ||
        p.startMinute < 0 ||
        p.endMinute > 1440 ||
        p.startMinute >= p.endMinute ||
        p.restStart < 0 ||
        p.restEnd > 1440 ||
        p.restStart > p.restEnd ||
        p.quietStart < 0 ||
        p.quietStart > 1439 ||
        p.quietEnd < 0 ||
        p.quietEnd > 1439) {
      throw const RepositoryException('时间偏好无效，请检查每日预算、时间范围与缓冲。');
    }
  }

  static void validatePlacement(
    CalendarEntry entry,
    Workspace workspace, {
    String? ignoreEntryId,
    List<CalendarEntry>? occupied,
    bool applyPreferences = false,
    int? dailyBudget,
    int? dailyBudgetOverride,
  }) {
    if (entry.title.trim().isEmpty ||
        !entry.end.isAfter(entry.start) ||
        entry.minutes > (entry.isTask ? 1440 : 366 * 1440)) {
      throw const RepositoryException('请填写日程名称并设置有效的开始、结束时间。');
    }
    final others =
        (occupied ?? [...workspace.entries, ...workspace.externalBusyEntries])
            .where((e) => e.id != ignoreEntryId && e.id != entry.id);
    if ((entry.isTask || !entry.locked) &&
        others.any(
          (e) => entry.start.isBefore(e.end) && entry.end.isAfter(e.start),
        )) {
      throw const RepositoryException('所选时段与现有安排重叠，请选择其他时间。');
    }
    if (!applyPreferences) return;
    final p = workspace.preferences;
    final day = dateOnly(entry.start);
    if (!p.weekdays.contains(day.weekday) ||
        entry.start.isBefore(atMinute(day, p.startMinute)) ||
        entry.end.isAfter(atMinute(day, p.endMinute))) {
      throw const RepositoryException('所选时段不在可用工作日或规划时间段内。');
    }
    if (p.restStart < p.restEnd &&
        entry.start.isBefore(atMinute(day, p.restEnd)) &&
        entry.end.isAfter(atMinute(day, p.restStart))) {
      throw const RepositoryException('所选时段位于休息时间。');
    }
    final allocated = others
        .where((e) => e.isTask && dateOnly(e.start) == day)
        .fold<int>(0, (sum, e) => sum + e.minutes);
    final budget =
        dailyBudgetOverride ??
        (dailyBudget == null || dailyBudget > p.dailyBudget
            ? p.dailyBudget
            : dailyBudget);
    if (allocated + entry.minutes > budget) {
      throw const RepositoryException('所选日期已超过每日规划预算。');
    }
    if (others.any(
      (e) =>
          entry.start.isBefore(e.end.add(Duration(minutes: p.bufferMinutes))) &&
          entry.end.add(Duration(minutes: p.bufferMinutes)).isAfter(e.start),
    )) {
      throw const RepositoryException('所选时段未留足规划缓冲，请选择其他时间。');
    }
  }
}
