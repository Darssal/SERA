/// An explicit date hint for the user's confirmation, not a general natural
/// language parser. All dates use the device's local calendar and default 15:00.
class PromptDateHint {
  const PromptDateHint({
    required this.deadline,
    required this.recognized,
    required this.explanation,
  });
  final DateTime deadline;
  final bool recognized;
  final String explanation;
}

PromptDateHint parsePromptDate(String prompt, DateTime today) {
  final base = DateTime(today.year, today.month, today.day);
  PromptDateHint fallback([bool invalid = false]) => PromptDateHint(
    deadline: DateTime(base.year, base.month, base.day + 7, 15),
    recognized: false,
    explanation: invalid
        ? '输入中的日期无效；暂以 7 天后 15:00 作为待确认时间，请手动修改。'
        : '未识别到明确日期；暂以 7 天后 15:00 作为待确认时间，请手动确认。',
  );
  PromptDateHint identified(DateTime date, String matched, String rule) =>
      PromptDateHint(
        deadline: DateTime(date.year, date.month, date.day, 15),
        recognized: true,
        explanation: '根据「$matched」$rule，默认 15:00；可手动修改。',
      );
  DateTime? exact(int year, int month, int day) {
    if (year < 1 ||
        year > 9999 ||
        month < 1 ||
        month > 12 ||
        day < 1 ||
        day > 31) {
      return null;
    }
    final date = DateTime(year, month, day);
    return date.year == year && date.month == month && date.day == day
        ? date
        : null;
  }

  // An invalid explicit date must not normalize into the following month or
  // silently turn another word in the same prompt into a replacement deadline.
  final iso = RegExp(r'(?:^|[^0-9])(\d{4})-(\d{1,2})-(\d{1,2})(?!\d)')
      .firstMatch(prompt);
  if (iso != null) {
    final year = int.parse(iso.group(1)!);
    final month = int.parse(iso.group(2)!);
    final day = int.parse(iso.group(3)!);
    final date = exact(year, month, day);
    return date == null
        ? fallback(true)
        : identified(date, '$year-$month-$day', '识别为指定日期');
  }

  final monthDay = RegExp(r'(?:(\d{4})年)?(\d{1,2})月(\d{1,2})(?:日|号)?')
      .firstMatch(prompt);
  if (monthDay != null) {
    final explicitYear = monthDay.group(1);
    final month = int.parse(monthDay.group(2)!);
    final day = int.parse(monthDay.group(3)!);
    var year = explicitYear == null ? base.year : int.parse(explicitYear);
    // For a yearless month/day that has passed, infer the next calendar year.
    if (explicitYear == null &&
        (month < base.month || month == base.month && day < base.day)) {
      year++;
    }
    final date = exact(year, month, day);
    return date == null
        ? fallback(true)
        : identified(
            date,
            monthDay.group(0)!,
            explicitYear == null ? '按最近未过去的日期识别' : '识别为指定日期',
          );
  }

  final week = RegExp(r'(下周|下星期|本周|本星期|这周|这星期|星期|周)([一二三四五六日天1-7])')
      .firstMatch(prompt);
  if (week != null) {
    const weekdays = {
      '一': 1,
      '二': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '日': 7,
      '天': 7,
      '1': 1,
      '2': 2,
      '3': 3,
      '4': 4,
      '5': 5,
      '6': 6,
      '7': 7,
    };
    final targetWeekday = weekdays[week.group(2)!]!;
    final prefix = week.group(1)!;
    final int offset;
    final String rule;
    if (prefix.startsWith('下')) {
      offset = 7 - base.weekday + targetWeekday;
      rule = '按下一个自然周识别（周一为每周起点）';
    } else if (prefix.startsWith('本') || prefix.startsWith('这')) {
      offset = targetWeekday - base.weekday;
      rule = '按本自然周识别（周一为每周起点）';
    } else {
      offset = (targetWeekday - base.weekday + 7) % 7;
      rule = '按最近一次该星期识别（含今天）';
    }
    return identified(
      DateTime(base.year, base.month, base.day + offset),
      week.group(0)!,
      rule,
    );
  }

  for (final relative in const [('后天', 2), ('明天', 1), ('今天', 0)]) {
    if (prompt.contains(relative.$1)) {
      return identified(
        DateTime(base.year, base.month, base.day + relative.$2),
        relative.$1,
        '识别日期',
      );
    }
  }
  return fallback();
}
