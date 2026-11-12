part of 'models.dart';

class PlanningResultRef {
  const PlanningResultRef({required this.kind, required this.id});
  final String kind, id;
  Json toJson() => {'kind': kind, 'id': id};
  factory PlanningResultRef.fromJson(Json value) {
    final kind = value['kind'], id = value['id'];
    if (!const ['task', 'event'].contains(kind) ||
        id is! String ||
        id.isEmpty ||
        id.length > 128) {
      throw const FormatException('Invalid planning result reference');
    }
    return PlanningResultRef(kind: kind as String, id: id);
  }
}

/// A persisted, display-only turn. AI requests still use the approved input
/// snapshot, rather than sending the entire conversation automatically.
class PlanningMessage {
  const PlanningMessage({
    required this.id,
    required this.role,
    required this.text,
    this.understanding,
  });

  static const maxTextLength = 10000;
  // The existing AI context permits 16000 JSON characters. UTF-8 needs up to
  // four bytes per character, so storing a valid CJK/escaped reply must not
  // introduce a tighter bound than the request contract.
  static const maxUnderstandingBytes = 64000;
  final String id, role, text;
  final Json? understanding;

  Json toJson() {
    if (id.trim().isEmpty ||
        id.length > 128 ||
        !const ['user', 'assistant'].contains(role) ||
        text.length > maxTextLength ||
        (text.trim().isEmpty && understanding == null) ||
        (understanding != null && role != 'assistant')) {
      throw const FormatException('Invalid planning message');
    }
    Json? snapshot;
    if (understanding != null) {
      try {
        final encoded = jsonEncode(understanding);
        if (utf8.encode(encoded).length > maxUnderstandingBytes) {
          throw const FormatException('Planning message reply is too large');
        }
        snapshot = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
      } on FormatException {
        rethrow;
      } catch (_) {
        throw const FormatException('Invalid planning message reply');
      }
    }
    return {'id': id, 'role': role, 'text': text, 'understanding': ?snapshot};
  }

  factory PlanningMessage.fromJson(Json value) {
    if (!value.keys.every(
          const {'id', 'role', 'text', 'understanding'}.contains,
        ) ||
        value['id'] is! String ||
        value['role'] is! String ||
        value['text'] is! String ||
        (value['understanding'] != null && value['understanding'] is! Map)) {
      throw const FormatException('Invalid planning message');
    }
    final message = PlanningMessage(
      id: value['id'] as String,
      role: value['role'] as String,
      text: value['text'] as String,
      understanding: value['understanding'] == null
          ? null
          : Map<String, dynamic>.from(value['understanding'] as Map),
    );
    final snapshot = message.toJson();
    return PlanningMessage(
      id: message.id,
      role: message.role,
      text: message.text,
      understanding: snapshot['understanding'] as Json?,
    );
  }
}

List<Json> _planningMessageJson(List<PlanningMessage> messages) {
  if (messages.length > PlanningSession.maxMessages) {
    throw const FormatException('Too many planning messages');
  }
  final ids = <String>{};
  return [
    for (final message in messages)
      if (ids.add(message.id))
        message.toJson()
      else
        throw const FormatException('Duplicate planning message id'),
  ];
}

List<PlanningMessage> _readPlanningMessages(Object? value) {
  if (value == null) return const [];
  if (value is! List || value.length > PlanningSession.maxMessages) {
    throw const FormatException('Invalid planning conversation');
  }
  final messages = [
    for (final item in value)
      if (item is Map)
        PlanningMessage.fromJson(Map<String, dynamic>.from(item))
      else
        throw const FormatException('Invalid planning message'),
  ];
  _planningMessageJson(messages);
  return List.unmodifiable(messages);
}

String _readPlanningComposerDraft(Object? value) {
  if (value == null) return '';
  if (value is! String || value.length > PlanningMessage.maxTextLength) {
    throw const FormatException('Invalid planning composer draft');
  }
  return value;
}

class PlanningSession {
  const PlanningSession({
    required this.id,
    required this.updatedAt,
    this.prompt = '',
    this.title = '',
    this.notes = '',
    this.deadline,
    this.dailyBudget = 90,
    this.stage = 'input',
    this.draftId,
    this.aiRequestId,
    this.aiRequestNotes,
    this.aiError,
    this.targetTaskId,
    this.baseTaskRevision,
    this.understanding,
    this.understandingRequestId,
    this.understandingInput,
    this.clarificationAnswers = const {},
    this.deadlineIsDateOnly = false,
    this.resultEntity,
    this.messages = const [],
    this.composerDraft = '',
  });
  static const maxMessages = 100;
  final String id, prompt, title, notes, stage;
  final DateTime updatedAt;
  final DateTime? deadline;
  final int dailyBudget;
  final String? draftId;
  // The notes sent to the original job include the then-approved context.
  // Recomputing them after restart could change an idempotent request payload.
  final String? aiRequestId, aiRequestNotes, aiError;
  final String? targetTaskId;
  final int? baseTaskRevision;
  final Json? understanding, understandingInput;
  final String? understandingRequestId;
  final Map<String, String> clarificationAnswers;
  final bool deadlineIsDateOnly;
  final PlanningResultRef? resultEntity;
  final List<PlanningMessage> messages;
  // Unsent text is restored locally and synced, but never becomes AI input
  // until an explicit send action promotes it to a user message.
  final String composerDraft;
  PlanningSession copyWith({
    String? prompt,
    String? title,
    String? notes,
    DateTime? deadline,
    bool clearDeadline = false,
    int? dailyBudget,
    String? stage,
    String? draftId,
    String? aiRequestId,
    String? aiRequestNotes,
    String? aiError,
    bool clearAiRequest = false,
    bool clearAiError = false,
    String? targetTaskId,
    int? baseTaskRevision,
    DateTime? updatedAt,
    Json? understanding,
    String? understandingRequestId,
    Json? understandingInput,
    Map<String, String>? clarificationAnswers,
    bool? deadlineIsDateOnly,
    bool clearUnderstanding = false,
    bool clearUnderstandingRequest = false,
    PlanningResultRef? resultEntity,
    List<PlanningMessage>? messages,
    String? composerDraft,
  }) => PlanningSession(
    id: id,
    updatedAt: updatedAt ?? this.updatedAt,
    prompt: prompt ?? this.prompt,
    title: title ?? this.title,
    notes: notes ?? this.notes,
    deadline: clearDeadline ? null : deadline ?? this.deadline,
    dailyBudget: dailyBudget ?? this.dailyBudget,
    stage: stage ?? this.stage,
    draftId: draftId ?? this.draftId,
    aiRequestId: clearAiRequest ? null : aiRequestId ?? this.aiRequestId,
    aiRequestNotes: clearAiRequest
        ? null
        : aiRequestNotes ?? this.aiRequestNotes,
    aiError: clearAiError ? null : aiError ?? this.aiError,
    targetTaskId: targetTaskId ?? this.targetTaskId,
    baseTaskRevision: baseTaskRevision ?? this.baseTaskRevision,
    understanding: clearUnderstanding
        ? null
        : understanding ?? this.understanding,
    understandingRequestId: clearUnderstandingRequest
        ? null
        : understandingRequestId ?? this.understandingRequestId,
    understandingInput: clearUnderstandingRequest
        ? null
        : understandingInput ?? this.understandingInput,
    clarificationAnswers: clarificationAnswers ?? this.clarificationAnswers,
    deadlineIsDateOnly:
        deadlineIsDateOnly ?? (clearDeadline ? false : this.deadlineIsDateOnly),
    resultEntity: resultEntity ?? this.resultEntity,
    messages: messages ?? this.messages,
    composerDraft: composerDraft ?? this.composerDraft,
  );
  Json toJson() => {
    'id': id,
    'prompt': prompt,
    'title': title,
    'notes': notes,
    'deadline': deadline?.toUtc().toIso8601String(),
    'dailyBudget': dailyBudget,
    'stage': stage,
    'draftId': draftId,
    'aiRequestId': aiRequestId,
    'aiRequestNotes': aiRequestNotes,
    'aiError': aiError,
    'targetTaskId': targetTaskId,
    'baseTaskRevision': baseTaskRevision,
    'understanding': understanding,
    'understandingRequestId': understandingRequestId,
    'understandingInput': understandingInput,
    'clarificationAnswers': clarificationAnswers,
    'deadlineIsDateOnly': deadlineIsDateOnly,
    'resultEntity': resultEntity?.toJson(),
    'messages': _planningMessageJson(messages),
    'composerDraft': _readPlanningComposerDraft(composerDraft),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
  factory PlanningSession.fromJson(
    Json j, {
    String displayZone = 'Asia/Hong_Kong',
  }) => PlanningSession(
    id: '${j['id']}',
    updatedAt:
        readZoned(j['updatedAt'], displayZone) ??
        DateTime.fromMillisecondsSinceEpoch(0),
    prompt: j['prompt'] as String? ?? '',
    title: j['title'] as String? ?? '',
    notes: j['notes'] as String? ?? '',
    deadline: readZoned(j['deadline'], displayZone),
    dailyBudget: (j['dailyBudget'] as num?)?.toInt() ?? 90,
    stage: j['stage'] as String? ?? 'input',
    draftId: j['draftId'] as String?,
    aiRequestId: j['aiRequestId'] as String?,
    aiRequestNotes: j['aiRequestNotes'] as String?,
    aiError: j['aiError'] as String?,
    targetTaskId: j['targetTaskId'] as String?,
    baseTaskRevision: (j['baseTaskRevision'] as num?)?.toInt(),
    understanding: j['understanding'] is Map
        ? Map<String, dynamic>.from(j['understanding'] as Map)
        : null,
    understandingRequestId: j['understandingRequestId'] as String?,
    understandingInput: j['understandingInput'] is Map
        ? Map<String, dynamic>.from(j['understandingInput'] as Map)
        : null,
    clarificationAnswers: j['clarificationAnswers'] is Map
        ? (j['clarificationAnswers'] as Map).map(
            (key, value) => MapEntry('$key', '$value'),
          )
        : const {},
    deadlineIsDateOnly: j['deadlineIsDateOnly'] == true,
    resultEntity: j['resultEntity'] == null
        ? null
        : j['resultEntity'] is Map
        ? PlanningResultRef.fromJson(
            Map<String, dynamic>.from(j['resultEntity'] as Map),
          )
        : throw const FormatException('Invalid planning result reference'),
    messages: _readPlanningMessages(j['messages']),
    composerDraft: _readPlanningComposerDraft(j['composerDraft']),
  );
}

class FocusSession {
  const FocusSession({
    required this.id,
    required this.taskId,
    required this.startedAt,
    this.lastResumedAt,
    this.accumulatedSeconds = 0,
    this.isRunning = true,
    this.targetMinutes,
  });
  final String id, taskId;
  final DateTime startedAt;
  final DateTime? lastResumedAt;
  final int accumulatedSeconds;
  final bool isRunning;

  /// Fixed when this focus starts; later task/calendar edits do not retime it.
  final int? targetMinutes;
  int elapsedSeconds(DateTime now) =>
      accumulatedSeconds +
      (isRunning
          ? now.difference(lastResumedAt ?? startedAt).inSeconds.clamp(0, 86400)
          : 0);
  Json toJson() => {
    'id': id,
    'taskId': taskId,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'lastResumedAt': lastResumedAt?.toUtc().toIso8601String(),
    'accumulatedSeconds': accumulatedSeconds,
    'isRunning': isRunning,
    'targetMinutes': targetMinutes,
  };
  factory FocusSession.fromJson(Json j) {
    final target = j['targetMinutes'];
    if (target != null && (target is! int || target < 1 || target > 1440)) {
      throw const FormatException('Invalid focus target minutes');
    }
    return FocusSession(
      id: '${j['id']}',
      taskId: '${j['taskId']}',
      startedAt: parseDate(j['startedAt'])!,
      lastResumedAt: parseDate(j['lastResumedAt']),
      accumulatedSeconds: (j['accumulatedSeconds'] as num?)?.toInt() ?? 0,
      isRunning: j['isRunning'] != false,
      targetMinutes: target as int?,
    );
  }
}

class ReviewRecord {
  const ReviewRecord({
    required this.id,
    required this.day,
    this.kind = 'daily',
    this.feedback = '',
  });
  final String id, kind, feedback;
  final DateTime day;
  Json toJson() => {
    'id': id,
    'day':
        '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
    'kind': kind,
    'feedback': feedback,
  };
  factory ReviewRecord.fromJson(
    Json j, {
    String displayZone = 'Asia/Hong_Kong',
  }) => ReviewRecord(
    id: '${j['id']}',
    day: readZoned(j['day'], displayZone)!,
    kind: j['kind'] as String? ?? 'daily',
    feedback: j['feedback'] as String? ?? '',
  );
}
