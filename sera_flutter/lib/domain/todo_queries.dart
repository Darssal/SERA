import 'models.dart';

/// Every active task remains a to-do until the user completes or cancels it.
/// A deadline is the latest completion date, not the date work may begin.
List<SeraTask> pendingTodoTasks(Iterable<SeraTask> tasks) =>
    tasks.where((task) => task.active).toList();

/// Build only the requested list and preserve entryForTask's source-order first
/// entry. This index belongs to one snapshot; it is never shared across accounts.
({List<SeraTask> tasks, Map<String, CalendarEntry> firstEntries})
taskListQuery({
  required List<SeraTask> tasks,
  required Iterable<CalendarEntry> entries,
  required DateTime day,
  required String filter,
}) {
  final firstEntries = <String, CalendarEntry>{};
  final todayIds = <String>{};
  final start = dateOnly(day);
  final end = calendarDay(start, 1);
  for (final entry in entries) {
    final id = entry.taskId;
    if (id == null) continue;
    firstEntries.putIfAbsent(id, () => entry);
    if (filter == 'today' &&
        entry.start.isBefore(end) &&
        entry.end.isAfter(start)) {
      todayIds.add(id);
    }
  }
  final filtered = filter == 'all'
      ? tasks
      : tasks
            .where(
              (task) => switch (filter) {
                'done' => task.done,
                'inbox' => task.active && !firstEntries.containsKey(task.id),
                'scheduled' => task.active && firstEntries.containsKey(task.id),
                'today' =>
                  task.active &&
                      (task.notBefore == null ||
                          task.notBefore!.isBefore(end)) &&
                      (todayIds.contains(task.id) ||
                          (task.deadline != null &&
                              task.deadline!.isBefore(end))),
                _ => task.active,
              },
            )
            .toList();
  return (tasks: filtered, firstEntries: firstEntries);
}

List<SeraTask> todayTodoTasks({
  required Iterable<SeraTask> tasks,
  required Iterable<CalendarEntry> entries,
  required DateTime day,
}) {
  final start = dateOnly(day);
  final end = calendarDay(start, 1);
  final taskEntries = <String, List<CalendarEntry>>{};
  for (final entry in entries) {
    final taskId = entry.taskId;
    if (taskId != null) {
      (taskEntries[taskId] ??= []).add(entry);
    }
  }
  return tasks.where((task) {
    if (!task.active) return false;
    if (task.notBefore != null && !task.notBefore!.isBefore(end)) {
      return false;
    }
    final blocks = taskEntries[task.id] ?? const <CalendarEntry>[];
    if (blocks.any(
      (block) => block.start.isBefore(end) && block.end.isAfter(start),
    )) {
      return true;
    }
    if (task.deadline != null && task.deadline!.isBefore(end)) return true;
    // Today is an execution view. Unscheduled and unfinished past work
    // remains in the task library until scheduled or due.
    return false;
  }).toList();
}
