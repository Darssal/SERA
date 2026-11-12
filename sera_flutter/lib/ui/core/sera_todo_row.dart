import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../application/sera_controller.dart';
import '../../data/workspace_repository.dart';
import '../../domain/models.dart';
import 'sera_motion.dart';
import 'sera_widgets.dart';

class SeraTaskCompletion {
  const SeraTaskCompletion(
    this.before,
    this.revision,
    this.owner,
    this.accountId,
    this.recordId,
  );
  final SeraTask before;
  final int revision;
  final SeraController owner;
  final String? accountId;
  final String recordId;

  bool canUndoWith(SeraController controller) {
    if (!identical(owner, controller) || accountId != controller.accountId) {
      return false;
    }
    final current = controller.task(before.id);
    return current != null && current.done && current.revision == revision;
  }
}

/// Keep the last completion reversible even after it leaves the pending list.
Future<SeraTaskCompletion?> completeTaskFromList(
  BuildContext context,
  SeraController controller,
  SeraTask task,
  bool done,
) async {
  final route = ModalRoute.of(context);
  final account = controller.accountId;
  SeraTaskCompletion? result;
  await runAction(context, () async {
    final before = controller.task(task.id);
    if (before == null) throw const RepositoryException('任务已不存在。');
    final recordId = done
        ? await controller.completeTaskWithUndo(task.id)
        : null;
    if (!done) await controller.setDone(task.id, false);
    if (done &&
        !before.done &&
        context.mounted &&
        identical(context.read<SeraController>(), controller) &&
        controller.accountId == account &&
        route?.isCurrent == true) {
      final after = controller.task(task.id);
      if (after?.done == true && after!.revision == before.revision + 1) {
        result = SeraTaskCompletion(
          before,
          after.revision,
          controller,
          account,
          recordId!,
        );
      }
    }
  });
  return result;
}

class SeraCompletionUndo extends StatefulWidget {
  const SeraCompletionUndo(this.completion, {super.key});
  final SeraTaskCompletion completion;
  @override
  State<SeraCompletionUndo> createState() => _SeraCompletionUndoState();
}

class _SeraCompletionUndoState extends State<SeraCompletionUndo> {
  bool _pending = false;
  String? _error;
  @override
  void didUpdateWidget(SeraCompletionUndo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.completion.recordId != widget.completion.recordId) {
      _error = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<SeraController>();
    if (!widget.completion.canUndoWith(controller)) {
      return const SizedBox.shrink();
    }
    final previous = widget.completion.before;
    final current = controller.task(previous.id)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const SeraIcon('check', size: 18, color: SeraColors.brand),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '已完成 ${current.title}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: SeraColors.muted),
              ),
            ),
            TextButton(
              onPressed: _pending || controller.busy
                  ? null
                  : () async {
                      setState(() {
                        _pending = true;
                        _error = null;
                      });
                      try {
                        await controller.undoTaskCompletion(
                          widget.completion.recordId,
                        );
                      } catch (error) {
                        if (mounted) setState(() => _error = '$error');
                      } finally {
                        if (mounted) setState(() => _pending = false);
                      }
                    },
              child: const Text('撤销完成'),
            ),
          ],
        ),
        if (_error != null)
          Text(
            _error!,
            style: const TextStyle(
              color: SeraColors.red,
              fontSize: 13,
              height: 1.5,
            ),
          ),
      ],
    );
  }
}

/// A task shown as an actionable checklist item, without requiring a time slot.
class SeraTodoRow extends StatefulWidget {
  const SeraTodoRow(
    this.task, {
    super.key,
    this.entry,
    this.onTap,
    this.onDone,
    this.onCheck,
  });

  final SeraTask task;
  final CalendarEntry? entry;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onDone;
  final void Function(String check, bool done)? onCheck;

  @override
  State<SeraTodoRow> createState() => _SeraTodoRowState();
}

class _SeraTodoRowState extends State<SeraTodoRow>
    with AutomaticKeepAliveClientMixin<SeraTodoRow> {
  bool _expanded = false;

  @override
  bool get wantKeepAlive => _expanded;

  @override
  void didUpdateWidget(SeraTodoRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.id != widget.task.id || widget.task.checklist.isEmpty) {
      _expanded = false;
      updateKeepAlive();
    }
  }

  Widget _animateChecklist(BuildContext context, Widget child) {
    if (SeraMotion.reduced(context)) return child;
    return AnimatedSize(
      duration: SeraMotion.primaryDuration,
      reverseDuration: SeraMotion.reverseDuration,
      curve: SeraMotion.curve,
      alignment: Alignment.topCenter,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final task = widget.task;
    final entry = widget.entry;
    final duration = SeraMotion.reduced(context)
        ? Duration.zero
        : SeraMotion.primaryDuration;
    final details = <String>[
      if (entry != null) formatEntryRange(entry, showDate: true),
      if (entry == null && task.deadline != null)
        '${formatDate(task.deadline!)}截止',
      if (task.checklist.isNotEmpty)
        '${task.completedChecks.where(task.checklist.contains).length}/${task.checklist.length} 项',
      if (task.status == 'blocked') '遇到阻碍',
    ];
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: SeraColors.line)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: widget.onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 64),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Checkbox(
                        value: task.done,
                        semanticLabel:
                            '${task.done ? '恢复未完成' : '完成'} ${task.title}',
                        onChanged: widget.onDone == null
                            ? null
                            : (value) => widget.onDone!(value ?? false),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                task.title,
                                style: TextStyle(
                                  fontSize: 16,
                                  height: 1.5,
                                  color: task.done
                                      ? SeraColors.muted
                                      : SeraColors.ink,
                                  decoration: task.done
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                              ),
                              if (details.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  details.join(' · '),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    height: 1.5,
                                    color: SeraColors.muted,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      if (task.checklist.isNotEmpty)
                        Semantics(
                          expanded: _expanded,
                          child: IconButton(
                            tooltip: _expanded ? '收起子项' : '展开子项',
                            onPressed: () {
                              setState(() => _expanded = !_expanded);
                              updateKeepAlive();
                            },
                            icon: AnimatedRotation(
                              turns: _expanded ? .5 : 0,
                              duration: duration,
                              curve: SeraMotion.curve,
                              child: const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 22,
                                color: SeraColors.muted,
                              ),
                            ),
                          ),
                        )
                      else if (task.goalId != null)
                        const Padding(
                          padding: EdgeInsets.only(left: 8, right: 12),
                          child: SeraIcon(
                            'target',
                            size: 16,
                            color: SeraColors.muted,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            _animateChecklist(
              context,
              _expanded && task.checklist.isNotEmpty
                  ? Padding(
                      key: ValueKey('todo-checklist:${task.id}'),
                      padding: const EdgeInsets.only(
                        left: 32,
                        right: 8,
                        bottom: 8,
                      ),
                      child: Column(
                        children: [
                          for (final check in task.checklist)
                            CheckboxListTile(
                              key: ValueKey('todo-check:${task.id}:$check'),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              title: Text(
                                check,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.5,
                                  color: task.completedChecks.contains(check)
                                      ? SeraColors.muted
                                      : SeraColors.ink,
                                  decoration:
                                      task.completedChecks.contains(check)
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                              ),
                              value: task.completedChecks.contains(check),
                              onChanged: widget.onCheck == null
                                  ? null
                                  : (value) =>
                                        widget.onCheck!(check, value ?? false),
                            ),
                        ],
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}
