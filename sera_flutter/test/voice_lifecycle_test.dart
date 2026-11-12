import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:sera_flutter/ui/screens/voice_screens.dart';

const _channel = MethodChannel('com.sera/platform');

void main() {
  testWidgets(
    'late recording cancellation cannot navigate over a newer route',
    (tester) async {
      final cancel = Completer<void>();
      var cancelCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (call.method == 'cancelRecording') {
              cancelCalls++;
              await cancel.future;
            }
            return null;
          });
      addTearDown(() {
        if (!cancel.isCompleted) cancel.complete();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, null);
      });
      final auth = AuthRepository(apiBaseUrl: 'http://voice-lifecycle.invalid');
      auth.session = AuthSession(
        token: 'fixture',
        sessionId: 'fixture-session',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        user: const AuthUser(
          id: 'voice-fixture',
          username: 'fixture',
          email: 'fixture@example.invalid',
        ),
      );
      final router = GoRouter(
        initialLocation: '/50',
        routes: [
          GoRoute(path: '/50', builder: (_, _) => const VoiceInputScreen()),
          GoRoute(
            path: '/04',
            builder: (_, _) => const Scaffold(body: Text('Today')),
          ),
          GoRoute(
            path: '/covered',
            builder: (_, _) => const Scaffold(body: Text('Newer route')),
          ),
        ],
      );
      addTearDown(router.dispose);
      addTearDown(auth.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: auth,
          child: MaterialApp.router(theme: seraTheme(), routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      final back = find.widgetWithText(SeraButton, '返回今天');
      await tester.ensureVisible(back);
      await tester.tap(back);
      for (var i = 0; i < 30 && cancelCalls == 0; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(cancelCalls, 1);
      await tester.pump();
      final record = tester.widget<SeraButton>(
        find.widgetWithText(SeraButton, '开始录音'),
      );
      expect(record.busy, isTrue);
      expect(record.onPressed, isNull);
      unawaited(router.push<void>('/covered'));
      await tester.pumpAndSettle();
      cancel.complete();
      await tester.pumpAndSettle();
      expect(find.text('Newer route'), findsOneWidget);
      expect(router.state.uri.path, '/covered');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
  for (final fail in [false, true]) {
    testWidgets(
      'covered file recording ignores late ${fail ? 'failure' : 'success'} and can be used again',
      (tester) async {
        final start = Completer<void>();
        final methods = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, (call) async {
              methods.add(call.method);
              if (call.method == 'requestPermission') return 'granted';
              if (call.method == 'startRecording') await start.future;
              return null;
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(_channel, null);
        });
        final auth = AuthRepository(
          apiBaseUrl: 'http://voice-lifecycle.invalid',
        );
        auth.session = AuthSession(
          token: 'fixture',
          sessionId: 'fixture-session',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
          user: const AuthUser(
            id: 'voice-fixture',
            username: 'fixture',
            email: 'fixture@example.invalid',
          ),
        );
        final router = GoRouter(
          initialLocation: '/50',
          routes: [
            GoRoute(path: '/50', builder: (_, _) => const VoiceInputScreen()),
            GoRoute(
              path: '/covered',
              builder: (_, _) => const Scaffold(body: Text('Covering route')),
            ),
          ],
        );
        addTearDown(router.dispose);
        addTearDown(auth.dispose);
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: auth,
            child: MaterialApp.router(theme: seraTheme(), routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('录完后识别'));
        await tester.pumpAndSettle();
        final button = find.widgetWithText(SeraButton, '开始录音');
        await tester.ensureVisible(button);
        await tester.tap(button);
        for (var i = 0; i < 30 && !methods.contains('startRecording'); i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(methods, contains('startRecording'));
        unawaited(router.push<void>('/covered'));
        await tester.pumpAndSettle();
        expect(find.text('Covering route'), findsOneWidget);
        if (fail) {
          start.completeError(
            PlatformException(
              code: 'late_failure',
              message: 'Late recording failure',
            ),
          );
        } else {
          start.complete();
        }
        await tester.pumpAndSettle();
        if (!fail) expect(methods, contains('cancelRecording'));
        router.pop();
        await tester.pumpAndSettle();
        expect(find.text('正在录音'), findsNothing);
        expect(find.textContaining('Late recording failure'), findsNothing);
        expect(tester.widget<SeraButton>(button).busy, isFalse);
        expect(tester.widget<SeraButton>(button).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
}
