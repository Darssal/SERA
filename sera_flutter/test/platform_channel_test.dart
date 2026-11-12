import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/platform/platform_native.dart';
import 'package:sera_flutter/platform/platform_services_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NativePlatformServices service;
  final calls = <MethodCall>[];
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativePlatformServices.channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'requestPermission':
              return 'granted';
            case 'listCalendars':
              return [
                {
                  'id': '4',
                  'name': '课程日历',
                  'account': 'work',
                  'writable': true,
                  'isSera': false,
                },
              ];
            case 'syncCalendarEntries':
              return [
                {
                  'sourceId': 'entry-1',
                  'operation': 'update',
                  'success': false,
                  'error': '外部修改冲突',
                },
              ];
            case 'scheduleNotifications':
              return {
                'scheduled': 0,
                'skipped': 0,
                'exact': false,
                'errors': [],
              };
            default:
              return null;
          }
        });
    service = NativePlatformServices();
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativePlatformServices.channel, null);
  });
  test('scope changes pass only account ID and never credentials', () async {
    await service.setAccountScope('user-a');
    expect(calls.single.method, 'setAccountScope');
    expect(calls.single.arguments, {'userId': 'user-a'});
  });
  test('all-day busy JSON keeps UTC dates when mapped to a western zone', () {
    final start = DateTime.utc(2026, 11, 1);
    final end = DateTime.utc(2026, 11, 2);
    final json = <String, dynamic>{
      'id': 'external:4:2',
      'calendarId': '4',
      'title': '全天占用',
      'start': start.millisecondsSinceEpoch,
      'end': end.millisecondsSinceEpoch,
      'allDay': true,
    };
    final event = ExternalBusyEvent.fromJson(json);
    expect(event.start.isUtc, isFalse);
    expect(event.end.isUtc, isFalse);
    expect(event.start, DateTime(2026, 11, 1));
    expect(event.end, DateTime(2026, 11, 2));
    final westernStart = inTimeZone(
      event.start,
      'America/Los_Angeles',
      wallClock: true,
    );
    final westernEnd = inTimeZone(
      event.end,
      'America/Los_Angeles',
      wallClock: true,
    );
    expect(
      (westernStart.year, westernStart.month, westernStart.day),
      (2026, 11, 1),
    );
    expect((westernEnd.year, westernEnd.month, westernEnd.day), (2026, 11, 2));
    expect(westernStart.hour, 0);
    expect(westernEnd.hour, 0);
    expect(westernEnd.difference(westernStart), const Duration(hours: 25));

    final timed = ExternalBusyEvent.fromJson({...json, 'allDay': false});
    expect(timed.start.millisecondsSinceEpoch, start.millisecondsSinceEpoch);
    expect(timed.end.millisecondsSinceEpoch, end.millisecondsSinceEpoch);
  });
  test(
    'all-day calendar channel uses UTC midnight dates across a 25-hour DST day',
    () async {
      final day = inTimeZone(
        DateTime(2026, 11, 1),
        'America/Los_Angeles',
        wallClock: true,
      );
      await service.syncCalendarEntries([
        CalendarEntry(
          id: 'all-day',
          title: '全天',
          start: day,
          end: calendarDay(day, 1),
          allDay: true,
          timeZone: 'America/Los_Angeles',
        ),
      ]);
      final row =
          ((calls.single.arguments as Map)['entries'] as List).single as Map;
      expect(row['allDay'], isTrue);
      expect(row['timeZone'], 'UTC');
      expect(row['start'], DateTime.utc(2026, 11, 1).millisecondsSinceEpoch);
      expect(row['end'], DateTime.utc(2026, 11, 2).millisecondsSinceEpoch);
      expect(day.add(const Duration(days: 1)).hour, 23);
    },
  );
  test(
    'cancel during permission request cannot open an orphan microphone stream',
    () async {
      final permission = Completer<String>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativePlatformServices.channel, (
            call,
          ) async {
            calls.add(call);
            if (call.method == 'requestPermission') return permission.future;
            return null;
          });
      final subscription = service.startAudioStream().listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await service.stopAudioStream(cancel: true);
      permission.complete('granted');
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((e) => e.method), isNot(contains('startAudioStream')));
      await subscription.cancel();
    },
  );
  test(
    'cancel pending file-recording permission cannot start capture afterward',
    () async {
      final permission = Completer<String>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativePlatformServices.channel, (
            call,
          ) async {
            calls.add(call);
            if (call.method == 'requestPermission') return permission.future;
            return null;
          });
      final opening = service.startRecording();
      final canceled = expectLater(
        opening,
        throwsA(
          isA<PlatformCapabilityException>().having(
            (e) => e.code,
            'code',
            'cancelled',
          ),
        ),
      );
      await service.cancelRecording();
      permission.complete('granted');
      await canceled;
      expect(calls.map((e) => e.method), isNot(contains('startRecording')));
    },
  );
  test(
    'calendar permission and device calendars use actual channel responses',
    () async {
      expect(await service.requestCalendarPermission(), 'granted');
      final calendars = await service.listCalendars();
      expect(calendars.single.id, '4');
      expect(calendars.single.writable, isTrue);
    },
  );
  test('calendar conflict stays failed and explicit overwrite is a separate parameter', () async {
    final result = await service.syncCalendarEntries([
      CalendarEntry(
        id: 'entry-1',
        title: '课程准备',
        start: DateTime(2026, 11, 1, 14),
        end: DateTime(2026, 11, 1, 15),
      ),
    ], overwriteConflicts: true);
    expect(result.single.success, isFalse);
    expect(result.single.error, contains('外部修改'));
    final args = calls.single.arguments as Map;
    expect(args['overwriteConflicts'], isTrue);
    expect(args['deleteMissing'], isTrue);
  });
  test('empty future reminder set still carries new revision so old alarms can cancel', () async {
    await service.scheduleReminders(const Workspace(revision: 27));
    final args = calls.single.arguments as Map;
    expect(args['generation'], 27);
    expect(args['requests'], isEmpty);
  });
  test(
    'native errors retain precise code and cause instead of returning success',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativePlatformServices.channel, (
            call,
          ) async {
            throw PlatformException(
              code: 'calendar_unavailable',
              message: '设备没有日历 Provider',
            );
          });
      await expectLater(
        service.listCalendars(),
        throwsA(
          isA<PlatformCapabilityException>().having(
            (e) => e.code,
            'code',
            'calendar_unavailable',
          ),
        ),
      );
    },
  );
  test('notification tap callback preserves follow-up route', () async {
    final route = service.notificationRoutes.first;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'com.sera/platform',
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('notificationTap', '/24?taskId=task-1'),
          ),
          (ByteData? _) {},
        );
    expect(await route, '/24?taskId=task-1');
  });
  test('unsupported desktop platform reports capability rather than fake calendar access', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect((await service.capabilities()).calendarSupported, isFalse);
    await expectLater(
      service.ensureSeraCalendar(),
      throwsA(
        isA<PlatformCapabilityException>().having(
          (e) => e.code,
          'code',
          'unsupported',
        ),
      ),
    );
  });
}
