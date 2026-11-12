import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/platform/icalendar.dart';
import 'package:sera_flutter/platform/platform_services_types.dart';
import 'package:sera_flutter/platform/reminder_requests.dart';

String calendar(String fields) =>
    'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:course-event\r\n$fields\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n';

void main() {
  group('ICS exchange', () {
    test('UTF-8 folding, escapes, location and UTC survive round trip', () {
      final title = List.filled(20, '课程项目展示，交流;').join();
      final original = CalendarEntry(
        id: 'event-1',
        title: title,
        start: DateTime.utc(2026, 11, 1, 1),
        end: DateTime.utc(2026, 11, 1, 2),
        notes: '第一行\n第二行 \\ 资料',
        place: '教室 A, B; C',
      );
      final text = exportIcs([original]);
      expect(
        text.split('\r\n').every((line) => utf8.encode(line).length <= 75),
        isTrue,
      );
      final result = parseIcs(text).single;
      expect(result.title, title);
      expect(result.notes, original.notes);
      expect(result.place, original.place);
      expect(result.start.toUtc(), original.start);
      expect(result.end.toUtc(), original.end);
      expect(result.locked, isTrue);
    });
    test('explicit Hong Kong timezone preserves the intended instant', () {
      final event = parseIcs(
        calendar(
          'DTSTART;TZID=Asia/Hong_Kong:20261101T090000\r\nDTEND;TZID=Asia/Hong_Kong:20261101T100000',
        ),
      ).single;
      expect(event.start.toUtc(), DateTime.utc(2026, 11, 1, 1));
    });
    test('floating local and all-day values stay local calendar dates', () {
      final event = parseIcs(
        calendar('DTSTART;VALUE=DATE:20261101\r\nDTEND;VALUE=DATE:20261102'),
      ).single;
      expect(event.start, DateTime(2026, 11, 1));
      expect(event.end, DateTime(2026, 11, 2));
      expect(event.allDay, isTrue);
      expect(event.source, 'ics-import');
    });
    test(
      'all-day export stays DATE-valued and preserves IANA dates over DST',
      () {
        final events = parseIcs(
          calendar(
            'DTSTART;VALUE=DATE:20260308\r\nDTEND;VALUE=DATE:20260309\r\nRRULE:FREQ=DAILY;COUNT=2',
          ),
          timeZone: 'America/Los_Angeles',
          rangeStart: DateTime.utc(2026, 3, 1),
          rangeEnd: DateTime.utc(2026, 3, 15),
        );
        expect(events, hasLength(2));
        expect(events.first.end.difference(events.first.start).inHours, 23);
        expect(events.last.end.difference(events.last.start).inHours, 24);
        expect(
          events.every((e) => e.start.hour == 0 && e.end.hour == 0 && e.allDay),
          isTrue,
        );
        final text = exportIcs(events);
        expect(text, contains('DTSTART;VALUE=DATE:20260308'));
        expect(text, contains('DTEND;VALUE=DATE:20260310'));
        final imported = parseIcs(text, timeZone: 'America/Los_Angeles');
        expect(
          imported.map((e) => e.start.toUtc()),
          events.map((e) => e.start.toUtc()),
        );
      },
    );
    test('floating input honors the explicit account timezone', () {
      final event = parseIcs(
        calendar('DTSTART:20261102T090000\r\nDURATION:PT1H'),
        timeZone: 'America/Los_Angeles',
      ).single;
      expect(event.start.toUtc(), DateTime.utc(2026, 11, 2, 17));
      expect(event.timeZone, 'America/Los_Angeles');
    });
    test(
      'weekly count, exceptions and additional dates expand without duplicates',
      () {
        final events = parseIcs(
          calendar(
            'DTSTART:20261102T010000Z\r\nDTEND:20261102T020000Z\r\nRRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=4\r\nEXDATE:20261104T010000Z\r\nRDATE:20261109T010000Z,20261113T010000Z',
          ),
          rangeStart: DateTime.utc(2026, 11, 1),
          rangeEnd: DateTime.utc(2026, 12, 1),
        );
        expect(events.map((e) => e.start.toUtc().day).toList(), [2, 9, 11, 13]);
      },
    );
    test('monthly BYDAY means each matching weekday in selected months', () {
      final events = parseIcs(
        calendar(
          'DTSTART:20261102T010000Z\r\nDURATION:PT30M\r\nRRULE:FREQ=MONTHLY;BYDAY=MO;COUNT=4',
        ),
        rangeStart: DateTime.utc(2026, 11, 1),
        rangeEnd: DateTime.utc(2027, 1, 1),
      );
      expect(events.map((e) => e.start.toUtc().day).toList(), [2, 9, 16, 23]);
      expect(events.every((e) => e.minutes == 30), isTrue);
    });
    test('daily recurrence applies BYMONTHDAY filter', () {
      final events = parseIcs(
        calendar(
          'DTSTART:20261101T010000Z\r\nDURATION:PT1H\r\nRRULE:FREQ=DAILY;BYMONTHDAY=2,3;COUNT=3',
        ),
        rangeStart: DateTime.utc(2026, 11, 1),
        rangeEnd: DateTime.utc(2027, 1, 1),
      );
      expect(
        events
            .map((e) => '${e.start.toUtc().month}/${e.start.toUtc().day}')
            .toList(),
        ['11/2', '11/3', '12/2'],
      );
    });
    test('cancelled and transparent events do not block scheduling', () {
      expect(
        parseIcs(
          calendar(
            'DTSTART:20261101T010000Z\r\nDTEND:20261101T020000Z\r\nSTATUS:CANCELLED',
          ),
        ),
        isEmpty,
      );
      expect(
        parseIcs(
          calendar(
            'DTSTART:20261101T010000Z\r\nDTEND:20261101T020000Z\r\nTRANSP:TRANSPARENT',
          ),
        ),
        isEmpty,
      );
    });
    test('VALARM descriptions do not replace event description', () {
      final event = parseIcs(
        calendar(
          'DTSTART:20261101T010000Z\r\nDESCRIPTION:课程准备\r\nBEGIN:VALARM\r\nDESCRIPTION:提醒\r\nEND:VALARM',
        ),
      ).single;
      expect(event.notes, '课程准备');
    });
    test(
      'UID-based IDs are stable across repeated imports and 64-hex SHA256',
      () {
        final text = calendar(
          'DTSTART:20261101T010000Z\r\nDTEND:20261101T020000Z',
        );
        final id = parseIcs(text).single.id;
        expect(parseIcs(text).single.id, id);
        expect(RegExp(r'^ics-[a-f0-9]{64}-\d+$').hasMatch(id), isTrue);
      },
    );
    test('unsupported DST timezone fails explicitly before persistence', () {
      expect(
        () =>
            parseIcs(calendar('DTSTART;TZID=America/New_York:20261101T090000')),
        throwsA(
          isA<PlatformCapabilityException>().having(
            (e) => e.code,
            'code',
            'unsupported_timezone',
          ),
        ),
      );
    });
    test('ordinal weekdays reject explicitly instead of changing meaning', () {
      expect(
        () => parseIcs(
          calendar('DTSTART:20261101T010000Z\r\nRRULE:FREQ=MONTHLY;BYDAY=-1MO'),
        ),
        throwsA(
          isA<PlatformCapabilityException>().having(
            (e) => e.code,
            'code',
            'unsupported_recurrence',
          ),
        ),
      );
    });
    test('invalid dates, malformed calendar and invalid duration reject', () {
      for (final fields in [
        'DTSTART:20260230T090000Z',
        'DTSTART:20261101T250000Z',
        'DTSTART:20261101T010000Z\r\nDTEND:20261031T010000Z',
      ]) {
        expect(
          () => parseIcs(calendar(fields)),
          throwsA(isA<PlatformCapabilityException>()),
        );
      }
      expect(
        () => parseIcs('BEGIN:VCALENDAR'),
        throwsA(isA<PlatformCapabilityException>()),
      );
      expect(
        () => parseIcs(calendar('DTSTART:20261101T010000Z\r\nDURATION:Pbad')),
        throwsA(isA<PlatformCapabilityException>()),
      );
    });
    test('file and expansion limits reject oversized input', () {
      expect(
        () => parseIcs(
          'BEGIN:VCALENDAR${List.filled(4 * 1024 * 1024, 'x').join()}',
        ),
        throwsA(
          isA<PlatformCapabilityException>().having(
            (e) => e.code,
            'code',
            'file_too_large',
          ),
        ),
      );
    });
  });

  group('real reminder requests', () {
    final clock = DateTime(2026, 11, 2, 7);
    Workspace sample({
      SeraPreferences prefs = const SeraPreferences(),
      bool done = false,
      int reminder = 10,
      DateTime? start,
    }) {
      final at = start ?? DateTime(2026, 11, 2, 14);
      return Workspace(
        revision: 9,
        preferences: prefs,
        tasks: [
          SeraTask(
            id: 'task-1',
            title: '课程准备',
            done: done,
            reminderMinutes: reminder,
          ),
        ],
        entries: [
          CalendarEntry(
            id: 'entry-1',
            taskId: 'task-1',
            title: '课程准备',
            start: at,
            end: at.add(const Duration(minutes: 45)),
          ),
        ],
      );
    }

    test('start and follow-up use distinct IDs and correct routes', () {
      final requests = buildReminderRequests(sample(), now: clock).requests;
      expect(requests, hasLength(2));
      expect(requests.first['id'], 'entry-1:start');
      expect(requests.last['id'], 'entry-1:followup');
      expect(requests.first['route'], '/18?taskId=task-1');
      expect(requests.last['route'], '/24?taskId=task-1');
      expect(requests.every((e) => e['generation'] == 9), isTrue);
    });
    test('follow-up switch actually removes the follow-up request', () {
      expect(
        buildReminderRequests(
          sample(prefs: const SeraPreferences(followUp: false)),
          now: clock,
        ).requests,
        hasLength(1),
      );
    });
    test('split task blocks keep four independent reminder IDs', () {
      final base = sample();
      final other = CalendarEntry(
        id: 'entry-2',
        taskId: base.tasks.single.id,
        title: base.tasks.single.title,
        start: DateTime(2026, 11, 2, 16),
        end: DateTime(2026, 11, 2, 16, 30),
      );
      final requests = buildReminderRequests(
        base.copyWith(entries: [...base.entries, other]),
        now: clock,
      ).requests;
      expect(requests, hasLength(4));
      expect(requests.map((e) => e['id']).toSet(), hasLength(4));
    });
    test('canceled tasks never retain notifications', () {
      final base = sample();
      expect(
        buildReminderRequests(
          base.copyWith(
            tasks: [base.tasks.single.copyWith(status: 'canceled')],
          ),
          now: clock,
        ).requests,
        isEmpty,
      );
    });
    test('ack applies only to the same original scheduled instant', () {
      final base = sample();
      final original = base.entries.single.start.subtract(
        const Duration(minutes: 10),
      );
      final marked = base.copyWith(
        reminderStates: {
          'entry-1:start': {
            'status': 'ack',
            'scheduledAt': original.toUtc().toIso8601String(),
          },
        },
      );
      expect(
        buildReminderRequests(marked, now: clock).requests.single['kind'],
        'followup',
      );
      final moved = marked.copyWith(
        entries: [
          base.entries.single.copyWith(
            start: base.entries.single.start.add(const Duration(hours: 1)),
            end: base.entries.single.end.add(const Duration(hours: 1)),
          ),
        ],
      );
      expect(buildReminderRequests(moved, now: clock).requests, hasLength(2));
    });
    test('snooze retains a past original reminder until the explicit future instant', () {
      final base = sample();
      final original = base.entries.single.start.subtract(
        const Duration(minutes: 10),
      );
      final snoozeUntil = base.entries.single.start.add(
        const Duration(minutes: 2),
      );
      final marked = base.copyWith(
        reminderStates: {
          'entry-1:start': {
            'status': 'snoozed',
            'scheduledAt': original.toUtc().toIso8601String(),
            'at': original
                .add(const Duration(minutes: 1))
                .toUtc()
                .toIso8601String(),
            'snoozeUntil': snoozeUntil.toUtc().toIso8601String(),
          },
        },
      );
      final requests = buildReminderRequests(
        marked,
        now: original.add(const Duration(minutes: 1)),
      ).requests;
      expect(requests.first['fireAt'], snoozeUntil.millisecondsSinceEpoch);
      expect(requests.first['scheduledAt'], original.toUtc().toIso8601String());
      final tooLate = marked.copyWith(
        reminderStates: {
          'entry-1:start': {
            'status': 'snoozed',
            'scheduledAt': original.toUtc().toIso8601String(),
            'snoozeUntil': base.entries.single.end.toUtc().toIso8601String(),
          },
        },
      );
      expect(
        buildReminderRequests(tooLate, now: clock).requests.single['kind'],
        'followup',
      );
    });
    test('quiet hours use the account IANA zone rather than device zone', () {
      final at = DateTime.utc(2026, 11, 2, 16, 10);
      final workspace = Workspace(
        preferences: const SeraPreferences(
          timeZone: 'America/Los_Angeles',
          followUp: false,
        ),
        tasks: const [
          SeraTask(id: 'la-task', title: '洛杉矶任务', reminderMinutes: 30),
        ],
        entries: [
          CalendarEntry(
            id: 'la-entry',
            taskId: 'la-task',
            title: '洛杉矶任务',
            start: at,
            end: at.add(const Duration(minutes: 45)),
          ),
        ],
      );
      final request = buildReminderRequests(
        workspace,
        now: DateTime.utc(2026, 11, 2, 14),
      ).requests.single;
      expect(
        request['fireAt'],
        DateTime.utc(2026, 11, 2, 16).millisecondsSinceEpoch,
      );
      expect(
        request['scheduledAt'],
        DateTime.utc(2026, 11, 2, 15, 40).toIso8601String(),
      );
      expect(request['timeZone'], 'America/Los_Angeles');
    });
    test('global disabled and task completion cancel every request', () {
      expect(
        buildReminderRequests(
          sample(prefs: const SeraPreferences(notifications: false)),
          now: clock,
        ).requests,
        isEmpty,
      );
      expect(
        buildReminderRequests(sample(done: true), now: clock).requests,
        isEmpty,
      );
    });
    test(
      'per-task no start reminder still honors separately enabled follow-up',
      () {
        final requests = buildReminderRequests(
          sample(reminder: -1),
          now: clock,
        ).requests;
        expect(requests.single['kind'], 'followup');
      },
    );
    test('quiet time defers early morning notification until quiet end', () {
      final requests = buildReminderRequests(
        sample(start: DateTime(2026, 11, 2, 8)),
        now: clock,
      ).requests;
      expect(
        DateTime.fromMillisecondsSinceEpoch(requests.first['fireAt'] as int),
        DateTime(2026, 11, 2, 8),
      );
    });
    test(
      'reminder delayed beyond event end is skipped while follow-up may remain',
      () {
        final requests = buildReminderRequests(
          sample(start: DateTime(2026, 11, 2, 6)),
          now: DateTime(2026, 11, 2, 5),
        );
        expect(requests.skipped, 1);
        expect(requests.requests.single['kind'], 'followup');
        expect(
          DateTime.fromMillisecondsSinceEpoch(
            requests.requests.single['fireAt'] as int,
          ).hour,
          8,
        );
      },
    );
    test(
      'past requests and inbox tasks do not create phantom notifications',
      () {
        final result = buildReminderRequests(
          sample(),
          now: DateTime(2026, 11, 3),
        );
        expect(result.requests, isEmpty);
        expect(
          buildReminderRequests(
            const Workspace(
              tasks: [SeraTask(id: 'inbox', title: '待安排')],
            ),
            now: clock,
          ).requests,
          isEmpty,
        );
      },
    );
    test('quiet windows handle midnight and equal endpoints', () {
      expect(isQuietMinute(23 * 60, 1320, 480), isTrue);
      expect(isQuietMinute(7 * 60, 1320, 480), isTrue);
      expect(isQuietMinute(8 * 60, 1320, 480), isFalse);
      expect(isQuietMinute(12 * 60, 600, 840), isTrue);
      expect(isQuietMinute(12 * 60, 0, 0), isFalse);
    });
  });
}
