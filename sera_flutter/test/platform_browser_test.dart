@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/platform/platform_web.dart';
import 'package:sera_flutter/platform/platform_services_types.dart';

void main() {
  test(
    'Web implementation compiles and reports device calendar limits',
    () async {
      final service = WebPlatformServices();
      final caps = await service.capabilities();
      expect(caps.platform, 'web');
      expect(caps.calendarSupported, isFalse);
      await expectLater(
        service.listCalendars(),
        throwsA(
          isA<PlatformCapabilityException>().having(
            (e) => e.code,
            'code',
            'unsupported',
          ),
        ),
      );
    },
  );
}
