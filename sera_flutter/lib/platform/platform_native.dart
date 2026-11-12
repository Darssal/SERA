import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import 'platform_services_types.dart';
import 'reminder_requests.dart';

SeraPlatformServices createPlatformServices() => NativePlatformServices();

class NativePlatformServices implements SeraPlatformServices {
  NativePlatformServices() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'notificationTap' && call.arguments is String) {
        _routes.add(call.arguments as String);
      }
    });
  }
  final _routes = StreamController<String>.broadcast();
  @override
  Stream<String> get notificationRoutes => _routes.stream;
  @override
  Future<String?> consumeInitialNotificationRoute() async =>
      _android ? await _call<String>('consumeInitialNotificationRoute') : null;
  static const channel = MethodChannel('com.sera/platform');
  static const audioEvents = EventChannel('com.sera/audio_pcm');
  StreamController<Uint8List>? _pcm;
  StreamSubscription<dynamic>? _pcmEvents;
  int _recordOperation = 0;
  bool get _android => defaultTargetPlatform == TargetPlatform.android;
  @override
  Future<void> setAccountScope(String userId) async {
    _recordOperation++;
    await stopAudioStream(cancel: true);
    if (_android) await _call<void>('setAccountScope', {'userId': userId});
  }

  Future<T?> _call<T>(String method, [Map<String, dynamic>? args]) async {
    if (!_android) {
      throw const PlatformCapabilityException(
        'unsupported',
        '当前平台没有 Android 设备能力；请使用 Android，或在 Web 使用 ICS 与浏览器能力。',
      );
    }
    try {
      return await channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw PlatformCapabilityException(e.code, e.message ?? '系统操作失败。');
    } on MissingPluginException {
      throw const PlatformCapabilityException(
        'not_registered',
        '原生平台通道未注册，请完整重新构建并安装应用。',
      );
    }
  }

  @override
  Future<PlatformCapabilities> capabilities() async {
    if (!_android) {
      return const PlatformCapabilities(
        platform: 'unsupported',
        calendarSupported: false,
        notificationsSupported: false,
        backgroundNotifications: false,
        recordingSupported: false,
        calendarPermission: 'unsupported',
        notificationPermission: 'unsupported',
        microphonePermission: 'unsupported',
        exactAlarmsSupported: false,
      );
    }
    return PlatformCapabilities.fromJson(
      Map<String, dynamic>.from((await _call<Map>('capabilities'))!),
    );
  }

  Future<String> _permission(String kind) async =>
      await _call<String>('requestPermission', {'kind': kind}) ?? 'denied';
  @override
  Future<String> requestCalendarPermission() => _permission('calendar');
  @override
  Future<String> requestNotificationPermission() =>
      _permission('notifications');
  @override
  Future<String> requestMicrophonePermission() => _permission('microphone');
  @override
  Future<void> openApplicationSettings() async {
    await _call<void>('openApplicationSettings');
  }

  @override
  Future<void> requestExactAlarmPermission() async {
    await _call<void>('requestExactAlarmPermission');
  }

  @override
  Future<List<PlatformCalendar>> listCalendars() async =>
      ((await _call<List>('listCalendars')) ?? [])
          .map(
            (e) =>
                PlatformCalendar.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList();
  @override
  Future<List<ExternalBusyEvent>> readBusyEvents(
    List<String> calendarIds,
    DateTime start,
    DateTime end,
  ) async =>
      ((await _call<List>('readBusyEvents', {
                'calendarIds': calendarIds,
                'start': start.millisecondsSinceEpoch,
                'end': end.millisecondsSinceEpoch,
              })) ??
              [])
          .map(
            (e) =>
                ExternalBusyEvent.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList();
  @override
  Future<PlatformCalendar> ensureSeraCalendar() async =>
      PlatformCalendar.fromJson(
        Map<String, dynamic>.from((await _call<Map>('ensureSeraCalendar'))!),
      );
  @override
  Future<List<PlatformSyncResult>> syncCalendarEntries(
    List<CalendarEntry> entries, {
    bool deleteMissing = true,
    bool overwriteConflicts = false,
  }) async =>
      ((await _call<List>('syncCalendarEntries', {
                'deleteMissing': deleteMissing,
                'overwriteConflicts': overwriteConflicts,
                'entries': entries
                    .map(
                      (e) => {
                        'id': e.id,
                        'title': e.title,
                        'start': _calendarInstant(e.start, e),
                        'end': _calendarInstant(e.end, e),
                        'allDay': e.allDay,
                        'timeZone': e.allDay ? 'UTC' : e.timeZone,
                        'place': e.place,
                        'notes': e.notes,
                      },
                    )
                    .toList(),
              })) ??
              [])
          .map(
            (e) => PlatformSyncResult.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList();
  int _calendarInstant(DateTime instant, CalendarEntry entry) {
    if (!entry.allDay) return instant.millisecondsSinceEpoch;
    // All-day values are floating dates. Models preserve year/month/day in
    // the display zone; converting the instant to its original zone can
    // shift that date and must never happen when writing Calendar Provider.
    return DateTime.utc(
      instant.year,
      instant.month,
      instant.day,
    ).millisecondsSinceEpoch;
  }

  @override
  Future<NotificationScheduleResult> scheduleReminders(
    Workspace workspace,
  ) async {
    final requests = buildReminderRequests(workspace);
    final result = Map<String, dynamic>.from(
      (await _call<Map>('scheduleNotifications', {
        'requests': requests.requests,
        'enabled': workspace.preferences.notifications,
        'generation': workspace.revision,
        'quietStart': workspace.preferences.quietStart,
        'quietEnd': workspace.preferences.quietEnd,
        'timeZone': workspace.preferences.timeZone,
      }))!,
    );
    return NotificationScheduleResult(
      scheduled: (result['scheduled'] as num?)?.toInt() ?? 0,
      skipped: requests.skipped + (result['skipped'] as num? ?? 0).toInt(),
      exact: result['exact'] == true,
      errors: List<String>.from(result['errors'] as List? ?? []),
      warnings: List<String>.from(result['warnings'] as List? ?? []),
    );
  }

  @override
  Future<void> showTestNotification() async {
    await _call<void>('showTestNotification');
  }

  @override
  Future<void> cancelNotifications() async {
    await _call<void>('cancelNotifications');
  }

  @override
  Future<List<Map<String, dynamic>>> scheduledNotifications() async =>
      ((await _call<List>('scheduledNotifications')) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
  @override
  Future<String?> pickIcsFile() => _call<String>('pickIcsFile');
  @override
  Future<void> downloadIcs(
    String content, {
    String filename = 'sera-calendar.ics',
  }) async {
    await _call<void>('saveIcsFile', {
      'content': content,
      'filename': filename,
    });
  }

  @override
  Future<void> downloadText(
    String content, {
    required String filename,
    String mimeType = 'application/json',
  }) async {
    await _call<void>('saveTextFile', {
      'content': content,
      'filename': filename,
      'mimeType': mimeType,
    });
  }

  @override
  Future<void> startRecording() async {
    final operation = ++_recordOperation;
    if (await requestMicrophonePermission() != 'granted') {
      throw const PlatformCapabilityException(
        'microphone_denied',
        '麦克风权限未开启，请到系统设置授权后再试。',
      );
    }
    if (operation != _recordOperation) {
      throw const PlatformCapabilityException('cancelled', '已取消录音。');
    }
    await _call<void>('startRecording');
  }

  @override
  Future<RecordedAudio> stopRecording() async {
    final data = Map<String, dynamic>.from(
      (await _call<Map>('stopRecording'))!,
    );
    return RecordedAudio(
      bytes: base64Decode(data['base64'] as String),
      mimeType: data['mimeType'] as String,
      fileName: data['fileName'] as String,
      durationMilliseconds: (data['durationMilliseconds'] as num).toInt(),
    );
  }

  @override
  Future<void> cancelRecording() async {
    _recordOperation++;
    await _call<void>('cancelRecording');
  }

  @override
  Stream<Uint8List> startAudioStream() {
    if (_pcm != null) {
      return Stream.error(
        const PlatformCapabilityException('recording_busy', '已有音频流正在运行。'),
      );
    }
    final controller = StreamController<Uint8List>();
    _pcm = controller;
    controller.onListen = () async {
      try {
        if (await requestMicrophonePermission() != 'granted') {
          throw const PlatformCapabilityException(
            'microphone_denied',
            '麦克风权限未开启。',
          );
        }
        if (!identical(_pcm, controller) || controller.isClosed) return;
        _pcmEvents = audioEvents.receiveBroadcastStream().listen(
          (data) {
            if (data is Uint8List && !controller.isClosed) controller.add(data);
          },
          onError: (Object error, StackTrace stack) {
            if (!controller.isClosed) controller.addError(error, stack);
          },
          onDone: () {
            if (!controller.isClosed) unawaited(controller.close());
            if (identical(_pcm, controller)) _pcm = null;
          },
        );
        await _call<void>('startAudioStream');
        if (!identical(_pcm, controller) || controller.isClosed) {
          await _call<void>('stopAudioStream', {'cancel': true});
        }
      } catch (error, stack) {
        if (!controller.isClosed) {
          controller.addError(error, stack);
          unawaited(controller.close());
        }
        await _pcmEvents?.cancel();
        _pcmEvents = null;
        if (identical(_pcm, controller)) _pcm = null;
      }
    };
    controller.onCancel = () => stopAudioStream(cancel: true);
    return controller.stream;
  }

  @override
  Future<void> stopAudioStream({bool cancel = false}) async {
    final controller = _pcm;
    _pcm = null;
    final events = _pcmEvents;
    _pcmEvents = null;
    if (controller == null && events == null) return;
    try {
      await _call<void>('stopAudioStream', {'cancel': cancel});
    } finally {
      // The MethodChannel acknowledgement means AudioRecord has stopped and
      // released MIC. Detach the event adapter independently: a controller's
      // onCancel can be reentered while its own cancel future is pending.
      // Waiting on that future here would make stream cancellation wait on
      // itself and prevent the caller from sending the ASR finish message.
      if (events != null) unawaited(events.cancel());
      if (controller != null && !controller.isClosed) {
        unawaited(controller.close());
      }
    }
  }

  @override
  Future<Map<String, dynamic>> subscribeWebPush(String vapidPublicKey) async =>
      throw const PlatformCapabilityException(
        'unsupported',
        'Android 使用原生本地定时通知，不使用浏览器 Web Push。',
      );
  @override
  Future<Map<String, dynamic>?> currentWebPushSubscription() async => null;
  @override
  Future<void> unsubscribeWebPush() async {}
}
