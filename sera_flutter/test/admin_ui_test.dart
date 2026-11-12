import 'package:flutter/material.dart';
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
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Auth extends AuthRepository {
  _Auth() : super(apiBaseUrl: 'https://admin.test', storage: _Storage());
  void use(String? id) {
    session = id == null
        ? null
        : AuthSession(
            token: 'token-$id',
            sessionId: 'session-$id',
            csrfToken: 'csrf-$id',
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
const _moderator = CommunityViewer(
  signedIn: true,
  isAdmin: true,
  permissions: CommunityPermissions(moderateComments: true),
);

CommunityPost _post(String id) => CommunityPost(
  id: id,
  authorId: 'user',
  authorName: '测试同学',
  title: '复习记录 $id',
  content: '完成今天的阅读和练习。',
  createdAt: DateTime.utc(2026, 11, 9, 8),
  canDelete: true,
);

class _Repo extends AdminRepository {
  _Repo({required super.auth});
  final rows = <CommunityPost>[_post('p1'), _post('p2'), _post('p3')];
  final queries = <(String, String, String, String?)>[];
  final deletions = <(String, String, String)>[];
  bool failDelete = false;
  int bootstrapCalls = 0;
  CommunityViewer get viewer =>
      auth.session?.user.id == 'moderator' ? _moderator : _owner;
  @override
  Future<AdminBootstrap> bootstrap() async {
    bootstrapCalls++;
    if (!const ['official', 'moderator'].contains(auth.session?.user.id)) {
      throw const RepositoryException(
        '此账号没有后台管理权限。',
        details: {'code': 'admin_required'},
      );
    }
    return AdminBootstrap(
      viewer: viewer,
      counts: AdminCounts(posts: rows.length, comments: 0, users: 4),
    );
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
    queries.add((q, category, kind, cursor));
    final matches = rows.where((row) => row.title.contains(q)).toList();
    final index = cursor == null ? 0 : int.parse(cursor);
    return AdminPage(
      items: matches.skip(index).take(1).toList(),
      total: matches.length,
      nextCursor: index + 1 < matches.length ? '${index + 1}' : null,
    );
  }

  @override
  Future<AdminPage<AdminComment>> listComments({
    String q = '',
    String postId = '',
    String? cursor,
    int limit = 30,
  }) async => AdminPage(items: [], total: 0);

  @override
  Future<void> deletePost(
    String id, {
    required String requestId,
    required String reason,
  }) async {
    deletions.add((id, requestId, reason));
    if (failDelete) throw const RepositoryException('网络断开，请重试。');
    rows.removeWhere((row) => row.id == id);
  }
}

class _CommunityRepo extends CommunityRepository {
  _CommunityRepo(_Auth auth, this.admin) : super(auth: auth);
  final _Repo admin;
  @override
  String? get stableSessionScope => null;
  @override
  Future<CommunityFeed> list({String filter = 'all', String? cursor}) async =>
      CommunityFeed(posts: admin.rows, viewer: admin.viewer);
  @override
  Future<CommunityDetail> getDetail(String id, {String? commentCursor}) async =>
      CommunityDetail(
        post: admin.rows.singleWhere((post) => post.id == id),
        comments: [],
        viewer: admin.viewer,
      );
  @override
  Future<CommunityManagement> getManagement() async => CommunityManagement(
    viewer: admin.viewer,
    admins: const [
      CommunityAdmin(
        userId: 'helper',
        username: '协助同学',
        permissions: CommunityPermissions(moderateComments: true),
      ),
    ],
  );
}

class _Fixture {
  _Fixture({String? account = 'official'}) {
    auth = _Auth()..use(account);
    repo = _Repo(auth: auth);
    communityRepo = _CommunityRepo(auth, repo);
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
  final key = GlobalKey<AdminConsoleScreenState>();
  GoRouter? router;
  Future<void> mount(
    WidgetTester tester, {
    String section = 'posts',
    double width = 1536,
    double textScale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1024);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    router = GoRouter(
      initialLocation: '/admin/$section',
      routes: [
        GoRoute(
          path: '/admin/:section',
          onExit: (_, _) async =>
              await key.currentState?.confirmLeave() ?? true,
          pageBuilder: (_, state) => NoTransitionPage<void>(
            key: const ValueKey('admin-console-test'),
            child: AdminConsoleScreen(
              key: key,
              section: state.pathParameters['section']!,
              controller: controller,
            ),
          ),
        ),
        GoRoute(
          path: '/community',
          builder: (_, _) => const Scaffold(body: Text('测试社区出口')),
        ),
        GoRoute(
          path: '/login',
          builder: (_, _) => const Scaffold(body: Text('测试登录出口')),
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
    await tester.pumpAndSettle();
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'guest cannot load administration data and sign-in preserves the destination',
    (tester) async {
      final f = _Fixture(account: null);
      await f.mount(tester);
      expect(f.repo.bootstrapCalls, 0);
      expect(find.byKey(const ValueKey('admin-nav-posts')), findsNothing);
      await _tap(tester, find.widgetWithText(FilledButton, '登录'));
      expect(f.router!.state.uri.path, '/login');
      expect(f.router!.state.uri.queryParameters['returnTo'], '/admin/posts');
      expect(f.repo.queries, isEmpty);
    },
  );

  testWidgets('ordinary account cannot see the admin data or navigation', (
    tester,
  ) async {
    final f = _Fixture(account: 'ordinary');
    await f.mount(tester);
    expect(f.repo.bootstrapCalls, 1);
    expect(f.repo.queries, isEmpty);
    expect(find.byKey(const ValueKey('admin-nav-users')), findsNothing);
    expect(find.byKey(const ValueKey('admin-view-post-p1')), findsNothing);
    expect(f.controller.bootstrap, isNull);
  });

  testWidgets(
    'comment moderator sees content but cannot navigate to owner management',
    (tester) async {
      final f = _Fixture(account: 'moderator');
      await f.mount(tester);
      expect(find.byKey(const ValueKey('admin-nav-posts')), findsOneWidget);
      expect(find.byKey(const ValueKey('admin-nav-users')), findsNothing);
      expect(find.byKey(const ValueKey('admin-nav-team')), findsNothing);
      expect(find.byKey(const ValueKey('admin-nav-publish')), findsNothing);
      expect(find.byKey(const ValueKey('admin-delete-post-p1')), findsNothing);
      await _tap(
        tester,
        find.byKey(const ValueKey('admin-content-tab-comments')),
      );
      expect(f.controller.comments.items, isEmpty);
      expect(f.controller.comments.error, isNull);
    },
  );

  for (final width in [390.0, 1536.0]) {
    testWidgets(
      'content layout supports $width px and large text without overflow',
      (tester) async {
        final f = _Fixture();
        await f.mount(tester, width: width, textScale: 1.7);
        expect(tester.takeException(), isNull);
        expect(f.controller.posts.items.single.id, 'p1');
        if (width > 900) {
          expect(find.byKey(const ValueKey('admin-nav-users')), findsOneWidget);
        } else {
          await _tap(tester, find.byTooltip('Open navigation menu'));
          expect(find.byKey(const ValueKey('admin-nav-users')), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'query tabs and load-more update real request parameters and rows',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      final field = find.byType(TextField).first;
      await tester.enterText(field, '  复习  ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(f.repo.queries.last.$1, '复习');
      await _tap(tester, find.widgetWithText(OutlinedButton, '加载更多'));
      expect(f.repo.queries.last.$4, '1');
      expect(f.controller.posts.items.map((post) => post.id), ['p1', 'p2']);
      await _tap(
        tester,
        find.byKey(const ValueKey('admin-content-tab-feedback')),
      );
      expect(f.repo.queries.last, ('复习', 'feedback', '', null));
      expect(f.controller.posts.items.single.id, 'p1');
    },
  );

  testWidgets(
    'removal cancel does not write and failed confirmation retains reason for stable retry',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await _tap(tester, find.byKey(const ValueKey('admin-delete-post-p1')));
      await _tap(tester, find.widgetWithText(TextButton, '取消'));
      expect(f.repo.deletions, isEmpty);
      await _tap(tester, find.byKey(const ValueKey('admin-delete-post-p1')));
      await tester.enterText(
        find.byKey(const ValueKey('admin-action-reason')),
        '重复内容',
      );
      f.repo.failDelete = true;
      await _tap(tester, find.widgetWithText(FilledButton, '确认移除'));
      expect(f.controller.posts.items.single.id, 'p1');
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('admin-action-reason')),
            )
            .controller!
            .text,
        '重复内容',
      );
      expect(f.repo.deletions.length, 1);
      f.repo.failDelete = false;
      await _tap(tester, find.widgetWithText(FilledButton, '确认移除'));
      expect(f.repo.deletions.length, 2);
      expect(f.repo.deletions.first.$2, f.repo.deletions.last.$2);
      expect(f.repo.rows.map((post) => post.id), ['p2', 'p3']);
      expect(f.controller.counts.posts, 2);
      expect(find.byKey(const ValueKey('admin-action-reason')), findsNothing);
    },
  );

  testWidgets(
    'account change closes open content detail and clears its cached record',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await _tap(tester, find.byKey(const ValueKey('admin-view-post-p1')));
      expect(f.controller.detail('p1')!.post.id, 'p1');
      expect(find.byTooltip('关闭详情'), findsOneWidget);
      f.auth.use('ordinary');
      await tester.pumpAndSettle();
      expect(find.byTooltip('关闭详情'), findsNothing);
      expect(f.controller.detail('p1'), isNull);
      expect(f.controller.posts.items, isEmpty);
    },
  );

  testWidgets(
    'account change closes permission editing without granting the unsaved checkboxes',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester, section: 'team');
      await _tap(
        tester,
        find.byKey(const ValueKey('admin-edit-member-helper')),
      );
      final checkbox = find.byKey(
        const ValueKey('admin-permission-publishOfficial'),
      );
      expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
      await _tap(tester, checkbox);
      expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);
      expect(
        f.community.management!.admins.single.permissions.publishOfficial,
        isFalse,
      );
      f.auth.use('ordinary');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('admin-permission-dialog')),
        findsNothing,
      );
      expect(f.community.management, isNull);
      expect(f.controller.bootstrap, isNull);
    },
  );

  testWidgets(
    'publication leave guard retains input on cancel and discards it only on confirmation',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester, section: 'publish');
      final input = find.byKey(const ValueKey('community-content-input'));
      await tester.enterText(input, '尚未发布的活动说明');
      await tester.pumpAndSettle();
      final cancelled = f.key.currentState!.confirmLeave();
      await tester.pumpAndSettle();
      await _tap(tester, find.widgetWithText(TextButton, '继续编辑'));
      expect(await cancelled, isFalse);
      expect(tester.widget<TextFormField>(input).controller!.text, '尚未发布的活动说明');
      final confirmed = f.key.currentState!.confirmLeave();
      await tester.pumpAndSettle();
      await _tap(tester, find.widgetWithText(FilledButton, '放弃并离开'));
      expect(await confirmed, isTrue);
      expect(f.repo.rows.length, 3);
      expect(
        find.byKey(const ValueKey('community-content-input')),
        findsNothing,
      );
    },
  );
}
