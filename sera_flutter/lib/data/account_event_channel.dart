import 'account_event_channel_native.dart'
    if (dart.library.js_interop) 'account_event_channel_web.dart'
    as platform;
import 'account_event_channel_types.dart';

export 'account_event_channel_types.dart';

AccountEventChannel createAccountEventChannel() =>
    platform.createAccountEventChannel();
