import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/domain/models.dart';

void main() {
  test(
    'UTC preference works before the IANA database has been initialized',
    () {
      final instant = DateTime.utc(2026, 11, 1, 5, 30);
      final displayed = inTimeZone(instant, 'UTC');
      expect(displayed.millisecondsSinceEpoch, instant.millisecondsSinceEpoch);
      expect(displayed.hour, 5);
      expect(displayed.timeZoneOffset, Duration.zero);
      expect(calendarDay(displayed, 1).day, 2);
      // The UTC fast path must not skip later initialization of a named zone.
      expect(inTimeZone(instant, 'Asia/Hong_Kong').hour, 13);
    },
  );
}
