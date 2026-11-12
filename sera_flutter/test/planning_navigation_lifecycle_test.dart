import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/planning_ai_provider.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:sera_flutter/domain/planning_service.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _LifecycleStore
    implements
        WorkspaceRepository,
        PlanningAiProvider,
        InputUnderstandingProvider,
        CancellableInputUnderstandingProvider {
  _LifecycleStore(this.value);
  Workspace value;
  final planning = Completer<AiPlanResult>();
  final understanding = Completer<AiUnderstanding>();
  final planningRequests = <String?>[];
  final understandingRequests = <String>[];
  int understandingCancellations = 0;
  int saves = 0;

  @override
  String get mode => 'planning-lifecycle-test';
  @override
  Future<Workspace?> load() async => value;
  @override
  Future<void> clear() async => value = const Workspace();
  @override
  Future<Workspace> save(
    Workspace workspace, {
    required int expectedRevision,
  }) async {
    if (value.revision != expectedRevision) {
      throw const RepositoryException('测试工作区版本冲突', conflict: true);
    }
    saves++;
    return value = Workspace.fromJson(
      workspace.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }

  @override
  Future<AiPlanResult> generateTaskBreakdown({
    required String title,
    required DateTime deadline,
    required int dailyBudget,
    String notes = '',
    String prompt = '',
    String? requestId,
  }) {
    planningRequests.add(requestId);
    return planning.future;
  }

  @override
  Future<AiUnderstanding> understandInput({
    required Json input,
    required String requestId,
    void Function(String)? onStage,
  }) {
    understandingRequests.add(requestId);
    return understanding.future;
  }

  @override
  void cancelUnderstanding() => understandingCancellations++;
}

const _outline = AiPlanResult(
  model: 'navigation-lifecycle-test-model',
  tasks: [TaskOutline(title: '整理方案核心论点', estimatedMinutes: 30)],
);
const _interpretation = AiUnderstanding(
  intent: 'goal',
  title: '迟到的理解结果',
  summary: '这段结果属于已经离开的助手页面。',
  outcome: '准备完成方案',
  model: 'navigation-lifecycle-test-model',
);
final _today = DateTime(2026, 11, 2, 8);
final _deadline = DateTime(2026, 11, 9, 18);
const _sessionId = 'lifecycle-session';

PlanningSession _session({String stage = 'clarify', String? draftId}) =>
    PlanningSession(
      id: _sessionId,
      updatedAt: _today,
      prompt: '准备方案评审',
      title: '准备方案评审',
      notes: '保留原始准备要求',
      deadline: _deadline,
      stage: stage,
      draftId: draftId,
      aiRequestId: stage == 'generating' ? 'durable-lifecycle-request' : null,
      aiRequestNotes: stage == 'generating' ? '冻结后的原始准备要求' : null,
    );

PlanDraft _draft() {
  var nextId = 0;
  return const PlanningService().generate(
    workspace: const Workspace(),
    today: _today,
    title: '准备方案评审',
    deadline: _deadline,
    dailyBudget: 90,
    outlines: _outline.tasks,
    source: 'siliconflow',
    model: _outline.model,
    newId: (prefix) => '$prefix-lifecycle-${nextId++}',
  );
}

Future<({SeraController controller, GoRouter router})> _mount(
  WidgetTester tester,
  _LifecycleStore store,
  String location,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final controller = SeraController(
    repository: store,
    today: _today,
    seedDemo: false,
  );
  await controller.initialize();
  await tester.pumpWidget(
    SeraApp(controller: controller, initialLocation: location),
  );
  await tester.pumpAndSettle();
  final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  return (controller: controller, router: router);
}

Future<void> _tap(WidgetTester tester, String label) async {
  var button = find.widgetWithText(SeraButton, label);
  if (button.evaluate().isEmpty) {
    button = find.widgetWithText(TextButton, label);
  }
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Interrupt after the destination really builds, before its automatic
/// post-frame action. The route remains mounted during its reverse animation.
Future<void> _pushThenBackBeforePostFrame(
  WidgetTester tester,
  GoRouter router, {
  required String location,
  required String title,
}) async {
  var armed = true;
  var intercepted = false;
  final returnUri = router.state.uri;
  Uri? uriImmediatelyAfterPop;
  tester.binding.addPersistentFrameCallback((_) {
    if (!armed) return;
    // Entrance routes are built Offstage on their first frame for Hero
    // measurement. Skipping Offstage would miss the only frame before their
    // automatic post-frame work, especially a fast completed commit.
    final destinations = find
        .byWidgetPredicate(
          (widget) => widget is SeraScaffold && widget.title == title,
          skipOffstage: false,
        )
        .evaluate();
    final builtWhileCurrent = destinations.any(
      (element) => ModalRoute.of(element)?.isCurrent == true,
    );
    if (!builtWhileCurrent || !router.canPop()) return;
    armed = false;
    intercepted = true;
    router.pop();
    // The delegate changes synchronously; Navigator's isCurrent may remain
    // stale until its next build. Business guards must handle that interval.
    uriImmediatelyAfterPop = router.state.uri;
  });
  try {
    unawaited(router.push<void>(location));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      intercepted,
      isTrue,
      reason: 'The test must pop an actually built destination before post-frame work.',
    );
    expect(
      uriImmediatelyAfterPop,
      returnUri,
      reason:
          'Back must update the destination before automatic post-frame work.',
    );
  } finally {
    // Persistent callbacks cannot be removed; disarm this one for later frames.
    armed = false;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  for (final legacy in ['/10', '/10-confirm']) {
    testWidgets(
      '$legacy retains draft context and leaving writing before its first frame does not commit',
      (tester) async {
        final draft = _draft();
        final store = _LifecycleStore(
          Workspace(
            revision: 1,
            drafts: [draft],
            planningSessions: [_session(stage: 'draft', draftId: draft.id)],
          ),
        );
        final app = await _mount(
          tester,
          store,
          '$legacy?draftId=${draft.id}&sessionId=$_sessionId&from=history',
        );
        expect(app.router.state.uri.path, '/08');
        expect(app.router.state.uri.queryParameters, {
          'draftId': draft.id,
          'sessionId': _sessionId,
          'from': 'history',
        });
        expect(app.controller.data.tasks, isEmpty);
        expect(
          store.saves,
          0,
          reason: 'A legacy confirmation link only opens the draft.',
        );
        final savesBefore = store.saves;
        await _pushThenBackBeforePostFrame(
          tester,
          app.router,
          location: '/51?draftId=${draft.id}&sessionId=$_sessionId',
          title: '正在安排',
        );
        expect(app.router.routeInformationProvider.value.uri.path, '/08');
        expect(store.saves, savesBefore);
        expect(app.controller.draft(draft.id)!.status, 'draft');
        expect(app.controller.data.tasks, isEmpty);
        expect(app.controller.data.entries, isEmpty);
        expect(app.controller.data.goals, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'quickly leaving auto-resume progress does not start a provider request',
    (tester) async {
      final store = _LifecycleStore(
        Workspace(
          revision: 1,
          planningSessions: [_session(stage: 'generating')],
        ),
      );
      final app = await _mount(tester, store, '/34');
      await _pushThenBackBeforePostFrame(
        tester,
        app.router,
        location: '/07?sessionId=$_sessionId&start=1',
        title: '正在规划',
      );
      expect(app.router.routeInformationProvider.value.uri.path, '/34');
      expect(store.planningRequests, isEmpty);
      expect(app.controller.data.drafts, isEmpty);
      expect(
        app.controller.planningSession(_sessionId)!.aiRequestId,
        'durable-lifecycle-request',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a late generated draft persists without stealing navigation from a newer page',
    (tester) async {
      final store = _LifecycleStore(
        Workspace(revision: 1, planningSessions: [_session()]),
      );
      final app = await _mount(tester, store, '/06?sessionId=$_sessionId');
      await _tap(tester, '生成可执行的计划');
      expect(store.planningRequests, hasLength(1));
      expect(
        app.router.routeInformationProvider.value.uri.path,
        '/07-generating',
      );
      final requestId = store.planningRequests.single!;
      // Push keeps 06 and 07 mounted underneath, so a mounted-only check is not
      // sufficient to pass this regression test.
      unawaited(app.router.push<void>('/12'));
      await tester.pumpAndSettle();
      expect(app.router.routeInformationProvider.value.uri.path, '/12');
      store.planning.complete(_outline);
      await tester.pumpAndSettle();
      expect(app.router.routeInformationProvider.value.uri.path, '/12');
      expect(app.controller.data.drafts, hasLength(1));
      expect(app.controller.data.drafts.single.aiRequestId, requestId);
      expect(app.controller.data.tasks, isEmpty);
      expect(app.controller.data.entries, isEmpty);
      final reopened = SeraController(
        repository: store,
        today: _today,
        seedDemo: false,
      );
      await reopened.initialize();
      final restored = await reopened.generatePlan(
        title: '准备方案评审',
        deadline: _deadline,
        dailyBudget: 90,
        requestId: requestId,
      );
      expect(restored.id, app.controller.data.drafts.single.id);
      expect(store.planningRequests, hasLength(1));
      reopened.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a late generation failure does not open an error page over a newer route',
    (tester) async {
      final store = _LifecycleStore(
        Workspace(revision: 1, planningSessions: [_session()]),
      );
      final app = await _mount(tester, store, '/06?sessionId=$_sessionId');
      await _tap(tester, '生成可执行的计划');
      expect(store.planningRequests, hasLength(1));
      unawaited(app.router.push<void>('/12'));
      await tester.pumpAndSettle();
      store.planning.completeError(
        const RepositoryException('模型本次未完成', details: {'jobStatus': 'failed'}),
      );
      await tester.pumpAndSettle();
      expect(app.router.routeInformationProvider.value.uri.path, '/12');
      expect(app.controller.data.drafts, isEmpty);
      expect(app.controller.data.tasks, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'returning from progress to the original editor does not let a late draft take navigation',
    (tester) async {
      final store = _LifecycleStore(
        Workspace(revision: 1, planningSessions: [_session()]),
      );
      final app = await _mount(tester, store, '/06?sessionId=$_sessionId');
      await _tap(tester, '生成可执行的计划');
      expect(store.planningRequests, hasLength(1));
      expect(
        app.router.routeInformationProvider.value.uri.path,
        '/07-generating',
      );
      // A native/browser back pops 07 without pressing its cancel button. 06
      // becomes current again while its original generation future is pending.
      app.router.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(app.router.routeInformationProvider.value.uri.path, '/06');
      store.planning.complete(_outline);
      await tester.pumpAndSettle();
      expect(app.router.routeInformationProvider.value.uri.path, '/06');
      expect(app.controller.data.drafts, hasLength(1));
      expect(app.controller.data.tasks, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'leaving assistant preserves canceled input and ignores its late interpretation',
    (tester) async {
      final store = _LifecycleStore(const Workspace(revision: 1));
      final app = await _mount(
        tester,
        store,
        '/05?prompt=${Uri.encodeComponent('先保留这段未完成的输入')}',
      );
      await _tap(tester, '理解这段输入');
      expect(store.understandingRequests, hasLength(1));
      final sessionId = app.controller.planningSession()!.id;
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      final departedUri = app.router.routeInformationProvider.value.uri;
      expect(departedUri.path, '/04');
      expect(store.understandingCancellations, 1);
      store.understanding.complete(_interpretation);
      await tester.pumpAndSettle();
      expect(app.router.routeInformationProvider.value.uri, departedUri);
      final saved = app.controller.planningSession(sessionId)!;
      expect(saved.prompt, '先保留这段未完成的输入');
      expect(saved.stage, 'understanding_canceled');
      expect(saved.understanding, isNull);
      expect(saved.understandingRequestId, isNull);
      expect(app.controller.data.tasks, isEmpty);
      expect(app.controller.data.drafts, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
