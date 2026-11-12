import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'account_event_channel_types.dart';

@JS('globalThis')
external JSObject get _global;

@JS('BroadcastChannel')
extension type _BroadcastChannel._(JSObject _) implements JSObject {
  external factory _BroadcastChannel(String name);
  external set onmessage(JSFunction? callback);
  external void postMessage(JSAny? data);
  external void close();
}

AccountEventChannel createAccountEventChannel() => _WebAccountEvents();

class _WebAccountEvents implements AccountEventChannel {
  _WebAccountEvents() {
    if (!_global.has('BroadcastChannel')) return;
    _channel = _BroadcastChannel('sera-account');
    _channel!.onmessage = ((JSObject message) {
      if (_closed) return;
      try {
        final raw = message.getProperty<JSString>('data'.toJS).toDart;
        if (raw.length > 4096) return;
        final event = AccountEvent.fromJson(jsonDecode(raw));
        if (event != null) _events.add(event);
      } catch (_) {
        // Ignore unrelated/malformed messages on this origin-wide channel.
      }
    }).toJS;
  }
  final _events = StreamController<AccountEvent>.broadcast(sync: true);
  _BroadcastChannel? _channel;
  bool _closed = false;
  @override
  Stream<AccountEvent> get events => _events.stream;
  @override
  void publish(AccountEvent event) {
    if (!_closed) _channel?.postMessage(jsonEncode(event.toJson()).toJS);
  }

  @override
  void dispose() {
    _closed = true;
    _channel?.onmessage = null;
    _channel?.close();
    unawaited(_events.close());
  }
}
