part of 'sera_controller.dart';

extension SeraControllerFeatures on SeraController {
  String planningRequestNotes(String notes) => data.preferences.useAiContext
      ? '$notes\n用户允许参考的已完成任务：${data.tasks.where((t) => t.done).take(5).map((t) => "${t.title}（实际${t.actualSeconds ~/ 60}分钟）").join("；")}'
      : notes;

  String _calendarFingerprint(Workspace w, {String? targetGoalId}) => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'entries': w.entries
                .where(
                  (e) =>
                      targetGoalId == null ||
                      task(e.taskId)?.goalId != targetGoalId,
                )
                .map((e) => e.toJson())
                .toList(),
            'busy': w.externalBusyEntries.map((e) => e.toJson()).toList(),
            'preferences': w.preferences.toJson(),
          }),
        ),
      )
      .toString();
  int get pendingSyncCount => repository is SynchronizingWorkspaceRepository
      ? (repository as SynchronizingWorkspaceRepository).pendingCount
      : 0;
  bool get isOffline =>
      repository is SynchronizingWorkspaceRepository &&
      (repository as SynchronizingWorkspaceRepository).isOffline;
  Json? get syncConflict => repository is SynchronizingWorkspaceRepository
      ? (repository as SynchronizingWorkspaceRepository).syncConflict
      : null;
  Future<void> retrySync() async {
    if (repository is LocalWorkspaceCache) return refresh();
    await _serial(() async {
      if (repository case SynchronizingWorkspaceRepository r) {
        data = await r.synchronize() ?? data;
        await _afterSave();
      }
    });
  }

  Future<void> resolveSyncConflict({required bool keepLocal}) =>
      _serial(() async {
        if (repository case SynchronizingWorkspaceRepository r) {
          data = await r.resolveConflict(keepLocal: keepLocal) ?? data;
          await _afterSave();
        }
      });
  Future<void> _refreshExternal(DateTime deadline) async {
    if (_disposed) throw const RepositoryException('当前工作区已关闭。');
    final refreshed = await onBeforePlanning?.call(data, deadline);
    // Device calendar reads can outlive sign-out. Never persist that old
    // snapshot after this account's controller has been closed.
    if (_disposed) throw const RepositoryException('当前工作区已关闭。');
    if (refreshed != null &&
        jsonEncode(
              refreshed.externalBusyEntries.map((e) => e.toJson()).toList(),
            ) !=
            jsonEncode(
              data.externalBusyEntries.map((e) => e.toJson()).toList(),
            )) {
      data = await repository.save(refreshed, expectedRevision: data.revision);
    }
  }

  Future<void> _afterSave() async {
    if (_disposed || onWorkspaceSaved == null) return;
    _pendingPlatformWorkspace = data;
    // The main object is already durable. Coalesce device integrations without
    // holding the user's save or allowing older integrations to finish last.
    _platformWork ??= _drainPlatformUpdates();
  }

  Future<void> _drainPlatformUpdates() async {
    try {
      while (!_disposed && _pendingPlatformWorkspace != null) {
        final workspace = _pendingPlatformWorkspace!;
        _pendingPlatformWorkspace = null;
        String? failure;
        try {
          await onWorkspaceSaved!(workspace);
        } catch (_) {
          failure = '数据已保存，系统日历或提醒尚未更新，请到连接设置重试。';
        }
        if (_disposed) return;
        // A newer saved state will be reconciled next; only its outcome is final.
        if (_pendingPlatformWorkspace == null) {
          platformError = failure;
          _notify();
        }
      }
    } finally {
      _platformWork = null;
    }
  }

  void cancelGeneration() {
    cancelUnderstanding();
    _generation++;
    if (repository case CancellablePlanningAiProvider provider) {
      provider.cancelPlanning();
    }
    generationStage = '';
  }

  void _validateDependencies(SeraTask value, List<SeraTask> tasks) {
    final all = {for (final t in tasks) t.id: t, value.id: value};
    final visiting = <String>{}, visited = <String>{};
    void visit(String id) {
      if (visiting.contains(id)) throw const RepositoryException('任务依赖不能形成循环。');
      if (visited.contains(id)) return;
      final t = all[id];
      if (t == null) throw const RepositoryException('前置任务已不存在，请重新选择。');
      visiting.add(id);
      for (final d in t.dependencyIds) {
        visit(d);
      }
      visiting.remove(id);
      visited.add(id);
    }

    visit(value.id);
  }

  Future<void> saveGoal(SeraGoal value) => _mutate('保存目标', (w) {
    if (value.title.trim().isEmpty ||
        value.title.length > 200 ||
        !const [
          'active',
          'paused',
          'completed',
          'archived',
        ].contains(value.status)) {
      throw const RepositoryException('请检查目标名称和状态。');
    }
    final old = goal(value.id);
    if (old != null && old.revision != value.revision) {
      throw const RepositoryException('目标已有新修改，请重新打开。', conflict: true);
    }
    return w.copyWith(
      goals: [
        ...w.goals.where((g) => g.id != value.id),
        value.copyWith(
          title: value.title.trim(),
          revision: (old?.revision ?? 0) + 1,
        ),
      ],
    );
  });

  Future<void> setGoalStatus(String id, String status) async {
    final value = goal(id);
    if (value == null) throw const RepositoryException('目标已不存在。');
    if (status == 'completed' && tasksForGoal(id).any((t) => t.active)) {
      throw const RepositoryException('请先处理尚未完成的任务，再验收目标。');
    }
    await saveGoal(value.copyWith(status: status));
  }

  Future<void> setTaskStatus(String id, String status, {String reason = ''}) =>
      _mutate('更新任务状态', (w) {
        final t = _requireTask(id);
        if (!const [
          'todo',
          'in_progress',
          'blocked',
          'done',
          'canceled',
        ].contains(status)) {
          throw const RepositoryException('任务状态无效。');
        }
        if (status == 'in_progress' &&
            t.dependencyIds.any((id) => task(id)?.done != true)) {
          throw const RepositoryException('请先完成前置任务。');
        }
        if (status == 'blocked' && reason.trim().isEmpty) {
          throw const RepositoryException('请记录遇到的阻碍。');
        }
        final terminal = status == 'done' || status == 'canceled';
        final updated = _replaceTask(
          w,
          t.copyWith(
            status: status,
            blockedReason: status == 'blocked' ? reason.trim() : '',
            revision: t.revision + 1,
          ),
        );
        return terminal ? _terminalCleanup(updated, id) : updated;
      });

  /// Return the exact completion record, including any removed future blocks.
  Future<String> completeTaskWithUndo(String id) => _serial(() async {
    final current = _requireTask(id);
    if (current.done) {
      throw const RepositoryException('这项任务已经完成。');
    }
    final recordId = newId('change');
    final completed = current.copyWith(
      status: 'done',
      blockedReason: '',
      revision: current.revision + 1,
    );
    await _persistChange(
      '完成任务',
      _terminalCleanup(_replaceTask(data, completed), id),
      recordId: recordId,
    );
    return recordId;
  });

  /// Reverse only this completion; focus time already recorded stays recorded.
  Future<bool> undoTaskCompletion(String recordId) => _serial(() async {
    Never conflict(String message) =>
        throw RepositoryException(message, conflict: true);
    final record = _find(data.history, (item) => item.id == recordId);
    if (record == null ||
        record.label != '完成任务' ||
        record.format != null && !record.isDelta) {
      conflict('这次完成记录已不存在，请重新打开任务。');
    }
    if (record.undone) return false;
    Map<String, Json> entities(Json snapshot, String kind) {
      final raw = snapshot[kind];
      if (raw is! List) conflict('这次完成记录不完整，无法撤销。');
      final values = <String, Json>{};
      for (final item in raw) {
        if (item is! Map ||
            item['id'] is! String ||
            values.containsKey(item['id'])) {
          conflict('这次完成记录不完整，无法撤销。');
        }
        values[item['id'] as String] = Map<String, dynamic>.from(item);
      }
      return values;
    }

    final beforeTasks = entities(record.before, 'tasks');
    final afterTasks = entities(record.after, 'tasks');
    final changedTasks = {...beforeTasks.keys, ...afterTasks.keys}
        .where(
          (id) => jsonEncode(beforeTasks[id]) != jsonEncode(afterTasks[id]),
        )
        .toList();
    if (changedTasks.length != 1) conflict('这次完成记录的范围无法确认。');
    final id = changedTasks.single;
    if (beforeTasks[id] == null || afterTasks[id] == null) {
      conflict('这次完成记录的对象无法确认。');
    }
    final original = SeraTask.fromJson(beforeTasks[id]!);
    final completed = SeraTask.fromJson(afterTasks[id]!);
    final current = task(id);
    if (original.done ||
        !completed.done ||
        current == null ||
        jsonEncode(current.toJson()) != jsonEncode(completed.toJson())) {
      conflict('任务已有后续修改，无法撤销这次完成。');
    }
    final restoredTask = current.copyWith(
      status: original.status,
      blockedReason: original.blockedReason,
      revision: current.revision + 1,
    );
    _validateTask(restoredTask);
    if (restoredTask.status == 'in_progress' &&
        restoredTask.dependencyIds.any(
          (dependency) => task(dependency)?.done != true,
        )) {
      conflict('前置任务状态已改变，无法恢复原执行状态。');
    }
    final beforeEntries = entities(record.before, 'entries');
    final afterEntries = entities(record.after, 'entries');
    final removed = <CalendarEntry>[];
    for (final entryId in {...beforeEntries.keys, ...afterEntries.keys}) {
      if (jsonEncode(beforeEntries[entryId]) ==
          jsonEncode(afterEntries[entryId])) {
        continue;
      }
      final before = beforeEntries[entryId];
      if (before == null ||
          afterEntries[entryId] != null ||
          before['taskId'] != id) {
        conflict('这次完成记录还涉及其他安排，无法单独撤销。');
      }
      if (data.entries.any((entry) => entry.id == entryId)) {
        conflict('原安排已有同名记录，无法直接恢复。');
      }
      // A later local reuse and deletion of the ID must not resurrect it again.
      final index = data.history.indexWhere((item) => item.id == recordId);
      for (final later in data.history.skip(index + 1)) {
        final old = entities(later.before, 'entries')[entryId];
        final updated = entities(later.after, 'entries')[entryId];
        if (jsonEncode(old) != jsonEncode(updated)) {
          conflict('原安排后来有新修改，无法直接恢复。');
        }
      }
      final block = CalendarEntry.fromJson(before);
      removed.add(block.copyWith(revision: block.revision + 1));
    }
    final currentTaskEntries = {
      for (final entry in data.entries.where((entry) => entry.taskId == id))
        entry.id: historyEntityDigest(entry.toJson()),
    };
    final expectedTaskEntries = record.isDelta
        ? record.afterTaskEntries[id]
        : {
            for (final entry in afterEntries.entries)
              if (entry.value['taskId'] == id)
                entry.key: historyEntityDigest(entry.value),
          };
    if (expectedTaskEntries == null) conflict('这次完成记录不完整，无法撤销。');
    if (currentTaskEntries.length != expectedTaskEntries.length ||
        currentTaskEntries.entries.any(
          (entry) => entry.value != expectedTaskEntries[entry.key],
        )) {
      conflict('这项任务的安排已有后续修改，无法直接恢复。');
    }
    var next = _replaceTask(data, restoredTask);
    for (final block in removed) {
      try {
        PlanningService.validatePlacement(block, next);
        _validateTaskWindow(restoredTask, block);
      } on RepositoryException catch (error) {
        conflict('原时段现在无法恢复：${error.message}');
      }
      next = next.copyWith(entries: [...next.entries, block]);
    }
    final history = data.history
        .map((item) => item.id == recordId ? item.copyWith(undone: true) : item)
        .toList();
    data = await repository.save(
      next.copyWith(history: history),
      expectedRevision: data.revision,
    );
    await _afterSave();
    return true;
  });

  Workspace _terminalCleanup(Workspace w, String id) {
    final session = w.focusSession?.taskId == id ? w.focusSession : null;
    var result = w;
    if (session != null) {
      final seconds = session.elapsedSeconds(DateTime.now()).clamp(0, 86400);
      final t = w.tasks.firstWhere((t) => t.id == id);
      result =
          _replaceTask(
            w,
            t.copyWith(actualSeconds: t.actualSeconds + seconds),
          ).copyWith(
            focusRecords: [
              ...w.focusRecords,
              if (seconds > 0)
                FocusRecord(
                  id: session.id,
                  taskId: id,
                  startedAt: session.startedAt,
                  seconds: seconds,
                ),
            ],
          );
    }
    return result.copyWith(
      entries: result.entries
          .where((e) => e.taskId != id || !e.end.isAfter(_planningNow))
          .toList(),
      clearFocusSession: session != null,
    );
  }

  Future<void> setExternalBusyEntries(
    List<CalendarEntry> entries, {
    required String source,
  }) => _mutate('更新外部忙闲', (w) {
    if (source.isEmpty ||
        entries.any((e) => e.id.isEmpty || !e.end.isAfter(e.start))) {
      throw const RepositoryException('外部日历数据无效。');
    }
    final unique = <String, CalendarEntry>{
      for (final e in entries) e.id: e.copyWith(source: source, locked: true),
    };
    return w.copyWith(
      externalBusyEntries: [
        ...w.externalBusyEntries.where((e) => e.source != source),
        ...unique.values,
      ],
    );
  });

  Future<void> importCalendarEntries(List<CalendarEntry> entries) =>
      setExternalBusyEntries(entries, source: 'ics-import');
  Future<void> savePlatformSettings(Json settings) => _mutate(
    '保存连接设置',
    (w) => w.copyWith(platformSettings: {...w.platformSettings, ...settings}),
  );
  Future<void> saveReminderState(
    String id,
    String status, {
    DateTime? snoozeUntil,
    DateTime? scheduledAt,
  }) => _mutate('更新提醒', (w) {
    if (!const [
      'ack',
      'snoozed',
      'scheduled',
      'delivered',
      'expired',
      'canceled',
    ].contains(status)) {
      throw const RepositoryException('提醒状态无效。');
    }
    final separator = id.lastIndexOf(':');
    final block = separator < 0 ? null : entry(id.substring(0, separator));
    final task = block?.taskId == null ? null : this.task(block!.taskId);
    final isFollowup = id.endsWith(':followup');
    final scheduled =
        scheduledAt ??
        (block == null
            ? null
            : isFollowup
            ? block.end.add(const Duration(minutes: 5))
            : block.start.subtract(
                Duration(minutes: task?.reminderMinutes ?? 10),
              ));
    final now = DateTime.now();
    return w.copyWith(
      reminderStates: {
        ...w.reminderStates,
        id: {
          'status': status,
          'at': now.toUtc().toIso8601String(),
          if (scheduled != null)
            'scheduledAt': scheduled.toUtc().toIso8601String(),
          if (status == 'snoozed')
            'snoozeUntil': (snoozeUntil ?? now.add(const Duration(minutes: 10)))
                .toUtc()
                .toIso8601String(),
        },
      },
    );
  });

  PlanningSession? planningSession([String? id]) {
    if (id != null) return _find(data.planningSessions, (s) => s.id == id);
    final all = [...data.planningSessions]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return all.isEmpty ? null : all.first;
  }

  Future<void> savePlanningSession(PlanningSession value) {
    // Save exactly the state the caller confirmed, even if a queued operation
    // awaits disk I/O while the editor continues to change its answer maps.
    final snapshot = PlanningSession.fromJson(
      _understandingSnapshot(value.toJson()),
      displayZone: data.preferences.timeZone,
    );
    return _serial(() async {
      final existing = planningSession(snapshot.id);
      if (existing?.resultEntity != null) {
        final result = snapshot.resultEntity;
        if (result != null &&
            (result.kind != existing!.resultEntity!.kind ||
                result.id != existing.resultEntity!.id)) {
          throw const RepositoryException('这次输入已经保存，不能改写原结果。');
        }
        // A timer or a covered editor may still hold its pre-save snapshot.
        // Completion and its result reference are authoritative.
        return;
      }
      if (snapshot.resultEntity != null) {
        throw const RepositoryException('事项结果必须与任务或日程一起保存。');
      }
      if (existing?.stage == 'confirmed' && snapshot.stage != 'confirmed') {
        return;
      }
      data = await repository.save(
        data.copyWith(
          planningSessions: [
            ...data.planningSessions.where((e) => e.id != snapshot.id),
            snapshot,
          ],
        ),
        expectedRevision: data.revision,
      );
    });
  }

  Future<void> clearPlanningHistory() {
    cancelGeneration();
    return _mutate(
      '清除对话记录',
      (w) => w.copyWith(
        planningSessions: [],
        drafts: w.drafts.where((e) => e.status == 'committed').toList(),
      ),
    );
  }

  Future<void> saveReview(ReviewRecord value) => _mutate(
    '保存回顾',
    (w) => w.copyWith(
      reviews: [...w.reviews.where((e) => e.id != value.id), value],
    ),
  );

  /// One focus uses the current/next valid block, not all work across days.
  /// Existing sessions keep their original target even after midnight or edits.
  int focusTargetMinutes(String taskId) {
    final value = _requireTask(taskId);
    final active = data.focusSession;
    if (active?.taskId == taskId && active?.targetMinutes != null) {
      return active!.targetMinutes!;
    }
    final reference = active?.taskId == taskId
        ? inTimeZone(active!.startedAt, data.preferences.timeZone)
        : _planningNow;
    final day = dateOnly(reference);
    final nextDay = calendarDay(day, 1);
    final available =
        entriesForTask(taskId)
            .where(
              (entry) =>
                  entry.start.isBefore(nextDay) &&
                  entry.end.isAfter(day) &&
                  entry.end.isAfter(reference),
            )
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    final work = value.workMinutes.clamp(1, 1440).toInt();
    if (available.isEmpty) return work;
    final entry = available.first;
    final start = entry.start.isBefore(day) ? day : entry.start;
    final end = entry.end.isAfter(nextDay) ? nextDay : entry.end;
    return end.difference(start).inMinutes.clamp(1, work).toInt();
  }

  Future<void> startFocus(String taskId, {int? targetMinutes}) =>
      _mutate('开始专注', (w) {
        final t = _requireTask(taskId);
        if (!t.active) throw const RepositoryException('这项任务已结束。');
        if (t.dependencyIds.any((id) => task(id)?.done != true)) {
          throw const RepositoryException('请先完成前置任务。');
        }
        if (w.focusSession != null) {
          if (w.focusSession!.taskId == taskId) return null;
          throw const RepositoryException('另一项专注尚未结束，请先处理当前专注。');
        }
        final target = targetMinutes ?? focusTargetMinutes(taskId);
        if (target < 1 || target > 1440) {
          throw const RepositoryException('本次专注时长需在 1 至 1440 分钟之间。');
        }
        final now = DateTime.now();
        return _replaceTask(
          w,
          t.copyWith(status: 'in_progress', revision: t.revision + 1),
        ).copyWith(
          focusSession: FocusSession(
            id: newId('session'),
            taskId: taskId,
            startedAt: now,
            lastResumedAt: now,
            targetMinutes: target,
          ),
        );
      });
  Future<void> pauseFocus() => _mutate('暂停专注', (w) {
    final s = w.focusSession;
    if (s == null || !s.isRunning) return null;
    return w.copyWith(
      focusSession: FocusSession(
        id: s.id,
        taskId: s.taskId,
        startedAt: s.startedAt,
        accumulatedSeconds: s.elapsedSeconds(DateTime.now()),
        isRunning: false,
        targetMinutes: s.targetMinutes,
      ),
    );
  });
  Future<void> resumeFocus() => _mutate('继续专注', (w) {
    final s = w.focusSession;
    if (s == null || s.isRunning) return null;
    return w.copyWith(
      focusSession: FocusSession(
        id: s.id,
        taskId: s.taskId,
        startedAt: s.startedAt,
        lastResumedAt: DateTime.now(),
        accumulatedSeconds: s.accumulatedSeconds,
        targetMinutes: s.targetMinutes,
      ),
    );
  });
  Future<int> finishFocus() => _serial(() async {
    final s = data.focusSession;
    if (s == null) return 0;
    final seconds = s.elapsedSeconds(DateTime.now()).clamp(0, 86400);
    final t = _requireTask(s.taskId);
    final next =
        _replaceTask(
          data,
          t.copyWith(
            actualSeconds: t.actualSeconds + seconds,
            revision: t.revision + 1,
          ),
        ).copyWith(
          clearFocusSession: true,
          focusRecords: [
            ...data.focusRecords,
            if (seconds > 0)
              FocusRecord(
                id: s.id,
                taskId: s.taskId,
                startedAt: s.startedAt,
                seconds: seconds,
              ),
          ],
        );
    await _persistChange('结束专注', next);
    return seconds;
  });

  PlanningSession createTaskRefinementSession(
    String taskId, {
    required String reason,
  }) {
    final original = _requireTask(taskId);
    if (!original.active) {
      throw const RepositoryException('这项任务已经结束，请先查看当前任务状态。');
    }
    return PlanningSession(
      id: newId('planning'),
      updatedAt: DateTime.now(),
      title: original.title,
      prompt: original.title,
      notes: reason,
      deadline: _planningNow.add(const Duration(days: 7)),
      dailyBudget: data.preferences.dailyBudget,
      stage: 'generating',
      aiRequestId: newId('ai-refine'),
      aiRequestNotes: _taskRefinementNotes(original, reason),
      targetTaskId: original.id,
      baseTaskRevision: original.revision,
    );
  }

  String _taskRefinementNotes(SeraTask original, String reason) =>
      '保留原任务，只将执行步骤拆成检查项。当前阻碍：$reason；原完成标准：${original.notes}；剩余估时：${original.workMinutes}分钟。';

  Future<PlanDraft> refineTaskPlan(
    String taskId, {
    required String reason,
    String? requestId,
    String? requestNotes,
    DateTime? requestDeadline,
    int? requestDailyBudget,
    int? expectedTaskRevision,
  }) => _serial(() async {
    final generation = ++_generation;
    generationStage = '拆解执行步骤';
    _notify();
    final original = _requireTask(taskId);
    if (requestId != null && (requestId.isEmpty || requestId.length > 128)) {
      throw const RepositoryException('这次规划记录无效，请重新生成建议。');
    }
    if (expectedTaskRevision != null &&
        original.revision != expectedTaskRevision) {
      throw const RepositoryException(
        '原任务已经修改，请核对当前内容后明确重新生成建议。',
        conflict: true,
        details: {'taskChanged': true},
      );
    }
    if (!original.active) {
      throw const RepositoryException('这项任务已经结束，请先查看当前任务状态。');
    }
    if (requestId != null) {
      final saved = _find(data.drafts, (d) => d.aiRequestId == requestId);
      if (saved != null) return saved;
    }
    final provider = repository;
    if (provider is! PlanningAiProvider) {
      throw const RepositoryException('需要连接 AI 服务才能生成拆解建议。');
    }
    final result = await (provider as PlanningAiProvider).generateTaskBreakdown(
      title: original.title,
      deadline: requestDeadline ?? _planningNow.add(const Duration(days: 7)),
      dailyBudget: requestDailyBudget ?? data.preferences.dailyBudget,
      notes: requestNotes ?? _taskRefinementNotes(original, reason),
      prompt: original.title,
      requestId: requestId,
    );
    if (generation != _generation || _disposed) {
      throw const RepositoryException('已停止生成，输入已保留。');
    }
    if (task(taskId)?.revision != original.revision) {
      throw const RepositoryException('任务已有新修改，请重新检查。', conflict: true);
    }
    final checklist = result.tasks.map((e) => e.title).toSet().toList();
    if (checklist.isEmpty) throw const RepositoryException('没有获得可用的执行步骤。');
    final suggested = original.copyWith(
      checklist: checklist,
      completedChecks: [],
      splittable: true,
      minBlockMinutes: 15,
      status: 'todo',
      blockedReason: '',
    );
    final existing = entriesForTask(taskId);
    final plan = PlanDraft(
      id: newId('draft'),
      goal:
          goal(original.goalId) ??
          SeraGoal(
            id: 'task-refinement:$taskId',
            title: original.title,
            deadline:
                original.deadline ?? _planningNow.add(const Duration(days: 7)),
          ),
      items: [
        PlannedTask(
          task: suggested,
          entry: existing.firstOrNull,
          additionalEntries: existing.skip(1).toList(),
        ),
      ],
      source: result.source,
      model: result.model,
      prompt: reason,
      aiRequestId: requestId,
      targetTaskId: taskId,
      baseRevision: data.revision,
      baseTaskVersions: {taskId: original.revision},
    );
    await _persistChange(
      '生成任务拆解建议',
      data.copyWith(drafts: [...data.drafts, plan]),
    );
    return plan;
  });

  Future<PlanDraft> editGoalPlan(String goalId) => _serial(() async {
    final g = goal(goalId);
    if (g == null) throw const RepositoryException('目标已不存在。');
    final confirmedBudget = data.drafts
        .where(
          (draft) =>
              draft.goal.id == goalId &&
              draft.status == 'committed' &&
              draft.budgetOverrideConfirmed,
        )
        .lastOrNull;
    final confirmedCapacity = data.drafts
        .where(
          (draft) =>
              draft.goal.id == goalId &&
              draft.status == 'committed' &&
              draft.capacityLimited &&
              draft.capacityConfirmed,
        )
        .lastOrNull;
    final currentItems = tasksForGoal(g.id).map((t) {
      final blocks = entriesForTask(t.id);
      return PlannedTask(
        task: t,
        entry: blocks.firstOrNull,
        additionalEntries: blocks.skip(1).toList(),
      );
    }).toList();
    final plan = PlanDraft(
      id: newId('draft'),
      goal: g,
      targetGoalId: g.id,
      baseRevision: data.revision,
      validationRevision: data.revision,
      source: 'existing-plan',
      originalDailyBudget: confirmedBudget?.originalDailyBudget,
      suggestedDailyBudget: confirmedBudget?.suggestedDailyBudget,
      budgetOverrideConfirmed: confirmedBudget != null,
      capacityLimited: confirmedCapacity != null,
      capacityConfirmed:
          confirmedCapacity?.copyWith(items: currentItems).capacityConfirmed ??
          false,
      baseTaskVersions: {for (final t in tasksForGoal(g.id)) t.id: t.revision},
      calendarFingerprint: _calendarFingerprint(data, targetGoalId: g.id),
      items: currentItems,
    );
    await _persistChange(
      '编辑目标计划',
      data.copyWith(drafts: [...data.drafts, plan]),
    );
    return plan;
  });

  Future<void> reorderDraftItems(String id, List<String> ids) =>
      _mutate('调整草案顺序', (w) {
        final p = _requireDraft(id);
        if (ids.toSet().length != p.items.length ||
            !p.items.every((e) => ids.contains(e.task.id))) {
          throw const RepositoryException('任务顺序无效。');
        }
        return w.copyWith(
          drafts: w.drafts
              .map(
                (e) => e.id == id
                    ? p.copyWith(
                        items: ids
                            .map(
                              (id) =>
                                  p.items.firstWhere((e) => e.task.id == id),
                            )
                            .toList(),
                      )
                    : e,
              )
              .toList(),
        );
      });

  Future<void> revalidateDraft(String id) async {
    await _serial(() => _refreshExternal(_requireDraft(id).goal.deadline));
    await _mutate('重新检查草案', (w) {
      final p = _requireDraft(id);
      final occupied = [
        ...w.entries.where(
          (e) =>
              p.targetGoalId == null ||
              !p.items.any((i) => i.task.id == e.taskId),
        ),
        ...w.externalBusyEntries,
      ];
      final items = <PlannedTask>[];
      var cursor = _planningNow;
      var waitingForTime = false;
      for (final item in p.items) {
        if (!item.task.active) {
          items.add(item);
          occupied.addAll(item.blocks);
          continue;
        }
        if (waitingForTime) {
          if (item.blocks.any((block) => block.locked)) {
            throw const RepositoryException(
              '锁定安排与新日历冲突，请先手动确认。',
              conflict: true,
            );
          }
          items.add(PlannedTask(task: item.task));
          continue;
        }
        final preserved = item.blocks;
        var valid = preserved.isNotEmpty;
        final checked = [...occupied];
        for (final block in preserved) {
          try {
            PlanningService.validatePlacement(
              block,
              w,
              occupied: checked,
              applyPreferences: true,
              dailyBudgetOverride: p.suggestedDailyBudget,
            );
            _validateTaskWindow(item.task, block, deadline: p.goal.deadline);
            if (block.start.isBefore(cursor)) valid = false;
          } on RepositoryException {
            valid = false;
          }
          checked.add(block);
        }
        if (valid) {
          items.add(item);
          occupied.addAll(preserved);
          cursor = preserved.last.end;
          continue;
        }
        if (preserved.any((e) => e.locked)) {
          throw const RepositoryException('锁定安排与新日历冲突，请先手动确认。', conflict: true);
        }
        final blocks = _planner.findSlots(
          workspace: w,
          today: cursor,
          deadline: p.goal.deadline,
          task: item.task,
          dailyBudget: w.preferences.dailyBudget,
          dailyBudgetOverride: p.suggestedDailyBudget,
          occupied: occupied,
          newId: newId,
        );
        if (blocks.isEmpty) {
          waitingForTime = true;
          items.add(PlannedTask(task: item.task));
          continue;
        }
        items.add(
          PlannedTask(
            task: item.task,
            entry: blocks.first,
            additionalEntries: blocks.skip(1).toList(),
          ),
        );
        occupied.addAll(blocks);
        cursor = blocks.last.end;
      }
      return w.copyWith(
        drafts: w.drafts
            .map(
              (e) => e.id == id
                  ? p.copyWith(
                      items: items,
                      capacityLimited: p.capacityLimited || waitingForTime,
                      validationRevision: w.revision,
                      calendarFingerprint: _calendarFingerprint(
                        w,
                        targetGoalId: p.targetGoalId,
                      ),
                    )
                  : e,
            )
            .toList(),
      );
    });
  }
}
