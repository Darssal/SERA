import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/domain/seed_data.dart';
import 'package:sera_flutter/ui/core/sera_motion.dart';

// Layout/navigation performance only: seeded memory data, no AuthRepository,
// network, account, native permissions, calendar writes or paid AI requests.
// Host: SERA_ANDROID_QA=1 flutter drive --profile --no-dds
//   --driver=integration_test/feedback_driver.dart
//   --target=integration_test/motion_profile_test.dart
//   -d 127.0.0.1:16416 --keep-app-running
// flutter drive has no --no-uninstall flag; --keep-app-running avoids its
// default stop/uninstall. The isolated QA applicationId remains required.

class _MotionFixtureRepository implements WorkspaceRepository {
  _MotionFixtureRepository(this.value);

  final Workspace value;
  int writeAttempts = 0;

  @override
  String get mode => 'motion-profile-memory-fixture';

  @override
  Future<Workspace?> load() async => value;

  @override
  Future<void> clear() async {
    writeAttempts++;
    throw StateError('The motion fixture must not clear business data.');
  }

  @override
  Future<Workspace> save(
    Workspace workspace, {
    required int expectedRevision,
  }) async {
    writeAttempts++;
    throw StateError('The motion fixture must not save business data.');
  }
}

const _detailRoute = '/18?taskId=task-1';
const _editorRoute = '/09-edit-plan-task?taskId=task-1';
const _preferencesRoute = '/31';
const _settle = Duration(milliseconds: 360);
const _interruptAfter = Duration(milliseconds: 60);
const _sampleRounds = 5;

Future<void> _push(
  GoRouter router,
  IntegrationTestWidgetsFlutterBinding binding,
  String route, {
  Duration dwell = _settle,
}) async {
  // A push future completes after pop, so do not await it before navigating.
  unawaited(router.push<void>(route));
  // Wall-clock waits allow the engine/device to request the animation frames;
  // no synthetic pumpFrames or virtual-clock advance is used for measurement.
  await binding.delayed(dwell);
}

Future<void> _pop(
  GoRouter router,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  expect(
    router.canPop(),
    isTrue,
    reason: 'The fixture navigation stack was lost.',
  );
  router.pop();
  await binding.delayed(_settle);
}

Future<void> _settledRound(
  GoRouter router,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  await _push(router, binding, _detailRoute);
  await _push(router, binding, _editorRoute);
  await _pop(router, binding);
  await _pop(router, binding);
  await _push(router, binding, _preferencesRoute);
  await _pop(router, binding);
}

Future<void> _interruptedRound(
  GoRouter router,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  for (final route in [_detailRoute, _editorRoute, _preferencesRoute]) {
    await _push(router, binding, route, dwell: _interruptAfter);
    await _pop(router, binding);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // This SDK policy respects real animation frame requests and ignores pumps,
  // matching the SDK's own macrobenchmark fixture setup.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;

  testWidgets('profile seeded today, task, editor and preference transitions', (
    tester,
  ) async {
    expect(
      kProfileMode,
      isTrue,
      reason: 'Run this sample with flutter drive --profile.',
    );
    expect(
      defaultTargetPlatform,
      TargetPlatform.android,
      reason: 'This bounded sample is intended for the selected MuMu1 Android device.',
    );

    final today = DateTime(2026, 10, 31);
    final repository = _MotionFixtureRepository(
      createSeedWorkspace(today).copyWith(revision: 1),
    );
    final controller = SeraController(
      repository: repository,
      today: today,
      accountId: 'qa-motion-fixture',
      seedDemo: false,
    );
    const platformChannel = MethodChannel('com.sera/platform');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(platformChannel, (
      call,
    ) async {
      if (call.method == 'consumeInitialNotificationRoute') return null;
      throw StateError(
        'Native business operations are outside the motion fixture.',
      );
    });

    try {
      await controller.initialize();
      await tester.pumpWidget(
        SeraApp(controller: controller, initialLocation: '/04'),
      );
      await binding.delayed(const Duration(seconds: 1));
      final context = tester.element(find.byType(Scaffold).first);
      final router = GoRouter.of(context);
      final view = View.of(context);
      final media = MediaQuery.of(context);
      final reducedMotion = SeraMotion.reduced(context);
      binding.reportData = {
        'sample': {
          'mode': 'profile',
          'platform': 'Android',
          'deviceSelection': 'Host must select MuMu1 / 127.0.0.1:16416',
          'dataSource': 'in-memory seeded layout fixture',
          'fixtureDate': '2026-10-31',
          'businessFlowVerified': false,
          'networkRequests': 0,
          'paidAiCalls': 0,
          'logicalWidth': media.size.width,
          'logicalHeight': media.size.height,
          'devicePixelRatio': view.devicePixelRatio,
          'displayRefreshRateHz': view.display.refreshRate,
          'textScaleAt14px': media.textScaler.scale(14) / 14,
          'reducedMotion': reducedMotion,
          'framePolicy': 'benchmarkLive',
          'warmupRounds': 1,
          'measuredRoundsPerScenario': _sampleRounds,
          'settledDwellMs': _settle.inMilliseconds,
          'requestedBackDelayMs': _interruptAfter.inMilliseconds,
          'sdkSummaryBudgetMs': 16,
          'scope':
              'Recorded build/raster timings for these fixture transitions only; '
              'not display presentation FPS or an all-page performance guarantee.',
        },
      };
      expect(
        reducedMotion,
        isFalse,
        reason: 'Normal-motion profiling requires the existing device setting to allow animations.',
      );

      // Warm fonts, SVGs, route construction and the three page types before
      // collecting the explicitly labelled warm sample.
      await _settledRound(router, binding);
      expect(find.byType(TextFormField), findsNothing);
      expect(router.canPop(), isFalse);

      await binding.watchPerformance(() async {
        for (var round = 0; round < _sampleRounds; round++) {
          await _settledRound(router, binding);
        }
        await binding.delayed(const Duration(milliseconds: 1200));
      }, reportKey: 'settled_route_transitions');

      await binding.watchPerformance(() async {
        for (var round = 0; round < _sampleRounds; round++) {
          await _interruptedRound(router, binding);
        }
        await binding.delayed(const Duration(milliseconds: 1200));
      }, reportKey: 'interrupted_route_transitions');

      expect(router.canPop(), isFalse);
      expect(find.byType(TextFormField), findsNothing);
      expect(repository.writeAttempts, 0);
      expect(controller.data.revision, 1);
      expect(tester.takeException(), isNull);
      binding.reportData!['fixtureWrites'] = repository.writeAttempts;
      binding.reportData!['returnedToToday'] = true;
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await binding.delayed(const Duration(milliseconds: 200));
      controller.dispose();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        platformChannel,
        null,
      );
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
