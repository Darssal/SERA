import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:sera_flutter/ui/screens/voice_screens.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _platform = MethodChannel('com.sera/platform');
const _pcm = MethodChannel('com.sera/audio_pcm');

AuthSession _session(String id) => AuthSession(
  token: 'synthetic-$id',
  sessionId: 'session-$id',
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
  user: AuthUser(
    id: id,
    username: 'voice-fixture',
    email: '$id@example.invalid',
  ),
);

class _Auth extends AuthRepository {
  _Auth() : super(apiBaseUrl: 'http://voice-fixture.invalid') {
    session = _session('first');
  }
  int tickets = 0;
  Completer<Json>? ticketGate;
  @override
  Future<Json> createAsrTicket() async {
    tickets++;
    return ticketGate == null ? ticket : await ticketGate!.future;
  }

  static const Json ticket = {
    'ticket': 'synthetic-ticket',
    'websocketUrl': 'ws://voice-fixture.invalid/asr',
  };
  void changeAccount() {
    session = _session('second');
    notifyListeners();
  }
}

class _Sink implements WebSocketSink {
  final sent = <dynamic>[];
  final closed = Completer<void>();
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
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (!closed.isCompleted) closed.complete();
  }

  @override
  Future<void> get done => closed.future;
}

class _Socket implements WebSocketChannel {
  final incoming = StreamController<dynamic>();
  @override
  final _Sink sink = _Sink();
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
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Fixture {
  final auth = _Auth();
  final socket = _Socket();
  final methods = <String>[];
  final changed = <String>[];
  final confirmed = <String>[];
  Completer<String>? permissionGate;
  Completer<void>? startGate;
  late GoRouter router;
  int connections = 0;
  bool autoFinal = true;
  String permission = 'granted';
  List<String> get messages => socket.sink.sent
      .whereType<String>()
      .map((s) => (jsonDecode(s) as Map)['type'] as String)
      .toList();
  void event(String type, String text) =>
      socket.incoming.add(jsonEncode({'type': type, 'text': text}));
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<_Fixture> _mount(
  WidgetTester tester, {
  _Fixture? fixture,
  String initialText = '',
}) async {
  final f = fixture ?? _Fixture();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_platform, (call) async {
        f.methods.add(call.method);
        if (call.method == 'requestPermission') {
          return f.permissionGate == null
              ? f.permission
              : await f.permissionGate!.future;
        }
        if (call.method == 'startAudioStream' && f.startGate != null) {
          await f.startGate!.future;
        }
        return null;
      });
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_pcm, (_) async => null);
  f.socket.sink.onAdd = (data) {
    if (data is String &&
        (jsonDecode(data) as Map)['type'] == 'finish' &&
        f.autoFinal) {
      f.event('final', '明天下午准备评审');
    }
  };
  f.router = GoRouter(
    initialLocation: '/voice',
    routes: [
      GoRoute(
        path: '/voice',
        builder: (_, _) => Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: VoiceInputScreen(
                embedded: true,
                holdToTalk: true,
                initialText: initialText,
                onTextChanged: f.changed.add,
                onConfirmed: f.confirmed.add,
                connect: (_) {
                  f.connections++;
                  return f.socket;
                },
              ),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/cover',
        builder: (_, _) => const Scaffold(body: Text('cover')),
      ),
    ],
  );
  await tester.pumpWidget(
    ChangeNotifierProvider<AuthRepository>.value(
      value: f.auth,
      child: MaterialApp.router(theme: seraTheme(), routerConfig: f.router),
    ),
  );
  await _frames(tester);
  addTearDown(() async {
    if (f.permissionGate?.isCompleted == false) {
      f.permissionGate!.complete('granted');
    }
    if (f.startGate?.isCompleted == false) f.startGate!.complete();
    if (f.auth.ticketGate?.isCompleted == false) {
      f.auth.ticketGate!.complete(_Auth.ticket);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await _frames(tester);
    unawaited(f.socket.incoming.close());
    f.router.dispose();
    f.auth.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pcm, null);
  });
  return f;
}

Finder get _hold => find.byKey(const ValueKey('voice-hold-button'));
Future<TestGesture> _press(WidgetTester tester) async {
  final gesture = await tester.startGesture(tester.getCenter(_hold));
  await tester.pump(const Duration(milliseconds: 600));
  await _frames(tester);
  return gesture;
}

Future<void> _frame(WidgetTester tester) async {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        'com.sera/audio_pcm',
        const StandardMethodCodec().encodeSuccessEnvelope(Uint8List(3200)),
        (_) {},
      );
  await _frames(tester);
}

void main() {
  testWidgets(
    'empty voice input stays compact and an emptied correction stays editable',
    (tester) async {
      final f = await _mount(tester);
      expect(find.text('按住说话'), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.widgetWithText(SeraButton, '让 AI 安排'), findsNothing);
      expect(find.text('改用备用识别'), findsNothing);
      expect(f.auth.tickets, 0);
      expect(f.methods, isEmpty);

      final press = await _press(tester);
      await _frame(tester);
      await press.up();
      await _frames(tester);
      final editor = find.byKey(const ValueKey('voice-confirmed-text'));
      expect(editor, findsOneWidget);
      await tester.enterText(editor, '');
      await _frames(tester);
      expect(editor, findsOneWidget);
      expect(
        tester
            .widget<SeraButton>(find.widgetWithText(SeraButton, '让 AI 安排'))
            .onPressed,
        isNull,
      );
      expect(f.changed, ['明天下午准备评审', '']);
      expect(f.confirmed, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'hold sends PCM, release finishes, only edited final text is confirmed',
    (tester) async {
      final f = await _mount(tester, initialText: '原有想法');
      expect(f.auth.tickets, 0);
      expect(f.methods, isEmpty);
      expect(find.byType(SeraScaffold), findsNothing);
      final press = await _press(tester);
      expect(f.auth.tickets, 1);
      expect(f.methods, contains('startAudioStream'));
      await _frame(tester);
      f.event('partial', '明天下午');
      await _frames(tester);
      expect(find.text('明天下午'), findsOneWidget);
      expect(f.changed, isEmpty);
      expect(f.confirmed, isEmpty);
      expect(f.socket.sink.sent.whereType<Uint8List>(), hasLength(1));
      await press.up();
      await _frames(tester);
      expect(f.messages.where((m) => m == 'finish'), hasLength(1));
      expect(f.methods, contains('stopAudioStream'));
      expect(f.changed, ['原有想法\n明天下午准备评审']);
      expect(f.confirmed, isEmpty);
      final editor = find.byKey(const ValueKey('voice-confirmed-text'));
      await tester.enterText(editor, '后天下午准备评审');
      await tester.pump();
      await tester.tap(find.widgetWithText(SeraButton, '让 AI 安排'));
      await _frames(tester);
      expect(f.confirmed, ['后天下午准备评审']);
      expect(f.changed.last, '后天下午准备评审');
      expect(f.router.state.uri.path, '/voice');
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final pending in ['ticket', 'permission', 'native']) {
    testWidgets(
      'release while $pending is pending prevents a late unattended recording',
      (tester) async {
        final fixture = _Fixture();
        if (pending == 'ticket') fixture.auth.ticketGate = Completer<Json>();
        if (pending == 'permission') {
          fixture.permissionGate = Completer<String>();
        }
        if (pending == 'native') fixture.startGate = Completer<void>();
        final f = await _mount(tester, fixture: fixture, initialText: '保留文字');
        final press = await _press(tester);
        await press.up();
        await _frames(tester);
        if (pending == 'ticket') f.auth.ticketGate!.complete(_Auth.ticket);
        if (pending == 'permission') f.permissionGate!.complete('granted');
        if (pending == 'native') f.startGate!.complete();
        await _frames(tester);
        expect(f.auth.tickets, 1);
        if (pending == 'ticket') expect(f.connections, 0);
        if (pending != 'native') {
          expect(f.methods, isNot(contains('startAudioStream')));
        }
        if (pending == 'native') expect(f.methods, contains('stopAudioStream'));
        expect(f.messages, isNot(contains('finish')));
        expect(find.text('按住说话'), findsOneWidget);
        expect(f.changed, isEmpty);
        expect(f.confirmed, isEmpty);
        expect(
          tester
              .widget<TextFormField>(find.byType(TextFormField))
              .controller!
              .text,
          '保留文字',
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  for (final pending in ['permission', 'native']) {
    testWidgets(
      'disposing while $pending is pending cancels a late microphone start',
      (tester) async {
        final fixture = _Fixture();
        if (pending == 'permission') {
          fixture.permissionGate = Completer<String>();
        }
        if (pending == 'native') fixture.startGate = Completer<void>();
        final f = await _mount(tester, fixture: fixture);
        final press = await _press(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await _frames(tester);
        await press.up();
        if (pending == 'permission') f.permissionGate!.complete('granted');
        if (pending == 'native') f.startGate!.complete();
        await _frames(tester);
        f.event('final', '不能接受的迟到结果');
        await _frames(tester);
        expect(f.methods, contains('stopAudioStream'));
        if (pending == 'permission') {
          expect(f.methods, isNot(contains('startAudioStream')));
        } else {
          expect(
            f.methods.where((m) => m == 'stopAudioStream').length,
            greaterThanOrEqualTo(2),
          );
        }
        expect(f.messages, contains('cancel'));
        expect(f.messages, isNot(contains('finish')));
        expect(f.changed, isEmpty);
        expect(f.confirmed, isEmpty);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets(
    'another press during a pending start does not request another session',
    (tester) async {
      final fixture = _Fixture()..auth.ticketGate = Completer<Json>();
      final f = await _mount(tester, fixture: fixture);
      final press = await _press(tester);
      final duplicate = await tester.startGesture(
        tester.getCenter(_hold),
        pointer: 2,
      );
      await tester.pump(const Duration(milliseconds: 700));
      await duplicate.up();
      await _frames(tester);
      expect(f.auth.tickets, 1);
      expect(f.connections, 0);
      await press.up();
      f.auth.ticketGate!.complete(_Auth.ticket);
      await _frames(tester);
      expect(f.connections, 0);
      expect(f.methods, isNot(contains('startAudioStream')));
      expect(f.confirmed, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'microphone denial offers explicit backup without starting or uploading',
    (tester) async {
      final fixture = _Fixture()..permission = 'denied';
      final f = await _mount(tester, fixture: fixture);
      final press = await _press(tester);
      await press.up();
      await _frames(tester);
      expect(find.byKey(const ValueKey('voice-error')), findsOneWidget);
      expect(find.text('打开麦克风权限设置'), findsOneWidget);
      expect(f.methods, isNot(contains('startAudioStream')));
      expect(find.text('备用识别 · 录音结束后上传至云端转写'), findsNothing);
      await tester.tap(find.text('改用备用识别'));
      await _frames(tester);
      expect(find.text('备用识别 · 录音结束后上传至云端转写'), findsOneWidget);
      expect(f.methods, isNot(contains('startRecording')));
      expect(f.messages, isNot(contains('finish')));
      expect(f.auth.tickets, 1);
      expect(f.changed, isEmpty);
      expect(f.confirmed, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'pointer cancellation releases microphone and discards late partial/final',
    (tester) async {
      final f = await _mount(tester);
      final press = await _press(tester);
      await _frame(tester);
      await press.cancel();
      await _frames(tester);
      f.event('partial', '不要保存');
      f.event('final', '不要提交');
      await _frames(tester);
      expect(f.messages, contains('cancel'));
      expect(f.messages, isNot(contains('finish')));
      expect(f.methods, contains('stopAudioStream'));
      expect(f.changed, isEmpty);
      expect(f.confirmed, isEmpty);
      expect(find.text('不要提交'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final change in ['cover', 'account', 'dispose']) {
    testWidgets(
      '$change during hold releases audio without accepting late recognition',
      (tester) async {
        final f = await _mount(tester);
        final press = await _press(tester);
        await _frame(tester);
        if (change == 'cover') unawaited(f.router.push('/cover'));
        if (change == 'account') f.auth.changeAccount();
        if (change == 'dispose') {
          await tester.pumpWidget(const SizedBox.shrink());
        }
        await _frames(tester);
        await press.up();
        f.event('final', '旧会话内容');
        await _frames(tester);
        expect(f.methods, contains('stopAudioStream'));
        expect(f.messages, contains('cancel'));
        expect(f.confirmed, isEmpty);
        expect(f.changed.where((text) => text.isNotEmpty), isEmpty);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets('keyboard activation can start and stop without a long press', (
    tester,
  ) async {
    final f = await _mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _frames(tester);
    expect(f.auth.tickets, 1);
    await _frame(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _frames(tester);
    expect(f.messages, contains('finish'));
    expect(f.changed, ['明天下午准备评审']);
    expect(f.confirmed, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
