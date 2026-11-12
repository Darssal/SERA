import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/models.dart';
import 'platform_services_types.dart';

String _escape(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll('\n', r'\n')
    .replaceAll(',', r'\,')
    .replaceAll(';', r'\;');
String _unescape(String value) => value.replaceAllMapped(
  RegExp(r'\\([nN,;\\])'),
  (m) => m[1]!.toLowerCase() == 'n' ? '\n' : m[1]!,
);
String _utc(DateTime value) {
  final d = value.toUtc();
  String n(int x) => x.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}${n(d.month)}${n(d.day)}T${n(d.hour)}${n(d.minute)}${n(d.second)}Z';
}

String _date(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}${value.month.toString().padLeft(2, '0')}${value.day.toString().padLeft(2, '0')}';

String _fold(String value) {
  final lines = <String>[];
  var current = StringBuffer();
  var bytes = 0;
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    final count = utf8.encode(char).length;
    if (bytes + count > 75) {
      lines.add(current.toString());
      current = StringBuffer(' ');
      bytes = 1;
    }
    current.write(char);
    bytes += count;
  }
  lines.add(current.toString());
  return lines.join('\r\n');
}

/// RFC 5545 text export: escaped UTF-8, folded at 75 octets, absolute UTC times.
String exportIcs(List<CalendarEntry> entries) {
  final lines = <String>[
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//SERA//Calendar 1.0//ZH',
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
  ];
  final stamp = _utc(DateTime.now());
  for (final e in entries) {
    if (!e.end.isAfter(e.start)) {
      throw const PlatformCapabilityException(
        'invalid_event',
        '不能导出结束时间早于开始的日程。',
      );
    }
    lines.addAll([
      'BEGIN:VEVENT',
      'UID:${_escape(e.id)}@sera.local',
      'DTSTAMP:$stamp',
      e.allDay
          ? 'DTSTART;VALUE=DATE:${_date(e.start)}'
          : 'DTSTART:${_utc(e.start)}',
      e.allDay ? 'DTEND;VALUE=DATE:${_date(e.end)}' : 'DTEND:${_utc(e.end)}',
      'SUMMARY:${_escape(e.title)}',
      'DESCRIPTION:${_escape(e.notes)}',
      'LOCATION:${_escape(e.place)}',
      'END:VEVENT',
    ]);
  }
  lines.add('END:VCALENDAR');
  return '${lines.map(_fold).join('\r\n')}\r\n';
}

class _IcsProperty {
  const _IcsProperty(this.params, this.value);
  final Map<String, String> params;
  final String value;
}

class _Stamp {
  const _Stamp(this.wall, this.offset, this.allDay);
  final DateTime wall;
  final int? offset;
  final bool allDay;
  DateTime resolve([DateTime? occurrence, String? floatingTimeZone]) {
    final w = occurrence ?? wall;
    if (offset == null && floatingTimeZone != null) {
      return inTimeZone(
        DateTime(w.year, w.month, w.day, w.hour, w.minute, w.second),
        floatingTimeZone,
        wallClock: true,
      );
    }
    return offset == null
        ? DateTime(w.year, w.month, w.day, w.hour, w.minute, w.second)
        : w.subtract(Duration(minutes: offset!)).toLocal();
  }
}

DateTime _validDate(
  int year,
  int month,
  int day, [
  int hour = 0,
  int minute = 0,
  int second = 0,
]) {
  final d = DateTime.utc(year, month, day, hour, minute, second);
  if (year < 1900 ||
      year > 2200 ||
      d.year != year ||
      d.month != month ||
      d.day != day ||
      d.hour != hour ||
      d.minute != minute ||
      d.second != second) {
    throw const PlatformCapabilityException(
      'invalid_ics_date',
      'ICS 包含无效日期或时间。',
    );
  }
  return d;
}

_Stamp _parseStamp(_IcsProperty p) {
  final raw = p.value.trim();
  final match = RegExp(
    r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$',
  ).firstMatch(raw);
  if (match == null) {
    throw const PlatformCapabilityException(
      'invalid_ics_date',
      'ICS 日期格式不受支持，请使用标准 DTSTART/DTEND。',
    );
  }
  int n(int i) => int.parse(match[i] ?? '0');
  final wall = _validDate(n(1), n(2), n(3), n(4), n(5), n(6));
  int? offset = match[7] == 'Z' ? 0 : null;
  final zone = p.params['TZID']?.replaceAll('"', '');
  if (zone != null && match[7] != 'Z') {
    const zones = {
      'UTC': 0,
      'Etc/UTC': 0,
      'GMT': 0,
      'Asia/Hong_Kong': 480,
      'Asia/Shanghai': 480,
      'Asia/Taipei': 480,
      'Asia/Singapore': 480,
      'Asia/Tokyo': 540,
      'Asia/Seoul': 540,
      'Etc/GMT-8': 480,
    };
    if (!zones.containsKey(zone)) {
      throw PlatformCapabilityException(
        'unsupported_timezone',
        'ICS 时区 $zone 暂不支持。请在来源日历中导出 UTC 日期，避免误读夏令时。',
      );
    }
    offset = zones[zone];
  }
  return _Stamp(wall, offset, match[4] == null || p.params['VALUE'] == 'DATE');
}

String _hash(String value) => sha256.convert(utf8.encode(value)).toString();
Duration _duration(String text) {
  final m = RegExp(
    r'^P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$',
  ).firstMatch(text);
  if (m == null) {
    throw const PlatformCapabilityException(
      'invalid_ics_duration',
      'ICS DURATION 格式无效。',
    );
  }
  int n(int i) => int.parse(m[i] ?? '0');
  return Duration(
    days: n(1) * 7 + n(2),
    hours: n(3),
    minutes: n(4),
    seconds: n(5),
  );
}

/// Imports standard events and bounded DAILY/WEEKLY/MONTHLY recurrences.
/// Unsupported timezone/recurrence rules are rejected before any persistence.
List<CalendarEntry> parseIcs(
  String content, {
  DateTime? rangeStart,
  DateTime? rangeEnd,
  String? timeZone,
}) {
  if (utf8.encode(content).length > 4 * 1024 * 1024) {
    throw const PlatformCapabilityException(
      'file_too_large',
      'ICS 文件不能超过 4 MiB。',
    );
  }
  final unfolded = content
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp(r'\n[ \t]'), '');
  if (!unfolded.contains('BEGIN:VCALENDAR') ||
      !unfolded.contains('END:VCALENDAR')) {
    throw const PlatformCapabilityException(
      'invalid_ics',
      '文件不是有效的 iCalendar (.ics)。',
    );
  }
  final events = <Map<String, List<_IcsProperty>>>[];
  Map<String, List<_IcsProperty>>? current;
  var nested = 0;
  for (final raw in unfolded.split('\n')) {
    final line = raw.trimRight();
    if (line == 'BEGIN:VEVENT') {
      if (current != null) {
        throw const PlatformCapabilityException('invalid_ics', 'ICS 事件嵌套无效。');
      }
      current = {};
      nested = 0;
      continue;
    }
    if (line == 'END:VEVENT') {
      if (current != null) events.add(current);
      current = null;
      continue;
    }
    if (current == null) continue;
    if (line.startsWith('BEGIN:')) {
      nested++;
      continue;
    }
    if (line.startsWith('END:')) {
      nested--;
      continue;
    }
    if (nested > 0) continue;
    final colon = line.indexOf(':');
    if (colon < 1) continue;
    final header = line.substring(0, colon).split(';');
    final params = <String, String>{};
    for (final param in header.skip(1)) {
      final eq = param.indexOf('=');
      if (eq > 0) {
        params[param.substring(0, eq).toUpperCase()] = param.substring(eq + 1);
      }
    }
    current
        .putIfAbsent(header.first.toUpperCase(), () => [])
        .add(_IcsProperty(params, line.substring(colon + 1)));
  }
  if (current != null) {
    throw const PlatformCapabilityException(
      'invalid_ics',
      'ICS 事件缺少 END:VEVENT。',
    );
  }
  final output = <String, CalendarEntry>{};
  final lower = rangeStart ?? DateTime.now().subtract(const Duration(days: 30));
  final upper = rangeEnd ?? DateTime.now().add(const Duration(days: 366));
  for (var index = 0; index < events.length; index++) {
    final values = events[index];
    _IcsProperty? first(String key) => values[key]?.firstOrNull;
    if (first('STATUS')?.value == 'CANCELLED' ||
        first('TRANSP')?.value == 'TRANSPARENT') {
      continue;
    }
    final initial = first('DTSTART');
    if (initial == null) {
      throw const PlatformCapabilityException(
        'invalid_ics',
        'ICS 事件缺少 DTSTART。',
      );
    }
    final stamp = _parseStamp(initial);
    final start = stamp.resolve(null, timeZone);
    final endProp = first('DTEND');
    if (endProp != null && _parseStamp(endProp).allDay != stamp.allDay) {
      throw const PlatformCapabilityException(
        'invalid_ics',
        'DTSTART 与 DTEND 必须使用相同的日期或时间类型。',
      );
    }
    final duration = endProp != null
        ? _parseStamp(endProp).resolve(null, timeZone).difference(start)
        : first('DURATION') != null
        ? _duration(first('DURATION')!.value)
        : Duration(days: stamp.allDay ? 1 : 0, hours: stamp.allDay ? 0 : 1);
    if (duration <= Duration.zero) {
      throw const PlatformCapabilityException('invalid_ics', 'ICS 事件结束必须晚于开始。');
    }
    final allDayDays = stamp.allDay
        ? endProp != null
              ? _parseStamp(endProp).wall.difference(stamp.wall).inDays
              : first('DURATION') != null
              ? _duration(first('DURATION')!.value).inDays
              : 1
        : 0;
    if (stamp.allDay && allDayDays < 1) {
      throw const PlatformCapabilityException(
        'invalid_ics',
        '全天日程必须至少持续一个完整日期。',
      );
    }
    final title = _unescape(first('SUMMARY')?.value ?? '导入的日程');
    final uid = first('UID')?.value ?? '$title:${initial.value}:$index';
    final excluded = <int>{};
    for (final p in values['EXDATE'] ?? <_IcsProperty>[]) {
      for (final item in p.value.split(',')) {
        excluded.add(
          _parseStamp(_IcsProperty(p.params, item))
              .resolve(null, timeZone)
              .millisecondsSinceEpoch,
        );
      }
    }
    final occurrences = <DateTime>[start];
    final ruleProp = first('RRULE');
    if (ruleProp != null) {
      final rule = <String, String>{};
      for (final field in ruleProp.value.split(';')) {
        final eq = field.indexOf('=');
        if (eq > 0) rule[field.substring(0, eq)] = field.substring(eq + 1);
      }
      const allowed = {
        'FREQ',
        'INTERVAL',
        'COUNT',
        'UNTIL',
        'BYDAY',
        'BYMONTHDAY',
        'WKST',
      };
      if (rule.keys.any((k) => !allowed.contains(k)) ||
          !{'DAILY', 'WEEKLY', 'MONTHLY'}.contains(rule['FREQ']) ||
          (rule['WKST'] != null && rule['WKST'] != 'MO')) {
        throw const PlatformCapabilityException(
          'unsupported_recurrence',
          'ICS 包含不支持的重复规则。支持每日/每周/每月、次数、截止与排除日期；复杂规则请从设备日历读取。',
        );
      }
      final interval = int.tryParse(rule['INTERVAL'] ?? '1') ?? 0;
      final count = int.tryParse(rule['COUNT'] ?? '10000') ?? 0;
      if (interval < 1 || count < 1) {
        throw const PlatformCapabilityException(
          'invalid_ics',
          'ICS 重复间隔或次数无效。',
        );
      }
      final weekdays = <int>[];
      const dayMap = {
        'MO': 1,
        'TU': 2,
        'WE': 3,
        'TH': 4,
        'FR': 5,
        'SA': 6,
        'SU': 7,
      };
      for (final day
          in (rule['BYDAY'] ?? '').split(',').where((d) => d.isNotEmpty)) {
        if (!dayMap.containsKey(day)) {
          throw const PlatformCapabilityException(
            'unsupported_recurrence',
            '暂不支持包含序号的 BYDAY 规则（如 -1MO），请导出展开后的事件。',
          );
        }
        weekdays.add(dayMap[day]!);
      }
      final monthDays = (rule['BYMONTHDAY'] ?? '')
          .split(',')
          .where((v) => v.isNotEmpty)
          .map((value) {
            final parsed = int.tryParse(value);
            if (parsed == null) {
              throw const PlatformCapabilityException(
                'invalid_ics',
                'BYMONTHDAY 必须为整数。',
              );
            }
            return parsed;
          })
          .toList();
      if (monthDays.any((d) => d < 1 || d > 31)) {
        throw const PlatformCapabilityException(
          'unsupported_recurrence',
          '暂不支持负数 BYMONTHDAY 规则。',
        );
      }
      final until = rule['UNTIL'] == null
          ? null
          : _parseStamp(_IcsProperty(initial.params, rule['UNTIL']!))
                .resolve(null, timeZone);
      occurrences.clear();
      var matched = 0;
      final initialWeek = stamp.wall.subtract(
        Duration(days: stamp.wall.weekday - 1),
      );
      // Hard bound prevents malicious files from expanding unbounded histories.
      for (var delta = 0; delta <= 36525; delta++) {
        final wall = stamp.wall.add(Duration(days: delta));
        final instant = stamp.resolve(wall, timeZone);
        if (instant.isAfter(upper) ||
            (until != null && instant.isAfter(until)) ||
            matched >= count) {
          break;
        }
        final freq = rule['FREQ'];
        var matches = false;
        if (freq == 'DAILY') matches = delta % interval == 0;
        if (freq == 'WEEKLY') {
          matches =
              (wall.difference(initialWeek).inDays ~/ 7) % interval == 0 &&
              (weekdays.isEmpty
                  ? wall.weekday == stamp.wall.weekday
                  : weekdays.contains(wall.weekday));
        }
        if (freq == 'MONTHLY') {
          matches =
              ((wall.year - stamp.wall.year) * 12 +
                          wall.month -
                          stamp.wall.month) %
                      interval ==
                  0 &&
              (monthDays.isNotEmpty
                  ? monthDays.contains(wall.day)
                  : weekdays.isNotEmpty
                  ? weekdays.contains(wall.weekday)
                  : wall.day == stamp.wall.day);
        }
        if (monthDays.isNotEmpty && freq != 'MONTHLY') {
          matches = matches && monthDays.contains(wall.day);
        }
        if (weekdays.isNotEmpty && freq != 'WEEKLY') {
          matches = matches && weekdays.contains(wall.weekday);
        }
        if (matches) {
          matched++;
          if (!instant.isBefore(lower)) occurrences.add(instant);
        }
        if (occurrences.length > 1500) {
          throw const PlatformCapabilityException(
            'too_many_events',
            'ICS 展开后超过 1500 项，请缩小日期范围。',
          );
        }
      }
    }
    for (final p in values['RDATE'] ?? <_IcsProperty>[]) {
      for (final item in p.value.split(',')) {
        occurrences.add(
          _parseStamp(_IcsProperty(p.params, item)).resolve(null, timeZone),
        );
      }
    }
    for (final occurrence in occurrences) {
      if (excluded.contains(occurrence.millisecondsSinceEpoch)) continue;
      final id = 'ics-${_hash(uid)}-${occurrence.millisecondsSinceEpoch}';
      output[id] = CalendarEntry(
        id: id,
        title: title,
        start: occurrence,
        end: stamp.allDay
            ? calendarDay(occurrence, allDayDays)
            : occurrence.add(duration),
        place: _unescape(first('LOCATION')?.value ?? ''),
        notes: _unescape(first('DESCRIPTION')?.value ?? ''),
        locked: true,
        allDay: stamp.allDay,
        source: 'ics-import',
        externalId: uid,
        timeZone: initial.params['TZID'] ?? timeZone ?? 'Asia/Hong_Kong',
      );
      if (output.length > 1500) {
        throw const PlatformCapabilityException(
          'too_many_events',
          'ICS 超过 1500 项，请缩小导出范围。',
        );
      }
    }
  }
  return output.values.toList()..sort((a, b) => a.start.compareTo(b.start));
}
