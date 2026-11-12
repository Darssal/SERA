import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/domain/prompt_date.dart';

void main() {
  group('explicit date hints', () {
    for (final day in [DateTime(2026, 10, 28), DateTime(2026, 10, 31)]) {
      test('next Friday from $day uses the next natural week', () {
        final hint = parsePromptDate('下周五要做方案评审，帮我安排准备时间', day);
        expect(hint.deadline, DateTime(2026, 11, 6, 15));
        expect(hint.recognized, isTrue);
        expect(hint.explanation, contains('周一'));
      });
    }

    test('relative days keep the default 15:00 and cross year correctly', () {
      final today = DateTime(2026, 12, 31, 23, 50);
      expect(
        parsePromptDate('今天完成', today).deadline,
        DateTime(2026, 12, 31, 15),
      );
      expect(parsePromptDate('明天提交', today).deadline, DateTime(2027, 1, 1, 15));
      expect(parsePromptDate('后天复盘', today).deadline, DateTime(2027, 1, 2, 15));
    });

    test(
      'this week stays literal while bare weekday chooses the next occurrence',
      () {
        final saturday = DateTime(2026, 10, 31);
        expect(
          parsePromptDate('本周五交付', saturday).deadline,
          DateTime(2026, 10, 30, 15),
        );
        expect(
          parsePromptDate('周五交付', saturday).deadline,
          DateTime(2026, 11, 6, 15),
        );
        expect(
          parsePromptDate('周六完成', saturday).deadline,
          DateTime(2026, 10, 31, 15),
        );
        expect(
          parsePromptDate('本周日复盘', DateTime(2026, 12, 30)).deadline,
          DateTime(2027, 1, 3, 15),
        );
        expect(
          parsePromptDate('下周五提交', DateTime(2026, 12, 30)).deadline,
          DateTime(2027, 1, 8, 15),
        );
      },
    );

    test(
      'explicit dates precede incidental relative words and retain the year',
      () {
        final today = DateTime(2026, 10, 31);
        expect(
          parsePromptDate('今天开始，2026-11-06提交', today).deadline,
          DateTime(2026, 11, 6, 15),
        );
        expect(
          parsePromptDate('2027年3月2日演示', today).deadline,
          DateTime(2027, 3, 2, 15),
        );
        expect(
          parsePromptDate('2024-02-29有历史记录', today).deadline,
          DateTime(2024, 2, 29, 15),
        );
      },
    );

    test(
      'yearless month and day move to next year only after the date has passed',
      () {
        final today = DateTime(2026, 12, 30);
        expect(
          parsePromptDate('1月2日提交', today).deadline,
          DateTime(2027, 1, 2, 15),
        );
        expect(
          parsePromptDate('12月30日提交', today).deadline,
          DateTime(2026, 12, 30, 15),
        );
        expect(
          parsePromptDate('12月31日提交', today).deadline,
          DateTime(2026, 12, 31, 15),
        );
      },
    );

    test('invalid dates fall back without DateTime normalization or hidden reinterpretation', () {
      final today = DateTime(2026, 10, 31);
      for (final prompt in [
        '2026-02-29提交',
        '2026-13-04提交',
        '2026-04-31提交，明天准备',
        '2月30日提交',
      ]) {
        final hint = parsePromptDate(prompt, today);
        expect(hint.deadline, DateTime(2026, 11, 7, 15));
        expect(hint.recognized, isFalse);
        expect(hint.explanation, contains('无效'));
        expect(hint.explanation, contains('待确认'));
      }
    });

    test(
      'unrecognized text has an explicitly unconfirmed seven-day fallback',
      () {
        final hint = parsePromptDate('有空时整理课程笔记', DateTime(2026, 12, 28));
        expect(hint.deadline, DateTime(2027, 1, 4, 15));
        expect(hint.recognized, isFalse);
        expect(hint.explanation, contains('待确认'));
      },
    );
  });
}
