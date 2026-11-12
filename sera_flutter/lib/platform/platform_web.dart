import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../domain/models.dart';
import 'platform_services_types.dart';
import 'reminder_requests.dart';

@JS('globalThis')
external JSObject get _global;
@JS('document')
external JSObject get _document;
@JS('navigator')
external JSObject get _navigator;

SeraPlatformServices createPlatformServices() => WebPlatformServices();

class WebPlatformServices implements SeraPlatformServices {
  WebPlatformServices() {
    _document.callMethod<JSAny?>(
      'addEventListener'.toJS,
      'visibilitychange'.toJS,
      (() {
        if (_document.getProperty<JSString>('visibilityState'.toJS).toDart ==
                'visible' &&
            !_pushActive) {
          _armTimers();
        }
      }).toJS,
    );
  }
  String _userId = 'signed-out';
  int _quietStart = 1320, _quietEnd = 480;
  bool _pushActive = false;
  bool _scopeReady = false;
  int _scopeOperation = 0;
  void _assertScope(int operation, String userId) {
    if (operation != _scopeOperation || userId != _userId) {
      throw const PlatformCapabilityException(
        'stale_account',
        '账户已切换，旧账户的平台操作已停止。',
      );
    }
  }

  StreamController<Uint8List>? _pcmController;
  bool get _pushSupported =>
      _global.has('PushManager') &&
      _navigator.has('serviceWorker') &&
      _global.has('seraPlatform');
  bool get _pcmSupported =>
      _global.has('AudioWorkletNode') &&
      _navigator.has('mediaDevices') &&
      _global.has('seraPlatform');
  JSObject get _bridge => _global.getProperty<JSObject>('seraPlatform'.toJS);
  Future<JSAny?> _bridgeCall(
    String method, [
    List<JSAny?> args = const [],
  ]) async {
    if (!_global.has('seraPlatform')) {
      throw const PlatformCapabilityException(
        'bridge_missing',
        '浏览器平台脚本未加载，请刷新或重新构建 Web 文件。',
      );
    }
    try {
      return await _bridge
          .callMethodVarArgs<JSPromise<JSAny?>>(method.toJS, args)
          .toDart;
    } catch (e) {
      throw PlatformCapabilityException('browser_platform_failed', '$e');
    }
  }

  final _routes = StreamController<String>.broadcast();
  @override
  Stream<String> get notificationRoutes => _routes.stream;
  @override
  Future<String?> consumeInitialNotificationRoute() async => null;
  String _scope = 'signed-out';
  final _timers = <Timer>[];
  final _visibleNotifications = <JSObject>[];
  List<Map<String, dynamic>> _pending = [];
  JSObject? _stream, _recorder;
  int _recordOperation = 0;
  bool _recordOpening = false;
  Completer<RecordedAudio>? _audioResult;
  final _chunks = <JSAny?>[];
  final _recordWatch = Stopwatch();
  Timer? _recordLimit;
  bool _cancelled = false;
  String? _recordError;
  int _audioBytes = 0;
  String _mime = 'audio/webm';
  bool get _notifications => _global.has('Notification');
  bool get _recordSupported =>
      _global.has('MediaRecorder') &&
      _navigator.has('mediaDevices') &&
      _recordMime() != null;
  JSObject get _notificationClass =>
      _global.getProperty<JSObject>('Notification'.toJS);
  String get _notificationPermission => !_notifications
      ? 'unsupported'
      : _notificationClass.getProperty<JSString>('permission'.toJS).toDart ==
            'granted'
      ? 'granted'
      : 'denied';
  PlatformCapabilityException _unsupported(String capability) =>
      PlatformCapabilityException(
        'unsupported',
        'Web 无法直接$capability。设备日历请使用 ICS 文件导入/导出；关闭页面后的提醒需另行开启浏览器 Web Push。',
      );

  @override
  Future<void> setAccountScope(String userId) async {
    final next = base64Url.encode(
      utf8.encode(userId.isEmpty ? 'signed-out' : userId),
    );
    if (next == _scope && _scopeReady) return;
    final operation = ++_scopeOperation;
    void assertCurrent() {
      if (operation != _scopeOperation) {
        throw const PlatformCapabilityException(
          'stale_account',
          '账户已切换，旧账户平台初始化已取消。',
        );
      }
    }

    _scopeReady = false;
    _clearTimers();
    await stopAudioStream(cancel: true);
    assertCurrent();
    await cancelRecording();
    assertCurrent();
    for (final notification in _visibleNotifications) {
      try {
        notification.callMethod<JSAny?>('close'.toJS);
      } catch (_) {}
    }
    _visibleNotifications.clear();
    _scope = next;
    _userId = userId.isEmpty ? 'signed-out' : userId;
    if (_global.has('seraPlatform')) {
      await _bridgeCall('setAccountScope', [_userId.toJS]);
    }
    assertCurrent();
    _scopeReady = true;
    _pending = _readStored();
    final subscribed = await currentWebPushSubscription() != null;
    assertCurrent();
    _pushActive = subscribed;
    if (_notificationPermission == 'granted' && !_pushActive) _armTimers();
  }

  Future<String> _microphonePermission() async {
    if (!_recordSupported && !_pcmSupported) return 'unsupported';
    try {
      if (!_navigator.has('permissions')) return 'denied';
      final permissions = _navigator.getProperty<JSObject>('permissions'.toJS);
      final result = await permissions
          .callMethod<JSPromise<JSObject>>(
            'query'.toJS,
            {'name': 'microphone'}.jsify(),
          )
          .toDart;
      return result.getProperty<JSString>('state'.toJS).toDart == 'granted'
          ? 'granted'
          : 'denied';
    } catch (_) {
      return 'denied';
    }
  }

  @override
  Future<PlatformCapabilities> capabilities() async {
    final operation = _scopeOperation, userId = _userId;
    final subscribed = await currentWebPushSubscription() != null;
    _assertScope(operation, userId);
    final microphonePermission = await _microphonePermission();
    _assertScope(operation, userId);
    _pushActive = subscribed;
    return PlatformCapabilities(
      platform: 'web',
      calendarSupported: false,
      notificationsSupported: _notifications,
      backgroundNotifications: subscribed,
      recordingSupported: _recordSupported || _pcmSupported,
      calendarPermission: 'unsupported',
      notificationPermission: _notificationPermission,
      microphonePermission: microphonePermission,
      exactAlarmsSupported: false,
      webPushSupported: _pushSupported,
      webPushSubscribed: subscribed,
    );
  }

  @override
  Future<String> requestCalendarPermission() async =>
      throw _unsupported('请求设备日历权限');
  @override
  Future<String> requestNotificationPermission() async {
    if (!_notifications) {
      throw const PlatformCapabilityException(
        'unsupported',
        '当前浏览器没有 Notification API；请在支持该能力的桌面 Chrome/Edge 站点中使用。',
      );
    }
    try {
      final result = await _notificationClass
          .callMethod<JSPromise<JSString>>('requestPermission'.toJS)
          .toDart;
      return result.toDart == 'granted' ? 'granted' : 'denied';
    } catch (_) {
      throw const PlatformCapabilityException(
        'notification_denied',
        '浏览器未授予通知权限。请使用 HTTPS/localhost，并在地址栏站点设置中开启通知。',
      );
    }
  }

  @override
  Future<String> requestMicrophonePermission() async {
    if (!_recordSupported && !_pcmSupported) {
      throw const PlatformCapabilityException(
        'unsupported',
        '当前浏览器不能生成 WAV/WebM 录音。请使用支持 MediaRecorder 的 Chrome/Edge，并通过 HTTPS 或 localhost 访问。',
      );
    }
    JSObject? stream;
    try {
      stream = await _getStream();
      return 'granted';
    } catch (_) {
      return 'denied';
    } finally {
      if (stream != null) _stopTracks(stream);
    }
  }

  @override
  Future<void> openApplicationSettings() async =>
      throw const PlatformCapabilityException(
        'unsupported',
        '浏览器不允许网页打开系统或站点权限设置。请点击地址栏站点图标，手动修改通知或麦克风权限，再返回重试。',
      );
  @override
  Future<void> requestExactAlarmPermission() async =>
      throw _unsupported('申请 Android 精确闹钟权限');
  @override
  Future<List<PlatformCalendar>> listCalendars() async =>
      throw _unsupported('列出设备日历');
  @override
  Future<List<ExternalBusyEvent>> readBusyEvents(
    List<String> calendarIds,
    DateTime start,
    DateTime end,
  ) async => throw _unsupported('读取设备日历');
  @override
  Future<PlatformCalendar> ensureSeraCalendar() async =>
      throw _unsupported('创建系统日历');
  @override
  Future<List<PlatformSyncResult>> syncCalendarEntries(
    List<CalendarEntry> entries, {
    bool deleteMissing = true,
    bool overwriteConflicts = false,
  }) async => throw _unsupported('自动同步系统日历');

  String get _storageKey => 'sera.platform.reminders.$_scope';
  JSObject get _storage => _global.getProperty<JSObject>('localStorage'.toJS);
  List<Map<String, dynamic>> _readStored() {
    try {
      final raw = _storage
          .callMethod<JSString?>('getItem'.toJS, _storageKey.toJS)
          ?.toDart;
      return raw == null
          ? []
          : (jsonDecode(raw) as List)
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
    } catch (_) {
      return [];
    }
  }

  void _store() {
    try {
      _storage.callMethod<JSAny?>(
        'setItem'.toJS,
        _storageKey.toJS,
        jsonEncode(_pending).toJS,
      );
    } catch (_) {
      throw const PlatformCapabilityException(
        'storage_unavailable',
        '浏览器禁止本地存储，无法保存提醒。请调整站点设置后重试。',
      );
    }
  }

  void _clearTimers() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
  }

  Future<void> _show(
    String title,
    String body, {
    String route = '/27',
    String id = 'test',
  }) async {
    if (_notificationPermission != 'granted') {
      throw const PlatformCapabilityException(
        'notification_denied',
        '通知权限未开启。',
      );
    }
    await _bridgeCall('showNotification', [
      title.toJS,
      body.toJS,
      route.toJS,
      id.toJS,
    ]);
  }

  void _armTimers() {
    _clearTimers();
    if (_pushActive || _notificationPermission != 'granted') return;
    final activeScope = _scope;
    final now = DateTime.now().millisecondsSinceEpoch;
    _pending.removeWhere(
      (e) =>
          (e['validUntil'] as num? ?? (e['fireAt'] as num) + 3600000).toInt() <=
          now,
    );
    for (final request in _pending) {
      final wait = ((request['fireAt'] as num).toInt() - now).clamp(
        0,
        86400000,
      );
      _timers.add(
        Timer(Duration(milliseconds: wait), () {
          if (_scope != activeScope || _pushActive) return;
          if ((request['fireAt'] as num).toInt() >
              DateTime.now().millisecondsSinceEpoch) {
            _armTimers();
            return;
          }
          unawaited(_deliver(request, activeScope));
        }),
      );
    }
  }

  Future<void> _deliver(Map<String, dynamic> request, String scope) async {
    if (request['delivering'] == true ||
        !_pending.contains(request) ||
        _scope != scope) {
      return;
    }
    final now = inTimeZone(
      DateTime.now(),
      request['timeZone'] as String? ?? 'Asia/Hong_Kong',
    );
    final quietStart = (request['quietStart'] as num?)?.toInt() ?? _quietStart;
    final quietEnd = (request['quietEnd'] as num?)?.toInt() ?? _quietEnd;
    if (isQuietMinute(now.hour * 60 + now.minute, quietStart, quietEnd)) {
      final offset =
          quietStart > quietEnd && now.hour * 60 + now.minute >= quietStart
          ? 1
          : 0;
      request['fireAt'] = atMinute(
        calendarDay(now, offset),
        quietEnd,
      ).millisecondsSinceEpoch;
      _store();
      _armTimers();
      return;
    }
    request['delivering'] = true;
    try {
      await _show(
        request['title'] as String,
        request['body'] as String,
        route: request['route'] as String? ?? '/27',
        id: request['id'] as String,
      );
    } catch (error) {
      if (_scope != scope) return;
      try {
        _storage.callMethod<JSAny?>(
          'setItem'.toJS,
          'sera.platform.delivery-error.$_scope'.toJS,
          jsonEncode({
            'error': '$error',
            'id': request['id'],
            'at': DateTime.now().toIso8601String(),
          }).toJS,
        );
      } catch (_) {}
    } finally {
      if (_scope == scope) {
        _pending.remove(request);
        _store();
      }
    }
  }

  @override
  Future<NotificationScheduleResult> scheduleReminders(
    Workspace workspace,
  ) async {
    final operation = _scopeOperation, userId = _userId;
    final built = buildReminderRequests(workspace);
    if (workspace.preferences.notifications &&
        _notificationPermission != 'granted') {
      await cancelNotifications();
      _assertScope(operation, userId);
      throw const PlatformCapabilityException(
        'notification_denied',
        '浏览器通知权限未开启，未注册提醒。站内任务仍然可用。',
      );
    }
    final subscribed = await currentWebPushSubscription() != null;
    _assertScope(operation, userId);
    _quietStart = workspace.preferences.quietStart;
    _quietEnd = workspace.preferences.quietEnd;
    _pushActive = subscribed;
    _pending = built.requests;
    _store();
    if (_global.has('seraPlatform')) {
      await _bridgeCall('messageWorker', [
        {
          'type': 'reminder-snapshot',
          'scope': userId,
          'snapshot': {
            'revision': workspace.revision,
            'ids': built.requests.map((e) => e['id']).toList(),
          },
        }.jsify(),
      ]);
      _assertScope(operation, userId);
    }
    _armTimers();
    return NotificationScheduleResult(
      scheduled: _pending.length,
      skipped: built.skipped,
      exact: false,
      warnings: [
        _pushActive
            ? '浏览器已存在 Push 订阅；后台任务由已登录服务端持久调度，系统省电或权限会影响展示。'
            : '尚未开启 Web Push，提醒仅在本站保持打开时运行；可在通知设置中开启关闭页面后的后台提醒。',
      ],
    );
  }

  @override
  Future<void> showTestNotification() async =>
      _show('序日提醒测试', '这是一条由浏览器 Notification API 实际展示的测试提醒。');
  @override
  Future<void> cancelNotifications() async {
    _clearTimers();
    _pending = [];
    _store();
    for (final n in _visibleNotifications) {
      try {
        n.callMethod<JSAny?>('close'.toJS);
      } catch (_) {}
    }
    _visibleNotifications.clear();
  }

  @override
  Future<List<Map<String, dynamic>>> scheduledNotifications() async =>
      List.unmodifiable(_pending);

  @override
  Future<String?> pickIcsFile() async {
    final completer = Completer<String?>();
    final input = _document.callMethod<JSObject>(
      'createElement'.toJS,
      'input'.toJS,
    );
    input['type'] = 'file'.toJS;
    input['accept'] = '.ics,text/calendar'.toJS;
    input.getProperty<JSObject>('style'.toJS)['display'] = 'none'.toJS;
    void cleanup() {
      input.callMethod<JSAny?>('remove'.toJS);
    }

    input['oncancel'] = ((JSAny? _) {
      if (!completer.isCompleted) {
        cleanup();
        completer.complete(null);
      }
    }).toJS;
    Future<void> readSelectedFile() async {
      try {
        final files = input.getProperty<JSObject?>('files'.toJS);
        if (files == null ||
            files.getProperty<JSNumber>('length'.toJS).toDartInt == 0) {
          completer.complete(null);
          return;
        }
        final file = files.getProperty<JSObject>('0'.toJS);
        if (file.getProperty<JSNumber>('size'.toJS).toDartInt >
            4 * 1024 * 1024) {
          throw const PlatformCapabilityException(
            'file_too_large',
            'ICS 文件不能超过 4 MiB。',
          );
        }
        final text = await file
            .callMethod<JSPromise<JSString>>('text'.toJS)
            .toDart;
        completer.complete(text.toDart);
      } catch (e) {
        completer.completeError(
          e is PlatformCapabilityException
              ? e
              : const PlatformCapabilityException(
                  'file_read_failed',
                  '无法读取选中的 ICS 文件。',
                ),
        );
      } finally {
        cleanup();
      }
    }

    input['onchange'] = ((JSAny? _) {
      unawaited(readSelectedFile());
    }).toJS;
    _document
        .getProperty<JSObject>('body'.toJS)
        .callMethod<JSAny?>('appendChild'.toJS, input);
    input.callMethod<JSAny?>('click'.toJS);
    return completer.future;
  }

  @override
  Future<void> downloadIcs(
    String content, {
    String filename = 'sera-calendar.ics',
  }) => downloadText(
    content,
    filename: filename,
    mimeType: 'text/calendar;charset=utf-8',
  );
  @override
  Future<void> downloadText(
    String content, {
    required String filename,
    String mimeType = 'application/json',
  }) async {
    if (utf8.encode(content).length > 10 * 1024 * 1024) {
      throw const PlatformCapabilityException(
        'file_too_large',
        '导出文件不能超过 10 MiB。',
      );
    }
    final blob = _global
        .getProperty<JSFunction>('Blob'.toJS)
        .callAsConstructor<JSObject>(
          [content.toJS].toJS,
          {'type': mimeType}.jsify(),
        );
    final urls = _global.getProperty<JSObject>('URL'.toJS);
    final url = urls.callMethod<JSString>('createObjectURL'.toJS, blob);
    final anchor = _document.callMethod<JSObject>(
      'createElement'.toJS,
      'a'.toJS,
    );
    anchor['href'] = url;
    anchor['download'] = filename
        .replaceAll(RegExp(r'[\\/\x00-\x1f]'), '_')
        .toJS;
    _document
        .getProperty<JSObject>('body'.toJS)
        .callMethod<JSAny?>('appendChild'.toJS, anchor);
    anchor.callMethod<JSAny?>('click'.toJS);
    anchor.callMethod<JSAny?>('remove'.toJS);
    Timer(
      const Duration(seconds: 1),
      () => urls.callMethod<JSAny?>('revokeObjectURL'.toJS, url),
    );
  }

  String? _recordMime() {
    if (!_global.has('MediaRecorder')) return null;
    final ctor = _global.getProperty<JSObject>('MediaRecorder'.toJS);
    for (final mime in ['audio/webm;codecs=opus', 'audio/webm', 'audio/wav']) {
      try {
        if (ctor
            .callMethod<JSBoolean>('isTypeSupported'.toJS, mime.toJS)
            .toDart) {
          return mime;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<JSObject> _getStream() async => await _navigator
      .getProperty<JSObject>('mediaDevices'.toJS)
      .callMethod<JSPromise<JSObject>>(
        'getUserMedia'.toJS,
        {'audio': true, 'video': false}.jsify(),
      )
      .toDart;
  void _stopTracks(JSObject stream) {
    final tracks = stream
        .callMethod<JSArray<JSObject>>('getTracks'.toJS)
        .toDart;
    for (final track in tracks) {
      track.callMethod<JSAny?>('stop'.toJS);
    }
  }

  void _stopRecorder() {
    _recordLimit?.cancel();
    _recordWatch.stop();
    final recorder = _recorder;
    if (recorder != null &&
        recorder.getProperty<JSString>('state'.toJS).toDart != 'inactive') {
      recorder.callMethod<JSAny?>('stop'.toJS);
    }
    if (_stream != null) {
      _stopTracks(_stream!);
      _stream = null;
    }
  }

  @override
  Future<void> startRecording() async {
    if (_recorder != null || _recordOpening || _pcmController != null) {
      throw const PlatformCapabilityException(
        'recording_busy',
        '已有录音正在进行，请先完成或取消。',
      );
    }
    final mime = _recordMime();
    if (!_recordSupported || mime == null) {
      throw const PlatformCapabilityException(
        'unsupported',
        '当前浏览器不能录制 WAV/WebM 音频，请使用 HTTPS/localhost 下的 Chrome/Edge。',
      );
    }
    final operation = ++_recordOperation;
    _recordOpening = true;
    try {
      final stream = await _getStream();
      if (operation != _recordOperation) {
        _stopTracks(stream);
        throw const PlatformCapabilityException('cancelled', '已取消录音。');
      }
      _stream = stream;
      _mime = mime;
      _chunks.clear();
      _cancelled = false;
      _recordError = null;
      _audioBytes = 0;
      _audioResult = Completer<RecordedAudio>();
      unawaited(
        _audioResult!.future.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        ),
      );
      final recorder = _global
          .getProperty<JSFunction>('MediaRecorder'.toJS)
          .callAsConstructor<JSObject>(_stream!, {'mimeType': mime}.jsify());
      _recorder = recorder;
      recorder['ondataavailable'] = ((JSObject event) {
        final blob = event.getProperty<JSObject>('data'.toJS);
        final size = blob.getProperty<JSNumber>('size'.toJS).toDartInt;
        _audioBytes += size;
        if (_audioBytes > 10 * 1024 * 1024) {
          _recordError = '录音超过 10 MiB 上限，请缩短录音。';
          _stopRecorder();
          return;
        }
        if (size > 0) _chunks.add(blob);
      }).toJS;
      recorder['onerror'] = ((JSAny? _) {
        _recordError = '浏览器录音失败，请检查麦克风是否被其他应用占用。';
        _stopRecorder();
      }).toJS;
      Future<void> finishRecording() async {
        try {
          _recordWatch.stop();
          if (_cancelled) {
            throw const PlatformCapabilityException(
              'cancelled',
              '已取消录音，音频已丢弃。',
            );
          }
          if (_recordError != null) {
            throw PlatformCapabilityException(
              'recording_failed',
              _recordError!,
            );
          }
          final blob = _global
              .getProperty<JSFunction>('Blob'.toJS)
              .callAsConstructor<JSObject>(
                _chunks.toJS,
                {'type': _mime}.jsify(),
              );
          final buffer = await blob
              .callMethod<JSPromise<JSArrayBuffer>>('arrayBuffer'.toJS)
              .toDart;
          final bytes = buffer.toDart.asUint8List();
          if (bytes.isEmpty) {
            throw const PlatformCapabilityException(
              'empty_audio',
              '麦克风未产生可用音频，请重试。',
            );
          }
          _audioResult!.complete(
            RecordedAudio(
              bytes: Uint8List.fromList(bytes),
              mimeType: _mime,
              fileName: _mime.contains('wav')
                  ? 'sera-recording.wav'
                  : 'sera-recording.webm',
              durationMilliseconds: _recordWatch.elapsedMilliseconds,
            ),
          );
        } catch (e) {
          if (!(_audioResult?.isCompleted ?? true)) {
            _audioResult!.completeError(e);
          }
        } finally {
          _recordLimit?.cancel();
          if (_stream != null) {
            _stopTracks(_stream!);
            _stream = null;
          }
          _recorder = null;
          _chunks.clear();
        }
      }

      recorder['onstop'] = ((JSAny? _) {
        unawaited(finishRecording());
      }).toJS;
      _recordWatch
        ..reset()
        ..start();
      recorder.callMethod<JSAny?>('start'.toJS, 1000.toJS);
      _recordLimit = Timer(const Duration(seconds: 60), _stopRecorder);
    } catch (e) {
      if (operation == _recordOperation && _stream != null) {
        _stopTracks(_stream!);
        _stream = null;
      }
      if (operation == _recordOperation) _recorder = null;
      if (e is PlatformCapabilityException) rethrow;
      throw const PlatformCapabilityException(
        'microphone_denied',
        '无法使用麦克风，请在站点设置中授予权限，并检查设备是否被占用。',
      );
    } finally {
      if (operation == _recordOperation) _recordOpening = false;
    }
  }

  @override
  Future<RecordedAudio> stopRecording() async {
    if (_audioResult == null) {
      throw const PlatformCapabilityException('not_recording', '尚未开始录音。');
    }
    _stopRecorder();
    return _audioResult!.future;
  }

  @override
  Future<void> cancelRecording() async {
    _recordOperation++;
    _recordOpening = false;
    if (_recorder == null) {
      _audioResult = null;
      return;
    }
    _cancelled = true;
    _stopRecorder();
    try {
      await _audioResult?.future;
    } catch (_) {}
    _audioResult = null;
  }

  @override
  Future<Map<String, dynamic>?> currentWebPushSubscription() async {
    if (!_pushSupported) return null;
    try {
      final result = await _bridgeCall('subscription');
      return result == null
          ? null
          : Map<String, dynamic>.from(result.dartify() as Map);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>> subscribeWebPush(String vapidPublicKey) async {
    final operation = _scopeOperation, userId = _userId;
    if (!_pushSupported) {
      throw const PlatformCapabilityException(
        'unsupported',
        '浏览器不支持 Web Push，请使用 HTTPS/localhost，iOS 请从已添加到主屏幕的应用打开。',
      );
    }
    final result = await _bridgeCall('subscribePush', [vapidPublicKey.toJS]);
    _assertScope(operation, userId);
    if (result == null) {
      throw const PlatformCapabilityException(
        'push_subscribe_failed',
        '浏览器没有创建推送订阅。',
      );
    }
    _pushActive = true;
    _clearTimers();
    return Map<String, dynamic>.from(result.dartify() as Map);
  }

  @override
  Future<void> unsubscribeWebPush() async {
    final operation = _scopeOperation, userId = _userId;
    if (_pushSupported) await _bridgeCall('unsubscribePush');
    _assertScope(operation, userId);
    _pushActive = false;
    _armTimers();
  }

  @override
  Stream<Uint8List> startAudioStream() {
    if (_pcmController != null || _recorder != null || _recordOpening) {
      return Stream.error(
        const PlatformCapabilityException('recording_busy', '已有录音正在运行。'),
      );
    }
    final controller = StreamController<Uint8List>();
    _pcmController = controller;
    controller.onListen = () async {
      try {
        if (!_pcmSupported) {
          throw const PlatformCapabilityException(
            'audio_unsupported',
            '实时语音需要 HTTPS/localhost 与 AudioWorklet 支持。',
          );
        }
        await _bridgeCall('startPcm', [
          ((JSUint8Array bytes) {
            if (!controller.isClosed) {
              controller.add(Uint8List.fromList(bytes.toDart));
            }
          }).toJS,
          ((JSString message) {
            if (!controller.isClosed) {
              controller.addError(
                PlatformCapabilityException(
                  'audio_stream_failed',
                  message.toDart,
                ),
              );
            }
          }).toJS,
          (() {
            if (identical(_pcmController, controller)) _pcmController = null;
            if (!controller.isClosed) unawaited(controller.close());
          }).toJS,
        ]);
      } catch (error, stack) {
        if (!controller.isClosed) {
          controller.addError(error, stack);
          unawaited(controller.close());
        }
        if (identical(_pcmController, controller)) _pcmController = null;
      }
    };
    controller.onCancel = () => stopAudioStream(cancel: true);
    return controller.stream;
  }

  @override
  Future<void> stopAudioStream({bool cancel = false}) async {
    final controller = _pcmController;
    _pcmController = null;
    if (controller == null) return;
    try {
      await _bridgeCall('stopPcm', [cancel.toJS]);
    } finally {
      if (!controller.isClosed) unawaited(controller.close());
    }
  }
}
