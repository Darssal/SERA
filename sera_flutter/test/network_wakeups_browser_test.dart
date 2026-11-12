@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/platform/network_wakeups.dart';

@JS('globalThis')
external JSObject get _global;

@JS('Event')
extension type _Event._(JSObject _) implements JSObject {
  external _Event(String type);
}

void main() {
  test(
    'only online wakes sync and cancelled owners receive no events',
    () async {
      var calls = 0;
      final subscription = networkRestored.listen((_) => calls++);
      _global.callMethod<JSAny?>('dispatchEvent'.toJS, _Event('offline'));
      await Future<void>.delayed(Duration.zero);
      expect(calls, 0);
      _global.callMethod<JSAny?>('dispatchEvent'.toJS, _Event('online'));
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      await subscription.cancel();
      _global.callMethod<JSAny?>('dispatchEvent'.toJS, _Event('online'));
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      final next = networkRestored.first;
      _global.callMethod<JSAny?>('dispatchEvent'.toJS, _Event('online'));
      await next.timeout(const Duration(seconds: 2));
    },
  );
}
