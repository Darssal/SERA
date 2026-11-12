import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tzdata;

part 'session_models.dart';
part 'time_zones.dart';

typedef Json = Map<String, dynamic>;

DateTime dateOnly(DateTime value) => calendarDay(value, 0);
DateTime? parseDate(Object? value) =>
    value == null ? null : DateTime.tryParse('$value')?.toLocal();
List<T> readList<T>(Object? value, T Function(Json) decode) =>
    (value is List ? value : <dynamic>[])
        .whereType<Map>()
        .map((e) => decode(Map<String, dynamic>.from(e)))
        .toList();

String calendarDateString(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

DateTime _readAllDay(Json j, String key, String? displayZone) {
  final originalZone = j['timeZone'] as String? ?? 'Asia/Hong_Kong';
  final day =
      j['${key}Date'] as String? ??
      calendarDateString(readZoned(j[key], originalZone)!);
  return readZoned(day, displayZone ?? originalZone)!;
}

class SeraTask {
  const SeraTask({
    required this.id,
    required this.title,
    this.notes = '',
    this.goalId,
    this.estimatedMinutes = 30,
    this.actualSeconds = 0,
    this.dueAt,
    this.phase = '',
    this.notBefore,
    bool done = false,
    String? status,
    this.priority = 'normal',
    this.dependencyIds = const [],
    this.splittable = false,
    this.minBlockMinutes = 15,
    this.remainingMinutes = -1,
    this.blockedReason = '',
    this.dueDate,
    this.timeZone = 'Asia/Hong_Kong',
    this.checklist = const [],
    this.completedChecks = const [],
    this.reminderMinutes = 10,
    this.revision = 1,
  }) : status = status ?? (done ? 'done' : 'todo');
  final String id, title, notes, phase;
  final String? goalId;
  final int estimatedMinutes, actualSeconds, reminderMinutes, revision;
  final DateTime? dueAt, notBefore;
  final String status, priority, blockedReason;
  final String? dueDate;
  final String timeZone;
  DateTime? get deadline =>
      dueAt ??
      (dueDate == null ? null : atMinute(readZoned(dueDate, timeZone)!, 1439));
  final List<String> dependencyIds;
  final bool splittable;
  final int minBlockMinutes, remainingMinutes;
  bool get done => status == 'done';
  bool get active => !done && status != 'canceled';
  int get workMinutes =>
      remainingMinutes < 0 ? estimatedMinutes : remainingMinutes;
  final List<String> checklist, completedChecks;
  SeraTask copyWith({
    String? title,
    String? notes,
    String? goalId,
    int? estimatedMinutes,
    int? actualSeconds,
    DateTime? dueAt,
    bool clearDue = false,
    String? phase,
    DateTime? notBefore,
    bool clearNotBefore = false,
    bool? done,
    String? status,
    String? priority,
    List<String>? dependencyIds,
    bool? splittable,
    int? minBlockMinutes,
    int? remainingMinutes,
    String? blockedReason,
    String? dueDate,
    bool clearGoal = false,
    bool clearDueDate = false,
    String? timeZone,
    List<String>? checklist,
    List<String>? completedChecks,
    int? reminderMinutes,
    int? revision,
  }) => SeraTask(
    id: id,
    title: title ?? this.title,
    notes: notes ?? this.notes,
    goalId: clearGoal ? null : goalId ?? this.goalId,
    estimatedMinutes: estimatedMinutes ?? this.estimatedMinutes,
    actualSeconds: actualSeconds ?? this.actualSeconds,
    dueAt: clearDue ? null : dueAt ?? this.dueAt,
    phase: phase ?? this.phase,
    notBefore: clearNotBefore ? null : notBefore ?? this.notBefore,
    status:
        status ??
        (done == null
            ? this.status
            : done
            ? 'done'
            : 'todo'),
    priority: priority ?? this.priority,
    dependencyIds: dependencyIds ?? this.dependencyIds,
    splittable: splittable ?? this.splittable,
    minBlockMinutes: minBlockMinutes ?? this.minBlockMinutes,
    remainingMinutes: remainingMinutes ?? this.remainingMinutes,
    blockedReason: blockedReason ?? this.blockedReason,
    dueDate: clearDueDate ? null : dueDate ?? this.dueDate,
    timeZone: timeZone ?? this.timeZone,
    checklist: checklist ?? this.checklist,
    completedChecks: completedChecks ?? this.completedChecks,
    reminderMinutes: reminderMinutes ?? this.reminderMinutes,
    revision: revision ?? this.revision,
  );
  Json toJson() => {
    'id': id,
    'title': title,
    'notes': notes,
    'goalId': goalId,
    'estimatedMinutes': estimatedMinutes,
    'actualSeconds': actualSeconds,
    'dueAt': dueAt?.toUtc().toIso8601String(),
    'phase': phase,
    'notBefore': notBefore?.toUtc().toIso8601String(),
    'done': done,
    'status': status,
    'priority': priority,
    'dependencyIds': dependencyIds,
    'splittable': splittable,
    'minBlockMinutes': minBlockMinutes,
    'remainingMinutes': remainingMinutes,
    'blockedReason': blockedReason,
    'dueDate': dueDate,
    'timeZone': timeZone,
    'checklist': checklist,
    'completedChecks': completedChecks,
    'reminderMinutes': reminderMinutes,
    'revision': revision,
  };
  factory SeraTask.fromJson(Json j, {String? displayZone}) => SeraTask(
    id: '${j['id']}',
    title: j['title'] as String? ?? '',
    notes: j['notes'] as String? ?? '',
    goalId: j['goalId'] as String?,
    estimatedMinutes: (j['estimatedMinutes'] as num?)?.toInt() ?? 30,
    actualSeconds: (j['actualSeconds'] as num?)?.toInt() ?? 0,
    dueAt: readZoned(
      j['dueAt'],
      displayZone ?? j['timeZone'] as String? ?? 'Asia/Hong_Kong',
    ),
    phase: j['phase'] as String? ?? '',
    notBefore: readZoned(
      j['notBefore'],
      displayZone ?? j['timeZone'] as String? ?? 'Asia/Hong_Kong',
    ),
    done: j['done'] == true,
    status: j['status'] as String?,
    priority: j['priority'] as String? ?? 'normal',
    dependencyIds: List<String>.from(j['dependencyIds'] as List? ?? []),
    splittable: j['splittable'] == true,
    minBlockMinutes: (j['minBlockMinutes'] as num?)?.toInt() ?? 15,
    remainingMinutes: (j['remainingMinutes'] as num?)?.toInt() ?? -1,
    blockedReason: j['blockedReason'] as String? ?? '',
    dueDate: j['dueDate'] as String?,
    timeZone: j['timeZone'] as String? ?? 'Asia/Hong_Kong',
    checklist: List<String>.from(j['checklist'] as List? ?? []),
    completedChecks: List<String>.from(j['completedChecks'] as List? ?? []),
    reminderMinutes: (j['reminderMinutes'] as num?)?.toInt() ?? 10,
    revision: (j['revision'] as num?)?.toInt() ?? 1,
  );
}

class CalendarEntry {
  const CalendarEntry({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    this.taskId,
    this.place = '',
    this.notes = '',
    this.locked = false,
    this.source = 'local',
    this.externalId,
    this.allDay = false,
    this.timeZone = 'Asia/Hong_Kong',
    this.syncState = 'local_only',
    this.revision = 1,
  });
  final String id, title, place, notes;
  final String? taskId;
  final DateTime start, end;
  final bool locked, allDay;
  final String source, timeZone, syncState;
  final String? externalId;
  bool get isExternal => source != 'local';
  final int revision;
  bool get isTask => taskId != null;
  int get minutes => end.difference(start).inMinutes;
  CalendarEntry copyWith({
    String? title,
    DateTime? start,
    DateTime? end,
    String? place,
    String? notes,
    bool? locked,
    String? source,
    String? externalId,
    bool? allDay,
    String? timeZone,
    String? syncState,
    int? revision,
  }) => CalendarEntry(
    id: id,
    title: title ?? this.title,
    start: start ?? this.start,
    end: end ?? this.end,
    taskId: taskId,
    place: place ?? this.place,
    notes: notes ?? this.notes,
    locked: locked ?? this.locked,
    source: source ?? this.source,
    externalId: externalId ?? this.externalId,
    allDay: allDay ?? this.allDay,
    timeZone: timeZone ?? this.timeZone,
    syncState: syncState ?? this.syncState,
    revision: revision ?? this.revision,
  );
  Json toJson() => {
    'id': id,
    'title': title,
    'start': (allDay ? readZoned(calendarDateString(start), timeZone)! : start)
        .toUtc()
        .toIso8601String(),
    'end': (allDay ? readZoned(calendarDateString(end), timeZone)! : end)
        .toUtc()
        .toIso8601String(),
    if (allDay) 'startDate': calendarDateString(start),
    if (allDay) 'endDate': calendarDateString(end),
    'taskId': taskId,
    'place': place,
    'notes': notes,
    'locked': locked,
    'source': source,
    'externalId': externalId,
    'allDay': allDay,
    'timeZone': timeZone,
    'syncState': syncState,
    'revision': revision,
  };
  factory CalendarEntry.fromJson(Json j, {String? displayZone}) =>
      CalendarEntry(
        id: '${j['id']}',
        title: j['title'] as String? ?? '',
        start: j['allDay'] == true
            ? _readAllDay(j, 'start', displayZone)
            : readZoned(
                j['start'],
                displayZone ?? j['timeZone'] as String? ?? 'Asia/Hong_Kong',
              )!,
        end: j['allDay'] == true
            ? _readAllDay(j, 'end', displayZone)
            : readZoned(
                j['end'],
                displayZone ?? j['timeZone'] as String? ?? 'Asia/Hong_Kong',
              )!,
        taskId: j['taskId'] as String?,
        place: j['place'] as String? ?? '',
        notes: j['notes'] as String? ?? '',
        locked: j['locked'] == true,
        source: j['source'] as String? ?? 'local',
        externalId: j['externalId'] as String?,
        allDay: j['allDay'] == true,
        timeZone: j['timeZone'] as String? ?? 'Asia/Hong_Kong',
        syncState: j['syncState'] as String? ?? 'local_only',
        revision: (j['revision'] as num?)?.toInt() ?? 1,
      );
}

class SeraGoal {
  const SeraGoal({
    required this.id,
    required this.title,
    required this.deadline,
    this.outcome = '',
    this.status = 'active',
    this.taskIds = const [],
    this.revision = 1,
  });
  final String id, title, outcome, status;
  final DateTime deadline;
  final List<String> taskIds;
  final int revision;
  SeraGoal copyWith({
    String? title,
    String? outcome,
    String? status,
    DateTime? deadline,
    List<String>? taskIds,
    int? revision,
  }) => SeraGoal(
    id: id,
    title: title ?? this.title,
    deadline: deadline ?? this.deadline,
    outcome: outcome ?? this.outcome,
    status: status ?? this.status,
    taskIds: taskIds ?? this.taskIds,
    revision: revision ?? this.revision,
  );
  Json toJson() => {
    'id': id,
    'title': title,
    'deadline': deadline.toUtc().toIso8601String(),
    'outcome': outcome,
    'status': status,
    'taskIds': taskIds,
    'revision': revision,
  };
  factory SeraGoal.fromJson(Json j, {String? displayZone}) => SeraGoal(
    id: '${j['id']}',
    title: j['title'] as String? ?? '',
    deadline: readZoned(j['deadline'], displayZone ?? 'Asia/Hong_Kong')!,
    outcome: j['outcome'] as String? ?? '',
    status: j['status'] as String? ?? 'active',
    taskIds: List<String>.from(j['taskIds'] as List? ?? []),
    revision: (j['revision'] as num?)?.toInt() ?? 1,
  );
}

class PlannedTask {
  const PlannedTask({
    required this.task,
    this.entry,
    this.additionalEntries = const [],
  });
  final SeraTask task;
  final CalendarEntry? entry;
  final List<CalendarEntry> additionalEntries;
  List<CalendarEntry> get blocks => [?entry, ...additionalEntries];
  Json toJson() => {
    'task': task.toJson(),
    'entry': entry?.toJson(),
    'additionalEntries': additionalEntries.map((e) => e.toJson()).toList(),
  };
  factory PlannedTask.fromJson(Json j, {String? displayZone}) => PlannedTask(
    task: SeraTask.fromJson(
      Map<String, dynamic>.from(j['task'] as Map),
      displayZone: displayZone,
    ),
    additionalEntries: readList(
      j['additionalEntries'],
      (v) => CalendarEntry.fromJson(v, displayZone: displayZone),
    ),
    entry: j['entry'] is Map
        ? CalendarEntry.fromJson(
            Map<String, dynamic>.from(j['entry'] as Map),
            displayZone: displayZone,
          )
        : null,
  );
}

class PlanDraft {
  const PlanDraft({
    required this.id,
    required this.goal,
    required this.items,
    this.prompt = '',
    this.status = 'draft',
    this.baseRevision = 0,
    this.source = 'local-template',
    this.model = '',
    this.aiRequestId,
    this.targetGoalId,
    this.targetTaskId,
    this.validationRevision = 0,
    this.calendarFingerprint = '',
    this.baseTaskVersions = const {},
    this.originalDailyBudget,
    this.suggestedDailyBudget,
    this.budgetOverrideConfirmed = false,
    this.capacityLimited = false,
    this.capacityConfirmed = false,
  });
  final String id, prompt, status;
  final String source, model;
  final String? aiRequestId;
  final SeraGoal goal;
  final List<PlannedTask> items;
  final int baseRevision, validationRevision;
  final String calendarFingerprint;
  final Json baseTaskVersions;
  final String? targetGoalId, targetTaskId;

  /// This plan's explicit exception; personal planning preferences stay intact.
  final int? originalDailyBudget, suggestedDailyBudget;
  final bool budgetOverrideConfirmed;
  final bool capacityLimited, capacityConfirmed;
  Iterable<PlannedTask> get unscheduledItems =>
      items.where((item) => item.task.active && item.blocks.isEmpty);
  bool get needsCapacityConfirmation =>
      capacityLimited && unscheduledItems.isNotEmpty && !capacityConfirmed;
  bool get needsPlanningConfirmation =>
      needsBudgetConfirmation || needsCapacityConfirmation;
  bool get needsBudgetConfirmation =>
      suggestedDailyBudget != null && !budgetOverrideConfirmed;
  int? get confirmedDailyBudget =>
      budgetOverrideConfirmed ? suggestedDailyBudget : null;
  int get totalMinutes =>
      items.fold(0, (sum, item) => sum + item.task.estimatedMinutes);
  PlanDraft copyWith({
    List<PlannedTask>? items,
    String? status,
    int? baseRevision,
    String? source,
    String? model,
    SeraGoal? goal,
    int? validationRevision,
    String? calendarFingerprint,
    String? aiRequestId,
    bool? budgetOverrideConfirmed,
    bool? capacityLimited,
    bool? capacityConfirmed,
  }) => PlanDraft(
    id: id,
    goal: goal ?? this.goal,
    items: items ?? this.items,
    prompt: prompt,
    status: status ?? this.status,
    baseRevision: baseRevision ?? this.baseRevision,
    source: source ?? this.source,
    model: model ?? this.model,
    aiRequestId: aiRequestId ?? this.aiRequestId,
    targetGoalId: targetGoalId,
    targetTaskId: targetTaskId,
    validationRevision: validationRevision ?? this.validationRevision,
    calendarFingerprint: calendarFingerprint ?? this.calendarFingerprint,
    baseTaskVersions: baseTaskVersions,
    originalDailyBudget: originalDailyBudget,
    suggestedDailyBudget: suggestedDailyBudget,
    budgetOverrideConfirmed:
        budgetOverrideConfirmed ?? this.budgetOverrideConfirmed,
    capacityLimited: capacityLimited ?? this.capacityLimited,
    capacityConfirmed:
        capacityConfirmed ??
        (this.capacityConfirmed &&
            _capacityConsentCovers(this.items, items ?? this.items)),
  );
  Json toJson() => {
    'id': id,
    'goal': goal.toJson(),
    'items': items.map((e) => e.toJson()).toList(),
    'prompt': prompt,
    'status': status,
    'baseRevision': baseRevision,
    'source': source,
    'model': model,
    'aiRequestId': aiRequestId,
    'targetGoalId': targetGoalId,
    'targetTaskId': targetTaskId,
    'validationRevision': validationRevision,
    'calendarFingerprint': calendarFingerprint,
    'baseTaskVersions': baseTaskVersions,
    'originalDailyBudget': originalDailyBudget,
    'suggestedDailyBudget': suggestedDailyBudget,
    'budgetOverrideConfirmed': budgetOverrideConfirmed,
    'capacityLimited': capacityLimited,
    'capacityConfirmed': capacityConfirmed,
  };
  factory PlanDraft.fromJson(Json j, {String? displayZone}) => PlanDraft(
    id: '${j['id']}',
    goal: SeraGoal.fromJson(
      Map<String, dynamic>.from(j['goal'] as Map),
      displayZone: displayZone,
    ),
    items: readList(
      j['items'],
      (v) => PlannedTask.fromJson(v, displayZone: displayZone),
    ),
    prompt: j['prompt'] as String? ?? '',
    status: j['status'] as String? ?? 'draft',
    baseRevision: (j['baseRevision'] as num?)?.toInt() ?? 0,
    source: j['source'] as String? ?? 'local-template',
    model: j['model'] as String? ?? '',
    aiRequestId: j['aiRequestId'] as String?,
    targetGoalId: j['targetGoalId'] as String?,
    targetTaskId: j['targetTaskId'] as String?,
    validationRevision: (j['validationRevision'] as num?)?.toInt() ?? 0,
    calendarFingerprint: j['calendarFingerprint'] as String? ?? '',
    baseTaskVersions: Map<String, dynamic>.from(
      j['baseTaskVersions'] as Map? ?? {},
    ),
    originalDailyBudget: _readDraftBudget(j, original: true),
    suggestedDailyBudget: _readDraftBudget(j, original: false),
    budgetOverrideConfirmed: j['budgetOverrideConfirmed'] as bool? ?? false,
    capacityLimited: _readDraftCapacity(j, confirmed: false),
    capacityConfirmed: _readDraftCapacity(j, confirmed: true),
  );
}

bool _capacityConsentCovers(
  List<PlannedTask> original,
  List<PlannedTask> updated,
) {
  String scope(SeraTask task) => jsonEncode([
    task.workMinutes,
    task.deadline?.toUtc().toIso8601String(),
    task.notBefore?.toUtc().toIso8601String(),
    task.dependencyIds,
  ]);
  final accepted = {
    for (final item in original)
      if (item.task.active && item.blocks.isEmpty)
        item.task.id: scope(item.task),
  };
  return updated
      .where((item) => item.task.active && item.blocks.isEmpty)
      .every((item) => accepted[item.task.id] == scope(item.task));
}

bool _readDraftCapacity(Json value, {required bool confirmed}) {
  final limited = value.containsKey('capacityLimited')
      ? value['capacityLimited']
      : false;
  final accepted = value.containsKey('capacityConfirmed')
      ? value['capacityConfirmed']
      : false;
  if (limited is! bool || accepted is! bool || (accepted && !limited)) {
    throw const FormatException('Invalid plan capacity confirmation');
  }
  if (value['status'] == 'committed' && limited && !accepted) {
    final items = readList(value['items'], PlannedTask.fromJson);
    if (items.any((item) => item.task.active && item.blocks.isEmpty)) {
      throw const FormatException('Unconfirmed plan capacity');
    }
  }
  return confirmed ? accepted : limited;
}

int? _readDraftBudget(Json value, {required bool original}) {
  final base = value['originalDailyBudget'];
  final suggested = value['suggestedDailyBudget'];
  final confirmed = value['budgetOverrideConfirmed'] ?? false;
  if (confirmed is! bool ||
      (base == null) != (suggested == null) ||
      (base != null &&
          (base is! int ||
              base < 15 ||
              base > 480 ||
              suggested is! int ||
              suggested <= base ||
              suggested > 1440)) ||
      (confirmed && suggested == null) ||
      (value['status'] == 'committed' && suggested != null && !confirmed)) {
    throw const FormatException('Invalid plan daily budget confirmation');
  }
  return (original ? base : suggested) as int?;
}

class SeraPreferences {
  const SeraPreferences({
    this.weekdays = const [1, 2, 3, 4, 5],
    this.dailyBudget = 90,
    this.bufferMinutes = 15,
    this.startMinute = 840,
    this.endMinute = 1020,
    this.notifications = true,
    this.followUp = true,
    this.useAiContext = false,
    this.timeZone = 'Asia/Hong_Kong',
    this.restStart = 720,
    this.restEnd = 780,
    this.quietStart = 1320,
    this.quietEnd = 480,
  });
  final List<int> weekdays;
  final int dailyBudget,
      bufferMinutes,
      startMinute,
      endMinute,
      quietStart,
      quietEnd;
  final bool notifications, followUp, useAiContext;
  final String timeZone;
  final int restStart, restEnd;
  SeraPreferences copyWith({
    List<int>? weekdays,
    int? dailyBudget,
    int? bufferMinutes,
    int? startMinute,
    int? endMinute,
    bool? notifications,
    bool? followUp,
    bool? useAiContext,
    String? timeZone,
    int? restStart,
    int? restEnd,
    int? quietStart,
    int? quietEnd,
  }) => SeraPreferences(
    weekdays: weekdays ?? this.weekdays,
    dailyBudget: dailyBudget ?? this.dailyBudget,
    bufferMinutes: bufferMinutes ?? this.bufferMinutes,
    startMinute: startMinute ?? this.startMinute,
    endMinute: endMinute ?? this.endMinute,
    notifications: notifications ?? this.notifications,
    followUp: followUp ?? this.followUp,
    useAiContext: useAiContext ?? this.useAiContext,
    timeZone: timeZone ?? this.timeZone,
    restStart: restStart ?? this.restStart,
    restEnd: restEnd ?? this.restEnd,
    quietStart: quietStart ?? this.quietStart,
    quietEnd: quietEnd ?? this.quietEnd,
  );
  Json toJson() => {
    'weekdays': weekdays,
    'dailyBudget': dailyBudget,
    'bufferMinutes': bufferMinutes,
    'startMinute': startMinute,
    'endMinute': endMinute,
    'notifications': notifications,
    'followUp': followUp,
    'useAiContext': useAiContext,
    'timeZone': timeZone,
    'restStart': restStart,
    'restEnd': restEnd,
    'quietStart': quietStart,
    'quietEnd': quietEnd,
  };
  factory SeraPreferences.fromJson(Json j) => SeraPreferences(
    weekdays: List<int>.from(j['weekdays'] as List? ?? [1, 2, 3, 4, 5]),
    dailyBudget: (j['dailyBudget'] as num?)?.toInt() ?? 90,
    bufferMinutes: (j['bufferMinutes'] as num?)?.toInt() ?? 15,
    startMinute: (j['startMinute'] as num?)?.toInt() ?? 840,
    endMinute: (j['endMinute'] as num?)?.toInt() ?? 1020,
    notifications: j['notifications'] != false,
    followUp: j['followUp'] != false,
    useAiContext: j['useAiContext'] == true,
    timeZone: j['timeZone'] as String? ?? 'Asia/Hong_Kong',
    restStart: (j['restStart'] as num?)?.toInt() ?? 720,
    restEnd: (j['restEnd'] as num?)?.toInt() ?? 780,
    quietStart: (j['quietStart'] as num?)?.toInt() ?? 1320,
    quietEnd: (j['quietEnd'] as num?)?.toInt() ?? 480,
  );
}

class FocusRecord {
  const FocusRecord({
    required this.id,
    required this.taskId,
    required this.startedAt,
    required this.seconds,
  });
  final String id, taskId;
  final DateTime startedAt;
  final int seconds;
  Json toJson() => {
    'id': id,
    'taskId': taskId,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'seconds': seconds,
  };
  factory FocusRecord.fromJson(
    Json j, {
    String displayZone = 'Asia/Hong_Kong',
  }) => FocusRecord(
    id: '${j['id']}',
    taskId: '${j['taskId']}',
    startedAt: readZoned(j['startedAt'], displayZone)!,
    seconds: (j['seconds'] as num?)?.toInt() ?? 0,
  );
}

class ChangeRecord {
  const ChangeRecord({
    required this.id,
    required this.label,
    required this.at,
    this.before = const {},
    this.after = const {},
    this.undone = false,
    this.format,
    this.afterDigest,
    this.beforeOrder = const {},
    this.afterTaskEntries = const {},
  });
  final String id, label;
  final DateTime at;
  final Json before, after;
  final bool undone;
  final String? format, afterDigest;
  final Map<String, List<String>> beforeOrder;
  final Map<String, Map<String, String>> afterTaskEntries;
  bool get isDelta => format == 'entity-delta-v1';
  ChangeRecord copyWith({bool? undone}) => ChangeRecord(
    id: id,
    label: label,
    at: at,
    before: before,
    after: after,
    undone: undone ?? this.undone,
    format: format,
    afterDigest: afterDigest,
    beforeOrder: beforeOrder,
    afterTaskEntries: afterTaskEntries,
  );
  Json toJson() => {
    'id': id,
    'label': label,
    'at': at.toUtc().toIso8601String(),
    'before': before,
    'after': after,
    'undone': undone,
    if (format != null) 'format': format,
    if (afterDigest != null) 'afterDigest': afterDigest,
    if (format != null) 'beforeOrder': beforeOrder,
    if (afterTaskEntries.isNotEmpty) 'afterTaskEntries': afterTaskEntries,
  };
  factory ChangeRecord.fromJson(
    Json j, {
    String displayZone = 'Asia/Hong_Kong',
  }) {
    final format = j['format'];
    if (format != null && format != 'entity-delta-v1') {
      throw const FormatException('Unsupported change history format');
    }
    final digest = j['afterDigest'];
    if (format != null &&
        (digest is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest))) {
      throw const FormatException('Invalid change history digest');
    }
    return ChangeRecord(
      id: '${j['id']}',
      label: '${j['label']}',
      at: readZoned(j['at'], displayZone)!,
      before: Map<String, dynamic>.from(j['before'] as Map? ?? {}),
      after: Map<String, dynamic>.from(j['after'] as Map? ?? {}),
      undone: j['undone'] == true,
      format: format as String?,
      afterDigest: digest as String?,
      beforeOrder: {
        for (final e in (j['beforeOrder'] as Map? ?? const {}).entries)
          e.key as String: List<String>.from(e.value as List),
      },
      afterTaskEntries: {
        for (final e in (j['afterTaskEntries'] as Map? ?? const {}).entries)
          e.key as String: Map<String, String>.from(e.value as Map),
      },
    );
  }
}

class Workspace {
  const Workspace({
    this.revision = 0,
    this.tasks = const [],
    this.entries = const [],
    this.goals = const [],
    this.drafts = const [],
    this.preferences = const SeraPreferences(),
    this.focusRecords = const [],
    this.history = const [],
    this.externalBusyEntries = const [],
    this.planningSessions = const [],
    this.focusSession,
    this.reviews = const [],
    this.reminderStates = const {},
    this.platformSettings = const {},
    this.entityVersions = const {},
  });
  final List<CalendarEntry> externalBusyEntries;
  final List<PlanningSession> planningSessions;
  final FocusSession? focusSession;
  final List<ReviewRecord> reviews;
  final Json reminderStates, platformSettings, entityVersions;
  final int revision;
  final List<SeraTask> tasks;
  final List<CalendarEntry> entries;
  final List<SeraGoal> goals;
  final List<PlanDraft> drafts;
  final SeraPreferences preferences;
  final List<FocusRecord> focusRecords;
  final List<ChangeRecord> history;
  Workspace copyWith({
    int? revision,
    List<SeraTask>? tasks,
    List<CalendarEntry>? entries,
    List<SeraGoal>? goals,
    List<PlanDraft>? drafts,
    SeraPreferences? preferences,
    List<FocusRecord>? focusRecords,
    List<ChangeRecord>? history,
    List<CalendarEntry>? externalBusyEntries,
    List<PlanningSession>? planningSessions,
    FocusSession? focusSession,
    bool clearFocusSession = false,
    List<ReviewRecord>? reviews,
    Json? reminderStates,
    Json? platformSettings,
    Json? entityVersions,
  }) => Workspace(
    revision: revision ?? this.revision,
    tasks: tasks ?? this.tasks,
    entries: entries ?? this.entries,
    goals: goals ?? this.goals,
    drafts: drafts ?? this.drafts,
    preferences: preferences ?? this.preferences,
    focusRecords: focusRecords ?? this.focusRecords,
    history: history ?? this.history,
    externalBusyEntries: externalBusyEntries ?? this.externalBusyEntries,
    planningSessions: planningSessions ?? this.planningSessions,
    focusSession: clearFocusSession ? null : focusSession ?? this.focusSession,
    reviews: reviews ?? this.reviews,
    reminderStates: reminderStates ?? this.reminderStates,
    platformSettings: platformSettings ?? this.platformSettings,
    entityVersions: entityVersions ?? this.entityVersions,
  );
  Json toJson() => {
    'schemaVersion': 2,
    'revision': revision,
    'tasks': tasks.map((e) => e.toJson()).toList(),
    'entries': entries.map((e) => e.toJson()).toList(),
    'goals': goals.map((e) => e.toJson()).toList(),
    'drafts': drafts.map((e) => e.toJson()).toList(),
    'preferences': preferences.toJson(),
    'focusRecords': focusRecords.map((e) => e.toJson()).toList(),
    'history': history.map((e) => e.toJson()).toList(),
    'externalBusyEntries': externalBusyEntries.map((e) => e.toJson()).toList(),
    'planningSessions': planningSessions.map((e) => e.toJson()).toList(),
    'focusSession': focusSession?.toJson(),
    'reviews': reviews.map((e) => e.toJson()).toList(),
    'reminderStates': reminderStates,
    'platformSettings': platformSettings,
    'entityVersions': entityVersions,
  };
  factory Workspace.fromJson(Json j) {
    final prefs = SeraPreferences.fromJson(
      Map<String, dynamic>.from(j['preferences'] as Map? ?? {}),
    );
    return Workspace(
      revision: (j['revision'] as num?)?.toInt() ?? 0,
      tasks: readList(
        j['tasks'],
        (v) => SeraTask.fromJson(v, displayZone: prefs.timeZone),
      ),
      entries: readList(
        j['entries'],
        (v) => CalendarEntry.fromJson(v, displayZone: prefs.timeZone),
      ),
      goals: readList(
        j['goals'],
        (v) => SeraGoal.fromJson(v, displayZone: prefs.timeZone),
      ),
      drafts: readList(
        j['drafts'],
        (v) => PlanDraft.fromJson(v, displayZone: prefs.timeZone),
      ),
      preferences: SeraPreferences.fromJson(
        Map<String, dynamic>.from(j['preferences'] as Map? ?? {}),
      ),
      focusRecords: readList(
        j['focusRecords'],
        (v) => FocusRecord.fromJson(v, displayZone: prefs.timeZone),
      ),
      history: readList(
        j['history'],
        (v) => ChangeRecord.fromJson(v, displayZone: prefs.timeZone),
      ),
      externalBusyEntries: readList(
        j['externalBusyEntries'],
        (v) => CalendarEntry.fromJson(v, displayZone: prefs.timeZone),
      ),
      planningSessions: readList(
        j['planningSessions'],
        (v) => PlanningSession.fromJson(v, displayZone: prefs.timeZone),
      ),
      focusSession: j['focusSession'] is Map
          ? FocusSession.fromJson(
              Map<String, dynamic>.from(j['focusSession'] as Map),
            )
          : null,
      reviews: readList(
        j['reviews'],
        (v) => ReviewRecord.fromJson(v, displayZone: prefs.timeZone),
      ),
      reminderStates: Map<String, dynamic>.from(
        j['reminderStates'] as Map? ?? {},
      ),
      platformSettings: Map<String, dynamic>.from(
        j['platformSettings'] as Map? ?? {},
      ),
      entityVersions: Map<String, dynamic>.from(
        j['entityVersions'] as Map? ?? {},
      ),
    );
  }
}
