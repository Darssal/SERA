import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/data/phone_auth_repository.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:sera_flutter/ui/screens/phone_auth_screen.dart';
import 'package:sera_flutter/ui/screens/account_screens.dart';

void main() {
  testWidgets(
    'passwordless account Provider can build verification panel before capability notifications',
    (tester) async {
      var checks = 0, sends = 0;
      final harness = _Harness((options, handler) {
        if (options.path.endsWith('/capabilities')) {
          checks++;
          _reply(options, handler, _capabilities());
        } else {
          sends++;
          fail('Building account identity controls must not send SMS.');
        }
      });
      harness.auth.session = _session();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        harness.auth.dispose();
      });
      await tester.pumpWidget(
        ChangeNotifierProvider<AuthRepository>.value(
          value: harness.auth,
          child: MaterialApp(
            theme: seraTheme(),
            home: const AccountScreen(mode: 'account'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byType(RecentPhoneVerification, skipOffstage: false),
        findsOneWidget,
      );
      expect(checks, 1);
      expect(sends, 0);
      expect(harness.auth.loading, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disabled service keeps email login and never sends a fake SMS', (
    tester,
  ) async {
    var sends = 0, emailClicks = 0;
    final harness = _Harness((options, handler) {
      if (options.path.endsWith('/capabilities')) {
        _reply(options, handler, {
          'enabled': false,
          'message': '短信服务尚未配置，请使用邮箱登录。',
        });
      } else {
        sends++;
        fail('A disabled provider must never receive a send request.');
      }
    });
    await _pump(tester, harness, onEmailLogin: () => emailClicks++);
    expect(find.text('短信登录暂未启用'), findsOneWidget);
    expect(_buttonWidget(tester, '获取短信验证码').onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('phone-number')),
      '13800138000',
    );
    await _tap(tester, '使用邮箱或用户名登录');
    expect(emailClicks, 1);
    expect(sends, 0);
    expect(harness.auth.session, isNull);
  });

  testWidgets(
    'invalid phone does not send and existing binding requires current password',
    (tester) async {
      var sends = 0;
      final harness = _Harness((options, handler) {
        if (options.path.endsWith('/capabilities')) {
          _reply(options, handler, _capabilities());
        } else {
          sends++;
          _reply(options, handler, _challenge());
        }
      });
      await _pump(tester, harness);
      expect(_buttonWidget(tester, '获取短信验证码').onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('phone-number')), '123');
      await tester.pump();
      expect(_buttonWidget(tester, '获取短信验证码').onPressed, isNull);
      expect(find.textContaining('11 位手机号码'), findsWidgets);
      expect(sends, 0);
      harness.auth.session = _session(hasPassword: true, phone: null);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          theme: seraTheme(),
          home: PhoneAuthScreen(
            mode: PhoneAuthMode.bindPhone,
            repository: harness.phone,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('phone-number')),
        '13800138000',
      );
      await tester.pump();
      expect(_buttonWidget(tester, '获取短信验证码').onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('phone-current-password')),
        'current-password',
      );
      await tester.pump();
      expect(_buttonWidget(tester, '获取短信验证码').onPressed, isNotNull);
      final passwordInput = find.descendant(
        of: find.byKey(const ValueKey('phone-current-password')),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(passwordInput).obscureText, isTrue);
      await tester.ensureVisible(
        find.byKey(const ValueKey('phone-current-password-visibility')),
      );
      await tester.tap(
        find.byKey(const ValueKey('phone-current-password-visibility')),
      );
      await tester.pump();
      expect(tester.widget<TextField>(passwordInput).obscureText, isFalse);
      expect(
        _field(tester, 'phone-current-password').controller!.text,
        'current-password',
      );
      expect(sends, 0);
    },
  );

  testWidgets(
    'sending starts cooldown and a wrong code keeps phone and entered code',
    (tester) async {
      var sends = 0;
      final harness = _Harness((options, handler) {
        if (options.path.endsWith('/capabilities')) {
          _reply(options, handler, _capabilities());
        } else if (options.path.endsWith('/challenge')) {
          sends++;
          _reply(options, handler, _challenge());
        } else {
          _reject(options, handler, 400, '验证码错误，请检查后重试。');
        }
      });
      await _pump(tester, harness);
      await _send(tester);
      final resend = tester
          .widgetList<SeraButton>(find.byType(SeraButton))
          .where((button) => button.label.contains('秒后可重新获取'))
          .single;
      expect(resend.onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('phone-code')),
        '111111',
      );
      await _tap(tester, '验证并登录');
      expect(find.text('验证码错误，请检查后重试。'), findsOneWidget);
      expect(_field(tester, 'phone-number').controller!.text, '13800138000');
      expect(_field(tester, 'phone-code').controller!.text, '111111');
      expect(sends, 1);
      expect(harness.auth.session, isNull);
    },
  );

  testWidgets(
    'new phone registration requires explicit consent and retries the same challenge',
    (tester) async {
      var sends = 0, logins = 0;
      bool? created;
      final harness = _Harness((options, handler) {
        if (options.path.endsWith('/capabilities')) {
          _reply(options, handler, _capabilities());
        } else if (options.path.endsWith('/challenge')) {
          sends++;
          _reply(options, handler, _challenge());
        } else {
          logins++;
          expect((options.data as Map)['challengeId'], 'challenge-a');
          expect((options.data as Map)['code'], '451236');
          if ((options.data as Map)['acceptRegistration'] != true) {
            _reject(options, handler, 409, '此手机号尚未注册，请明确同意创建账户后继续。');
          } else {
            _reply(options, handler, {..._session().toJson(), 'created': true});
          }
        }
      });
      await _pump(tester, harness, onAuthenticated: (value) => created = value);
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
      await _send(tester);
      await tester.enterText(
        find.byKey(const ValueKey('phone-code')),
        '451236',
      );
      await _tap(tester, '验证并登录');
      expect(created, isNull);
      expect(_field(tester, 'phone-code').controller!.text, '451236');
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await _tap(tester, '验证并登录');
      expect(created, isTrue);
      expect(sends, 1);
      expect(logins, 2);
      expect(harness.auth.session!.user.hasPassword, isFalse);
    },
  );

  testWidgets(
    'provider timeout keeps real challenge and states delivery is uncertain',
    (tester) async {
      final harness = _Harness(
        (options, handler) => _reply(
          options,
          handler,
          options.path.endsWith('/capabilities')
              ? _capabilities()
              : {
                  ..._challenge(),
                  'deliveryStatus': 'unknown',
                  'message': '短信发送状态暂时无法确认。如已收到验证码请继续输入。',
                },
        ),
      );
      await _pump(tester, harness);
      await _send(tester);
      expect(find.text('暂时无法确认短信是否发出'), findsOneWidget);
      expect(find.textContaining('如已收到验证码请继续输入'), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-code')), findsOneWidget);
      expect(find.textContaining('验证码已发送至'), findsNothing);
    },
  );

  testWidgets(
    'changing phone invalidates local old challenge without automatic resend',
    (tester) async {
      var sends = 0;
      final harness = _Harness((options, handler) {
        if (options.path.endsWith('/capabilities')) {
          _reply(options, handler, _capabilities());
        } else {
          sends++;
          _reply(options, handler, _challenge());
        }
      });
      await _pump(tester, harness);
      await _send(tester);
      await tester.enterText(
        find.byKey(const ValueKey('phone-code')),
        '451236',
      );
      await tester.enterText(
        find.byKey(const ValueKey('phone-number')),
        '13900139000',
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('phone-code')), findsNothing);
      expect(_buttonWidget(tester, '验证并登录').onPressed, isNull);
      expect(sends, 1);
    },
  );

  testWidgets(
    'recent verification returns a memory proof without exposing it in the UI',
    (tester) async {
      PhoneSensitiveProof? proof;
      final harness = _Harness((options, handler) {
        if (options.path.endsWith('/capabilities')) {
          _reply(options, handler, _capabilities());
        } else if (options.path.endsWith('/challenge')) {
          expect(options.data, {
            'phone': '13800138000',
            'purpose': 'sensitive',
          });
          _reply(options, handler, _challenge());
        } else {
          _reply(options, handler, {
            'phoneProof': 'NEVER-RENDER-THIS-PROOF',
            'expiresIn': 300,
          });
        }
      });
      harness.auth.session = _session();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        harness.auth.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: seraTheme(),
          home: SeraScaffold(
            body: RecentPhoneVerification(
              repository: harness.phone,
              onVerified: (value) => proof = value,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final phoneInput = find.descendant(
        of: find.byKey(const ValueKey('phone-number')),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(phoneInput).readOnly, isTrue);
      expect(
        find.byKey(const ValueKey('phone-current-password')),
        findsNothing,
      );
      await _tap(tester, '获取短信验证码');
      await tester.enterText(
        find.byKey(const ValueKey('phone-code')),
        '451236',
      );
      await _tap(tester, '验证当前手机号');
      expect(proof, isNotNull);
      expect(find.textContaining('NEVER-RENDER-THIS-PROOF'), findsNothing);
      expect(find.textContaining('手机号已验证'), findsOneWidget);
    },
  );

  testWidgets(
    'late send after account logout cannot restore a sensitive challenge',
    (tester) async {
      final entered = Completer<void>(), release = Completer<void>();
      final harness = _Harness((options, handler) async {
        if (options.path.endsWith('/capabilities')) {
          _reply(options, handler, _capabilities());
        } else {
          entered.complete();
          await release.future;
          _reply(options, handler, _challenge());
        }
      });
      harness.auth.session = _session();
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await tester.pumpWidget(const SizedBox());
        harness.auth.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: seraTheme(),
          home: SeraScaffold(
            body: RecentPhoneVerification(
              repository: harness.phone,
              onVerified: (_) => fail('A stale session cannot verify.'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(_button('获取短信验证码'));
      await tester.tap(_button('获取短信验证码'));
      for (var attempt = 0; attempt < 50 && !entered.isCompleted; attempt++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(entered.isCompleted, isTrue);
      await harness.auth.invalidateSession();
      release.complete();
      await tester.pumpAndSettle();
      expect(find.text('请先登录账户'), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-code')), findsNothing);
      expect(harness.auth.session, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'passwordless identity management never asks for an existing password',
    (tester) async {
      final harness = _Harness(
        (options, handler) => _reply(options, handler, _capabilities()),
      );
      harness.auth.session = _session();
      await _pump(tester, harness, mode: PhoneAuthMode.manageIdentity);
      expect(
        find.byKey(const ValueKey('identity-current-password')),
        findsNothing,
      );
      expect(find.text('尚未设置'), findsOneWidget);
      expect(find.widgetWithText(SeraDisclosure, '确认邮箱绑定'), findsOneWidget);
      await tester.ensureVisible(find.widgetWithText(ChoiceChip, '设置密码'));
      await tester.tap(find.widgetWithText(ChoiceChip, '设置密码'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(SeraDisclosure, '确认邮箱绑定'), findsNothing);
      expect(
        find.byKey(const ValueKey('identity-new-password')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('identity-confirm-password')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('identity-new-password')),
        'new-private-password',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('identity-new-password-visibility')),
      );
      await tester.tap(
        find.byKey(const ValueKey('identity-new-password-visibility')),
      );
      await tester.pump();
      final newPasswordInput = find.descendant(
        of: find.byKey(const ValueKey('identity-new-password')),
        matching: find.byType(TextField),
      );
      final confirmPasswordInput = find.descendant(
        of: find.byKey(const ValueKey('identity-confirm-password')),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(newPasswordInput).obscureText, isFalse);
      expect(
        tester.widget<TextField>(confirmPasswordInput).obscureText,
        isTrue,
      );
      expect(
        _field(tester, 'identity-new-password').controller!.text,
        'new-private-password',
      );
      await _tap(tester, '设置账户密码');
      expect(find.textContaining('请先验证当前手机号'), findsOneWidget);
      expect(
        harness.requests.where((request) => request.path.endsWith('/set')),
        isEmpty,
      );
    },
  );

  testWidgets(
    'leaving a pending phone login ignores its late session response',
    (tester) async {
      final entered = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final harness = _Harness((options, handler) async {
        if (options.path.endsWith('/capabilities')) {
          _reply(options, handler, _capabilities());
        } else if (options.path.endsWith('/challenge')) {
          _reply(options, handler, _challenge());
        } else {
          entered.complete();
          await release.future;
          _reply(options, handler, {..._session().toJson(), 'created': false});
        }
      });
      await _pump(
        tester,
        harness,
        onAuthenticated: (_) => fail('A disposed login page cannot navigate.'),
      );
      await _send(tester);
      await tester.enterText(
        find.byKey(const ValueKey('phone-code')),
        '451236',
      );
      await tester.pump();
      await tester.ensureVisible(_button('验证并登录'));
      await tester.pump();
      expect(_buttonWidget(tester, '验证并登录').onPressed, isNotNull);
      await tester.tap(_button('验证并登录'));
      await _waitFor(tester, entered);
      expect(
        harness.requests.where((request) => request.path.endsWith('/login')),
        hasLength(1),
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('邮箱登录页面'))),
      );
      release.complete();
      await tester.pumpAndSettle();
      expect(find.text('邮箱登录页面'), findsOneWidget);
      expect(harness.auth.session, isNull);
      expect(harness.storage.values, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'existing password phone user can reset through fresh phone proof without old password',
    (tester) async {
      var resets = 0;
      final harness = _Harness((options, handler) {
        if (options.path.endsWith('/capabilities')) {
          _reply(options, handler, _capabilities());
        } else if (options.path.endsWith('/challenge')) {
          expect(options.data, {
            'phone': '13800138000',
            'purpose': 'sensitive',
          });
          _reply(options, handler, _challenge());
        } else if (options.path.endsWith('/verify-sensitive')) {
          _reply(options, handler, {
            'phoneProof': 'private-reset-proof',
            'expiresIn': 300,
          });
        } else if (options.path.endsWith('/set')) {
          resets++;
          expect(options.data, {
            'password': 'replacement-password',
            'phoneProof': 'private-reset-proof',
          });
          _reply(options, handler, {'passwordSet': true});
        } else {
          expect(options.path, '/api/v1/auth/me');
          _reply(options, handler, _session(hasPassword: true).toJson());
        }
      });
      harness.auth.session = _session(hasPassword: true);
      await _pump(tester, harness, mode: PhoneAuthMode.manageIdentity);
      await tester.ensureVisible(find.widgetWithText(ChoiceChip, '重设密码'));
      await tester.tap(find.widgetWithText(ChoiceChip, '重设密码'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('identity-current-password')),
        findsNothing,
      );
      await _tap(tester, '获取短信验证码');
      await tester.enterText(
        find.byKey(const ValueKey('phone-code')),
        '451236',
      );
      await _tap(tester, '验证当前手机号');
      await tester.enterText(
        find.byKey(const ValueKey('identity-new-password')),
        'replacement-password',
      );
      await tester.enterText(
        find.byKey(const ValueKey('identity-confirm-password')),
        'replacement-password',
      );
      await _tap(tester, '重设账户密码');
      expect(resets, 1);
      expect(find.textContaining('密码已重设，其他登录已退出'), findsOneWidget);
      expect(find.textContaining('private-reset-proof'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'complete phone and code enable actions without auto sending or verifying',
    (tester) async {
      var sends = 0, logins = 0;
      final harness = _Harness((options, handler) {
        if (options.path.endsWith('/capabilities')) {
          _reply(options, handler, _capabilities());
        } else if (options.path.endsWith('/challenge')) {
          sends++;
          _reply(options, handler, _challenge());
        } else {
          logins++;
          _reply(options, handler, {..._session().toJson(), 'created': false});
        }
      });
      await _pump(tester, harness);
      expect(_buttonWidget(tester, '获取短信验证码').onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('phone-number')),
        '13800138000',
      );
      await tester.pump();
      expect(_buttonWidget(tester, '获取短信验证码').onPressed, isNotNull);
      expect(sends, 0);
      await _tap(tester, '获取短信验证码');
      expect(_buttonWidget(tester, '验证并登录').onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('phone-code')), '45123');
      await tester.pump();
      expect(_buttonWidget(tester, '验证并登录').onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('phone-code')),
        '451236',
      );
      await tester.pump();
      expect(_buttonWidget(tester, '验证并登录').onPressed, isNotNull);
      expect(sends, 1);
      expect(logins, 0);
      expect(harness.auth.session, isNull);
      await _tap(tester, '验证并登录');
      expect(logins, 1);
      expect(harness.auth.signedIn, isTrue);
    },
  );

  for (final created in [false, true]) {
    testWidgets(
      'default phone ${created ? 'registration' : 'login'} adopts its verified session and navigates',
      (tester) async {
        final harness = _Harness((options, handler) {
          if (options.path.endsWith('/capabilities')) {
            _reply(options, handler, _capabilities());
          } else if (options.path.endsWith('/challenge')) {
            _reply(options, handler, _challenge());
          } else {
            expect(options.path, '/api/v1/auth/phone/login');
            expect((options.data as Map)['acceptRegistration'], created);
            _reply(options, handler, {
              ..._session().toJson(),
              'created': created,
            });
          }
        });
        final router = await _pumpRouter(tester, harness);
        await _send(tester);
        await tester.enterText(
          find.byKey(const ValueKey('phone-code')),
          '451236',
        );
        if (created) {
          await tester.ensureVisible(find.byType(CheckboxListTile));
          await tester.tap(find.byType(CheckboxListTile));
          await tester.pump();
        }
        await _tap(tester, '验证并登录');
        expect(router.routerDelegate.state.uri.path, '/30');
        expect(harness.auth.signedIn, isTrue);
        expect(harness.auth.session!.user.id, 'phone-user');
        expect(
          harness.storage.values.values.single,
          contains('native-session'),
        );
        expect(
          harness.requests.where((r) => r.path.endsWith('/login')),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'default binding keeps the existing account session and enters today',
    (tester) async {
      final harness = _bindingHarness();
      harness.auth.session = _session(hasPassword: true, phone: null);
      final owner = harness.auth.sessionOwner;
      final router = await _pumpRouter(
        tester,
        harness,
        mode: PhoneAuthMode.bindPhone,
      );
      await _prepareBinding(tester);
      await _tap(tester, '确认绑定手机号');
      expect(router.routerDelegate.state.uri.path, '/04');
      expect(harness.auth.session!.user.id, 'phone-user');
      expect(harness.auth.session!.user.phone, '13800138000');
      expect(harness.auth.sessionOwner, owner);
      expect(harness.auth.signedIn, isTrue);
      expect(harness.requests.map((r) => r.path), [
        '/api/v1/auth/phone/capabilities',
        '/api/v1/auth/phone/challenge',
        '/api/v1/auth/phone/bind',
        '/api/v1/auth/me',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('binding respects a custom completion callback exactly once', (
    tester,
  ) async {
    var completions = 0;
    final harness = _bindingHarness();
    harness.auth.session = _session(hasPassword: true, phone: null);
    final router = await _pumpRouter(
      tester,
      harness,
      mode: PhoneAuthMode.bindPhone,
      onCompleted: () => completions++,
    );
    await _prepareBinding(tester);
    await _tap(tester, '确认绑定手机号');
    expect(completions, 1);
    expect(router.routerDelegate.state.uri.path, '/bind-phone');
    expect(find.byKey(const ValueKey('phone-code')), findsNothing);
    expect(harness.auth.signedIn, isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final covered in [true, false]) {
    testWidgets(
      'late binding cannot take navigation after the page is ${covered ? 'covered' : 'replaced'}',
      (tester) async {
        final entered = Completer<void>(), release = Completer<void>();
        final harness = _bindingHarness(
          beforeBind: () async {
            entered.complete();
            await release.future;
          },
        );
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        harness.auth.session = _session(hasPassword: true, phone: null);
        final router = await _pumpRouter(
          tester,
          harness,
          mode: PhoneAuthMode.bindPhone,
        );
        await _prepareBinding(tester);
        await tester.ensureVisible(_button('确认绑定手机号'));
        await tester.tap(_button('确认绑定手机号'));
        await _waitFor(tester, entered);
        if (covered) {
          unawaited(router.push<void>('/covered'));
        } else {
          router.go('/covered');
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        release.complete();
        await tester.pumpAndSettle();
        expect(router.routerDelegate.state.uri.path, '/covered');
        expect(find.byKey(const ValueKey('covered-page')), findsOneWidget);
        expect(
          harness.requests.where((r) => r.path == '/api/v1/auth/me'),
          hasLength(covered ? 1 : 0),
        );
        expect(harness.auth.session!.user.id, 'phone-user');
        if (covered) {
          router.pop();
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('phone-code')), findsNothing);
          await _tap(tester, '继续');
          expect(router.routerDelegate.state.uri.path, '/04');
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'account switch during binding refresh preserves the new account and route',
    (tester) async {
      final entered = Completer<void>(), release = Completer<void>();
      final harness = _bindingHarness(
        beforeRefresh: () async {
          entered.complete();
          await release.future;
        },
      );
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      harness.auth.session = _session(hasPassword: true, phone: null);
      final router = await _pumpRouter(
        tester,
        harness,
        mode: PhoneAuthMode.bindPhone,
      );
      await _prepareBinding(tester);
      await tester.ensureVisible(_button('确认绑定手机号'));
      await tester.tap(_button('确认绑定手机号'));
      await _waitFor(tester, entered);
      harness.auth.session = _session(
        id: 'new-account',
        hasPassword: true,
        phone: null,
      );
      release.complete();
      await tester.pumpAndSettle();
      expect(router.routerDelegate.state.uri.path, '/bind-phone');
      expect(harness.auth.session!.user.id, 'new-account');
      expect(harness.auth.session!.user.phone, isNull);
      expect(harness.storage.values, isEmpty);
      expect(find.byKey(const ValueKey('phone-code')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'confirmed binding with failed refresh clears one-use inputs and retries only me',
    (tester) async {
      var reads = 0;
      final harness = _bindingHarness(rejectRefresh: () => ++reads == 1);
      harness.auth.session = _session(hasPassword: true, phone: null);
      final owner = harness.auth.sessionOwner;
      final router = await _pumpRouter(
        tester,
        harness,
        mode: PhoneAuthMode.bindPhone,
      );
      await _prepareBinding(tester);
      await _tap(tester, '确认绑定手机号');
      expect(router.routerDelegate.state.uri.path, '/bind-phone');
      expect(find.byKey(const ValueKey('phone-code')), findsNothing);
      expect(
        find.byKey(const ValueKey('phone-current-password')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('phone-refresh-binding')),
        findsOneWidget,
      );
      await _tap(tester, '刷新账户并继续');
      expect(router.routerDelegate.state.uri.path, '/04');
      expect(harness.auth.sessionOwner, owner);
      expect(harness.auth.session!.user.phone, '13800138000');
      expect(
        harness.requests.where((r) => r.path.endsWith('/challenge')),
        hasLength(1),
      );
      expect(
        harness.requests.where((r) => r.path.endsWith('/bind')),
        hasLength(1),
      );
      expect(
        harness.requests.where((r) => r.path == '/api/v1/auth/me'),
        hasLength(2),
      );
      expect(harness.requests.where((r) => r.path.endsWith('/login')), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a send completed under a covering page retains its challenge', (
    tester,
  ) async {
    final entered = Completer<void>(), release = Completer<void>();
    var sends = 0;
    final harness = _Harness((options, handler) async {
      if (options.path.endsWith('/capabilities')) {
        _reply(options, handler, _capabilities());
      } else {
        expect(options.path, '/api/v1/auth/phone/challenge');
        sends++;
        entered.complete();
        await release.future;
        _reply(options, handler, _challenge());
      }
    });
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final router = await _pumpRouter(tester, harness);
    await tester.enterText(
      find.byKey(const ValueKey('phone-number')),
      '13800138000',
    );
    await tester.pump();
    await tester.ensureVisible(_button('获取短信验证码'));
    await tester.tap(_button('获取短信验证码'));
    await _waitFor(tester, entered);
    unawaited(router.push<void>('/covered'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    release.complete();
    await tester.pumpAndSettle();
    expect(router.routerDelegate.state.uri.path, '/covered');
    router.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('phone-code')), findsOneWidget);
    expect(_buttonWidget(tester, '验证并登录').onPressed, isNull);
    expect(sends, 1);
    expect(harness.auth.session, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'covered sensitive verification preserves its one-use proof without navigation',
    (tester) async {
      final entered = Completer<void>(), release = Completer<void>();
      var verifications = 0;
      PhoneSensitiveProof? proof;
      final harness = _Harness((options, handler) async {
        if (options.path.endsWith('/capabilities')) {
          _reply(options, handler, _capabilities());
        } else if (options.path.endsWith('/challenge')) {
          _reply(options, handler, _challenge());
        } else {
          expect(options.path, '/api/v1/auth/phone/verify-sensitive');
          verifications++;
          entered.complete();
          await release.future;
          _reply(options, handler, {
            'phoneProof': 'private-covered-proof',
            'expiresIn': 300,
          });
        }
      });
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      harness.auth.session = _session();
      final router = await _pumpRouter(
        tester,
        harness,
        mode: PhoneAuthMode.manageIdentity,
        phonePage: SeraScaffold(
          body: RecentPhoneVerification(
            repository: harness.phone,
            onVerified: (value) => proof = value,
          ),
        ),
      );
      await _tap(tester, '获取短信验证码');
      await tester.enterText(
        find.byKey(const ValueKey('phone-code')),
        '451236',
      );
      await tester.pump();
      await tester.ensureVisible(_button('验证当前手机号'));
      await tester.tap(_button('验证当前手机号'));
      await _waitFor(tester, entered);
      unawaited(router.push<void>('/covered'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      release.complete();
      await tester.pumpAndSettle();
      expect(router.routerDelegate.state.uri.path, '/covered');
      expect(proof, isNotNull);
      expect(proof!.consumed, isFalse);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('phone-code')), findsNothing);
      expect(find.textContaining('private-covered-proof'), findsNothing);
      expect(verifications, 1);
      expect(
        harness.requests.where((r) => r.path.endsWith('/challenge')),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('registration consent belongs to the normalized phone identity', (
    tester,
  ) async {
    final harness = _Harness((options, handler) {
      expect(options.path, '/api/v1/auth/phone/capabilities');
      _reply(options, handler, _capabilities());
    });
    await _pump(tester, harness);
    await tester.enterText(
      find.byKey(const ValueKey('phone-number')),
      '13800138000',
    );
    await tester.pump();
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isTrue,
    );
    await tester.enterText(
      find.byKey(const ValueKey('phone-number')),
      '+86 138-0013-8000',
    );
    await tester.pump();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isTrue,
    );
    await tester.enterText(
      find.byKey(const ValueKey('phone-number')),
      '13900139000',
    );
    await tester.pump();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isFalse,
    );
    expect(harness.requests, hasLength(1));
  });

  testWidgets(
    'cooldown and exact expiry boundaries never send or verify automatically',
    (tester) async {
      var clock = DateTime.now();
      var sends = 0;
      final harness = _Harness((options, handler) {
        if (options.path.endsWith('/capabilities')) {
          _reply(options, handler, {..._capabilities(), 'cooldownSeconds': 2});
        } else {
          expect(options.path, '/api/v1/auth/phone/challenge');
          sends++;
          _reply(
            options,
            handler,
            _challenge(
              referenceNow: clock,
              cooldownSeconds: 2,
              expiresSeconds: 4,
              id: 'challenge-$sends',
            ),
          );
        }
      }, now: () => clock);
      await _pump(tester, harness);
      await _send(tester);
      await tester.enterText(
        find.byKey(const ValueKey('phone-code')),
        '451236',
      );
      await tester.pump();
      expect(_buttonWidget(tester, '验证并登录').onPressed, isNotNull);
      clock = clock.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));
      expect(_buttonWidget(tester, '重新获取验证码').onPressed, isNotNull);
      expect(sends, 1);
      clock = clock.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));
      expect(_buttonWidget(tester, '验证并登录').onPressed, isNull);
      expect(find.textContaining('验证码已过期'), findsOneWidget);
      expect(sends, 1);
      await _tap(tester, '重新获取验证码');
      expect(sends, 2);
      expect(_field(tester, 'phone-code').controller!.text, isEmpty);
      expect(harness.requests.where((r) => r.path.endsWith('/login')), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final password in [false, true]) {
    testWidgets(
      'confirmed ${password ? 'password' : 'email binding'} clears one-use inputs and retries only identity read',
      (tester) async {
        var writes = 0, reads = 0;
        final harness = _Harness((options, handler) {
          if (options.path.endsWith('/capabilities')) {
            _reply(options, handler, _capabilities());
          } else if (options.path.endsWith('/challenge')) {
            _reply(options, handler, _challenge());
          } else if (options.path.endsWith('/verify-sensitive')) {
            _reply(options, handler, {
              'phoneProof': 'private-identity-proof',
              'expiresIn': 300,
            });
          } else if (options.path.endsWith('/set') ||
              options.path.endsWith('/confirm')) {
            writes++;
            expect(
              options.path,
              password
                  ? '/api/v1/auth/password/set'
                  : '/api/v1/auth/email/bind/confirm',
            );
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
                _session(
                  hasPassword: password,
                  email: password ? '' : 'bound@example.test',
                ).toJson(),
              );
            }
          }
        });
        harness.auth.session = _session();
        final owner = harness.auth.sessionOwner;
        await _pumpRouter(
          tester,
          harness,
          mode: PhoneAuthMode.manageIdentity,
          token: password ? null : 'private-email-token',
        );
        if (password) {
          await tester.ensureVisible(find.widgetWithText(ChoiceChip, '设置密码'));
          await tester.tap(find.widgetWithText(ChoiceChip, '设置密码'));
          await tester.pumpAndSettle();
          await _tap(tester, '获取短信验证码');
          await tester.enterText(
            find.byKey(const ValueKey('phone-code')),
            '451236',
          );
          await _tap(tester, '验证当前手机号');
          await tester.enterText(
            find.byKey(const ValueKey('identity-new-password')),
            'private-new-password',
          );
          await tester.enterText(
            find.byKey(const ValueKey('identity-confirm-password')),
            'private-new-password',
          );
          await _tap(tester, '设置账户密码');
        } else {
          await _tap(tester, '确认绑定电子邮箱');
        }
        expect(find.byKey(const ValueKey('identity-refresh')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('identity-new-password')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('phone-code')), findsNothing);
        expect(find.text('private-email-token'), findsNothing);
        expect(find.text('private-new-password'), findsNothing);
        final refreshRect = tester.getRect(
          find.byKey(const ValueKey('identity-refresh')),
        );
        expect(
          refreshRect.overlaps(const Rect.fromLTWH(0, 0, 390, 844)),
          isTrue,
        );
        await _tap(tester, '刷新账户状态');
        expect(find.byKey(const ValueKey('identity-refresh')), findsNothing);
        expect(writes, 1);
        expect(reads, 2);
        expect(harness.auth.sessionOwner, owner);
        expect(harness.auth.session!.user.hasPassword, password);
        expect(
          harness.auth.session!.user.email,
          password ? '' : 'bound@example.test',
        );
        expect(
          harness.requests.where((r) => r.path.endsWith('/challenge')),
          hasLength(password ? 1 : 0),
        );
        expect(
          harness.storage.values.values.join(),
          isNot(contains('private-new-password')),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

_Harness _bindingHarness({
  Future<void> Function()? beforeBind,
  Future<void> Function()? beforeRefresh,
  bool Function()? rejectRefresh,
}) => _Harness((options, handler) async {
  if (options.path.endsWith('/capabilities')) {
    _reply(options, handler, _capabilities());
  } else if (options.path.endsWith('/challenge')) {
    expect((options.data as Map)['purpose'], 'bind_phone');
    _reply(options, handler, _challenge());
  } else if (options.path.endsWith('/bind')) {
    await beforeBind?.call();
    _reply(options, handler, {'bound': true});
  } else {
    expect(options.path, '/api/v1/auth/me');
    await beforeRefresh?.call();
    if (rejectRefresh?.call() == true) {
      _reject(options, handler, 503, '账户状态暂时无法读取。');
    } else {
      _reply(options, handler, _session(hasPassword: true).toJson());
    }
  }
});

Future<GoRouter> _pumpRouter(
  WidgetTester tester,
  _Harness harness, {
  PhoneAuthMode mode = PhoneAuthMode.login,
  VoidCallback? onCompleted,
  String? token,
  Widget? phonePage,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final location = switch (mode) {
    PhoneAuthMode.login => '/phone-login',
    PhoneAuthMode.bindPhone => '/bind-phone',
    PhoneAuthMode.manageIdentity => '/phone-identity',
  };
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: location,
        builder: (_, _) =>
            phonePage ??
            PhoneAuthScreen(
              mode: mode,
              repository: harness.phone,
              onCompleted: onCompleted,
              token: token,
            ),
      ),
      for (final path in ['/02', '/04', '/30', '/covered'])
        GoRoute(
          path: path,
          builder: (_, _) => Scaffold(
            body: Text(
              path,
              key: ValueKey(path == '/covered' ? 'covered-page' : path),
            ),
          ),
        ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    router.dispose();
    harness.auth.dispose();
  });
  await tester.pumpWidget(
    ChangeNotifierProvider<AuthRepository>.value(
      value: harness.auth,
      child: MaterialApp.router(theme: seraTheme(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

Future<void> _prepareBinding(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('phone-number')),
    '13800138000',
  );
  await tester.enterText(
    find.byKey(const ValueKey('phone-current-password')),
    'current-password',
  );
  await _tap(tester, '获取短信验证码');
  await tester.enterText(find.byKey(const ValueKey('phone-code')), '451236');
  await tester.pump();
}

Future<void> _waitFor(WidgetTester tester, Completer<void> entered) async {
  for (var attempt = 0; attempt < 50 && !entered.isCompleted; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(
    entered.isCompleted,
    isTrue,
    reason: 'The intercepted request did not start.',
  );
}

Future<void> _pump(
  WidgetTester tester,
  _Harness harness, {
  PhoneAuthMode mode = PhoneAuthMode.login,
  VoidCallback? onEmailLogin,
  ValueChanged<bool>? onAuthenticated,
}) async {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    harness.auth.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: seraTheme(),
      home: PhoneAuthScreen(
        mode: mode,
        repository: harness.phone,
        onEmailLogin: onEmailLogin ?? () {},
        onAuthenticated: onAuthenticated ?? (_) {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _send(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('phone-number')),
    '13800138000',
  );
  await _tap(tester, '获取短信验证码');
}

Finder _button(String text) => find.widgetWithText(SeraButton, text);
SeraButton _buttonWidget(WidgetTester tester, String text) =>
    tester.widget<SeraButton>(_button(text));
TextFormField _field(WidgetTester tester, String key) =>
    tester.widget<TextFormField>(find.byKey(ValueKey(key)));

Future<void> _tap(WidgetTester tester, String label) async {
  // Editing can queue a caret/keyboard scroll after the next frame. Let it
  // finish before positioning the action, then hit-test its actual control.
  await tester.pumpAndSettle();
  await tester.ensureVisible(_button(label));
  await tester.pumpAndSettle();
  expect(
    _buttonWidget(tester, label).onPressed,
    isNotNull,
    reason: 'The action must be enabled after input state has rebuilt.',
  );
  final control = find.descendant(
    of: _button(label),
    matching: find.byType(TextButton),
  );
  expect(
    control.hitTestable(),
    findsOneWidget,
    reason: 'The action must be reachable after scrolling settles.',
  );
  await tester.tap(control);
  await tester.pumpAndSettle();
}

Map<String, dynamic> _capabilities() => {
  'enabled': true,
  'message': '支持中国大陆手机号。',
  'codeLength': 6,
  'cooldownSeconds': 60,
};
Map<String, dynamic> _challenge({
  DateTime? referenceNow,
  int cooldownSeconds = 60,
  int expiresSeconds = 300,
  String id = 'challenge-a',
}) => {
  'challengeId': id,
  'maskedPhone': '138****8000',
  'expiresAt': (referenceNow ?? DateTime.now())
      .add(Duration(seconds: expiresSeconds))
      .toUtc()
      .toIso8601String(),
  'resendAt': (referenceNow ?? DateTime.now())
      .add(Duration(seconds: cooldownSeconds))
      .toUtc()
      .toIso8601String(),
  'deliveryStatus': 'submitted',
  'message': '验证码已提交发送，请查看手机短信。',
};

AuthSession _session({
  String id = 'phone-user',
  bool hasPassword = false,
  String? phone = '13800138000',
  String email = '',
}) => AuthSession(
  token: 'native-session',
  sessionId: 'session-a',
  expiresAt: DateTime.now().add(const Duration(days: 1)),
  user: AuthUser(
    id: id,
    username: 'phone-user',
    email: email,
    emailVerified: email.isNotEmpty,
    phone: phone,
    hasPassword: hasPassword,
  ),
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
      apiBaseUrl: 'http://phone-ui.test',
      client: client,
      storage: storage,
      accountEvents: _Events(),
    );
    phone = PhoneAuthRepository(auth: auth, now: now);
  }
  final requests = <RequestOptions>[];
  final interceptorErrors = <Object>[];
  final storage = _Storage();
  late final AuthRepository auth;
  late final PhoneAuthRepository phone;
}

class _Storage implements AuthSessionStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
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
