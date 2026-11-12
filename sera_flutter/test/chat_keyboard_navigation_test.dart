import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/planning_ai_provider.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _prompt = '整理下周的评审材料';
const _sessionId = 'chat-keyboard-session';
const _interpretation = AiUnderstanding(
  intent: 'task',
  title: '整理评审材料',
  summary: '核对图表和演示材料。',
  outcome: '',
  model: 'chat-navigation-fixture',
  estimatedMinutes: 30,
);
const _updated = AiUnderstanding(
  intent: 'task',
  title: '整理并打印评审材料',
  summary: '核对图表和演示材料，并打印一份。',
  outcome: '',
  model: 'chat-navigation-fixture',
  estimatedMinutes: 40,
);

class _ChatStore implements WorkspaceRepository, InputUnderstandingProvider {
  _ChatStore()
    : value = Workspace(
        revision: 1,
        planningSessions: [
          PlanningSession(
            id: _sessionId,
            prompt: _prompt,
            title: _interpretation.title,
            stage: 'understood',
            updatedAt: DateTime(2026, 10, 31),
            understanding: _interpretation.toJson(),
          ),
        ],
      );
  Workspace? value;
  final requests = <({Json input, String id})>[];
  final gate = Completer<AiUnderstanding>();
  @override
  String get mode => 'chat-keyboard-navigation-test';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async => value = null;
  @override
  Future<Workspace> save(
    Workspace next, {
    required int expectedRevision,
  }) async {
    if (value?.revision != expectedRevision) {
      throw const RepositoryException('版本冲突', conflict: true);
    }
    return value = Workspace.fromJson(
      next.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }

  @override
  Future<AiUnderstanding> understandInput({
    required Json input,
    required String requestId,
    void Function(String stage)? onStage,
  }) {
    requests.add((input: input, id: requestId));
    return gate.future;
  }
}

typedef _Harness = ({SeraController controller, GoRouter router});

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<_Harness> _mount(
  WidgetTester tester,
  _ChatStore store, {
  Size size = const Size(390, 844),
  double scale = 1,
  String initialLocation = '/05?sessionId=$_sessionId',
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final controller = SeraController(
    repository: store,
    today: DateTime(2026, 10, 31),
    accountId: 'chat-owner',
  );
  await controller.initialize();
  await tester.pumpWidget(
    SeraApp(controller: controller, initialLocation: initialLocation),
  );
  await _frames(tester);
  final router = GoRouter.of(tester.element(find.byType(SeraScaffold).last));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    controller.dispose();
  });
  return (controller: controller, router: router);
}

Finder get _composer => find.byKey(const ValueKey('planning-chat-composer'));
Finder get _send => find.byKey(const ValueKey('planning-chat-send'));
String _draft(WidgetTester tester) =>
    tester.widget<TextField>(_composer).controller!.text;

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await _frames(tester);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  for (final width in [320.0, 390.0]) {
    testWidgets(
      'chat composer and send remain reachable at $width with enlarged text and keyboard',
      (tester) async {
        final store = _ChatStore();
        await _mount(tester, store, size: Size(width, 600), scale: 1.5);
        expect(
          find.byKey(const ValueKey('planning-original-message')),
          findsOneWidget,
        );
        expect(store.requests, isEmpty);
        await tester.enterText(_composer, '再打印一份');
        tester.view.viewInsets = const FakeViewPadding(bottom: 320);
        addTearDown(tester.view.resetViewInsets);
        await _frames(tester);
        expect(_composer.hitTestable(), findsOneWidget);
        expect(_send.hitTestable(), findsOneWidget);
        expect(find.byTooltip('语音输入').hitTestable(), findsOneWidget);
        expect(tester.getSize(_send).height, greaterThanOrEqualTo(48));
        expect(tester.getBottomRight(_send).dy, lessThanOrEqualTo(280));
        expect(tester.getBottomRight(_composer).dy, lessThanOrEqualTo(280));
        expect(_draft(tester), '再打印一份');
        expect(store.requests, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'goal entry keeps one contextual prompt and manual creation in a compact menu',
    (tester) async {
      final store = _ChatStore()..value = const Workspace(revision: 1);
      await _mount(tester, store, initialLocation: '/05?new=1&from=goals');
      expect(find.widgetWithText(AppBar, 'AI 助手'), findsOneWidget);
      expect(find.text('规划目标'), findsOneWidget);
      expect(
        tester.widget<TextField>(_composer).decoration!.hintText,
        '说说你想达成的目标…',
      );
      expect(find.byTooltip('规划记录').hitTestable(), findsOneWidget);
      expect(find.byTooltip('语音输入').hitTestable(), findsOneWidget);
      await _tap(tester, find.byTooltip('更多操作'));
      expect(find.byType(PopupMenuItem<String>), findsNWidgets(3));
      expect(find.text('添加任务'), findsOneWidget);
      expect(find.text('添加日程'), findsOneWidget);
      expect(find.text('创建目标'), findsOneWidget);
      expect(find.text('新对话'), findsNothing);
      expect(find.text('对话记录'), findsNothing);
      expect(store.requests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'visible history and voice entries preserve an unsent goal input',
    (tester) async {
      final store = _ChatStore()..value = const Workspace(revision: 1);
      final h = await _mount(
        tester,
        store,
        initialLocation: '/05?new=1&from=goals',
      );
      await tester.enterText(_composer, '下个月完成课程作品');
      await _tap(tester, find.byTooltip('规划记录'));
      expect(h.router.state.uri.path, '/34-history');
      expect(h.controller.data.planningSessions, hasLength(1));
      expect(
        h.controller.data.planningSessions.single.composerDraft,
        '下个月完成课程作品',
      );
      h.router.pop();
      await _frames(tester);
      expect(_draft(tester), '下个月完成课程作品');

      await _tap(tester, find.byTooltip('语音输入'));
      expect(h.router.state.uri.path, '/50-voice');
      expect(h.router.state.uri.queryParameters['from'], 'goals');
      h.router.pop();
      await _frames(tester);
      expect(_draft(tester), '下个月完成课程作品');
      expect(store.requests, isEmpty);
      expect(h.controller.data.tasks, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('canceling original edit preserves the unsent chat draft', (
    tester,
  ) async {
    final store = _ChatStore();
    final h = await _mount(tester, store);
    await tester.enterText(_composer, '再打印一份');
    await _tap(tester, find.byTooltip('更多操作'));
    await _tap(tester, find.text('修改原文'));
    final original = find.descendant(
      of: find.widgetWithText(SeraInput, '这次想处理什么？'),
      matching: find.byType(TextFormField),
    );
    await tester.enterText(original, '尚未确认的修改');
    await _tap(tester, find.widgetWithText(TextButton, '取消'));
    expect(_draft(tester), '再打印一份');
    expect(h.controller.planningSession(_sessionId)!.prompt, _prompt);
    expect(find.text('尚未确认的修改'), findsNothing);
    expect(store.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'canceling a suggested task editor returns to the same unsent message',
    (tester) async {
      final store = _ChatStore();
      final h = await _mount(tester, store);
      await tester.enterText(_composer, '再打印一份');
      await _tap(tester, find.widgetWithText(SeraButton, '编辑任务'));
      expect(h.router.state.uri.path.split('-').first, '/19');
      await _tap(tester, find.byTooltip('返回'));
      await _tap(tester, find.widgetWithText(TextButton, '放弃修改'));
      expect(h.router.state.uri.path.split('-').first, '/05');
      expect(_draft(tester), '再打印一份');
      expect(h.controller.data.tasks, isEmpty);
      expect(h.controller.planningSession(_sessionId)!.stage, 'understood');
      expect(store.requests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a cached send callback cannot duplicate the message or request',
    (tester) async {
      final store = _ChatStore();
      final h = await _mount(tester, store);
      await tester.enterText(_composer, '再打印一份');
      await tester.pump();
      final send = tester.widget<IconButton>(_send).onPressed!;
      send();
      send();
      await _frames(tester);
      expect(store.requests, hasLength(1));
      expect(store.requests.single.input['prompt'], _prompt);
      expect(store.requests.single.input['notes'], '再打印一份');
      expect(find.text('再打印一份'), findsOneWidget);
      store.gate.complete(_updated);
      await _frames(tester);
      expect(h.controller.planningSession(_sessionId)!.notes, '再打印一份');
      expect(_draft(tester), isEmpty);
      expect(store.requests, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a late chat reply under a covering page leaves navigation and draft intact',
    (tester) async {
      final store = _ChatStore();
      final h = await _mount(tester, store);
      await tester.enterText(_composer, '再打印一份');
      await tester.pump();
      await _tap(tester, _send);
      expect(store.requests, hasLength(1));
      unawaited(h.router.push('/12'));
      await _frames(tester);
      store.gate.complete(_updated);
      await _frames(tester);
      expect(h.router.state.uri.path, '/12');
      h.router.pop();
      await _frames(tester);
      expect(h.router.state.uri.path.split('-').first, '/05');
      expect(find.text(_updated.title), findsOneWidget);
      expect(h.controller.planningSession(_sessionId)!.notes, '再打印一份');
      expect(store.requests, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a partial historical assistant snapshot retains readable text without an action',
    (tester) async {
      const readableReply = '这是一条旧版本保留下来的回复。';
      final store = _ChatStore()
        ..value = Workspace(
          revision: 1,
          planningSessions: [
            PlanningSession(
              id: _sessionId,
              prompt: _prompt,
              stage: 'understood',
              updatedAt: DateTime(2026, 10, 31),
              messages: const [
                PlanningMessage(id: 'old-user', role: 'user', text: _prompt),
                PlanningMessage(
                  id: 'old-assistant',
                  role: 'assistant',
                  text: readableReply,
                  understanding: {},
                ),
              ],
            ),
          ],
        );
      final h = await _mount(tester, store);
      expect(find.text(readableReply), findsOneWidget);
      expect(find.widgetWithText(SeraButton, '编辑任务'), findsNothing);
      expect(find.widgetWithText(SeraButton, '编辑固定事项'), findsNothing);
      expect(find.widgetWithText(SeraButton, '核对目标并规划'), findsNothing);
      expect(_composer.hitTestable(), findsOneWidget);
      expect(store.requests, isEmpty);
      expect(h.controller.data.tasks, isEmpty);
      expect(h.controller.data.entries, isEmpty);
      expect(h.controller.data.drafts, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
