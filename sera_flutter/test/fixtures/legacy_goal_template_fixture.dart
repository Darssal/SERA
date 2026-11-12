import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/domain/planning_service.dart';

/// Test-only historical payload. The app no longer offers or creates this
/// template, but saved local-template drafts remain ordinary editable drafts.
PlanDraft legacyGoalDraft(
  Workspace workspace,
  DateTime now, {
  String title = '整理完书桌',
  String outcome = '桌面只留下电脑和台灯，其他物品都有固定位置。',
  String requestId = 'legacy-template-fixture',
}) {
  var nextId = 0;
  final draft = const PlanningService()
      .generate(
        workspace: workspace,
        today: now,
        title: title,
        deadline: _LegacyGoalTemplate.deadline(now),
        dailyBudget: workspace.preferences.dailyBudget,
        notes: outcome,
        prompt: _LegacyGoalTemplate.title,
        newId: (kind) => '$requestId-$kind-${nextId++}',
        outlines: _LegacyGoalTemplate.tasks,
        source: 'local-template',
        suggestBudgetOverflow: true,
      )
      .copyWith(aiRequestId: requestId);
  return PlanDraft.fromJson(
    draft.toJson(),
    displayZone: workspace.preferences.timeZone,
  );
}

abstract final class _LegacyGoalTemplate {
  static const title = '7天，完成一件小事';
  static const days = 7;
  static const tasks = <TaskOutline>[
    TaskOutline(
      title: '选定一件小事并写下完成标准',
      estimatedMinutes: 15,
      checklist: ['选一件这周能完成的小事', '写下做到什么就算完成'],
    ),
    TaskOutline(
      title: '做出第一步',
      estimatedMinutes: 25,
      checklist: ['准备最少需要的材料或工具', '完成一个能看见的小进展'],
    ),
    TaskOutline(
      title: '继续推进关键部分',
      estimatedMinutes: 25,
      checklist: ['接着上次的进展继续做', '完成最影响结果的部分'],
    ),
    TaskOutline(
      title: '检查成果并完成收尾',
      estimatedMinutes: 20,
      checklist: ['对照完成标准检查一次', '补齐缺漏并保存成果'],
    ),
    TaskOutline(
      title: '回顾并记下下一步',
      estimatedMinutes: 10,
      checklist: ['记下一件这次做得好的事', '决定到此完成，或记下下一步'],
    ),
  ];

  /// Calendar arithmetic keeps the deadline at the selected zone's day end,
  /// including weeks that cross a daylight-saving transition.
  static DateTime deadline(DateTime planningNow) =>
      atMinute(calendarDay(planningNow, days), 1439);
}
