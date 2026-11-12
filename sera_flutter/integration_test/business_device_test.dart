import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sera_flutter/application/auth_shell.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';

// Run on MuMu1 against the real, already running API. This test never requests
// AI generation, mocks business data, or deletes an account it did not create.
// adb -s 127.0.0.1:16416 reverse tcp:8787 tcp:8787
// flutter test integration_test/business_device_test.dart \
//   -d 127.0.0.1:16416 --dart-define=API_BASE_URL=http://127.0.0.1:8787
const _api = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8787',
);

Finder _button(String text) => find.widgetWithText(SeraButton, text);

Finder _bottomDestination(WidgetTester tester, String label) {
  final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).last);
  return find.descendant(
    of: find.byWidget(scaffold.bottomNavigationBar!),
    matching: find.text(label),
  );
}

Future<void> _tick(
  WidgetTester tester, [
  Duration duration = const Duration(milliseconds: 120),
]) async {
  // Network, secure storage and native callbacks need the real event loop.
  // pumpAndSettle cannot be used while the persistent focus timer is running.
  await tester.runAsync(() => Future<void>.delayed(duration));
  await tester.pump(const Duration(milliseconds: 30));
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() ready, {
  required String reason,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await _tick(tester);
  }
  if (!ready()) {
    final visibleText = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? '')
        .where((text) => text.isNotEmpty)
        .map(
          (text) => text
              .replaceAll(RegExp(r'qa_ui_[A-Za-z0-9_]+'), '[QA account]')
              .replaceAll(RegExp(r'Sera-QA![A-Za-z0-9_]+'), '[QA password]')
              .replaceAll(RegExp(r'[^\s@]+@[^\s@]+\.[^\s@]+'), '[email]'),
        )
        .take(35)
        .toList();
    debugPrint('QA screen checkpoint: $visibleText');
  }
  expect(ready(), isTrue, reason: reason);
}

Future<void> _waitFor(WidgetTester tester, Finder finder) => _waitUntil(
  tester,
  () => finder.evaluate().isNotEmpty,
  reason: 'Expected the real application to display $finder.',
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _waitUntil(tester, () {
    final elements = finder.evaluate();
    if (elements.isEmpty) return false;
    final widget = elements.first.widget;
    if (widget is SeraButton) {
      return widget.onPressed != null && !widget.busy;
    }
    if (widget is IconButton) return widget.onPressed != null;
    if (widget is TextButton) return widget.onPressed != null;
    return true;
  }, reason: 'Expected an enabled UI action: $finder.');
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.ensureVisible(finder.first);
  await tester.tap(finder.first);
  await _tick(tester);
}

Future<void> _enter(WidgetTester tester, Finder field, String value) async {
  await _waitFor(tester, field);
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pump();
}

Finder _input(String label) => find.descendant(
  of: find.widgetWithText(SeraInput, label),
  matching: find.byType(TextFormField),
);

Future<Response<dynamic>> _request(
  WidgetTester tester,
  Future<Response<dynamic>> Function() action,
) async {
  final response = await tester.runAsync(action);
  expect(response, isNotNull, reason: 'The real HTTP request did not finish.');
  return response!;
}

Map<String, dynamic> _object(Object? value) =>
    Map<String, dynamic>.from(value as Map);

List<Map<String, dynamic>> _objects(Object? value) =>
    (value as List? ?? const []).map(_object).toList();

Future<Map<String, dynamic>> _remoteUntil(
  WidgetTester tester,
  Dio inspector,
  bool Function(Map<String, dynamic>) ready, {
  required String reason,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(deadline)) {
    final response = await _request(
      tester,
      () => inspector.get<dynamic>('/api/v1/sync/state'),
    );
    expect(
      response.statusCode,
      200,
      reason: 'Authenticated state read failed.',
    );
    final body = _object(response.data);
    final workspace = body['workspace'] is Map
        ? _object(body['workspace'])
        : <String, dynamic>{};
    if (ready(workspace)) return workspace;
    await _tick(tester, const Duration(milliseconds: 200));
  }
  fail(reason);
}

Future<void> _openAccount(WidgetTester tester) async {
  if (find.byTooltip('账户与设置').evaluate().isEmpty) {
    await _tap(tester, _bottomDestination(tester, '今日'));
  }
  await _tap(tester, find.byTooltip('账户与设置'));
  await _tap(tester, find.byKey(const ValueKey('profile-account-entry')));
  await _waitFor(tester, _button('退出登录'));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'MuMu1 real account, inbox, focus, completion and login persistence',
    (tester) async {
      expect(
        Uri.tryParse(_api)?.hasScheme,
        isTrue,
        reason: 'Supply a device-reachable API_BASE_URL, not same-origin.',
      );
      final stamp =
          '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 20)}';
      final username = 'qa_ui_$stamp';
      final email = '$username@example.invalid';
      final password = 'Sera-QA!$stamp';
      final taskTitle = 'QA设备业务收件箱_$stamp';
      final inspector = Dio(
        BaseOptions(
          baseUrl: _api,
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 15),
          headers: {'X-Sera-Client': 'native'},
          validateStatus: (status) => status != null && status < 600,
        ),
      );
      var registrationAttempted = false;
      var deletedThroughUi = false;
      String? createdUserId;
      try {
        final health = await _request(
          tester,
          () => inspector.get<dynamic>('/health/live'),
        );
        expect(health.statusCode, 200, reason: 'Start the API on host 8787.');
        await tester.pumpWidget(const SeraRoot(apiBaseUrl: _api));
        await _waitUntil(
          tester,
          () =>
              _button('登录').evaluate().isNotEmpty ||
              find.byTooltip('账户与设置').evaluate().isNotEmpty ||
              find.widgetWithText(AppBar, '你的节奏').evaluate().isNotEmpty,
          reason: 'The real root did not finish restoring its native session.',
        );

        // A prior device session may exist. Only sign it out through its UI;
        // never reset its workspace, import data, or delete that unknown user.
        if (_button('登录').evaluate().isEmpty) {
          if (find.widgetWithText(AppBar, '你的节奏').evaluate().isNotEmpty) {
            await _tap(tester, find.byTooltip('返回'));
          }
          await _openAccount(tester);
          await _tap(tester, _button('退出登录'));
          await _waitFor(tester, _button('登录'));
        }

        await _tap(tester, _button('还没有账户，去注册'));
        await _waitFor(tester, _input('用户名'));
        await _enter(tester, _input('用户名'), username);
        await _enter(tester, _input('电子邮箱'), email);
        expect(find.byType(TextFormField), findsNWidgets(4));
        await _enter(tester, find.byType(TextFormField).at(2), password);
        await _enter(tester, find.byType(TextFormField).at(3), password);
        registrationAttempted = true;
        await _tap(tester, _button('创建账户并开始'));
        await _waitFor(tester, _button('继续，连接已有日历'));
        await _tap(tester, _button('继续，连接已有日历'));
        await _tap(tester, _button('继续，查看今天'));
        await _waitFor(tester, find.byTooltip('账户与设置'));
        expect(find.byKey(const ValueKey('today-capture')), findsOneWidget);

        // Obtain an independent native HTTP session for read-only inspection.
        // Registration itself was performed by the production UI above.
        final login = await _request(
          tester,
          () => inspector.post<dynamic>(
            '/api/v1/auth/login',
            data: {'identifier': email, 'password': password},
          ),
        );
        expect(login.statusCode, 200, reason: 'The new UI account must exist.');
        final session = _object(login.data);
        final user = _object(session['user']);
        expect(user['username'], username);
        expect(user['email'], email);
        createdUserId = user['id'] as String;
        inspector.options.headers['Authorization'] =
            'Bearer ${session['token']}';

        await _tap(tester, find.byKey(const ValueKey('today-capture')));
        await _tap(tester, find.text('文字输入'));
        await _tap(tester, find.text('手动添加任务'));
        await _enter(tester, _input('要做什么？'), taskTitle);
        await _tap(tester, find.text('安排时间'));
        await _enter(tester, _input('补充说明'), '仅由本次设备集成测试创建。');
        await _enter(tester, _input('预计用时（分钟）'), '5');
        await _tap(tester, find.widgetWithText(ChoiceChip, '暂不安排'));
        await _tap(tester, _button('保存任务'));
        await _waitFor(tester, find.widgetWithText(AppBar, '今日'));
        await _tap(tester, _bottomDestination(tester, '计划'));
        await _waitFor(tester, find.widgetWithText(AppBar, '计划'));
        await _tap(tester, find.text(taskTitle));
        await _waitFor(tester, find.widgetWithText(AppBar, '任务详情'));
        final created = await _remoteUntil(
          tester,
          inspector,
          (w) => _objects(w['tasks']).any((t) => t['title'] == taskTitle),
          reason: 'UI task save never reached the authenticated server.',
        );
        final savedTask = _objects(created['tasks'])
            .singleWhere((t) => t['title'] == taskTitle);
        final taskId = savedTask['id'] as String;
        expect(savedTask['status'], 'todo');
        expect(savedTask['estimatedMinutes'], 5);
        expect(
          _objects(created['entries']).where((e) => e['taskId'] == taskId),
          isEmpty,
        );
        expect(
          _object(created['platformSettings'])['onboardingComplete'],
          isTrue,
        );

        await _tap(tester, _button('开始专注'));
        await _waitFor(tester, find.byTooltip('暂停专注'));
        await _remoteUntil(
          tester,
          inspector,
          (w) =>
              w['focusSession'] is Map &&
              _object(w['focusSession'])['taskId'] == taskId &&
              _object(w['focusSession'])['isRunning'] == true,
          reason: 'Starting focus did not persist the real running session.',
        );
        await _tick(tester, const Duration(milliseconds: 1400));
        await _tap(tester, find.byTooltip('暂停专注'));
        final paused = await _remoteUntil(
          tester,
          inspector,
          (w) =>
              w['focusSession'] is Map &&
              _object(w['focusSession'])['isRunning'] == false,
          reason: 'Pausing focus did not persist the paused state.',
        );
        final pausedSeconds =
            (_object(paused['focusSession'])['accumulatedSeconds'] as num)
                .toInt();
        expect(pausedSeconds, greaterThanOrEqualTo(1));
        await _tick(tester, const Duration(milliseconds: 1100));
        final stillPaused = await _remoteUntil(
          tester,
          inspector,
          (w) => _object(w['focusSession'])['isRunning'] == false,
          reason: 'The paused session unexpectedly resumed.',
        );
        expect(
          _object(stillPaused['focusSession'])['accumulatedSeconds'],
          pausedSeconds,
          reason: 'Paused wall time must not become actual focus time.',
        );
        await _tap(tester, find.byTooltip('继续专注'));
        await _remoteUntil(
          tester,
          inspector,
          (w) => _object(w['focusSession'])['isRunning'] == true,
          reason: 'Resuming focus did not persist the running state.',
        );
        await _tick(tester, const Duration(milliseconds: 1400));
        await _tap(tester, find.byTooltip('结束并保存专注'));
        await _tap(tester, find.widgetWithText(TextButton, '结束并保存'));
        await _waitFor(tester, _button('已完成，更新任务进度'));
        final focused = await _remoteUntil(
          tester,
          inspector,
          (w) =>
              w['focusSession'] == null &&
              _objects(w['focusRecords']).any((r) => r['taskId'] == taskId),
          reason: 'Finishing focus did not persist the actual focus record.',
        );
        final record = _objects(focused['focusRecords'])
            .singleWhere((r) => r['taskId'] == taskId);
        final seconds = (record['seconds'] as num).toInt();
        expect(seconds, greaterThan(pausedSeconds));
        final focusedTask = _objects(focused['tasks'])
            .singleWhere((t) => t['id'] == taskId);
        expect(focusedTask['actualSeconds'], seconds);
        expect(focusedTask['status'], 'in_progress');

        await _tap(tester, _button('已完成，更新任务进度'));
        await _waitFor(tester, _button('设为未完成'));
        await _remoteUntil(
          tester,
          inspector,
          (w) => _objects(w['tasks']).any(
            (t) =>
                t['id'] == taskId &&
                t['status'] == 'done' &&
                t['actualSeconds'] == seconds,
          ),
          reason: 'Completion did not persist task status and actual seconds.',
        );

        await _tap(tester, find.byTooltip('返回'));
        await _openAccount(tester);
        expect(find.text(username), findsOneWidget);
        await _tap(tester, _button('退出登录'));
        await _waitFor(tester, _button('登录'));
        await _enter(tester, _input('邮箱或用户名'), email);
        await _enter(tester, find.byType(TextFormField).last, password);
        await _tap(tester, _button('登录'));
        await _waitFor(tester, find.byTooltip('账户与设置'));
        expect(_button('继续，连接已有日历'), findsNothing);
        await _tap(tester, _bottomDestination(tester, '计划'));
        await _waitFor(tester, find.widgetWithText(AppBar, '计划'));
        await _tap(
          tester,
          find.byWidgetPredicate(
            (widget) =>
                widget is FilterChip &&
                widget.label is Text &&
                (widget.label as Text).data == '已完成',
          ),
        );
        await _tap(tester, find.text(taskTitle));
        await _waitFor(tester, _button('设为未完成'));
        final restored = await _remoteUntil(
          tester,
          inspector,
          (w) =>
              _objects(w['tasks'])
                  .any((t) => t['id'] == taskId && t['status'] == 'done'),
          reason: 'Logging in again lost the completed server task.',
        );
        expect(_objects(restored['focusRecords']), hasLength(1));
        expect(_objects(restored['tasks']), hasLength(1));

        // Only the account dynamically created by this run is removed.
        await _tap(tester, find.byTooltip('返回'));
        await _openAccount(tester);
        expect(find.text(username), findsOneWidget);
        await _tap(tester, find.text('删除账户与数据'));
        expect(find.byType(TextFormField), findsOneWidget);
        await _enter(tester, find.byType(TextFormField), password);
        await _tap(tester, _button('删除账户与数据'));
        await _tap(tester, find.widgetWithText(TextButton, '确认删除'));
        await _waitUntil(
          tester,
          () =>
              _button('登录').evaluate().isNotEmpty ||
              _button('创建账户并开始').evaluate().isNotEmpty,
          reason:
              'Deleting this test account did not return to authentication.',
        );
        final revoked = await _request(
          tester,
          () => inspector.get<dynamic>('/api/v1/auth/me'),
        );
        expect(revoked.statusCode, 401);
        deletedThroughUi = true;
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await _tick(tester);
        try {
          if (registrationAttempted && !deletedThroughUi) {
            // Failure cleanup authenticates using this run's exact random
            // credentials and verifies identity before deleting anything.
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
              expect(user['email'], email);
              expect(user['username'], username);
              if (createdUserId != null) expect(user['id'], createdUserId);
              inspector.options.headers['Authorization'] =
                  'Bearer ${session['token']}';
              final deleted = await _request(
                tester,
                () => inspector.delete<dynamic>(
                  '/api/v1/account',
                  data: {'password': password},
                ),
              );
              expect(deleted.statusCode, 200);
            } else {
              expect(
                login.statusCode,
                401,
                reason: 'Could not confirm cleanup of this run\'s QA account.',
              );
            }
          }
        } finally {
          inspector.close(force: true);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
