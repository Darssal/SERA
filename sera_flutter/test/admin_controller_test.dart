import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/application/admin_controller.dart';
import 'package:sera_flutter/data/admin_repository.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/data/community_repository.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/admin_models.dart';
import 'package:sera_flutter/domain/community_models.dart';

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
  _Auth({super.client})
    : super(apiBaseUrl: 'https://admin.test', storage: _Storage());
  void use(String? id, {String sessionId = 'one', bool cookie = false}) {
    session = id == null
        ? null
        : AuthSession(
            token: cookie ? '' : 'token-$id-$sessionId',
            csrfToken: 'csrf-$id-$sessionId',
            sessionId: '$id-$sessionId',
            cookieSession: cookie,
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
  authorName: '测试用户',
  title: '标题$id',
  content: '内容$id',
  createdAt: DateTime.utc(2026, 11, 9),
  canDelete: true,
);
AdminComment _comment(String id, {String postId = 'p1'}) => AdminComment(
  comment: CommunityComment(
    id: id,
    postId: postId,
    authorName: '测试用户',
    content: '评论$id',
    createdAt: DateTime.utc(2026, 11, 9),
    canDelete: true,
  ),
  postTitle: '标题$postId',
);
AdminUser _user(String id, {bool disabled = false}) => AdminUser(
  id: id,
  username: id,
  createdAt: DateTime.utc(2026, 11, 9),
  emailMasked: 'u***@example.test',
  disabled: disabled,
);
AdminAuditEntry _entry(String id) => AdminAuditEntry(
  id: id,
  actorName: '官方',
  action: 'delete_post',
  targetType: 'post',
  targetId: 'p1',
  targetLabel: '标题p1',
  createdAt: DateTime.utc(2026, 11, 9),
);

class _Repo extends AdminRepository {
  _Repo({required super.auth});
  CommunityViewer currentViewer = _owner;
  List<CommunityPost> postRows = [_post('p1'), _post('p2')];
  List<AdminComment> commentRows = [_comment('c1'), _comment('c2')];
  List<AdminUser> userRows = [_user('u1')];
  int bootstrapCalls = 0;
  final postCalls = <(String, String, String, bool?, String?)>[];
  final commentCalls = <(String, String, String?)>[];
  final userCalls = <(String, String, String?)>[];
  final auditCalls = <(String, String?)>[];
  final writes = <(String, String, String, String, bool?)>[];
  Future<AdminBootstrap> Function()? onBootstrap;
  Future<AdminPage<CommunityPost>> Function(String? cursor)? onPosts;
  Future<AdminPage<AdminComment>> Function(String? cursor)? onComments;
  Future<AdminPage<AdminUser>> Function(String? cursor)? onUsers;
  Future<AdminPage<AdminAuditEntry>> Function(String? cursor)? onAudit;
  Future<void> Function()? onWrite;
  Future<AdminStatus> Function()? onStatus;

  @override
  Future<AdminBootstrap> bootstrap() {
    bootstrapCalls++;
    return onBootstrap?.call() ??
        Future.value(
          AdminBootstrap(
            viewer: currentViewer,
            counts: AdminCounts(
              posts: postRows.length,
              comments: commentRows.length,
              users: currentViewer.canManageAdmins ? userRows.length : null,
              pendingApplications: currentViewer.canManageAdmins ? 2 : null,
            ),
          ),
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
  }) {
    postCalls.add((q, category, kind, official, cursor));
    return onPosts?.call(cursor) ??
        Future.value(AdminPage(items: postRows, total: postRows.length));
  }

  @override
  Future<AdminPage<AdminComment>> listComments({
    String q = '',
    String postId = '',
    String? cursor,
    int limit = 30,
  }) {
    commentCalls.add((q, postId, cursor));
    return onComments?.call(cursor) ??
        Future.value(AdminPage(items: commentRows, total: commentRows.length));
  }

  @override
  Future<AdminPage<AdminUser>> listUsers({
    String q = '',
    String status = '',
    String? cursor,
    int limit = 30,
  }) {
    userCalls.add((q, status, cursor));
    return onUsers?.call(cursor) ??
        Future.value(AdminPage(items: userRows, total: userRows.length));
  }

  @override
  Future<AdminPage<AdminAuditEntry>> listAudit({
    String q = '',
    String? cursor,
    int limit = 30,
  }) {
    auditCalls.add((q, cursor));
    return onAudit?.call(cursor) ??
        Future.value(AdminPage(items: [_entry('a1')], total: 1));
  }

  @override
  Future<AdminStatus> getStatus() =>
      onStatus?.call() ??
      Future.value(
        AdminStatus(
          components: const [
            AdminStatusComponent(
              id: 'mail',
              name: '邮件',
              status: 'configured',
              configured: true,
              healthy: null,
              detail: '已配置，未进行外部连通性检测',
            ),
          ],
        ),
      );

  @override
  Future<void> deletePost(
    String id, {
    required String requestId,
    required String reason,
  }) async {
    writes.add(('post', id, requestId, reason, null));
    await onWrite?.call();
    postRows = postRows.where((post) => post.id != id).toList();
    commentRows = commentRows.where((comment) => comment.postId != id).toList();
  }

  @override
  Future<void> deleteComment(
    String id, {
    required String requestId,
    required String reason,
  }) async {
    writes.add(('comment', id, requestId, reason, null));
    await onWrite?.call();
    commentRows = commentRows.where((comment) => comment.id != id).toList();
  }

  @override
  Future<void> setUserDisabled(
    String id, {
    required bool disabled,
    required String reason,
    required String requestId,
  }) async {
    writes.add(('user', id, requestId, reason, disabled));
    await onWrite?.call();
    userRows = [
      for (final user in userRows)
        if (user.id == id) _user(id, disabled: disabled) else user,
    ];
  }
}

class _CommunityRepo extends CommunityRepository {
  _CommunityRepo(_Auth auth) : super(auth: auth);
  Future<CommunityDetail> Function(String id)? onDetail;
  @override
  Future<CommunityDetail> getDetail(String id, {String? commentCursor}) =>
      onDetail?.call(id) ??
      Future.value(
        CommunityDetail(post: _post(id), comments: [], viewer: _owner),
      );
}

({AdminController controller, _Repo repo, _CommunityRepo community, _Auth auth})
_fixture() {
  final auth = _Auth()..use('official');
  final repo = _Repo(auth: auth);
  final community = _CommunityRepo(auth);
  final controller = AdminController(
    auth: auth,
    repository: repo,
    communityRepository: community,
  );
  addTearDown(() {
    controller.dispose();
    community.dispose();
    auth.dispose();
  });
  return (controller: controller, repo: repo, community: community, auth: auth);
}

void main() {
  test(
    'a failed new filter keeps rows without reusing the old filter cursor',
    () async {
      final f = _fixture();
      f.repo.onPosts = (_) async =>
          AdminPage(items: [_post('p1')], total: 2, nextCursor: 'old-filter');
      await f.controller.loadPosts(q: 'old');
      f.repo.onPosts = (_) async => throw const RepositoryException('网络断开');
      await f.controller.loadPosts(q: 'new');
      await f.controller.loadMorePosts();
      expect(f.controller.posts.items.single.id, 'p1');
      expect(f.controller.posts.hasMore, isFalse);
      expect(f.repo.postCalls.length, 2);
    },
  );

  test('revoked admin access clears privileged cached content', () async {
    final f = _fixture();
    await f.controller.loadBootstrap();
    await f.controller.loadPosts();
    await f.controller.loadUsers();
    await f.controller.loadDetail('p1');
    f.repo.onBootstrap = () async => throw const RepositoryException(
      '此账号没有后台管理权限。',
      details: {'code': 'admin_required'},
    );
    await f.controller.loadBootstrap();
    expect(f.controller.bootstrap, isNull);
    expect(f.controller.posts.items, isEmpty);
    expect(f.controller.users.items, isEmpty);
    expect(f.controller.detail('p1'), isNull);
    expect(f.controller.error, isNotNull);
  });

  test(
    'malformed admin lists fail instead of displaying empty success',
    () async {
      final dio = Dio();
      final auth = _Auth(client: dio)..use('official');
      final repo = AdminRepository(auth: auth);
      addTearDown(() {
        auth.dispose();
        dio.close();
      });
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'posts': [42],
                'total': 1,
              },
            ),
          ),
        ),
      );
      await expectLater(repo.listPosts(), throwsA(isA<RepositoryException>()));
    },
  );

  test('bootstrap exposes server counts and role permissions without loading unseen lists', () async {
    final f = _fixture();
    await f.controller.loadBootstrap();
    expect(f.controller.viewer.canManageAdmins, isTrue);
    expect(f.controller.counts.posts, 2);
    expect(f.controller.counts.pendingApplications, 2);
    expect(f.repo.postCalls, isEmpty);
    expect(f.repo.userCalls, isEmpty);
    expect(f.controller.loading, isFalse);
  });

  test('pagination keeps filters, replaces duplicate IDs, and stops a repeated cursor', () async {
    final f = _fixture();
    f.repo.onPosts = (cursor) async => cursor == null
        ? AdminPage(items: [_post('p1')], total: 2, nextCursor: 'page-two')
        : AdminPage(
            items: [_post('p1'), _post('p2')],
            total: 2,
            nextCursor: 'page-two',
          );
    await f.controller.loadPosts(
      q: '  日常  ',
      category: 'daily',
      kind: 'post',
      official: true,
    );
    await f.controller.loadMorePosts();
    await f.controller.loadMorePosts();
    expect(f.controller.posts.items.map((post) => post.id), ['p1', 'p2']);
    expect(f.repo.postCalls, [
      ('日常', 'daily', 'post', true, null),
      ('日常', 'daily', 'post', true, 'page-two'),
    ]);
    expect(f.controller.posts.hasMore, isFalse);
  });

  test('new search result wins over an older pending filter request', () async {
    final f = _fixture();
    final old = Completer<AdminPage<CommunityPost>>();
    f.repo.onPosts = (_) => old.future;
    final pending = f.controller.loadPosts(q: 'old');
    f.repo.onPosts = (_) async => AdminPage(items: [_post('new')], total: 1);
    await f.controller.loadPosts(q: 'new');
    old.complete(AdminPage(items: [_post('old')], total: 1));
    await pending;
    expect(f.controller.posts.items.single.id, 'new');
    expect(f.controller.posts.loading, isFalse);
  });

  test(
    'failed refresh retains successful data and retries the active filter',
    () async {
      final f = _fixture();
      await f.controller.loadBootstrap();
      await f.controller.loadPosts(q: '自习', category: 'daily');
      f.repo.onPosts = (_) async => throw const RepositoryException('暂时离线');
      await f.controller.refresh();
      expect(f.controller.posts.items.length, 2);
      expect(f.controller.posts.error, '暂时离线');
      expect(f.repo.postCalls.last, ('自习', 'daily', '', null, null));
      expect(f.controller.posts.loading, isFalse);
      f.repo.onPosts = null;
      await f.controller.refresh();
      expect(f.controller.posts.error, isNull);
      expect(f.repo.userCalls, isEmpty);
    },
  );

  test(
    'comments users and audit maintain independent query and pagination state',
    () async {
      final f = _fixture();
      f.repo.onComments = (cursor) async => AdminPage(
        items: [_comment(cursor == null ? 'c1' : 'c2')],
        total: 2,
        nextCursor: cursor == null ? 'comments-two' : null,
      );
      f.repo.onUsers = (cursor) async => AdminPage(
        items: [_user(cursor == null ? 'u1' : 'u2')],
        total: 2,
        nextCursor: cursor == null ? 'users-two' : null,
      );
      f.repo.onAudit = (cursor) async => AdminPage(
        items: [_entry(cursor == null ? 'a1' : 'a2')],
        total: 2,
        nextCursor: cursor == null ? 'audit-two' : null,
      );
      await f.controller.loadComments(q: '评论', postId: 'p1');
      await f.controller.loadUsers(q: '用户', status: 'disabled');
      await f.controller.loadAudit(q: '删除');
      await Future.wait([
        f.controller.loadMoreComments(),
        f.controller.loadMoreUsers(),
        f.controller.loadMoreAudit(),
      ]);
      expect(f.repo.commentCalls.last, ('评论', 'p1', 'comments-two'));
      expect(f.repo.userCalls.last, ('用户', 'disabled', 'users-two'));
      expect(f.repo.auditCalls.last, ('删除', 'audit-two'));
      expect(f.controller.comments.items.length, 2);
      expect(f.controller.users.items.length, 2);
      expect(f.controller.audit.items.length, 2);
    },
  );

  test('a second load-more cannot duplicate a pending page request', () async {
    final f = _fixture();
    await f.controller.loadPosts();
    f.controller.posts.nextCursor = 'two';
    final page = Completer<AdminPage<CommunityPost>>();
    f.repo.onPosts = (_) => page.future;
    final loading = f.controller.loadMorePosts();
    await f.controller.loadMorePosts();
    expect(f.repo.postCalls.length, 2);
    page.complete(AdminPage(items: [_post('p3')], total: 3));
    await loading;
    expect(f.controller.posts.items.length, 3);
  });

  test('account switching clears every list, role, detail, status, error, and late read', () async {
    final f = _fixture();
    await f.controller.loadBootstrap();
    await f.controller.loadPosts();
    await f.controller.loadComments();
    await f.controller.loadUsers();
    await f.controller.loadAudit();
    await f.controller.loadStatus();
    await f.controller.loadDetail('p1');
    final pendingPage = Completer<AdminPage<CommunityPost>>();
    f.repo.onPosts = (_) => pendingPage.future;
    final pending = f.controller.loadPosts(q: '旧账号');
    f.auth.use('other');
    expect(f.controller.bootstrap, isNull);
    expect(f.controller.posts.items, isEmpty);
    expect(f.controller.comments.items, isEmpty);
    expect(f.controller.users.items, isEmpty);
    expect(f.controller.audit.items, isEmpty);
    expect(f.controller.status, isNull);
    expect(f.controller.detail('p1'), isNull);
    pendingPage.complete(AdminPage(items: [_post('private')], total: 1));
    await pending;
    expect(f.controller.posts.items, isEmpty);
    expect(f.controller.posts.error, isNull);
  });

  test(
    'renewing a session for the same account invalidates privileged state',
    () async {
      final f = _fixture();
      await f.controller.loadBootstrap();
      await f.controller.loadUsers();
      f.auth.use('official', sessionId: 'two');
      expect(f.controller.bootstrap, isNull);
      expect(f.controller.users.items, isEmpty);
    },
  );

  test(
    'loss of owner role discards owner-only data and its in-flight result',
    () async {
      final f = _fixture();
      await f.controller.loadBootstrap();
      await f.controller.loadUsers();
      await f.controller.loadAudit();
      await f.controller.loadStatus();
      final userPage = Completer<AdminPage<AdminUser>>();
      f.repo.onUsers = (_) => userPage.future;
      final pending = f.controller.loadUsers();
      f.repo.currentViewer = _moderator;
      await f.controller.loadBootstrap();
      userPage.complete(AdminPage(items: [_user('private')], total: 1));
      await pending;
      expect(f.controller.viewer.canManageAdmins, isFalse);
      expect(f.controller.users.items, isEmpty);
      expect(f.controller.audit.items, isEmpty);
      expect(f.controller.status, isNull);
      expect(f.controller.counts.users, isNull);
    },
  );

  test('post deletion refreshes actual counts and related rows, invalidating cached detail', () async {
    final f = _fixture();
    await f.controller.loadBootstrap();
    await f.controller.loadPosts();
    await f.controller.loadComments();
    await f.controller.loadDetail('p1');
    await f.controller.deletePost('p1', reason: '  重复内容  ');
    expect(f.controller.posts.items.single.id, 'p2');
    expect(f.controller.comments.items, isEmpty);
    expect(f.controller.counts.posts, 1);
    expect(f.controller.counts.comments, 0);
    expect(f.controller.detail('p1'), isNull);
    expect(f.repo.writes.single.$4, '重复内容');
    expect(f.controller.saving, isFalse);
  });

  test('failure retains rows and stable operation ID; a successful retry deletes once', () async {
    final f = _fixture();
    await f.controller.loadBootstrap();
    await f.controller.loadComments();
    f.repo.onWrite = () async => throw const RepositoryException('网络断开');
    await expectLater(
      f.controller.deleteComment('c1', reason: '不适当内容'),
      throwsA(isA<RepositoryException>()),
    );
    expect(f.controller.comments.items.length, 2);
    expect(f.controller.error, '网络断开');
    f.repo.onWrite = null;
    await f.controller.deleteComment('c1', reason: '不适当内容');
    expect(f.repo.writes[0].$3, f.repo.writes[1].$3);
    expect(f.controller.comments.items.single.id, 'c2');
    expect(f.controller.counts.comments, 1);
  });

  test('global mutation lock rejects double submission and late account writes do not leak', () async {
    final f = _fixture();
    await f.controller.loadBootstrap();
    final completion = Completer<void>();
    f.repo.onWrite = () => completion.future;
    final first = f.controller.deletePost('p1', reason: '重复');
    final firstResult = expectLater(first, throwsA(isA<RepositoryException>()));
    await expectLater(
      f.controller.setUserDisabled('u1', disabled: true, reason: '违规'),
      throwsA(isA<RepositoryException>()),
    );
    expect(f.repo.writes.length, 1);
    f.auth.use('other');
    completion.complete();
    await firstResult;
    expect(f.controller.bootstrap, isNull);
    expect(f.controller.error, isNull);
    expect(f.controller.saving, isFalse);
  });

  test(
    'disable and restore report the server state and refresh audit records',
    () async {
      final f = _fixture();
      await f.controller.loadBootstrap();
      await f.controller.loadUsers(q: 'u1');
      await f.controller.loadAudit();
      await f.controller.setUserDisabled('u1', disabled: true, reason: '违规处理');
      expect(f.controller.users.items.single.disabled, isTrue);
      await f.controller.setUserDisabled('u1', disabled: false, reason: '申诉通过');
      expect(f.controller.users.items.single.disabled, isFalse);
      expect(f.repo.writes.map((write) => write.$5), [true, false]);
      expect(f.repo.writes.first.$3, isNot(f.repo.writes.last.$3));
      expect(f.repo.userCalls.last.$1, 'u1');
      expect(f.repo.auditCalls.length, 3);
    },
  );

  test('empty reasons and signed-out writes never call the server', () async {
    final f = _fixture();
    expect(
      () => f.controller.deletePost('p1', reason: '  '),
      throwsA(isA<RepositoryException>()),
    );
    f.auth.use(null);
    await expectLater(
      f.controller.deleteComment('c1', reason: '重复'),
      throwsA(isA<RepositoryException>()),
    );
    expect(f.repo.writes, isEmpty);
  });

  test(
    'a pre-write read cannot reinsert a deleted post after reconciliation',
    () async {
      final f = _fixture();
      await f.controller.loadBootstrap();
      await f.controller.loadPosts();
      final stale = Completer<AdminPage<CommunityPost>>();
      f.repo.onPosts = (_) => stale.future;
      final pending = f.controller.loadPosts();
      f.repo.onPosts = null;
      await f.controller.deletePost('p1', reason: '重复');
      stale.complete(AdminPage(items: [_post('p1'), _post('p2')], total: 2));
      await pending;
      expect(f.controller.posts.items.single.id, 'p2');
      expect(f.controller.counts.posts, 1);
    },
  );

  test(
    'detail failure is scoped to its ID and cannot replace another post',
    () async {
      final f = _fixture();
      await f.controller.loadDetail('p1');
      f.community.onDetail = (_) async =>
          CommunityDetail(post: _post('wrong'), comments: []);
      await f.controller.loadDetail('p2');
      expect(f.controller.detail('p1')!.post.id, 'p1');
      expect(f.controller.detail('p2'), isNull);
      expect(f.controller.detailError('p2'), isNotNull);
      expect(f.controller.isDetailLoading('p2'), isFalse);
    },
  );

  test('configured service has unknown health and failure retains the last observed status', () async {
    final f = _fixture();
    await f.controller.loadStatus();
    expect(f.controller.status!.components.single.status, 'configured');
    expect(f.controller.status!.components.single.healthy, isNull);
    f.repo.onStatus = () async => throw const RepositoryException('网络断开');
    await f.controller.loadStatus();
    expect(f.controller.status!.components.single.id, 'mail');
    expect(f.controller.statusError, '网络断开');
  });

  test('disposed controllers ignore every pending response', () async {
    final auth = _Auth()..use('official');
    final repo = _Repo(auth: auth);
    final pending = Completer<AdminBootstrap>();
    repo.onBootstrap = () => pending.future;
    final controller = AdminController(auth: auth, repository: repo);
    final load = controller.loadBootstrap();
    controller.dispose();
    pending.complete(
      const AdminBootstrap(viewer: _owner, counts: AdminCounts()),
    );
    await load;
    expect(controller.bootstrap, isNull);
    auth.dispose();
  });

  test('repository uses encoded filters and the account transport for native and Cookie writes', () async {
    final dio = Dio();
    final auth = _Auth(client: dio)..use('official');
    final repo = AdminRepository(auth: auth);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    final requests = <RequestOptions>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: options.method == 'GET'
                  ? {'posts': [], 'total': 0, 'nextCursor': null}
                  : {'deleted': true},
            ),
          );
        },
      ),
    );
    await repo.listPosts(q: '  一 & 二  ', category: 'feedback', official: true);
    expect(requests.first.uri.queryParameters['q'], '一 & 二');
    expect(requests.first.uri.queryParameters['official'], 'yes');
    expect(
      requests.first.headers['Authorization'],
      'Bearer token-official-one',
    );
    auth.use('official', cookie: true, sessionId: 'web');
    await repo.deletePost('a/b', requestId: 'stable-id', reason: '重复');
    expect(requests.last.path, '/api/v1/admin/posts/a%2Fb');
    expect(requests.last.headers.containsKey('Authorization'), isFalse);
    expect(requests.last.headers['X-CSRF-Token'], 'csrf-official-web');
    expect(requests.last.headers['Idempotency-Key'], 'stable-id');
    expect(requests.last.data, {'requestId': 'stable-id', 'reason': '重复'});
  });

  test(
    'repository rejects a late authenticated response after account change',
    () async {
      final dio = Dio();
      final auth = _Auth(client: dio)..use('official');
      final repo = AdminRepository(auth: auth);
      addTearDown(() {
        auth.dispose();
        dio.close();
      });
      RequestInterceptorHandler? delayed;
      RequestOptions? request;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            request = options;
            delayed = handler;
          },
        ),
      );
      final read = repo.listUsers();
      final rejected = expectLater(read, throwsA(isA<RepositoryException>()));
      while (delayed == null) {
        await Future<void>.delayed(Duration.zero);
      }
      auth.use('other');
      delayed!.resolve(
        Response<dynamic>(
          requestOptions: request!,
          statusCode: 200,
          data: {'users': [], 'total': 0},
        ),
      );
      await rejected;
      expect(auth.session!.user.id, 'other');
    },
  );
}
