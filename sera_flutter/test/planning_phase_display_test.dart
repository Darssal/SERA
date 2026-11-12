import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/app.dart';
import 'package:sera_flutter/application/sera_controller.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

final _today = DateTime(2026, 10, 31);

class _PhaseDisplayStore implements WorkspaceRepository {
  _PhaseDisplayStore(this.value);
  Workspace value;
  int writes = 0;

  @override
  String get mode => 'phase-display-memory-fixture';

  @override
  Future<Workspace?> load() async => value;

  @override
  Future<void> clear() async => value = const Workspace();

  @override
  Future<Workspace> save(
    Workspace workspace, {
    required int expectedRevision,
  }) async {
    if (expectedRevision != value.revision) {
      throw const RepositoryException('测试工作区版本冲突', conflict: true);
    }
    writes++;
    return value = Workspace.fromJson(
      workspace.copyWith(revision: expectedRevision + 1).toJson(),
    );
  }
}

PlannedTask _item(String id, {String phase = '', String? start, String? end}) =>
    PlannedTask(
      task: SeraTask(
        id: id,
        title: '复习任务 $id',
        goalId: 'phase-goal',
        phase: phase,
        notBefore: start == null ? null : DateTime.parse(start),
        dueAt: end == null ? null : DateTime.parse(end),
      ),
    );

Workspace _draftWorkspace(List<PlannedTask> items) => Workspace(
  revision: 1,
  preferences: const SeraPreferences(timeZone: 'Asia/Hong_Kong'),
  drafts: [
    PlanDraft(
      id: 'phase-draft',
      goal: SeraGoal(
        id: 'phase-goal',
        title: '跨周课程复习',
        deadline: DateTime.parse('2027-01-31T23:59:00+08:00'),
      ),
      items: items,
    ),
  ],
);

Future<_PhaseDisplayStore> _mount(
  WidgetTester tester,
  Workspace workspace,
  String location,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final store = _PhaseDisplayStore(workspace);
  final controller = SeraController(repository: store, today: _today);
  await controller.initialize();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  await tester.pumpWidget(
    SeraApp(
      key: UniqueKey(),
      controller: controller,
      initialLocation: location,
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  testWidgets(
    'phase groups show one header and their full cross-year date window',
    (tester) async {
      final store = await _mount(
        tester,
        _draftWorkspace([
          _item(
            'foundation-later',
            phase: '基础积累',
            start: '2027-01-03T16:00:00Z',
            end: '2027-01-10T15:59:00Z',
          ),
          _item(
            'foundation-earlier',
            phase: '基础积累',
            start: '2026-12-27T16:00:00Z',
            end: '2027-01-03T15:59:00Z',
          ),
          _item(
            'practice-later',
            phase: '专项强化',
            start: '2027-01-17T16:00:00Z',
            end: '2027-01-24T15:59:00Z',
          ),
          _item(
            'practice-earlier',
            phase: '专项强化',
            start: '2027-01-10T16:00:00Z',
            end: '2027-01-17T15:59:00Z',
          ),
        ]),
        '/08?draftId=phase-draft',
      );
      expect(find.text('基础积累'), findsOneWidget);
      expect(find.text('专项强化'), findsOneWidget);
      expect(find.text('12月28日 周一 — 2027年1月10日 周日'), findsOneWidget);
      expect(find.text('2027年1月11日 周一 — 2027年1月24日 周日'), findsOneWidget);
      expect(find.textContaining('复习任务 '), findsNWidgets(4));
      final firstHeader = tester.getTopLeft(find.text('基础积累')).dy;
      final firstTask = tester
          .getTopLeft(
            find.byKey(
              const ValueKey('draft-row:phase-draft:foundation-later'),
            ),
          )
          .dy;
      final secondHeader = tester.getTopLeft(find.text('专项强化')).dy;
      final secondTask = tester
          .getTopLeft(
            find.byKey(const ValueKey('draft-row:phase-draft:practice-later')),
          )
          .dy;
      expect(firstHeader, lessThan(firstTask));
      expect(secondHeader, greaterThan(firstTask));
      expect(secondHeader, lessThan(secondTask));
      await tester.ensureVisible(find.text('复习任务 practice-earlier'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(store.writes, 0);
    },
  );

  testWidgets('legacy unphased tasks keep their rows without empty headers', (
    tester,
  ) async {
    final store = await _mount(
      tester,
      _draftWorkspace([_item('legacy-one'), _item('legacy-two')]),
      '/08?draftId=phase-draft',
    );
    expect(find.text('复习任务 legacy-one'), findsOneWidget);
    expect(find.text('复习任务 legacy-two'), findsOneWidget);
    expect(find.textContaining(' — '), findsNothing);
    expect(find.text('基础积累'), findsNothing);
    expect(find.text('专项强化'), findsNothing);
    expect(tester.takeException(), isNull);
    expect(store.writes, 0);
  });

  testWidgets(
    'a named phase without known dates does not invent a date range',
    (tester) async {
      final store = await _mount(
        tester,
        _draftWorkspace([
          _item('unknown-one', phase: '待定阶段'),
          _item('unknown-two', phase: '待定阶段'),
        ]),
        '/08?draftId=phase-draft',
      );
      expect(find.text('待定阶段'), findsOneWidget);
      expect(find.textContaining(' — '), findsNothing);
      expect(find.text('复习任务 unknown-one'), findsOneWidget);
      expect(find.text('复习任务 unknown-two'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(store.writes, 0);
    },
  );

  for (final route in ['06', '39']) {
    for (final requestedBudget in [180, 90]) {
      testWidgets(
        '$route preserves the requested daily target without presenting a hard cap ($requestedBudget)',
        (tester) async {
          final store = await _mount(
            tester,
            Workspace(
              revision: 1,
              preferences: const SeraPreferences(dailyBudget: 90),
              planningSessions: [
                PlanningSession(
                  id: 'budget-session',
                  updatedAt: _today,
                  prompt: '准备课程复习',
                  title: '课程复习',
                  deadline: DateTime(2027, 1, 31, 23, 59),
                  dailyBudget: requestedBudget,
                  stage: route == '06' ? 'clarify' : 'failed',
                ),
              ],
            ),
            '/$route?sessionId=budget-session',
          );
          if (route == '39') {
            expect(find.text('输入已保留，可以重试或调整要求。'), findsOneWidget);
            expect(find.text('$requestedBudget 分钟'), findsNothing);
            await tester.tap(find.text('查看详情'));
            await tester.pumpAndSettle();
          }
          expect(find.text('$requestedBudget 分钟'), findsOneWidget);
          if (route == '06' && requestedBudget > 90) {
            final reference = find.text('日常规划参考：90 分钟');
            expect(reference, findsOneWidget);
            await tester.ensureVisible(reference);
            await tester.pumpAndSettle();
            expect(reference.hitTestable(), findsOneWidget);
          } else {
            expect(find.textContaining('日常规划参考'), findsNothing);
          }
          expect(find.textContaining('实际每日上限'), findsNothing);
          expect(tester.takeException(), isNull);
          expect(store.writes, 0);
        },
      );
    }
  }
}
