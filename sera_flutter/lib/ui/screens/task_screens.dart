import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';

import '../../application/sera_controller.dart';
import '../../data/planning_ai_provider.dart';
import '../../data/workspace_repository.dart';
import '../../domain/models.dart';
import '../../domain/todo_queries.dart';
import '../../platform/reminder_requests.dart';
import '../core/sera_plan_switcher.dart';
import '../core/sera_widgets.dart';
import '../core/sera_flow_return.dart';
import '../core/sera_motion.dart';
import '../core/sera_scroll_reveal.dart';
import '../core/sera_todo_row.dart';

/// Native Flutter task, execution and review pages from the approved prototype.
Widget buildTaskScreen(
  String id, {
  String? taskId,
  String? eventId,
  String? draftId,
}) {
  if (id.startsWith('09') || id.startsWith('19')) {
    return _TaskEditor(id: id, taskId: taskId, draftId: draftId);
  }
  if (id.startsWith('16')) return _EventEditor(eventId: eventId);
  if (id.startsWith('25')) return _FocusScreen(taskId: taskId);
  return _TaskSurface(
    id: id,
    taskId: taskId,
    eventId: eventId,
    draftId: draftId,
  );
}

const _gap = SizedBox(height: 24);
const _smallGap = SizedBox(height: 12);
const _body = TextStyle(fontSize: 15, height: 22 / 15, color: SeraColors.muted);
const _strong = TextStyle(
  fontSize: 16,
  fontWeight: FontWeight.w500,
  height: 1.5,
);
const _caption = TextStyle(
  fontSize: 13,
  height: 20 / 13,
  color: SeraColors.muted,
);

// Controller identity changes with the authenticated session in SeraRoot. A
// mounted exiting page alone is not permission to navigate for its successor.
bool _sameOwner(
  BuildContext context,
  SeraController controller,
  String account,
) =>
    context.mounted &&
    identical(context.read<SeraController>(), controller) &&
    controller.accountId == account;

bool _currentOwner(
  BuildContext context,
  ModalRoute<dynamic>? route,
  SeraController controller,
  String account,
) => _sameOwner(context, controller, account) && route?.isCurrent == true;

String? _suggestedText(String? value, int limit) {
  if (value == null) {
    return null;
  }
  final text = value.trim();
  if (text.length > limit ||
      RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]').hasMatch(text)) {
    return null;
  }
  // Text controllers render this as literal text; never interpret markup or
  // execute any instruction arriving through a route.
  return text;
}

DateTime? _suggestedDate(String? value, String zone, {bool dateOnly = false}) {
  if (value == null || value.length > 40) {
    return null;
  }
  final pattern = dateOnly
      ? RegExp(r'^\d{4}-\d{2}-\d{2}$')
      : RegExp(
          r'^\d{4}-\d{2}-\d{2}T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d{1,6})?)?(?:Z|[+-]\d{2}:\d{2})?$',
        );
  final match = pattern.firstMatch(value);
  if (match == null) {
    return null;
  }
  final day = DateTime.tryParse(value.substring(0, 10));
  if (day == null ||
      day.year < 2020 ||
      day.year > 2040 ||
      calendarDateString(day) != value.substring(0, 10)) {
    return null;
  }
  if (!dateOnly &&
      (int.parse(match.group(1)!) > 23 ||
          int.parse(match.group(2)!) > 59 ||
          int.parse(match.group(3) ?? '0') > 59)) {
    return null;
  }
  final parsed = DateTime.tryParse(value);
  return parsed == null
      ? null
      : inTimeZone(parsed, zone, wallClock: !parsed.isUtc);
}

SeraTask? _resolveTask(SeraController c, String? id) {
  if (id != null) return c.task(id);
  final pending = c.data.tasks.where((t) => !t.done);
  return pending.isNotEmpty ? pending.first : c.data.tasks.firstOrNull;
}

CalendarEntry? _resolveEntry(SeraController c, String? id) {
  if (id != null) return c.entry(id);
  return c.data.entries.where((e) => !e.isTask).firstOrNull;
}

Map<String, String> _sessionPrefill(
  PlanningSession session,
  String kind,
  String zone, {
  bool manual = false,
}) {
  final result = manual || session.understanding == null
      ? null
      : AiUnderstanding.fromJson(session.understanding!);
  if (result != null && result.intent != kind) {
    throw const RepositoryException('这条输入的类型已改变，请返回输入页核对。');
  }
  final notes = <String>{
    if (result != null && result.summary.isNotEmpty) result.summary,
    if (result != null && result.outcome.isNotEmpty) result.outcome,
    if (session.notes.trim().isNotEmpty) session.notes.trim(),
    ...session.clarificationAnswers.entries
        .where((entry) => entry.value.trim().isNotEmpty)
        .map((entry) => '${entry.key}：${entry.value.trim()}'),
    if (session.prompt.trim().isNotEmpty) '原始输入：${session.prompt.trim()}',
  };
  return {
    'title':
        result?.title ??
        (session.title.trim().isEmpty
            ? null
            : _suggestedText(session.title, 200)) ??
        _suggestedText(session.prompt.split('\n').first, 200) ??
        '',
    'notes': notes.join('\n\n'),
    if (result != null) 'fromAi': '1',
    if (result != null && result.estimatedMinutes != null)
      'estimatedMinutes': '${result.estimatedMinutes}',
    if (result != null && result.deadline != null)
      (result.deadlineIsDateOnly
          ? 'dueDate'
          : 'dueAt'): result.deadlineIsDateOnly
          ? calendarDateString(inTimeZone(result.deadline!, zone))
          : result.deadline!.toUtc().toIso8601String(),
    if (result != null && result.start != null)
      'start': result.start!.toUtc().toIso8601String(),
    if (result != null && result.end != null)
      'end': result.end!.toUtc().toIso8601String(),
    if (kind == 'event' &&
        result != null &&
        (result.start == null || result.end == null))
      'requiresTimeConfirmation': '1',
  };
}

Widget _sessionError(BuildContext context, String message) => SeraScaffold(
  title: '输入记录',
  body: SeraEmpty(
    '暂时无法打开这条输入',
    message,
    action: '返回任务列表',
    onAction: () => context.go('/17'),
  ),
);

Widget? _sessionState(BuildContext context, String? id) {
  if (id == null) return null;
  final c = context.read<SeraController>();
  final session = c.planningSession(id);
  if (session == null) return _sessionError(context, '这条输入已不存在。');
  if (session.stage != 'confirmed') return null;
  final ref = session.resultEntity;
  if (ref == null) return _sessionError(context, '这条输入已经处理，请从列表查看保存结果。');
  final exists = ref.kind == 'task'
      ? c.task(ref.id) != null
      : c.entry(ref.id) != null;
  if (!exists) {
    return _sessionError(
      context,
      '已保存的${ref.kind == 'task' ? '任务' : '日程'}已删除，请开始新的输入。',
    );
  }
  final route = ModalRoute.of(context);
  final account = c.accountId;
  void open() {
    if (_currentOwner(context, route, c, account)) {
      Router.neglect(context, () {
        context.replace(
          Uri(
            path: ref.kind == 'task' ? '/18' : '/15',
            queryParameters: {
              (ref.kind == 'task' ? 'taskId' : 'eventId'): ref.id,
            },
          ).toString(),
        );
      });
    }
  }

  WidgetsBinding.instance.addPostFrameCallback((_) => open());
  return SeraScaffold(
    title: '已保存',
    body: SeraButton('查看保存结果', onPressed: open),
  );
}

bool _within(BuildContext child, GlobalKey ancestor) {
  var found = false;
  child.visitAncestorElements((element) {
    if (element.widget.key == ancestor) found = true;
    return !found;
  });
  return found;
}

void _revealInvalid(
  BuildContext context,
  Set<FormFieldState<Object?>> invalid, {
  bool expanding = false,
}) {
  final c = context.read<SeraController>();
  final account = c.accountId;
  final ownerRoute = ModalRoute.of(context);
  final reduced = SeraMotion.reduced(context);
  final scrollDuration = SeraMotion.scrollDuration(context);
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    if (expanding && !reduced) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      // The expansion ticker can finish in the same frame as this delay. Read
      // geometry only after layout updates the outer scroll extent.
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!context.mounted || !_currentOwner(context, ownerRoute, c, account)) {
      return;
    }
    final fields = invalid
        .where((field) => field.mounted && field.hasError)
        .toList();
    double top(FormFieldState<Object?> field) {
      final box = field.context.findRenderObject();
      return box is RenderBox && box.attached && box.hasSize
          ? box.localToGlobal(Offset.zero).dy
          : double.infinity;
    }

    fields.sort((a, b) => top(a).compareTo(top(b)));
    final field = fields.firstOrNull;
    if (field != null && field.mounted) {
      await Scrollable.ensureVisible(
        field.context,
        alignment: .1,
        // Reveal an expanded error immediately once its final layout exists;
        // animating from the collapsed extent can leave it below the viewport.
        duration: expanding ? Duration.zero : scrollDuration,
      );
    }
  });
}

String _eventDateRange(CalendarEntry entry) {
  final last = entry.allDay ? calendarDay(entry.end, -1) : entry.end;
  final crossesYear = entry.start.year != last.year;
  String day(DateTime value) =>
      '${crossesYear ? '${value.year}年' : ''}${formatDate(value)}';
  final sameDay = calendarDateString(entry.start) == calendarDateString(last);
  if (entry.allDay) {
    return '${day(entry.start)}${sameDay ? '' : ' – ${day(last)}'} · 全天';
  }
  if (sameDay) {
    return '${day(entry.start)} · ${formatRange(entry.start, entry.end)}';
  }
  return '${day(entry.start)} ${formatTime(entry.start)} – '
      '${day(entry.end)} ${formatTime(entry.end)}';
}

String _eventDuration(CalendarEntry entry) {
  if (!entry.allDay) return formatMinutes(entry.minutes);
  final start = entry.start;
  final end = entry.end;
  final days = DateTime.utc(
    end.year,
    end.month,
    end.day,
  ).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
  return '${math.max(1, days)} 天';
}

Widget _stack(List<Widget> children) =>
    Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);

Widget _missing(BuildContext context, {bool event = false}) => SeraScaffold(
  title: event ? '日程详情' : '任务详情',
  body: _stack([
    SeraEmpty(
      event ? '这项日程暂时不在这里' : '这里还没有任务',
      '可以返回列表，或记下接下来想做的事。',
      icon: event ? 'calendar' : 'inbox',
      action: '添加一项任务',
      onAction: () => openScreen(context, '19-new-task'),
    ),
    SeraButton(
      '查看任务列表',
      variant: 'ghost',
      onPressed: () => openScreen(context, '17-tasks'),
    ),
  ]),
);

Widget _symbol(
  String icon, {
  Color color = SeraColors.brand,
  Color background = SeraColors.mint,
}) => Padding(
  padding: const EdgeInsets.only(top: 16, bottom: 16),
  child: Center(
    child: Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Center(child: SeraIcon(icon, size: 24, color: color)),
    ),
  ),
);

Widget _centerIntro(String title, String subtitle) => Column(
  children: [
    Text(
      title,
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        height: 32 / 24,
      ),
    ),
    const SizedBox(height: 12),
    Text(subtitle, textAlign: TextAlign.center, style: _body),
  ],
);

Widget _stats(List<(String, String)> values) => Container(
  margin: const EdgeInsets.only(bottom: 24),
  padding: const EdgeInsets.symmetric(vertical: 16),
  decoration: const BoxDecoration(
    border: Border(
      top: BorderSide(color: SeraColors.line),
      bottom: BorderSide(color: SeraColors.line),
    ),
  ),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < values.length; i++) ...[
        if (i > 0) Container(height: 45, width: 1, color: SeraColors.line),
        Expanded(
          child: Column(
            children: [
              Text(
                values[i].$1,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 5),
              Text(values[i].$2, textAlign: TextAlign.center, style: _caption),
            ],
          ),
        ),
      ],
    ],
  ),
);

String _reminderLabel(int minutes) => minutes < 0
    ? '不提醒'
    : minutes == 0
    ? '开始时提醒'
    : '开始前 $minutes 分钟';

Map<String, String> _planningRouteContext(BuildContext context) {
  final query = GoRouterState.of(context).uri.queryParameters;
  return {
    'sessionId': ?query['sessionId'],
    if (const {
      'tasks',
      'today',
      'goals',
      'history',
      'search',
    }.contains(query['from']))
      'from': query['from']!,
  };
}

bool _canResumeTaskFlow(
  SeraController controller,
  Uri uri, {
  String? deletedTaskId,
  String? deletedEntryId,
}) {
  if (!isSeraFlowReturnPage(uri)) return false;
  final screen = seraScreenId(uri);
  if (screen == '18') {
    final id = uri.queryParameters['taskId'];
    if (deletedTaskId != null && id == null) return false;
    if (id != null && (id == deletedTaskId || controller.task(id) == null)) {
      return false;
    }
  } else if (screen == '15') {
    final id = uri.queryParameters['eventId'];
    if ((deletedEntryId != null || deletedTaskId != null) && id == null) {
      return false;
    }
    if (id != null && (id == deletedEntryId || controller.entry(id) == null)) {
      return false;
    }
  } else if (screen == '21') {
    final id = uri.queryParameters['goalId'];
    if (id != null && controller.goal(id) == null) return false;
  }
  return true;
}

void _showTaskCompletionUndo(
  ScaffoldMessengerState messenger,
  SeraTaskCompletion completion,
) {
  bool stillOwned() =>
      messenger.mounted &&
      identical(messenger.context.read<SeraController?>(), completion.owner) &&
      completion.canUndoWith(completion.owner);

  if (!stillOwned()) return;
  messenger.removeCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: const Text('任务已完成'),
      duration: const Duration(seconds: 3),
      action: SnackBarAction(
        label: '撤销',
        onPressed: () async {
          if (!stillOwned()) return;
          try {
            await completion.owner.undoTaskCompletion(completion.recordId);
          } catch (error) {
            if (messenger.mounted &&
                identical(
                  messenger.context.read<SeraController?>(),
                  completion.owner,
                ) &&
                completion.owner.accountId == completion.accountId) {
              messenger.showSnackBar(SnackBar(content: Text('$error')));
            }
          }
        },
      ),
    ),
  );
}

Future<void> _deleteTask(
  BuildContext context,
  SeraTask task, {
  String? draftId,
  bool alreadyConfirmed = false,
}) async {
  final c = context.read<SeraController>();
  final account = c.accountId;
  final ownerRoute = ModalRoute.of(context);
  if (!_currentOwner(context, ownerRoute, c, account)) {
    return;
  }
  final confirmed = alreadyConfirmed
      ? true
      : await showDialog<bool>(
          context: context,
          animationStyle: SeraMotion.dialogStyle(context),
          builder: (ctx) => AlertDialog(
            scrollable: true,
            icon: const SeraIcon('trash', size: 28, color: SeraColors.red),
            title: const Text('删除任务？'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(task.title, style: _strong),
                const SizedBox(height: 12),
                Text(
                  draftId == null
                      ? '这项任务及 ${task.checklist.length} 个检查项将被移除，关联的专注安排与提醒也会取消。可在操作记录中撤销。'
                      : '这项任务将从草案中移除。其他草案任务会继续保留。',
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('保留任务'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text(
                  '确认删除',
                  style: TextStyle(color: SeraColors.red),
                ),
              ),
            ],
          ),
        );
  if (confirmed != true ||
      !context.mounted ||
      !_currentOwner(context, ownerRoute, c, account)) {
    return;
  }
  await runAction(context, () async {
    if (draftId != null) {
      await c.deleteDraftItem(draftId, task.id);
    } else {
      await c.deleteTask(task.id);
    }
    if (context.mounted && _currentOwner(context, ownerRoute, c, account)) {
      finishSeraFlow(
        context,
        fallback: Uri(
          path: draftId == null ? '/17' : '/08',
          queryParameters: draftId == null
              ? {'filter': 'todo'}
              : {'draftId': draftId, ..._planningRouteContext(context)},
        ).toString(),
        accepts: (uri) => draftId == null
            ? _canResumeTaskFlow(c, uri, deletedTaskId: task.id)
            : seraScreenId(uri) == '08' &&
                  uri.queryParameters['draftId'] == draftId &&
                  c.draft(draftId)?.status == 'draft',
      );
    }
  }, success: '已删除任务');
}

Future<void> _showReminder(BuildContext context, SeraTask task) async {
  final c = context.read<SeraController>();
  final account = c.accountId;
  if (!_currentOwner(context, ModalRoute.of(context), c, account)) {
    return;
  }
  var selected = task.reminderMinutes;
  var saving = false;
  await showModalBottomSheet<void>(
    context: context,
    sheetAnimationStyle: SeraMotion.sheetStyle(context),
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    backgroundColor: SeraColors.surface,
    builder: (sheetContext) => LayoutBuilder(
      builder: (_, constraints) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: constraints.maxHeight),
        child: SafeArea(
          top: false,
          child: StatefulBuilder(
            builder: (ctx, setSheetState) {
              final sheetRoute = ModalRoute.of(ctx);
              bool ownsSheet() =>
                  _sameOwner(context, c, account) &&
                  _currentOwner(ctx, sheetRoute, c, account);
              return SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  24,
                  0,
                  24,
                  24 + MediaQuery.viewInsetsOf(ctx).bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '什么时候提醒你？',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭提醒设置',
                          onPressed: () {
                            if (ownsSheet()) Navigator.pop(ctx);
                          },
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    Text(task.title, style: _body),
                    _gap,
                    for (final value in [-1, 0, 10, 30])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _ChoiceTile(
                          label: _reminderLabel(value),
                          selected: value == selected,
                          onTap: saving
                              ? null
                              : () => setSheetState(() => selected = value),
                        ),
                      ),
                    const Text(
                      '开始时间变化后，提醒将跟随更新。提醒中心会展示当前任务提醒。',
                      style: _caption,
                    ),
                    _gap,
                    SeraButton(
                      '保存提醒',
                      busy: saving,
                      onPressed: saving
                          ? null
                          : () async {
                              if (saving || !ownsSheet()) {
                                return;
                              }
                              setSheetState(() => saving = true);
                              try {
                                await c.setReminder(task.id, selected);
                                if (context.mounted &&
                                    ctx.mounted &&
                                    ownsSheet()) {
                                  Navigator.pop(ctx);
                                }
                              } catch (error) {
                                if (context.mounted &&
                                    ctx.mounted &&
                                    ownsSheet()) {
                                  setSheetState(() => saving = false);
                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                    SnackBar(content: Text('$error')),
                                  );
                                }
                              }
                            },
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({required this.label, required this.selected, this.onTap});
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: selected ? SeraColors.mint : SeraColors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(color: selected ? SeraColors.brand : SeraColors.line),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: selected ? SeraColors.brand : SeraColors.ink,
                ),
              ),
            ),
            if (selected)
              const SeraIcon('check', size: 18, color: SeraColors.brand),
          ],
        ),
      ),
    ),
  );
}

class _AddTaskChecksDialog extends StatefulWidget {
  const _AddTaskChecksDialog({required this.onSave});
  final Future<void> Function(List<String>) onSave;
  @override
  State<_AddTaskChecksDialog> createState() => _AddTaskChecksDialogState();
}

class _AddTaskChecksDialogState extends State<_AddTaskChecksDialog> {
  final _text = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('添加子项'),
    scrollable: true,
    content: Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            key: const ValueKey('add-task-checks-input'),
            controller: _text,
            autofocus: true,
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(labelText: '子项（每行一项）'),
            validator: (value) {
              final items = (value ?? '')
                  .split('\n')
                  .map((e) => e.trim())
                  .where((e) => e.isNotEmpty)
                  .toSet();
              if (items.isEmpty) return '请写下一个子项';
              if (items.length > 100) return '最多添加 100 个子项。';
              if (items.any((e) => e.length > 500)) return '每个子项最多 500 字。';
              return null;
            },
          ),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: SeraColors.red)),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _saving
            ? null
            : () async {
                if (!_form.currentState!.validate()) return;
                setState(() {
                  _saving = true;
                  _error = null;
                });
                try {
                  await widget.onSave(
                    _text.text
                        .split('\n')
                        .map((e) => e.trim())
                        .where((e) => e.isNotEmpty)
                        .toSet()
                        .toList(),
                  );
                  if (context.mounted &&
                      ModalRoute.of(context)?.isCurrent == true) {
                    Navigator.pop(context);
                  }
                } catch (error) {
                  if (mounted) setState(() => _error = '$error');
                } finally {
                  if (mounted) setState(() => _saving = false);
                }
              },
        child: Text(_saving ? '正在保存…' : '保存子项'),
      ),
    ],
  );
}

class _TaskSurface extends StatefulWidget {
  const _TaskSurface({
    required this.id,
    this.taskId,
    this.eventId,
    this.draftId,
  });
  final String id;
  final String? taskId, eventId, draftId;
  @override
  State<_TaskSurface> createState() => _TaskSurfaceState();
}

class _TaskSurfaceState extends State<_TaskSurface> {
  String _filter = 'todo';
  String _feedback = 'right';
  int? _remainingOverride;
  final _reviewNote = TextEditingController();
  String? _reviewAccount;
  bool _reviewLoaded = false;
  String? _filterQuery;
  String? _focusTaskId;
  SeraRevealRequest _focusTaskRequest = SeraRevealRequest();
  final _taskScroll = ScrollController();
  final _taskRowKeys = <String, GlobalKey>{};
  bool _listRevealPending = false, _listRevealRunning = false;
  SeraController? _listOwner;
  final _detailDisclosure = ExpansibleController();
  String? _detailError;
  bool _completingDetail = false;
  SeraTaskCompletion? _lastCompletion;

  Future<void> _addChecks(SeraTask task) async {
    final c = context.read<SeraController>();
    final account = c.accountId;
    final route = ModalRoute.of(context);
    await showDialog<void>(
      context: context,
      animationStyle: SeraMotion.dialogStyle(context),
      builder: (_) => _AddTaskChecksDialog(
        onSave: (checks) async {
          if (!mounted ||
              !_sameOwner(context, c, account) ||
              route?.isActive != true) {
            throw const RepositoryException('账户或页面已改变，请重新打开。');
          }
          final current = c.task(task.id);
          if (current == null || !current.active) {
            throw const RepositoryException('任务状态已改变，请重新打开。');
          }
          final merged = {...current.checklist, ...checks}.toList();
          if (merged.length > 100) {
            throw const RepositoryException('最多添加 100 个子项。');
          }
          await c.saveTask(current.copyWith(checklist: merged));
        },
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = context.read<SeraController>();
    if ((widget.id.startsWith('28') || widget.id.startsWith('29')) &&
        (!_reviewLoaded || _reviewAccount != c.accountId)) {
      _reviewLoaded = true;
      _reviewAccount = c.accountId;
      _loadReview();
    }
    if (widget.id.startsWith('17')) {
      final parameters = GoRouterState.of(context).uri.queryParameters;
      final focusTaskId = parameters['focusTaskId'];
      if (focusTaskId != _focusTaskId) {
        _focusTaskId = focusTaskId;
        _focusTaskRequest = SeraRevealRequest();
        _listRevealPending = focusTaskId != null;
      }
      final query = parameters['filter'] ?? 'todo';
      if (query != _filterQuery) {
        _filterQuery = query;
        _filter =
            const [
              'today',
              'todo',
              'inbox',
              'scheduled',
              'all',
              'done',
            ].contains(query)
            ? query
            : 'todo';
      }
    }
  }

  String _reviewKey(DateTime date) {
    final weekly = widget.id.startsWith('29');
    final day = weekly ? date.subtract(Duration(days: date.weekday - 1)) : date;
    return '${weekly ? 'weekly' : 'daily'}-${day.toIso8601String().substring(0, 10)}';
  }

  void _loadReview() {
    final c = context.read<SeraController>();
    final value = c.data.reviews
        .where((r) => r.id == _reviewKey(c.today))
        .firstOrNull;
    _feedback = 'right';
    _reviewNote.clear();
    if (value != null) {
      try {
        final decoded = jsonDecode(value.feedback) as Map<String, dynamic>;
        _feedback = decoded['rating'] as String? ?? 'right';
        _reviewNote.text = decoded['note'] as String? ?? '';
      } catch (_) {
        _reviewNote.text = value.feedback;
      }
    }
  }

  @override
  void dispose() {
    _taskScroll.dispose();
    _detailDisclosure.dispose();
    _reviewNote.dispose();
    super.dispose();
  }

  Future<void> _complete(SeraTask task) async {
    final c = context.read<SeraController>();
    final account = c.accountId;
    final ownerRoute = ModalRoute.of(context);
    if (_completingDetail ||
        !mounted ||
        !_currentOwner(context, ownerRoute, c, account)) {
      return;
    }
    setState(() => _completingDetail = true);
    try {
      await runAction(context, () async {
        final before = c.task(task.id);
        if (before == null) throw const RepositoryException('任务已不存在。');
        final recordId = await c.completeTaskWithUndo(task.id);
        if (mounted && _currentOwner(context, ownerRoute, c, account)) {
          final after = c.task(task.id)!;
          final messenger = ScaffoldMessenger.of(context);
          finishSeraFlow(
            context,
            fallback: Uri(
              path: '/17',
              queryParameters: {'filter': 'done', 'focusTaskId': task.id},
            ).toString(),
            accepts: (uri) => _canResumeTaskFlow(c, uri),
          );
          _showTaskCompletionUndo(
            messenger,
            SeraTaskCompletion(before, after.revision, c, account, recordId),
          );
        }
      });
    } finally {
      if (mounted && _sameOwner(context, c, account)) {
        setState(() => _completingDetail = false);
      }
    }
  }

  Future<void> _reportBlock(SeraController c, SeraTask task) async {
    final account = c.accountId;
    final ownerRoute = ModalRoute.of(context);
    if (!mounted || !_currentOwner(context, ownerRoute, c, account)) {
      return;
    }
    final value = await showDialog<String>(
      context: context,
      animationStyle: SeraMotion.dialogStyle(context),
      builder: (_) => _TaskBlockDialog(initialReason: task.blockedReason),
    );
    if (value != null &&
        mounted &&
        _currentOwner(context, ownerRoute, c, account)) {
      await runAction(context, () async {
        await c.setTaskStatus(task.id, 'blocked', reason: value);
        if (!mounted || !_currentOwner(context, ownerRoute, c, account)) {
          return;
        }
        final session = c.createTaskRefinementSession(task.id, reason: value);
        await c.savePlanningSession(session);
        if (!mounted || !_currentOwner(context, ownerRoute, c, account)) {
          return;
        }
        unawaited(
          context.push(
            Uri(
              path: '/07',
              queryParameters: {'sessionId': session.id, 'start': '1'},
            ).toString(),
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.id.split('-').first == '17') {
      return Selector<
        SeraController,
        (SeraController, List<SeraTask>, List<CalendarEntry>, DateTime, bool)
      >(
        selector: (_, c) => (c, c.data.tasks, c.data.entries, c.today, c.busy),
        builder: (_, value, _) => _taskList(value.$1),
      );
    }
    final c = context.watch<SeraController>();
    final task = _resolveTask(c, widget.taskId);
    switch (widget.id.split('-').first) {
      case '15':
        return _eventDetail(c);
      case '18':
        return task == null ? _missing(context) : _taskDetail(c, task);
      case '24':
        return task == null ? _missing(context) : _checkIn(c, task);
      case '26':
        return task == null ? _missing(context) : _focusResult(c, task);
      case '27':
        return _reminders(c);
      case '28':
        return _review(c, weekly: false);
      case '29':
        return _review(c, weekly: true);
      case '43':
        return _deletePage(c, task);
      case '45':
        return task == null ? _missing(context) : _reminderPage(c, task);
      case '46':
        return task == null ? _missing(context) : _completed(c, task);
      case '47':
        return task == null ? _missing(context) : _remaining(c, task);
      default:
        return _missing(context);
    }
  }

  Widget _taskList(SeraController c) {
    if (!identical(_listOwner, c)) {
      _listOwner = c;
      _taskRowKeys.clear();
      _focusTaskRequest = SeraRevealRequest();
      _listRevealPending = _focusTaskId != null;
      _lastCompletion = null;
    }
    final query = taskListQuery(
      tasks: c.data.tasks,
      entries: c.data.entries,
      day: c.today,
      filter: _filter,
    );
    final filtered = query.tasks;
    final indices = {
      for (var i = 0; i < filtered.length; i++) filtered[i].id: i,
    };
    _taskRowKeys.removeWhere((id, _) => !indices.containsKey(id));
    _revealLazyTask(c, indices);
    final completion = _lastCompletion?.canUndoWith(c) == true
        ? _lastCompletion
        : null;
    final rangeLabel = switch (_filter) {
      'inbox' => '未安排',
      'scheduled' => '已安排',
      'today' => '今天',
      'all' => '全部任务',
      _ => null,
    };
    return SeraScaffold(
      title: '计划',
      navIndex: 1,
      showBack: false,
      footer: completion == null ? null : SeraCompletionUndo(completion),
      scrollController: _taskScroll,
      scrollKey: PageStorageKey(('task-list', c, _filter)),
      slivers: [
        SliverToBoxAdapter(
          child: _stack([
            const SeraPlanSwitcher(goals: false),
            _smallGap,
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final value in [('todo', '未完成'), ('done', '已完成')])
                  FilterChip(
                    label: Text(value.$2),
                    selected: _filter == value.$1,
                    onSelected: (_) => setState(() => _filter = value.$1),
                    showCheckmark: false,
                    selectedColor: SeraColors.brand,
                    backgroundColor: const Color(0xffeef2ef),
                    labelStyle: TextStyle(
                      fontSize: 13,
                      color: _filter == value.$1
                          ? Colors.white
                          : SeraColors.muted,
                    ),
                    side: BorderSide.none,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
              ],
            ),
            if (rangeLabel != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(rangeLabel, style: _caption),
              ),
            _smallGap,
            if (filtered.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  switch (_filter) {
                    'todo' => '暂无未完成任务',
                    'done' => '暂无已完成任务',
                    'inbox' => '暂无未安排任务',
                    'scheduled' => '暂无已安排任务',
                    'today' => '今天暂无任务',
                    _ => '暂无任务',
                  },
                  textAlign: TextAlign.center,
                  style: _body,
                ),
              ),
          ]),
        ),
        SliverList.builder(
          itemCount: filtered.length,
          findChildIndexCallback: (key) => key is ValueKey<String>
              ? indices[key.value.replaceFirst('task-list-row:', '')]
              : null,
          itemBuilder: (_, index) {
            final task = filtered[index];
            return SeraRevealOnce(
              key: ValueKey('task-list-row:${task.id}'),
              request: task.id == _focusTaskId ? _focusTaskRequest : null,
              child: KeyedSubtree(
                key: _taskRowKeys.putIfAbsent(task.id, GlobalKey.new),
                child: SeraTodoRow(
                  task,
                  entry: query.firstEntries[task.id],
                  onTap: () =>
                      openScreen(context, '18-task-detail', taskId: task.id),
                  onCheck: c.busy || !task.active
                      ? null
                      : (check, done) => runAction(
                          context,
                          () => c.setCheck(task.id, check, done),
                        ),
                  onDone: c.busy || task.status == 'canceled'
                      ? null
                      : (value) async {
                          final result = await completeTaskFromList(
                            context,
                            c,
                            task,
                            value,
                          );
                          if (mounted &&
                              identical(context.read<SeraController>(), c)) {
                            setState(() => _lastCompletion = result);
                          }
                        },
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  // A lazy row has no BuildContext until it is built. Jump towards its index
  // using measured row heights, then let SeraRevealOnce do the final alignment.
  // This is local to the route/account; it does not issue a jump for every row.
  void _revealLazyTask(SeraController c, Map<String, int> indices) {
    final id = _focusTaskId;
    if (!_listRevealPending ||
        _listRevealRunning ||
        id == null ||
        !indices.containsKey(id)) {
      return;
    }
    _listRevealRunning = true;
    final request = _focusTaskRequest;
    final filter = _filter;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        for (var attempt = 0; attempt < 32; attempt++) {
          if (!mounted ||
              !identical(_listOwner, c) ||
              !identical(_focusTaskRequest, request) ||
              filter != _filter ||
              ModalRoute.of(context)?.isCurrent != true ||
              !_taskScroll.hasClients) {
            return;
          }
          if (_taskRowKeys[id]?.currentContext != null) {
            _listRevealPending = false;
            return;
          }
          final mountedRows = <(int, BuildContext, RenderBox)>[];
          for (final entry in _taskRowKeys.entries) {
            final rowContext = entry.value.currentContext;
            final box = rowContext?.findRenderObject();
            final index = indices[entry.key];
            if (rowContext != null &&
                index != null &&
                box is RenderBox &&
                box.hasSize &&
                box.attached) {
              mountedRows.add((index, rowContext, box));
            }
          }
          if (mountedRows.isEmpty) return;
          final target = indices[id]!;
          mountedRows.sort(
            (a, b) => (a.$1 - target).abs().compareTo((b.$1 - target).abs()),
          );
          final nearest = mountedRows.first;
          final average =
              mountedRows.fold<double>(
                0,
                (sum, row) => sum + row.$3.size.height,
              ) /
              mountedRows.length;
          final viewport =
              Scrollable.of(nearest.$2).context.findRenderObject()!
                  as RenderBox;
          final position = _taskScroll.position;
          final rowTop =
              nearest.$3.localToGlobal(Offset.zero).dy -
              viewport.localToGlobal(Offset.zero).dy;
          final desired =
              position.pixels +
              rowTop +
              (target - nearest.$1) * average -
              position.viewportDimension * .35;
          final next = desired
              .clamp(position.minScrollExtent, position.maxScrollExtent)
              .toDouble();
          if ((next - position.pixels).abs() < .5) return;
          _taskScroll.jumpTo(next);
          await WidgetsBinding.instance.endOfFrame;
        }
      } finally {
        _listRevealRunning = false;
      }
    });
  }

  Widget _taskDetail(SeraController c, SeraTask task) {
    final entry = c.entryForTask(task.id);
    final goal = c.goal(task.goalId);
    final blocks = c.entriesForTask(task.id);
    final completed = task.completedChecks
        .where(task.checklist.contains)
        .length;
    final timing = <String>[
      if (entry != null) _eventDateRange(entry),
      if (task.deadline != null)
        '截止 ${task.deadline!.year != c.today.year ? '${task.deadline!.year}年' : ''}${formatDate(task.deadline!)}${task.dueAt == null ? '' : ' ${formatTime(task.deadline!)}'}',
    ];
    Future<void> toggleDone() async {
      if (_completingDetail) return;
      final account = c.accountId;
      final route = ModalRoute.of(context);
      setState(() {
        _detailError = null;
        _completingDetail = true;
      });
      try {
        if (task.done) {
          await c.setDone(task.id, false);
        } else {
          final before = c.task(task.id);
          if (before == null) throw const RepositoryException('任务已不存在。');
          final recordId = await c.completeTaskWithUndo(task.id);
          if (mounted && _currentOwner(context, route, c, account)) {
            final after = c.task(task.id)!;
            final messenger = ScaffoldMessenger.of(context);
            finishSeraFlow(
              context,
              fallback: Uri(
                path: '/17',
                queryParameters: {'filter': 'done', 'focusTaskId': task.id},
              ).toString(),
              accepts: (uri) =>
                  _canResumeTaskFlow(c, uri) &&
                  !(seraScreenId(uri) == '18' &&
                      uri.queryParameters['taskId'] == task.id),
            );
            _showTaskCompletionUndo(
              messenger,
              SeraTaskCompletion(before, after.revision, c, account, recordId),
            );
          }
        }
      } catch (error) {
        if (mounted && _currentOwner(context, route, c, account)) {
          setState(() => _detailError = '$error');
        }
      } finally {
        if (mounted && _sameOwner(context, c, account)) {
          setState(() => _completingDetail = false);
        }
      }
    }

    return SeraScaffold(
      title: '任务详情',
      actions: [
        TextButton(
          onPressed: () => Router.neglect(context, () {
            context.push(
              Uri(
                path: '/09',
                queryParameters: {
                  'taskId': task.id,
                  if (entry == null) 'mode': 'todo',
                },
              ).toString(),
              extra: const {'replaceHistoryOnExit': true},
            );
          }),
          child: const Text('编辑'),
        ),
      ],
      footer: _stack([
        if (_detailError != null) ...[
          Semantics(
            liveRegion: true,
            child: Text(
              _detailError!,
              style: const TextStyle(
                color: SeraColors.red,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Semantics(
          label: '目标 ${c.focusTargetMinutes(task.id)} 分钟',
          child: SeraButton(
            '开始专注',
            onPressed: c.busy || _completingDetail || !task.active
                ? null
                : () => openScreen(context, '25-focus', taskId: task.id),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: SeraButton(
                task.done ? '设为未完成' : '完成',
                variant: 'ghost',
                busy: _completingDetail,
                onPressed:
                    c.busy || _completingDetail || task.status == 'canceled'
                    ? null
                    : toggleDone,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SeraButton(
                entry == null ? '安排时间' : '修改时间',
                variant: 'ghost',
                onPressed: c.busy || _completingDetail || !task.active
                    ? null
                    : () => Router.neglect(context, () {
                        context.push(
                          Uri(
                            path: '/09-edit-plan-task',
                            queryParameters: {
                              'taskId': task.id,
                              'section': 'time',
                            },
                          ).toString(),
                          extra: const {'replaceHistoryOnExit': true},
                        );
                      }),
              ),
            ),
          ],
        ),
      ]),
      body: _stack([
        if (task.status != 'todo') ...[
          Align(
            alignment: Alignment.centerLeft,
            child: SeraTag(switch (task.status) {
              'done' => '已完成',
              'canceled' => '已取消',
              'blocked' => '遇到阻碍',
              'in_progress' => '进行中',
              _ => '待完成',
            }),
          ),
          const SizedBox(height: 12),
        ],
        SeraIntro(
          task.title,
          subtitle: timing.isEmpty ? null : timing.join('\n'),
        ),
        if (task.blockedReason.isNotEmpty) ...[
          Text(task.blockedReason, style: _body),
          const SizedBox(height: 16),
        ],
        if (task.dependencyIds.any((id) => c.task(id)?.active == true)) ...[
          const SeraSection('先完成'),
          for (final id in task.dependencyIds)
            if (c.task(id) case final SeraTask dependency
                when dependency.active)
              SeraSettingRow(
                dependency.title,
                icon: 'clock',
                onTap: () => openScreen(context, '18', taskId: id),
              ),
          const SizedBox(height: 16),
        ],
        if (task.checklist.isNotEmpty) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('检查清单', style: _strong),
              Text('$completed/${task.checklist.length}', style: _caption),
            ],
          ),
          const SizedBox(height: 8),
          for (final check in task.checklist)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                check,
                style: const TextStyle(fontSize: 15, height: 1.5),
              ),
              value: task.completedChecks.contains(check),
              onChanged: c.busy || !task.active
                  ? null
                  : (value) => runAction(
                      context,
                      () => c.setCheck(task.id, check, value ?? false),
                    ),
            ),
        ],
        if (task.active)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: c.busy ? null : () => _addChecks(task),
              icon: const SeraIcon('plus', size: 18),
              label: const Text('添加子项'),
            ),
          ),
        if (task.checklist.isNotEmpty || task.active)
          const SizedBox(height: 16),
        if (task.notes.isNotEmpty && task.checklist.isEmpty)
          AnimatedBuilder(
            animation: _detailDisclosure,
            builder: (context, _) => _detailDisclosure.isExpanded
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: InkWell(
                      onTap: _detailDisclosure.expand,
                      child: Text(
                        task.notes,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: _body,
                      ),
                    ),
                  ),
          ),
        SeraDisclosure(
          title: '更多任务信息',
          controller: _detailDisclosure,
          children: [
            if (task.notes.isNotEmpty) ...[
              Text(task.notes, style: _body),
              const SizedBox(height: 16),
            ],
            if (blocks.length > 1) ...[
              const SeraSection('分段安排'),
              for (final block in blocks)
                SeraField(
                  formatDate(block.start),
                  formatRange(block.start, block.end),
                ),
            ],
            SeraField('预计用时', formatMinutes(task.estimatedMinutes)),
            SeraField('优先程度', switch (task.priority) {
              'high' => '优先推进',
              'low' => '可以稍后',
              _ => '一般',
            }),
            if (task.remainingMinutes >= 0)
              SeraField('还需用时', formatMinutes(task.remainingMinutes)),
            SeraField('实际投入', _secondsLabel(task.actualSeconds)),
            SeraField('提醒', _reminderLabel(task.reminderMinutes)),
            SeraField('关联目标', goal?.title ?? '不关联目标'),
            if (task.dependencyIds.any((id) => c.task(id)?.done == true))
              for (final id in task.dependencyIds)
                if (c.task(id) case final SeraTask dependency
                    when dependency.done)
                  SeraSettingRow(
                    dependency.title,
                    subtitle: '已完成',
                    icon: 'check',
                    onTap: () => openScreen(context, '18', taskId: id),
                  ),
            const SizedBox(height: 12),
            SeraButton(
              '设置提醒',
              variant: 'quiet',
              onPressed: () => _showReminder(context, task),
            ),
            SeraButton(
              '删除任务',
              variant: 'quiet',
              onPressed: c.busy ? null : () => _deleteTask(context, task),
            ),
          ],
        ),
      ]),
    );
  }

  Widget _eventDetail(SeraController c) {
    final entry = _resolveEntry(c, widget.eventId);
    if (entry == null) return _missing(context, event: true);
    return SeraScaffold(
      title: '日程详情',
      actions: entry.isExternal
          ? []
          : [
              TextButton(
                onPressed: () => openScreen(
                  context,
                  '16-event-edit',
                  eventId: entry.id,
                  replaceBrowserHistory: true,
                ),
                child: const Text('编辑'),
              ),
            ],
      body: _stack([
        Align(
          alignment: Alignment.centerLeft,
          child: SeraTag(entry.locked ? '固定日程' : '日程'),
        ),
        const SizedBox(height: 14),
        SeraIntro(entry.title, subtitle: _eventDateRange(entry)),
        SeraCard(
          child: _stack([
            SeraField('时长', _eventDuration(entry)),
            if (entry.place.isNotEmpty) SeraField('地点', entry.place),
            SeraField('来源', entry.isExternal ? '外部日历 · 请在原日历应用中修改' : '序日'),
          ]),
        ),
        if (entry.notes.isNotEmpty) ...[
          const SeraSection('日程说明'),
          Text(entry.notes, style: _body),
        ],
      ]),
    );
  }

  Widget _checkIn(SeraController c, SeraTask task) => SeraScaffold(
    title: '进展怎么样？',
    body: _stack([
      _symbol('leaf'),
      _centerIntro(task.title, '原计划 ${formatMinutes(task.estimatedMinutes)}'),
      _gap,
      SeraButton(
        '完成任务',
        busy: _completingDetail,
        onPressed: c.busy || _completingDetail ? null : () => _complete(task),
      ),
      _smallGap,
      SeraButton(
        '还需要一点时间',
        variant: 'secondary',
        onPressed: () => openScreen(context, '47-no-capacity', taskId: task.id),
      ),
      _smallGap,
      SeraButton(
        '卡住了，记录原因并调整',
        variant: 'secondary',
        onPressed: () => _reportBlock(c, task),
      ),
      _gap,
      SeraButton(
        '晚一点再看',
        variant: 'quiet',
        onPressed: () => finishSeraFlow(
          context,
          fallback: Uri(
            path: '/18',
            queryParameters: {'taskId': task.id},
          ).toString(),
          accepts: (uri) => _canResumeTaskFlow(c, uri),
        ),
      ),
    ]),
  );

  Widget _focusResult(SeraController c, SeraTask task) {
    final records =
        c.data.focusRecords.where((r) => r.taskId == task.id).toList()
          ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final seconds = records.firstOrNull?.seconds ?? 0;
    return SeraScaffold(
      title: '专注结束',
      body: _stack([
        _symbol('leaf'),
        _centerIntro(
          records.isEmpty ? '暂无专注记录' : '已专注${_secondsLabel(seconds)}',
          task.title,
        ),
        _gap,
        SeraButton(
          '已完成，更新任务进度',
          busy: _completingDetail,
          onPressed: c.busy || _completingDetail ? null : () => _complete(task),
        ),
        _smallGap,
        SeraButton(
          '还差一点，安排剩余时间',
          variant: 'ghost',
          onPressed: () =>
              openScreen(context, '47-no-capacity', taskId: task.id),
        ),
        _smallGap,
        SeraButton(
          '遇到阻碍，记录原因',
          variant: 'quiet',
          onPressed: () => _reportBlock(c, task),
        ),
      ]),
    );
  }

  Widget _reminders(SeraController c) {
    final now = DateTime.now();
    final scheduled = {
      for (final request in buildReminderRequests(c.data).requests)
        '${request['id']}': request,
    };
    final upcoming = <Json>[];
    for (final entry in c.data.entries) {
      final task = c.task(entry.taskId);
      if (task == null || !task.active) continue;
      for (final followUp in [false, true]) {
        if (followUp
            ? !c.data.preferences.followUp
            : task.reminderMinutes < 0) {
          continue;
        }
        final original = followUp
            ? entry.end.add(const Duration(minutes: 5))
            : entry.start.subtract(Duration(minutes: task.reminderMinutes));
        final validUntil = followUp
            ? entry.end.add(const Duration(days: 1))
            : entry.end;
        if (!validUntil.isAfter(now)) continue;
        final id = '${entry.id}:${followUp ? 'followup' : 'start'}';
        final raw = c.data.reminderStates[id];
        final state =
            raw is Map &&
                DateTime.tryParse('${raw['scheduledAt']}')
                        ?.isAtSameMomentAs(original) ==
                    true
            ? raw
            : <String, dynamic>{};
        if (state['status'] == 'ack') continue;
        final trigger =
            scheduled[id]?['fireAt'] as int? ??
            (state['status'] == 'snoozed'
                ? DateTime.tryParse('${state['snoozeUntil']}')
                      ?.millisecondsSinceEpoch
                : null) ??
            original.millisecondsSinceEpoch;
        upcoming.add({
          'id': id,
          'title': task.title,
          'taskId': task.id,
          'followUp': followUp,
          'scheduledAt': original,
          'validUntil': validUntil,
          'trigger': inTimeZone(
            DateTime.fromMillisecondsSinceEpoch(trigger),
            c.data.preferences.timeZone,
          ),
          'snoozed': state['status'] == 'snoozed',
        });
      }
    }
    upcoming.sort(
      (a, b) => (a['trigger'] as DateTime).compareTo(b['trigger'] as DateTime),
    );
    final groups = <String, List<Json>>{};
    for (final reminder in upcoming.take(12)) {
      final day = calendarDateString(reminder['trigger'] as DateTime);
      groups.putIfAbsent(day, () => []).add(reminder);
    }
    final entries = c.data.entries.toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    var conflict = false;
    for (var i = 0; i < entries.length; i++) {
      for (
        var j = i + 1;
        j < entries.length && entries[j].start.isBefore(entries[i].end);
        j++
      ) {
        if ((entries[i].isTask || entries[j].isTask) &&
            !entries[i].end.isBefore(c.today)) {
          conflict = true;
        }
      }
    }
    return SeraScaffold(
      title: '提醒中心',
      actions: [
        IconButton(
          tooltip: '提醒设置',
          onPressed: () => openScreen(context, '33-notification-settings'),
          icon: const SeraIcon('settings'),
        ),
      ],
      body: _stack([
        if (conflict) ...[
          const SeraSection('需要你看一下'),
          SeraCard(
            color: SeraColors.amberBg,
            child: _stack([
              const Text('有一处时间冲突', style: _strong),
              _smallGap,
              const Text('已有日程与任务时间重叠，确认调整前会保留原安排。', style: _body),
              _smallGap,
              SeraButton(
                '查看调整建议',
                variant: 'secondary',
                onPressed: () => openScreen(context, '22-replan'),
              ),
            ]),
          ),
          _gap,
        ],
        if (upcoming.isEmpty) const Text('暂时没有待提醒事项', style: _body),
        for (final group in groups.values) ...[
          SeraSection(
            '${(group.first['trigger'] as DateTime).year == c.today.year ? '' : '${(group.first['trigger'] as DateTime).year}年'}${formatDate(group.first['trigger'] as DateTime)}',
          ),
          SeraCard(
            padding: EdgeInsets.zero,
            child: _stack([
              for (var i = 0; i < group.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _reminderRow(c, group[i], now),
              ],
            ]),
          ),
          _gap,
        ],
      ]),
    );
  }

  Widget _reminderRow(SeraController c, Json reminder, DateTime now) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: _stack([
      InkWell(
        onTap: () => openScreen(
          context,
          reminder['followUp'] == true ? '24' : '18',
          taskId: '${reminder['taskId']}',
        ),
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              Expanded(child: Text('${reminder['title']}', style: _strong)),
              const SizedBox(width: 12),
              const SeraIcon('chevron', size: 18, color: SeraColors.muted),
            ],
          ),
        ),
      ),
      Text(
        '${formatTime(reminder['trigger'] as DateTime)} · ${reminder['followUp'] == true ? '进度跟进' : '开始提醒'} · ${reminder['snoozed'] == true
            ? '稍后提醒'
            : (reminder['trigger'] as DateTime).isBefore(now)
            ? '待处理'
            : '待提醒'}',
        style: _caption,
      ),
      Wrap(
        spacing: 12,
        children: [
          TextButton(
            onPressed: c.busy
                ? null
                : () => runAction(
                    context,
                    () => c.saveReminderState(
                      '${reminder['id']}',
                      'ack',
                      scheduledAt: reminder['scheduledAt'] as DateTime,
                    ),
                    success: '已标记处理',
                  ),
            child: const Text('已了解'),
          ),
          if ((reminder['trigger'] as DateTime).isBefore(now) &&
              (reminder['validUntil'] as DateTime).isAfter(
                now.add(const Duration(minutes: 10)),
              ))
            TextButton(
              onPressed: c.busy
                  ? null
                  : () => runAction(
                      context,
                      () => c.saveReminderState(
                        '${reminder['id']}',
                        'snoozed',
                        scheduledAt: reminder['scheduledAt'] as DateTime,
                        snoozeUntil: now.add(const Duration(minutes: 10)),
                      ),
                      success: '已设为10分钟后提醒',
                    ),
              child: const Text('10分钟后提醒'),
            ),
        ],
      ),
    ]),
  );

  Widget _review(SeraController c, {required bool weekly}) {
    final start = weekly
        ? c.today.subtract(Duration(days: c.today.weekday - 1))
        : c.today;
    final end = start.add(Duration(days: weekly ? 7 : 1));
    bool inRange(DateTime value) =>
        !value.isBefore(start) && value.isBefore(end);
    final entries =
        c.data.entries
            .where((e) => e.taskId != null && inRange(e.start))
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    final ids = entries.map((e) => e.taskId).toSet();
    final planned = c.data.tasks.where((t) => ids.contains(t.id)).toList();
    final completed = planned.where((t) => t.done).toList();
    final records = c.data.focusRecords
        .where((r) => inRange(r.startedAt))
        .toList();
    final seconds = records.fold<int>(0, (total, r) => total + r.seconds);
    return SeraScaffold(
      title: weekly ? '本周回顾' : '今日回顾',
      footer: SeraButton(
        weekly ? '保存本周回顾' : '保存回顾',
        busy: c.busy,
        onPressed: c.busy
            ? null
            : () async {
                final account = c.accountId;
                final ownerRoute = ModalRoute.of(context);
                if (!mounted ||
                    !_currentOwner(context, ownerRoute, c, account)) {
                  return;
                }
                await runAction(context, () async {
                  await c.saveReview(
                    ReviewRecord(
                      id: _reviewKey(c.today),
                      day: weekly ? start : dateOnly(c.today),
                      kind: weekly ? 'weekly' : 'daily',
                      feedback: jsonEncode({
                        'rating': _feedback,
                        'note': _reviewNote.text.trim(),
                      }),
                    ),
                  );
                  if (mounted &&
                      _currentOwner(context, ownerRoute, c, account)) {
                    finishSeraFlow(
                      context,
                      fallback: '/04',
                      accepts: (uri) => _canResumeTaskFlow(c, uri),
                    );
                  }
                }, success: weekly ? '本周回顾已保存' : '今日回顾已保存');
              },
      ),
      body: _stack([
        Text(
          weekly
              ? '${formatDate(start)} — ${formatDate(end.subtract(const Duration(days: 1)))}'
              : formatDate(c.today),
          style: _caption,
        ),
        _gap,
        _stats([
          (
            '${completed.length} / ${planned.length}',
            weekly ? '本周计划任务完成' : '今日计划任务完成',
          ),
          (_secondsLabel(seconds), weekly ? '本周实际专注' : '今日实际专注'),
        ]),
        SeraSection(weekly ? '本周的推进' : '今天完成了什么'),
        if ((weekly ? planned : completed).isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(weekly ? '本周暂无安排任务' : '今天暂无完成任务', style: _body),
          ),
        for (final task in (weekly ? planned : completed))
          SeraTaskRow(
            task,
            entry: entries
                .where((entry) => entry.taskId == task.id)
                .firstOrNull,
            showDate: weekly,
            onTap: () => openScreen(context, '18-task-detail', taskId: task.id),
          ),
        _gap,
        if (!weekly) ...[
          const SeraSection('今天的安排适合你吗？'),
          Wrap(
            spacing: 9,
            runSpacing: 8,
            children: [
              for (final pair in [
                ('light', '稍轻松'),
                ('right', '刚刚好'),
                ('heavy', '有点满'),
              ])
                ChoiceChip(
                  label: Text(pair.$2),
                  selected: _feedback == pair.$1,
                  onSelected: (_) => setState(() => _feedback = pair.$1),
                ),
            ],
          ),
          _gap,
          SeraInput(
            label: '留一句给明天的自己',
            hintText: '写下想法',
            controller: _reviewNote,
            minLines: 2,
            maxLines: 4,
          ),
        ] else ...[
          SeraInput(
            label: '记录本周的收获与下周调整',
            hintText: '写下想法',
            controller: _reviewNote,
            minLines: 3,
            maxLines: 6,
          ),
          TextButton(
            onPressed: () {
              c.setSelectedDate(start.add(const Duration(days: 7)));
              openScreen(context, '13-calendar-week');
            },
            child: const Text('查看下周安排'),
          ),
        ],
      ]),
    );
  }

  Widget _deletePage(SeraController c, SeraTask? selected) {
    final draft = widget.draftId == null ? null : c.draft(widget.draftId);
    final task = draft == null
        ? selected
        : draft.items
              .where(
                (item) =>
                    widget.taskId == null || item.task.id == widget.taskId,
              )
              .firstOrNull
              ?.task;
    if (task == null) return _missing(context);
    return SeraScaffold(
      title: '删除任务？',
      body: _stack([
        _symbol('trash', color: SeraColors.red, background: SeraColors.redBg),
        _centerIntro(
          task.title,
          draft == null
              ? '关联的检查项、日程与提醒将一并移除，可在操作记录中撤销。'
              : '这项任务将从草案中移除，其他草案任务继续保留。',
        ),
        _gap,
        SeraButton(
          '保留任务',
          variant: 'secondary',
          onPressed: () => finishSeraFlow(
            context,
            fallback: Uri(
              path: draft == null ? '/18' : '/08',
              queryParameters: {
                if (draft == null) 'taskId': task.id,
                if (draft != null) 'draftId': draft.id,
                if (draft != null) ..._planningRouteContext(context),
              },
            ).toString(),
            accepts: (uri) => draft == null
                ? _canResumeTaskFlow(c, uri)
                : seraScreenId(uri) == '08' &&
                      uri.queryParameters['draftId'] == draft.id &&
                      c.draft(draft.id)?.status == 'draft',
          ),
        ),
        _smallGap,
        SeraButton(
          '确认删除',
          variant: 'danger',
          onPressed: c.busy
              ? null
              : () => _deleteTask(
                  context,
                  task,
                  draftId: draft?.id,
                  alreadyConfirmed: true,
                ),
        ),
      ]),
    );
  }

  Widget _reminderPage(SeraController c, SeraTask task) => SeraScaffold(
    title: '任务提醒',
    onBack: () => finishSeraFlow(
      context,
      fallback: Uri(
        path: '/18',
        queryParameters: {'taskId': task.id},
      ).toString(),
      accepts: (uri) => _canResumeTaskFlow(c, uri),
    ),
    body: _stack([
      const SeraIntro('什么时候提醒你？', subtitle: '提醒会跟随任务的新开始时间更新。'),
      SeraCard(
        child: _stack([
          Text(task.title, style: _strong),
          _smallGap,
          Text('当前设置：${_reminderLabel(task.reminderMinutes)}', style: _body),
        ]),
      ),
      _gap,
      SeraButton('设置任务提醒', onPressed: () => _showReminder(context, task)),
    ]),
  );

  Widget _completed(SeraController c, SeraTask task) {
    return SeraScaffold(
      title: task.done ? '任务已完成' : '任务进度',
      footer: SeraButton(
        '返回',
        onPressed: () => finishSeraFlow(
          context,
          fallback: '/04',
          accepts: (uri) => _canResumeTaskFlow(c, uri),
        ),
      ),
      body: _stack([
        _symbol(task.done ? 'check' : 'target'),
        Text(
          task.title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 24,
            height: 32 / 24,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          children: [
            Text('实际专注 ${_secondsLabel(task.actualSeconds)}', style: _caption),
            if (task.done)
              TextButton(
                onPressed: c.busy
                    ? null
                    : () => runAction(
                        context,
                        () => c.setDone(task.id, false),
                        success: '任务已恢复为未完成',
                      ),
                child: const Text('撤销完成'),
              ),
          ],
        ),
        if (!task.done) ...[
          _gap,
          SeraButton(
            '确认标记完成',
            busy: _completingDetail,
            onPressed: c.busy || _completingDetail
                ? null
                : () => _complete(task),
          ),
        ],
      ]),
    );
  }

  Widget _remaining(SeraController c, SeraTask task) {
    final remaining =
        _remainingOverride ??
        (task.remainingMinutes >= 0
            ? math.max(5, task.remainingMinutes)
            : math.max(
                15,
                task.estimatedMinutes - (task.actualSeconds / 60).ceil(),
              ));
    final tomorrow = c.today.add(const Duration(days: 1));
    final goal = c.goal(task.goalId);
    final deadline =
        task.deadline ??
        goal?.deadline ??
        DateTime(tomorrow.year, tomorrow.month, tomorrow.day + 7, 18);
    final candidate = c.findAvailableSlot(
      task.id,
      from: tomorrow,
      deadlineOverride: deadline,
      durationMinutes: remaining,
    );
    var suggestedDue = deadline;
    if (candidate != null) {
      final evening = DateTime(
        candidate.end.year,
        candidate.end.month,
        candidate.end.day,
        18,
      );
      suggestedDue = evening.isBefore(candidate.end) ? candidate.end : evening;
      if (suggestedDue.isAfter(deadline)) suggestedDue = deadline;
    }
    final newDue =
        task.deadline == null || task.deadline!.isBefore(suggestedDue)
        ? suggestedDue
        : task.deadline!;
    return SeraScaffold(
      title: '安排剩余时间',
      body: _stack([
        SeraIntro(
          task.title,
          subtitle: '已实际专注 ${_secondsLabel(task.actualSeconds)}',
        ),
        SeraCard(
          child: _stack([
            Text('还需用时：$remaining 分钟', style: _strong),
            Slider(
              value: remaining.clamp(5, 480).toDouble(),
              min: 5,
              max: 480,
              divisions: 95,
              label: '$remaining 分钟',
              onChanged: (value) =>
                  setState(() => _remainingOverride = value.round()),
            ),
            if (task.deadline != null || goal?.deadline != null)
              SeraField(
                '原有截止',
                task.dueDate != null && task.dueAt == null
                    ? '${formatDate(task.deadline!)} 当天完成'
                    : '${formatDate(task.deadline ?? goal!.deadline)} ${formatTime(task.deadline ?? goal!.deadline)}',
              ),
          ]),
        ),
        _gap,
        if (candidate != null) ...[
          const SeraSection('建议时段'),
          SeraCard(
            color: SeraColors.mint,
            child: Text(
              _eventDateRange(candidate),
              style: const TextStyle(
                fontSize: 18,
                height: 26 / 18,
                color: SeraColors.brand,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          _gap,
          const SeraSection('确认时一起更新'),
          SeraCard(
            child: _stack([
              SeraField('剩余专注时长', formatMinutes(remaining)),
              SeraField('任务截止', '${formatDate(newDue)} ${formatTime(newDue)}'),
              const SeraField('原有安排', '替换为新的可用时段'),
            ]),
          ),
          _gap,
        ] else
          SeraEmpty(
            '暂无可用时段',
            '可以调整截止时间、空闲时段或每天可安排的时长。',
            icon: 'clock',
            action: '编辑任务安排',
            onAction: () =>
                openScreen(context, '09-edit-plan-task', taskId: task.id),
          ),
        if (candidate != null)
          SeraButton(
            '确认安排剩余 $remaining 分钟',
            busy: c.busy,
            onPressed: c.busy
                ? null
                : () async {
                    final account = c.accountId;
                    final ownerRoute = ModalRoute.of(context);
                    if (!mounted ||
                        !_currentOwner(context, ownerRoute, c, account)) {
                      return;
                    }
                    await runAction(context, () async {
                      await c.saveTask(
                        task.copyWith(
                          dueAt: task.dueDate != null && task.dueAt == null
                              ? null
                              : newDue,
                          clearDue: task.dueDate != null && task.dueAt == null,
                          remainingMinutes: remaining,
                          status: 'todo',
                          blockedReason: '',
                        ),
                        entry: candidate,
                      );
                      if (mounted &&
                          _currentOwner(context, ownerRoute, c, account)) {
                        finishSeraFlow(
                          context,
                          fallback: Uri(
                            path: '/18',
                            queryParameters: {'taskId': task.id},
                          ).toString(),
                          accepts: (uri) => _canResumeTaskFlow(c, uri),
                        );
                      }
                    }, success: '剩余工作已重新安排');
                  },
          ),
        SeraButton(
          '调整空闲时段与每天可用时长',
          variant: 'ghost',
          onPressed: () => openScreen(context, '31-ai-preferences'),
        ),
        SeraButton(
          '先保留任务，稍后决定',
          variant: 'quiet',
          onPressed: () => finishSeraFlow(
            context,
            fallback: Uri(
              path: '/18',
              queryParameters: {'taskId': task.id},
            ).toString(),
            accepts: (uri) => _canResumeTaskFlow(c, uri),
          ),
        ),
      ]),
    );
  }
}

String _secondsLabel(int seconds) => seconds < 60
    ? '$seconds 秒'
    : seconds % 60 == 0
    ? '${seconds ~/ 60} 分钟'
    : '${seconds ~/ 60} 分 ${seconds % 60} 秒';

class _TaskBlockDialog extends StatefulWidget {
  const _TaskBlockDialog({required this.initialReason});
  final String initialReason;

  @override
  State<_TaskBlockDialog> createState() => _TaskBlockDialogState();
}

class _TaskBlockDialogState extends State<_TaskBlockDialog> {
  late final TextEditingController _reason;

  @override
  void initState() {
    super.initState();
    _reason = TextEditingController(text: widget.initialReason);
  }

  @override
  void dispose() {
    // The dialog owns this controller until its reverse transition has ended.
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('是哪里卡住了？'),
    content: SeraInput(
      label: '记录阻碍和需要的帮助',
      controller: _reason,
      minLines: 3,
      maxLines: 6,
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('稍后记录'),
      ),
      TextButton(
        onPressed: () {
          if (_reason.text.trim().isNotEmpty) {
            Navigator.pop(context, _reason.text.trim());
          }
        },
        child: const Text('记录并生成拆解建议'),
      ),
    ],
  );
}

class _TaskEditor extends StatefulWidget {
  const _TaskEditor({required this.id, this.taskId, this.draftId});
  final String id;
  final String? taskId, draftId;
  @override
  State<_TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<_TaskEditor> {
  final _otherInformationKey = GlobalKey();
  final _otherInformationController = ExpansibleController();
  bool _timeFirst = false;
  final _form = GlobalKey<FormState>();
  final _executionKey = GlobalKey();
  final _executionController = ExpansibleController();
  final _title = TextEditingController();
  final _notes = TextEditingController();
  final _duration = TextEditingController(text: '30');
  final _remaining = TextEditingController();
  final _blocked = TextEditingController();
  final _minBlock = TextEditingController(text: '15');
  final _checks = TextEditingController();
  final _blockDuration = TextEditingController(text: '30');
  List<CalendarEntry> _extraBlocks = [];
  String _initialExtraBlocks = '[]';
  String _status = 'todo', _priority = 'normal';
  Set<String> _dependencies = {};
  bool _splittable = false, _saving = false, _allowExit = false, _saved = false;
  bool _leaving = false;
  bool _replaceHistoryOnExit = false;
  bool _dueDateOnly = false;
  bool _fromAiSuggestion = false;
  bool _todoMode = false, _showTodoChecks = false;
  String? _saveError;
  String? _newTaskId;
  String? _sourceSessionId, _sourceError;
  SeraTask? _original;
  CalendarEntry? _originalEntry;
  DateTime? _due;
  late DateTime _start;
  String? _goalId;
  bool _initialized = false,
      _schedule = false,
      _locked = false,
      _autoSchedule = false;
  bool get _isNew => widget.id.startsWith('19');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) {
      return;
    }
    _initialized = true;
    final routeExtra = GoRouterState.of(context).extra;
    _replaceHistoryOnExit =
        routeExtra is Map && routeExtra['replaceHistoryOnExit'] == true;
    final c = context.read<SeraController>();
    final parameters = GoRouterState.of(context).uri.queryParameters;
    _timeFirst = parameters['section'] == 'time';
    _todoMode = !_timeFirst && parameters['mode'] == 'todo';
    if (!_isNew) {
      if (widget.draftId != null) {
        final items = c.draft(widget.draftId)?.items ?? <PlannedTask>[];
        final item = items
            .where((e) => widget.taskId == null || e.task.id == widget.taskId)
            .firstOrNull;
        _original = item?.task;
        _originalEntry = item?.entry;
        _extraBlocks = [...item?.additionalEntries ?? []];
      } else {
        _original = _resolveTask(c, widget.taskId);
        _originalEntry = _original == null
            ? null
            : c.entryForTask(_original!.id);
        _extraBlocks = _original == null
            ? []
            : c.entriesForTask(_original!.id).skip(1).toList();
      }
      final task = _original;
      if (task != null) {
        _title.text = task.title;
        _notes.text = task.notes;
        _duration.text = '${task.estimatedMinutes}';
        _due = task.deadline;
        _dueDateOnly = task.dueAt == null && task.dueDate != null;
        _goalId = task.goalId;
        _status = task.status;
        _priority = task.priority;
        _dependencies = task.dependencyIds.toSet();
        _splittable = task.splittable;
        _minBlock.text = '${task.minBlockMinutes}';
        _remaining.text = task.remainingMinutes < 0
            ? ''
            : '${task.remainingMinutes}';
        _blocked.text = task.blockedReason;
        _checks.text = task.checklist.join('\n');
      }
    }
    _start = _originalEntry?.start ?? atMinute(c.today, 14 * 60);
    _schedule = _originalEntry != null || _timeFirst;
    _locked = _originalEntry?.locked ?? false;
    if (_isNew && widget.taskId == null && widget.draftId == null) {
      var query = GoRouterState.of(context).uri.queryParameters;
      _sourceSessionId = query['sessionId'];
      if (_sourceSessionId != null) {
        final session = c.planningSession(_sourceSessionId);
        if (session != null && session.stage != 'confirmed') {
          try {
            query = _sessionPrefill(
              session,
              'task',
              c.data.preferences.timeZone,
              manual: query['manual'] == '1',
            );
          } catch (error) {
            _sourceError = '$error';
          }
        }
      }
      _fromAiSuggestion =
          query['fromEvent'] != '1' &&
          (query['fromAi'] == '1' || _sourceSessionId == null) &&
          const [
            'title',
            'notes',
            'estimatedMinutes',
            'dueAt',
            'dueDate',
            'start',
            'end',
          ].any(query.containsKey);
      _title.text = _suggestedText(query['title'], 200) ?? '';
      _notes.text = _sourceSessionId == null
          ? _suggestedText(query['notes'], 10000) ?? ''
          : query['notes'] ?? '';
      final minutes = int.tryParse(query['estimatedMinutes'] ?? '');
      if (minutes != null && minutes >= 5 && minutes <= 480) {
        _duration.text = '$minutes';
      }
      final zone = c.data.preferences.timeZone;
      final dueAt = _suggestedDate(query['dueAt'], zone);
      final dueDate = _suggestedDate(query['dueDate'], zone, dateOnly: true);
      _due = dueAt ?? dueDate;
      _dueDateOnly = dueAt == null && dueDate != null;
      final start = _suggestedDate(query['start'], zone);
      final end = _suggestedDate(query['end'], zone);
      if (start != null && end != null) {
        final span = end.difference(start);
        if (span.inMinutes >= 5 &&
            span.inMinutes <= 480 &&
            span.inMicroseconds ==
                Duration(minutes: span.inMinutes).inMicroseconds) {
          _start = start;
          _schedule = true;
          _duration.text = '${span.inMinutes}';
        }
      }
    }
    _initialExtraBlocks = jsonEncode(
      _extraBlocks.map((e) => e.toJson()).toList(),
    );
    if (_original == null) _newTaskId = c.newId('task');
    _blockDuration.text =
        '${_originalEntry?.minutes ?? int.tryParse(_duration.text) ?? 30}';
    _showTodoChecks = _checks.text.trim().isNotEmpty;
    for (final field in [
      _title,
      _notes,
      _duration,
      _remaining,
      _blocked,
      _minBlock,
      _checks,
      _blockDuration,
    ]) {
      field.addListener(() {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _otherInformationController.dispose();
    _executionController.dispose();
    _title.dispose();
    _notes.dispose();
    _duration.dispose();
    _remaining.dispose();
    _blocked.dispose();
    _minBlock.dispose();
    _checks.dispose();
    _blockDuration.dispose();
    super.dispose();
  }

  Future<DateTime?> _pickDateTime(
    DateTime initial, {
    required String label,
  }) async {
    final c = context.read<SeraController>();
    final account = c.accountId;
    final ownerRoute = ModalRoute.of(context);
    if (!mounted || !_currentOwner(context, ownerRoute, c, account)) {
      return null;
    }
    final date = await SeraMotion.pickDate(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2040),
      helpText: label,
      cancelText: '取消',
      confirmText: '下一步',
    );
    if (date == null ||
        !mounted ||
        !_currentOwner(context, ownerRoute, c, account)) {
      return null;
    }
    final time = await SeraMotion.pickTime(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: label,
      cancelText: '取消',
      confirmText: '确定',
    );
    if (time == null ||
        !mounted ||
        !_currentOwner(context, ownerRoute, c, account)) {
      return null;
    }
    return inTimeZone(
      DateTime(date.year, date.month, date.day, time.hour, time.minute),
      c.data.preferences.timeZone,
      wallClock: true,
    );
  }

  Future<void> _save() async {
    final c = context.read<SeraController>();
    final account = c.accountId;
    final ownerRoute = ModalRoute.of(context);
    if (_saving ||
        _leaving ||
        !mounted ||
        !_currentOwner(context, ownerRoute, c, account)) {
      return;
    }
    final invalid = _form.currentState!.validateGranularly();
    if (invalid.isNotEmpty) {
      final expandingOther =
          _timeFirst &&
          invalid.any((field) => _within(field.context, _otherInformationKey));
      if (expandingOther) _otherInformationController.expand();
      final expanding = invalid.any(
        (field) => _within(field.context, _executionKey),
      );
      if (expanding) _executionController.expand();
      _revealInvalid(context, invalid, expanding: expanding || expandingOther);
      return;
    }
    final minutes = int.parse(_duration.text.trim());
    final checks = _checks.text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    final task = (_original ?? SeraTask(id: _newTaskId!, title: '')).copyWith(
      title: _title.text.trim(),
      notes: _notes.text.trim(),
      goalId: _goalId,
      clearGoal: _goalId == null,
      estimatedMinutes: minutes,
      dueAt: _dueDateOnly ? null : _due,
      clearDue: _due == null || _dueDateOnly,
      dueDate: _dueDateOnly && _due != null
          ? '${_due!.year.toString().padLeft(4, '0')}-${_due!.month.toString().padLeft(2, '0')}-${_due!.day.toString().padLeft(2, '0')}'
          : null,
      clearDueDate: !_dueDateOnly || _due == null,
      timeZone: _original?.timeZone ?? c.data.preferences.timeZone,
      status: _status,
      priority: _priority,
      dependencyIds: _dependencies.toList(),
      splittable: _splittable,
      minBlockMinutes: int.tryParse(_minBlock.text) ?? 15,
      remainingMinutes: int.tryParse(_remaining.text) ?? -1,
      blockedReason: _status == 'blocked' ? _blocked.text.trim() : '',
      checklist: checks,
      completedChecks:
          _original?.completedChecks.where(checks.contains).toList() ?? [],
    );
    final entry = _schedule
        ? CalendarEntry(
            id: _originalEntry?.id ?? c.newId('entry'),
            title: task.title,
            start: _start,
            end: _start.add(
              Duration(
                minutes: _splittable
                    ? int.tryParse(_blockDuration.text) ?? task.workMinutes
                    : task.workMinutes,
              ),
            ),
            taskId: task.id,
            timeZone: _originalEntry?.timeZone ?? c.data.preferences.timeZone,
            place: _originalEntry?.place ?? '',
            notes: _originalEntry?.notes ?? '',
            locked: _locked,
            revision: _originalEntry?.revision ?? 1,
          )
        : null;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      var savedId = task.id;
      if (widget.draftId != null) {
        await c.updateDraftItem(
          widget.draftId!,
          PlannedTask(
            task: task,
            entry: entry,
            additionalEntries: _schedule ? _extraBlocks : [],
          ),
        );
      } else {
        final result = await c.saveTask(
          task,
          blocks: _schedule ? [entry!, ..._extraBlocks] : null,
          removeEntry: !_schedule && !_autoSchedule,
          autoSchedule: _autoSchedule,
          sourceSessionId: _sourceSessionId,
        );
        savedId = result.id;
      }
      if (mounted && _currentOwner(context, ownerRoute, c, account)) {
        setState(() {
          _saved = true;
          _allowExit = true;
        });
        FocusManager.instance.primaryFocus?.unfocus();
        ScaffoldMessenger.of(context).removeCurrentSnackBar();
        if (widget.draftId == null && _original == null) {
          final saved = c.task(savedId)!;
          final router = GoRouter.of(context);
          final filter = saved.done
              ? 'done'
              : !saved.active
              ? 'all'
              : _todoMode
              ? 'todo'
              : c.entryForTask(savedId) == null
              ? 'inbox'
              : c.entriesOn(c.today).any((entry) => entry.taskId == savedId)
              ? 'today'
              : 'all';
          final messenger = ScaffoldMessenger.of(context);
          final restored = finishSeraFlow(
            context,
            fallback: Uri(
              path: '/17',
              queryParameters: {'filter': filter, 'focusTaskId': savedId},
            ).toString(),
            accepts: (uri) => _canResumeTaskFlow(c, uri),
          );
          if (restored) {
            showSeraSavedFeedback(
              messenger: messenger,
              router: router,
              message: '已添加：${saved.title}',
              location: Uri(
                path: '/18',
                queryParameters: {'taskId': savedId},
              ).toString(),
              canOpen: () =>
                  identical(messenger.context.read<SeraController?>(), c) &&
                  c.accountId == account &&
                  c.task(savedId) != null,
            );
          }
          return;
        }
        if (context.canPop()) {
          if (_replaceHistoryOnExit) {
            Router.neglect(context, () => context.pop());
          } else {
            context.pop();
          }
          return;
        }
        Router.neglect(
          context,
          () => context.go(
            Uri(
              path: widget.draftId == null ? '/18' : '/08',
              queryParameters: {
                if (widget.draftId == null) 'taskId': savedId,
                if (widget.draftId != null) 'draftId': widget.draftId!,
                if (widget.draftId != null) ..._planningRouteContext(context),
              },
            ).toString(),
          ),
        );
      }
    } catch (error) {
      if (mounted && _currentOwner(context, ownerRoute, c, account)) {
        setState(() => _saveError = '$error');
      }
    } finally {
      if (mounted && _sameOwner(context, c, account)) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _editBlock(int? index) async {
    final c = context.read<SeraController>();
    final account = c.accountId;
    final ownerRoute = ModalRoute.of(context);
    if (!mounted || !_currentOwner(context, ownerRoute, c, account)) {
      return;
    }
    final old = index == null ? null : _extraBlocks[index];
    final initial =
        old?.start ??
        (_extraBlocks.isNotEmpty
                ? _extraBlocks.last.end
                : _start.add(
                    Duration(minutes: int.tryParse(_blockDuration.text) ?? 30),
                  ))
            .add(Duration(minutes: c.data.preferences.bufferMinutes));
    final start = await _pickDateTime(initial, label: '这次安排何时开始');
    if (start == null ||
        !mounted ||
        !_currentOwner(context, ownerRoute, c, account)) {
      return;
    }
    final input = TextEditingController(
      text: '${old?.minutes ?? int.tryParse(_minBlock.text) ?? 15}',
    );
    final form = GlobalKey<FormState>();
    final lengthDialog = DialogRoute<int>(
      context: context,
      animationStyle: SeraMotion.dialogStyle(context),
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(index == null ? '添加安排' : '修改安排'),
        content: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${formatDate(start)} ${formatTime(start)}',
                style: _caption,
              ),
              SeraInput(
                label: '持续时间（分钟）',
                controller: input,
                keyboardType: TextInputType.number,
                validator: (v) {
                  final n = int.tryParse(v ?? '');
                  return n == null ||
                          n < (int.tryParse(_minBlock.text) ?? 5) ||
                          n > 480
                      ? '不能短于设置的最短时长，且不超过 480 分钟。'
                      : null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              if (form.currentState?.validate() == true) {
                Navigator.pop(ctx, int.parse(input.text));
              }
            },
            child: const Text('保存安排'),
          ),
        ],
      ),
    );
    final length = await Navigator.of(
      context,
      rootNavigator: true,
    ).push(lengthDialog);
    await lengthDialog.completed;
    input.dispose();
    if (length == null ||
        !mounted ||
        !_currentOwner(context, ownerRoute, c, account)) {
      return;
    }
    final block =
        (old ??
                CalendarEntry(
                  id: c.newId('entry'),
                  title: _title.text,
                  taskId: _original?.id ?? _newTaskId,
                  start: start,
                  end: start.add(Duration(minutes: length)),
                  timeZone: c.data.preferences.timeZone,
                ))
            .copyWith(
              start: start,
              end: start.add(Duration(minutes: length)),
            );
    setState(() {
      if (index == null) {
        _extraBlocks.add(block);
      } else {
        _extraBlocks[index] = block;
      }
    });
  }

  bool get _hasChanges =>
      !_saved &&
      (_title.text.trim() != (_original?.title ?? '') ||
          _notes.text.trim() != (_original?.notes ?? '') ||
          (int.tryParse(_duration.text) ?? 0) !=
              (_original?.estimatedMinutes ?? 30) ||
          _due != _original?.deadline ||
          (_due != null &&
              _dueDateOnly !=
                  (_original?.dueDate != null && _original?.dueAt == null)) ||
          _goalId != _original?.goalId ||
          _status != (_original?.status ?? 'todo') ||
          _priority != (_original?.priority ?? 'normal') ||
          _splittable != (_original?.splittable ?? false) ||
          (int.tryParse(_minBlock.text) ?? 0) !=
              (_original?.minBlockMinutes ?? 15) ||
          _checks.text.trim() != (_original?.checklist.join('\n') ?? '') ||
          _blocked.text.trim() != (_original?.blockedReason ?? '') ||
          (int.tryParse(_remaining.text) ?? -1) !=
              (_original?.remainingMinutes ?? -1) ||
          jsonEncode(_extraBlocks.map((e) => e.toJson()).toList()) !=
              _initialExtraBlocks ||
          _dependencies.toList().join('|') !=
              (_original?.dependencyIds.join('|') ?? '') ||
          _schedule != (_originalEntry != null) ||
          _autoSchedule ||
          (_schedule &&
              (_start != _originalEntry?.start ||
                  (_splittable &&
                      int.tryParse(_blockDuration.text) !=
                          _originalEntry?.minutes) ||
                  _locked != (_originalEntry?.locked ?? false))));

  Future<void> _leave() async {
    final c = context.read<SeraController>();
    final account = c.accountId;
    final ownerRoute = ModalRoute.of(context);
    if (_saving ||
        _leaving ||
        !mounted ||
        !_currentOwner(context, ownerRoute, c, account)) {
      return;
    }
    _leaving = true;
    if (_hasChanges) {
      final leave = await showDialog<bool>(
        context: context,
        animationStyle: SeraMotion.dialogStyle(context),
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: const Text('放弃尚未保存的修改？'),
          content: const Text('本次输入还没有保存。可以返回继续编辑，或放弃修改。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('继续编辑'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('放弃修改'),
            ),
          ],
        ),
      );
      if (leave != true ||
          !mounted ||
          !_currentOwner(context, ownerRoute, c, account)) {
        _leaving = false;
        return;
      }
    }
    setState(() => _allowExit = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _currentOwner(context, ownerRoute, c, account)) {
        void leave() => context.canPop() ? context.pop() : context.go('/17');
        if (_replaceHistoryOnExit) {
          Router.neglect(context, leave);
        } else {
          leave();
        }
      } else {
        _leaving = false;
        if (mounted && _sameOwner(context, c, account)) {
          setState(() => _allowExit = false);
        }
      }
    });
  }

  Widget _todoForm(SeraController c) => _stack([
    SeraInput(
      label: '要做什么？',
      controller: _title,
      validator: (value) => value == null || value.trim().isEmpty
          ? '请写下一个任务'
          : value.trim().length > 200
          ? '名称最多 200 字。'
          : null,
    ),
    if (_showTodoChecks)
      SeraInput(
        label: '子项（每行一项）',
        controller: _checks,
        minLines: 2,
        maxLines: 8,
        validator: (value) {
          final items = (value ?? '')
              .split('\n')
              .map((line) => line.trim())
              .where((line) => line.isNotEmpty)
              .toSet();
          if (items.length > 100) return '最多添加 100 个子项。';
          if (items.any((line) => line.length > 500)) return '每个子项最多 500 字。';
          return null;
        },
      )
    else
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => setState(() => _showTodoChecks = true),
          icon: const SeraIcon('plus', size: 18),
          label: const Text('添加子项'),
        ),
      ),
    const SizedBox(height: 16),
    SeraCard(
      child: _stack([
        SeraSettingRow(
          '截止日期',
          icon: 'calendar',
          subtitle: _due == null
              ? '不设截止'
              : '${formatDate(_due!)}${_dueDateOnly ? '' : ' ${formatTime(_due!)}'}',
          onTap: () async {
            final route = ModalRoute.of(context);
            final account = c.accountId;
            if (_due != null && !_dueDateOnly) {
              final picked = await _pickDateTime(_due!, label: '任务截止');
              if (picked != null &&
                  mounted &&
                  _currentOwner(context, route, c, account)) {
                setState(() => _due = picked);
              }
              return;
            }
            final picked = await SeraMotion.pickDate(
              context: context,
              initialDate: _due ?? c.today,
              firstDate: DateTime(2020),
              lastDate: DateTime(2040),
              helpText: '任务截止日期',
            );
            if (picked != null &&
                mounted &&
                _currentOwner(context, route, c, account)) {
              setState(() {
                _due = inTimeZone(
                  picked,
                  c.data.preferences.timeZone,
                  wallClock: true,
                );
                _dueDateOnly = true;
              });
            }
          },
          trailing: _due == null
              ? null
              : IconButton(
                  tooltip: '清除截止日期',
                  onPressed: () => setState(() => _due = null),
                  icon: const Icon(Icons.close, size: 18),
                ),
        ),
        DropdownButtonFormField<String>(
          initialValue: c.data.goals.any((goal) => goal.id == _goalId)
              ? _goalId
              : null,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '关联目标',
            border: InputBorder.none,
          ),
          items: [
            const DropdownMenuItem<String>(value: null, child: Text('不关联目标')),
            for (final goal in c.data.goals)
              DropdownMenuItem(
                value: goal.id,
                child: Text(goal.title, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: widget.draftId == null
              ? (value) => setState(() => _goalId = value)
              : null,
        ),
        SeraSettingRow(
          '安排时间',
          icon: 'clock',
          onTap: () => setState(() => _todoMode = false),
        ),
      ]),
    ),
    const SizedBox(height: 16),
    SeraDisclosure(
      key: _executionKey,
      controller: _executionController,
      title: '备注',
      children: [
        SeraInput(
          label: '备注',
          controller: _notes,
          minLines: 2,
          maxLines: 6,
          validator: (value) =>
              (value?.length ?? 0) > 10000 ? '备注最多 10000 字。' : null,
        ),
      ],
    ),
  ]);

  List<Widget> _identityFields() => [
    if (_fromAiSuggestion) ...[
      const Text('来自AI的建议，请核对后保存', style: _caption),
      const SizedBox(height: 12),
    ],
    SeraInput(
      label: _isNew ? '要做什么？' : '任务名称',
      controller: _title,
      validator: (v) => v == null || v.trim().isEmpty
          ? '请写下一个可以行动的任务'
          : v.trim().length > 200
          ? '任务名称最多 200 字。'
          : null,
    ),
    SeraInput(
      label: _isNew ? '补充说明' : '完成标准',
      controller: _notes,
      minLines: 3,
      maxLines: 5,
      validator: (value) =>
          (value?.length ?? 0) > 10000 ? '说明最多 10000 字，请精简后保存。' : null,
    ),
  ];

  Widget _durationField() => SeraInput(
    label: '预计用时（分钟）',
    controller: _duration,
    keyboardType: TextInputType.number,
    validator: (v) {
      final n = int.tryParse(v ?? '');
      return n == null || n < 5 || n > 480 ? '请输入 5–480 分钟' : null;
    },
  );

  List<Widget> _scheduleFields(SeraController c, int minutes) => [
    SeraSection(_isNew ? '怎么安排这件事？' : '任务时间安排'),
    if (_isNew)
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          ChoiceChip(
            label: const Text('暂不安排'),
            selected: !_schedule && !_autoSchedule,
            onSelected: (_) => setState(() {
              _schedule = false;
              _autoSchedule = false;
            }),
          ),
          ChoiceChip(
            label: const Text('自动找时间'),
            selected: _autoSchedule,
            onSelected: (_) => setState(() {
              _schedule = false;
              _autoSchedule = true;
            }),
          ),
          ChoiceChip(
            label: const Text('手动安排'),
            selected: _schedule,
            onSelected: (_) => setState(() {
              _schedule = true;
              _autoSchedule = false;
            }),
          ),
        ],
      )
    else
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: const Text('安排专注时间', style: _strong),
        subtitle: const Text('关闭后保留任务，并取消日历中的相关安排', style: _caption),
        value: _schedule,
        onChanged: (value) => setState(() => _schedule = value),
      ),
    if (_schedule) ...[
      _gap,
      SeraCard(
        child: _stack([
          if (_splittable)
            SeraInput(
              label: '第一段用时（分钟）',
              controller: _blockDuration,
              keyboardType: TextInputType.number,
              validator: (v) {
                final n = int.tryParse(v ?? '');
                return n == null ||
                        n <
                            (_splittable
                                ? int.tryParse(_minBlock.text) ?? 5
                                : 5) ||
                        n > 480
                    ? '请检查这段安排的时长。'
                    : null;
              },
            ),
          InkWell(
            onTap: () async {
              final ownerRoute = ModalRoute.of(context);
              final account = c.accountId;
              final date = await _pickDateTime(_start, label: '任务开始时间');
              if (date != null &&
                  mounted &&
                  context.mounted &&
                  _currentOwner(context, ownerRoute, c, account)) {
                setState(() => _start = date);
              }
            },
            child: SeraField(
              '开始时间',
              '${formatDate(_start)} ${formatTime(_start)}',
              trailing: const SeraIcon('chevron', size: 16),
            ),
          ),
          SeraField(
            '结束时间',
            formatTime(
              _start.add(
                Duration(
                  minutes: _splittable
                      ? int.tryParse(_blockDuration.text) ?? minutes
                      : minutes,
                ),
              ),
            ),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('固定这个时间', style: TextStyle(fontSize: 14)),
            subtitle: const Text('自动安排不会改动这个时间。', style: _caption),
            value: _locked,
            onChanged: (v) => setState(() => _locked = v),
          ),
        ]),
      ),
      if (_splittable) ...[
        const SeraSection('其他安排'),
        for (var i = 0; i < _extraBlocks.length; i++)
          SeraCard(
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _editBlock(i),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(formatDate(_extraBlocks[i].start), style: _strong),
                        Text(
                          '${formatRange(_extraBlocks[i].start, _extraBlocks[i].end)} · ${_extraBlocks[i].minutes} 分钟',
                          style: _caption,
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '移除这段安排',
                  icon: const SeraIcon('trash', size: 18),
                  onPressed: () => setState(() => _extraBlocks.removeAt(i)),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        SeraButton(
          '添加一段安排',
          variant: 'ghost',
          icon: 'plus',
          onPressed: () => _editBlock(null),
        ),
      ],
    ],
  ];

  List<Widget> _metadataFields(SeraController c) => [
    _gap,
    SeraCard(
      child: _stack([
        InkWell(
          onTap: () async {
            final ownerRoute = ModalRoute.of(context);
            final account = c.accountId;
            if (!mounted || !_currentOwner(context, ownerRoute, c, account)) {
              return;
            }
            if (_dueDateOnly) {
              final picked = await SeraMotion.pickDate(
                context: context,
                initialDate: _due ?? c.today,
                firstDate: DateTime(2020),
                lastDate: DateTime(2040),
              );
              if (picked != null &&
                  mounted &&
                  context.mounted &&
                  _currentOwner(context, ownerRoute, c, account)) {
                setState(
                  () => _due = inTimeZone(
                    picked,
                    c.data.preferences.timeZone,
                    wallClock: true,
                  ),
                );
              }
              return;
            }
            final date = await _pickDateTime(
              _due ?? _start.add(const Duration(hours: 4)),
              label: '任务截止',
            );
            if (date != null &&
                mounted &&
                context.mounted &&
                _currentOwner(context, ownerRoute, c, account)) {
              setState(() => _due = date);
            }
          },
          child: SeraField(
            '截止日期',
            _due == null
                ? '暂无截止 · 点击设置'
                : _dueDateOnly
                ? formatDate(_due!)
                : '${formatDate(_due!)} ${formatTime(_due!)}',
            trailing: const SeraIcon('chevron', size: 16),
          ),
        ),
        if (_due != null)
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('截止只指定日期', style: TextStyle(fontSize: 15)),
            subtitle: const Text('按所选日期结束前完成，不要求具体时刻。', style: _caption),
            value: _dueDateOnly,
            onChanged: (value) => setState(() => _dueDateOnly = value),
          ),
        if (_due != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() => _due = null),
              child: const Text('清除截止日期'),
            ),
          ),
        DropdownButtonFormField<String>(
          initialValue: c.data.goals.any((g) => g.id == _goalId)
              ? _goalId
              : null,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '关联目标',
            border: InputBorder.none,
          ),
          items: [
            const DropdownMenuItem<String>(value: null, child: Text('不关联目标')),
            for (final goal in c.data.goals)
              DropdownMenuItem(
                value: goal.id,
                child: Text(goal.title, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: widget.draftId == null
              ? (value) => setState(() => _goalId = value)
              : null,
        ),
      ]),
    ),
  ];

  List<Widget> _splitFields(int minutes) => [
    SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: const Text('分时段安排', style: _strong),
      subtitle: const Text('可把剩余工作安排到多段空闲时间。', style: _caption),
      value: _splittable,
      onChanged: (v) {
        if (!v && _extraBlocks.isNotEmpty) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('请先移除其他安排，再关闭分时段安排。')));
          return;
        }
        setState(() => _splittable = v);
      },
    ),
    if (_splittable)
      SeraInput(
        label: '每次至少安排（分钟）',
        controller: _minBlock,
        keyboardType: TextInputType.number,
        validator: (v) {
          final n = int.tryParse(v ?? '');
          return n == null || n < 5 || n > minutes
              ? '请输入 5–$minutes 分钟。'
              : null;
        },
      ),
  ];

  List<Widget> _executionFields(SeraController c, int minutes) => [
    _gap,
    SeraDisclosure(
      key: _executionKey,
      controller: _executionController,
      title: '执行方式与前置条件',
      summary: '状态、优先级、剩余工作和拆分方式',
      initiallyExpanded:
          _status != 'todo' || _priority != 'normal' || _splittable,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _status,
          decoration: const InputDecoration(labelText: '任务状态'),
          items: [
            for (final item in [
              ('todo', '待开始'),
              ('in_progress', '进行中'),
              ('blocked', '遇到阻碍'),
              ('done', '已完成'),
              ('canceled', '已取消'),
            ])
              DropdownMenuItem(value: item.$1, child: Text(item.$2)),
          ],
          onChanged: (value) => setState(() => _status = value ?? 'todo'),
        ),
        if (_status == 'blocked')
          SeraInput(
            label: '遇到什么阻碍？',
            controller: _blocked,
            minLines: 2,
            maxLines: 4,
            validator: (v) =>
                v?.trim().isEmpty ?? true ? '请记录阻碍，便于之后继续。' : null,
          ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            for (final p in [
              ('high', '优先推进'),
              ('normal', '一般'),
              ('low', '可以稍后'),
            ])
              ChoiceChip(
                label: Text(p.$2),
                selected: _priority == p.$1,
                onSelected: (_) => setState(() => _priority = p.$1),
              ),
          ],
        ),
        const SizedBox(height: 16),
        SeraInput(
          label: '还需用时（分钟）',
          controller: _remaining,
          keyboardType: TextInputType.number,
          validator: (v) => v?.trim().isEmpty ?? true
              ? null
              : (int.tryParse(v!) == null ||
                        int.parse(v) < 0 ||
                        int.parse(v) > 480
                    ? '请输入 0–480 分钟。'
                    : null),
        ),
        if (!_timeFirst) ..._splitFields(minutes),
        SeraInput(
          label: '完成检查项（每行一项）',
          controller: _checks,
          minLines: 2,
          maxLines: 6,
        ),
        if (c.data.tasks.any((t) => t.id != _original?.id))
          ExpansionTile(
            title: const Text('前置任务', style: _strong),
            subtitle: Text('已选择 ${_dependencies.length} 项', style: _caption),
            tilePadding: EdgeInsets.zero,
            children: [
              for (final dependency in c.data.tasks.where(
                (t) => t.id != _original?.id,
              ))
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    dependency.title,
                    style: const TextStyle(fontSize: 13),
                  ),
                  value: _dependencies.contains(dependency.id),
                  onChanged: (v) => setState(
                    () => v == true
                        ? _dependencies.add(dependency.id)
                        : _dependencies.remove(dependency.id),
                  ),
                ),
            ],
          ),
      ],
    ),
    _gap,
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SeraController>();
    if (!_saving && !_saved) {
      final state = _sessionState(context, _sourceSessionId);
      if (state != null) return state;
      if (_sourceError != null) return _sessionError(context, _sourceError!);
    }
    if (!_isNew &&
        (_original == null ||
            (widget.draftId == null && c.task(_original!.id) == null) ||
            (widget.draftId != null &&
                c
                        .draft(widget.draftId)
                        ?.items
                        .any((item) => item.task.id == _original!.id) !=
                    true))) {
      return _missing(context);
    }
    final minutes = int.tryParse(_duration.text) ?? 30;
    final page = SeraScaffold(
      title: _isNew ? '添加任务' : '编辑任务',
      onBack: _leave,
      footer: _stack([
        if (_saveError != null) ...[
          Semantics(
            liveRegion: true,
            child: Text(
              _saveError!,
              style: const TextStyle(
                color: SeraColors.red,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        SeraButton(
          widget.draftId != null ? '保存到草案' : '保存任务',
          busy: c.busy || _saving,
          onPressed: c.busy || _saving ? null : _save,
        ),
        if (_original != null) const SizedBox(height: 12),
        if (_original != null)
          SeraButton(
            widget.draftId == null ? '删除这项任务' : '删除这项草案任务',
            variant: 'quiet',
            onPressed: c.busy
                ? null
                : () =>
                      _deleteTask(context, _original!, draftId: widget.draftId),
          ),
      ]),
      body: Form(
        key: _form,
        child: _todoMode
            ? _todoForm(c)
            : _stack([
                if (_timeFirst) ...[
                  Text(_title.text, style: _strong),
                  _smallGap,
                  _durationField(),
                  ..._splitFields(minutes),
                  ..._scheduleFields(c, minutes),
                  _gap,
                  SeraDisclosure(
                    key: _otherInformationKey,
                    controller: _otherInformationController,
                    title: '编辑其他信息',
                    children: [
                      ..._identityFields(),
                      ..._metadataFields(c),
                      ..._executionFields(c, minutes),
                    ],
                  ),
                ] else ...[
                  ..._identityFields(),
                  _durationField(),
                  ..._scheduleFields(c, minutes),
                  ..._metadataFields(c),
                  ..._executionFields(c, minutes),
                ],
              ]),
      ),
    );
    return PopScope(
      canPop: _allowExit || !_hasChanges,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: page,
    );
  }
}

class _EventEditor extends StatefulWidget {
  const _EventEditor({this.eventId});
  final String? eventId;
  @override
  State<_EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends State<_EventEditor> {
  final _form = GlobalKey<FormState>();
  final _timeReviewKey = GlobalKey();
  final _title = TextEditingController(),
      _place = TextEditingController(),
      _notes = TextEditingController();
  CalendarEntry? _original;
  late DateTime _start, _end;
  late DateTime _initialStart, _initialEnd;
  DateTime? _timedStart, _timedEnd;
  late bool _initialLocked, _initialAllDay;
  bool _loaded = false, _locked = true, _allDay = false;
  bool _submitting = false;
  bool _allowExit = false, _saved = false, _leaving = false;
  bool _replaceHistoryOnExit = false;
  bool _fromAiSuggestion = false;
  bool _needsTimeConfirmation = false, _timeConfirmed = false;
  bool _showTimeError = false;
  String? _newId;
  String? _sourceSessionId, _sourceError;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) {
      return;
    }
    _loaded = true;
    final routeExtra = GoRouterState.of(context).extra;
    _replaceHistoryOnExit =
        routeExtra is Map && routeExtra['replaceHistoryOnExit'] == true;
    final c = context.read<SeraController>();
    _original = widget.eventId == null
        ? null
        : _resolveEntry(c, widget.eventId);
    final entry = _original;
    if (entry != null) {
      _title.text = entry.title;
      _place.text = entry.place;
      _notes.text = entry.notes;
      _start = entry.start;
      _end = entry.end;
      _locked = entry.locked;
      _allDay = entry.allDay;
    } else {
      _newId = c.newId('entry');
      final date = c.selectedDate;
      _start = atMinute(
        inTimeZone(date, c.data.preferences.timeZone, wallClock: true),
        14 * 60,
      );
      _end = _start.add(const Duration(hours: 1));
      if (widget.eventId == null) {
        var query = GoRouterState.of(context).uri.queryParameters;
        _sourceSessionId = query['sessionId'];
        if (_sourceSessionId != null) {
          final session = c.planningSession(_sourceSessionId);
          if (session != null && session.stage != 'confirmed') {
            try {
              query = _sessionPrefill(
                session,
                'event',
                c.data.preferences.timeZone,
                manual: query['manual'] == '1',
              );
            } catch (error) {
              _sourceError = '$error';
            }
          }
        }
        _fromAiSuggestion =
            query['fromAi'] == '1' ||
            (_sourceSessionId == null &&
                const [
                  'title',
                  'notes',
                  'start',
                  'end',
                ].any(query.containsKey));
        _title.text = _suggestedText(query['title'], 200) ?? '';
        _notes.text = _sourceSessionId == null
            ? _suggestedText(query['notes'], 10000) ?? ''
            : query['notes'] ?? '';
        final zone = c.data.preferences.timeZone;
        _start = _suggestedDate(query['start'], zone) ?? _start;
        _end =
            _suggestedDate(query['end'], zone) ??
            _start.add(const Duration(hours: 1));
        _needsTimeConfirmation =
            _fromAiSuggestion &&
            (query['requiresTimeConfirmation'] == '1' ||
                _suggestedDate(query['start'], zone) == null ||
                _suggestedDate(query['end'], zone) == null);
      }
    }
    _initialStart = _start;
    _initialEnd = _end;
    _initialLocked = _locked;
    _initialAllDay = _allDay;
    for (final field in [_title, _place, _notes]) {
      field.addListener(() {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _place.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pick(bool isStart) async {
    final c = context.read<SeraController>();
    final account = c.accountId;
    final ownerRoute = ModalRoute.of(context);
    if (_submitting ||
        _leaving ||
        !mounted ||
        !_currentOwner(context, ownerRoute, c, account)) {
      return;
    }
    final original = isStart ? _start : _end;
    final date = await SeraMotion.pickDate(
      context: context,
      initialDate: original,
      firstDate: DateTime(2020),
      lastDate: DateTime(2040),
      helpText: isStart ? '开始日期' : '结束日期',
      cancelText: '取消',
      confirmText: '下一步',
    );
    if (date == null ||
        !mounted ||
        !_currentOwner(context, ownerRoute, c, account)) {
      return;
    }
    if (_allDay) {
      final selected = inTimeZone(
        date,
        _original?.timeZone ?? c.data.preferences.timeZone,
        wallClock: true,
      );
      setState(() {
        _timeConfirmed = false;
        if (isStart) {
          _start = selected;
          if (!_end.isAfter(_start)) _end = calendarDay(_start, 1);
        } else {
          _end = selected;
        }
      });
      return;
    }
    final time = await SeraMotion.pickTime(
      context: context,
      initialTime: TimeOfDay.fromDateTime(original),
      helpText: isStart ? '开始时间' : '结束时间',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (time == null ||
        !mounted ||
        !_currentOwner(context, ownerRoute, c, account)) {
      return;
    }
    setState(() {
      _timeConfirmed = false;
      final value = inTimeZone(
        DateTime(date.year, date.month, date.day, time.hour, time.minute),
        _original?.timeZone ?? c.data.preferences.timeZone,
        wallClock: true,
      );
      if (isStart) {
        final duration = _end.difference(_start);
        _start = value;
        _end = value.add(duration);
      } else {
        _end = value;
      }
    });
  }

  void _setAllDay(bool value) {
    if (_submitting || _leaving || value == _allDay) return;
    final zone =
        _original?.timeZone ??
        context.read<SeraController>().data.preferences.timeZone;
    DateTime withClock(DateTime day, DateTime clock) => inTimeZone(
      DateTime(
        day.year,
        day.month,
        day.day,
        clock.hour,
        clock.minute,
        clock.second,
        clock.millisecond,
        clock.microsecond,
      ),
      zone,
      wallClock: true,
    );
    setState(() {
      _timeConfirmed = false;
      if (value) {
        _timedStart = _start;
        _timedEnd = _end;
        _start = dateOnly(_start);
        // An all-day end is exclusive. Include the final occupied day, but
        // preserve an existing exact-midnight boundary.
        final endDay = dateOnly(_end);
        _end = _end == endDay ? endDay : calendarDay(endDay, 1);
        if (!_end.isAfter(_start)) _end = calendarDay(_start, 1);
      } else {
        final clockStart = _timedStart ?? atMinute(_start, 14 * 60);
        final clockEnd = _timedEnd ?? atMinute(_start, 15 * 60);
        final endAtMidnight =
            clockEnd.hour == 0 &&
            clockEnd.minute == 0 &&
            clockEnd.second == 0 &&
            clockEnd.millisecond == 0 &&
            clockEnd.microsecond == 0;
        final endDay = endAtMidnight ? _end : calendarDay(_end, -1);
        _start = withClock(_start, clockStart);
        _end = withClock(endDay, clockEnd);
        if (!_end.isAfter(_start)) {
          final duration = clockEnd.difference(clockStart);
          _end = _start.add(
            duration.isNegative || duration == Duration.zero
                ? const Duration(hours: 1)
                : duration,
          );
        }
      }
      _allDay = value;
    });
  }

  bool get _hasChanges =>
      !_saved &&
      (_title.text.trim() != (_original?.title ?? '') ||
          _place.text.trim() != (_original?.place ?? '') ||
          _notes.text.trim() != (_original?.notes ?? '') ||
          _start != _initialStart ||
          _end != _initialEnd ||
          _locked != _initialLocked ||
          _allDay != _initialAllDay);

  Future<void> _leave() async {
    final c = context.read<SeraController>();
    final account = c.accountId;
    final ownerRoute = ModalRoute.of(context);
    if (_submitting ||
        _leaving ||
        !mounted ||
        !_currentOwner(context, ownerRoute, c, account)) {
      return;
    }
    _leaving = true;
    if (_hasChanges) {
      final leave = await showDialog<bool>(
        context: context,
        animationStyle: SeraMotion.dialogStyle(context),
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: const Text('放弃尚未保存的修改？'),
          content: const Text('本次输入还没有保存。可以返回继续编辑，或放弃修改。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('继续编辑'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('放弃修改'),
            ),
          ],
        ),
      );
      if (leave != true ||
          !mounted ||
          !_currentOwner(context, ownerRoute, c, account)) {
        _leaving = false;
        return;
      }
    }
    setState(() => _allowExit = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _currentOwner(context, ownerRoute, c, account)) {
        void leave() => context.canPop() ? context.pop() : context.go('/12');
        if (_replaceHistoryOnExit) {
          Router.neglect(context, leave);
        } else {
          leave();
        }
      } else {
        _leaving = false;
        if (mounted && _sameOwner(context, c, account)) {
          setState(() => _allowExit = false);
        }
      }
    });
  }

  Future<void> _save() async {
    final c = context.read<SeraController>();
    final account = c.accountId;
    final ownerRoute = ModalRoute.of(context);
    if (_submitting ||
        _leaving ||
        !mounted ||
        !_currentOwner(context, ownerRoute, c, account)) {
      return;
    }
    final invalid = _form.currentState!.validateGranularly();
    if (invalid.isNotEmpty) {
      _revealInvalid(context, invalid);
      return;
    }
    if (_needsTimeConfirmation && !_timeConfirmed) {
      setState(() => _showTimeError = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final review = _timeReviewKey.currentContext;
        if (mounted &&
            _currentOwner(context, ownerRoute, c, account) &&
            review != null) {
          Scrollable.ensureVisible(
            review,
            duration: SeraMotion.scrollDuration(context),
          );
        }
      });
      return;
    }
    if (!_end.isAfter(_start)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('结束时间必须晚于开始时间')));
      return;
    }
    final entry =
        (_original ??
                CalendarEntry(
                  id: _newId!,
                  title: '',
                  start: _start,
                  end: _end,
                  timeZone: c.data.preferences.timeZone,
                ))
            .copyWith(
              title: _title.text.trim(),
              start: _start,
              end: _end,
              place: _place.text.trim(),
              notes: _notes.text.trim(),
              locked: _locked,
              allDay: _allDay,
            );
    setState(() => _submitting = true);
    try {
      final result = await c.saveEntry(
        entry,
        sourceSessionId: _sourceSessionId,
      );
      if (mounted && _currentOwner(context, ownerRoute, c, account)) {
        setState(() {
          _saved = true;
          _allowExit = true;
        });
        FocusManager.instance.primaryFocus?.unfocus();
        ScaffoldMessenger.of(context).removeCurrentSnackBar();
        if (_original == null) {
          final saved = c.entry(result.id)!;
          final messenger = ScaffoldMessenger.of(context);
          final router = GoRouter.of(context);
          final restored = finishSeraFlow(
            context,
            fallback: Uri(
              path: '/12',
              queryParameters: {'focusEntryId': result.id},
            ).toString(),
            accepts: (uri) => _canResumeTaskFlow(c, uri),
          );
          if (!restored) {
            c.setSelectedDate(
              inTimeZone(
                saved.start,
                c.data.preferences.timeZone,
                wallClock: saved.allDay,
              ),
            );
          }
          if (restored) {
            showSeraSavedFeedback(
              messenger: messenger,
              router: router,
              message: '已保存：${saved.title} · ${formatDate(saved.start)}',
              location: Uri(
                path: '/15',
                queryParameters: {'eventId': result.id},
              ).toString(),
              canOpen: () =>
                  identical(messenger.context.read<SeraController?>(), c) &&
                  c.accountId == account &&
                  c.entry(result.id) != null,
            );
          }
          return;
        }
        if (context.canPop()) {
          if (_replaceHistoryOnExit) {
            Router.neglect(context, () => context.pop());
          } else {
            context.pop();
          }
          return;
        }
        Router.neglect(
          context,
          () => context.go(
            Uri(
              path: '/15-event-detail',
              queryParameters: {'eventId': result.id},
            ).toString(),
          ),
        );
      }
    } catch (error) {
      if (mounted && _currentOwner(context, ownerRoute, c, account)) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted && _sameOwner(context, c, account)) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _delete() async {
    final c = context.read<SeraController>();
    final account = c.accountId;
    final ownerRoute = ModalRoute.of(context);
    if (_submitting ||
        _leaving ||
        _original == null ||
        !mounted ||
        !_currentOwner(context, ownerRoute, c, account)) {
      return;
    }
    final entry = _original!;
    setState(() => _submitting = true);
    try {
      final confirm = await showDialog<bool>(
        context: context,
        animationStyle: SeraMotion.dialogStyle(context),
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: const Text('删除这项日程？'),
          content: Text('「${entry.title}」将从应用日历中移除。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('保留'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认删除'),
            ),
          ],
        ),
      );
      if (confirm != true ||
          !mounted ||
          !_currentOwner(context, ownerRoute, c, account)) {
        return;
      }
      await c.deleteEntry(entry.id);
      if (mounted && _currentOwner(context, ownerRoute, c, account)) {
        // The list reflects the deletion immediately. Do not carry a snackbar
        // over subsequent routes, where it can cover the next primary action.
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).removeCurrentSnackBar();
        finishSeraFlow(
          context,
          fallback: '/12',
          accepts: (uri) =>
              _canResumeTaskFlow(c, uri, deletedEntryId: entry.id),
        );
      }
    } catch (error) {
      if (mounted && _currentOwner(context, ownerRoute, c, account)) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted && _sameOwner(context, c, account)) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SeraController>();
    if (!_submitting && !_saved) {
      final state = _sessionState(context, _sourceSessionId);
      if (state != null) return state;
      if (_sourceError != null) return _sessionError(context, _sourceError!);
    }
    if (widget.eventId != null &&
        (_original == null || c.entry(_original!.id) == null)) {
      return _missing(context, event: true);
    }
    if (_original?.isExternal == true) {
      return SeraScaffold(
        title: '外部日历安排',
        body: SeraEmpty(
          '这项安排来自外部日历',
          '请在原日历中修改，再回到日历连接页重新读取。',
          icon: 'calendar',
          action: '管理日历连接',
          onAction: () => openScreen(context, '32'),
        ),
      );
    }
    final page = SeraScaffold(
      title: _original == null ? '添加日程' : '编辑日程',
      onBack: _leave,
      footer: _stack([
        SeraButton(
          '保存日程',
          busy: c.busy || _submitting,
          onPressed: c.busy || _submitting ? null : _save,
        ),
        if (_original != null) const SizedBox(height: 12),
        if (_original != null)
          SeraButton(
            '删除日程',
            variant: 'quiet',
            onPressed: c.busy || _submitting ? null : _delete,
          ),
      ]),
      body: Form(
        key: _form,
        child: _stack([
          if (_fromAiSuggestion) ...[
            const Text('来自AI的建议，请核对后保存', style: _caption),
            const SizedBox(height: 12),
          ],
          SeraInput(
            label: '日程名称',
            controller: _title,
            validator: (v) => v == null || v.trim().isEmpty
                ? '请输入日程名称'
                : v.trim().length > 200
                ? '日程名称最多 200 字。'
                : null,
          ),
          SeraCard(
            child: _stack([
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('全天安排', style: _strong),
                value: _allDay,
                onChanged: _setAllDay,
              ),
              InkWell(
                onTap: () => _pick(true),
                child: SeraField(
                  '开始',
                  _allDay
                      ? formatDate(_start)
                      : '${formatDate(_start)} ${formatTime(_start)}',
                  trailing: const SeraIcon('chevron', size: 16),
                ),
              ),
              InkWell(
                onTap: () => _pick(false),
                child: SeraField(
                  '结束',
                  _allDay
                      ? '${formatDate(_end)}（当日零点结束）'
                      : '${formatDate(_end)} ${formatTime(_end)}',
                  trailing: const SeraIcon('chevron', size: 16),
                ),
              ),
              const SeraField('重复', '不重复'),
              if (_needsTimeConfirmation) ...[
                const Text('AI 尚未确定完整起止时间。请修改或核对上方时间，再确认。', style: _caption),
                CheckboxListTile(
                  key: _timeReviewKey,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('我已核对起止时间', style: _strong),
                  value: _timeConfirmed,
                  onChanged: (value) => setState(() {
                    _timeConfirmed = value ?? false;
                    _showTimeError = false;
                  }),
                ),
                if (_showTimeError)
                  const Text(
                    '请确认起止时间后再保存。',
                    style: TextStyle(color: SeraColors.red, fontSize: 13),
                  ),
              ],
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: _locked,
                onChanged: (v) => setState(() => _locked = v),
                title: const Text('固定这个时间', style: _strong),
                subtitle: const Text('自动安排不会改动这个时间。', style: _caption),
              ),
            ]),
          ),
          _gap,
          SeraInput(label: '地点', controller: _place),
          SeraInput(
            label: '备注',
            controller: _notes,
            minLines: 3,
            maxLines: 5,
            validator: (value) =>
                (value?.length ?? 0) > 10000 ? '备注最多 10000 字，请精简后保存。' : null,
          ),
        ]),
      ),
    );
    return PopScope(
      // Read the current controllers in _leave, including a back event that
      // arrives before the rebuild scheduled by the last keystroke.
      canPop: _allowExit,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: page,
    );
  }
}

class _FocusScreen extends StatefulWidget {
  const _FocusScreen({this.taskId});
  final String? taskId;
  @override
  State<_FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends State<_FocusScreen> {
  Timer? _timer;
  String? _taskId, _focusSessionId, _error;
  bool _initialized = false,
      _finishing = false,
      _asking = false,
      _updating = false;
  int _targetSeconds = 0;
  bool _hasSavedSession(SeraController c) =>
      _taskId != null &&
      _focusSessionId != null &&
      c.data.focusSession?.taskId == _taskId &&
      c.data.focusSession?.id == _focusSessionId;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) {
      return;
    }
    _initialized = true;
    final c = context.read<SeraController>();
    final active = c.data.focusSession;
    final task = c.task(active?.taskId) ?? _resolveTask(c, widget.taskId);
    if (task == null) {
      return;
    }
    _taskId = task.id;
    _focusSessionId = active?.id;
    _targetSeconds = c.focusTargetMinutes(task.id) * 60;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      _start();
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted ||
          _finishing ||
          _asking ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      setState(() {});
      final focus = context.read<SeraController>().data.focusSession;
      if (focus != null &&
          focus.isRunning &&
          focus.elapsedSeconds(DateTime.now()) >= _targetSeconds) {
        _finish();
      }
    });
  }

  Future<void> _start() async {
    if (!mounted ||
        ModalRoute.of(context)?.isCurrent != true ||
        _taskId == null ||
        _updating) {
      return;
    }
    setState(() {
      _updating = true;
      _error = null;
    });
    final c = context.read<SeraController>();
    final account = c.accountId;
    try {
      await c.startFocus(_taskId!, targetMinutes: _targetSeconds ~/ 60);
      if (mounted &&
          _sameOwner(context, c, account) &&
          c.data.focusSession?.taskId == _taskId) {
        setState(() {
          _focusSessionId = c.data.focusSession!.id;
          _targetSeconds = c.focusTargetMinutes(_taskId!) * 60;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted) {
        setState(() => _updating = false);
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _togglePause() async {
    if (_updating || _finishing) {
      return;
    }
    final c = context.read<SeraController>();
    if (!_hasSavedSession(c) ||
        !_currentOwner(context, ModalRoute.of(context), c, c.accountId)) {
      return;
    }
    setState(() => _updating = true);
    try {
      if (c.data.focusSession?.isRunning == true) {
        await c.pauseFocus();
      } else {
        await c.resumeFocus();
      }
      if (mounted) {
        setState(() => _error = null);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted) {
        setState(() => _updating = false);
      }
    }
  }

  Future<void> _finish() async {
    if (!mounted ||
        ModalRoute.of(context)?.isCurrent != true ||
        _asking ||
        _updating ||
        _finishing ||
        _taskId == null) {
      return;
    }
    final c = context.read<SeraController>();
    if (!_hasSavedSession(c)) return;
    final account = c.accountId;
    final ownerRoute = ModalRoute.of(context);
    setState(() => _finishing = true);
    try {
      await c.finishFocus();
      if (mounted && _currentOwner(context, ownerRoute, c, account)) {
        Router.neglect(context, () {
          context.replace(
            Uri(
              path: '/26-focus-result',
              queryParameters: {'taskId': _taskId!},
            ).toString(),
          );
        });
      } else if (mounted) {
        setState(() => _finishing = false);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _finishing = false;
          _error = '$error';
        });
      }
    }
  }

  Future<void> _confirmExit() async {
    final c = context.read<SeraController>();
    final account = c.accountId;
    final ownerRoute = ModalRoute.of(context);
    if (_asking ||
        _finishing ||
        !mounted ||
        !_currentOwner(context, ownerRoute, c, account)) {
      return;
    }
    if (_updating) return;
    if (!_hasSavedSession(c)) {
      finishSeraFlow(
        context,
        fallback: Uri(
          path: '/18',
          queryParameters: {'taskId': _taskId!},
        ).toString(),
        accepts: (uri) => _canResumeTaskFlow(c, uri),
      );
      return;
    }
    _asking = true;
    var pausing = false;
    late final DialogRoute<bool> exitRoute;
    exitRoute = DialogRoute<bool>(
      context: context,
      animationStyle: SeraMotion.dialogStyle(context),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          scrollable: true,
          title: const Text('结束这次专注？'),
          content: const Text('会按实际计时保存专注记录，之后再确认任务是否完成。'),
          actions: [
            TextButton(
              onPressed: pausing
                  ? null
                  : () async {
                      if (pausing ||
                          !mounted ||
                          !ctx.mounted ||
                          !_sameOwner(context, c, account) ||
                          !_hasSavedSession(c) ||
                          !_currentOwner(ctx, exitRoute, c, account)) {
                        return;
                      }
                      setDialogState(() => pausing = true);
                      try {
                        await c.pauseFocus();
                        if (!mounted ||
                            !ctx.mounted ||
                            !_sameOwner(context, c, account) ||
                            !_currentOwner(ctx, exitRoute, c, account)) {
                          return;
                        }
                        Navigator.pop(ctx, false);
                        await exitRoute.completed;
                        if (mounted &&
                            _currentOwner(context, ownerRoute, c, account)) {
                          finishSeraFlow(
                            context,
                            fallback: '/04',
                            accepts: (uri) => _canResumeTaskFlow(c, uri),
                          );
                        }
                      } catch (error) {
                        if (mounted &&
                            ctx.mounted &&
                            _sameOwner(context, c, account) &&
                            _currentOwner(ctx, exitRoute, c, account)) {
                          setDialogState(() => pausing = false);
                          ScaffoldMessenger.of(ctx)
                              .showSnackBar(SnackBar(content: Text('$error')));
                        }
                      }
                    },
              child: Text(pausing ? '正在暂停…' : '暂停并稍后继续'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('继续专注'),
            ),
            TextButton(
              onPressed: pausing ? null : () => Navigator.pop(ctx, true),
              child: const Text('结束并保存'),
            ),
          ],
        ),
      ),
    );
    final shouldEnd = await Navigator.of(context).push(exitRoute);
    await exitRoute.completed;
    _asking = false;
    if (shouldEnd == true &&
        mounted &&
        _currentOwner(context, ownerRoute, c, account)) {
      await _finish();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SeraController>();
    final task = c.task(_taskId);
    if (task == null) return _missing(context);
    final focus = c.data.focusSession;
    final hasSession = _hasSavedSession(c);
    final pendingChecks = task.checklist
        .where((check) => !task.completedChecks.contains(check))
        .toList();
    final focusNotes = pendingChecks.isNotEmpty
        ? pendingChecks.join('、')
        : task.notes.trim();
    final elapsed = hasSession ? focus!.elapsedSeconds(DateTime.now()) : 0;
    final paused = focus?.isRunning != true;
    final remaining = math.max(0, _targetSeconds - elapsed);
    final display =
        "${(remaining ~/ 60).toString().padLeft(2, '0')}:${(remaining % 60).toString().padLeft(2, '0')}";
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmExit();
      },
      child: SeraScaffold(
        title: '专注一下',
        onBack: _confirmExit,
        body: _stack([
          const SizedBox(height: 22),
          if (widget.taskId != null && widget.taskId != task.id) ...[
            const SeraNote('先继续上次专注', body: '另一个任务的专注尚未结束。先结束或保存这次专注，再切换任务。'),
            _gap,
          ],
          if (_error != null) ...[
            SeraNote(
              '专注状态未保存',
              body: _error,
              color: SeraColors.amber,
              background: SeraColors.amberBg,
            ),
            SeraButton('重试', onPressed: _start),
            _gap,
          ],
          Center(child: SeraTag(c.goal(task.goalId)?.title ?? '眼前这一步')),
          const SizedBox(height: 15),
          Text(
            task.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 38),
            child: Center(
              child: SizedBox(
                width: 244,
                height: 244,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox.expand(
                      child: CircularProgressIndicator(
                        value: (elapsed / math.max(1, _targetSeconds)).clamp(
                          0.0,
                          1.0,
                        ),
                        strokeWidth: 7,
                        backgroundColor: const Color(0xffdde9e2),
                        color: SeraColors.brand,
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          display,
                          style: const TextStyle(
                            fontSize: 56,
                            height: 64 / 56,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -1,
                          ),
                        ),
                        const Text('剩余专注时间', style: _caption),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          Text(
            '目标 ${formatMinutes(_targetSeconds ~/ 60)} · ${_finishing
                ? '正在保存'
                : !hasSession
                ? '尚未开始'
                : paused
                ? '已暂停'
                : '已开始'}',
            textAlign: TextAlign.center,
            style: _caption,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 25),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.filledTonal(
                  tooltip: paused ? '继续专注' : '暂停专注',
                  onPressed: _finishing || _updating || !hasSession
                      ? null
                      : _togglePause,
                  icon: Icon(
                    paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  ),
                  style: IconButton.styleFrom(
                    minimumSize: const Size(54, 54),
                    backgroundColor: SeraColors.mint,
                    foregroundColor: SeraColors.brand,
                  ),
                ),
                const SizedBox(width: 20),
                IconButton.filled(
                  tooltip: '结束并保存专注',
                  onPressed: _finishing || _updating || !hasSession
                      ? null
                      : _finish,
                  icon: const Icon(Icons.stop_rounded),
                  style: IconButton.styleFrom(
                    minimumSize: const Size(54, 54),
                    backgroundColor: SeraColors.brand,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          if (focusNotes.isNotEmpty)
            SeraCard(
              child: _stack([
                const Text('这次先做到', style: _caption),
                const SizedBox(height: 8),
                Text(focusNotes, style: _body),
              ]),
            ),
          _gap,
          const Text(
            '结束专注后，再确认任务的实际进展。\n暂停期间不会计入专注时长。',
            textAlign: TextAlign.center,
            style: _caption,
          ),
        ]),
      ),
    );
  }
}
