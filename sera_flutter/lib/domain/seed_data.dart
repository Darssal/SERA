import 'models.dart';

Workspace createSeedWorkspace(DateTime today) {
  final day = dateOnly(today);
  DateTime at(int offset, int hour, [int minute = 0]) =>
      DateTime(day.year, day.month, day.day + offset, hour, minute);
  const titles = [
    '梳理方案框架',
    '整理用户访谈资料',
    '完成关键页面设计',
    '准备评审演示稿',
    '根据反馈调整方案',
    '检查并提交评审材料',
  ];
  const durations = [45, 45, 60, 60, 30, 30];
  const offsets = [0, 0, 1, 2, 3, 3];
  const hours = [14, 16, 14, 14, 14, 15];
  const notes = [
    '先把方案的骨架搭起来，形成一页可讨论的提纲。',
    '提炼访谈中的共性问题，整理支持方案的关键依据。',
    '围绕关键用户路径完成页面，并补充状态说明。',
    '讲清问题、方案与预期结果，准备演示顺序。',
    '记录评审反馈，优先处理影响主流程的问题。',
    '核对文案、链接和材料完整性，完成最后提交。',
  ];
  final tasks = List.generate(
    6,
    (i) => SeraTask(
      id: 'task-${i + 1}',
      title: titles[i],
      notes: notes[i],
      goalId: 'goal-review',
      estimatedMinutes: durations[i],
      dueAt: at(offsets[i], 18),
      checklist: i == 0
          ? const ['明确评审的核心问题', '整理关键用户路径', '形成一页方案提纲']
          : const [],
    ),
  );
  return Workspace(
    tasks: [
      ...tasks,
      SeraTask(
        id: 'task-inbox-1',
        title: '整理十月报销单',
        notes: '收集票据，整理后提交。',
        dueAt: at(1, 18),
      ),
      const SeraTask(
        id: 'task-inbox-2',
        title: '预约下周的牙齿检查',
        estimatedMinutes: 15,
      ),
    ],
    entries: [
      for (var i = 0; i < tasks.length; i++)
        CalendarEntry(
          id: 'entry-${i + 1}',
          title: titles[i],
          taskId: tasks[i].id,
          start: at(offsets[i], hours[i]),
          end: at(offsets[i], hours[i]).add(Duration(minutes: durations[i])),
        ),
      CalendarEntry(
        id: 'meeting-1',
        title: '产品周会',
        start: at(0, 10),
        end: at(0, 11),
        place: '会议室 A · 线上会议',
        locked: true,
      ),
    ],
    goals: [
      SeraGoal(
        id: 'goal-review',
        title: '准备项目方案评审',
        deadline: at(7, 15),
        outcome: '形成清楚、完整、可讨论的方案，让评审从容一点。',
        taskIds: tasks.map((e) => e.id).toList(),
      ),
    ],
  );
}
