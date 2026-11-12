import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../application/sera_controller.dart';
import '../../application/platform_coordinator.dart';
import '../../data/auth_repository.dart';
import '../../domain/models.dart';
import '../../platform/platform_services.dart';
import '../core/sera_widgets.dart';
import '../core/sera_motion.dart';

Widget buildPlatformScreen(String id) =>
    PlatformSettingsScreen(mode: id.split('-').first);

class _SyncSnapshot {
  List<PlatformSyncResult> results = [];
  DateTime? at;
  String? error;
  int busyCount = 0;
}

final _syncSnapshots = <String, _SyncSnapshot>{};

class _PlatformOperation {
  const _PlatformOperation(
    this.serial,
    this.route,
    this.controller,
    this.auth,
    this.session,
    this.scope,
  );
  final int serial;
  final ModalRoute<dynamic>? route;
  final SeraController controller;
  final AuthRepository? auth;
  final AuthSession? session;
  final String scope;
  String get selectionKey => 'sera.platform.calendar.sources.$scope';
}

class PlatformSettingsScreen extends StatefulWidget {
  const PlatformSettingsScreen({super.key, required this.mode});
  final String mode;
  @override
  State<PlatformSettingsScreen> createState() => _PlatformSettingsScreenState();
}

class _PlatformSettingsScreenState extends State<PlatformSettingsScreen> {
  PlatformCapabilities? _capabilities;
  List<PlatformCalendar> _calendars = [];
  Set<String> _selected = {};
  NotificationScheduleResult? _schedule;
  int? _pending;
  SeraPreferences? _notificationPreferences;
  bool _busy = false, _initialized = false;
  int _operationSerial = 0;
  String? _error, _message;
  final _prefs = SharedPreferencesAsync();
  final _statusAnchor = GlobalKey();
  String get _scope =>
      context.read<AuthRepository?>()?.session?.user.id ??
      context.read<SeraController>().accountId;
  _SyncSnapshot get _snapshot =>
      _syncSnapshots.putIfAbsent(_scope, _SyncSnapshot.new);

  _PlatformOperation _captureOperation() {
    final auth = context.read<AuthRepository?>();
    return _PlatformOperation(
      _operationSerial,
      ModalRoute.of(context),
      context.read<SeraController>(),
      auth,
      auth?.session,
      _scope,
    );
  }

  bool _owns(_PlatformOperation operation, {bool current = false}) =>
      mounted &&
      operation.serial == _operationSerial &&
      operation.route?.isActive == true &&
      (!current || operation.route?.isCurrent == true) &&
      identical(context.read<SeraController>(), operation.controller) &&
      identical(context.read<AuthRepository?>(), operation.auth) &&
      _scope == operation.scope &&
      operation.auth?.session?.sessionId == operation.session?.sessionId &&
      operation.auth?.session?.token == operation.session?.token;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      _notificationPreferences = context
          .read<SeraController>()
          .data
          .preferences;
      final owner = _captureOperation();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_owns(owner, current: true)) _load();
      });
    }
  }

  Future<void> _perform(
    Future<void> Function(_PlatformOperation) action,
  ) async {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true || _busy) return;
    _operationSerial++;
    final operation = _captureOperation();
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      await action(operation);
    } catch (error) {
      if (_owns(operation)) setState(() => _error = '$error');
    } finally {
      if (_owns(operation)) {
        setState(() => _busy = false);
        if (_error != null || _message != null) _revealStatus(operation);
      }
    }
  }

  void _revealStatus(_PlatformOperation operation) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final status = _statusAnchor.currentContext;
      if (!_owns(operation, current: true) || status == null) return;
      Scrollable.ensureVisible(
        status,
        alignment: 0,
        duration: SeraMotion.scrollDuration(context),
      );
    });
  }

  Future<void> _load() => _perform((operation) async {
    final configured =
        operation.controller.data.platformSettings['selectedCalendarIds'];
    final selected = configured is List
        ? configured.whereType<String>().toList()
        : await _prefs.getStringList(operation.selectionKey) ?? [];
    if (!_owns(operation)) return;
    final capabilities = await platformServices.capabilities();
    if (!_owns(operation)) return;
    final calendars =
        capabilities.calendarSupported &&
            capabilities.calendarPermission == 'granted'
        ? await platformServices.listCalendars()
        : <PlatformCalendar>[];
    if (!_owns(operation)) return;
    final pending = capabilities.notificationsSupported
        ? (await platformServices.scheduledNotifications()).length
        : 0;
    if (!_owns(operation)) return;
    setState(() {
      _capabilities = capabilities;
      _calendars = calendars;
      _selected = selected.toSet();
      _pending = pending;
    });
  });

  Future<void> _connect() => _perform((operation) async {
    final permission = await platformServices.requestCalendarPermission();
    if (!_owns(operation)) return;
    final capabilities = await platformServices.capabilities();
    if (!_owns(operation)) return;
    if (_owns(operation)) setState(() => _capabilities = capabilities);
    if (permission != 'granted') {
      throw const PlatformCapabilityException(
        'permission_denied',
        '日历权限尚未开启。你可以打开系统设置授权后重试。',
      );
    }
    final calendars = await platformServices.listCalendars();
    if (_owns(operation)) {
      setState(() {
        _calendars = calendars;
        _message = '已允许访问日历，请选择要连接的日历。';
      });
    }
  });

  Future<void> _saveSelection(String id, bool selected) async {
    await _perform((operation) async {
      final values = {..._selected};
      selected ? values.add(id) : values.remove(id);
      await operation.controller.savePlatformSettings({
        'selectedCalendarIds': values.toList(),
      });
      if (!_owns(operation)) return;
      await _prefs.setStringList(operation.selectionKey, values.toList());
      if (_owns(operation)) setState(() => _selected = values);
    });
  }

  Future<void> _sync({
    bool retryOnly = false,
    bool overwriteConflicts = false,
  }) => _perform((operation) async {
    final c = operation.controller;
    final snapshot = _syncSnapshots.putIfAbsent(
      operation.scope,
      _SyncSnapshot.new,
    );
    snapshot.error = null;
    if (!retryOnly) {
      final now = c.today;
      final busy = await platformServices.readBusyEvents(
        _selected.toList(),
        dateOnly(now),
        calendarDay(now, 366),
      );
      if (!_owns(operation)) return;
      final entries = busy
          .map(
            (event) => CalendarEntry(
              id: 'device:${event.calendarId}:${event.id}',
              title: event.title,
              start: inTimeZone(
                event.start,
                c.data.preferences.timeZone,
                wallClock: event.allDay,
              ),
              end: inTimeZone(
                event.end,
                c.data.preferences.timeZone,
                wallClock: event.allDay,
              ),
              place: event.place,
              locked: true,
              allDay: event.allDay,
              source: 'device-calendar',
              externalId: event.id,
              timeZone: c.data.preferences.timeZone,
            ),
          )
          .toList();
      await c.setExternalBusyEntries(entries, source: 'device-calendar');
      if (!_owns(operation)) return;
      snapshot.busyCount = busy.length;
      await _prefs.setStringList(operation.selectionKey, _selected.toList());
      if (!_owns(operation)) return;
      await platformServices.ensureSeraCalendar();
    }
    if (!_owns(operation)) return;
    // The device layer compares persisted fingerprints. Passing the whole
    // current set also retries failed deletes, which have no remaining entry.
    final results = await platformServices.syncCalendarEntries(
      c.data.entries,
      deleteMissing: true,
      overwriteConflicts: overwriteConflicts,
    );
    if (!_owns(operation)) return;
    snapshot.results = results;
    snapshot.at = DateTime.now();
    if (_owns(operation)) {
      setState(
        () => _message =
            '${results.where((r) => r.success).length} 项已同步，${results.where((r) => !r.success).length} 项未完成。',
      );
    }
    if (results.any((r) => !r.success) &&
        mounted &&
        _owns(operation, current: true) &&
        widget.mode != '42') {
      openScreen(context, '42');
    }
  });

  Future<void> _overwriteCalendarChanges() async {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true || _busy) return;
    final operation = _captureOperation();
    final yes = await showDialog<bool>(
      context: context,
      animationStyle: SeraMotion.dialogStyle(context),
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('覆盖系统日历中的改动？'),
        content: const Text('这些日程在系统日历中被改过。确认后，会用序日保存的内容替换这些改动。其他日历不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('保留系统改动'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('以序日内容覆盖'),
          ),
        ],
      ),
    );
    if (yes == true && _owns(operation, current: true)) {
      await _sync(retryOnly: true, overwriteConflicts: true);
    }
  }

  Future<void> _importIcs() => _perform((operation) async {
    final c = operation.controller;
    final auth = operation.auth;
    final content = await platformServices.pickIcsFile();
    if (content == null || !_owns(operation, current: true)) return;
    List<CalendarEntry> entries;
    try {
      entries = parseIcs(content, timeZone: c.data.preferences.timeZone);
    } on PlatformCapabilityException catch (error) {
      if (!error.code.startsWith('unsupported') || auth?.signedIn != true) {
        rethrow;
      }
      final preview = await auth!.authenticatedRequest(
        'POST',
        '/api/v1/calendar/ics/preview',
        data: {
          'content': content,
          'start': c.today.toUtc().toIso8601String(),
          'end': calendarDay(c.today, 366).toUtc().toIso8601String(),
          'timeZone': c.data.preferences.timeZone,
        },
      );
      if (!_owns(operation, current: true)) return;
      entries = (preview['entries'] as List? ?? [])
          .whereType<Map>()
          .map((e) => CalendarEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    if (entries.isEmpty) {
      throw const PlatformCapabilityException(
        'empty_calendar',
        '文件中没有可导入的有效日程。',
      );
    }
    if (!mounted || !_owns(operation, current: true)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      animationStyle: SeraMotion.dialogStyle(context),
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text('导入 ${entries.length} 项日程？'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '自动安排任务时会避开这些时间。本次导入将替换上次从文件导入的日程，序日中创建的任务和日程会保留。',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.8,
                  color: SeraColors.muted,
                ),
              ),
              const SizedBox(height: 14),
              for (final entry in entries.take(15))
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    '${entry.title}\n${formatDate(entry.start)} ${entry.allDay ? '全天' : formatRange(entry.start, entry.end)}',
                    style: const TextStyle(fontSize: 13, height: 1.6),
                  ),
                ),
              if (entries.length > 15)
                Text(
                  '另有 ${entries.length - 15} 项安排。',
                  style: const TextStyle(fontSize: 12, color: SeraColors.muted),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消导入'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认导入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !_owns(operation, current: true)) return;
    await c.setExternalBusyEntries(entries, source: 'ics-import');
    if (_owns(operation, current: true)) {
      setState(() => _message = '已导入 ${entries.length} 项日程，自动安排任务时会避开这些时间。');
    }
  });

  Future<void> _exportIcs() => _perform((operation) async {
    final entries = operation.controller.data.entries;
    await platformServices.downloadIcs(exportIcs(entries));
    if (_owns(operation, current: true)) {
      setState(() => _message = '已开始保存日历文件，保存后可导入其他日历应用。');
    }
  });

  Future<void> _requestNotifications() => _perform((operation) async {
    final permission = await platformServices.requestNotificationPermission();
    if (!_owns(operation)) return;
    final capabilities = await platformServices.capabilities();
    if (_owns(operation, current: true)) {
      setState(() {
        _capabilities = capabilities;
        _message = permission == 'granted'
            ? '通知权限已开启。'
            : '通知权限尚未开启，请在系统或浏览器站点设置中授权。';
      });
    }
  });

  Future<void> _saveNotifications() => _perform((operation) async {
    final c = operation.controller;
    final edited = _notificationPreferences ?? c.data.preferences;
    final preferences = c.data.preferences.copyWith(
      notifications: edited.notifications,
      followUp: edited.followUp,
      quietStart: edited.quietStart,
      quietEnd: edited.quietEnd,
    );
    await c.savePreferences(preferences);
    if (!_owns(operation)) return;
    _notificationPreferences = c.data.preferences;
    if (!preferences.notifications) {
      await platformServices.cancelNotifications();
      if (_owns(operation, current: true)) {
        setState(() {
          _pending = 0;
          _schedule = null;
          _message = '提醒已关闭，已取消本账户提醒。';
        });
      }
      return;
    }
    final permission = await platformServices.requestNotificationPermission();
    if (!_owns(operation)) return;
    final capabilities = await platformServices.capabilities();
    if (!_owns(operation)) return;
    if (_owns(operation, current: true)) {
      setState(() => _capabilities = capabilities);
    }
    if (permission != 'granted') {
      throw const PlatformCapabilityException(
        'permission_denied',
        '偏好已保存；请开启通知权限后重试。',
      );
    }
    final result = await platformServices.scheduleReminders(c.data);
    if (!_owns(operation)) return;
    final pending = await platformServices.scheduledNotifications();
    if (_owns(operation, current: true)) {
      setState(() {
        _schedule = result;
        _pending = pending.length;
        _message = '已安排 ${result.scheduled} 条提醒，${result.skipped} 条未安排。';
      });
    }
  });

  Future<void> _testNotification() => _perform((operation) async {
    final permission = await platformServices.requestNotificationPermission();
    if (!_owns(operation)) return;
    if (permission != 'granted') {
      throw const PlatformCapabilityException(
        'permission_denied',
        '请先开启通知权限，再发送测试提醒。',
      );
    }
    await platformServices.showTestNotification();
    if (!_owns(operation)) return;
    final capabilities = await platformServices.capabilities();
    if (_owns(operation, current: true)) {
      setState(() {
        _capabilities = capabilities;
        _message = '已请求发送测试提醒，请查看设备或浏览器通知。';
      });
    }
  });

  Future<void> _setPush(bool enabled) => _perform((operation) async {
    final coordinator = context.read<PlatformCoordinator>();
    final c = operation.controller;
    if (enabled) {
      await coordinator.enableWebPush();
    } else {
      await coordinator.disableWebPush();
    }
    if (!_owns(operation)) return;
    await c.savePlatformSettings({'webPush': enabled});
    if (!_owns(operation)) return;
    final caps = await platformServices.capabilities();
    if (_owns(operation, current: true)) {
      setState(() {
        _capabilities = caps;
        _message = enabled ? '后台提醒已开启。关闭页面后，也可接收浏览器推送。' : '后台提醒已关闭。';
      });
    }
  });

  Future<void> _testPush() => _perform((operation) async {
    await context.read<PlatformCoordinator>().testPush();
    if (_owns(operation, current: true)) {
      setState(() => _message = '已请求发送后台测试提醒，请查看浏览器通知。');
    }
  });

  Future<void> _pickQuiet(bool start) async {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true || _busy) return;
    final operation = _captureOperation();
    final p = _notificationPreferences!;
    final minutes = start ? p.quietStart : p.quietEnd;
    final time = await SeraMotion.pickTime(
      context: context,
      initialTime: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
    );
    if (time != null && _owns(operation, current: true)) {
      setState(
        () => _notificationPreferences = start
            ? p.copyWith(quietStart: time.hour * 60 + time.minute)
            : p.copyWith(quietEnd: time.hour * 60 + time.minute),
      );
    }
  }

  String _minute(int value) =>
      '${(value ~/ 60).toString().padLeft(2, '0')}:${(value % 60).toString().padLeft(2, '0')}';
  Widget _statusMessages() => Semantics(
    key: _statusAnchor,
    container: true,
    liveRegion: _error != null || _message != null,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_busy) ...[
          const LinearProgressIndicator(minHeight: 3),
          const SizedBox(height: 18),
        ],
        if (_error != null) ...[
          SeraNote(
            '这次操作没有完成',
            body: _error,
            icon: 'warning',
            color: SeraColors.amber,
            background: SeraColors.amberBg,
          ),
          const SizedBox(height: 18),
        ],
        if (_message != null) ...[
          SeraNote('操作结果', body: _message, icon: 'check'),
          const SizedBox(height: 18),
        ],
      ],
    ),
  );

  Widget _permissionCard(
    String title,
    String permission, {
    bool showRequest = false,
    VoidCallback? onRequest,
  }) => SeraCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const SeraIcon('shield'),
            const SizedBox(width: 12),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 15))),
            SeraTag(
              permission == 'granted'
                  ? '已授权'
                  : permission == 'unsupported'
                  ? '此设备暂不支持'
                  : '未授权',
              color: permission == 'granted'
                  ? SeraColors.brand
                  : SeraColors.amber,
              background: permission == 'granted'
                  ? SeraColors.mint
                  : SeraColors.amberBg,
            ),
          ],
        ),
        if (showRequest)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: onRequest,
              child: const Text('开启通知权限'),
            ),
          ),
      ],
    ),
  );

  Widget _calendar() {
    final caps = _capabilities;
    final snapshot = _snapshot;
    final native = caps?.calendarSupported ?? false;
    final onboarding = widget.mode == '03';
    final permissionPage = widget.mode == '41';
    final resultsPage = widget.mode == '42';
    return SeraScaffold(
      title: onboarding
          ? '连接日历'
          : permissionPage
          ? caps?.platform == 'web'
                ? '日历文件'
                : '日历权限'
          : resultsPage
          ? '同步结果'
          : '日历与同步',
      actions: [
        IconButton(
          tooltip: '重新检查',
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh_rounded, color: SeraColors.brand),
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (onboarding)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                '第 2 步，共 2 步',
                style: TextStyle(fontSize: 12, color: SeraColors.muted),
              ),
            ),
          _statusMessages(),
          if (caps != null && caps.platform != 'web')
            _permissionCard(
              '设备日历访问',
              native ? caps.calendarPermission : 'unsupported',
            ),
          if (native && caps?.calendarPermission != 'granted') ...[
            const SizedBox(height: 20),
            SeraButton(
              '允许访问设备日历',
              variant: onboarding ? 'secondary' : 'primary',
              onPressed: _busy ? null : _connect,
            ),
            SeraButton(
              '打开系统权限设置',
              variant: 'quiet',
              onPressed: _busy
                  ? null
                  : () => _perform(
                      (_) => platformServices.openApplicationSettings(),
                    ),
            ),
          ],
          if (native && caps?.calendarPermission == 'granted') ...[
            const SeraSection('读取哪些日历？'),
            if (_calendars.where((c) => !c.isSera).isEmpty)
              const SeraNote(
                '没有找到其他日历',
                body: '序日的安排仍可保存到系统日历。',
                icon: 'calendar',
              ),
            for (final calendar in _calendars.where((c) => !c.isSera))
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  calendar.name,
                  style: const TextStyle(fontSize: 14),
                ),
                subtitle: Text(
                  calendar.account,
                  style: const TextStyle(fontSize: 11, color: SeraColors.muted),
                ),
                value: _selected.contains(calendar.id),
                controlAffinity: ListTileControlAffinity.leading,
                onChanged: _busy
                    ? null
                    : (value) => _saveSelection(calendar.id, value ?? false),
              ),
            const SizedBox(height: 18),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动同步已确认的安排', style: TextStyle(fontSize: 14)),
              subtitle: const Text(
                '任务改期、完成和删除后，更新本账户的序日日历。',
                style: TextStyle(fontSize: 12, height: 1.7),
              ),
              value:
                  context
                      .watch<SeraController>()
                      .data
                      .platformSettings['calendarAutoSync'] ==
                  true,
              onChanged: _busy
                  ? null
                  : (enabled) => _perform(
                      (operation) => operation.controller.savePlatformSettings({
                        'calendarAutoSync': enabled,
                        'selectedCalendarIds': _selected.toList(),
                      }),
                    ),
            ),
            if (context.watch<SeraController>().platformError
                case final String error)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: SeraNote(
                  '日历还没有连接成功',
                  body: error,
                  color: SeraColors.amber,
                  background: SeraColors.amberBg,
                ),
              ),
            SeraButton(
              '同步日历',
              icon: 'refresh',
              variant: onboarding ? 'secondary' : 'primary',
              onPressed: _busy ? null : () => _sync(),
            ),
          ],
          if (resultsPage && snapshot.at == null && snapshot.results.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('尚无同步记录', style: TextStyle(color: SeraColors.muted)),
            ),
          if (snapshot.at != null || snapshot.results.isNotEmpty) ...[
            const SeraSection('最近一次同步'),
            SeraCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SeraField('已读取的日程', '${snapshot.busyCount} 项'),
                  SeraField(
                    '同步结果',
                    '${snapshot.results.where((r) => r.success).length} 项成功 / ${snapshot.results.where((r) => !r.success).length} 项失败',
                  ),
                  SeraField(
                    '同步时间',
                    snapshot.at == null
                        ? '尚未执行'
                        : '${formatDate(snapshot.at!)} ${formatTime(snapshot.at!)}',
                  ),
                ],
              ),
            ),
            for (final result in snapshot.results.where((r) => !r.success))
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: SeraNote(
                  switch (context.read<SeraController>().entry(
                    result.sourceId,
                  )) {
                    final entry? => '“${entry.title}”未同步',
                    null => '有一项日程未同步',
                  },
                  body: result.error ?? '设备日历未确认这次操作。',
                  icon: 'warning',
                  color: SeraColors.amber,
                  background: SeraColors.amberBg,
                ),
              ),
            if (snapshot.results.any((r) => !r.success)) ...[
              const SizedBox(height: 18),
              SeraButton(
                '重试未同步的日程',
                onPressed: _busy ? null : () => _sync(retryOnly: true),
              ),
              if (snapshot.results.any(
                (r) =>
                    !r.success &&
                    (r.error?.contains('冲突') == true ||
                        r.error?.contains('外部修改') == true),
              )) ...[
                const SizedBox(height: 10),
                SeraButton(
                  '用序日内容覆盖系统改动',
                  variant: 'ghost',
                  onPressed: _busy ? null : _overwriteCalendarChanges,
                ),
              ],
            ],
          ],
          if (!permissionPage || native) const SeraSection('日历文件'),
          SeraButton(
            '导入日历文件',
            variant: 'secondary',
            icon: 'calendar',
            onPressed: _busy ? null : _importIcs,
          ),
          const SizedBox(height: 12),
          SeraButton(
            '导出我的安排',
            variant: 'secondary',
            icon: 'download',
            onPressed: _busy ? null : _exportIcs,
          ),
        ],
      ),
      footer: onboarding
          ? SeraButton(
              '继续，查看今天',
              onPressed: _busy
                  ? null
                  : () => _perform((operation) async {
                      await operation.controller.savePlatformSettings({
                        'onboardingComplete': true,
                      });
                      if (mounted && _owns(operation, current: true)) {
                        context.go('/04');
                      }
                    }),
            )
          : null,
    );
  }

  Widget _notifications() {
    final caps = _capabilities;
    final p = _notificationPreferences!;
    return SeraScaffold(
      title: widget.mode == '54' ? '开启提醒' : '提醒与免打扰',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _statusMessages(),
          if (caps != null) ...[
            _permissionCard(
              '系统通知权限',
              caps.notificationPermission,
              showRequest: caps.notificationPermission != 'granted',
              onRequest: _busy ? null : _requestNotifications,
            ),
          ],
          const SeraSection('任务提醒'),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('启用任务提醒', style: TextStyle(fontSize: 15)),
            subtitle: const Text(
              '为尚未完成的未来任务安排系统提醒。',
              style: TextStyle(fontSize: 12),
            ),
            value: p.notifications,
            onChanged: _busy
                ? null
                : (value) => setState(
                    () => _notificationPreferences = p.copyWith(
                      notifications: value,
                    ),
                  ),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('未开始时再提醒', style: TextStyle(fontSize: 15)),
            subtitle: const Text(
              '任务开始后仍未处理时，再提醒一次。',
              style: TextStyle(fontSize: 12),
            ),
            value: p.followUp,
            onChanged: _busy
                ? null
                : (value) => setState(
                    () =>
                        _notificationPreferences = p.copyWith(followUp: value),
                  ),
          ),
          const SeraSection('免打扰时段'),
          SeraCard(
            child: Column(
              children: [
                InkWell(
                  onTap: _busy ? null : () => _pickQuiet(true),
                  child: SeraField(
                    '开始',
                    _minute(p.quietStart),
                    valueAlign: TextAlign.end,
                    trailing: const SeraIcon('chevron', size: 16),
                  ),
                ),
                InkWell(
                  onTap: _busy ? null : () => _pickQuiet(false),
                  child: SeraField(
                    '结束',
                    '${p.quietEnd < p.quietStart ? '次日' : ''}${_minute(p.quietEnd)}',
                    valueAlign: TextAlign.end,
                    trailing: const SeraIcon('chevron', size: 16),
                  ),
                ),
              ],
            ),
          ),
          if (caps?.webPushSupported == true) ...[
            const SeraSection('浏览器后台提醒'),
            SeraButton(
              caps!.webPushSubscribed ? '关闭后台提醒' : '开启后台提醒',
              variant: 'secondary',
              onPressed: _busy ? null : () => _setPush(!caps.webPushSubscribed),
            ),
          ],
          if (_schedule != null) ...[
            for (final warning in _schedule!.warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  warning,
                  style: const TextStyle(fontSize: 12, color: SeraColors.amber),
                ),
              ),
            for (final error in _schedule!.errors)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  error,
                  style: const TextStyle(fontSize: 12, color: SeraColors.red),
                ),
              ),
          ],
          const SizedBox(height: 20),
          SeraDisclosure(
            title: '提醒状态与测试',
            summary: '查看已安排的提醒，发送测试提醒',
            children: [
              SeraField('已安排的提醒', _pending == null ? '正在读取…' : '$_pending 条'),
              if (_schedule != null) ...[
                SeraField(
                  '本次安排',
                  '${_schedule!.scheduled} 条已安排 / ${_schedule!.skipped} 条未安排',
                ),
                SeraField(
                  '提醒时间',
                  _schedule!.exact ? '按设定时间提醒' : '可能因系统或浏览器限制而延迟',
                ),
              ],
              const SizedBox(height: 12),
              if (caps?.webPushSupported == true &&
                  caps?.webPushSubscribed == true) ...[
                SeraButton(
                  '测试后台提醒',
                  variant: 'quiet',
                  onPressed: _busy ? null : _testPush,
                ),
                const SizedBox(height: 8),
              ],
              SeraButton(
                '发送一条测试提醒',
                variant: 'quiet',
                onPressed: _busy ? null : _testNotification,
              ),
              const SizedBox(height: 8),
              SeraButton(
                '打开系统或站点设置',
                variant: 'quiet',
                onPressed: _busy
                    ? null
                    : () => _perform(
                        (_) => platformServices.openApplicationSettings(),
                      ),
              ),
            ],
          ),
          if (caps != null &&
              caps.platform == 'android' &&
              !caps.exactAlarmsSupported)
            SeraButton(
              '允许准时提醒',
              variant: 'quiet',
              onPressed: _busy
                  ? null
                  : () => _perform(
                      (_) => platformServices.requestExactAlarmPermission(),
                    ),
            ),
        ],
      ),
      footer: SeraButton(
        '保存设置',
        busy: _busy,
        onPressed: _busy ? null : _saveNotifications,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    context.watch<SeraController>();
    return const {'33', '54'}.contains(widget.mode)
        ? _notifications()
        : _calendar();
  }
}
