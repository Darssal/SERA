import 'dart:typed_data';

import '../domain/models.dart';

class PlatformCapabilityException implements Exception {
  const PlatformCapabilityException(this.code, this.message);
  final String code, message;
  @override
  String toString() => message;
}

class PlatformCapabilities {
  const PlatformCapabilities({
    required this.platform,
    required this.calendarSupported,
    required this.notificationsSupported,
    required this.backgroundNotifications,
    required this.recordingSupported,
    required this.calendarPermission,
    required this.notificationPermission,
    required this.microphonePermission,
    required this.exactAlarmsSupported,
    this.webPushSupported = false,
    this.webPushSubscribed = false,
  });
  final String platform,
      calendarPermission,
      notificationPermission,
      microphonePermission;
  final bool calendarSupported,
      notificationsSupported,
      backgroundNotifications,
      recordingSupported,
      exactAlarmsSupported;
  final bool webPushSupported, webPushSubscribed;
  factory PlatformCapabilities.fromJson(Map<String, dynamic> j) =>
      PlatformCapabilities(
        platform: j['platform'] as String? ?? 'unsupported',
        calendarSupported: j['calendarSupported'] == true,
        notificationsSupported: j['notificationsSupported'] == true,
        backgroundNotifications: j['backgroundNotifications'] == true,
        recordingSupported: j['recordingSupported'] == true,
        calendarPermission: j['calendarPermission'] as String? ?? 'unsupported',
        notificationPermission:
            j['notificationPermission'] as String? ?? 'unsupported',
        microphonePermission:
            j['microphonePermission'] as String? ?? 'unsupported',
        exactAlarmsSupported: j['exactAlarmsSupported'] == true,
        webPushSupported: j['webPushSupported'] == true,
        webPushSubscribed: j['webPushSubscribed'] == true,
      );
}

class PlatformCalendar {
  const PlatformCalendar({
    required this.id,
    required this.name,
    required this.account,
    required this.writable,
    required this.isSera,
  });
  final String id, name, account;
  final bool writable, isSera;
  factory PlatformCalendar.fromJson(Map<String, dynamic> j) => PlatformCalendar(
    id: '${j['id']}',
    name: '${j['name'] ?? ''}',
    account: '${j['account'] ?? ''}',
    writable: j['writable'] == true,
    isSera: j['isSera'] == true,
  );
}

class ExternalBusyEvent {
  const ExternalBusyEvent({
    required this.id,
    required this.calendarId,
    required this.title,
    required this.start,
    required this.end,
    this.allDay = false,
    this.place = '',
  });
  final String id, calendarId, title, place;
  final DateTime start, end;
  final bool allDay;
  factory ExternalBusyEvent.fromJson(Map<String, dynamic> j) {
    final allDay = j['allDay'] == true;
    DateTime readDate(String key) {
      final instant = DateTime.fromMillisecondsSinceEpoch(
        (j[key] as num).toInt(),
        isUtc: allDay,
      );
      // Calendar Provider encodes all-day dates at UTC midnight. Keep their
      // calendar dates floating until the workspace assigns its display zone.
      return allDay
          ? DateTime(instant.year, instant.month, instant.day)
          : instant;
    }

    return ExternalBusyEvent(
      id: '${j['id']}',
      calendarId: '${j['calendarId']}',
      title: '${j['title'] ?? '忙碌'}',
      start: readDate('start'),
      end: readDate('end'),
      allDay: allDay,
      place: '${j['place'] ?? ''}',
    );
  }
}

class PlatformSyncResult {
  const PlatformSyncResult({
    required this.sourceId,
    required this.operation,
    required this.success,
    this.deviceEventId,
    this.error,
  });
  final String sourceId, operation;
  final bool success;
  final String? deviceEventId, error;
  factory PlatformSyncResult.fromJson(Map<String, dynamic> j) =>
      PlatformSyncResult(
        sourceId: '${j['sourceId'] ?? ''}',
        operation: '${j['operation'] ?? 'sync'}',
        success: j['success'] == true,
        deviceEventId: j['deviceEventId']?.toString(),
        error: j['error']?.toString(),
      );
}

class NotificationScheduleResult {
  const NotificationScheduleResult({
    required this.scheduled,
    required this.skipped,
    required this.exact,
    this.errors = const [],
    this.warnings = const [],
  });
  final int scheduled, skipped;
  final bool exact;
  final List<String> errors, warnings;
}

class RecordedAudio {
  const RecordedAudio({
    required this.bytes,
    required this.mimeType,
    required this.fileName,
    required this.durationMilliseconds,
  });
  final Uint8List bytes;
  final String mimeType, fileName;
  final int durationMilliseconds;
}

abstract interface class SeraPlatformServices {
  Future<void> setAccountScope(String userId);
  Stream<String> get notificationRoutes;
  Future<String?> consumeInitialNotificationRoute();
  Future<PlatformCapabilities> capabilities();
  Future<String> requestCalendarPermission();
  Future<String> requestNotificationPermission();
  Future<String> requestMicrophonePermission();
  Future<void> openApplicationSettings();
  Future<void> requestExactAlarmPermission();
  Future<List<PlatformCalendar>> listCalendars();
  Future<List<ExternalBusyEvent>> readBusyEvents(
    List<String> calendarIds,
    DateTime start,
    DateTime end,
  );
  Future<PlatformCalendar> ensureSeraCalendar();
  Future<List<PlatformSyncResult>> syncCalendarEntries(
    List<CalendarEntry> entries, {
    bool deleteMissing = true,
    bool overwriteConflicts = false,
  });
  Future<NotificationScheduleResult> scheduleReminders(Workspace workspace);
  Future<void> showTestNotification();
  Future<void> cancelNotifications();
  Future<List<Map<String, dynamic>>> scheduledNotifications();
  Future<String?> pickIcsFile();
  Future<void> downloadIcs(
    String content, {
    String filename = 'sera-calendar.ics',
  });
  Future<void> downloadText(
    String content, {
    required String filename,
    String mimeType = 'application/json',
  });
  Future<void> startRecording();
  Future<RecordedAudio> stopRecording();
  Future<void> cancelRecording();
  Stream<Uint8List> startAudioStream();
  Future<void> stopAudioStream({bool cancel = false});
  Future<Map<String, dynamic>> subscribeWebPush(String vapidPublicKey);
  Future<Map<String, dynamic>?> currentWebPushSubscription();
  Future<void> unsubscribeWebPush();
}
