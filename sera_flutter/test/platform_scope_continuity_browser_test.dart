@TestOn('browser')
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/platform/platform_web.dart';
import 'package:sera_flutter/platform/platform_services_types.dart';

@JS('globalThis')
external JSObject get _global;
@JS('eval')
external JSAny? _eval(JSString source);

void _js(String source) => _eval(source.toJS);

Future<void> _untilGate() async {
  for (var n = 0; n < 30; n++) {
    final count =
        _eval('globalThis.__seraScopeTest.gates.length'.toJS) as JSNumber;
    if (count.toDartInt > 0) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('The held browser bridge operation did not start.');
}

Workspace _workspace(String account) {
  final start = DateTime.now().add(const Duration(hours: 2));
  return Workspace(
    revision: 2,
    preferences: const SeraPreferences(
      quietStart: 0,
      quietEnd: 0,
      followUp: false,
    ),
    tasks: [SeraTask(id: 'task-$account', title: 'Account $account')],
    entries: [
      CalendarEntry(
        id: 'entry-$account',
        title: 'Account $account',
        taskId: 'task-$account',
        start: start,
        end: start.add(const Duration(minutes: 30)),
      ),
    ],
  );
}

Future<WebPlatformServices> _fixture() async {
  _js(r'''
    (() => {
      const names = ['Notification', 'PushManager', 'seraPlatform'];
      const descriptors = Object.fromEntries(names.map(name => [name, Object.getOwnPropertyDescriptor(globalThis, name)]));
      const fixture = globalThis.__seraScopeTest = {gates: [], snapshots: [], holdSubscription: false, holdWorker: false};
      const held = () => new Promise(resolve => fixture.gates.push(resolve));
      Object.defineProperty(globalThis, 'Notification', {configurable: true, value: {permission: 'granted'}});
      if (!('PushManager' in globalThis)) Object.defineProperty(globalThis, 'PushManager', {configurable: true, value: class {}});
      Object.defineProperty(globalThis, 'seraPlatform', {configurable: true, value: {
        setAccountScope: async () => null,
        subscription: () => {
          if (fixture.holdSubscription) {fixture.holdSubscription = false; return held();}
          return Promise.resolve({endpoint: 'https://isolated.invalid/push'});
        },
        messageWorker: message => {
          fixture.snapshots.push(JSON.parse(JSON.stringify(message)));
          if (fixture.holdWorker) {fixture.holdWorker = false; return held();}
          return Promise.resolve({ok: true});
        }
      }});
      fixture.restore = () => {
        for (const name of names) {
          const original = descriptors[name];
          if (original) Object.defineProperty(globalThis, name, original); else delete globalThis[name];
        }
        delete globalThis.__seraScopeTest;
      };
    })();
  ''');
  final service = WebPlatformServices();
  await service.setAccountScope('continuity-a');
  addTearDown(() async {
    await service.cancelNotifications();
    final storage = _global.getProperty<JSObject>('localStorage'.toJS);
    for (final account in ['continuity-a', 'continuity-b']) {
      final scope = base64Url.encode(utf8.encode(account));
      storage.callMethod<JSAny?>(
        'removeItem'.toJS,
        'sera.platform.reminders.$scope'.toJS,
      );
    }
    _js('globalThis.__seraScopeTest.restore();');
  });
  return service;
}

Matcher get _staleAccount => throwsA(
  isA<PlatformCapabilityException>().having(
    (error) => error.code,
    'scope guard',
    'stale_account',
  ),
);

void main() {
  test('old account reminder generation cannot write into the new account after a held subscription lookup', () async {
    final service = await _fixture();
    _js('globalThis.__seraScopeTest.holdSubscription = true;');
    final old = service.scheduleReminders(_workspace('a'));
    final rejected = expectLater(old, _staleAccount);
    await _untilGate();
    await service.setAccountScope('continuity-b');
    await service.scheduleReminders(_workspace('b'));
    _js('globalThis.__seraScopeTest.gates.shift()(null);');
    await rejected;
    final pending = await service.scheduledNotifications();
    expect(pending.single['taskId'], 'task-b');
    final snapshots = jsonDecode(
      (_eval(
        'JSON.stringify(globalThis.__seraScopeTest.snapshots)'.toJS,
      ) as JSString).toDart,
    ) as List;
    expect(snapshots, hasLength(1));
    expect((snapshots.single as Map)['scope'], 'continuity-b');
    final scope = base64Url.encode(utf8.encode('continuity-b'));
    final storage = _global.getProperty<JSObject>('localStorage'.toJS);
    final stored = storage
        .callMethod<JSString>(
          'getItem'.toJS,
          'sera.platform.reminders.$scope'.toJS,
        )
        .toDart;
    expect(stored, contains('task-b'));
    expect(stored, isNot(contains('task-a')));
  });

  test('an old worker acknowledgement cannot complete or re-arm reminder generation for a new account', () async {
    final service = await _fixture();
    _js('globalThis.__seraScopeTest.holdWorker = true;');
    final rejected = expectLater(
      service.scheduleReminders(_workspace('a')),
      _staleAccount,
    );
    await _untilGate();
    await service.setAccountScope('continuity-b');
    await service.scheduleReminders(_workspace('b'));
    _js('globalThis.__seraScopeTest.gates.shift()({ok: true});');
    await rejected;
    expect((await service.scheduledNotifications()).single['taskId'], 'task-b');
    final snapshots = jsonDecode(
      (_eval(
        'JSON.stringify(globalThis.__seraScopeTest.snapshots)'.toJS,
      ) as JSString).toDart,
    ) as List;
    expect(snapshots.map((item) => (item as Map)['scope']), [
      'continuity-a',
      'continuity-b',
    ]);
  });

  test('a capability lookup started by the previous account is rejected after its scope changes', () async {
    final service = await _fixture();
    _js('globalThis.__seraScopeTest.holdSubscription = true;');
    final rejected = expectLater(service.capabilities(), _staleAccount);
    await _untilGate();
    await service.setAccountScope('continuity-b');
    await service.scheduleReminders(_workspace('b'));
    _js('globalThis.__seraScopeTest.gates.shift()(null);');
    await rejected;
    expect((await service.scheduledNotifications()).single['taskId'], 'task-b');
  });
}
