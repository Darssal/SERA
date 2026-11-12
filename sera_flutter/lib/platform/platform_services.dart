import 'platform_native.dart'
    if (dart.library.js_interop) 'platform_web.dart'
    as implementation;
import 'platform_services_types.dart';
export 'platform_services_types.dart';
export 'icalendar.dart';
export 'reminder_requests.dart';

/// One platform owner prevents duplicate web timers and microphone streams.
final SeraPlatformServices platformServices = implementation
    .createPlatformServices();
