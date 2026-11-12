import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:sera_flutter/ui/screens/account_screens.dart';
import 'package:sera_flutter/ui/screens/voice_screens.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _channel = MethodChannel('com.sera/platform');

Map<String, dynamic> _session() => {
  'token': 'test-session',
  'expiresAt': DateTime.now()
      .add(const Duration(days: 1))
      .toUtc()
      .toIso8601String(),
  'user': {'id': 'u-test', 'username': '林悦测试', 'email': 'lin@example.test'},
};

Future<GoRouter> _pump(
  WidgetTester tester,
  AuthRepository auth,
  String location, {
  WebSocketChannel Function(Uri)? connect,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: location,
    routes: [
      for (final mode in [
        'login',
        'register',
        'account',
        'verify-email',
        'forgot-password',
        'reset-password',
      ])
        GoRoute(
          path: '/$mode',
          builder: (_, state) => AccountScreen(
            key: ValueKey(mode),
            mode: mode,
            token: state.uri.queryParameters['token'],
          ),
        ),
      GoRoute(
        path: '/50',
        builder: (_, _) => VoiceInputScreen(connect: connect),
      ),
      GoRoute(
        path: '/02',
        builder: (_, _) => const Scaffold(body: Text('first-use settings')),
      ),
      GoRoute(
        path: '/30',
        builder: (_, _) => const Scaffold(body: Text('local profile')),
      ),
      GoRoute(
        path: '/04',
        builder: (_, _) => const Scaffold(body: Text('workspace destination')),
      ),
      GoRoute(
        path: '/05',
        builder: (_, state) =>
            Scaffold(body: Text(state.uri.queryParameters['prompt'] ?? '')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: auth,
      child: MaterialApp.router(theme: seraTheme(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

class _SocketSink implements WebSocketSink {
  final List<dynamic> sent = [];
  final Completer<void> _closed = Completer<void>();
  void Function(dynamic)? onAdd;
  @override
  void add(dynamic data) {
    sent.add(data);
    onAdd?.call(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<dynamic> stream) async {
    await for (final value in stream) {
      add(value);
    }
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<void> get done => _closed.future;
}

class _Socket implements WebSocketChannel {
  final incoming = StreamController<dynamic>();
  @override
  final _SocketSink sink = _SocketSink();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  Future<void> get ready => Future<void>.value();
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
  @override
  String? get protocol => null;
}

Future<void> _tap(
  WidgetTester tester,
  String label, {
  bool settle = true,
}) async {
  final action = find.widgetWithText(SeraButton, label);
  final button = action.evaluate().isEmpty
      ? find.widgetWithText(ListTile, label)
      : action;
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
  if (settle) await tester.pumpAndSettle();
}

Future<void> _mockLogin(
  WidgetTester tester,
  AuthRepository auth, {
  String identifier = 'lin',
}) async {
  var completed = false;
  Object? loginError;
  unawaited(
    auth
        .login(identifier: identifier, password: 'test-password')
        .then<void>(
          (_) {
            completed = true;
          },
          onError: (Object error, StackTrace stack) {
            loginError = error;
            completed = true;
          },
        ),
  );
  for (var attempt = 0; attempt < 100 && !completed; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(
    completed,
    isTrue,
    reason: 'The mocked login must finish in the widget test zone.',
  );
  expect(loginError, isNull);
  expect(auth.signedIn, isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.sera/audio_pcm'),
          null,
        );
  });

  testWidgets(
    'password recovery uses email and token endpoints with validation',
    (tester) async {
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) {
              requests.add(o);
              h.resolve(
                Response<dynamic>(
                  requestOptions: o,
                  statusCode: 200,
                  data: o.path.endsWith('/reset/request')
                      ? <String, dynamic>{
                          'accepted': true,
                          'deliveryMode': 'local',
                          'deliveryStatus': 'request_accepted',
                          'developmentPreview': false,
                          'message': '如果邮箱已注册，重置邮件仅保存在本机，未投递到外部收件箱。',
                        }
                      : <String, dynamic>{'reset': true},
                ),
              );
            },
          ),
        );
      final auth = AuthRepository(
        apiBaseUrl: 'http://test.invalid',
        client: dio,
        preferences: SharedPreferencesAsync(),
      );
      final router = await _pump(tester, auth, '/forgot-password');
      await tester.enterText(find.byType(TextFormField), 'lin@example.test');
      await _tap(tester, '发送重置邮件');
      expect(requests.single.path, '/api/v1/auth/password/reset/request');
      expect(requests.single.data, {'email': 'lin@example.test'});
      router.go('/reset-password?token=one-use-test-token');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller!
            .text,
        'one-use-test-token',
      );
      await tester.enterText(
        find.byType(TextFormField).at(1),
        'Strong-new-password',
      );
      await tester.enterText(
        find.byType(TextFormField).at(2),
        'Strong-new-password',
      );
      await _tap(tester, '保存新密码');
      expect(requests.last.path, '/api/v1/auth/password/reset/confirm');
      expect((requests.last.data as Map)['token'], 'one-use-test-token');
      expect(find.text('新密码已保存，请使用新密码登录。'), findsOneWidget);
      expect(auth.signedIn, isFalse);
    },
  );

  testWidgets(
    'realtime voice sends PCM frames and confirms the final editable transcript',
    (tester) async {
      final methods = <String>[];
      final socket = _Socket();
      addTearDown(() {
        unawaited(socket.incoming.close());
      });
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) => h.resolve(
              Response<dynamic>(
                requestOptions: o,
                statusCode: 200,
                data: o.path.endsWith('/tickets')
                    ? {
                        'ticket': 'one-use-asr-ticket',
                        'websocketUrl': 'ws://test.invalid/ws',
                      }
                    : _session(),
              ),
            ),
          ),
        );
      final auth = AuthRepository(
        apiBaseUrl: 'http://test.invalid',
        client: dio,
        preferences: SharedPreferencesAsync(),
      );
      await _mockLogin(tester, auth);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            methods.add(call.method);
            if (call.method == 'requestPermission') return 'granted';
            return null;
          });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.sera/audio_pcm'),
            (call) async => null,
          );
      socket.sink.onAdd = (data) {
        if (data is String && (jsonDecode(data) as Map)['type'] == 'finish') {
          socket.incoming.add(
            jsonEncode({'type': 'final', 'text': '明天安排30分钟英语口语'}),
          );
        }
      };
      Uri? connected;
      final router = await _pump(
        tester,
        auth,
        '/50?from=tasks',
        connect: (uri) {
          connected = uri;
          return socket;
        },
      );
      await _tap(tester, '开始录音', settle: false);
      await tester.pump(const Duration(milliseconds: 400));
      expect(connected!.queryParameters['ticket'], 'one-use-asr-ticket');
      expect(methods, contains('startAudioStream'));
      socket.incoming.add(jsonEncode({'type': 'partial', 'text': '明天安排'}));
      await tester.pump();
      expect(find.text('明天安排'), findsOneWidget);
      final frame = Uint8List(3200);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'com.sera/audio_pcm',
            const StandardMethodCodec().encodeSuccessEnvelope(frame),
            (_) {},
          );
      await tester.pump();
      expect(socket.sink.sent.whereType<Uint8List>(), hasLength(1));
      await _tap(tester, '说好了，确认文字', settle: false);
      await tester.pump(const Duration(seconds: 1));
      expect(
        socket.sink.sent
            .whereType<String>()
            .map(jsonDecode)
            .where((e) => e['type'] == 'finish'),
        hasLength(1),
        reason:
            'finish should be sent after microphone release; platform calls: $methods',
      );
      expect(methods, contains('stopAudioStream'));
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        '明天安排30分钟英语口语',
      );
      await _tap(tester, '使用这段文字继续');
      expect(find.text('明天安排30分钟英语口语'), findsOneWidget);
      expect(router.state.uri.path, '/05');
      expect(router.state.uri.queryParameters['from'], 'tasks');
      expect(tester.takeException(), isNull);
      // Flush the asynchronous fake stream inside the pumped test zone. An
      // awaited close in package:test teardown has no widget clock to advance.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(
        socket.incoming.hasListener,
        isFalse,
        reason: 'The application must detach its socket subscription.',
      );
      // The test owns these fake terminal resources. This is cleanup, while
      // microphone release/finish/PCM and final text were asserted above.
      unawaited(socket.sink.close());
      unawaited(socket.incoming.close());
      expect(socket.incoming.isClosed, isTrue);
    },
  );

  testWidgets(
    'registration validates real constraints before making a request',
    (tester) async {
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) {
              requests.add(o);
              h.resolve(
                Response<dynamic>(
                  requestOptions: o,
                  data: _session(),
                  statusCode: 200,
                ),
              );
            },
          ),
        );
      final auth = AuthRepository(
        apiBaseUrl: 'http://test.invalid',
        client: dio,
        preferences: SharedPreferencesAsync(),
      );
      await _pump(tester, auth, '/register');
      await tester.enterText(find.byType(TextFormField).at(0), 'ab');
      await tester.enterText(find.byType(TextFormField).at(1), 'not-an-email');
      await tester.enterText(find.byType(TextFormField).at(2), 'short');
      await tester.enterText(find.byType(TextFormField).at(3), 'other');
      await _tap(tester, '创建账户并开始');
      expect(requests, isEmpty);
      expect(find.text('请输入有效的电子邮箱。'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).at(0), '林悦测试');
      await tester.enterText(
        find.byType(TextFormField).at(1),
        'lin@example.test',
      );
      await tester.enterText(
        find.byType(TextFormField).at(2),
        'A-secure-test-password',
      );
      await tester.enterText(
        find.byType(TextFormField).at(3),
        'A-secure-test-password',
      );
      await _tap(tester, '创建账户并开始');
      expect(requests.single.path, '/api/v1/auth/register');
      expect(auth.signedIn, isTrue);
      expect(find.text('local profile'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account export saves the returned JSON and logout revokes the session',
    (tester) async {
      final paths = <String>[];
      final saved = <Map<dynamic, dynamic>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (call.method == 'saveTextFile') saved.add(call.arguments as Map);
            return null;
          });
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) {
              paths.add(o.path);
              h.resolve(
                Response<dynamic>(
                  requestOptions: o,
                  statusCode: 200,
                  data: o.path.endsWith('/export')
                      ? {
                          'user': {'username': '林悦测试'},
                          'workspace': {'tasks': []},
                        }
                      : _session(),
                ),
              );
            },
          ),
        );
      final auth = AuthRepository(
        apiBaseUrl: 'http://test.invalid',
        client: dio,
        preferences: SharedPreferencesAsync(),
      );
      await _mockLogin(tester, auth, identifier: 'lin@example.test');
      await _pump(tester, auth, '/account');
      expect(find.byType(TextFormField), findsNothing);
      expect(find.widgetWithText(SeraButton, '查找旧版记录'), findsNothing);
      final deleteSection = find.text('删除账户与数据');
      await tester.ensureVisible(deleteSection);
      await tester.tap(deleteSection);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'unfinished-password');
      final deleteHeading = find
          .descendant(
            of: find.widgetWithText(SeraDisclosure, '删除账户与数据'),
            matching: find.text('删除账户与数据'),
          )
          .first;
      await tester.ensureVisible(deleteHeading);
      await tester.tap(deleteHeading);
      await tester.pumpAndSettle();
      expect(find.byType(TextFormField), findsNothing);
      await tester.tap(deleteHeading);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        'unfinished-password',
      );
      await tester.ensureVisible(deleteHeading);
      await tester.tap(deleteHeading);
      await tester.pumpAndSettle();
      await _tap(tester, '准备账户备份');
      await _tap(tester, '保存备份');
      expect(saved, hasLength(1));
      expect(
        jsonDecode(saved.single['content'] as String)['user']['username'],
        '林悦测试',
      );
      expect(saved.single['content'], isNot(contains('test-session')));
      await _tap(tester, '退出登录');
      expect(paths, contains('/api/v1/auth/logout'));
      expect(auth.session, isNull);
      expect(find.text('local profile'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'real recording method calls feed ASR retry and editable goal text',
    (tester) async {
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            methods.add(call.method);
            if (call.method == 'requestPermission') return 'granted';
            if (call.method == 'stopRecording') {
              return {
                'base64': base64Encode([82, 73, 70, 70, 1]),
                'mimeType': 'audio/wav',
                'fileName': 'recording.wav',
                'durationMilliseconds': 1000,
              };
            }
            return null;
          });
      var transcriptions = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) {
              if (o.path.endsWith('/transcribe')) {
                transcriptions++;
                expect(o.headers['Authorization'], 'Bearer test-session');
                expect(
                  (o.data as FormData).files.single.value.filename,
                  'recording.wav',
                );
                if (transcriptions == 1) {
                  h.reject(
                    DioException(
                      requestOptions: o,
                      type: DioExceptionType.badResponse,
                      response: Response<dynamic>(
                        requestOptions: o,
                        statusCode: 502,
                        data: {'error': '语音服务暂时不可用'},
                      ),
                    ),
                  );
                } else {
                  h.resolve(
                    Response<dynamic>(
                      requestOptions: o,
                      statusCode: 200,
                      data: {
                        'text': '明天练习英语口语',
                        'source': 'siliconflow',
                        'model': 'test-asr',
                      },
                    ),
                  );
                }
              } else {
                h.resolve(
                  Response<dynamic>(
                    requestOptions: o,
                    statusCode: 200,
                    data: _session(),
                  ),
                );
              }
            },
          ),
        );
      final auth = AuthRepository(
        apiBaseUrl: 'http://test.invalid',
        client: dio,
        preferences: SharedPreferencesAsync(),
      );
      await _mockLogin(tester, auth);
      await _pump(tester, auth, '/50');
      await tester.tap(find.text('录完后识别'));
      await tester.pumpAndSettle();
      await _tap(tester, '开始录音', settle: false);
      await tester.pump(const Duration(milliseconds: 400));
      expect(methods, contains('startRecording'));
      expect(find.text('正在录音'), findsOneWidget);
      await _tap(tester, '完成录音，识别文字');
      expect(find.text('语音服务暂时不可用'), findsOneWidget);
      await _tap(tester, '重新识别这段录音');
      expect(transcriptions, 2);
      expect(find.text('文字已识别'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), '后天完成英语口语练习');
      await _tap(tester, '使用这段文字继续');
      expect(find.text('后天完成英语口语练习'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'denied microphone can open settings and cancelling releases recording',
    (tester) async {
      var granted = false;
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            methods.add(call.method);
            if (call.method == 'requestPermission') {
              return granted ? 'granted' : 'denied';
            }
            return null;
          });
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) => h.resolve(
              Response<dynamic>(
                requestOptions: o,
                statusCode: 200,
                data: _session(),
              ),
            ),
          ),
        );
      final auth = AuthRepository(
        apiBaseUrl: 'http://test.invalid',
        client: dio,
        preferences: SharedPreferencesAsync(),
      );
      await _mockLogin(tester, auth);
      await _pump(tester, auth, '/50');
      await tester.tap(find.text('录完后识别'));
      await tester.pumpAndSettle();
      await _tap(tester, '开始录音');
      expect(find.textContaining('麦克风权限未开启'), findsOneWidget);
      expect(methods, isNot(contains('startRecording')));
      await _tap(tester, '打开麦克风权限设置');
      expect(methods, contains('openApplicationSettings'));
      granted = true;
      await _tap(tester, '开始录音', settle: false);
      await tester.pump(const Duration(milliseconds: 400));
      await _tap(tester, '取消录音');
      expect(methods, contains('cancelRecording'));
      expect(find.text('workspace destination'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
