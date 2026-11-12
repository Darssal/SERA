import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/platform/platform_native.dart';
import 'package:sera_flutter/platform/platform_services_types.dart';

Future<void> verifyExternalCalendarChanges(
  NativePlatformServices service,
  CalendarEntry original,
) async {
  final entry = CalendarEntry(
    id: 'qa-external-conflict',
    title: 'QA external baseline',
    start: original.start,
    end: original.end,
    timeZone: original.timeZone,
  );
  final inserted = (await service.syncCalendarEntries([entry])).single;
  expect(inserted.success, isTrue, reason: inserted.error);
  var stage = 'external-update';
  var signal = Completer<void>();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8799);
  final listener = server.listen((request) async {
    request.response.headers.contentType = ContentType.json;
    if (request.method == 'POST' && request.uri.path == '/advance') {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      if (body['stage'] == stage && !signal.isCompleted) signal.complete();
    }
    request.response.write(
      jsonEncode({'stage': stage, 'eventId': inserted.deviceEventId}),
    );
    await request.response.close();
  });
  try {
    await signal.future.timeout(const Duration(seconds: 20));
    final conflict = (await service.syncCalendarEntries([entry])).single;
    expect(conflict.success, isFalse);
    expect(conflict.error, contains('外部修改'));
    final resolved = (await service.syncCalendarEntries([
      entry,
    ], overwriteConflicts: true)).single;
    expect(resolved.success, isTrue, reason: resolved.error);
    signal = Completer<void>();
    stage = 'external-delete';
    await signal.future.timeout(const Duration(seconds: 20));
    final blocked = (await service.syncCalendarEntries(const [])).single;
    expect(blocked.success, isFalse);
    expect(blocked.error, contains('系统日历中修改'));
    final retried = (await service.syncCalendarEntries(
      const [],
      overwriteConflicts: true,
    )).single;
    expect(retried.success, isTrue, reason: retried.error);
    expect(retried.operation, 'delete');
    stage = 'done';
  } finally {
    await listener.cancel();
    await server.close(force: true);
  }
}

// This branch deliberately remains alive until the host reboots the device.
// Its disconnected Flutter result is not a successful Flutter test run: the
// host independently records actual notification delivery before/after boot.
Future<void> runReminderRebootExperiment() async {
  void require(bool condition, String reason) {
    if (!condition) throw StateError(reason);
  }

  final service = NativePlatformServices();
  final runId = DateTime.now().millisecondsSinceEpoch.toString();
  final scope = 'qa-platform-reboot:$runId';
  final marker = File(
    '${Directory.systemTemp.path}/sera-platform-reboot-qa.json',
  );
  HttpServer? server;
  StreamSubscription<HttpRequest>? listener;
  final stop = Completer<void>();
  try {
    await service.setAccountScope(scope);
    var caps = await service.capabilities();
    final permissionDeadline = DateTime.now().add(const Duration(seconds: 25));
    while (caps.notificationPermission != 'granted' &&
        DateTime.now().isBefore(permissionDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      caps = await service.capabilities();
    }
    require(
      caps.notificationPermission == 'granted',
      'QA notification permission was not granted.',
    );
    require(
      caps.exactAlarmsSupported,
      'This bounded experiment requires existing exact-alarm permission; it must not change global device settings.',
    );
    final now = DateTime.now();
    final normalTask = SeraTask(
      id: 'qa-normal-$runId',
      title: 'SERA_QA_NORMAL_$runId',
      reminderMinutes: 0,
    );
    final rebootTask = SeraTask(
      id: 'qa-reboot-$runId',
      title: 'SERA_QA_REBOOT_$runId',
      reminderMinutes: 0,
    );
    final normalEntry = CalendarEntry(
      id: 'qa-normal-entry-$runId',
      taskId: normalTask.id,
      title: normalTask.title,
      start: now.add(const Duration(seconds: 5)),
      end: now.add(const Duration(minutes: 10)),
    );
    final rebootEntry = CalendarEntry(
      id: 'qa-reboot-entry-$runId',
      taskId: rebootTask.id,
      title: rebootTask.title,
      start: now.add(const Duration(seconds: 60)),
      end: now.add(const Duration(minutes: 10)),
    );
    final result = await service.scheduleReminders(
      Workspace(
        revision: now.millisecondsSinceEpoch,
        tasks: [normalTask, rebootTask],
        entries: [normalEntry, rebootEntry],
        preferences: const SeraPreferences(
          quietStart: 0,
          quietEnd: 0,
          followUp: false,
          timeZone: 'UTC',
        ),
      ),
    );
    require(result.errors.isEmpty, 'QA reminder scheduling returned errors.');
    require(result.exact, 'QA requires existing exact-alarm permission.');
    require(
      result.scheduled == 2,
      'QA did not schedule exactly two reminders.',
    );
    final persisted = await service.scheduledNotifications();
    require(
      persisted.length == 2,
      'QA reminder state did not contain exactly two records.',
    );
    final status = <String, dynamic>{
      'mode': 'platform-reboot-qa',
      'stage': 'reboot-ready',
      'runId': runId,
      'scope': scope,
      'normalReminderId': '${normalEntry.id}:start',
      'rebootReminderId': '${rebootEntry.id}:start',
      'normalFireAt': normalEntry.start.millisecondsSinceEpoch,
      'rebootFireAt': rebootEntry.start.millisecondsSinceEpoch,
      'normalTitle': normalTask.title,
      'rebootTitle': rebootTask.title,
      'exact': result.exact,
    };
    await marker.writeAsString(jsonEncode(status), flush: true);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8799);
    listener = server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'POST' && request.uri.path == '/abort') {
        if (!stop.isCompleted) stop.complete();
      }
      request.response.write(jsonEncode(status));
      await request.response.close();
    });
    await stop.future.timeout(const Duration(seconds: 120));
  } finally {
    await service.cancelNotifications();
    await service.setAccountScope('signed-out');
    if (await marker.exists()) await marker.delete();
    await listener?.cancel();
    await server?.close(force: true);
  }
}

Future<void> main() async {
  if (const bool.fromEnvironment('PLATFORM_QA_REBOOT')) {
    WidgetsFlutterBinding.ensureInitialized();
    runApp(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('SERA QA：仅合成数据，等待设备重启验收'))),
      ),
    );
    await runReminderRebootExperiment();
    return;
  }
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android device calendar, local alarms and real PCM capture', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('SERA Android 平台能力验证'))),
      ),
    );
    await tester.runAsync(() async {
      final service = NativePlatformServices();
      await service.setAccountScope('qa-platform-device-v3');
      var calendarReady = false;
      try {
        var caps = await service.capabilities();
        // flutter test installs a fresh test APK. The host grants only this
        // app's declared runtime permissions while this explicit QA test waits.
        final permissionDeadline = DateTime.now().add(
          const Duration(seconds: 25),
        );
        while ((caps.calendarPermission != 'granted' ||
                caps.notificationPermission != 'granted' ||
                caps.microphonePermission != 'granted') &&
            DateTime.now().isBefore(permissionDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          caps = await service.capabilities();
        }
        calendarReady =
            caps.calendarPermission == 'granted' && caps.calendarSupported;
        expect(caps.platform, 'android');
        expect(
          caps.calendarSupported,
          isTrue,
          reason: 'The trusted API32 CalendarProvider must be installed on MuMu device 1.',
        );
        expect(caps.calendarPermission, 'granted');
        expect(caps.notificationPermission, 'granted');
        expect(caps.microphonePermission, 'granted');

        if (caps.calendarSupported) {
          final calendar = await service.ensureSeraCalendar();
          expect(calendar.isSera, isTrue);
          expect(calendar.writable, isTrue);
          expect(
            (await service.listCalendars()).any((e) => e.id == calendar.id),
            isTrue,
          );
          if (calendarReady) {
            await service.syncCalendarEntries(
              const [],
              overwriteConflicts: true,
            );
          }
          final now = DateTime.now();
          final original = CalendarEntry(
            id: 'qa-device-entry',
            title: 'QA 系统日历实际写入',
            start: now.add(const Duration(hours: 1)),
            end: now.add(const Duration(hours: 2)),
            place: 'MuMu 安卓设备 1',
            notes: '测试结束自动清除。',
            timeZone: 'America/Los_Angeles',
          );
          final inserted = await service.syncCalendarEntries([original]);
          expect(
            inserted.single.success,
            isTrue,
            reason: inserted.single.error,
          );
          expect(inserted.single.operation, 'insert');
          final eventId = inserted.single.deviceEventId;
          expect(eventId, isNotEmpty);
          final unchanged = await service.syncCalendarEntries([original]);
          expect(unchanged.single.operation, 'unchanged');
          expect(unchanged.single.deviceEventId, eventId);
          final changed = original.copyWith(title: 'QA 系统日历实际修改');
          final updated = await service.syncCalendarEntries([changed]);
          expect(updated.single.success, isTrue, reason: updated.single.error);
          expect(updated.single.operation, 'update');
          expect(updated.single.deviceEventId, eventId);
          final deleted = await service.syncCalendarEntries(const []);
          expect(deleted.single.success, isTrue);
          expect(deleted.single.operation, 'delete');
          expect(await service.syncCalendarEntries(const []), isEmpty);
          final day = inTimeZone(
            DateTime(2026, 11, 1),
            'America/Los_Angeles',
            wallClock: true,
          );
          final allDay = CalendarEntry(
            id: 'qa-all-day',
            title: 'QA 全天日期与时区',
            start: day,
            end: calendarDay(day, 1),
            allDay: true,
            timeZone: 'America/Los_Angeles',
          );
          final allDayInsert = await service.syncCalendarEntries([allDay]);
          expect(
            allDayInsert.single.success,
            isTrue,
            reason: allDayInsert.single.error,
          );
          final allDayReadback = await service.syncCalendarEntries([allDay]);
          expect(
            allDayReadback.single.success,
            isTrue,
            reason: allDayReadback.single.error,
          );
          expect(
            allDayReadback.single.operation,
            'unchanged',
            reason: 'Provider readback must preserve ALL_DAY=1, UTC-midnight dates and UTC zone.',
          );
          expect(
            allDayReadback.single.deviceEventId,
            allDayInsert.single.deviceEventId,
          );
          expect(
            (await service.syncCalendarEntries(const [])).single.success,
            isTrue,
          );
          if (const bool.fromEnvironment('PLATFORM_QA_EXTERNAL')) {
            await verifyExternalCalendarChanges(service, original);
          }
        } else {
          await expectLater(
            service.ensureSeraCalendar(),
            throwsA(
              isA<PlatformCapabilityException>().having(
                (e) => e.code,
                'code',
                'calendar_unavailable',
              ),
            ),
          );
        }

        final task = SeraTask(
          id: 'qa-notification-task',
          title: 'QA 实际定时通知',
          reminderMinutes: 0,
        );
        final notificationEntry = CalendarEntry(
          id: 'qa-notification-entry',
          taskId: task.id,
          title: task.title,
          start: DateTime.now().add(const Duration(seconds: 5)),
          end: DateTime.now().add(const Duration(minutes: 10)),
        );
        final result = await service.scheduleReminders(
          Workspace(
            revision: DateTime.now().millisecondsSinceEpoch,
            tasks: [task],
            entries: [notificationEntry],
            preferences: const SeraPreferences(
              quietStart: 0,
              quietEnd: 0,
              followUp: false,
            ),
          ),
        );
        expect(result.errors, isEmpty);
        expect(result.scheduled, 1);
        final scheduled = await service.scheduledNotifications();
        expect(scheduled.single['route'], '/18?taskId=${task.id}');
        expect(scheduled.single['version'], isNotEmpty);
        await service.showTestNotification();
        await service.cancelNotifications();
        expect(await service.scheduledNotifications(), isEmpty);

        final pcm = Completer<Uint8List>();
        final subscription = service.startAudioStream().listen(
          (data) {
            if (!pcm.isCompleted) pcm.complete(data);
          },
          onError: (Object e, StackTrace stack) {
            if (!pcm.isCompleted) pcm.completeError(e, stack);
          },
        );
        try {
          final frame = await pcm.future.timeout(const Duration(seconds: 15));
          expect(frame.length, 3200);
          await service.stopAudioStream();
        } finally {
          await subscription.cancel();
          await service.stopAudioStream(cancel: true);
        }
        // A new recording must work after stream cancellation and release MIC.
        await service.startRecording();
        await Future<void>.delayed(const Duration(milliseconds: 400));
        final wav = await service.stopRecording();
        expect(wav.mimeType, 'audio/wav');
        expect(wav.bytes.length, greaterThan(44));
        expect(String.fromCharCodes(wav.bytes.take(4)), 'RIFF');
        expect(wav.durationMilliseconds, greaterThan(0));
      } finally {
        await service.stopAudioStream(cancel: true);
        await service.cancelRecording();
        await service.cancelNotifications();
        if (calendarReady) {
          await service.syncCalendarEntries(const [], overwriteConflicts: true);
        }
        await service.setAccountScope('signed-out');
      }
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
