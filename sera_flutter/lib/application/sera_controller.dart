import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';

import '../data/workspace_repository.dart';
import '../data/planning_ai_provider.dart';
import '../domain/models.dart';
import '../domain/change_history.dart';
import '../domain/planning_service.dart';
import '../domain/seed_data.dart';

part 'controller_features.dart';

class SeraController extends ChangeNotifier {
  SeraController({
    required this.repository,
    DateTime? today,
    this.accountId = 'local',
    this.seedDemo = true,
    this.onWorkspaceSaved,
    this.onBeforePlanning,
  }) : _clockOverride = today,
       today = dateOnly(today ?? DateTime.now()),
       selectedDate = dateOnly(today ?? DateTime.now()) {
    if (repository case LocalWorkspaceCache cache) {
      _cacheSubscription = cache.localChanges.listen(
        (_) => _queueLocalRefresh(),
      );
    }
  }

  final WorkspaceRepository repository;
  final String accountId;
  final bool seedDemo;
  final Future<void> Function(Workspace)? onWorkspaceSaved;
  final Future<Workspace> Function(Workspace, DateTime)? onBeforePlanning;
  bool _disposed = false;
  StreamSubscription<void>? _cacheSubscription;
  bool _cacheRefreshQueued = false;
  Workspace? _pendingPlatformWorkspace;
  Future<void>? _platformWork;
  String? platformError;
  int _generation = 0;
  String generationStage = '';
  int _understandingGeneration = 0;
  bool understanding = false;
  String understandingStage = '';
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_cacheSubscription?.cancel());
    _pendingPlatformWorkspace = null;
    cancelGeneration();
    super.dispose();
  }

  final DateTime? _clockOverride;
  DateTime get planningNow => _planningNow;
  DateTime get _planningNow => inTimeZone(
    _clockOverride ?? DateTime.now(),
    data.preferences.timeZone,
    wallClock: _clockOverride != null,
  );
  DateTime today;
  DateTime selectedDate;
  Workspace data = const Workspace();
  bool loading = true, busy = false;
  String? error;
  String get mode => repository.mode;
  bool get usesRemoteAi => repository is PlanningAiProvider;
  bool get canUnderstandInput => repository is InputUnderstandingProvider;

  Json createUnderstandingInput({
    required String prompt,
    String notes = '',
    Json? previous,
  }) {
    final now = _planningNow;
    final offset = now.timeZoneOffset;
    final absoluteMinutes = offset.inMinutes.abs();
    final suffix =
        '${offset.isNegative ? '-' : '+'}'
        '${(absoluteMinutes ~/ 60).toString().padLeft(2, '0')}:'
        '${(absoluteMinutes % 60).toString().padLeft(2, '0')}';
    // UTC construction keeps wall-clock fields independent of the device's
    // timezone (including a device DST gap). The selected zone supplies offset.
    final wall = DateTime.utc(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute,
      now.second,
      now.millisecond,
      now.microsecond,
    ).toIso8601String().replaceFirst(RegExp(r'Z$'), '');
    return {
      'prompt': prompt,
      'referenceNow': '$wall$suffix',
      'timeZone': data.preferences.timeZone,
      'dailyBudget': data.preferences.dailyBudget,
      'notes': notes,
      if (previous != null) 'previous': _understandingSnapshot(previous),
    };
  }

  Json _understandingSnapshot(Json value) {
    try {
      return Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
    } catch (_) {
      throw const RepositoryException('理解请求内容无效，请重新填写。');
    }
  }

  void _validateUnderstandingInput(Json input, String requestId) {
    final prompt = input['prompt'];
    if (prompt is! String || prompt.trim().isEmpty || prompt.length > 10000) {
      throw const RepositoryException('请填写 1 至 10000 字的描述。');
    }
    if (requestId.trim().isEmpty || requestId.length > 128) {
      throw const RepositoryException('这次理解记录无效，请重新提交。');
    }
    final notes = input['notes'];
    final reference = input['referenceNow'];
    final zone = input['timeZone'];
    final budget = input['dailyBudget'];
    final previous = input['previous'];
    if (notes != null && (notes is! String || notes.length > 10000) ||
        reference is! String ||
        !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(reference) ||
        DateTime.tryParse(reference) == null ||
        zone is! String ||
        zone.isEmpty ||
        zone.length > 100 ||
        budget is! int ||
        budget < 15 ||
        budget > 480 ||
        previous != null &&
            (previous is! Map || jsonEncode(previous).length > 16000)) {
      throw const RepositoryException('请检查理解请求的时间、时区和投入预算。');
    }
    try {
      userLocation(zone);
    } catch (_) {
      throw const RepositoryException('请选择有效的规划时区。');
    }
  }

  RepositoryException get _understandingCanceled => const RepositoryException(
    '已取消理解，输入已保留。',
    details: {'jobStatus': 'canceled'},
  );

  Future<AiUnderstanding> understandInput({
    required Json input,
    required String requestId,
  }) async {
    if (_disposed) throw const RepositoryException('当前工作区已关闭。');
    if (understanding || busy) throw const RepositoryException('请等待当前操作完成。');
    final provider = repository;
    if (provider is! InputUnderstandingProvider) {
      throw const RepositoryException('当前未连接在线 AI，请稍后再试，或手动添加任务。');
    }
    // Freeze the submitted context before the first await. UI edits must not
    // change an in-flight or idempotently retried request's JSON payload.
    final snapshot = _understandingSnapshot(input);
    _validateUnderstandingInput(snapshot, requestId);
    final generation = ++_understandingGeneration;
    understanding = true;
    understandingStage = '正在提交理解请求';
    _notify();
    try {
      final result = await (provider as InputUnderstandingProvider)
          .understandInput(
            input: snapshot,
            requestId: requestId,
            onStage: (stage) {
              if (_disposed || generation != _understandingGeneration) return;
              understandingStage = stage;
              _notify();
            },
          );
      if (_disposed || generation != _understandingGeneration) {
        throw _understandingCanceled;
      }
      return result;
    } catch (failure) {
      if (_disposed || generation != _understandingGeneration) {
        throw _understandingCanceled;
      }
      if (failure is RepositoryException) rethrow;
      throw const RepositoryException('AI 理解未能完成，输入已保留，请稍后重试。');
    } finally {
      if (generation == _understandingGeneration) {
        understanding = false;
        understandingStage = '';
        _notify();
      }
    }
  }

  void cancelUnderstanding() {
    _understandingGeneration++;
    if (understanding) {
      if (repository case CancellableInputUnderstandingProvider provider) {
        provider.cancelUnderstanding();
      }
    }
    understanding = false;
    understandingStage = '';
    _notify();
  }

  String get planningMode =>
      usesRemoteAi ? 'SiliconFlow AI 拆解 · 本地约束排期' : '本地模板拆解 · 本地约束排期';
  Future<void> _tail = Future<void>.value();
  Future<void>? _initialization;
  var _counter = 0;
  final _planner = const PlanningService();

  String newId(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}-${_counter++}';
  T? _find<T>(Iterable<T> values, bool Function(T) match) {
    for (final value in values) {
      if (match(value)) return value;
    }
    return null;
  }

  SeraTask? task(String? id) => _find(data.tasks, (e) => e.id == id);
  CalendarEntry? entry(String? id) =>
      _find([...data.entries, ...data.externalBusyEntries], (e) => e.id == id);
  List<CalendarEntry> entriesForTask(String id) =>
      data.entries.where((e) => e.taskId == id).toList()
        ..sort((a, b) => a.start.compareTo(b.start));
  String schedulingState(String id) {
    final t = task(id);
    if (t == null) return 'unplanned';
    final m = entriesForTask(id).fold<int>(0, (s, e) => s + e.minutes);
    return m == 0
        ? 'unplanned'
        : m < t.workMinutes
        ? 'partial'
        : 'planned';
  }

  CalendarEntry? entryForTask(String id) =>
      _find(data.entries, (e) => e.taskId == id);
  SeraGoal? goal(String? id) => _find(data.goals, (e) => e.id == id);
  PlanDraft? draft(String? id) => _find(data.drafts, (e) => e.id == id);
  List<SeraTask> tasksForGoal(String id) =>
      data.tasks.where((e) => e.goalId == id).toList();
  List<CalendarEntry> entriesOn(DateTime date) =>
      [...data.entries, ...data.externalBusyEntries]
          .where(
            (e) =>
                e.start.isBefore(calendarDay(date, 1)) &&
                e.end.isAfter(dateOnly(date)),
          )
          .toList()
        ..sort((a, b) => a.start.compareTo(b.start));
  void setSelectedDate(DateTime date) {
    selectedDate = dateOnly(date);
    _notify();
  }

  Future<T> _serial<T>(Future<T> Function() action, {bool foreground = true}) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      if (_disposed) {
        completer.completeError(const RepositoryException('当前工作区已关闭。'));
        return;
      }
      if (foreground) {
        busy = true;
        error = null;
        _notify();
      }
      try {
        completer.complete(await action());
      } catch (e, stack) {
        final failure = e is RepositoryException
            ? e
            : const RepositoryException('操作未能保存，请稍后重试。');
        if (foreground) error = failure.message;
        completer.completeError(failure, stack);
      } finally {
        if (foreground) busy = false;
        _notify();
      }
    });
    return completer.future;
  }

  Future<void> initialize() => _initialization ??= _serial(() async {
    try {
      final cached = repository is LocalWorkspaceCache
          ? await (repository as LocalWorkspaceCache).loadLocal()
          : null;
      final existing = cached ?? await repository.load();
      if (_disposed) throw const RepositoryException('当前工作区已关闭。');
      data =
          existing ??
          await repository.save(
            seedDemo ? createSeedWorkspace(today) : const Workspace(),
            expectedRevision: 0,
          );
      today = dateOnly(_planningNow);
      selectedDate = today;
      await _afterSave();
      if (cached != null) {
        unawaited(refresh().catchError((Object _) {}));
      }
    } finally {
      loading = false;
    }
  });

  void _queueLocalRefresh() {
    if (_disposed || _cacheRefreshQueued || loading) return;
    _cacheRefreshQueued = true;
    unawaited(
      _serial(() async {
        _cacheRefreshQueued = false;
        if (repository case LocalWorkspaceCache cache) {
          await _adoptWorkspace(await cache.loadLocal());
        }
      }, foreground: false).catchError((Object _) {
        _cacheRefreshQueued = false;
      }),
    );
  }

  Future<void> refresh() async {
    if (repository is LocalWorkspaceCache &&
        repository is SynchronizingWorkspaceRepository) {
      // Network work runs outside the foreground mutation queue. The final
      // adoption reads the newest local projection inside that queue.
      await repository.load();
      if (_disposed) return;
      await _serial(() async {
        await _adoptWorkspace(
          await (repository as LocalWorkspaceCache).loadLocal(),
        );
      }, foreground: false);
      return;
    }
    await _serial(() async => _adoptWorkspace(await repository.load()));
  }

  Future<void> _adoptWorkspace(Workspace? existing) async {
    if (_disposed) throw const RepositoryException('当前工作区已关闭。');
    final next = existing ?? const Workspace();
    String platformContent(Workspace w) => jsonEncode(
      w.toJson()
        ..remove('revision')
        ..remove('entityVersions')
        ..remove('history')
        ..remove('planningSessions'),
    );
    final changed = platformContent(data) != platformContent(next);
    data = next;
    loading = false;
    today = dateOnly(_planningNow);
    // A read-only sign-in or a remote edit must rebuild device reminders and
    // calendar state too. Unchanged polling does not repeat successful work.
    if (changed || platformError != null) await _afterSave();
  }

  Future<void> _mutate(String label, Workspace? Function(Workspace) action) =>
      _serial(() async {
        final next = action(data);
        if (next == null) return;
        await _persistChange(label, next);
      });

  /// Runs a device import in the same queue and CAS/history boundary as normal
  /// edits. The caller's owner guard prevents a delayed sign-in from adopting
  /// state or starting platform effects after an account switch.
  Future<Workspace> mergeDeviceRecords(
    Workspace? Function(Workspace current) merge, {
    required bool Function() isCurrent,
  }) => _serial(() async {
    void requireCurrent() {
      if (_disposed || !isCurrent()) {
        throw const RepositoryException('账号已变化，原同步操作已停止。');
      }
    }

    requireCurrent();
    final current = repository is LocalWorkspaceCache
        ? await (repository as LocalWorkspaceCache).loadLocal() ?? data
        : data;
    requireCurrent();
    final next = merge(current);
    if (next == null) return current;
    final record = createCompactChange(
      id: newId('change'),
      label: '同步本机记录',
      at: DateTime.now(),
      before: current,
      after: next,
    );
    final history = [...current.history.map(compactLegacyChange), record];
    if (history.length > 30) history.removeRange(0, history.length - 30);
    requireCurrent();
    final saved = await repository.save(
      next.copyWith(history: history),
      expectedRevision: current.revision,
    );
    requireCurrent();
    data = saved;
    await _afterSave();
    return saved;
  });

  Future<void> _persistChange(
    String label,
    Workspace next, {
    String? recordId,
  }) async {
    final record = createCompactChange(
      id: recordId ?? newId('change'),
      label: label,
      at: DateTime.now(),
      before: data,
      after: next,
    );
    final history = [...data.history.map(compactLegacyChange), record];
    // Snapshot history is intentionally bounded to avoid unbounded storage.
    if (history.length > 30) history.removeRange(0, history.length - 30);
    data = await repository.save(
      next.copyWith(history: history),
      expectedRevision: data.revision,
    );
    await _afterSave();
  }

  void _validateTask(SeraTask value) {
    _validateDependencies(value, [
      ...data.tasks,
      ...data.drafts.expand((p) => p.items.map((i) => i.task)),
    ]);
    if (value.id.isEmpty ||
        value.title.trim().isEmpty ||
        value.title.length > 200 ||
        value.phase.length > 100 ||
        (value.notBefore != null &&
            value.deadline != null &&
            !value.deadline!.isAfter(value.notBefore!)) ||
        value.estimatedMinutes < 1 ||
        value.estimatedMinutes > 1440 ||
        value.actualSeconds < 0 ||
        !const [
          'todo',
          'in_progress',
          'blocked',
          'done',
          'canceled',
        ].contains(value.status) ||
        !const ['high', 'normal', 'low'].contains(value.priority) ||
        value.minBlockMinutes < 5 ||
        value.minBlockMinutes > 240 ||
        value.remainingMinutes < -1 ||
        value.remainingMinutes > 1440 ||
        value.reminderMinutes < -1 ||
        value.reminderMinutes > 10080 ||
        value.checklist.toSet().length != value.checklist.length ||
        value.completedChecks.any((e) => !value.checklist.contains(e))) {
      throw const RepositoryException('任务内容无效，请检查名称、时长、提醒与检查清单。');
    }
  }

  void _validateTaskWindow(
    SeraTask value,
    CalendarEntry block, {
    DateTime? deadline,
  }) {
    if (value.notBefore != null && block.start.isBefore(value.notBefore!)) {
      throw const RepositoryException('安排不能早于阶段开始时间。');
    }
    if ((value.deadline != null && block.end.isAfter(value.deadline!)) ||
        (deadline != null && block.end.isAfter(deadline))) {
      throw const RepositoryException('安排不能晚于截止时间。');
    }
  }

  void _checkTaskRevision(SeraTask value, SeraTask? previous) {
    if (previous != null && value.revision != previous.revision) {
      throw const RepositoryException('这项任务已有新修改，请重新打开后编辑。', conflict: true);
    }
  }

  void _checkEntryRevision(CalendarEntry value, CalendarEntry? previous) {
    if (previous != null && value.revision != previous.revision) {
      throw const RepositoryException('这项日程已有新修改，请刷新后重试。', conflict: true);
    }
  }

  PlanningResultRef planningResultFor(String sessionId, String kind) {
    if (!const ['task', 'event'].contains(kind)) {
      throw const RepositoryException('这次输入的事项类型无效。');
    }
    final session = planningSession(sessionId);
    if (session == null) {
      throw const RepositoryException('这次输入记录已不存在，请开始新的输入。');
    }
    final existing = session.resultEntity;
    if (existing != null) {
      if (existing.kind != kind) {
        throw const RepositoryException('这次输入已保存为其他类型，请开始新的输入。');
      }
      return existing;
    }
    if (session.stage == 'confirmed') {
      throw const RepositoryException('这次输入已经确认，请开始新的输入。');
    }
    return PlanningResultRef(
      kind: kind,
      id: 'planning-$kind-${sha256.convert(utf8.encode(sessionId))}',
    );
  }

  bool hasPlanningResult(PlanningResultRef ref) => ref.kind == 'task'
      ? task(ref.id) != null
      : ref.kind == 'event' && entry(ref.id) != null;

  Workspace _confirmPlanningResult(
    Workspace next,
    String? sessionId,
    PlanningResultRef ref,
  ) {
    if (sessionId == null) return next;
    return next.copyWith(
      planningSessions: [
        for (final session in next.planningSessions)
          if (session.id == sessionId)
            session.copyWith(
              stage: 'confirmed',
              resultEntity: ref,
              updatedAt: DateTime.now(),
            )
          else
            session,
      ],
    );
  }

  Future<PlanningResultRef> _savePlanningEntity({
    required String kind,
    required String id,
    required String? sourceSessionId,
    required Workspace Function(Workspace, PlanningResultRef) update,
  }) => _serial(() async {
    final ref = sourceSessionId == null
        ? PlanningResultRef(kind: kind, id: id)
        : planningResultFor(sourceSessionId, kind);
    if (sourceSessionId != null) {
      if (planningSession(sourceSessionId)!.resultEntity != null) {
        if (!hasPlanningResult(ref)) {
          throw RepositoryException(
            '已保存的${kind == 'task' ? '任务' : '日程'}已删除，请开始新的输入。',
          );
        }
        return ref;
      }
      if (hasPlanningResult(ref)) {
        throw const RepositoryException(
          '这次输入的结果标识已存在，请重新打开记录。',
          conflict: true,
        );
      }
    }
    final next = update(data, ref);
    await _persistChange(
      kind == 'task' ? '保存任务' : '保存日程',
      _confirmPlanningResult(next, sourceSessionId, ref),
    );
    return ref;
  });

  Future<PlanningResultRef> saveTask(
    SeraTask value, {
    CalendarEntry? entry,
    bool removeEntry = false,
    bool autoSchedule = false,
    List<CalendarEntry>? blocks,
    String? sourceSessionId,
  }) => _savePlanningEntity(
    kind: 'task',
    id: value.id,
    sourceSessionId: sourceSessionId,
    update: (w, ref) {
      if (sourceSessionId != null &&
          (entry != null && entry.taskId != value.id ||
              blocks?.any((block) => block.taskId != value.id) == true)) {
        throw const RepositoryException('时间块关联无效。');
      }
      final task = ref.id == value.id
          ? value
          : SeraTask.fromJson({
              ...value.toJson(),
              'id': ref.id,
            }, displayZone: w.preferences.timeZone);
      CalendarEntry normalize(CalendarEntry item) => ref.id == value.id
          ? item
          : CalendarEntry.fromJson({
              ...item.toJson(),
              'taskId': ref.id,
            }, displayZone: w.preferences.timeZone);
      return _saveTaskWorkspace(
        w,
        task,
        entry: entry == null ? null : normalize(entry),
        removeEntry: removeEntry,
        autoSchedule: autoSchedule,
        blocks: blocks?.map(normalize).toList(),
      );
    },
  );

  Workspace _saveTaskWorkspace(
    Workspace w,
    SeraTask value, {
    CalendarEntry? entry,
    bool removeEntry = false,
    bool autoSchedule = false,
    List<CalendarEntry>? blocks,
  }) {
    _validateTask(value);
    final previous = task(value.id);
    _checkTaskRevision(value, previous);
    if (value.goalId != null && goal(value.goalId) == null) {
      throw const RepositoryException('关联目标不存在。');
    }
    final saved = value.copyWith(
      title: value.title.trim(),
      revision: (previous?.revision ?? 0) + 1,
    );
    var entries = [...w.entries];
    if (blocks != null) {
      if (entry != null || autoSchedule) {
        throw const RepositoryException('请选择手动时间块或自动排期。');
      }
      if (blocks.map((e) => e.id).toSet().length != blocks.length ||
          blocks.any((e) => e.taskId != value.id)) {
        throw const RepositoryException('时间块关联无效。');
      }
      final future = blocks.where((e) => e.end.isAfter(_planningNow)).toList();
      if (future.length > 1 && !saved.splittable ||
          future.length > 1 &&
              future.any((e) => e.minutes < saved.minBlockMinutes) ||
          future.fold<int>(0, (sum, e) => sum + e.minutes) >
              saved.workMinutes) {
        throw const RepositoryException('请核对分段限制、最短时长和剩余工作量。');
      }
      final occupied = [
        ...w.entries.where((e) => e.taskId != value.id),
        ...w.externalBusyEntries,
      ];
      final normalized = <CalendarEntry>[];
      for (final block in blocks) {
        final old = this.entry(block.id);
        _checkEntryRevision(block, old);
        PlanningService.validatePlacement(block, w, occupied: occupied);
        _validateTaskWindow(saved, block);
        final next = block.copyWith(
          title: saved.title,
          revision: (old?.revision ?? 0) + 1,
        );
        normalized.add(next);
        occupied.add(next);
      }
      final result = w.copyWith(
        tasks: [...w.tasks.where((e) => e.id != saved.id), saved],
        entries: [
          ...w.entries.where((e) => e.taskId != saved.id),
          ...normalized,
        ],
        goals: w.goals.map((g) {
          final ids = [...g.taskIds]..remove(saved.id);
          if (saved.goalId == g.id) ids.add(saved.id);
          return g.copyWith(taskIds: ids);
        }).toList(),
      );
      return saved.active ? result : _terminalCleanup(result, saved.id);
    }
    if (removeEntry) entries.removeWhere((e) => e.taskId == value.id);
    if (autoSchedule) {
      final blocks = _planner.findSlots(
        workspace: w.copyWith(
          tasks: [...w.tasks.where((e) => e.id != saved.id), saved],
        ),
        today: _planningNow,
        deadline: saved.deadline ?? today.add(const Duration(days: 30)),
        task: saved,
        dailyBudget: w.preferences.dailyBudget,
        occupied: [
          ...w.entries.where((e) => e.taskId != value.id),
          ...w.externalBusyEntries,
        ],
        newId: newId,
      );
      if (blocks.isEmpty) {
        throw const RepositoryException('截止前没有可用时段，任务尚未保存。请延后截止或改为收件箱。');
      }
      entries.removeWhere((e) => e.taskId == value.id);
      entries.addAll(blocks);
    } else {
      final existing = entriesForTask(value.id);
      final block =
          entry ??
          (removeEntry || existing.length != 1
              ? null
              : existing.single.copyWith(
                  title: saved.title,
                  end: existing.single.start.add(
                    Duration(minutes: saved.workMinutes),
                  ),
                ));
      if (block != null) {
        if (block.taskId != value.id) {
          throw const RepositoryException('日程与任务关联不正确。');
        }
        final old = this.entry(block.id);
        _checkEntryRevision(block, old);
        PlanningService.validatePlacement(
          block,
          w,
          occupied: [
            ...entries.where((e) => e.id != block.id),
            ...w.externalBusyEntries,
          ],
        );
        _validateTaskWindow(saved, block);
        entries.removeWhere((e) => e.id == block.id);
        entries.add(
          block.copyWith(
            title: saved.title,
            revision: (old?.revision ?? 0) + 1,
          ),
        );
      }
      entries = entries
          .map((e) => e.taskId == saved.id ? e.copyWith(title: saved.title) : e)
          .toList();
    }
    if (saved.active) {
      for (final block in entries.where(
        (entry) => entry.taskId == saved.id && entry.end.isAfter(_planningNow),
      )) {
        _validateTaskWindow(saved, block);
      }
    }
    final goals = w.goals.map((g) {
      final ids = [...g.taskIds]..remove(value.id);
      if (saved.goalId == g.id) ids.add(value.id);
      return g.copyWith(taskIds: ids);
    }).toList();
    final next = w.copyWith(
      tasks: [...w.tasks.where((e) => e.id != saved.id), saved],
      entries: entries,
      goals: goals,
    );
    return saved.active ? next : _terminalCleanup(next, saved.id);
  }

  Future<PlanningResultRef> saveEntry(
    CalendarEntry value, {
    String? sourceSessionId,
  }) => _savePlanningEntity(
    kind: 'event',
    id: value.id,
    sourceSessionId: sourceSessionId,
    update: (w, ref) {
      if (sourceSessionId != null && value.taskId != null) {
        throw const RepositoryException('固定日程不能作为任务时间块保存。');
      }
      return _saveEntryWorkspace(
        w,
        ref.id == value.id
            ? value
            : CalendarEntry.fromJson({
                ...value.toJson(),
                'id': ref.id,
              }, displayZone: w.preferences.timeZone),
      );
    },
  );

  Workspace _saveEntryWorkspace(Workspace w, CalendarEntry value) {
    final previous = entry(value.id);
    _checkEntryRevision(value, previous);
    if (value.taskId != null && task(value.taskId) == null) {
      throw const RepositoryException('关联任务不存在。');
    }
    PlanningService.validatePlacement(value, w);
    final linked = task(value.taskId);
    if (linked != null) _validateTaskWindow(linked, value);
    return w.copyWith(
      entries: [
        ...w.entries.where((e) => e.id != value.id),
        value.copyWith(
          title: value.title.trim(),
          revision: (previous?.revision ?? 0) + 1,
        ),
      ],
    );
  }

  Future<void> deleteTask(String id) => _mutate('删除任务', (w) {
    if (task(id) == null) throw const RepositoryException('任务已不存在。');
    return w.copyWith(
      clearFocusSession: w.focusSession?.taskId == id,
      tasks: w.tasks
          .where((e) => e.id != id)
          .map(
            (e) => e.copyWith(
              dependencyIds: e.dependencyIds.where((d) => d != id).toList(),
            ),
          )
          .toList(),
      entries: w.entries.where((e) => e.taskId != id).toList(),
      focusRecords: w.focusRecords.where((e) => e.taskId != id).toList(),
      drafts: w.drafts.where((d) => d.targetTaskId != id).toList(),
      goals: w.goals
          .map(
            (g) =>
                g.copyWith(taskIds: g.taskIds.where((e) => e != id).toList()),
          )
          .toList(),
    );
  });

  Future<void> deleteEntry(String id) => _mutate('删除日程', (w) {
    if (entry(id) == null) throw const RepositoryException('日程已不存在。');
    return w.copyWith(entries: w.entries.where((e) => e.id != id).toList());
  });

  SeraTask _requireTask(String id) =>
      task(id) ?? (throw const RepositoryException('任务已不存在，请返回列表刷新。'));
  PlanDraft _requireDraft(String id) =>
      draft(id) ?? (throw const RepositoryException('草案不存在，请重新生成。'));
  Workspace _replaceTask(Workspace w, SeraTask value) => w.copyWith(
    tasks: w.tasks.map((e) => e.id == value.id ? value : e).toList(),
  );

  Future<void> setDone(String id, bool done) =>
      setTaskStatus(id, done ? 'done' : 'todo');

  Future<void> setCheck(String id, String check, bool done) =>
      _mutate('更新检查项', (w) {
        final value = _requireTask(id);
        if (!value.checklist.contains(check)) {
          throw const RepositoryException('检查项不存在。');
        }
        final checks = [...value.completedChecks]..remove(check);
        if (done) checks.add(check);
        return _replaceTask(
          w,
          value.copyWith(completedChecks: checks, revision: value.revision + 1),
        );
      });

  Future<void> setReminder(String id, int minutes) => _mutate('设置提醒', (w) {
    final value = _requireTask(id).copyWith(reminderMinutes: minutes);
    _validateTask(value);
    return _replaceTask(w, value.copyWith(revision: value.revision + 1));
  });

  Future<void> savePreferences(SeraPreferences value) async {
    await _mutate('保存规划偏好', (w) {
      PlanningService.validatePreferences(value);
      return Workspace.fromJson(w.copyWith(preferences: value).toJson());
    });
    today = dateOnly(_planningNow);
    selectedDate = today;
    _notify();
  }

  Future<PlanDraft> generatePlan({
    required String title,
    required DateTime deadline,
    required int dailyBudget,
    String notes = '',
    String prompt = '',
    String? requestId,
    String? requestNotes,
  }) => _serial(() async {
    if (requestId != null) {
      if (requestId.isEmpty || requestId.length > 128) {
        throw const RepositoryException('这次规划记录无效，请重新确认目标。');
      }
      final saved = _find(data.drafts, (d) => d.aiRequestId == requestId);
      if (saved != null) return saved;
    }
    if (title.trim().isEmpty ||
        title.length > 200 ||
        deadline.isBefore(_planningNow) ||
        deadline.difference(dateOnly(_planningNow)).inDays > 366 ||
        dailyBudget < 15 ||
        dailyBudget > 480) {
      throw const RepositoryException('请检查目标名称、未来一年内的截止时间与每日投入（15 至 480 分钟）。');
    }
    PlanningService.validatePreferences(data.preferences);
    await _refreshExternal(deadline);
    final generation = ++_generation;
    generationStage = '理解目标并拆解任务';
    _notify();
    final provider = repository;
    final ai = provider is PlanningAiProvider
        ? await (provider as PlanningAiProvider).generateTaskBreakdown(
            title: title,
            deadline: deadline,
            dailyBudget: dailyBudget,
            notes: requestNotes ?? planningRequestNotes(notes),
            prompt: prompt,
            requestId: requestId,
          )
        : null;
    if (generation != _generation || _disposed) {
      throw const RepositoryException('已停止生成，输入已保留。');
    }
    generationStage = '检查可用时间';
    _notify();
    PlanDraft generated;
    try {
      generated = _planner
          .generate(
            workspace: data,
            today: _planningNow,
            title: title,
            deadline: deadline,
            dailyBudget: dailyBudget,
            notes: notes,
            prompt: prompt,
            newId: newId,
            outlines: ai?.tasks,
            source: ai?.source ?? 'local-template',
            model: ai?.model ?? '',
            suggestBudgetOverflow: true,
          )
          .copyWith(
            calendarFingerprint: _calendarFingerprint(data),
            aiRequestId: requestId,
          );
    } on RepositoryException catch (failure) {
      if (requestId != null && ai != null) {
        throw RepositoryException(
          failure.message,
          conflict: failure.conflict,
          offline: failure.offline,
          details: {...failure.details, 'planningJobRecoverable': true},
        );
      }
      rethrow;
    }
    await _persistChange(
      '生成规划草案',
      data.copyWith(drafts: [...data.drafts, generated]),
    );
    return generated;
  });

  Future<void> updateDraftItem(String draftId, PlannedTask value) => _mutate(
    '编辑规划草案',
    (w) {
      final plan = _requireDraft(draftId);
      if (plan.status != 'draft') {
        throw const RepositoryException('草案已提交，请到任务详情修改。');
      }
      final old = _find(plan.items, (e) => e.task.id == value.task.id);
      if (old == null) throw const RepositoryException('草案任务不存在。');
      _checkTaskRevision(value.task, old.task);
      _validateTask(value.task);
      final targetGoal = plan.targetTaskId != null
          ? task(plan.targetTaskId)?.goalId
          : plan.goal.id;
      if (value.task.goalId != targetGoal ||
          value.blocks.any((e) => e.taskId != value.task.id)) {
        throw const RepositoryException('草案任务关联不正确。');
      }
      final raw = value.blocks;
      final normalized = raw
          .map(
            (e) => e.copyWith(
              title: value.task.title.trim(),
              end: raw.length == 1 && value.task.active
                  ? e.start.add(Duration(minutes: value.task.workMinutes))
                  : e.end,
            ),
          )
          .toList();
      if (normalized.length > 1 && !value.task.splittable ||
          normalized.length > 1 &&
              normalized.any((e) => e.minutes < value.task.minBlockMinutes)) {
        throw const RepositoryException('请开启允许分段并核对每段最短时长。');
      }
      final occupied = [
        ...w.entries.where(
          (e) => plan.targetTaskId != null
              ? e.taskId != plan.targetTaskId
              : plan.targetGoalId == null ||
                    task(e.taskId)?.goalId != plan.targetGoalId,
        ),
        ...w.externalBusyEntries,
        ...plan.items
            .where((e) => e.task.id != value.task.id)
            .expand((e) => e.blocks),
      ];
      for (final block in normalized) {
        if (block.end.isAfter(_planningNow) && value.task.active) {
          PlanningService.validatePlacement(
            block,
            w,
            occupied: occupied,
            applyPreferences: plan.targetTaskId == null,
            dailyBudgetOverride: plan.suggestedDailyBudget,
          );
        }
        _validateTaskWindow(value.task, block, deadline: plan.goal.deadline);
        occupied.add(block);
      }
      final updated = PlannedTask(
        task: value.task.copyWith(revision: old.task.revision + 1),
        entry: normalized.firstOrNull,
        additionalEntries: normalized.skip(1).toList(),
      );
      return w.copyWith(
        drafts: w.drafts
            .map(
              (e) => e.id == draftId
                  ? e.copyWith(
                      items: e.items
                          .map((i) => i.task.id == value.task.id ? updated : i)
                          .toList(),
                    )
                  : e,
            )
            .toList(),
      );
    },
  );

  Future<void> deleteDraftItem(String draftId, String taskId) => _mutate(
    '移除草案任务',
    (w) {
      final plan = _requireDraft(draftId);
      if (plan.status != 'draft') throw const RepositoryException('这份草案已经提交。');
      if (!plan.items.any((e) => e.task.id == taskId)) {
        throw const RepositoryException('草案任务不存在。');
      }
      return w.copyWith(
        drafts: w.drafts
            .map(
              (e) => e.id == draftId
                  ? e.copyWith(
                      items: e.items
                          .where((item) => item.task.id != taskId)
                          .toList(),
                    )
                  : e,
            )
            .toList(),
      );
    },
  );

  Future<void> confirmDraftDailyBudget(String id) =>
      confirmDraftPlanningLimits(id);

  Future<void> confirmDraftPlanningLimits(String id) => _mutate('确认本次计划的安排', (
    w,
  ) {
    final plan = _requireDraft(id);
    if (!plan.needsPlanningConfirmation || plan.status != 'draft') return null;
    if (plan.calendarFingerprint.isNotEmpty &&
        plan.calendarFingerprint !=
            _calendarFingerprint(w, targetGoalId: plan.targetGoalId)) {
      throw const RepositoryException('日程已变化，请重新检查草案。', conflict: true);
    }
    final occupied = [
      ...w.entries.where(
        (entry) =>
            plan.targetGoalId == null ||
            task(entry.taskId)?.goalId != plan.targetGoalId,
      ),
      ...w.externalBusyEntries,
    ];
    for (final item in plan.items) {
      for (final block in item.blocks) {
        _validateTaskWindow(item.task, block, deadline: plan.goal.deadline);
        PlanningService.validatePlacement(
          block,
          w,
          occupied: occupied,
          applyPreferences: true,
          dailyBudgetOverride: plan.suggestedDailyBudget,
        );
        occupied.add(block);
      }
    }
    return w.copyWith(
      drafts: w.drafts
          .map(
            (draft) => draft.id == id
                ? draft.copyWith(
                    budgetOverrideConfirmed: draft.suggestedDailyBudget != null,
                    capacityConfirmed: draft.capacityLimited,
                  )
                : draft,
          )
          .toList(),
    );
  });

  Future<void> commitDraft(String id) async {
    await _serial(() => _refreshExternal(_requireDraft(id).goal.deadline));
    await _mutate('确认规划草案', (w) {
      final plan = _requireDraft(id);
      if (plan.status == 'committed') return null;
      if (plan.needsBudgetConfirmation) {
        throw const RepositoryException('请先确认本次计划增加的每日投入。');
      }
      if (plan.needsCapacityConfirmation) {
        throw const RepositoryException('请先确认保留待安排任务。');
      }
      if (plan.targetTaskId != null) {
        final original = _requireTask(plan.targetTaskId!);
        if (plan.items.length != 1 ||
            plan.items.single.task.id != original.id ||
            plan.baseTaskVersions[original.id] != original.revision) {
          throw const RepositoryException('任务已发生变化，请重新检查建议。', conflict: true);
        }
        final updated = plan.items.single.task.copyWith(
          revision: original.revision + 1,
        );
        _validateTask(updated);
        for (final block in entriesForTask(updated.id)) {
          _validateTaskWindow(updated, block);
        }
        return _replaceTask(w, updated).copyWith(
          drafts: w.drafts
              .map((e) => e.id == id ? e.copyWith(status: 'committed') : e)
              .toList(),
        );
      }

      if (plan.items.isEmpty) throw const RepositoryException('草案中没有任务。');
      if (plan.calendarFingerprint.isNotEmpty &&
          plan.calendarFingerprint !=
              _calendarFingerprint(w, targetGoalId: plan.targetGoalId)) {
        throw const RepositoryException('日历或规划条件已有变化，请重新检查草案。', conflict: true);
      }
      final existingGoal = plan.targetGoalId == null
          ? null
          : goal(plan.targetGoalId);
      if (plan.targetGoalId != null &&
          (existingGoal == null ||
              existingGoal.revision != plan.goal.revision)) {
        throw const RepositoryException('目标已有新修改，请重新打开计划。', conflict: true);
      }
      final replacedIds = plan.targetGoalId == null
          ? <String>{}
          : tasksForGoal(plan.targetGoalId!).map((e) => e.id).toSet();
      final occupied = [
        ...w.entries.where((e) => !replacedIds.contains(e.taskId)),
        ...w.externalBusyEntries,
      ];
      for (final item in plan.items) {
        _validateTask(item.task);
        final previous = task(item.task.id);
        if (item.task.goalId != plan.goal.id ||
            (previous != null &&
                (!replacedIds.contains(previous.id) ||
                    previous.revision !=
                        (plan.baseTaskVersions[item.task.id] ??
                            item.task.revision)))) {
          throw const RepositoryException('任务已有新修改，请重新检查。', conflict: true);
        }
        for (final block in item.blocks) {
          if (!item.task.active || !block.end.isAfter(_planningNow)) {
            occupied.add(block);
            continue;
          }
          _validateTaskWindow(item.task, block, deadline: plan.goal.deadline);
          if (block.taskId != item.task.id) {
            throw const RepositoryException('时间块关联无效。');
          }
          if (block.start.isBefore(_planningNow) && previous == null) {
            throw const RepositoryException('开始时间已过去，请重新检查草案。', conflict: true);
          }
          PlanningService.validatePlacement(
            block,
            w,
            occupied: occupied,
            applyPreferences: true,
            dailyBudgetOverride: plan.confirmedDailyBudget,
          );
          occupied.add(block.copyWith(title: item.task.title));
        }
      }
      final finalTasks = [
        ...w.tasks.where((e) => !replacedIds.contains(e.id)),
        ...plan.items.map((i) => i.task),
      ];
      for (final t in finalTasks) {
        _validateDependencies(t, finalTasks);
      }
      final savedGoal = plan.goal.copyWith(
        taskIds: plan.items.map((e) => e.task.id).toList(),
        revision: (existingGoal?.revision ?? 0) + 1,
      );
      return w.copyWith(
        tasks: [
          ...w.tasks.where((e) => !replacedIds.contains(e.id)),
          ...plan.items.map(
            (e) =>
                e.task.copyWith(revision: (task(e.task.id)?.revision ?? 0) + 1),
          ),
        ],
        entries: occupied.where((e) => !e.isExternal).toList(),
        goals: [...w.goals.where((e) => e.id != savedGoal.id), savedGoal],
        drafts: w.drafts
            .map((e) => e.id == id ? e.copyWith(status: 'committed') : e)
            .toList(),
      );
    });
  }

  CalendarEntry? findAvailableSlot(
    String taskId, {
    DateTime? from,
    DateTime? deadlineOverride,
    int? durationMinutes,
    String? entryId,
  }) {
    final value = _requireTask(taskId);
    final old = entryId == null
        ? entryForTask(taskId)
        : _find(
            data.entries,
            (entry) => entry.id == entryId && entry.taskId == taskId,
          );
    if (entryId != null && old == null) {
      throw const RepositoryException('原时间块已不存在，请重新选择安排。');
    }
    final now = _planningNow;
    var start = from == null || from.isBefore(now) ? now : from;
    if (value.notBefore != null && value.notBefore!.isAfter(start)) {
      start = value.notBefore!;
    }
    final deadline =
        deadlineOverride ??
        value.deadline ??
        dateOnly(start).add(const Duration(days: 30));
    return _planner
        .findSlot(
          workspace: data,
          today: start,
          deadline: deadline,
          minutes:
              durationMinutes ??
              (entriesForTask(taskId).length > 1
                  ? old!.minutes
                  : value.workMinutes),
          dailyBudget: data.preferences.dailyBudget,
          occupied: [
            // Replanning moves one block; sibling blocks remain occupied and
            // continue to count toward this day's budget and buffer.
            ...data.entries.where((e) => e.id != old?.id),
            ...data.externalBusyEntries,
          ],
          taskId: taskId,
          title: value.title,
          entryId: old?.id ?? newId('entry'),
        )
        ?.copyWith(revision: old?.revision ?? 1);
  }

  DateTime? suggestReplan(String taskId) => findAvailableSlot(
    taskId,
    from: entryForTask(taskId)?.end
        .add(Duration(minutes: data.preferences.bufferMinutes)),
  )?.start;

  Future<void> scheduleTask(String taskId, {DateTime? from}) =>
      _mutate('安排剩余工作', (w) {
        final task = _requireTask(taskId);
        final current = entriesForTask(taskId)
            .where((e) => e.end.isAfter(_planningNow))
            .toList();
        if (current.any((e) => e.locked)) {
          throw const RepositoryException('任务含锁定安排，请先手动确认或解锁。');
        }
        final occupied = [
          ...w.entries.where(
            (e) => e.taskId != taskId || !e.end.isAfter(_planningNow),
          ),
          ...w.externalBusyEntries,
        ];
        final start = from == null || from.isBefore(_planningNow)
            ? _planningNow
            : from;
        final blocks = _planner.findSlots(
          workspace: w,
          today: start,
          deadline: task.deadline ?? today.add(const Duration(days: 30)),
          task: task,
          dailyBudget: w.preferences.dailyBudget,
          occupied: occupied,
          newId: newId,
        );
        if (blocks.isEmpty) {
          throw const RepositoryException('截止前没有可用时间，请调整截止、拆分或规划偏好。');
        }
        return w.copyWith(
          entries: [...occupied.where((e) => !e.isExternal), ...blocks],
        );
      });

  Future<String> applyReplan(
    String taskId,
    DateTime start, {
    String? entryId,
    int? expectedEntryRevision,
  }) => _serial(() async {
    final original = _requireTask(taskId);
    await _refreshExternal(
      original.deadline ?? start.add(const Duration(days: 1)),
    );
    if (_disposed) throw const RepositoryException('当前工作区已关闭。');
    final w = data;
    if (start.isBefore(_planningNow)) {
      throw const RepositoryException('新安排不能早于当前时间。');
    }
    final value = _requireTask(taskId);
    final old = entryId == null
        ? entryForTask(taskId)
        : _find(
            data.entries,
            (entry) => entry.id == entryId && entry.taskId == taskId,
          );
    if (entryId != null && old == null) {
      throw const RepositoryException('原时间块已不存在，请重新选择安排。');
    }
    if (expectedEntryRevision != null &&
        old?.revision != expectedEntryRevision) {
      throw const RepositoryException('原时间块已有新修改，请重新核对。', conflict: true);
    }
    final updated = CalendarEntry(
      id: old?.id ?? newId('entry'),
      taskId: taskId,
      title: value.title,
      start: start,
      end: start.add(
        Duration(
          minutes: entriesForTask(taskId).length > 1
              ? old!.minutes
              : value.workMinutes,
        ),
      ),
      place: old?.place ?? '',
      notes: old?.notes ?? '',
      locked: old?.locked ?? false,
      revision: (old?.revision ?? 0) + 1,
    );
    PlanningService.validatePlacement(updated, w, applyPreferences: true);
    _validateTaskWindow(value, updated);
    final recordId = newId('change');
    await _persistChange(
      '调整任务时间',
      w.copyWith(
        entries: [...w.entries.where((e) => e.id != updated.id), updated],
      ),
      recordId: recordId,
    );
    return recordId;
  });

  Future<void> recordFocus(String taskId, int seconds) => _mutate('记录专注', (w) {
    final value = _requireTask(taskId);
    if (seconds < 1 || seconds > 86400) {
      throw const RepositoryException('专注时长需在 1 秒至 24 小时之间。');
    }
    return _replaceTask(
      w,
      value.copyWith(
        actualSeconds: value.actualSeconds + seconds,
        revision: value.revision + 1,
      ),
    ).copyWith(
      focusRecords: [
        ...w.focusRecords,
        FocusRecord(
          id: newId('focus'),
          taskId: taskId,
          startedAt: DateTime.now().subtract(Duration(seconds: seconds)),
          seconds: seconds,
        ),
      ],
    );
  });

  String? replanUndoConflict(String recordId) {
    final record = _find(data.history, (item) => item.id == recordId);
    if (record == null) return '这次调整记录已不存在。';
    if (record.undone) return '这次调整已撤销。';
    try {
      _replanUndoUpdate(record);
      return null;
    } on RepositoryException catch (error) {
      return error.message;
    } catch (_) {
      return '这次记录不支持单独撤销，请核对当前安排。';
    }
  }

  bool canUndoReplan(String recordId) => replanUndoConflict(recordId) == null;

  // Replanning changes one local time block. Reverse only that recorded
  // change, never the whole historical workspace after unrelated edits.
  ({String entryId, CalendarEntry? restore}) _replanUndoUpdate(
    ChangeRecord record,
  ) {
    Never conflict(String message) =>
        throw RepositoryException(message, conflict: true);
    if (record.label != '调整任务时间' || record.format != null && !record.isDelta) {
      conflict('这次记录不支持单独撤销，请核对当前安排。');
    }
    final beforeOther = Map<String, dynamic>.from(record.before)
      ..remove('entries');
    final afterOther = Map<String, dynamic>.from(record.after)
      ..remove('entries');
    if (jsonEncode(beforeOther) != jsonEncode(afterOther)) {
      conflict('这次调整还涉及其他内容，请核对当前安排。');
    }
    Map<String, Json> entries(Json snapshot) {
      final values = snapshot['entries'];
      if (values is! List) conflict('这次调整记录不完整，请核对当前安排。');
      final result = <String, Json>{};
      for (final value in values) {
        if (value is! Map ||
            value['id'] is! String ||
            (value['id'] as String).isEmpty) {
          conflict('这次调整记录不完整，请核对当前安排。');
        }
        final id = value['id'] as String;
        if (result.containsKey(id)) {
          conflict('这次调整记录不完整，请核对当前安排。');
        }
        result[id] = Map<String, dynamic>.from(value);
      }
      return result;
    }

    final before = entries(record.before);
    final after = entries(record.after);
    final changed = <String>{
      ...before.keys,
      ...after.keys,
    }.where((id) => jsonEncode(before[id]) != jsonEncode(after[id])).toList();
    if (changed.length != 1 || after[changed.single] == null) {
      conflict('这次调整的范围无法确认，请核对当前安排。');
    }
    final id = changed.single;
    final saved = CalendarEntry.fromJson(after[id]!);
    final original = before[id] == null
        ? null
        : CalendarEntry.fromJson(before[id]!);
    if (saved.isExternal ||
        saved.taskId == null ||
        original != null &&
            (original.isExternal || original.taskId != saved.taskId)) {
      conflict('这次调整的对象已改变，请核对当前安排。');
    }
    final current = _find(data.entries, (item) => item.id == id);
    if (current == null) conflict('这项安排已删除，无法撤销这次调整。');
    if (jsonEncode(current.toJson()) != jsonEncode(saved.toJson())) {
      conflict('这项安排后来有新修改，无法直接撤销。');
    }
    final recordIndex = data.history.indexWhere((item) => item.id == record.id);
    for (final later in data.history.skip(recordIndex + 1)) {
      final old = entries(later.before)[id];
      final updated = entries(later.after)[id];
      if (jsonEncode(old) != jsonEncode(updated)) {
        conflict('这项安排后来有新修改，无法直接撤销。');
      }
    }
    final linked = task(current.taskId);
    if (linked == null || !linked.active) {
      conflict('关联任务已删除或完成，请核对当前安排。');
    }
    if (original == null) return (entryId: id, restore: null);
    final restored = original.copyWith(revision: current.revision + 1);
    try {
      // Restoring an old slot must not overlap later user/calendar changes.
      // Budget preferences remain soft guidance, just as in manual placement.
      PlanningService.validatePlacement(restored, data);
      _validateTaskWindow(linked, restored);
    } on RepositoryException catch (error) {
      conflict('原时段现在无法恢复：${error.message}');
    }
    return (entryId: id, restore: restored);
  }

  Future<bool> undoReplan(String recordId) =>
      _serial(() => _undoReplan(recordId));

  Future<bool> _undoReplan(String recordId) async {
    final record = _find(data.history, (item) => item.id == recordId);
    if (record == null) {
      throw const RepositoryException('这次调整记录已不存在。', conflict: true);
    }
    if (record.undone) return false;
    final update = _replanUndoUpdate(record);
    final history = data.history
        .map((item) => item.id == recordId ? item.copyWith(undone: true) : item)
        .toList();
    data = await repository.save(
      data.copyWith(
        entries: [
          for (final entry in data.entries)
            if (entry.id != update.entryId)
              entry
            else if (update.restore != null)
              update.restore!,
        ],
        history: history,
      ),
      expectedRevision: data.revision,
    );
    await _afterSave();
    return true;
  }

  Future<bool> undoLast({String? expectedRecordId}) => _serial(() async {
    if (expectedRecordId != null &&
        _find(data.history, (item) => item.id == expectedRecordId)?.label ==
            '调整任务时间') {
      return _undoReplan(expectedRecordId);
    }
    final record = _find(data.history.reversed, (e) => !e.undone);
    if (expectedRecordId != null && record?.id != expectedRecordId) {
      throw const RepositoryException('这次调整之后已有其他修改，请先核对最新记录。', conflict: true);
    }
    if (record == null) return false;
    if (record.format != null && !record.isDelta) {
      throw const RepositoryException('这次记录格式不受支持，无法撤销。', conflict: true);
    }
    if (!historyMatchesAfter(record, data)) {
      throw const RepositoryException(
        '当前内容后来又被修改，撤销会覆盖新修改。请刷新并检查记录。',
        conflict: true,
      );
    }
    final restored = restoreHistoryBefore(record, data);
    final history = data.history
        .map((e) => e.id == record.id ? e.copyWith(undone: true) : e)
        .toList();
    data = await repository.save(
      restored.copyWith(
        history: history,
        planningSessions: data.planningSessions,
        focusSession: data.focusSession,
        platformSettings: data.platformSettings,
        reminderStates: data.reminderStates,
        entityVersions: data.entityVersions,
      ),
      expectedRevision: data.revision,
    );
    await _afterSave();
    return true;
  });

  Future<void> resetDemo() => _serial(() async {
    data = await repository.save(
      createSeedWorkspace(today),
      expectedRevision: data.revision,
    );
    selectedDate = today;
  });

  Future<void> clearWorkspace() => _mutate(
    '清空工作区',
    (w) => Workspace(
      preferences: w.preferences,
      platformSettings: w.platformSettings,
    ),
  );
}
