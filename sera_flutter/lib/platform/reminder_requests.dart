import '../domain/models.dart';

class ReminderRequests {
  const ReminderRequests(this.requests, this.skipped);
  final List<Map<String, dynamic>> requests;
  final int skipped;
}

/// Generate absolute local reminders; never invent a schedule for inbox items.
ReminderRequests buildReminderRequests(Workspace workspace, {DateTime? now}) {
  if (!workspace.preferences.notifications) {
    return const ReminderRequests([], 0);
  }
  final clock = now ?? DateTime.now();
  final prefs = workspace.preferences;
  final tasks = {for (final t in workspace.tasks) t.id: t};
  final requests = <Map<String, dynamic>>[];
  var skipped = 0;
  for (final entry in workspace.entries) {
    final task = tasks[entry.taskId];
    if (task == null || !task.active) continue;
    void add(DateTime trigger, {required bool followUp}) {
      final id = '${entry.id}:${followUp ? 'followup' : 'start'}';
      final validUntil = followUp
          ? entry.end.add(const Duration(days: 1))
          : entry.end;
      var at = trigger;
      final rawState = workspace.reminderStates[id];
      if (rawState is Map) {
        final scheduledAt = DateTime.tryParse('${rawState['scheduledAt']}');
        if (scheduledAt != null && scheduledAt.isAtSameMomentAs(trigger)) {
          if (rawState['status'] == 'ack') {
            skipped++;
            return;
          }
          if (rawState['status'] == 'snoozed') {
            at =
                DateTime.tryParse('${rawState['snoozeUntil']}') ??
                (DateTime.tryParse('${rawState['at']}') ?? clock).add(
                  const Duration(minutes: 10),
                );
          }
        }
      }
      at = inTimeZone(at, prefs.timeZone);
      if (isQuietMinute(
        at.hour * 60 + at.minute,
        prefs.quietStart,
        prefs.quietEnd,
      )) {
        final dayOffset =
            prefs.quietStart > prefs.quietEnd &&
                at.hour * 60 + at.minute >= prefs.quietStart
            ? 1
            : 0;
        at = atMinute(calendarDay(at, dayOffset), prefs.quietEnd);
      }
      if (!at.isAfter(clock) || !at.isBefore(validUntil)) {
        skipped++;
        return;
      }
      requests.add({
        'id': id,
        'entryId': entry.id,
        'title': task.title,
        'body': followUp
            ? '刚才那一步进展怎么样？记录完成、剩余时间或遇到的阻碍。'
            : '计划 ${inTimeZone(entry.start, prefs.timeZone).hour.toString().padLeft(2, '0')}:${inTimeZone(entry.start, prefs.timeZone).minute.toString().padLeft(2, '0')} 开始，给重要的事留一点时间。',
        'fireAt': at.millisecondsSinceEpoch,
        'scheduledAt': trigger.toUtc().toIso8601String(),
        'taskId': task.id,
        'kind': followUp ? 'followup' : 'start',
        'generation': workspace.revision,
        'validUntil': validUntil.millisecondsSinceEpoch,
        'quietStart': prefs.quietStart,
        'quietEnd': prefs.quietEnd,
        'timeZone': prefs.timeZone,
        'route':
            '/${followUp ? '24' : '18'}?taskId=${Uri.encodeQueryComponent(task.id)}',
      });
    }

    if (task.reminderMinutes >= 0) {
      add(
        entry.start.subtract(Duration(minutes: task.reminderMinutes)),
        followUp: false,
      );
    }
    if (prefs.followUp) {
      add(entry.end.add(const Duration(minutes: 5)), followUp: true);
    }
  }
  requests.sort((a, b) => (a['fireAt'] as int).compareTo(b['fireAt'] as int));
  return ReminderRequests(requests, skipped);
}

bool isQuietMinute(int minute, int start, int end) => start == end
    ? false
    : start < end
    ? minute >= start && minute < end
    : minute >= start || minute < end;
