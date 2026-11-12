import 'package:flutter_test/flutter_test.dart';

import 'dart:async';

import 'package:sera_flutter/application/platform_coordinator.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/platform/platform_services.dart';

class _Auth extends Fake implements AuthRepository {
  bool fail = true;
  @override
  bool get signedIn => session != null;
  @override
  AuthSession? session = AuthSession(
    token: 'a',
    sessionId: 'a',
    expiresAt: DateTime.now().add(const Duration(days: 1)),
    user: const AuthUser(id: 'a', username: 'a', email: 'a@example.test'),
  );
  Completer<void>? postGate;
  final postEntered = Completer<void>();
  final paths = <String>[];
  @override
  Future<Json> authenticatedRequest(
    String method,
    String path, {
    Object? data,
    String? contentType,
    String? idempotencyKey,
  }) async {
    paths.add('$method $path');
    if (method == 'GET') return {'publicKey': 'test-vapid-public'};
    if (!postEntered.isCompleted) postEntered.complete();
    await postGate?.future;
    if (fail) throw const RepositoryException('注册接口离线');
    return {'subscribed': true};
  }
}

class _Platform extends Fake implements SeraPlatformServices {
  bool subscribed = false;
  int cancellations = 0;
  @override
  Future<Map<String, dynamic>> subscribeWebPush(String vapidPublicKey) async {
    subscribed = true;
    return {
      'endpoint': 'https://push.example/device',
      'keys': <String, String>{},
    };
  }

  @override
  Future<void> unsubscribeWebPush() async {
    cancellations++;
    subscribed = false;
  }
}

void main() {
  test('device-only use does not register a cloud push subscription', () async {
    final auth = _Auth()..session = null;
    final platform = _Platform();
    final coordinator = PlatformCoordinator(
      auth: auth,
      accountId: 'device-local',
      services: platform,
    );
    await expectLater(
      coordinator.enableWebPush(),
      throwsA(isA<PlatformCapabilityException>()),
    );
    expect(auth.paths, isEmpty);
    expect(platform.subscribed, isFalse);
    expect(platform.cancellations, 0);
    coordinator.dispose();
  });
  test('backend registration failure retires browser subscription and reports original error', () async {
    final auth = _Auth();
    final platform = _Platform();
    final coordinator = PlatformCoordinator(
      auth: auth,
      accountId: 'a',
      services: platform,
    );
    await expectLater(
      coordinator.enableWebPush(),
      throwsA(isA<RepositoryException>()),
    );
    expect(platform.subscribed, isFalse);
    expect(platform.cancellations, 1);
    expect(coordinator.lastError, contains('已撤销'));
    expect(auth.paths, [
      'GET /api/v1/push/config',
      'POST /api/v1/push/subscriptions',
    ]);
    auth.fail = false;
    await coordinator.enableWebPush();
    expect(platform.subscribed, isTrue);
    expect(platform.cancellations, 1);
    expect(coordinator.lastError, isNull);
    coordinator.dispose();
  });
  test(
    'old account registration failure cannot retire a new account subscription',
    () async {
      final auth = _Auth()..postGate = Completer<void>();
      final platform = _Platform();
      final coordinator = PlatformCoordinator(
        auth: auth,
        accountId: 'a',
        services: platform,
      );
      final assertion = expectLater(
        coordinator.enableWebPush(),
        throwsA(isA<RepositoryException>()),
      );
      await auth.postEntered.future;
      coordinator.dispose();
      auth.session = AuthSession(
        token: 'b',
        sessionId: 'b',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
        user: const AuthUser(id: 'b', username: 'b', email: 'b@example.test'),
      );
      auth.postGate!.complete();
      await assertion;
      expect(platform.cancellations, 0);
    },
  );
}
