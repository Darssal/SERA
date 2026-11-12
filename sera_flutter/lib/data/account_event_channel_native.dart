import 'dart:async';

import 'account_event_channel_types.dart';

AccountEventChannel createAccountEventChannel() => _NoAccountEvents();

class _NoAccountEvents implements AccountEventChannel {
  @override
  Stream<AccountEvent> get events => const Stream.empty();
  @override
  void publish(AccountEvent event) {}
  @override
  void dispose() {}
}
