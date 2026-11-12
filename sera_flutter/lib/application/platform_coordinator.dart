import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/auth_repository.dart';
import '../domain/models.dart';
import '../platform/platform_services.dart';

/// Platform work starts only after durable application writes. Failures are
/// reported separately so a device permission cannot roll back a saved task.
class PlatformCoordinator extends ChangeNotifier {
  PlatformCoordinator({
    required this.auth,
    required this.accountId,
    SeraPlatformServices? services,
  }) : _services = services ?? platformServices;
  final SeraPlatformServices _services;
  final AuthRepository auth;
  final String accountId;
  bool _closed = false;
  bool _pushSubscriptionRestored = false;
  bool get _active =>
      !_closed &&
      (accountId == 'device-local'
          ? !auth.signedIn
          : auth.session?.user.id == accountId);
  String? lastError;
  List<PlatformSyncResult> syncResults = [];
  Future<Workspace> readBusySnapshot(
    Workspace workspace,
    DateTime deadline,
  ) async {
    final ids = List<String>.from(
      workspace.platformSettings['selectedCalendarIds'] as List? ?? [],
    );
    final capability = await _services.capabilities();
    if (!_active ||
        !capability.calendarSupported ||
        capability.calendarPermission != 'granted') {
      return workspace;
    }
    final events = ids.isEmpty
        ? <ExternalBusyEvent>[]
        : await _services.readBusyEvents(
            ids,
            DateTime.now().subtract(const Duration(days: 30)),
            deadline.add(const Duration(days: 1)),
          );
    if (!_active) return workspace;
    return workspace.copyWith(
      externalBusyEntries: [
        ...workspace.externalBusyEntries.where(
          (e) => e.source != 'device-calendar',
        ),
        ...events.map(
          (e) => CalendarEntry(
            id: 'device:${e.calendarId}:${e.id}',
            title: e.title,
            start: inTimeZone(
              e.allDay ? dateOnly(e.start) : e.start,
              workspace.preferences.timeZone,
              wallClock: e.allDay,
            ),
            end: inTimeZone(
              e.allDay ? dateOnly(e.end) : e.end,
              workspace.preferences.timeZone,
              wallClock: e.allDay,
            ),
            place: e.place,
            locked: true,
            allDay: e.allDay,
            source: 'device-calendar',
            externalId: e.id,
            timeZone: workspace.preferences.timeZone,
          ),
        ),
      ],
    );
  }

  Future<void> reconcile(Workspace workspace) async {
    if (!_active) return;
    try {
      final capability = await _services.capabilities();
      if (!_active) return;
      if (auth.signedIn &&
          !_pushSubscriptionRestored &&
          capability.webPushSupported) {
        final subscription = await _services.currentWebPushSubscription();
        if (!_active) return;
        if (subscription != null) {
          await auth.authenticatedRequest(
            'POST',
            '/api/v1/push/subscriptions',
            data: {
              ...subscription,
              'subscription': subscription,
              'scope': accountId,
            },
          );
        }
        if (!_active) return;
        _pushSubscriptionRestored = true;
      }
      if (capability.notificationPermission == 'granted') {
        await _services.scheduleReminders(workspace);
      }
      if (!_active) return;
      if (workspace.platformSettings['calendarAutoSync'] == true &&
          capability.calendarPermission == 'granted') {
        syncResults = await _services.syncCalendarEntries(workspace.entries);
        if (!_active) return;
        if (syncResults.any((e) => !e.success)) {
          throw const PlatformCapabilityException(
            'partial_sync',
            '部分日历事项尚未同步，请到日历设置重试。',
          );
        }
      }
      lastError = null;
    } catch (e) {
      lastError = '$e';
      rethrow;
    } finally {
      if (!_closed) notifyListeners();
    }
  }

  Future<void> enableWebPush() async {
    if (!auth.signedIn) {
      throw const PlatformCapabilityException(
        'cloud_sync_required',
        '登录并同步记录后可开启云端提醒。',
      );
    }
    final boundSession = auth.session?.sessionId;
    final config = await auth.authenticatedRequest(
      'GET',
      '/api/v1/push/config',
    );
    if (_closed ||
        auth.session?.user.id != accountId ||
        auth.session?.sessionId != boundSession) {
      throw const PlatformCapabilityException(
        'account_changed',
        '账号已变化，后台提醒操作已停止。',
      );
    }
    final key = config['publicKey'] ?? config['vapidPublicKey'];
    if (key is! String || key.isEmpty) {
      throw const PlatformCapabilityException(
        'push_not_configured',
        '后台提醒服务尚未配置。',
      );
    }
    final subscription = await _services.subscribeWebPush(key);
    if (_closed ||
        auth.session?.user.id != accountId ||
        auth.session?.sessionId != boundSession) {
      throw const PlatformCapabilityException(
        'account_changed',
        '账号已变化，后台提醒操作已停止。',
      );
    }
    try {
      await auth.authenticatedRequest(
        'POST',
        '/api/v1/push/subscriptions',
        data: {
          ...subscription,
          'subscription': subscription,
          'scope': accountId,
        },
      );
      lastError = null;
    } catch (_) {
      if (_closed ||
          auth.session?.user.id != accountId ||
          auth.session?.sessionId != boundSession) {
        rethrow;
      }
      // Browser-only success must not disable fallback timers or look like a
      // registered backend subscription when its durable registration failed.
      try {
        await _services.unsubscribeWebPush();
        lastError = '后台提醒注册失败，浏览器订阅已撤销。';
      } catch (cleanup) {
        lastError = '后台提醒注册失败，浏览器订阅撤销也未确认：$cleanup';
      }
      if (!_closed) notifyListeners();
      rethrow;
    }
    if (!_closed) notifyListeners();
  }

  Future<void> disableWebPush() async {
    final boundSession = auth.session?.sessionId;
    final subscription = await _services.currentWebPushSubscription();
    if (!_active || auth.session?.sessionId != boundSession) return;
    if (subscription != null) {
      await auth.authenticatedRequest(
        'DELETE',
        '/api/v1/push/subscriptions',
        data: {'endpoint': subscription['endpoint']},
      );
    }
    if (!_active || auth.session?.sessionId != boundSession) return;
    await _services.unsubscribeWebPush();
    if (!_closed) notifyListeners();
  }

  Future<void> testPush() async {
    await auth.authenticatedRequest(
      'POST',
      '/api/v1/push/test',
      data: <String, dynamic>{},
    );
  }

  Future<void> exportWorkspace(Workspace value) => _services.downloadText(
    const JsonEncoder.withIndent('  ').convert(value.toJson()),
    filename: 'sera-backup.json',
  );
  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
