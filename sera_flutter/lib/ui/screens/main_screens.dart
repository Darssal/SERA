import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../application/sera_controller.dart';
import '../../application/device_cloud_sync.dart';
import '../../data/auth_repository.dart';
import '../../data/workspace_repository.dart';
import '../../domain/models.dart';
import '../../domain/todo_queries.dart';
import '../core/sera_capture_entry.dart';
import '../core/sera_plan_switcher.dart';
import '../core/sera_todo_row.dart';
import '../core/sera_widgets.dart';
import '../core/calendar_time_grid.dart';
import '../core/sera_motion.dart';
import '../core/sera_flow_return.dart';
import 'platform_screens.dart';

bool _sameMainOwner(
  BuildContext context,
  SeraController controller,
  AuthRepository? auth,
  AuthSession? session,
) =>
    context.mounted &&
    identical(context.read<SeraController>(), controller) &&
    identical(context.read<AuthRepository?>(), auth) &&
    auth?.session?.user.id == session?.user.id &&
    auth?.session?.sessionId == session?.sessionId &&
    auth?.session?.token == session?.token;

Widget buildMainScreen(String id, {String? goalId}) => switch (id) {
  '04' => const TodayScreen(),
  '12' || '13' || '14' => CalendarScreen(view: id),
  '20' => const GoalsScreen(),
  '21' => GoalsScreen(goalId: goalId, detail: true),
  '30' => const ProfileScreen(),
  '31' => const PreferencesScreen(),
  '32' => buildPlatformScreen('32'),
  '33' => buildPlatformScreen('33'),
  '35' => const SearchScreen(),
  '36' => const PrivacyScreen(),
  _ => const TodayScreen(),
};

class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});

  @override
  State<TodayScreen> createState() => _TodayState();
}

class _TodayState extends State<TodayScreen> {
  SeraTaskCompletion? _lastCompletion;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SeraController>();
    final entries = c.entriesOn(c.today);
    final todos = todayTodoTasks(
      tasks: c.data.tasks,
      entries: c.data.entries,
      day: c.today,
    );
    final focus = c.data.focusSession;
    final focusTask = focus == null ? null : c.task(focus.taskId);
    final fixed = entries.where((entry) => !entry.isTask).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    final wallNow = DateTime.now();
    final now = calendarDateString(wallNow) == calendarDateString(c.today)
        ? wallNow
        : dateOnly(c.today);
    final nextEvent = fixed
        .where((entry) => entry.end.isAfter(now))
        .firstOrNull;
    return SeraScaffold(
      title: '今日',
      showBack: false,
      navIndex: 0,
      footer: _lastCompletion?.canUndoWith(c) == true
          ? SeraCompletionUndo(_lastCompletion!)
          : null,
      actions: [
        PopupMenuButton<String>(
          tooltip: '今日更多',
          popUpAnimationStyle: SeraMotion.dialogStyle(context),
          icon: const Icon(Icons.more_horiz),
          onSelected: (value) => context.push(value),
          itemBuilder: (_) => const [
            PopupMenuItem(value: '/28', child: Text('今日回顾')),
            PopupMenuItem(value: '/29', child: Text('本周回顾')),
            PopupMenuItem(value: '/27', child: Text('提醒中心')),
          ],
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            formatDate(c.today),
            style: const TextStyle(fontSize: 13, color: SeraColors.muted),
          ),
          const SizedBox(height: 12),
          const SeraCaptureEntry(origin: 'today'),
          if (focusTask != null) ...[
            const SizedBox(height: 12),
            SeraSettingRow(
              '继续专注',
              subtitle: focusTask.title,
              icon: 'clock',
              onTap: () => openScreen(context, '25', taskId: focusTask.id),
            ),
          ],
          const SizedBox(height: 24),
          const Text(
            '今天要做',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          if (todos.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '今天没有待完成的任务',
                style: TextStyle(fontSize: 15, color: SeraColors.muted),
              ),
            ),
          for (final task in todos)
            SeraTodoRow(
              task,
              key: ValueKey('today-todo:${task.id}'),
              entry: entries
                  .where((entry) => entry.taskId == task.id)
                  .firstOrNull,
              onTap: () => openScreen(context, '18', taskId: task.id),
              onCheck: c.busy || !task.active
                  ? null
                  : (check, done) => runAction(
                      context,
                      () => c.setCheck(task.id, check, done),
                    ),
              onDone: c.busy
                  ? null
                  : (done) async {
                      final auth = context.read<AuthRepository?>();
                      final session = auth?.session;
                      final result = await completeTaskFromList(
                        context,
                        c,
                        task,
                        done,
                      );
                      if (mounted &&
                          context.mounted &&
                          _sameMainOwner(context, c, auth, session)) {
                        setState(() => _lastCompletion = result);
                      }
                    },
            ),
          if (nextEvent != null) ...[
            const SizedBox(height: 24),
            const Text(
              '下一项日程',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            SeraAgendaRow(
              nextEvent,
              onTap: () => openScreen(context, '15', eventId: nextEvent.id),
            ),
          ],
        ],
      ),
    );
  }
}

class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key, required this.view, this.focusEntryId});
  final String view;
  final String? focusEntryId;
  DateTime _move(DateTime date, int delta, String zone) {
    if (view == '14') {
      final month = inTimeZone(
        DateTime(date.year, date.month + delta, 1),
        zone,
        wallClock: true,
      );
      final last = DateUtils.getDaysInMonth(month.year, month.month);
      return calendarDay(month, date.day.clamp(1, last) - 1);
    }
    return calendarDay(date, delta * (view == '13' ? 7 : 1));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SeraController>();
    final focusId =
        focusEntryId ??
        GoRouterState.of(context).uri.queryParameters['focusEntryId'];
    final date = dateOnly(
      inTimeZone(c.selectedDate, c.data.preferences.timeZone, wallClock: true),
    );
    final entries = c.entriesOn(date);
    final start = calendarDay(date, 1 - date.weekday);
    return SeraScaffold(
      title: '日程',
      showBack: false,
      navIndex: 2,
      actions: [
        if (entries.any(
          (entry) =>
              entry.isTask &&
              !entry.locked &&
              c.task(entry.taskId)?.active == true,
        ))
          IconButton(
            tooltip: '调整安排',
            onPressed: () =>
                context.push('/22?date=${calendarDateString(date)}'),
            icon: const SeraIcon('refresh'),
          ),
        IconButton(
          tooltip: '添加日程',
          onPressed: () => openScreen(context, '16'),
          icon: const SeraIcon('plus'),
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${date.year}年${date.month}月',
                  style: const TextStyle(
                    fontSize: 18,
                    height: 26 / 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => c.setSelectedDate(c.today),
                child: const Text('今天'),
              ),
              IconButton(
                tooltip: view == '14'
                    ? '上个月'
                    : view == '13'
                    ? '上一周'
                    : '前一天',
                onPressed: () => c.setSelectedDate(
                  _move(date, -1, c.data.preferences.timeZone),
                ),
                icon: const SeraIcon('back', size: 19),
              ),
              IconButton(
                tooltip: view == '14'
                    ? '下个月'
                    : view == '13'
                    ? '下一周'
                    : '后一天',
                onPressed: () => c.setSelectedDate(
                  _move(date, 1, c.data.preferences.timeZone),
                ),
                icon: const SeraIcon('chevron', size: 19),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            expandedInsets: EdgeInsets.zero,
            segments: const [
              ButtonSegment(value: '12', label: Text('日')),
              ButtonSegment(value: '13', label: Text('工作周')),
              ButtonSegment(value: '14', label: Text('月')),
            ],
            selected: {view},
            showSelectedIcon: false,
            onSelectionChanged: (s) {
              FocusManager.instance.primaryFocus?.unfocus();
              context.go('/${s.first}');
            },
            style: SegmentedButton.styleFrom(
              minimumSize: const Size(88, 48),
              selectedBackgroundColor: SeraColors.brand,
              selectedForegroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          if (view == '14')
            _month(context, c, date)
          else if (view != '13')
            Row(
              children: List.generate(7, (i) {
                final d = calendarDay(start, i);
                final active = dateOnly(d) == dateOnly(date);
                return Expanded(
                  child: InkWell(
                    onTap: () => c.setSelectedDate(d),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: active ? SeraColors.brand : Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        children: [
                          Text(
                            ['一', '二', '三', '四', '五', '六', '日'][i],
                            style: TextStyle(
                              fontSize: 13,
                              color: active ? Colors.white : SeraColors.muted,
                            ),
                          ),
                          const SizedBox(height: 7),
                          Text(
                            '${d.day}',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: active ? Colors.white : SeraColors.ink,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          if (view == '13') ...[
            SeraCalendarTimeGrid(
              controller: c,
              days: List.generate(5, (i) => calendarDay(start, i)),
              focusEntryId: focusId,
            ),
            const SizedBox(height: 18),
            const Wrap(
              spacing: 8,
              children: [
                SeraTag('专注任务'),
                SeraTag(
                  '固定日程',
                  color: SeraColors.muted,
                  background: SeraColors.line,
                ),
              ],
            ),
          ] else ...[
            if (view == '14')
              SeraSection(formatDate(date))
            else
              const SizedBox(height: 24),
            if (entries.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '这一天没有安排',
                  style: TextStyle(fontSize: 15, color: SeraColors.muted),
                ),
              ),
            if (view == '12' && entries.isNotEmpty)
              SeraCalendarAgenda(
                controller: c,
                day: date,
                focusEntryId: focusId,
              ),
            if (view == '14')
              ...entries.map(
                (e) => SeraAgendaRow(
                  e,
                  onTap: () => openScreen(
                    context,
                    e.isTask ? '18' : '15',
                    taskId: e.taskId,
                    eventId: e.id,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _month(BuildContext context, SeraController c, DateTime date) {
    final first = inTimeZone(
      DateTime(date.year, date.month, 1),
      c.data.preferences.timeZone,
      wallClock: true,
    );
    final start = calendarDay(first, 1 - first.weekday);
    return Column(
      children: [
        Row(
          children: ['一', '二', '三', '四', '五', '六', '日']
              .map(
                (s) => Expanded(
                  child: Center(
                    child: Text(
                      s,
                      style: const TextStyle(
                        fontSize: 13,
                        color: SeraColors.muted,
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 8),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 42,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            childAspectRatio: .92,
          ),
          itemBuilder: (context, i) {
            final d = calendarDay(start, i);
            final active = dateOnly(d) == dateOnly(date);
            final count = c.entriesOn(d).length;
            return InkWell(
              onTap: () => c.setSelectedDate(d),
              child: Container(
                margin: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: active ? SeraColors.brand : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '${d.day}',
                      style: TextStyle(
                        fontSize: 14,
                        color: active
                            ? Colors.white
                            : d.month != date.month
                            ? SeraColors.muted
                            : SeraColors.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (count > 0)
                      Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                          color: active ? Colors.white : SeraColors.brand,
                          shape: BoxShape.circle,
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class GoalsScreen extends StatefulWidget {
  const GoalsScreen({super.key, this.goalId, this.detail = false});
  final String? goalId;
  final bool detail;
  @override
  State<GoalsScreen> createState() => _GoalsScreenState();
}

class _GoalsScreenState extends State<GoalsScreen> {
  String? get goalId => widget.goalId;
  bool get detail => widget.detail;
  SeraTaskCompletion? _lastCompletion;

  @override
  Widget build(BuildContext context) {
    final c = context.read<SeraController>();
    // Focus ticks and unrelated workspace fields do not rebuild this list.
    final goals = context.select((SeraController controller) {
      final selectedGoal =
          controller.goal(goalId) ??
          (goalId == null ? controller.data.goals.firstOrNull : null);
      return detail ? <SeraGoal>[?selectedGoal] : controller.data.goals;
    });
    final goalIds = goals.map((goal) => goal.id).toSet();
    final goalTasks = context.select(
      (SeraController controller) => controller.data.tasks
          .where((task) => goalIds.contains(task.goalId))
          .toList(),
    );
    final taskIds = goalTasks.map((task) => task.id).toSet();
    final view = (
      goals: goals,
      tasks: goalTasks,
      entries: context.select(
        (SeraController controller) => detail
            ? controller.data.entries
                  .where((entry) => taskIds.contains(entry.taskId))
                  .toList()
            : const <CalendarEntry>[],
      ),
      drafts: context.select(
        (SeraController controller) => detail
            ? const <PlanDraft>[]
            : controller.data.drafts
                  .where((draft) => draft.status == 'draft')
                  .toList(),
      ),
      busy: context.select((SeraController controller) => controller.busy),
      accountId: context.select(
        (SeraController controller) => controller.accountId,
      ),
    );
    final goal =
        view.goals.where((goal) => goal.id == goalId).firstOrNull ??
        (goalId == null ? view.goals.firstOrNull : null);
    final tasksByGoal = <String, List<SeraTask>>{};
    for (final task in view.tasks) {
      final ownerGoal = task.goalId;
      if (ownerGoal != null) (tasksByGoal[ownerGoal] ??= []).add(task);
    }
    final tasks = goal == null
        ? const <SeraTask>[]
        : tasksByGoal[goal.id] ?? const <SeraTask>[];
    final firstEntries = <String, CalendarEntry>{};
    for (final entry in view.entries) {
      if (entry.taskId != null) {
        firstEntries.putIfAbsent(entry.taskId!, () => entry);
      }
    }
    final taskPositions = {
      for (var i = 0; i < tasks.length; i++) tasks[i].id: i,
    };
    final completion = _lastCompletion?.canUndoWith(c) == true
        ? _lastCompletion
        : null;
    return SeraScaffold(
      title: detail ? '目标详情' : '计划',
      showBack: detail,
      onBack: detail
          ? () {
              if (context.canPop()) {
                context.pop();
              } else {
                context.go('/20');
              }
            }
          : null,
      navIndex: detail ? null : 1,
      scrollKey: PageStorageKey(
        'goals:${view.accountId}:${detail ? goalId ?? goal?.id : 'list'}',
      ),
      actions: detail
          ? []
          : [
              IconButton(
                tooltip: '创建目标',
                onPressed: () => context.push('/05?new=1&from=goals'),
                icon: const SeraIcon('plus'),
              ),
            ],
      footer: detail
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (completion != null) SeraCompletionUndo(completion),
                SeraButton(
                  '编辑目标计划',
                  icon: 'spark',
                  onPressed: goal == null || view.busy
                      ? null
                      : () => runAction(context, () async {
                          final route = ModalRoute.of(context);
                          final auth = context.read<AuthRepository?>();
                          final session = auth?.session;
                          final draft = await c.editGoalPlan(goal.id);
                          if (context.mounted &&
                              route?.isCurrent == true &&
                              _sameMainOwner(context, c, auth, session)) {
                            openScreen(context, '08', draftId: draft.id);
                          }
                        }),
                ),
              ],
            )
          : null,
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!detail) ...[
                const SeraPlanSwitcher(goals: true),
                const SizedBox(height: 16),
                if (view.goals.isEmpty && view.drafts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Text(
                      '还没有目标，点击＋创建',
                      style: TextStyle(fontSize: 15, color: SeraColors.muted),
                    ),
                  ),
                ...view.goals
                    .where((g) => g.status != 'archived')
                    .map(
                      (g) =>
                          _goalCard(context, g, tasksByGoal[g.id] ?? const []),
                    ),
                if (view.goals.any((g) => g.status == 'archived'))
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(
                      '已归档目标 · ${view.goals.where((g) => g.status == 'archived').length}',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    children: [
                      for (final goal in view.goals.where(
                        (g) => g.status == 'archived',
                      ))
                        _goalCard(
                          context,
                          goal,
                          tasksByGoal[goal.id] ?? const [],
                        ),
                    ],
                  ),
                if (view.drafts.isNotEmpty) ...[
                  const SeraSection('待确认的草案'),
                  ...view.drafts.map(
                    (d) => SeraSettingRow(
                      d.goal.title,
                      subtitle: '${d.items.length} 项任务 · 仅保存草案',
                      icon: 'edit',
                      onTap: () => context.push(
                        Uri(
                          path: '/08',
                          queryParameters: {'draftId': d.id, 'from': 'goals'},
                        ).toString(),
                      ),
                    ),
                  ),
                ],
              ] else if (goal == null)
                const SeraEmpty('目标不存在', '返回目标列表，或创建一个新的目标。', icon: 'target')
              else ...[
                SeraIntro(
                  goal.title,
                  subtitle: goal.outcome,
                  eyebrow: '${formatDate(goal.deadline)} 截止',
                ),
                SeraTag(_goalStatus(goal.status)),
                const SizedBox(height: 12),
                _goalCard(context, goal, tasks, clickable: false),
                SeraSettingRow(
                  '修改目标信息',
                  icon: 'edit',
                  onTap: () => _editGoal(context, c, goal),
                ),
                if (goal.status != 'completed' &&
                    goal.status != 'archived' &&
                    !tasks.any((task) => task.active))
                  TextButton(
                    onPressed: view.busy
                        ? null
                        : () => _completeGoal(context, c, goal),
                    child: const Text('验收完成'),
                  ),
                const SeraSection('任务清单'),
                if (tasks.isEmpty)
                  const Text('暂无任务', style: TextStyle(color: SeraColors.muted)),
              ],
            ],
          ),
        ),
        if (detail && goal != null)
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (rowContext, index) {
                final task = tasks[index];
                return SeraTodoRow(
                  task,
                  key: ValueKey('goal-task:${task.id}'),
                  entry: firstEntries[task.id],
                  onTap: () => openScreen(context, '18', taskId: task.id),
                  onCheck: view.busy || !task.active
                      ? null
                      : (check, done) => runAction(
                          context,
                          () => c.setCheck(task.id, check, done),
                        ),
                  onDone: view.busy || task.status == 'canceled'
                      ? null
                      : (done) async {
                          final auth = context.read<AuthRepository?>();
                          final session = auth?.session;
                          final result = await completeTaskFromList(
                            context,
                            c,
                            task,
                            done,
                          );
                          if (mounted &&
                              context.mounted &&
                              _sameMainOwner(context, c, auth, session)) {
                            setState(() => _lastCompletion = result);
                          }
                        },
                );
              },
              childCount: tasks.length,
              findChildIndexCallback: (key) =>
                  key is ValueKey<String> && key.value.startsWith('goal-task:')
                  ? taskPositions[key.value.substring('goal-task:'.length)]
                  : null,
            ),
          ),
      ],
    );
  }

  String _goalStatus(String status) => switch (status) {
    'paused' => '已暂停',
    'completed' => '已完成',
    'archived' => '已归档',
    _ => '进行中',
  };

  Future<void> _completeGoal(
    BuildContext context,
    SeraController c,
    SeraGoal goal,
  ) async {
    final ownerRoute = ModalRoute.of(context);
    if (c.busy || ownerRoute?.isCurrent != true) return;
    final auth = context.read<AuthRepository?>();
    final session = auth?.session;
    final accepted = await showDialog<bool>(
      context: context,
      animationStyle: SeraMotion.dialogStyle(context),
      builder: (dialogContext) => AlertDialog(
        title: const Text('目标已经达成了吗？'),
        scrollable: true,
        content: Text(goal.outcome.isEmpty ? goal.title : goal.outcome),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('再看看'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认完成'),
          ),
        ],
      ),
    );
    if (accepted != true ||
        !context.mounted ||
        ownerRoute?.isCurrent != true ||
        !_sameMainOwner(context, c, auth, session)) {
      return;
    }
    await runAction(context, () async {
      if (c.goal(goal.id)?.revision != goal.revision) {
        throw const RepositoryException('目标已有新修改，请重新查看后验收。', conflict: true);
      }
      await c.setGoalStatus(goal.id, 'completed');
    });
  }

  Widget _goalCard(
    BuildContext context,
    SeraGoal g,
    List<SeraTask> tasks, {
    bool clickable = true,
  }) {
    final done = tasks.where((e) => e.done).length;
    if (!clickable) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SeraProgress(tasks.isEmpty ? 0 : done / tasks.length),
          const SizedBox(height: 8),
          Text(
            '已完成 $done / ${tasks.length} 项任务',
            style: const TextStyle(fontSize: 13, color: SeraColors.muted),
          ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: InkWell(
        onTap: clickable
            ? () => context.push('/21?goalId=${Uri.encodeComponent(g.id)}')
            : null,
        borderRadius: BorderRadius.circular(20),
        child: SeraCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SeraTag(_goalStatus(g.status)),
                  const SizedBox(width: 8),
                  if (clickable)
                    Expanded(
                      child: Text(
                        '${formatDate(g.deadline)} 截止',
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          fontSize: 13,
                          color: SeraColors.muted,
                        ),
                      ),
                    ),
                ],
              ),
              if (clickable) ...[
                const SizedBox(height: 15),
                Text(
                  g.title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              SeraProgress(tasks.isEmpty ? 0 : done / tasks.length),
              const SizedBox(height: 10),
              Text(
                '已完成 $done / ${tasks.length} 项任务',
                style: const TextStyle(fontSize: 13, color: SeraColors.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editGoal(
    BuildContext context,
    SeraController c,
    SeraGoal goal,
  ) async {
    final ownerRoute = ModalRoute.of(context);
    final auth = context.read<AuthRepository?>();
    final session = auth?.session;
    final title = TextEditingController(text: goal.title),
        outcome = TextEditingController(text: goal.outcome);
    var deadline = goal.deadline;
    var status = goal.status;
    var saving = false;
    String? saveError;
    late final DialogRoute<void> dialogRoute;
    bool ownsDialog() =>
        _sameMainOwner(context, c, auth, session) &&
        ownerRoute?.isActive == true &&
        dialogRoute.isCurrent;
    dialogRoute = DialogRoute<void>(
      context: context,
      animationStyle: SeraMotion.dialogStyle(context),
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDialog) => PopScope(
          canPop: !saving,
          child: AlertDialog(
            title: const Text('修改目标信息'),
            scrollable: true,
            content: AbsorbPointer(
              absorbing: saving,
              child: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SeraInput(label: '目标名称', controller: title),
                    SeraInput(
                      label: '完成标准',
                      controller: outcome,
                      minLines: 2,
                      maxLines: 4,
                    ),
                    TextButton.icon(
                      icon: const SeraIcon('calendar', size: 18),
                      label: Text(
                        '${formatDate(deadline)} ${formatTime(deadline)}',
                      ),
                      onPressed: () async {
                        if (saving || !ownsDialog()) return;
                        final date = await SeraMotion.pickDate(
                          context: ctx,
                          initialDate: deadline,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2040),
                        );
                        if (date == null || !ctx.mounted || !ownsDialog()) {
                          return;
                        }
                        final time = await SeraMotion.pickTime(
                          context: ctx,
                          initialTime: TimeOfDay.fromDateTime(deadline),
                        );
                        if (time != null && ctx.mounted && ownsDialog()) {
                          setDialog(
                            () => deadline = inTimeZone(
                              DateTime(
                                date.year,
                                date.month,
                                date.day,
                                time.hour,
                                time.minute,
                              ),
                              c.data.preferences.timeZone,
                              wallClock: true,
                            ),
                          );
                        }
                      },
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: status,
                      decoration: const InputDecoration(labelText: '目标状态'),
                      items: [
                        const DropdownMenuItem(
                          value: 'active',
                          child: Text('进行中'),
                        ),
                        const DropdownMenuItem(
                          value: 'paused',
                          child: Text('暂停'),
                        ),
                        const DropdownMenuItem(
                          value: 'archived',
                          child: Text('归档'),
                        ),
                        if (goal.status == 'completed')
                          const DropdownMenuItem(
                            value: 'completed',
                            child: Text('已完成'),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null && !saving && ownsDialog()) {
                          setDialog(() => status = value);
                        }
                      },
                    ),
                    if (saveError != null)
                      Text(
                        saveError!,
                        style: const TextStyle(color: SeraColors.red),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving
                    ? null
                    : () {
                        if (ownsDialog()) Navigator.pop(ctx);
                      },
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: saving
                    ? null
                    : () async {
                        if (saving || !ownsDialog()) return;
                        setDialog(() {
                          saving = true;
                          saveError = null;
                        });
                        try {
                          await c.saveGoal(
                            goal.copyWith(
                              title: title.text.trim(),
                              outcome: outcome.text.trim(),
                              deadline: deadline,
                              status: status,
                            ),
                          );
                          if (ctx.mounted && ownsDialog()) Navigator.pop(ctx);
                        } catch (error) {
                          if (ctx.mounted && ownsDialog()) {
                            setDialog(() => saveError = '$error');
                          }
                        } finally {
                          if (ctx.mounted && ownsDialog()) {
                            setDialog(() => saving = false);
                          }
                        }
                      },
                child: Text(saving ? '保存中…' : '保存'),
              ),
            ],
          ),
        ),
      ),
    );
    await Navigator.of(context, rootNavigator: true).push(dialogRoute);
    // Popping completes before the reverse transition removes the text fields.
    await dialogRoute.completed;
    title.dispose();
    outcome.dispose();
  }
}

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  Future<void> _syncDeviceRecords(
    BuildContext context,
    DeviceCloudSync sync,
  ) async {
    if (sync.busy) return;
    final auth = context.read<AuthRepository?>();
    final session = auth?.session;
    final controller = context.read<SeraController>();
    final route = ModalRoute.of(context);
    bool? preferDevice;
    if (sync.hasConflicts) {
      preferDevice = await showDialog<bool>(
        context: context,
        animationStyle: SeraMotion.dialogStyle(context),
        builder: (dialogContext) => AlertDialog(
          scrollable: true,
          title: const Text('此设备与账户中的记录不同'),
          content: Text('有 ${sync.conflictCount} 项记录不一致，请选择要保留的那一份。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('保留账户中的记录'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('保留此设备的记录'),
            ),
          ],
        ),
      );
      if (preferDevice == null) return;
    }
    if (!context.mounted ||
        !_sameMainOwner(context, controller, auth, session) ||
        !identical(context.read<DeviceCloudSync?>(), sync) ||
        !(route?.isCurrent ?? true)) {
      return;
    }
    try {
      await sync.synchronize(preferDevice: preferDevice);
    } catch (error) {
      if (context.mounted &&
          _sameMainOwner(context, controller, auth, session) &&
          (route?.isCurrent ?? true)) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthRepository?>();
    final deviceSync = context.watch<DeviceCloudSync?>();
    final signedIn = auth?.signedIn == true;
    final name = signedIn ? auth!.session!.user.username : '登录并同步';
    final controller = context.watch<SeraController>();
    return SeraScaffold(
      title: '账户与设置',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SeraCard(
            child: InkWell(
              key: const ValueKey('profile-account-entry'),
              borderRadius: BorderRadius.circular(12),
              onTap: () => context.push(signedIn ? '/account' : '/login'),
              child: Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: SeraColors.mint,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Center(
                      child: signedIn
                          ? Text(
                              name.isEmpty ? '序' : name.characters.first,
                              style: const TextStyle(
                                fontSize: 23,
                                color: SeraColors.brand,
                                fontWeight: FontWeight.w600,
                              ),
                            )
                          : const SeraIcon('user', size: 25),
                    ),
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          signedIn ? '账户与安全' : '记录已保存在此设备',
                          style: const TextStyle(
                            fontSize: 13,
                            color: SeraColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(child: SeraIcon('chevron', size: 18)),
                  ),
                ],
              ),
            ),
          ),
          if (!signedIn && auth?.logoutWarning != null) ...[
            const SizedBox(height: 12),
            SeraNote(
              '此设备已退出',
              body: auth!.logoutWarning,
              icon: 'shield',
              color: SeraColors.amber,
              background: SeraColors.amberBg,
            ),
          ],
          const SeraSection('规划设置'),
          SeraCard(
            child: Column(
              children: [
                SeraSettingRow(
                  'AI 与规划偏好',
                  icon: 'spark',
                  onTap: () => openScreen(context, '31'),
                ),
                const Divider(height: 1),
                SeraSettingRow(
                  '日历与同步',
                  icon: 'calendar',
                  onTap: () => openScreen(context, '32'),
                ),
                const Divider(height: 1),
                SeraSettingRow(
                  '提醒与免打扰',
                  icon: 'bell',
                  onTap: () => openScreen(context, '33'),
                ),
              ],
            ),
          ),
          const SeraSection('数据管理'),
          SeraCard(
            child: Column(
              children: [
                if (signedIn && deviceSync != null && deviceSync.hasPending)
                  SeraSettingRow(
                    '同步此设备的记录',
                    subtitle: deviceSync.busy ? '正在同步…' : deviceSync.message,
                    icon: 'refresh',
                    trailing: deviceSync.busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                    onTap: deviceSync.busy
                        ? null
                        : () => _syncDeviceRecords(context, deviceSync),
                  ),
                if (signedIn)
                  SeraSettingRow(
                    '保存与同步',
                    subtitle: controller.pendingSyncCount > 0
                        ? '${controller.pendingSyncCount} 项修改尚未同步'
                        : null,
                    icon: 'refresh',
                    onTap: () => openScreen(context, '40'),
                  ),
                SeraSettingRow(
                  '数据与隐私',
                  icon: 'shield',
                  onTap: () => openScreen(context, '36'),
                ),
              ],
            ),
          ),
          if (const bool.fromEnvironment(
            'ENABLE_REVIEW',
            defaultValue: false,
          )) ...[
            const SizedBox(height: 24),
            SeraSettingRow(
              '课程演示 · 55 个界面与状态',
              icon: 'list',
              onTap: () => context.push('/gallery'),
            ),
          ],
        ],
      ),
    );
  }
}

class PreferencesScreen extends StatefulWidget {
  const PreferencesScreen({super.key});
  @override
  State<PreferencesScreen> createState() => _PreferencesState();
}

class _PreferencesState extends State<PreferencesScreen> {
  SeraPreferences? _value;
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    final c = context.read<SeraController>();
    final auth = context.read<AuthRepository?>();
    final session = auth?.session;
    final route = ModalRoute.of(context);
    setState(() => _saving = true);
    try {
      await c.savePreferences(_value!);
      if (!mounted ||
          route?.isCurrent != true ||
          !_sameMainOwner(context, c, auth, session)) {
        return;
      }
      final messenger = ScaffoldMessenger.of(context);
      FocusManager.instance.primaryFocus?.unfocus();
      if (context.canPop()) {
        Router.neglect(context, () => context.pop());
      } else {
        finishSeraFlow(context, fallback: '/30');
      }
      messenger.showSnackBar(const SnackBar(content: Text('规划偏好已保存')));
    } catch (error) {
      if (mounted &&
          route?.isCurrent == true &&
          _sameMainOwner(context, c, auth, session)) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted && _sameMainOwner(context, c, auth, session)) {
        setState(() => _saving = false);
      }
    }
  }

  String _zoneName(String zone) => switch (zone) {
    'Asia/Hong_Kong' => '香港时间',
    'Asia/Shanghai' => '北京时间',
    'Asia/Tokyo' => '东京时间',
    'Europe/London' => '伦敦时间',
    'America/New_York' => '纽约时间',
    'UTC' => '协调世界时（UTC）',
    _ => zone,
  };
  Future<void> _rest(bool start) async {
    final route = ModalRoute.of(context);
    final controller = context.read<SeraController>();
    final auth = context.read<AuthRepository?>();
    final session = auth?.session;
    final value = _value!;
    final minute = start ? value.restStart : value.restEnd;
    final time = await SeraMotion.pickTime(
      context: context,
      initialTime: TimeOfDay(hour: minute ~/ 60, minute: minute % 60),
    );
    if (time != null &&
        mounted &&
        route?.isCurrent == true &&
        _sameMainOwner(context, controller, auth, session)) {
      setState(
        () => _value = start
            ? value.copyWith(restStart: time.hour * 60 + time.minute)
            : value.copyWith(restEnd: time.hour * 60 + time.minute),
      );
    }
  }

  Future<void> _time(bool start) async {
    final route = ModalRoute.of(context);
    final controller = context.read<SeraController>();
    final auth = context.read<AuthRepository?>();
    final session = auth?.session;
    final v = _value!;
    final m = start ? v.startMinute : v.endMinute;
    final time = await SeraMotion.pickTime(
      context: context,
      initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60),
      initialEntryMode: TimePickerEntryMode.input,
    );
    if (time != null &&
        mounted &&
        route?.isCurrent == true &&
        _sameMainOwner(context, controller, auth, session)) {
      setState(
        () => _value = v.copyWith(
          startMinute: start ? time.hour * 60 + time.minute : null,
          endMinute: start ? null : time.hour * 60 + time.minute,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SeraController>();
    _value ??= c.data.preferences;
    final v = _value!;
    final budgetOptions = <int>{
      30,
      60,
      90,
      120,
      180,
      c.data.preferences.dailyBudget,
      v.dailyBudget,
    }.toList()..sort();
    final bufferOptions = <int>{
      0,
      10,
      15,
      30,
      c.data.preferences.bufferMinutes,
      v.bufferMinutes,
    }.toList()..sort();
    String hm(int n) =>
        '${(n ~/ 60).toString().padLeft(2, '0')}:${(n % 60).toString().padLeft(2, '0')}';
    return SeraScaffold(
      title: 'AI 与规划偏好',
      footer: SeraButton(
        '保存偏好',
        busy: _saving,
        onPressed: _saving ? null : _save,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '哪些日子可以安排？',
            style: TextStyle(
              fontSize: 18,
              height: 26 / 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          SeraWeekdayPicker(
            selected: v.weekdays,
            onChanged: (days) =>
                setState(() => _value = v.copyWith(weekdays: days)),
          ),
          const SeraSection('一天里的专注时段'),
          SeraCard(
            child: Column(
              children: [
                InkWell(
                  onTap: () => _time(true),
                  child: SeraField(
                    '开始时间',
                    hm(v.startMinute),
                    valueAlign: TextAlign.right,
                    trailing: const SeraIcon('chevron', size: 16),
                  ),
                ),
                InkWell(
                  onTap: () => _time(false),
                  child: SeraField(
                    '结束时间',
                    hm(v.endMinute),
                    valueAlign: TextAlign.right,
                    trailing: const SeraIcon('chevron', size: 16),
                  ),
                ),
              ],
            ),
          ),
          const SeraSection('每天最多安排'),
          Wrap(
            key: const ValueKey('preferences-budget-options'),
            spacing: 8,
            runSpacing: 6,
            children: budgetOptions
                .map(
                  (n) => ChoiceChip(
                    label: Text('$n 分钟'),
                    selected: v.dailyBudget == n,
                    onSelected: (_) =>
                        setState(() => _value = v.copyWith(dailyBudget: n)),
                  ),
                )
                .toList(),
          ),
          const SeraSection('事项之间的缓冲'),
          Wrap(
            key: const ValueKey('preferences-buffer-options'),
            spacing: 8,
            runSpacing: 6,
            children: bufferOptions
                .map(
                  (n) => ChoiceChip(
                    label: Text('$n 分钟'),
                    selected: v.bufferMinutes == n,
                    onSelected: (_) =>
                        setState(() => _value = v.copyWith(bufferMinutes: n)),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 20),
          SeraDisclosure(
            title: '休息与时区',
            summary:
                '${hm(v.restStart)}–${hm(v.restEnd)} · ${_zoneName(v.timeZone)}',
            children: [
              InkWell(
                onTap: () => _rest(true),
                child: SeraField(
                  '休息开始',
                  hm(v.restStart),
                  valueAlign: TextAlign.right,
                  trailing: const SeraIcon(
                    'chevron',
                    size: 16,
                    color: SeraColors.muted,
                  ),
                ),
              ),
              InkWell(
                onTap: () => _rest(false),
                child: SeraField(
                  '休息结束',
                  hm(v.restEnd),
                  valueAlign: TextAlign.right,
                  trailing: const SeraIcon(
                    'chevron',
                    size: 16,
                    color: SeraColors.muted,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue:
                    {
                      v.timeZone,
                      'Asia/Hong_Kong',
                      'Asia/Shanghai',
                      'Asia/Tokyo',
                      'Europe/London',
                      'America/New_York',
                      'UTC',
                    }.contains(v.timeZone)
                    ? v.timeZone
                    : 'Asia/Hong_Kong',
                decoration: const InputDecoration(labelText: '日程时区'),
                items: [
                  for (final zone in {
                    v.timeZone,
                    'Asia/Hong_Kong',
                    'Asia/Shanghai',
                    'Asia/Tokyo',
                    'Europe/London',
                    'America/New_York',
                    'UTC',
                  })
                    DropdownMenuItem(
                      value: zone,
                      child: Text(
                        _zoneName(zone),
                        style: const TextStyle(fontSize: 15),
                      ),
                    ),
                ],
                onChanged: (zone) {
                  if (zone != null) {
                    setState(() => _value = v.copyWith(timeZone: zone));
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('使用相关上下文帮助规划', style: TextStyle(fontSize: 15)),
            subtitle: const Text(
              '允许规划时参考相关任务和目标信息。关闭后仅使用本次输入与必要的忙闲时间。',
              style: TextStyle(fontSize: 13, height: 1.7),
            ),
            value: v.useAiContext,
            onChanged: (value) =>
                setState(() => _value = v.copyWith(useAiContext: value)),
          ),
        ],
      ),
    );
  }
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  @override
  State<SearchScreen> createState() => _SearchState();
}

class _SearchState extends State<SearchScreen> {
  final _q = TextEditingController();
  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SeraController>();
    final q = _q.text.trim().toLowerCase();
    final tasks = c.data.tasks
        .where(
          (t) =>
              q.isNotEmpty && '${t.title} ${t.notes}'.toLowerCase().contains(q),
        )
        .toList();
    final goals = c.data.goals
        .where(
          (g) =>
              q.isNotEmpty &&
              '${g.title} ${g.outcome}'.toLowerCase().contains(q),
        )
        .toList();
    final entries = c.data.entries
        .where(
          (e) =>
              !e.isTask &&
              q.isNotEmpty &&
              '${e.title} ${e.place} ${e.notes}'.toLowerCase().contains(q),
        )
        .toList();
    final drafts = c.data.drafts
        .where(
          (d) =>
              q.isNotEmpty &&
              '${d.goal.title} ${d.prompt}'.toLowerCase().contains(q),
        )
        .toList();
    final sessions = c.data.planningSessions
        .where(
          (s) =>
              q.isNotEmpty &&
              '${s.title} ${s.prompt} ${s.notes}'.toLowerCase().contains(q),
        )
        .toList();
    return SeraScaffold(
      title: '搜索',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _q,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: '搜索任务、目标和日程',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          const SizedBox(height: 20),
          if (q.isEmpty)
            const SeraEmpty('想找什么？', '输入关键词，找回任务、目标与安排。', icon: 'search')
          else if (tasks.isEmpty &&
              goals.isEmpty &&
              entries.isEmpty &&
              drafts.isEmpty &&
              sessions.isEmpty)
            const SeraEmpty('没有找到相关内容', '换一个关键词，再试一次。', icon: 'search'),
          if (tasks.isNotEmpty) ...[
            SeraSection('任务 · ${tasks.length}'),
            ...tasks.map(
              (t) => SeraTaskRow(
                t,
                entry: c.entryForTask(t.id),
                showDate: true,
                onTap: () => openScreen(context, '18', taskId: t.id),
              ),
            ),
          ],
          if (goals.isNotEmpty) ...[
            SeraSection('目标 · ${goals.length}'),
            ...goals.map(
              (g) => SeraSettingRow(
                g.title,
                icon: 'target',
                subtitle: formatDate(g.deadline),
                onTap: () =>
                    context.push('/21?goalId=${Uri.encodeComponent(g.id)}'),
              ),
            ),
          ],
          if (entries.isNotEmpty) ...[
            SeraSection('日程 · ${entries.length}'),
            ...entries.map(
              (e) => SeraAgendaRow(
                e,
                showDate: true,
                onTap: () => openScreen(context, '15', eventId: e.id),
              ),
            ),
          ],
          if (drafts.isNotEmpty) ...[
            SeraSection('计划草案 · ${drafts.length}'),
            for (final draft in drafts)
              SeraSettingRow(
                draft.goal.title,
                subtitle: draft.status == 'committed' ? '已确认计划' : '待确认草案',
                icon: 'book',
                onTap: () => context.push(
                  Uri(
                    path: '/08',
                    queryParameters: {'draftId': draft.id, 'from': 'search'},
                  ).toString(),
                ),
              ),
          ],
          if (sessions.isNotEmpty) ...[
            SeraSection('对话记录 · ${sessions.length}'),
            for (final session in sessions)
              SeraSettingRow(
                session.title.isEmpty ? session.prompt : session.title,
                subtitle: session.notes.isEmpty
                    ? session.prompt
                    : session.notes,
                icon: 'mail',
                onTap: () => context.push(
                  Uri(
                    path: '/05',
                    queryParameters: {
                      'sessionId': session.id,
                      'from': 'search',
                    },
                  ).toString(),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});
  Future<void> _confirm(
    BuildContext context,
    SeraController c, {
    required bool reset,
  }) async {
    final route = ModalRoute.of(context);
    final auth = context.read<AuthRepository?>();
    final session = auth?.session;
    final yes = await showDialog<bool>(
      context: context,
      animationStyle: SeraMotion.dialogStyle(context),
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(reset ? '重置演示数据？' : '清空安排与记录？'),
        content: Text(
          reset
              ? '现有任务、日程、草案和专注记录将被替换为演示数据。'
              : '任务、目标、日程、草案和专注记录将全部清空，无法恢复。账户会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              reset ? '重置' : '清空',
              style: const TextStyle(color: SeraColors.red),
            ),
          ),
        ],
      ),
    );
    if (yes == true &&
        context.mounted &&
        route?.isCurrent == true &&
        _sameMainOwner(context, c, auth, session)) {
      await runAction(
        context,
        reset ? c.resetDemo : c.clearWorkspace,
        success: reset ? '已恢复演示数据' : '安排与记录已清空',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SeraController>();
    return SeraScaffold(
      title: '数据与隐私',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SeraCard(
            child: Column(
              children: [
                SeraField(
                  '保存位置',
                  context.watch<AuthRepository?>()?.signedIn == true
                      ? '当前个人账户'
                      : '当前设备',
                ),
              ],
            ),
          ),
          const SeraSection('你的数据'),
          SeraSettingRow(
            '账户安全与备份',
            icon: 'user',
            onTap: () => context.push('/account'),
          ),
          const Divider(height: 1),
          SeraSettingRow(
            '查看与复制数据',
            icon: 'download',
            onTap: () {
              final json = const JsonEncoder.withIndent('  ')
                  .convert(c.data.toJson());
              showDialog<void>(
                context: context,
                animationStyle: SeraMotion.dialogStyle(context),
                builder: (ctx) => AlertDialog(
                  title: const Text('数据内容（JSON）'),
                  content: SizedBox(
                    width: 500,
                    child: SingleChildScrollView(
                      child: SelectableText(
                        json,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('关闭'),
                    ),
                    TextButton(
                      onPressed: () => runAction(
                        ctx,
                        () => Clipboard.setData(ClipboardData(text: json)),
                        success: '数据已复制到剪贴板',
                      ),
                      child: const Text('复制内容'),
                    ),
                  ],
                ),
              );
            },
          ),
          const Divider(height: 1),
          if (const bool.fromEnvironment('ENABLE_REVIEW', defaultValue: false))
            SeraSettingRow(
              '重置演示数据',
              icon: 'refresh',
              onTap: () => _confirm(context, c, reset: true),
            ),
          const SizedBox(height: 24),
          SeraSettingRow(
            '清空安排与记录',
            color: SeraColors.red,
            icon: 'trash',
            onTap: () => _confirm(context, c, reset: false),
          ),
        ],
      ),
    );
  }
}
