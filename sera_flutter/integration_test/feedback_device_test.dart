import 'dart:math';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sera_flutter/application/auth_shell.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';

// Run only in the separate QA application against an isolated real database.
// The API must use SERA_MAIL_MODE=local. No mailbox token, verification link,
// password, HTTP response body or screen dump is written to the test report.
// Example (the runner owns the server, QA package and MuMu1 reverse mapping):
// flutter test integration_test/feedback_device_test.dart -d 127.0.0.1:16416
//   --dart-define=API_BASE_URL=http://127.0.0.1:<isolated-port>
//   --dart-define=FEEDBACK_QA_ONLINE=true
// Online interpretation may incur provider charges and is disabled by default.
const _api = String.fromEnvironment('API_BASE_URL');
const _online = bool.fromEnvironment('FEEDBACK_QA_ONLINE', defaultValue: false);
const _prompt = '明天下午三点和同学讨论课程设计，持续半小时，请作为固定日程交给我核对。';

Finder _button(String label) => find.widgetWithText(SeraButton, label);

Finder _input(String label) => find.descendant(
  of: find.widgetWithText(SeraInput, label),
  matching: find.byType(TextFormField),
);

Future<void> _tick(
  WidgetTester tester, [
  Duration duration = const Duration(milliseconds: 150),
]) async {
  await tester.runAsync(() => Future<void>.delayed(duration));
  await tester.pump(const Duration(milliseconds: 30));
}

Future<void> _wait(
  WidgetTester tester,
  bool Function() ready, {
  required String checkpoint,
  Duration timeout = const Duration(seconds: 35),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await _tick(tester);
  }
  // Do not dump the screen here: the mailbox legitimately contains a secret.
  expect(ready(), isTrue, reason: checkpoint);
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await _wait(tester, () {
    final elements = target.evaluate();
    if (elements.isEmpty) return false;
    final widget = elements.first.widget;
    if (widget is SeraButton) {
      return widget.onPressed != null && !widget.busy;
    }
    if (widget is TextButton) return widget.onPressed != null;
    if (widget is IconButton) return widget.onPressed != null;
    return true;
  }, checkpoint: 'An expected UI action did not become available.');
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.ensureVisible(target.first);
  await tester.tap(target.first);
  await _tick(tester);
}

Future<void> _enter(WidgetTester tester, Finder field, String value) async {
  await _wait(
    tester,
    () => field.evaluate().isNotEmpty,
    checkpoint: 'An expected editable input did not appear.',
  );
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pump();
}

Future<Response<dynamic>> _request(
  WidgetTester tester,
  Future<Response<dynamic>> Function() action,
) async {
  // No logging interceptor is installed. Suppress exception details because
  // these operations include account credentials and authenticated mail data.
  try {
    final response = await tester.runAsync(action);
    if (response != null) return response;
  } catch (_) {
    fail('A real QA HTTP request failed; inspect the isolated service logs.');
  }
  fail('A real QA HTTP request did not finish.');
}

Map<String, dynamic> _object(Object? value) =>
    Map<String, dynamic>.from(value as Map);

List<Map<String, dynamic>> _objects(Object? value) =>
    (value as List? ?? const []).map(_object).toList();

Future<Map<String, dynamic>> _workspace(
  WidgetTester tester,
  Dio inspector,
) async {
  final response = await _request(
    tester,
    () => inspector.get<dynamic>('/api/v1/sync/state'),
  );
  expect(response.statusCode, 200, reason: 'Read the real QA account state.');
  return _object(_object(response.data)['workspace']);
}

Future<Map<String, dynamic>> _remoteUntil(
  WidgetTester tester,
  Dio inspector,
  bool Function(Map<String, dynamic>) ready, {
  required String checkpoint,
  Duration timeout = const Duration(seconds: 35),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final workspace = await _workspace(tester, inspector);
    if (ready(workspace)) return workspace;
    await _tick(tester, const Duration(milliseconds: 250));
  }
  fail(checkpoint);
}

Future<void> _openAccount(WidgetTester tester) async {
  if (find.byTooltip('账户与设置').evaluate().isEmpty) {
    await _tap(tester, find.text('今日').last);
  }
  await _tap(tester, find.byTooltip('账户与设置'));
  await _tap(tester, find.byKey(const ValueKey('profile-account-entry')));
  await _wait(
    tester,
    () => _button('退出登录').evaluate().isNotEmpty,
    checkpoint: 'The authenticated account page did not open.',
  );
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real QA email verification and opt-in online event review', (
    tester,
  ) async {
    final uri = Uri.tryParse(_api);
    expect(
      uri != null &&
          const ['http', 'https'].contains(uri.scheme) &&
          uri.host.isNotEmpty,
      isTrue,
      reason: 'Supply API_BASE_URL for the isolated real QA service.',
    );
    final stamp =
        '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 20)}';
    final username = 'qa_fb_$stamp';
    final email = '$username@example.invalid';
    final password = 'Sera-QA!$stamp';
    final inspector = Dio(
      BaseOptions(
        baseUrl: _api,
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 20),
        headers: {'X-Sera-Client': 'native'},
        validateStatus: (status) => status != null && status < 600,
      ),
    );
    var registrationAttempted = false;
    String? createdUserId;
    var mailVerified = false, onlineSaved = false, cleanupConfirmed = false;
    try {
      final health = await _request(
        tester,
        () => inspector.get<dynamic>('/health/live'),
      );
      expect(health.statusCode, 200, reason: 'Start the isolated QA API.');
      registrationAttempted = true;
      final registered = await _request(
        tester,
        () => inspector.post<dynamic>(
          '/api/v1/auth/register',
          data: {'username': username, 'email': email, 'password': password},
        ),
      );
      expect(
        registered.statusCode,
        201,
        reason: 'Create only this run\'s random QA account.',
      );
      final session = _object(registered.data);
      final user = _object(session['user']);
      expect(user['email'] == email && user['username'] == username, isTrue);
      expect(user['emailVerified'], isFalse);
      createdUserId = user['id'] as String;
      inspector.options.headers['Authorization'] = 'Bearer ${session['token']}';

      final mailboxMode = await _request(
        tester,
        () => inspector.get<dynamic>(
          '/api/v1/auth/development-mailbox?purpose=verify-email',
        ),
      );
      expect(
        mailboxMode.statusCode,
        200,
        reason: 'This test requires an isolated SERA_MAIL_MODE=local API.',
      );
      expect(_object(mailboxMode.data)['deliveryMode'], 'local');
      expect(_object(mailboxMode.data)['mail'] == null, isTrue);

      await tester.pumpWidget(const SeraRoot(apiBaseUrl: _api));
      await _wait(
        tester,
        () =>
            _button('登录').evaluate().isNotEmpty ||
            find.byTooltip('账户与设置').evaluate().isNotEmpty ||
            _button('继续，连接已有日历').evaluate().isNotEmpty,
        checkpoint: 'The isolated QA app did not restore its session.',
      );
      if (_button('登录').evaluate().isEmpty) {
        // A surviving QA package session is signed out through the UI. Its
        // workspace/account is neither reset nor deleted by this test.
        if (_button('继续，连接已有日历').evaluate().isNotEmpty) {
          await _tap(tester, find.byTooltip('返回'));
        }
        await _openAccount(tester);
        await _tap(tester, _button('退出登录'));
      }
      await _enter(tester, _input('邮箱或用户名'), email);
      await _enter(tester, find.byType(TextFormField).last, password);
      await _tap(tester, _button('登录'));
      await _wait(
        tester,
        () =>
            _button('继续，连接已有日历').evaluate().isNotEmpty ||
            find.byTooltip('账户与设置').evaluate().isNotEmpty,
        checkpoint: 'UI login did not open onboarding or Today.',
      );
      if (_button('继续，连接已有日历').evaluate().isNotEmpty) {
        await _tap(tester, _button('继续，连接已有日历'));
        await _tap(tester, _button('继续，查看今天'));
      }
      await _openAccount(tester);
      await _tap(tester, _button('验证电子邮箱'));
      await _tap(tester, find.text('测试验证邮件'));
      await _tap(tester, _button('查看测试验证邮件'));
      await _tap(tester, _button('发送验证邮件'));
      await _wait(
        tester,
        () => _button('使用此链接验证邮箱').evaluate().isNotEmpty,
        checkpoint: 'The real local mail was not exposed in the signed-in UI.',
      );
      final sentMailbox = await _request(
        tester,
        () => inspector.get<dynamic>(
          '/api/v1/auth/development-mailbox?purpose=verify-email',
        ),
      );
      expect(sentMailbox.statusCode, 200);
      expect(_object(sentMailbox.data)['deliveryMode'], 'local');
      expect(_object(sentMailbox.data)['mail'] is Map, isTrue);
      expect(sentMailbox.headers.value('cache-control'), 'no-store');
      await _tap(tester, _button('使用此链接验证邮箱'));
      await _wait(
        tester,
        () => find
            .byWidgetPredicate(
              (widget) => widget is SeraNote && widget.title == '邮箱已验证',
            )
            .evaluate()
            .isNotEmpty,
        checkpoint:
            'Following the real local verification link did not update the UI.',
      );
      final me = await _request(
        tester,
        () => inspector.get<dynamic>('/api/v1/auth/me'),
      );
      expect(me.statusCode, 200);
      expect(_object(_object(me.data)['user'])['emailVerified'], isTrue);
      final consumed = await _request(
        tester,
        () => inspector.get<dynamic>(
          '/api/v1/auth/development-mailbox?purpose=verify-email',
        ),
      );
      expect(consumed.statusCode, 200);
      expect(_object(consumed.data)['mail'] == null, isTrue);
      mailVerified = true;

      if (_online) {
        await _tap(tester, _button('返回账户'));
        await _tap(tester, find.byTooltip('返回'));
        await _tap(tester, find.byTooltip('返回'));
        await _tap(tester, find.byKey(const ValueKey('today-capture')));
        await _tap(tester, find.text('文字输入'));
        final composer = find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.hintText == '要做什么？',
        );
        await _enter(tester, composer, _prompt);
        await _tap(tester, _button('让 AI 安排'));
        await _wait(
          tester,
          () => find.widgetWithText(AppBar, 'AI 助手').evaluate().isNotEmpty,
          checkpoint: 'Today capture did not reach the assistant.',
        );
        expect(find.text(_prompt), findsOneWidget);
        await _tick(tester, const Duration(milliseconds: 900));
        final before = await _workspace(tester, inspector);
        expect(_objects(before['entries']), isEmpty);
        expect(_objects(before['tasks']), isEmpty);
        expect(
          _objects(before['planningSessions']).single['understandingRequestId']
              is String,
          isTrue,
          reason: 'An explicit home submit must persist its single understanding request.',
        );
        await _wait(
          tester,
          () =>
              find.text('编辑固定事项').evaluate().isNotEmpty ||
              find
                  .byWidgetPredicate(
                    (widget) => widget is SeraNote && widget.title == '理解尚未完成',
                  )
                  .evaluate()
                  .isNotEmpty,
          checkpoint: 'The real online interpretation did not finish.',
          timeout: const Duration(seconds: 150),
        );
        expect(
          find.text('编辑固定事项').evaluate().isNotEmpty,
          isTrue,
          reason: 'The real model must identify this input as an event.',
        );
        final interpreted = await _remoteUntil(
          tester,
          inspector,
          (w) => _objects(w['planningSessions'])
              .any((s) => s['prompt'] == _prompt && s['understanding'] is Map),
          checkpoint: 'The real model result did not persist.',
        );
        final planning = _objects(interpreted['planningSessions']).singleWhere(
          (s) => s['prompt'] == _prompt && s['understanding'] is Map,
        );
        final result = _object(planning['understanding']);
        final input = _object(planning['understandingInput']);
        expect(result['intent'], 'event');
        expect(result['source'], 'siliconflow');
        expect(
          result['model'] is String && (result['model'] as String).isNotEmpty,
          isTrue,
        );
        expect(input['prompt'], _prompt);
        expect(input['timeZone'], 'Asia/Hong_Kong');
        debugPrint(
          'QA online interpretation: ${jsonEncode({'referenceNow': input['referenceNow'], 'timeZone': input['timeZone'], 'intent': result['intent'], 'source': result['source'], 'model': result['model'], 'summary': result['summary'], 'outcome': result['outcome'], 'start': result['start'], 'end': result['end'], 'deadline': result['deadline'], 'estimatedMinutes': result['estimatedMinutes']})}',
        );
        expect(result['start'] is String && result['end'] is String, isTrue);
        final start = DateTime.parse(result['start'] as String).toUtc();
        final end = DateTime.parse(result['end'] as String).toUtc();
        final reference = DateTime.parse(input['referenceNow'] as String)
            .toUtc()
            .add(const Duration(hours: 8));
        final tomorrow = DateTime.utc(
          reference.year,
          reference.month,
          reference.day + 1,
        );
        final localStart = start.add(const Duration(hours: 8));
        expect(
          DateTime.utc(localStart.year, localStart.month, localStart.day),
          tomorrow,
        );
        expect(localStart.hour, 15);
        expect(localStart.minute, 0);
        expect(end.difference(start), const Duration(minutes: 30));
        expect(result['deadline'], isNull);
        expect(result['estimatedMinutes'], 30);
        expect(
          RegExp(
            '已(?:经)?(?:安排|创建|保存|完成|设定)',
          ).hasMatch('${result['summary'] ?? ''} ${result['outcome'] ?? ''}'),
          isFalse,
          reason: 'Understanding must not claim an unconfirmed action was completed.',
        );
        expect(_objects(interpreted['entries']), isEmpty);
        expect(_objects(interpreted['tasks']), isEmpty);
        expect(_objects(interpreted['goals']), isEmpty);

        await _tap(tester, find.text('编辑固定事项'));
        await _wait(
          tester,
          () => _input('日程名称').evaluate().isNotEmpty,
          checkpoint: 'The interpreted event did not open the real editor.',
        );
        expect(
          tester.widget<TextFormField>(_input('日程名称')).controller!.text,
          result['title'],
        );
        expect(
          tester
              .widget<TextFormField>(_input('备注'))
              .controller!
              .text
              .contains(_prompt),
          isTrue,
        );
        for (final pair in [
          ('开始', localStart),
          ('结束', end.add(const Duration(hours: 8))),
        ]) {
          final field = find.byWidgetPredicate(
            (widget) => widget is SeraField && widget.label == pair.$1,
          );
          expect(
            tester.widget<SeraField>(field).value,
            '${formatDate(pair.$2)} ${formatTime(pair.$2)}',
          );
        }
        expect(
          tester
              .widget<SwitchListTile>(
                find.widgetWithText(SwitchListTile, '固定这个时间'),
              )
              .value,
          isTrue,
        );
        final beforeSave = await _workspace(tester, inspector);
        expect(
          _objects(beforeSave['entries']),
          isEmpty,
          reason: 'Reviewing an AI suggestion must not create an event.',
        );
        expect(_objects(beforeSave['tasks']), isEmpty);
        expect(_objects(beforeSave['goals']), isEmpty);
        await _tap(tester, _button('保存日程'));
        final saved = await _remoteUntil(
          tester,
          inspector,
          (w) =>
              _objects(w['entries']).any((e) => e['title'] == result['title']),
          checkpoint: 'The explicitly saved event did not reach the real API.',
        );
        final event = _objects(saved['entries']).single;
        expect(event['title'], result['title']);
        expect(DateTime.parse(event['start'] as String).toUtc(), start);
        expect(DateTime.parse(event['end'] as String).toUtc(), end);
        expect(event['taskId'], isNull);
        expect(event['locked'], isTrue);
        expect((event['notes'] as String).contains(_prompt), isTrue);
        expect(_objects(saved['tasks']), isEmpty);
        onlineSaved = true;
      }
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await _tick(tester);
      try {
        if (registrationAttempted) {
          inspector.options.headers.remove('Authorization');
          final login = await _request(
            tester,
            () => inspector.post<dynamic>(
              '/api/v1/auth/login',
              data: {'identifier': email, 'password': password},
            ),
          );
          if (login.statusCode == 200) {
            final session = _object(login.data);
            final user = _object(session['user']);
            final ownsAccount =
                user['email'] == email &&
                user['username'] == username &&
                (createdUserId == null || user['id'] == createdUserId);
            expect(
              ownsAccount,
              isTrue,
              reason: 'Refuse cleanup unless exact QA account ownership is confirmed.',
            );
            if (ownsAccount) {
              inspector.options.headers['Authorization'] =
                  'Bearer ${session['token']}';
              final deleted = await _request(
                tester,
                () => inspector.delete<dynamic>(
                  '/api/v1/account',
                  data: {'password': password},
                ),
              );
              expect(
                deleted.statusCode,
                200,
                reason: 'Delete only this run\'s confirmed QA account.',
              );
              final revoked = await _request(
                tester,
                () => inspector.get<dynamic>('/api/v1/auth/me'),
              );
              expect(
                revoked.statusCode,
                401,
                reason: 'Deleting the QA account must revoke its session.',
              );
              cleanupConfirmed =
                  deleted.statusCode == 200 && revoked.statusCode == 401;
            }
          } else {
            expect(
              login.statusCode,
              401,
              reason: 'Could not confirm this run\'s QA account cleanup.',
            );
            cleanupConfirmed = login.statusCode == 401;
          }
        }
      } finally {
        binding.reportData = {
          'localEmailVerified': mailVerified,
          'onlineEnabled': _online,
          'onlineEventSaved': onlineSaved,
          'ownAccountCleanupConfirmed': cleanupConfirmed,
        };
        inspector.close(force: true);
      }
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
