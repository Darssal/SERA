import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:sera_flutter/application/admin_controller.dart';
import 'package:sera_flutter/application/community_controller.dart';
import 'package:sera_flutter/data/admin_repository.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/data/community_repository.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/admin_models.dart';
import 'package:sera_flutter/domain/community_models.dart';
import 'package:sera_flutter/ui/core/sera_theme.dart';
import 'package:sera_flutter/ui/screens/admin_screens.dart';

class _Storage implements AuthSessionStorage {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

class _Auth extends AuthRepository {
  _Auth() : super(apiBaseUrl: 'https://analytics.test', storage: _Storage());
  void use(String? id) {
    session = id == null
        ? null
        : AuthSession(
            token: 'token-$id',
            sessionId: 'session-$id',
            expiresAt: DateTime.now().add(const Duration(days: 1)),
            user: AuthUser(id: id, username: id, email: '$id@example.test'),
          );
    notifyListeners();
  }
}

const _owner = CommunityViewer(
  signedIn: true,
  isOfficial: true,
  canManageAdmins: true,
  canPublishOfficial: true,
  permissions: CommunityPermissions(
    publishOfficial: true,
    publishActivity: true,
    moderatePosts: true,
    moderateComments: true,
  ),
);
const _member = CommunityViewer(
  signedIn: true,
  isAdmin: true,
  permissions: CommunityPermissions(moderatePosts: true),
);

CommunityPost _rankedPost() => CommunityPost(
  id: 'ranked-real-id',
  authorId: 'writer',
  authorName: '测试作者',
  title: '分享周末的阅读记录',
  content: '这是真实对象 ID 对应的测试正文。',
  createdAt: DateTime.utc(2026, 11, 9, 7),
  likeCount: 5,
  commentCount: 2,
);

String _date(DateTime date) => date.toIso8601String().substring(0, 10);

AdminAnalytics _analytics(int days, {bool empty = false}) {
  final end = DateTime.utc(2026, 11, 9);
  final start = end.subtract(Duration(days: days - 1));
  final rows = [
    for (var i = 0; i < days; i++)
      AdminAnalyticsDay(
        date: _date(start.add(Duration(days: i))),
        newUsers: empty
            ? 0
            : i == 0
            ? 2
            : i == days - 1
            ? 1
            : 0,
        contributors: empty
            ? 0
            : i == 0
            ? 2
            : i == days - 1
            ? 1
            : 0,
        posts: empty
            ? 0
            : i == 0
            ? 3
            : i == days - 1
            ? 1
            : 0,
        comments: empty
            ? 0
            : i == 0
            ? 4
            : i == days - 1
            ? 2
            : 0,
      ),
  ];
  return AdminAnalytics(
    days: days,
    timeZone: 'Asia/Hong_Kong',
    generatedAt: DateTime.utc(2026, 11, 9, 8, 37),
    period: AdminAnalyticsPeriod(
      startDate: _date(start),
      endDate: _date(end),
      endAt: DateTime.utc(2026, 11, 9, 8, 37),
    ),
    previousPeriod: AdminAnalyticsPeriod(
      startDate: _date(start.subtract(Duration(days: days))),
      endDate: _date(start.subtract(const Duration(days: 1))),
      endAt: DateTime.utc(2026, 11, 9, 8, 37).subtract(Duration(days: days)),
    ),
    summary: AdminAnalyticsSummary(
      newUsers: AdminAnalyticsMetric(value: empty ? 0 : 3, previous: 0),
      contributors: AdminAnalyticsMetric(value: empty ? 0 : 2, previous: 1),
      posts: AdminAnalyticsMetric(value: empty ? 0 : 4, previous: 2),
      comments: AdminAnalyticsMetric(value: empty ? 0 : 6, previous: 0),
    ),
    daily: rows,
    contentTypes: [
      AdminAnalyticsCategory(key: 'daily', label: '日常动态', count: empty ? 0 : 2),
      AdminAnalyticsCategory(
        key: 'feedback',
        label: '使用反馈',
        count: empty ? 0 : 1,
      ),
      AdminAnalyticsCategory(
        key: 'activity',
        label: '活动',
        count: empty ? 0 : 1,
      ),
    ],
    currentInteractions: AdminAnalyticsInteractions(
      likes: empty ? 0 : 12,
      participants: empty ? 0 : 3,
    ),
    topPosts: empty
        ? []
        : [AdminAnalyticsPost(post: _rankedPost(), interactions: 7)],
  );
}

class _Repo extends AdminRepository {
  _Repo({required super.auth});
  final requests = <int>[];
  final pending = <int, Completer<AdminAnalytics>>{};
  int postsCalls = 0;
  bool empty = false, fail = false;
  @override
  Future<AdminBootstrap> bootstrap() async => AdminBootstrap(
    viewer: auth.session?.user.id == 'owner' ? _owner : _member,
    counts: const AdminCounts(posts: 6, comments: 5),
  );
  @override
  Future<AdminAnalytics> getAnalytics({int days = 30}) async {
    requests.add(days);
    if (pending[days] case final future?) return future.future;
    if (fail) throw const RepositoryException('统计服务暂时不可用。');
    return _analytics(days, empty: empty);
  }

  @override
  Future<AdminPage<CommunityPost>> listPosts({
    String q = '',
    String category = '',
    String kind = '',
    bool? official,
    String? cursor,
    int limit = 30,
  }) async {
    postsCalls++;
    return AdminPage(items: [], total: 0);
  }
}

class _CommunityRepo extends CommunityRepository {
  _CommunityRepo(_Auth auth) : super(auth: auth);
  final detailIds = <String>[];
  @override
  Future<CommunityDetail> getDetail(String id, {String? commentCursor}) async {
    detailIds.add(id);
    return CommunityDetail(post: _rankedPost(), comments: [], viewer: _owner);
  }
}

class _Fixture {
  _Fixture({String account = 'owner'}) {
    auth = _Auth()..use(account);
    repo = _Repo(auth: auth);
    communityRepo = _CommunityRepo(auth);
    community = CommunityController(repository: communityRepo);
    controller = AdminController(
      auth: auth,
      repository: repo,
      communityRepository: communityRepo,
    );
  }
  late final _Auth auth;
  late final _Repo repo;
  late final _CommunityRepo communityRepo;
  late final CommunityController community;
  late final AdminController controller;
  GoRouter? router;
  Future<void> mount(
    WidgetTester tester, {
    double width = 1536,
    double scale = 1,
    bool settle = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1024);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    router = GoRouter(
      initialLocation: '/admin/overview',
      routes: [
        GoRoute(
          path: '/admin/:section',
          builder: (_, state) => AdminConsoleScreen(
            section: state.pathParameters['section']!,
            controller: controller,
          ),
        ),
        GoRoute(
          path: '/community',
          builder: (_, _) => const Scaffold(body: Text('社区')),
        ),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      controller.dispose();
      community.dispose();
      communityRepo.dispose();
      auth.dispose();
      router!.dispose();
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthRepository>.value(value: auth),
          ChangeNotifierProvider<CommunityController>.value(value: community),
        ],
        child: MaterialApp.router(theme: seraTheme(), routerConfig: router),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump();
    }
  }
}

Finder _key(String value) => find.byKey(ValueKey(value));
Future<void> _show(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      180,
      scrollable: find
          .descendant(
            of: _key('admin-analytics-overview'),
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 60,
    );
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await _show(tester, target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'owner overview loads server analytics and displays exact periods, metrics and neutral comparisons',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      expect(f.repo.requests, [30]);
      expect(f.repo.postsCalls, 0);
      expect(
        tester.widget<Text>(_key('admin-analytics-metric-new-users')).data,
        '3',
      );
      expect(
        tester.widget<Text>(_key('admin-analytics-metric-contributors')).data,
        '2',
      );
      expect(
        tester.widget<Text>(_key('admin-analytics-metric-posts')).data,
        '4',
      );
      expect(
        tester.widget<Text>(_key('admin-analytics-metric-comments')).data,
        '6',
      );
      expect(
        tester.widget<Text>(_key('admin-analytics-period')).data,
        contains('2026/10/11 — 2026/11/09'),
      );
      expect(find.textContaining('较前期增加 3人'), findsOneWidget);
      expect(find.textContaining('100%'), findsNothing);
      expect(find.textContaining('截至 11月9日 16:37'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ordinary administrator keeps operational overview without calling owner analytics',
    (tester) async {
      final f = _Fixture(account: 'member');
      await f.mount(tester);
      expect(f.repo.requests, isEmpty);
      expect(f.repo.postsCalls, 1);
      expect(_key('admin-analytics-overview'), findsNothing);
      expect(_key('admin-count-社区内容'), findsOneWidget);
    },
  );

  for (final width in [320.0, 390.0, 1536.0]) {
    testWidgets(
      'analytics charts and lower sections remain usable at $width and 1.7 text scale',
      (tester) async {
        final f = _Fixture();
        await f.mount(tester, width: width, scale: 1.7);
        await _show(tester, _key('admin-analytics-trend-plot'));
        await tester.tap(_key('admin-analytics-trend-plot'));
        await tester.pumpAndSettle();
        await _show(tester, _key('admin-analytics-growth-plot'));
        await _show(tester, _key('admin-analytics-category-daily'));
        await _show(tester, _key('admin-analytics-current-interactions'));
        expect(
          tester
              .widget<Text>(_key('admin-analytics-current-interactions'))
              .data,
          '12 个赞 · 3 次报名',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'range failure never labels previous range data as new data and retry restores the selected range',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      final request = Completer<AdminAnalytics>();
      f.repo.pending[7] = request;
      await tester.tap(_key('admin-analytics-range-7'));
      await tester.pump();
      expect(_key('admin-analytics-metric-posts'), findsNothing);
      expect(find.text('正在读取近 7 天的数据…'), findsOneWidget);
      request.completeError(const RepositoryException('七天统计读取失败。'));
      await tester.pumpAndSettle();
      expect(_key('admin-analytics-period'), findsNothing);
      expect(find.text('七天统计读取失败。'), findsOneWidget);
      f.repo.pending.remove(7);
      await _tap(tester, find.widgetWithText(TextButton, '重试'));
      expect(
        tester.widget<Text>(_key('admin-analytics-period')).data,
        contains('2026/11/03 — 2026/11/09'),
      );
      expect(f.repo.requests, [30, 7, 7]);
    },
  );

  testWidgets(
    'pointer and keyboard choose exact daily values and synchronize both charts',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      final plot = _key('admin-analytics-trend-plot');
      await _show(tester, plot);
      final rect = tester.getRect(plot);
      await tester.tapAt(Offset(rect.left + 1, rect.center.dy));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(_key('admin-analytics-trend-selected')).data,
        '2026/10/11 · 发布内容 3 篇 · 新增评论 4 条',
      );
      expect(
        tester.widget<Text>(_key('admin-analytics-growth-selected')).data,
        '2026/10/11 · 新增账号 2 人',
      );
      final firstSemantics = tester
          .widget<Semantics>(_key('admin-analytics-trend-semantics'))
          .properties;
      expect(firstSemantics.decreasedValue, isNull);
      expect(firstSemantics.onDecrease, isNull);
      expect(firstSemantics.increasedValue, '2026/10/12，发布内容 0 篇 · 新增评论 0 条');
      firstSemantics.onIncrease!();
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(_key('admin-analytics-trend-selected')).data,
        '2026/10/12 · 发布内容 0 篇 · 新增评论 0 条',
      );
      tester
          .widget<Semantics>(_key('admin-analytics-trend-semantics'))
          .properties
          .onDecrease!();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(_key('admin-analytics-trend-selected')).data,
        '2026/10/12 · 发布内容 0 篇 · 新增评论 0 条',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(_key('admin-analytics-trend-selected')).data,
        '2026/11/09 · 发布内容 1 篇 · 新增评论 2 条',
      );
      final lastSemantics = tester
          .widget<Semantics>(_key('admin-analytics-trend-semantics'))
          .properties;
      expect(lastSemantics.increasedValue, isNull);
      expect(lastSemantics.onIncrease, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ranked content opens the exact server object instead of a placeholder and definitions stay collapsed',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await _tap(tester, _key('admin-analytics-view-post-ranked-real-id'));
      expect(f.communityRepo.detailIds, ['ranked-real-id']);
      expect(_key('admin-detail-dialog'), findsOneWidget);
      expect(find.text('这是真实对象 ID 对应的测试正文。'), findsOneWidget);
      await _tap(tester, find.byTooltip('关闭详情'));
      await _tap(tester, _key('admin-analytics-definitions'));
      expect(find.textContaining('不代表访问人数或日活跃用户'), findsOneWidget);
    },
  );

  testWidgets(
    'zero data produces zero shares, no fabricated ranking and an accessible daily table',
    (tester) async {
      final f = _Fixture();
      f.repo.empty = true;
      await f.mount(tester);
      await _show(tester, _key('admin-analytics-category-daily'));
      expect(
        tester.widget<Text>(_key('admin-analytics-category-daily')).data,
        '0 篇 · 0%',
      );
      expect(_key('admin-analytics-top-empty'), findsOneWidget);
      expect(find.textContaining('NaN'), findsNothing);
      expect(_key('admin-analytics-view-post-ranked-real-id'), findsNothing);
      await _tap(tester, _key('admin-analytics-daily-data'));
      expect(_key('admin-analytics-select-2026-11-09'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'initial failure never renders fake zeros and account changes discard late analytics results',
    (tester) async {
      final f = _Fixture();
      f.repo.fail = true;
      await f.mount(tester);
      expect(find.text('统计服务暂时不可用。'), findsOneWidget);
      expect(_key('admin-analytics-metric-posts'), findsNothing);
      f.repo.fail = false;
      final request = Completer<AdminAnalytics>();
      f.repo.pending[30] = request;
      await tester.tap(find.widgetWithText(TextButton, '重试'));
      await tester.pump();
      f.auth.use('member');
      await tester.pumpAndSettle();
      request.complete(_analytics(30));
      await tester.pumpAndSettle();
      expect(f.controller.analytics, isNull);
      expect(_key('admin-analytics-overview'), findsNothing);
      expect(_key('admin-count-社区内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
