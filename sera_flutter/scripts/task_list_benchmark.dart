import 'dart:convert';
import 'dart:io';

import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/domain/todo_queries.dart';

/// Test-only reproduction of the former list build: calculate every filter and
/// scan entries for each task before selecting the requested result.
({List<SeraTask> tasks, Map<String, CalendarEntry> firstEntries})
legacyTaskList({
  required List<SeraTask> tasks,
  required List<CalendarEntry> entries,
  required DateTime day,
  required String filter,
}) {
  CalendarEntry? first(String id) =>
      entries.where((entry) => entry.taskId == id).firstOrNull;
  final today = todayTodoTasks(tasks: tasks, entries: entries, day: day);
  final inbox = tasks
      .where((task) => first(task.id) == null && task.active)
      .toList();
  final scheduled = tasks
      .where((task) => first(task.id) != null && task.active)
      .toList();
  final done = tasks.where((task) => task.done).toList();
  final todo = pendingTodoTasks(tasks);
  final selected = switch (filter) {
    'todo' => todo,
    'today' => today,
    'inbox' => inbox,
    'scheduled' => scheduled,
    'done' => done,
    _ => tasks,
  };
  return (
    tasks: selected,
    firstEntries: {
      for (final task in selected)
        if (first(task.id) case final CalendarEntry entry) task.id: entry,
    },
  );
}

Workspace taskBenchmarkWorkspace(int count) {
  final day = DateTime(2026, 11, 8);
  final tasks = [
    for (var i = 0; i < count; i++)
      SeraTask(
        id: 'task-$i',
        title: i % 7 == 0 ? '一项带有较长说明的实际任务，需要核对资料并完成记录 $i' : '任务 $i',
        status: i % 11 == 0
            ? 'done'
            : i % 13 == 0
            ? 'canceled'
            : i % 5 == 0
            ? 'blocked'
            : 'todo',
        dueAt: i % 4 == 0
            ? day.add(const Duration(hours: 18))
            : day.add(const Duration(days: 3)),
        notBefore: i % 17 == 0 ? day.add(const Duration(days: 2)) : null,
        checklist: i % 7 == 0 ? const ['核对资料', '记录结果'] : const [],
      ),
  ];
  return Workspace(
    revision: 1,
    tasks: tasks,
    entries: [
      for (var i = 0; i < count; i++)
        if (i % 3 != 0)
          // Deliberately reverse time order: display must keep the source-first
          // entry instead of silently switching to chronological first.
          for (final hour in [16, 10, 8])
            CalendarEntry(
              id: 'entry-$i-$hour',
              taskId: tasks[i].id,
              title: tasks[i].title,
              start: day.add(Duration(hours: hour)),
              end: day.add(Duration(hours: hour, minutes: 30)),
            ),
    ],
  );
}

void main(List<String> arguments) {
  final results = <Map<String, Object>>[];
  const filters = ['todo', 'today', 'inbox', 'scheduled', 'done', 'all'];
  for (final count in [100, 300, 1000]) {
    final workspace = taskBenchmarkWorkspace(count);
    for (final filter in filters) {
      final old = legacyTaskList(
        tasks: workspace.tasks,
        entries: workspace.entries,
        day: DateTime(2026, 11, 8),
        filter: filter,
      );
      final next = taskListQuery(
        tasks: workspace.tasks,
        entries: workspace.entries,
        day: DateTime(2026, 11, 8),
        filter: filter,
      );
      if (old.tasks.map((t) => t.id).join(',') !=
              next.tasks.map((t) => t.id).join(',') ||
          old.tasks.any(
            (t) => old.firstEntries[t.id]?.id != next.firstEntries[t.id]?.id,
          )) {
        throw StateError('Query changed semantics for $count/$filter');
      }
      const iterations = 30;
      void runOld() => legacyTaskList(
        tasks: workspace.tasks,
        entries: workspace.entries,
        day: DateTime(2026, 11, 8),
        filter: filter,
      );
      void runNew() => taskListQuery(
        tasks: workspace.tasks,
        entries: workspace.entries,
        day: DateTime(2026, 11, 8),
        filter: filter,
      );
      for (var i = 0; i < 8; i++) {
        runOld();
        runNew();
      }
      final before = Stopwatch()..start();
      for (var i = 0; i < iterations; i++) {
        runOld();
      }
      before.stop();
      final after = Stopwatch()..start();
      for (var i = 0; i < iterations; i++) {
        runNew();
      }
      after.stop();
      results.add({
        'tasks': count,
        'entries': workspace.entries.length,
        'filter': filter,
        'resultCount': next.tasks.length,
        'iterations': iterations,
        'oldTotalMicroseconds': before.elapsedMicroseconds,
        'indexedTotalMicroseconds': after.elapsedMicroseconds,
        'equivalentOrderedTasksAndFirstEntries': true,
      });
    }
  }
  final output = File(
    arguments.isEmpty
        ? '.local/minimal-engineering-list-benchmark.json'
        : arguments.first,
  );
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'recordedAt': DateTime.now().toIso8601String(),
      'runtime': Platform.version,
      'environment': 'Windows Dart VM JIT microbenchmark; not Flutter profile, device latency or frame rate',
      'queryResults': results,
    }),
  );
  stdout.writeln(
    'Verified ${results.length} query cases; wrote ${output.path}',
  );
}
