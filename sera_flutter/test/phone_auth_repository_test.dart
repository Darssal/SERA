import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/data/phone_auth_repository.dart';
import 'package:sera_flutter/data/workspace_repository.dart';

void main() {
  test('normalizes only supported mainland mobile identities', () {
    expect(
      PhoneAuthRepository.normalizePhone(' +86 138-0013-8000 '),
      '13800138000',
    );
    for (final invalid in [
      '123',
      '12800138000',
      '+85291234567',
      '13800138000@x.test',
    ]) {
      expect(
        () => PhoneAuthRepository.normalizePhone(invalid),
        throwsA(isA<RepositoryException>()),
      );
    }
  });

  test(
    'disabled capabilities stay disabled and malformed status is rejected',
    () async {
      final harness = _Harness(
        (options, handler) => _reply(options, handler, {
          'enabled': false,
          'message': '短信登录暂未启用，请使用邮箱登录。',
        }),
      );
      addTearDown(harness.auth.dispose);
      final status = await harness.phone.capabilities();
      expect(status.enabled, isFalse);
      expect(status.message, contains('未启用'));
      expect(
        () => PhoneAuthCapabilities.fromJson({'enabled': true}),
        throwsA(isA<RepositoryException>()),
      );
      expect(harness.auth.session, isNull);
    },
  );

  test(
    'challenge sends normalized phone and purpose without a client code',
    () async {
      final harness = _Harness((options, handler) {
        expect(options.data, {'phone': '13800138000', 'purpose': 'login'});
        _reply(options, handler, _challenge());
      });
      addTearDown(harness.auth.dispose);
      final challenge = await harness.phone.requestChallenge(
        phone: '+86 13800138000',
        purpose: PhoneChallengePurpose.login,
      );
      expect(challenge.maskedPhone, '138****8000');
      expect(challenge.purpose, PhoneChallengePurpose.login);
      expect(challenge.deliveryStatus, 'submitted');
      expect(harness.storage.values, isEmpty);
    },
  );

  test(
    'unknown submission retains a real challenge without claiming delivery',
    () async {
      final harness = _Harness(
        (options, handler) => _reply(options, handler, {
          ..._challenge(),
          'deliveryStatus': 'unknown',
          'message': '发送状态未确认，请查收后输入。',
        }),
      );
      addTearDown(harness.auth.dispose);
      final challenge = await harness.phone.requestChallenge(
        phone: '13800138000',
        purpose: PhoneChallengePurpose.login,
      );
      expect(challenge.deliveryStatus, 'unknown');
      expect(challenge.id, 'challenge-a');
    },
  );

  test('missing challenge expiry cannot fabricate a send success', () async {
    final harness = _Harness(
      (options, handler) =>
          _reply(options, handler, {'challengeId': 'invalid'}),
    );
    addTearDown(harness.auth.dispose);
    await expectLater(
      harness.phone.requestChallenge(
        phone: '13800138000',
        purpose: PhoneChallengePurpose.login,
      ),
      throwsA(isA<RepositoryException>()),
    );
  });

  test('phone login explicitly forwards consent and uses existing native session storage', () async {
    final harness = _Harness((options, handler) {
      if (options.path.endsWith('/challenge')) {
        _reply(options, handler, _challenge());
      } else {
        expect(options.path, '/api/v1/auth/phone/login');
        expect(options.data, {
          'challengeId': 'challenge-a',
          'code': '451236',
          'acceptRegistration': true,
        });
        _reply(options, handler, {..._sessionBody(), 'created': true});
      }
    });
    addTearDown(harness.auth.dispose);
    final challenge = await harness.phone.requestChallenge(
      phone: '13800138000',
      purpose: PhoneChallengePurpose.login,
    );
    final result = await harness.phone.login(
      challenge: challenge,
      code: '451236',
      acceptRegistration: true,
    );
    expect(result.created, isTrue);
    expect(harness.auth.signedIn, isTrue);
    expect(harness.auth.session!.user.email, isEmpty);
    expect(harness.auth.session!.user.hasPassword, isFalse);
    final persisted = jsonEncode(harness.storage.values);
    expect(persisted, contains('native-session'));
    expect(persisted, isNot(contains('451236')));
    expect(persisted, isNot(contains('challenge-a')));
  });

  test(
    'Web cookie phone login retains CSRF and sends no empty Bearer',
    () async {
      final harness = _Harness((options, handler) {
        if (options.path.endsWith('/challenge')) {
          _reply(options, handler, _challenge());
        } else if (options.path.endsWith('/login')) {
          _reply(options, handler, {
            ..._sessionBody(cookie: true),
            'created': false,
          });
        } else {
          expect(options.headers.containsKey('Authorization'), isFalse);
          expect(options.headers['X-CSRF-Token'], 'cookie-csrf');
          _reply(options, handler, {'ok': true});
        }
      });
      addTearDown(harness.auth.dispose);
      final challenge = await harness.phone.requestChallenge(
        phone: '13800138000',
        purpose: PhoneChallengePurpose.login,
      );
      await harness.phone.login(
        challenge: challenge,
        code: '451236',
        acceptRegistration: false,
      );
      expect(harness.auth.session!.cookieSession, isTrue);
      await harness.auth.authenticatedRequest('POST', '/bound-test', data: {});
    },
  );

  test('wrong-purpose and expired challenge are rejected before verification request', () async {
    final harness = _Harness(
      (options, handler) => _reply(options, handler, _challenge()),
    );
    addTearDown(harness.auth.dispose);
    harness.auth.session = _session();
    final challenge = await harness.phone.requestChallenge(
      phone: '13800138000',
      purpose: PhoneChallengePurpose.sensitive,
    );
    await expectLater(
      harness.phone.login(
        challenge: challenge,
        code: '451236',
        acceptRegistration: false,
      ),
      throwsA(isA<RepositoryException>()),
    );
    expect(harness.requests, hasLength(1));
    final expiredRepository = PhoneAuthRepository(
      auth: harness.auth,
      now: () => DateTime.now().add(const Duration(days: 1)),
    );
    await expectLater(
      expiredRepository.verifySensitive(challenge: challenge, code: '451236'),
      throwsA(isA<RepositoryException>()),
    );
    expect(harness.requests, hasLength(1));
  });

  test('late login response cannot replace a newer account session', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final harness = _Harness((options, handler) async {
      if (options.path.endsWith('/challenge')) {
        _reply(options, handler, _challenge());
      } else {
        entered.complete();
        await release.future;
        _reply(options, handler, _sessionBody());
      }
    });
    addTearDown(harness.auth.dispose);
    final challenge = await harness.phone.requestChallenge(
      phone: '13800138000',
      purpose: PhoneChallengePurpose.login,
    );
    final pending = harness.phone.login(
      challenge: challenge,
      code: '451236',
      acceptRegistration: true,
    );
    final assertion = expectLater(pending, throwsA(isA<RepositoryException>()));
    await entered.future;
    harness.auth.session = _session(id: 'other-user');
    release.complete();
    await assertion;
    expect(harness.auth.session!.user.id, 'other-user');
    expect(harness.storage.values, isEmpty);
  });

  test('existing account phone binding authenticates current password twice and refreshes identity', () async {
    final harness = _Harness((options, handler) {
      expect(options.headers['Authorization'], 'Bearer native-session');
      if (options.path.endsWith('/challenge')) {
        expect((options.data as Map)['currentPassword'], 'current-password');
        _reply(options, handler, _challenge());
      } else if (options.path.endsWith('/bind')) {
        expect((options.data as Map)['currentPassword'], 'current-password');
        _reply(options, handler, {'bound': true});
      } else {
        expect(options.path, '/api/v1/auth/me');
        _reply(
          options,
          handler,
          _sessionBody(hasPassword: true, email: 'old@example.test'),
        );
      }
    });
    addTearDown(harness.auth.dispose);
    harness.auth.session = _session(hasPassword: true, phone: null);
    final owner = harness.auth.sessionOwner;
    final sessionId = harness.auth.session!.sessionId;
    final challenge = await harness.phone.requestChallenge(
      phone: '13800138000',
      purpose: PhoneChallengePurpose.bindPhone,
      currentPassword: 'current-password',
    );
    await harness.phone.bindPhone(
      challenge: challenge,
      code: '451236',
      currentPassword: 'current-password',
    );
    expect(harness.auth.session!.user.phone, '13800138000');
    expect(harness.auth.session!.user.hasPassword, isTrue);
    expect(harness.auth.session!.user.id, 'phone-user');
    expect(harness.auth.session!.sessionId, sessionId);
    expect(harness.auth.sessionOwner, owner);
    expect(harness.auth.signedIn, isTrue);
    expect(harness.requests.map((r) => r.path), [
      '/api/v1/auth/phone/challenge',
      '/api/v1/auth/phone/bind',
      '/api/v1/auth/me',
    ]);
    expect(
      jsonEncode(harness.storage.values),
      isNot(contains('current-password')),
    );
  });

  test(
    'leaving the login page before its response prevents session adoption',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      var current = true;
      final harness = _Harness((options, handler) async {
        if (options.path.endsWith('/challenge')) {
          _reply(options, handler, _challenge());
        } else {
          entered.complete();
          await release.future;
          _reply(options, handler, _sessionBody());
        }
      });
      addTearDown(harness.auth.dispose);
      final challenge = await harness.phone.requestChallenge(
        phone: '13800138000',
        purpose: PhoneChallengePurpose.login,
      );
      final pending = harness.phone.login(
        challenge: challenge,
        code: '451236',
        acceptRegistration: true,
        isCurrent: () => current,
      );
      final assertion = expectLater(
        pending,
        throwsA(isA<RepositoryException>()),
      );
      await entered.future;
      current = false;
      release.complete();
      await assertion;
      expect(harness.auth.session, isNull);
      expect(harness.storage.values, isEmpty);
    },
  );

  test(
    'leaving during secure storage write restores the prior signed-out state',
    () async {
      var current = true;
      final harness = _Harness(
        (options, handler) => _reply(
          options,
          handler,
          options.path.endsWith('/challenge') ? _challenge() : _sessionBody(),
        ),
      );
      addTearDown(harness.auth.dispose);
      final entered = Completer<void>(), release = Completer<void>();
      harness.storage.beforeWrite = () async {
        entered.complete();
        await release.future;
      };
      final challenge = await harness.phone.requestChallenge(
        phone: '13800138000',
        purpose: PhoneChallengePurpose.login,
      );
      final pending = harness.phone.login(
        challenge: challenge,
        code: '451236',
        acceptRegistration: true,
        isCurrent: () => current,
      );
      final assertion = expectLater(
        pending,
        throwsA(isA<RepositoryException>()),
      );
      await entered.future;
      current = false;
      release.complete();
      await assertion;
      expect(harness.auth.session, isNull);
      expect(harness.storage.values, isEmpty);
    },
  );

  test(
    'sensitive proof is single use even when identity request fails',
    () async {
      var writes = 0;
      final harness = _Harness((options, handler) {
        if (options.path.endsWith('/challenge')) {
          _reply(options, handler, _challenge());
        } else if (options.path.endsWith('/verify-sensitive')) {
          _reply(options, handler, {
            'phoneProof': 'opaque-private-proof',
            'expiresIn': 300,
          });
        } else {
          writes++;
          expect((options.data as Map)['phoneProof'], 'opaque-private-proof');
          _reject(options, handler, 503, '邮件服务未确认接受，请稍后重试。');
        }
      });
      addTearDown(harness.auth.dispose);
      harness.auth.session = _session();
      final proof = await _proof(harness);
      await expectLater(
        harness.phone.requestEmailBinding(
          email: 'user@example.test',
          proof: proof,
        ),
        throwsA(isA<RepositoryException>()),
      );
      expect(proof.consumed, isTrue);
      await expectLater(
        harness.phone.requestEmailBinding(
          email: 'user@example.test',
          proof: proof,
        ),
        throwsA(isA<RepositoryException>()),
      );
      expect(writes, 1);
      expect(
        jsonEncode(harness.storage.values),
        isNot(contains('opaque-private-proof')),
      );
    },
  );

  test('sensitive proof cannot cross accounts or survive expiry', () async {
    final harness = _Harness(
      (options, handler) => _reply(
        options,
        handler,
        options.path.endsWith('/challenge')
            ? _challenge()
            : {'phoneProof': 'private-proof', 'expiresIn': 300},
      ),
    );
    addTearDown(harness.auth.dispose);
    harness.auth.session = _session();
    final proof = await _proof(harness);
    harness.auth.session = _session(id: 'other-user');
    expect(
      () => harness.phone.consumeForAccountDeletion(proof),
      throwsA(isA<RepositoryException>()),
    );
    harness.auth.session = _session();
    expect(
      () => proof.consume(
        harness.auth,
        DateTime.now().add(const Duration(hours: 1)),
      ),
      throwsA(isA<RepositoryException>()),
    );
    expect(harness.requests, hasLength(2));
  });

  test('new phone user sets own password with proof and no invented current password', () async {
    final harness = _Harness((options, handler) {
      if (options.path.endsWith('/challenge')) {
        _reply(options, handler, _challenge());
      } else if (options.path.endsWith('/verify-sensitive')) {
        _reply(options, handler, {
          'phoneProof': 'private-proof',
          'expiresIn': 300,
        });
      } else if (options.path.endsWith('/set')) {
        expect(options.data, {
          'password': 'new-long-password',
          'phoneProof': 'private-proof',
        });
        _reply(options, handler, {'passwordSet': true});
      } else {
        _reply(options, handler, _sessionBody(hasPassword: true));
      }
    });
    addTearDown(harness.auth.dispose);
    harness.auth.session = _session();
    final proof = await _proof(harness);
    await harness.phone.setPassword(
      password: 'new-long-password',
      proof: proof,
    );
    expect(harness.auth.session!.user.hasPassword, isTrue);
    expect(
      jsonEncode(harness.storage.values),
      isNot(contains('new-long-password')),
    );
  });

  test('email binding rejects other-purpose links and supports native full binding link', () async {
    final harness = _Harness((options, handler) {
      if (options.path.endsWith('/confirm')) {
        expect(options.data, {'token': 'email-bind-token'});
        _reply(options, handler, {'verified': true});
      } else {
        _reply(options, handler, _sessionBody(email: 'new@example.test'));
      }
    });
    addTearDown(harness.auth.dispose);
    harness.auth.session = _session();
    await expectLater(
      harness.phone.confirmEmailBinding(
        'https://example.test/#/reset-password?token=wrong',
      ),
      throwsA(isA<RepositoryException>()),
    );
    expect(harness.requests, isEmpty);
    await harness.phone.confirmEmailBinding(
      'https://example.test/#/phone-email?token=email-bind-token',
    );
    expect(harness.auth.session!.user.email, 'new@example.test');
    expect(harness.requests, hasLength(2));
  });
  test(
    'leaving during signed-out marker deletion restores marker and no session',
    () async {
      var current = true;
      final harness = _Harness(
        (options, handler) => _reply(
          options,
          handler,
          options.path.endsWith('/challenge') ? _challenge() : _sessionBody(),
        ),
      );
      addTearDown(harness.auth.dispose);
      const signedOutKey =
          'sera.auth.session.http://phone-auth.test.signed-out';
      harness.storage.values[signedOutKey] = 'true';
      final entered = Completer<void>(), release = Completer<void>();
      harness.storage.beforeDelete = (key) async {
        if (key != signedOutKey) return;
        entered.complete();
        await release.future;
      };
      final challenge = await harness.phone.requestChallenge(
        phone: '13800138000',
        purpose: PhoneChallengePurpose.login,
      );
      final pending = harness.phone.login(
        challenge: challenge,
        code: '451236',
        acceptRegistration: true,
        isCurrent: () => current,
      );
      final assertion = expectLater(
        pending,
        throwsA(isA<RepositoryException>()),
      );
      await entered.future.timeout(const Duration(seconds: 3));
      current = false;
      release.complete();
      await assertion;
      expect(harness.auth.session, isNull);
      expect(harness.storage.values, {signedOutKey: 'true'});
    },
  );

  test(
    'confirmed binding retries only identity read after refresh failure',
    () async {
      var binds = 0, reads = 0;
      final harness = _Harness((options, handler) {
        if (options.path.endsWith('/challenge')) {
          _reply(options, handler, _challenge());
        } else if (options.path.endsWith('/bind')) {
          binds++;
          _reply(options, handler, {'bound': true});
        } else {
          expect(options.path, '/api/v1/auth/me');
          reads++;
          if (reads == 1) {
            _reject(options, handler, 503, '账户状态暂时无法读取。');
          } else {
            _reply(options, handler, _sessionBody(hasPassword: true));
          }
        }
      });
      addTearDown(harness.auth.dispose);
      harness.auth.session = _session(hasPassword: true, phone: null);
      final owner = harness.auth.sessionOwner;
      final challenge = await harness.phone.requestChallenge(
        phone: '13800138000',
        purpose: PhoneChallengePurpose.bindPhone,
        currentPassword: 'current-password',
      );
      PhoneBindingRefreshPending? receipt;
      try {
        await harness.phone.bindPhone(
          challenge: challenge,
          code: '451236',
          currentPassword: 'current-password',
        );
        fail(
          'A failed identity refresh must not claim a completed binding flow.',
        );
      } on PhoneBindingRefreshPending catch (error) {
        receipt = error;
      }
      expect(harness.auth.session!.user.phone, isNull);
      await harness.phone.refreshBoundPhone(receipt);
      expect(harness.auth.session!.user.phone, '13800138000');
      expect(harness.auth.sessionOwner, owner);
      expect(binds, 1);
      expect(reads, 2);
      expect(
        harness.requests.where((r) => r.path.endsWith('/challenge')),
        hasLength(1),
      );
      expect(jsonEncode(harness.storage.values), isNot(contains('451236')));
      expect(
        jsonEncode(harness.storage.values),
        isNot(contains('current-password')),
      );
    },
  );

  test(
    'binding refresh rejects a newer account instead of completing old work',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final harness = _Harness((options, handler) async {
        if (options.path.endsWith('/challenge')) {
          _reply(options, handler, _challenge());
        } else if (options.path.endsWith('/bind')) {
          _reply(options, handler, {'bound': true});
        } else {
          entered.complete();
          await release.future;
          _reply(options, handler, _sessionBody(hasPassword: true));
        }
      });
      addTearDown(() {
        if (!release.isCompleted) release.complete();
        harness.auth.dispose();
      });
      harness.auth.session = _session(hasPassword: true, phone: null);
      final challenge = await harness.phone.requestChallenge(
        phone: '13800138000',
        purpose: PhoneChallengePurpose.bindPhone,
        currentPassword: 'current-password',
      );
      final pending = harness.phone.bindPhone(
        challenge: challenge,
        code: '451236',
        currentPassword: 'current-password',
      );
      final assertion = expectLater(
        pending,
        throwsA(isA<RepositoryException>()),
      );
      await entered.future.timeout(const Duration(seconds: 3));
      harness.auth.session = _session(id: 'new-account', phone: null);
      release.complete();
      await assertion;
      expect(harness.auth.session!.user.id, 'new-account');
      expect(harness.auth.session!.user.phone, isNull);
      expect(harness.storage.values, isEmpty);
    },
  );

  test(
    'binding receipt cannot refresh after leaving or switching account',
    () async {
      var current = true;
      final harness = _Harness((options, handler) {
        if (options.path.endsWith('/challenge')) {
          _reply(options, handler, _challenge());
        } else {
          expect(options.path, '/api/v1/auth/phone/bind');
          current = false;
          _reply(options, handler, {'bound': true});
        }
      });
      addTearDown(harness.auth.dispose);
      harness.auth.session = _session(hasPassword: true, phone: null);
      final challenge = await harness.phone.requestChallenge(
        phone: '13800138000',
        purpose: PhoneChallengePurpose.bindPhone,
      );
      PhoneBindingRefreshPending? receipt;
      try {
        await harness.phone.bindPhone(
          challenge: challenge,
          code: '451236',
          isCurrent: () => current,
        );
        fail('The covered binding page must not finish its flow.');
      } on PhoneBindingRefreshPending catch (error) {
        receipt = error;
      }
      final confirmedReceipt = receipt;
      await expectLater(
        harness.phone.refreshBoundPhone(
          confirmedReceipt,
          isCurrent: () => current,
        ),
        throwsA(isA<RepositoryException>()),
      );
      harness.auth.session = _session(id: 'new-account');
      await expectLater(
        harness.phone.refreshBoundPhone(
          confirmedReceipt,
          isCurrent: () => true,
        ),
        throwsA(isA<RepositoryException>()),
      );
      expect(harness.requests, hasLength(2));
      expect(harness.auth.session!.user.id, 'new-account');
    },
  );

  for (final password in [false, true]) {
    test(
      'confirmed ${password ? 'password' : 'email binding'} has owner-bound read-only recovery',
      () async {
        var writes = 0, reads = 0;
        final harness = _Harness((options, handler) {
          if (options.path.endsWith('/challenge')) {
            _reply(options, handler, _challenge());
          } else if (options.path.endsWith('/verify-sensitive')) {
            _reply(options, handler, {
              'phoneProof': 'private-proof',
              'expiresIn': 300,
            });
          } else if (options.path.endsWith('/set') ||
              options.path.endsWith('/confirm')) {
            writes++;
            _reply(
              options,
              handler,
              password ? {'passwordSet': true} : {'verified': true},
            );
          } else {
            expect(options.path, '/api/v1/auth/me');
            reads++;
            if (reads == 1) {
              _reject(options, handler, 503, '账户状态暂时无法读取。');
            } else {
              _reply(
                options,
                handler,
                _sessionBody(
                  hasPassword: password,
                  email: password ? null : 'bound@example.test',
                ),
              );
            }
          }
        });
        addTearDown(harness.auth.dispose);
        harness.auth.session = _session();
        final owner = harness.auth.sessionOwner;
        PhoneIdentityRefreshPending? pending;
        try {
          if (password) {
            final proof = await _proof(harness);
            await harness.phone.setPassword(
              password: 'private-new-password',
              proof: proof,
            );
          } else {
            await harness.phone.confirmEmailBinding('private-email-token');
          }
          fail('A confirmed write with a failed read must provide recovery.');
        } on PhoneIdentityRefreshPending catch (error) {
          pending = error;
        }
        final receipt = pending;
        expect(
          receipt.change,
          password
              ? PhoneIdentityChange.password
              : PhoneIdentityChange.emailBinding,
        );
        await expectLater(
          harness.phone.refreshIdentity(receipt, isCurrent: () => false),
          throwsA(isA<RepositoryException>()),
        );
        expect(reads, 1);
        await harness.phone.refreshIdentity(receipt);
        expect(writes, 1);
        expect(reads, 2);
        expect(harness.auth.sessionOwner, owner);
        harness.auth.session = _session(id: 'other-account');
        await expectLater(
          harness.phone.refreshIdentity(receipt),
          throwsA(isA<RepositoryException>()),
        );
        expect(reads, 2);
        final persisted = jsonEncode(harness.storage.values);
        for (final secret in [
          'private-proof',
          'private-new-password',
          'private-email-token',
        ]) {
          expect(persisted, isNot(contains(secret)));
        }
      },
    );
  }

  test(
    'challenge and proof expire exactly at their server-issued deadlines',
    () async {
      var clock = DateTime.now();
      final harness = _Harness((options, handler) {
        if (options.path.endsWith('/challenge')) {
          _reply(
            options,
            handler,
            _challenge(referenceNow: clock, expiresSeconds: 4),
          );
        } else {
          expect(options.path, '/api/v1/auth/phone/verify-sensitive');
          _reply(options, handler, {
            'phoneProof': 'private-expiring-proof',
            'expiresIn': 5,
          });
        }
      }, now: () => clock);
      addTearDown(harness.auth.dispose);
      final loginChallenge = await harness.phone.requestChallenge(
        phone: '13800138000',
        purpose: PhoneChallengePurpose.login,
      );
      clock = clock.add(const Duration(seconds: 4));
      await expectLater(
        harness.phone.login(
          challenge: loginChallenge,
          code: '451236',
          acceptRegistration: false,
        ),
        throwsA(isA<RepositoryException>()),
      );
      expect(harness.requests, hasLength(1));
      harness.auth.session = _session();
      final proof = await _proof(harness);
      clock = clock.add(const Duration(seconds: 5));
      expect(
        () => proof.consume(harness.auth, clock),
        throwsA(isA<RepositoryException>()),
      );
      expect(proof.consumed, isFalse);
      expect(harness.requests, hasLength(3));
    },
  );
}

Future<PhoneSensitiveProof> _proof(_Harness harness) async {
  final challenge = await harness.phone.requestChallenge(
    phone: '13800138000',
    purpose: PhoneChallengePurpose.sensitive,
  );
  return harness.phone.verifySensitive(challenge: challenge, code: '451236');
}

Map<String, dynamic> _challenge({
  DateTime? referenceNow,
  int expiresSeconds = 300,
}) => {
  'challengeId': 'challenge-a',
  'maskedPhone': '138****8000',
  'expiresAt': (referenceNow ?? DateTime.now())
      .add(Duration(seconds: expiresSeconds))
      .toUtc()
      .toIso8601String(),
  'resendAt': (referenceNow ?? DateTime.now())
      .add(const Duration(seconds: 60))
      .toUtc()
      .toIso8601String(),
  'deliveryStatus': 'submitted',
  'message': '验证码已提交发送，请查看手机短信。',
};

Map<String, dynamic> _sessionBody({
  bool cookie = false,
  String id = 'phone-user',
  bool hasPassword = false,
  String? email,
  String? phone = '13800138000',
}) => {
  'token': cookie ? '' : 'native-session',
  'cookieSession': cookie,
  'csrfToken': cookie ? 'cookie-csrf' : '',
  'sessionId': 'session-$id',
  'expiresAt': DateTime.now()
      .add(const Duration(days: 1))
      .toUtc()
      .toIso8601String(),
  'user': {
    'id': id,
    'username': 'phone-user',
    'email': email,
    'emailVerified': email != null,
    'phone': phone,
    'hasPassword': hasPassword,
  },
};

AuthSession _session({
  String id = 'phone-user',
  bool hasPassword = false,
  String? phone = '13800138000',
}) => AuthSession.fromJson(
  _sessionBody(id: id, hasPassword: hasPassword, phone: phone),
);

class _Harness {
  _Harness(
    FutureOr<void> Function(RequestOptions, RequestInterceptorHandler) handle, {
    DateTime Function()? now,
  }) {
    final client = Dio();
    addTearDown(() => expect(interceptorErrors, isEmpty));
    client.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          requests.add(options);
          try {
            await handle(options, handler);
          } catch (error, stackTrace) {
            interceptorErrors.add(error);
            if (!handler.isCompleted) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  error: error,
                  stackTrace: stackTrace,
                ),
              );
            }
          }
        },
      ),
    );
    auth = AuthRepository(
      apiBaseUrl: 'http://phone-auth.test',
      client: client,
      storage: storage,
      accountEvents: _Events(),
    );
    phone = PhoneAuthRepository(auth: auth, now: now);
  }
  final requests = <RequestOptions>[];
  final interceptorErrors = <Object>[];
  final storage = _MemoryStorage();
  late final AuthRepository auth;
  late final PhoneAuthRepository phone;
}

class _MemoryStorage implements AuthSessionStorage {
  final values = <String, String>{};
  Future<void> Function()? beforeWrite;
  Future<void> Function(String)? beforeDelete;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    await beforeWrite?.call();
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    await beforeDelete?.call(key);
    values.remove(key);
  }
}

class _Events implements AccountEventChannel {
  final controller = StreamController<AccountEvent>.broadcast();
  @override
  Stream<AccountEvent> get events => controller.stream;
  @override
  void publish(AccountEvent event) {}
  @override
  void dispose() {
    unawaited(controller.close());
  }
}

void _reply(
  RequestOptions options,
  RequestInterceptorHandler handler,
  Map<String, dynamic> body,
) => handler.resolve(
  Response<dynamic>(requestOptions: options, statusCode: 200, data: body),
);

void _reject(
  RequestOptions options,
  RequestInterceptorHandler handler,
  int status,
  String message,
) => handler.reject(
  DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response<dynamic>(
      requestOptions: options,
      statusCode: status,
      data: {'error': message},
    ),
  ),
);
