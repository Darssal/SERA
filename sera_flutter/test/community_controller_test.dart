import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/application/community_controller.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/data/community_repository.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
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
    : super(apiBaseUrl: 'https://community.test', storage: _Storage());

  void use(String? id, {String sessionId = 'session-1', bool cookie = false}) {
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

CommunityPost _post(
  String id, {
  bool official = false,
  String category = 'daily',
  bool liked = false,
  bool joined = false,
  int likes = 0,
  int comments = 0,
  int participants = 0,
  List<CommunityMedia> media = const [],
}) => CommunityPost(
  id: id,
  authorId: 'a',
  authorName: 'A',
  title: '标题 $id',
  content: '内容 $id',
  createdAt: DateTime.utc(2026, 11, 9),
  isOfficial: official,
  category: category,
  liked: liked,
  joined: joined,
  likeCount: likes,
  commentCount: comments,
  participantCount: participants,
  canDelete: true,
  media: media,
);
CommunityMedia _media(String id) => CommunityMedia(
  id: id,
  url: '/api/v1/community/media/$id',
  width: 40,
  height: 20,
  mimeType: 'image/png',
  bytes: 120,
);
CommunityComment _comment(String id) => CommunityComment(
  id: id,
  postId: 'p',
  authorId: 'a',
  authorName: 'A',
  content: '评论 $id',
  createdAt: DateTime.utc(2026, 11, 9, 0, int.parse(id.substring(1))),
  canDelete: true,
);
const _viewer = CommunityViewer(signedIn: true, canPublishOfficial: true);
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
CommunityAdminApplication _application({String status = 'pending'}) =>
    CommunityAdminApplication(
      id: 'application-1',
      userId: 'a',
      username: 'A',
      reason: '愿意协助维护社区',
      status: status,
      createdAt: DateTime.utc(2026, 11, 9),
    );

class _Repo extends CommunityRepository {
  _Repo(_Auth auth) : super(auth: auth);
  Future<CommunityFeed> Function(String filter, String? cursor)? onList;
  Future<CommunityDetail> Function(String id, String? cursor)? onDetail;
  Future<CommunityPost> Function(String id, bool value)? onLike, onJoin;
  Future<CommunityPost> Function(String requestId)? onCreate;
  Future<CommunityCommentResult> Function(String requestId)? onComment;
  final createIds = <String>[];
  final createCategories = <String>[];
  final createMediaIds = <List<String>>[];
  final uploadIds = <String>[];
  Future<CommunityMedia> Function(String id, Uint8List bytes)? onUpload;
  final commentIds = <String>[];
  final deleted = <String>[];
  int likeCalls = 0;
  Future<CommunityManagement> Function()? onManagement;
  Future<void> Function(String id)? onApply;
  Future<void> Function(
    String action,
    String target,
    CommunityPermissions? permissions,
  )?
  onManage;
  final applicationIds = <String>[];
  final managementCalls = <(String, String, CommunityPermissions?)>[];

  @override
  Future<CommunityFeed> list({String filter = 'all', String? cursor}) =>
      onList?.call(filter, cursor) ??
      Future.value(CommunityFeed(posts: [_post('p')], viewer: _viewer));
  @override
  Future<CommunityDetail> getDetail(String id, {String? commentCursor}) =>
      onDetail?.call(id, commentCursor) ??
      Future.value(
        CommunityDetail(post: _post(id), comments: [], viewer: _viewer),
      );
  @override
  Future<CommunityPost> setLike(String id, bool liked) {
    likeCalls++;
    return onLike?.call(id, liked) ??
        Future.value(_post(id, liked: liked, likes: 37));
  }

  @override
  Future<CommunityPost> setJoin(String id, bool joined) =>
      onJoin?.call(id, joined) ??
      Future.value(_post(id, joined: joined, participants: 42));
  @override
  Future<CommunityPost> createPost({
    required String requestId,
    required String title,
    required String content,
    String kind = 'post',
    String category = 'daily',
    bool official = false,
    DateTime? startsAt,
    String place = '',
    List<String> mediaIds = const [],
  }) {
    createIds.add(requestId);
    createCategories.add(category);
    createMediaIds.add(List.of(mediaIds));
    return onCreate?.call(requestId) ?? Future.value(_post('created'));
  }

  @override
  Future<CommunityMedia> uploadImage(
    Uint8List bytes, {
    required String mimeType,
    required String requestId,
  }) {
    uploadIds.add(requestId);
    return onUpload?.call(requestId, bytes) ?? Future.value(_media(requestId));
  }

  @override
  Future<CommunityCommentResult> comment(
    String id,
    String content, {
    required String requestId,
  }) {
    commentIds.add(requestId);
    return onComment?.call(requestId) ??
        Future.value(
          CommunityCommentResult(
            comment: _comment('c3'),
            post: _post(id, comments: 17),
          ),
        );
  }

  @override
  Future<void> deletePost(String id) async => deleted.add('post:$id');
  @override
  Future<void> deleteComment(String id) async => deleted.add('comment:$id');
  @override
  Future<CommunityManagement> getManagement() =>
      onManagement?.call() ?? Future.value(CommunityManagement(viewer: _owner));
  @override
  Future<void> applyForAdmin(String reason, {required String requestId}) async {
    applicationIds.add(requestId);
    await onApply?.call(requestId);
  }

  Future<void> _manage(
    String action,
    String target,
    CommunityPermissions? permissions,
  ) async {
    managementCalls.add((action, target, permissions));
    await onManage?.call(action, target, permissions);
  }

  @override
  Future<void> addAdmin(String identifier, CommunityPermissions permissions) =>
      _manage('add', identifier, permissions);
  @override
  Future<void> updateAdmin(String userId, CommunityPermissions permissions) =>
      _manage('update', userId, permissions);
  @override
  Future<void> removeAdmin(String userId) => _manage('remove', userId, null);
  @override
  Future<void> reviewApplication(
    String id, {
    required String status,
    CommunityPermissions? permissions,
  }) => _manage(status, id, permissions);
}

({CommunityController controller, _Repo repo, _Auth auth}) _fixture() {
  final auth = _Auth()..use('a');
  final repo = _Repo(auth);
  final controller = CommunityController(repository: repo);
  addTearDown(() {
    controller.dispose();
    repo.dispose();
    auth.dispose();
  });
  return (controller: controller, repo: repo, auth: auth);
}

void main() {
  test('owner changes each administrator permissions without granting unrelated powers', () async {
    final f = _fixture();
    var members = <CommunityAdmin>[];
    var application = _application();
    f.repo.onManagement = () async => CommunityManagement(
      viewer: _owner,
      admins: members,
      applications: [application],
    );
    f.repo.onManage = (action, target, permissions) async {
      switch (action) {
        case 'add':
          members = [
            CommunityAdmin(
              userId: 'member',
              username: 'Member',
              permissions: permissions!,
            ),
          ];
        case 'update':
          members = [
            CommunityAdmin(
              userId: target,
              username: 'Member',
              permissions: permissions!,
            ),
          ];
        case 'remove':
          members = [];
        case 'approved':
          application = _application(status: 'approved');
          members = [
            CommunityAdmin(
              userId: application.userId,
              username: application.username,
              permissions: permissions!,
            ),
          ];
        case 'rejected':
          application = _application(status: 'rejected');
      }
    };
    await f.controller.loadManagement();
    const publishActivity = CommunityPermissions(publishActivity: true);
    await f.controller.addAdmin('member@example.test', publishActivity);
    expect(f.controller.management!.admins.single.permissions.toJson(), {
      'publishOfficial': false,
      'publishActivity': true,
      'moderatePosts': false,
      'moderateComments': false,
    });
    final moderateComments = publishActivity.copyWith(
      publishActivity: false,
      moderateComments: true,
    );
    await f.controller.updateAdmin('member', moderateComments);
    expect(
      f.controller.management!.admins.single.permissions.moderateComments,
      isTrue,
    );
    expect(
      f.controller.management!.admins.single.permissions.publishActivity,
      isFalse,
    );
    await f.controller.removeAdmin('member');
    expect(f.controller.management!.admins, isEmpty);
    await f.controller.reviewApplication(
      'application-1',
      status: 'approved',
      permissions: moderateComments,
    );
    expect(f.controller.management!.applications.single.status, 'approved');
    expect(
      f.controller.management!.admins.single.permissions.publishOfficial,
      isFalse,
    );
    expect(f.repo.managementCalls.map((call) => (call.$1, call.$2)), [
      ('add', 'member@example.test'),
      ('update', 'member'),
      ('remove', 'member'),
      ('approved', 'application-1'),
    ]);
    f.repo.onManage = (_, _, _) async =>
        throw const RepositoryException('权限保存失败');
    await expectLater(
      f.controller.updateAdmin('a', const CommunityPermissions()),
      throwsA(isA<RepositoryException>()),
    );
    expect(
      f.controller.management!.admins.single.permissions.moderateComments,
      isTrue,
    );
    expect(f.controller.managementError, '权限保存失败');
  });

  test('ordinary administrator cannot add peers, change permissions or review applications', () async {
    final f = _fixture();
    f.repo.onManagement = () async => CommunityManagement(
      viewer: const CommunityViewer(
        signedIn: true,
        isAdmin: true,
        permissions: CommunityPermissions(
          publishOfficial: true,
          publishActivity: true,
          moderatePosts: true,
          moderateComments: true,
        ),
      ),
    );
    await f.controller.loadManagement();
    for (final operation in <Future<void> Function()>[
      () => f.controller.addAdmin('peer', const CommunityPermissions()),
      () => f.controller.updateAdmin('a', const CommunityPermissions()),
      () => f.controller.removeAdmin('a'),
      () => f.controller.reviewApplication('application-1', status: 'approved'),
    ]) {
      await expectLater(operation(), throwsA(isA<RepositoryException>()));
    }
    expect(f.repo.managementCalls, isEmpty);
    expect(f.controller.viewer.canManageAdmins, isFalse);
  });

  test('application retry preserves request ID and only shows server acknowledgement', () async {
    final f = _fixture();
    var failed = true;
    f.repo.onApply = (_) async {
      if (failed) throw const RepositoryException('申请未送达');
    };
    f.repo.onManagement = () async => CommunityManagement(
      viewer: const CommunityViewer(signedIn: true),
      myApplication: failed ? null : _application(),
    );
    await f.controller.loadManagement();
    await expectLater(
      f.controller.applyForAdmin('愿意协助维护社区'),
      throwsA(isA<RepositoryException>()),
    );
    expect(f.controller.management!.myApplication, isNull);
    failed = false;
    await f.controller.applyForAdmin('愿意协助维护社区');
    expect(f.repo.applicationIds, hasLength(2));
    expect(f.repo.applicationIds[0], f.repo.applicationIds[1]);
    expect(f.controller.management!.myApplication!.status, 'pending');
    expect(f.controller.managementError, isNull);
    expect(
      f.controller.viewer.isAdmin,
      isFalse,
      reason: 'applying is not approval',
    );
  });

  test('account switch clears private management and ignores late privileged response', () async {
    final f = _fixture();
    await f.controller.loadManagement();
    final pendingManagement = Completer<CommunityManagement>();
    f.repo.onManagement = () => pendingManagement.future;
    final pending = f.controller.loadManagement();
    f.auth.use('b');
    expect(f.controller.management, isNull);
    expect(f.controller.viewer.canManageAdmins, isFalse);
    pendingManagement.complete(
      CommunityManagement(viewer: _owner, applications: [_application()]),
    );
    await pending;
    expect(f.controller.management, isNull);
    expect(f.controller.managementLoading, isFalse);
    expect(f.controller.managementError, isNull);
  });

  test('repository sends all four permissions and parses badges and private management response', () async {
    final client = Dio();
    final auth = _Auth(client: client)..use('owner');
    final repo = CommunityRepository(auth: auth);
    addTearDown(() {
      repo.dispose();
      auth.dispose();
      client.close();
    });
    final requests = <RequestOptions>[];
    client.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: options.method == 'GET'
                  ? {
                      'viewer': {
                        'signedIn': true,
                        'isOfficial': true,
                        'isAdmin': false,
                        'canManageAdmins': true,
                        'permissions': _owner.permissions.toJson(),
                      },
                      'admins': [
                        {
                          'userId': 'member',
                          'username': 'Member',
                          'permissions': const CommunityPermissions(
                            moderateComments: true,
                          ).toJson(),
                        },
                      ],
                      'applications': [],
                      'myApplication': null,
                    }
                  : {'updated': true},
            ),
          );
        },
      ),
    );
    const selected = CommunityPermissions(
      publishActivity: true,
      moderatePosts: true,
    );
    await repo.addAdmin('member@example.test', selected);
    await repo.updateAdmin(
      'member',
      const CommunityPermissions(moderateComments: true),
    );
    await repo.reviewApplication(
      'application-1',
      status: 'approved',
      permissions: selected,
    );
    final management = await repo.getManagement();
    expect(requests[0].data, {
      'identifier': 'member@example.test',
      'permissions': selected.toJson(),
    });
    expect(requests[1].data['permissions'], {
      'publishOfficial': false,
      'publishActivity': false,
      'moderatePosts': false,
      'moderateComments': true,
    });
    expect(requests[2].data, {
      'status': 'approved',
      'permissions': selected.toJson(),
    });
    expect(management.viewer.canManageAdmins, isTrue);
    expect(management.viewer.canPublishOfficial, isTrue);
    expect(management.admins.single.permissions.moderateComments, isTrue);
    expect(management.admins.single.permissions.publishActivity, isFalse);
    final post = CommunityPost.fromJson({
      'id': 'p',
      'authorName': 'Member',
      'title': '',
      'content': '个人分享',
      'createdAt': '2026-11-09T09:00:00Z',
      'isAdmin': true,
      'isOfficial': false,
    });
    final comment = CommunityComment.fromJson({
      'id': 'c',
      'postId': 'p',
      'authorName': 'Member',
      'content': '评论',
      'createdAt': '2026-11-09T09:00:00Z',
      'isAdmin': true,
      'isOfficial': false,
    });
    expect(post.isAdmin && comment.isAdmin, isTrue);
    expect(post.isOfficial || comment.isOfficial, isFalse);
    expect(post.category, 'daily');
    expect(post.media, isEmpty);
    expect(post.authorIsOfficial || comment.authorIsOfficial, isFalse);
  });

  test('image upload retry and ordered attachments keep successful images without duplicating publication', () async {
    final f = _fixture();
    final image = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);
    final first = await f.controller.uploadImage(
      image,
      mimeType: 'image/png',
      requestId: 'first',
    );
    var failed = true;
    f.repo.onUpload = (id, _) async {
      if (failed) throw const RepositoryException('图片上传中断');
      return _media('second');
    };
    await expectLater(
      f.controller.uploadImage(image, mimeType: 'image/png'),
      throwsA(isA<RepositoryException>()),
    );
    final failedId = f.repo.uploadIds.last;
    failed = false;
    final second = await f.controller.uploadImage(image, mimeType: 'image/png');
    expect(f.repo.uploadIds.last, failedId);
    expect(first.id, 'first');
    expect(second.id, 'second');
    final selected = [first.id, second.id];
    var publishFailed = true;
    f.repo.onCreate = (_) async {
      if (publishFailed) throw const RepositoryException('发布响应丢失');
      return _post('published', media: [first, second]);
    };
    await expectLater(
      f.controller.createPost(title: '', content: '两张图片', mediaIds: selected),
      throwsA(isA<RepositoryException>()),
    );
    await expectLater(
      f.controller.createPost(
        title: '',
        content: '两张图片',
        mediaIds: selected.reversed.toList(),
      ),
      throwsA(isA<RepositoryException>()),
    );
    expect(f.repo.createIds[0], isNot(f.repo.createIds[1]));
    publishFailed = false;
    await f.controller.createPost(
      title: '',
      content: '两张图片',
      mediaIds: selected,
    );
    expect(f.repo.createIds[2], f.repo.createIds[0]);
    expect(f.repo.createMediaIds.last, ['first', 'second']);
    expect(f.controller.posts.single.media.map((item) => item.id), [
      'first',
      'second',
    ]);
  });

  test(
    'image upload validates before transport and rejects old account responses',
    () async {
      final f = _fixture();
      final bytes = Uint8List.fromList([1, 2, 3]);
      final scope = f.controller.stableSessionScope;
      expect(scope, contains('https://community.test'));
      expect(scope, isNot(contains('token-')));
      await expectLater(
        f.controller.uploadImage(
          Uint8List(communityImageMaxBytes + 1),
          mimeType: 'image/png',
        ),
        throwsA(isA<RepositoryException>()),
      );
      await expectLater(
        f.controller.uploadImage(bytes, mimeType: 'image/gif'),
        throwsA(isA<RepositoryException>()),
      );
      expect(f.repo.uploadIds, isEmpty);
      final upload = Completer<CommunityMedia>();
      f.repo.onUpload = (_, _) => upload.future;
      final pending = f.controller.uploadImage(
        bytes,
        mimeType: 'image/png',
        requestId: 'late-image',
      );
      final rejected = expectLater(
        pending,
        throwsA(isA<RepositoryException>()),
      );
      f.auth.use('b');
      expect(f.controller.stableSessionScope, isNot(scope));
      upload.complete(_media('late-image'));
      await rejected;
      expect(f.controller.saving, isFalse);
      expect(f.controller.posts, isEmpty);
      f.auth.use(null);
      expect(f.controller.stableSessionScope, isNull);
      await expectLater(
        f.controller.uploadImage(bytes, mimeType: 'image/png'),
        throwsA(isA<RepositoryException>()),
      );
      expect(f.repo.uploadIds, ['late-image']);
    },
  );

  test('binary upload retains native and cookie bindings and attachment errors remain recoverable', () async {
    final client = Dio();
    final auth = _Auth(client: client)..use('a');
    final repo = CommunityRepository(auth: auth);
    addTearDown(() {
      repo.dispose();
      auth.dispose();
      client.close();
    });
    final requests = <RequestOptions>[];
    final rawBodies = <List<int>>[];
    final json = {
      'id': 'media-1',
      'url': '/api/v1/community/media/media-1',
      'width': 40,
      'height': 20,
      'mimeType': 'image/png',
      'bytes': 120,
    };
    client.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          requests.add(options);
          if (options.path.endsWith('/media')) {
            rawBodies.add(
              (await (options.data as Stream<Uint8List>).toList())
                  .expand((chunk) => chunk)
                  .toList(),
            );
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 201,
                data: {'media': json},
              ),
            );
          } else {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
                response: Response<dynamic>(
                  requestOptions: options,
                  statusCode: 410,
                  data: {
                    'error': '图片已过期',
                    'code': 'community_media_expired',
                    'details': {
                      'mediaIds': ['media-1'],
                    },
                  },
                ),
              ),
            );
          }
        },
      ),
    );
    final bytes = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);
    final uploaded = await repo.uploadImage(
      bytes,
      mimeType: 'image/png',
      requestId: 'upload-native',
    );
    expect(rawBodies.single, bytes);
    expect(requests.single.contentType, 'image/png');
    expect(requests.single.headers['Idempotency-Key'], 'upload-native');
    expect(
      requests.single.headers['Authorization'],
      'Bearer token-a-session-1',
    );
    expect(uploaded.width, 40);
    expect(
      repo.resolveMediaUrl(uploaded.url),
      'https://community.test/api/v1/community/media/media-1',
    );
    auth.use('a', sessionId: 'web', cookie: true);
    await repo.uploadImage(
      bytes,
      mimeType: 'image/png',
      requestId: 'upload-web',
    );
    expect(requests[1].headers['X-CSRF-Token'], 'csrf-a-web');
    expect(requests[1].headers.containsKey('Authorization'), isFalse);
    await expectLater(
      repo.createPost(
        requestId: 'publish-1',
        title: '',
        content: '正文',
        mediaIds: ['media-1'],
      ),
      throwsA(
        isA<RepositoryException>()
            .having(
              (error) => error.details['code'],
              'code',
              'community_media_expired',
            )
            .having(
              (error) => error.details['mediaIds'],
              'only expired images',
              ['media-1'],
            ),
      ),
    );
    expect(requests.last.data['mediaIds'], ['media-1']);
    expect(auth.signedIn, isTrue);
    final decoded = CommunityPost.fromJson({
      'id': 'p',
      'authorName': 'A',
      'title': '',
      'content': '正文',
      'createdAt': '2026-11-09T09:00:00Z',
      'media': [json],
    });
    expect(decoded.media.single.url, uploaded.url);
  });

  test('feedback retries keep their ID while a category change is a new publication', () async {
    final f = _fixture();
    f.repo.onList = (filter, _) async {
      expect(filter, 'feedback');
      return CommunityFeed(posts: [_post('existing', category: 'feedback')]);
    };
    await f.controller.load(filter: 'feedback');
    var failed = true;
    f.repo.onCreate = (_) async {
      if (failed) throw const RepositoryException('响应丢失');
      return _post(
        'created-${f.repo.createCategories.last}',
        category: f.repo.createCategories.last,
      );
    };
    Future<CommunityPost> publish(String category) => f.controller.createPost(
      title: '',
      content: '相同内容，明确选择分类',
      category: category,
    );
    await expectLater(publish('feedback'), throwsA(isA<RepositoryException>()));
    await expectLater(publish('daily'), throwsA(isA<RepositoryException>()));
    expect(f.repo.createIds[0], isNot(f.repo.createIds[1]));
    failed = false;
    await publish('feedback');
    expect(f.repo.createIds[2], f.repo.createIds[0]);
    expect(f.repo.createCategories, ['feedback', 'daily', 'feedback']);
    expect(f.controller.posts.map((post) => post.id), [
      'created-feedback',
      'existing',
    ]);
    await publish('daily');
    expect(f.repo.createIds[3], f.repo.createIds[1]);
    expect(f.controller.posts.map((post) => post.id), [
      'created-feedback',
      'existing',
    ]);
    f.repo.onLike = (id, liked) async => _post(
      id,
      category: 'feedback',
      official: true,
      liked: liked,
      likes: 23,
    );
    await f.controller.setLike('existing', true);
    expect(f.controller.posts.last.likeCount, 23);
    expect(f.controller.posts.last.isOfficial, isTrue);
  });

  test('preserving refresh reloads all browsed pages atomically using current server records', () async {
    final f = _fixture();
    var refreshing = false;
    var failTail = false;
    final cursors = <String?>[];
    f.repo.onList = (filter, cursor) async {
      expect(filter, 'feedback');
      cursors.add(cursor);
      if (cursor == null) {
        return CommunityFeed(
          posts: refreshing
              ? [
                  _post('new', category: 'feedback'),
                  _post('new-2', category: 'feedback'),
                  _post('p1', category: 'feedback', likes: 34),
                ]
              : [
                  _post('p1', category: 'feedback'),
                  _post('removed', category: 'feedback'),
                ],
          nextCursor: 'tail',
          viewer: _viewer,
        );
      }
      if (failTail) throw const RepositoryException('后续内容未读取');
      return CommunityFeed(
        posts: [_post('p3', category: 'feedback')],
        viewer: _viewer,
      );
    };
    await f.controller.load(filter: 'feedback');
    await f.controller.loadMore();
    expect(f.controller.nextCursor, isNull);
    refreshing = failTail = true;
    await f.controller.refresh(preserveLoaded: true);
    expect(f.controller.posts.map((post) => post.id), ['p1', 'removed', 'p3']);
    expect(f.controller.posts.first.likeCount, 0);
    expect(f.controller.nextCursor, isNull);
    expect(f.controller.error, '后续内容未读取');
    failTail = false;
    await f.controller.refresh(preserveLoaded: true);
    expect(f.controller.posts.map((post) => post.id), [
      'new',
      'new-2',
      'p1',
      'p3',
    ]);
    expect(f.controller.posts[2].likeCount, 34);
    expect(f.controller.nextCursor, isNull);
    expect(f.controller.error, isNull);
    expect(cursors, [null, 'tail', null, 'tail', null, 'tail']);
    await f.controller.refresh();
    expect(f.controller.posts.map((post) => post.id), ['new', 'new-2', 'p1']);
    expect(f.controller.nextCursor, 'tail');
  });

  test(
    'preserving refresh discards a late tail after account or filter changes',
    () async {
      final f = _fixture();
      for (final switchAccount in [false, true]) {
        final tail = Completer<CommunityFeed>();
        f.repo.onList = (_, _) async => CommunityFeed(posts: [_post('old')]);
        await f.controller.load(filter: 'all');
        var tailStarted = false;
        f.repo.onList = (filter, cursor) {
          if (filter == 'feedback') {
            return Future.value(
              CommunityFeed(posts: [_post('feedback', category: 'feedback')]),
            );
          }
          if (cursor != null) {
            tailStarted = true;
            return tail.future;
          }
          return Future.value(
            CommunityFeed(posts: [_post('head')], nextCursor: 'tail'),
          );
        };
        final pending = f.controller.refresh(preserveLoaded: true);
        while (!tailStarted) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(f.controller.posts.single.id, 'old');
        if (switchAccount) f.auth.use('b');
        await f.controller.load(filter: 'feedback');
        tail.complete(
          CommunityFeed(posts: [_post('late', liked: true)], viewer: _owner),
        );
        await pending;
        expect(f.controller.filter, 'feedback');
        expect(f.controller.posts.single.id, 'feedback');
        expect(f.controller.viewer.canManageAdmins, isFalse);
        expect(f.controller.loading, isFalse);
      }
    },
  );

  test('repository sends category and decodes author identity independently of official content', () async {
    final client = Dio();
    final auth = _Auth(client: client)..use('a');
    final repo = CommunityRepository(auth: auth);
    addTearDown(() {
      repo.dispose();
      auth.dispose();
      client.close();
    });
    final requests = <RequestOptions>[];
    client.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          final post = {
            'id': 'p',
            'authorName': 'Member',
            'title': '',
            'content': '反馈',
            'createdAt': '2026-11-09T09:00:00Z',
            'category': 'feedback',
            'isOfficial': true,
            'isAdmin': true,
            'authorIsOfficial': false,
          };
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: options.method == 'GET'
                  ? {
                      'posts': [post],
                      'nextCursor': null,
                      'viewer': {},
                    }
                  : {'post': post},
            ),
          );
        },
      ),
    );
    final post = await repo.createPost(
      requestId: 'feedback-1',
      title: '',
      content: '反馈',
      category: 'feedback',
      official: true,
    );
    expect(requests.single.data['category'], 'feedback');
    expect(requests.single.data.containsKey('authorIsOfficial'), isFalse);
    expect(post.category, 'feedback');
    expect(post.isOfficial, isTrue);
    expect(post.authorIsOfficial, isFalse);
    expect(post.authorName, 'Member');
    final feed = await repo.list(filter: 'feedback');
    expect(Uri.parse(requests.last.path).queryParameters['filter'], 'feedback');
    expect(feed.posts.single.category, 'feedback');
    final comment = CommunityComment.fromJson({
      'id': 'c',
      'postId': 'p',
      'authorName': 'SERA',
      'content': '回复',
      'createdAt': '2026-11-09T09:00:00Z',
      'authorIsOfficial': true,
    });
    expect(comment.authorIsOfficial, isTrue);
    expect(comment.isOfficial, isFalse);
  });

  test(
    'feed pagination deduplicates IDs and preserves failed page for retry',
    () async {
      final f = _fixture();
      var failPage = true;
      final cursors = <String?>[];
      f.repo.onList = (filter, cursor) async {
        cursors.add(cursor);
        if (cursor == null) {
          return CommunityFeed(
            posts: [_post('p1'), _post('p2')],
            nextCursor: 'page-2',
            viewer: _viewer,
          );
        }
        if (failPage) throw const RepositoryException('网络中断');
        return CommunityFeed(
          posts: [_post('p2', likes: 9), _post('p3')],
          viewer: _viewer,
        );
      };
      await f.controller.load();
      await f.controller.loadMore();
      expect(f.controller.posts.map((p) => p.id), ['p1', 'p2']);
      expect(f.controller.nextCursor, 'page-2');
      expect(f.controller.error, '网络中断');
      failPage = false;
      await f.controller.loadMore();
      expect(f.controller.posts.map((p) => p.id), ['p1', 'p2', 'p3']);
      expect(f.controller.posts[1].likeCount, 9);
      expect(f.controller.nextCursor, isNull);
      expect(cursors, [null, 'page-2', 'page-2']);
      expect(f.controller.error, isNull);
    },
  );

  test(
    'late all-feed response cannot replace a newly selected official feed',
    () async {
      final f = _fixture();
      final old = Completer<CommunityFeed>();
      f.repo.onList = (filter, _) => filter == 'all'
          ? old.future
          : Future.value(
              CommunityFeed(
                posts: [_post('official', official: true)],
                viewer: _viewer,
              ),
            );
      final pending = f.controller.load();
      await f.controller.load(filter: 'official');
      old.complete(CommunityFeed(posts: [_post('late')]));
      await pending;
      expect(f.controller.filter, 'official');
      expect(f.controller.posts.single.id, 'official');
      expect(f.controller.loading, isFalse);
    },
  );

  test(
    'account switch clears viewer caches and ignores late detail and mutation',
    () async {
      final f = _fixture();
      await f.controller.load();
      await f.controller.loadDetail('p');
      expect(f.controller.viewer.canPublishOfficial, isTrue);
      final oldDetail = Completer<CommunityDetail>();
      final oldLike = Completer<CommunityPost>();
      f.repo.onDetail = (_, _) => oldDetail.future;
      f.repo.onLike = (_, _) => oldLike.future;
      final detailRequest = f.controller.loadDetail('p');
      final likeRequest = f.controller.setLike('p', true);
      final ignored = expectLater(
        likeRequest,
        throwsA(isA<RepositoryException>()),
      );
      final before = f.controller.sessionOwner;
      f.auth.use('b');
      expect(f.controller.sessionOwner, isNot(before));
      expect(f.controller.posts, isEmpty);
      expect(f.controller.detail('p'), isNull);
      expect(f.controller.viewer.canPublishOfficial, isFalse);
      expect(f.controller.saving, isFalse);
      oldDetail.complete(
        CommunityDetail(
          post: _post('p', liked: true),
          comments: [_comment('c1')],
          viewer: _viewer,
        ),
      );
      oldLike.complete(_post('p', liked: true, likes: 99));
      await detailRequest;
      await ignored;
      expect(f.controller.posts, isEmpty);
      expect(f.controller.detail('p'), isNull);
      expect(f.controller.error, isNull);
    },
  );

  test('renewed session of the same account also clears old permissions and results', () async {
    final f = _fixture();
    await f.controller.load();
    final delayed = Completer<CommunityFeed>();
    f.repo.onList = (_, _) => delayed.future;
    final pending = f.controller.refresh();
    f.auth.use('a', sessionId: 'session-2');
    delayed.complete(
      CommunityFeed(posts: [_post('old-session')], viewer: _viewer),
    );
    await pending;
    expect(f.controller.posts, isEmpty);
    expect(f.controller.viewer.signedIn, isTrue);
    expect(f.controller.viewer.canPublishOfficial, isFalse);
  });

  test('failed mutations keep server values and retry creation with the same request ID', () async {
    final f = _fixture();
    await f.controller.load();
    f.repo.onLike = (_, _) async => throw const RepositoryException('保存失败');
    await expectLater(
      f.controller.setLike('p', true),
      throwsA(isA<RepositoryException>()),
    );
    expect(f.controller.posts.single.liked, isFalse);
    expect(f.controller.posts.single.likeCount, 0);
    expect(f.controller.saving, isFalse);
    var attempts = 0;
    f.repo.onCreate = (_) async {
      if (++attempts == 1) throw const RepositoryException('响应丢失');
      return _post('canonical-server-id');
    };
    await expectLater(
      f.controller.createPost(title: '', content: '待发布的完整文字'),
      throwsA(isA<RepositoryException>()),
    );
    await f.controller.createPost(title: '', content: '待发布的完整文字');
    expect(f.repo.createIds[0], f.repo.createIds[1]);
    expect(f.repo.createIds[0], matches(RegExp(r'^[a-zA-Z0-9._:-]{1,128}$')));
    expect(f.controller.posts.first.id, 'canonical-server-id');
    await f.controller.createPost(title: '', content: '待发布的完整文字');
    expect(
      f.repo.createIds.last,
      isNot(f.repo.createIds.first),
      reason: 'a new intentional publication gets a new ID after success',
    );
  });

  test('comments page in order and writes use server counts instead of local guesses', () async {
    final f = _fixture();
    await f.controller.load();
    f.repo.onDetail = (id, cursor) async => CommunityDetail(
      post: _post(id, comments: 16),
      comments: cursor == null
          ? [_comment('c1')]
          : [_comment('c1'), _comment('c2')],
      commentsNextCursor: cursor == null ? 'next-comment' : null,
      viewer: _viewer,
    );
    await f.controller.loadDetail('p');
    await f.controller.loadMoreComments('p');
    expect(f.controller.detail('p')!.comments.map((c) => c.id), ['c1', 'c2']);
    var attempts = 0;
    f.repo.onComment = (_) async {
      if (++attempts == 1) throw const RepositoryException('响应丢失');
      return CommunityCommentResult(
        comment: _comment('c3'),
        post: _post('p', comments: 17),
      );
    };
    await expectLater(
      f.controller.comment('p', '保留这条评论'),
      throwsA(isA<RepositoryException>()),
    );
    await f.controller.comment('p', '保留这条评论');
    expect(f.repo.commentIds[0], f.repo.commentIds[1]);
    expect(f.controller.detail('p')!.comments.map((c) => c.id), [
      'c1',
      'c2',
      'c3',
    ]);
    expect(f.controller.posts.single.commentCount, 17);
    await f.controller.setLike('p', true);
    expect(f.controller.detail('p')!.post.likeCount, 37);
    await f.controller.setJoin('p', true);
    expect(f.controller.posts.single.participantCount, 42);
    expect(f.controller.posts.single.joined, isTrue);
    await f.controller.deleteComment('p', 'c3');
    expect(f.repo.deleted, ['comment:c3']);
    expect(f.controller.detail('p')!.post.commentCount, 16);
    expect(
      f.controller.detail('p')!.comments.any((c) => c.id == 'c3'),
      isFalse,
    );
    await f.controller.deletePost('p');
    expect(f.controller.posts, isEmpty);
    expect(f.controller.detail('p'), isNull);
  });

  test('guest actions cannot fabricate local participation and empty server stays unavailable', () async {
    final f = _fixture();
    await f.controller.load();
    f.auth.use(null);
    await expectLater(
      f.controller.setLike('p', true),
      throwsA(isA<RepositoryException>()),
    );
    expect(f.repo.likeCalls, 0);
    expect(f.controller.posts, isEmpty);
    final offline = CommunityController(
      repository: CommunityRepository(apiBaseUrl: ''),
    );
    addTearDown(() {
      offline.repository.dispose();
      offline.dispose();
    });
    await offline.load();
    expect(offline.available, isFalse);
    expect(offline.posts, isEmpty);
    expect(offline.error, contains('连接服务器'));
    expect(offline.loading, isFalse);
  });

  test('a read started before a successful like cannot overwrite its server result', () async {
    final f = _fixture();
    await f.controller.load();
    final oldRead = Completer<CommunityFeed>();
    f.repo.onList = (_, _) => oldRead.future;
    final pending = f.controller.refresh();
    await f.controller.setLike('p', true);
    oldRead.complete(CommunityFeed(posts: [_post('p')], viewer: _viewer));
    await pending;
    expect(f.controller.posts.single.liked, isTrue);
    expect(f.controller.posts.single.likeCount, 37);
    expect(f.controller.loading, isFalse);
  });

  test('repository reuses native Bearer and Web Cookie CSRF bindings and rejects late identity', () async {
    final client = Dio();
    final auth = _Auth(client: client)..use('a');
    final repo = CommunityRepository(auth: auth);
    addTearDown(() {
      repo.dispose();
      auth.dispose();
      client.close();
    });
    final requests = <RequestOptions>[];
    RequestInterceptorHandler? delayed;
    client.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          if (requests.length == 3) {
            delayed = handler;
            return;
          }
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'post': {
                  'id': 'p',
                  'authorName': 'A',
                  'title': '',
                  'content': '服务器内容',
                  'createdAt': '2026-11-09T09:00:00Z',
                  'liked': true,
                  'likeCount': 12,
                },
              },
            ),
          );
        },
      ),
    );
    final native = await repo.setLike('p', true);
    expect(native.likeCount, 12);
    expect(requests[0].headers['Authorization'], 'Bearer token-a-session-1');
    auth.use('a', sessionId: 'web', cookie: true);
    await repo.setLike('p', true);
    expect(requests[1].headers.containsKey('Authorization'), isFalse);
    expect(requests[1].headers['X-CSRF-Token'], 'csrf-a-web');
    final late = repo.setLike('p', true);
    final rejected = expectLater(late, throwsA(isA<RepositoryException>()));
    while (delayed == null) {
      await Future<void>.delayed(Duration.zero);
    }
    auth.use('b');
    delayed!.resolve(
      Response<dynamic>(
        requestOptions: requests.last,
        statusCode: 200,
        data: {'post': {}},
      ),
    );
    await rejected;
    expect(auth.session!.user.id, 'b');
  });
}
