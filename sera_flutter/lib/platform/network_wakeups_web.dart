import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

@JS('globalThis')
external JSObject get _global;

final StreamController<void> _restored = StreamController<void>.broadcast(
  onListen: () => _global.callMethod<JSAny?>(
    'addEventListener'.toJS,
    'online'.toJS,
    _onOnline,
  ),
  onCancel: () => _global.callMethod<JSAny?>(
    'removeEventListener'.toJS,
    'online'.toJS,
    _onOnline,
  ),
);
final JSFunction _onOnline = (() => _restored.add(null)).toJS;

/// Connectivity is only a wake-up signal. The real request decides whether the
/// server can be reached; an `online` event never marks pending writes as synced.
Stream<void> get networkRestored => _restored.stream;
