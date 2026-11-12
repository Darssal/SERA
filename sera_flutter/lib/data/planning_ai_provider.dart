import '../domain/planning_service.dart';
import '../domain/models.dart';
import 'workspace_repository.dart';

class AiQuestion {
  const AiQuestion({required this.id, required this.question});
  final String id, question;
  Json toJson() => {'id': id, 'question': question};
}

/// A model interpretation is a proposal. It never creates business objects.
class AiUnderstanding {
  const AiUnderstanding({
    required this.intent,
    required this.title,
    required this.summary,
    required this.outcome,
    required this.model,
    this.deadline,
    this.deadlineIsDateOnly = false,
    this.dailyBudget,
    this.estimatedMinutes,
    this.start,
    this.end,
    this.questions = const [],
  });
  final String intent, title, summary, outcome, model;
  final DateTime? deadline, start, end;
  final bool deadlineIsDateOnly;
  final int? dailyBudget, estimatedMinutes;
  final List<AiQuestion> questions;
  Json toJson() => {
    'intent': intent,
    'title': title,
    'summary': summary,
    'outcome': outcome,
    'deadline': deadline?.toUtc().toIso8601String(),
    'deadlineIsDateOnly': deadlineIsDateOnly,
    'dailyBudget': dailyBudget,
    'estimatedMinutes': estimatedMinutes,
    'start': start?.toUtc().toIso8601String(),
    'end': end?.toUtc().toIso8601String(),
    'questions': questions.map((question) => question.toJson()).toList(),
    'source': 'siliconflow',
    'model': model,
  };
  factory AiUnderstanding.fromJson(Json json) {
    DateTime? instant(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! String || value.length > 64) {
        throw const RepositoryException('AI 返回的时间缺少时区，请重新理解。');
      }
      final parts = RegExp(
        r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,6}))?)?(Z|[+-](\d{2}):(\d{2}))$',
      ).firstMatch(value);
      if (parts == null) {
        throw const RepositoryException('AI 返回的时间缺少有效日期或时区，请重新理解。');
      }
      int number(int group) => int.parse(parts.group(group) ?? '0');
      final year = number(1), month = number(2), day = number(3);
      final calendar = DateTime.utc(year, month, day);
      // DateTime.tryParse normalizes e.g. February 31 and 24:00. Model output
      // must describe the user's actual time rather than roll into another day.
      if (year < 1 ||
          calendar.year != year ||
          calendar.month != month ||
          calendar.day != day ||
          number(4) > 23 ||
          number(5) > 59 ||
          number(6) > 59 ||
          number(9) > 23 ||
          number(10) > 59) {
        throw const RepositoryException('AI 返回的时间无效，请重新理解。');
      }
      return DateTime.parse(value);
    }

    if (json['source'] != 'siliconflow' ||
        !const ['goal', 'task', 'event', 'other'].contains(json['intent']) ||
        json['title'] is! String ||
        json['summary'] is! String ||
        json['outcome'] is! String ||
        (json['title'] as String).trim().isEmpty ||
        (json['title'] as String).length > 200 ||
        (json['summary'] as String).length > 1000 ||
        (json['outcome'] as String).length > 2000 ||
        json['model'] is! String ||
        (json['model'] as String).trim().isEmpty ||
        json['deadlineIsDateOnly'] is! bool ||
        json['questions'] is! List) {
      throw const RepositoryException('AI 理解结果不完整，请重新理解。');
    }
    final budget = json['dailyBudget'];
    final minutes = json['estimatedMinutes'];
    if (budget != null && (budget is! int || budget < 15 || budget > 480) ||
        minutes != null && (minutes is! int || minutes < 5 || minutes > 480)) {
      throw const RepositoryException('AI 理解结果中的时间预算无效。');
    }
    final questions = (json['questions'] as List).map((value) {
      if (value is! Map ||
          value['id'] is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{1,40}$').hasMatch(value['id'] as String) ||
          value['question'] is! String ||
          (value['question'] as String).trim().isEmpty ||
          (value['question'] as String).length > 300) {
        throw const RepositoryException('AI 的追问格式无效，请重新理解。');
      }
      return AiQuestion(
        id: value['id'] as String,
        question: (value['question'] as String).trim(),
      );
    }).toList();
    if (questions.length > 3 ||
        questions.map((q) => q.id).toSet().length != questions.length) {
      throw const RepositoryException('AI 的追问数量或标识无效。');
    }
    final deadline = instant('deadline');
    final start = instant('start'), end = instant('end');
    if (json['deadlineIsDateOnly'] == true && deadline == null) {
      throw const RepositoryException('AI 截止日期精度无效，请重新理解。');
    }
    if (start != null && end != null && !end.isAfter(start)) {
      throw const RepositoryException('AI 建议的结束时间必须晚于开始时间。');
    }
    return AiUnderstanding(
      intent: json['intent'] as String,
      title: (json['title'] as String).trim(),
      summary: (json['summary'] as String).trim(),
      outcome: (json['outcome'] as String).trim(),
      model: (json['model'] as String).trim(),
      deadline: deadline,
      deadlineIsDateOnly: json['deadlineIsDateOnly'] as bool,
      dailyBudget: budget as int?,
      estimatedMinutes: minutes as int?,
      start: start,
      end: end,
      questions: questions,
    );
  }
}

abstract interface class InputUnderstandingProvider {
  Future<AiUnderstanding> understandInput({
    required Json input,
    required String requestId,
    void Function(String stage)? onStage,
  });
}

abstract interface class CancellableInputUnderstandingProvider {
  void cancelUnderstanding();
}

class AiPlanResult {
  const AiPlanResult({
    required this.tasks,
    required this.model,
    this.source = 'siliconflow',
  });
  final List<TaskOutline> tasks;
  final String model, source;
}

/// Only the server knows the provider credential. Flutter sends goal data to
/// the application's own API and never receives a provider API key.
abstract interface class PlanningAiProvider {
  Future<AiPlanResult> generateTaskBreakdown({
    required String title,
    required DateTime deadline,
    required int dailyBudget,
    String notes = '',
    String prompt = '',
    String? requestId,
  });
}

abstract interface class CancellablePlanningAiProvider {
  void cancelPlanning();
}
