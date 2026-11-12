part of 'models.dart';

bool _zonesInitialized = false;
tz.Location userLocation(String name) {
  // UTC is a built-in Location; timezone's generated IANA database does not
  // consistently include the "UTC" alias on every platform.
  if (name == 'UTC') return tz.UTC;
  if (!_zonesInitialized) {
    tzdata.initializeTimeZones();
    _zonesInitialized = true;
  }
  return tz.getLocation(name);
}

DateTime inTimeZone(DateTime value, String zone, {bool wallClock = false}) {
  final location = userLocation(zone);
  if (wallClock && value is! tz.TZDateTime && !value.isUtc) {
    return tz.TZDateTime(
      location,
      value.year,
      value.month,
      value.day,
      value.hour,
      value.minute,
      value.second,
      value.millisecond,
      value.microsecond,
    );
  }
  return tz.TZDateTime.from(value, location);
}

DateTime? readZoned(Object? value, String zone) {
  if (value == null) return null;
  final parsed = DateTime.tryParse('$value');
  return parsed == null
      ? null
      : inTimeZone(parsed, zone, wallClock: !parsed.isUtc);
}

DateTime calendarDay(DateTime value, int offset) => value is tz.TZDateTime
    ? tz.TZDateTime(value.location, value.year, value.month, value.day + offset)
    : DateTime(value.year, value.month, value.day + offset);
DateTime atMinute(DateTime day, int minute) => day is tz.TZDateTime
    ? tz.TZDateTime(
        day.location,
        day.year,
        day.month,
        day.day,
        minute ~/ 60,
        minute % 60,
      )
    : DateTime(day.year, day.month, day.day, minute ~/ 60, minute % 60);
