import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:sera_flutter/application/community_controller.dart';
import 'package:sera_flutter/data/community_repository.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/community_models.dart';
import 'package:sera_flutter/platform/community_image_picker.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:sera_flutter/ui/screens/community_screens.dart';

Map<String, dynamic> _post(String id, {bool activity = false}) => {
  'id': id,
  'authorId': activity ? 'official' : 'user',
  'authorName': activity ? '序日' : '学习同伴',
  'authorIsOfficial': activity,
  'isOfficial': activity,
  'kind': activity ? 'activity' : 'post',
  'category': 'daily',
  'title': activity ? '周末一起整理计划' : '今天完成了一个小目标',
  'content': activity ? '一起分享最近的进展。' : '把任务拆小后，更容易开始。',
  'createdAt': '2026-11-08T10:00:00Z',
  if (activity) 'startsAt': '2026-12-12T06:00:00Z',
  'place': activity ? '线上交流' : '',
  'likeCount': 0,
  'commentCount': 0,
  'participantCount': 0,
  'liked': false,
  'joined': false,
  'canDelete': false,
  'media': <Map<String, dynamic>>[],
};

CommunityImageSelection _selection(String id) => CommunityImageSelection(
  id: id,
  bytes: base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  ),
  name: '$id.png',
  mimeType: 'image/png',
);

class _CommunityStore extends CommunityRepository {
  _CommunityStore({
    this.authenticated = true,
    this.official = false,
    this.admin = false,
    this.permissions = const CommunityPermissions(),
  }) : super(apiBaseUrl: 'http://community.test');
  bool authenticated, official, admin;
  CommunityPermissions permissions;
  int owner = 0;
  bool failCreate = false, failComment = false, failList = false;
  Completer<void>? createGate, commentGate, listGate;
  int creates = 0, commentsSent = 0;
  int pageSize = 1;
  final filters = <String>[];
  final listRequests = <(String, String?)>[];
  final createIds = <String>[];
  final commentIds = <String>[];
  final records = <String, Map<String, dynamic>>{
    'post': _post('post'),
    'event': _post('event', activity: true),
  };
  final comments = <CommunityComment>[];
  final admins = <CommunityAdmin>[];
  final applications = <CommunityAdminApplication>[];
  CommunityAdminApplication? myApplication;
  bool failApplication = false;
  final applicationIds = <String>[];
  final managementChanges = <String>[];
  final uploadRequests = <String>[];
  final uploadFailures = <String>{};
  final uploaded = <String, Map<String, dynamic>>{};
  String? recoveredSession;
  final expiredMedia = <String>[];
  @override
  bool get signedIn => authenticated;
  @override
  Object get sessionOwner => owner;
  @override
  String? get stableSessionScope => recoveredSession;
  CommunityViewer get viewer => CommunityViewer(
    signedIn: authenticated,
    isOfficial: official,
    isAdmin: admin,
    canManageAdmins: official,
    canPublishOfficial:
        official || permissions.publishOfficial || permissions.publishActivity,
    permissions: official
        ? const CommunityPermissions(
            publishOfficial: true,
            publishActivity: true,
            moderatePosts: true,
            moderateComments: true,
          )
        : permissions,
  );

  @override
  Future<CommunityFeed> list({String filter = 'all', String? cursor}) async {
    filters.add(filter);
    listRequests.add((filter, cursor));
    if (listGate != null) {
      await listGate!.future;
    }
    if (failList) {
      throw const RepositoryException('动态暂未加载，请重试。');
    }
    final matching = records.values
        .where(
          (p) => switch (filter) {
            'feedback' => p['category'] == 'feedback',
            'official' => p['isOfficial'] == true,
            _ => true,
          },
        )
        .toList();
    final start = cursor == null ? 0 : int.parse(cursor);
    return CommunityFeed(
      posts: matching
          .skip(start)
          .take(pageSize)
          .map(CommunityPost.fromJson)
          .toList(),
      nextCursor: start + pageSize < matching.length
          ? '${start + pageSize}'
          : null,
      viewer: viewer,
    );
  }

  @override
  Future<CommunityDetail> getDetail(String id, {String? commentCursor}) async =>
      CommunityDetail(
        post: CommunityPost.fromJson(records[id]!),
        comments: comments.where((c) => c.postId == id).toList(),
        viewer: viewer,
      );

  @override
  Future<CommunityPost> setLike(String id, bool liked) async {
    records[id]!['liked'] = liked;
    records[id]!['likeCount'] = liked ? 1 : 0;
    return CommunityPost.fromJson(records[id]!);
  }

  @override
  Future<CommunityPost> setJoin(String id, bool joined) async {
    records[id]!['joined'] = joined;
    records[id]!['participantCount'] = joined ? 1 : 0;
    return CommunityPost.fromJson(records[id]!);
  }

  @override
  Future<CommunityCommentResult> comment(
    String id,
    String content, {
    required String requestId,
  }) async {
    commentsSent++;
    commentIds.add(requestId);
    if (commentGate != null) await commentGate!.future;
    if (failComment) throw const RepositoryException('评论未发出，请重试。');
    final result = CommunityComment(
      id: 'comment-${comments.length}',
      postId: id,
      authorId: 'user',
      authorName: '我',
      authorIsOfficial: official,
      content: content,
      createdAt: DateTime(2026, 11, 9),
      canDelete: true,
    );
    comments.add(result);
    records[id]!['commentCount'] = comments.length;
    return CommunityCommentResult(
      comment: result,
      post: CommunityPost.fromJson(records[id]!),
    );
  }

  @override
  Future<CommunityMedia> uploadImage(
    Uint8List bytes, {
    required String mimeType,
    required String requestId,
  }) async {
    uploadRequests.add(requestId);
    if (uploadFailures.contains(requestId)) {
      throw const RepositoryException('这张图片暂未上传，请重试。');
    }
    final media = uploaded.putIfAbsent(
      requestId,
      () => {
        'id': 'media-$requestId',
        'url': '/api/v1/community/media/media-$requestId',
        'width': 640,
        'height': 800,
        'mimeType': mimeType,
        'bytes': bytes.length,
      },
    );
    return CommunityMedia.fromJson(media);
  }

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
  }) async {
    creates++;
    createIds.add(requestId);
    if (createGate != null) await createGate!.future;
    if (failCreate) throw const RepositoryException('发布未完成，请重试。');
    if (expiredMedia.isNotEmpty) {
      throw RepositoryException(
        '图片已过期，请重新上传。',
        details: {
          'code': 'community_media_expired',
          'mediaIds': List<String>.of(expiredMedia),
        },
      );
    }
    records['new'] = {
      ..._post('new'),
      'title': title,
      'content': content,
      'kind': kind,
      'category': category,
      'authorIsOfficial': this.official,
      'isOfficial': official,
      'startsAt': startsAt?.toIso8601String(),
      'place': place,
      'canDelete': true,
      'media': [
        for (final id in mediaIds)
          uploaded.values.singleWhere((item) => item['id'] == id),
      ],
    };
    return CommunityPost.fromJson(records['new']!);
  }

  @override
  Future<void> deletePost(String id) async {
    records.remove(id);
  }

  @override
  Future<void> deleteComment(String id) async {
    final comment = comments.singleWhere((item) => item.id == id);
    comments.remove(comment);
    records[comment.postId]!['commentCount'] = comments
        .where((item) => item.postId == comment.postId)
        .length;
  }

  @override
  Future<CommunityManagement> getManagement() async => CommunityManagement(
    viewer: viewer,
    admins: official ? admins : const [],
    applications: official ? applications : const [],
    myApplication: myApplication,
  );

  @override
  Future<void> applyForAdmin(String reason, {required String requestId}) async {
    applicationIds.add(requestId);
    if (failApplication) throw const RepositoryException('申请暂未提交，请重试。');
    myApplication = CommunityAdminApplication(
      id: 'application',
      userId: 'applicant',
      username: '申请者',
      reason: reason,
      status: 'pending',
      createdAt: DateTime(2026, 11, 9),
    );
  }

  @override
  Future<void> addAdmin(
    String identifier,
    CommunityPermissions permissions,
  ) async {
    managementChanges.add('add:$identifier');
    admins.add(
      CommunityAdmin(
        userId: 'member',
        username: identifier,
        permissions: permissions,
      ),
    );
  }

  @override
  Future<void> updateAdmin(
    String userId,
    CommunityPermissions permissions,
  ) async {
    managementChanges.add('update:$userId');
    final index = admins.indexWhere((admin) => admin.userId == userId);
    admins[index] = CommunityAdmin(
      userId: userId,
      username: admins[index].username,
      permissions: permissions,
    );
  }

  @override
  Future<void> removeAdmin(String userId) async {
    managementChanges.add('remove:$userId');
    admins.removeWhere((admin) => admin.userId == userId);
  }

  @override
  Future<void> reviewApplication(
    String id, {
    required String status,
    CommunityPermissions? permissions,
  }) async {
    managementChanges.add('review:$id:$status');
    final index = applications.indexWhere((item) => item.id == id);
    final old = applications[index];
    applications[index] = CommunityAdminApplication(
      id: old.id,
      userId: old.userId,
      username: old.username,
      reason: old.reason,
      status: status,
      createdAt: old.createdAt,
    );
    if (status == 'approved') {
      admins.add(
        CommunityAdmin(
          userId: old.userId,
          username: old.username,
          permissions: permissions!,
        ),
      );
    }
  }
}

Future<(CommunityController, GoRouter)> _mount(
  WidgetTester tester,
  _CommunityStore store,
  String location, {
  bool narrow = false,
  double? width,
  double? textScale,
  Future<List<CommunityImageSelection>> Function(int limit)? imagePicker,
  Future<List<CommunityImageSelection>> Function(int limit)? imageRecovery,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width ?? (narrow ? 320 : 390), 700);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  if (narrow || textScale != null) {
    tester.platformDispatcher.textScaleFactorTestValue =
        textScale ?? (narrow ? 1.5 : 1.0);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  final controller = CommunityController(repository: store);
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/community',
        builder: (_, _) => const CommunityFeedScreen(),
      ),
      GoRoute(
        path: '/community/compose',
        builder: (_, _) => CommunityComposeScreen(
          imagePicker: imagePicker,
          imageRecovery: imageRecovery,
        ),
      ),
      GoRoute(
        path: '/community/manage',
        builder: (_, _) => const CommunityManagementScreen(),
      ),
      GoRoute(
        path: '/community/post/:postId',
        builder: (_, state) =>
            CommunityDetailScreen(postId: state.pathParameters['postId']!),
      ),
      GoRoute(
        path: '/login',
        builder: (_, _) => const Scaffold(body: Text('账户登录')),
      ),
      GoRoute(
        path: '/covered',
        builder: (_, _) => const Scaffold(body: Text('另一个页面')),
      ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    controller.dispose();
    store.dispose();
    router.dispose();
  });
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: controller,
      child: MaterialApp.router(theme: seraTheme(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (controller, router);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'multi-photo and feedback labels do not overlap at 320px and 2x text',
    (tester) async {
      final store = _CommunityStore();
      store.records['post'] = {
        ..._post('post'),
        'category': 'feedback',
        'media': [
          for (var index = 0; index < 3; index++)
            {
              'id': 'feedback-photo-$index',
              'url': '/api/v1/community/media/feedback-photo-$index',
              'width': 800,
              'height': 1000,
              'mimeType': 'image/jpeg',
              'bytes': 100,
            },
        ],
      };
      final (controller, _) = await _mount(
        tester,
        store,
        '/community',
        width: 320,
        textScale: 2,
      );
      final cover = tester.getRect(
        find.byKey(const ValueKey('community-cover-post')),
      );
      final category = tester.getRect(
        find.byKey(const ValueKey('community-post-type-post')),
      );
      final count = tester.getRect(
        find.byKey(const ValueKey('community-media-count-post')),
      );
      expect(category.overlaps(count), isFalse);
      expect(category.left, greaterThanOrEqualTo(cover.left));
      expect(count.right, lessThanOrEqualTo(cover.right));
      expect(category.bottom, lessThan(cover.bottom));
      expect(controller.posts.first.media, hasLength(3));
      expect(find.text('使用反馈'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'feed filtering and pagination show server records without creating data',
    (tester) async {
      final store = _CommunityStore(authenticated: false);
      final (controller, _) = await _mount(
        tester,
        store,
        '/community',
        narrow: true,
      );
      expect(controller.posts.map((p) => p.id), ['post']);
      await _tap(tester, find.widgetWithText(SeraButton, '加载更多'));
      expect(controller.posts.map((p) => p.id), ['post', 'event']);
      await _tap(
        tester,
        find.byKey(const ValueKey('community-filter-official')),
      );
      expect(controller.posts.map((p) => p.id), ['event']);
      expect(store.filters.last, 'official');
      await _tap(tester, find.byKey(const ValueKey('community-filter-all')));
      expect(controller.posts.map((p) => p.id), ['post']);
      expect(store.creates, 0);
      expect(store.commentsSent, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'feedback publication remains a personal post and the feed filters server categories',
    (tester) async {
      final store = _CommunityStore();
      final (controller, router) = await _mount(
        tester,
        store,
        '/community/compose',
        narrow: true,
      );
      await _tap(tester, find.widgetWithText(ChoiceChip, '使用反馈'));
      await tester.enterText(
        find.byKey(const ValueKey('community-content-input')),
        '切换到日程时，希望继续停留在刚才查看的日期。',
      );
      await _tap(tester, find.widgetWithText(SeraButton, '发布'));
      final saved = store.records['new']!;
      expect(saved['kind'], 'post');
      expect(saved['category'], 'feedback');
      expect(saved['isOfficial'], isFalse);
      expect(saved['authorIsOfficial'], isFalse);
      expect(saved['title'], isEmpty);
      expect(saved['startsAt'], isNull);
      expect(saved['place'], isEmpty);
      expect(controller.detail('new')!.post.content, saved['content']);
      expect(router.state.uri.path, '/community/post/new');
      router.go('/community');
      await tester.pumpAndSettle();
      await _tap(
        tester,
        find.byKey(const ValueKey('community-filter-feedback')),
      );
      expect(controller.filter, 'feedback');
      expect(controller.posts.map((post) => post.id), ['new']);
      expect(controller.posts.single.category, 'feedback');
      expect(store.creates, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'one author keeps the same avatar for personal posts official posts and comments',
    (tester) async {
      final store = _CommunityStore();
      for (final record in store.records.values) {
        record['authorId'] = 'same-admin';
        record['authorName'] = '同一作者';
        record['authorIsOfficial'] = false;
        record['isAdmin'] = true;
      }
      store.comments.add(
        CommunityComment(
          id: 'same-author-comment',
          postId: 'event',
          authorId: 'same-admin',
          authorName: '同一作者',
          isAdmin: true,
          content: '补充一个自己的经验。',
          createdAt: DateTime(2026, 11, 9),
        ),
      );
      final (controller, router) = await _mount(
        tester,
        store,
        '/community/post/post',
        narrow: true,
      );
      final author = find.byKey(const ValueKey('community-avatar:same-admin'));
      final personal = tester.widget<CircleAvatar>(author);
      expect((personal.child! as Text).data, '同');
      router.go('/community/post/event');
      await tester.pumpAndSettle();
      expect(
        controller.detail('event')!.comments.single.authorId,
        'same-admin',
      );
      final officialPost = tester.widget<CircleAvatar>(author);
      expect(officialPost.backgroundColor, personal.backgroundColor);
      expect(officialPost.foregroundColor, personal.foregroundColor);
      expect((officialPost.child! as Text).data, '同');
      final comment = find.byKey(
        const ValueKey('community-comment-same-author-comment'),
      );
      await tester.scrollUntilVisible(
        comment,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final commentAvatar = tester.widget<CircleAvatar>(
        find.descendant(of: comment, matching: author),
      );
      expect(commentAvatar.backgroundColor, personal.backgroundColor);
      expect(commentAvatar.foregroundColor, personal.foregroundColor);
      expect((commentAvatar.child! as Text).data, '同');
      expect(store.records['event']!['isOfficial'], isTrue);
      store.records['owner'] = {
        ..._post('owner'),
        'authorId': 'official-owner',
        'authorName': '序日',
        'authorIsOfficial': true,
        'isOfficial': true,
      };
      router.go('/community/post/owner');
      await tester.pumpAndSettle();
      final owner = tester.widget<CircleAvatar>(
        find.byKey(const ValueKey('community-avatar:official-owner')),
      );
      expect(
        ((owner.child! as Image).image as AssetImage).assetName,
        'assets/brand/brand-sera-mark@3x.png',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'short feed waits for a real upward drag and loads once while the request is pending',
    (tester) async {
      final store = _CommunityStore();
      final (controller, _) = await _mount(tester, store, '/community');
      expect(store.listRequests, [('all', null)]);
      await tester.pump(const Duration(seconds: 1));
      expect(store.listRequests, hasLength(1));
      final feed = find.byKey(const PageStorageKey('community-feed'));
      final gate = store.listGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) {
          gate.complete();
        }
      });
      final drag = await tester.startGesture(tester.getCenter(feed));
      await drag.moveBy(const Offset(0, -80));
      await tester.pump();
      await drag.moveBy(const Offset(0, -80));
      await tester.pump();
      expect(store.listRequests, [('all', null), ('all', '1')]);
      expect(controller.loadingMore, isTrue);
      expect(controller.posts.map((post) => post.id), ['post']);
      gate.complete();
      await tester.pump();
      await tester.pump();
      await drag.moveBy(const Offset(0, -80));
      await tester.pump();
      expect(store.listRequests, hasLength(2));
      await drag.up();
      await tester.pumpAndSettle();
      expect(controller.posts.map((post) => post.id), ['post', 'event']);
      expect(controller.nextCursor, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mouse wheel loads the next page without a touch drag', (
    tester,
  ) async {
    final store = _CommunityStore()..pageSize = 4;
    store.records['third'] = _post('third');
    store.records['fourth'] = _post('fourth');
    store.records['fifth'] = _post('fifth');
    final (controller, _) = await _mount(tester, store, '/community');
    final feed = find.byKey(const PageStorageKey('community-feed'));
    final scroll = tester.widget<CustomScrollView>(feed).controller!;
    scroll.jumpTo(scroll.position.maxScrollExtent - 40);
    await tester.pumpAndSettle();
    expect(store.listRequests, [('all', null)]);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(feed),
        scrollDelta: const Offset(0, 80),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.posts.map((post) => post.id), [
      'post',
      'event',
      'third',
      'fourth',
      'fifth',
    ]);
    expect(store.listRequests, [('all', null), ('all', '4')]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'bottom pull refresh keeps the selected filter loaded pages and scroll offset',
    (tester) async {
      final store = _CommunityStore();
      store.records.clear();
      for (var index = 0; index < 3; index++) {
        store.records['feedback-$index'] = {
          ..._post('feedback-$index'),
          'category': 'feedback',
          'title': '反馈 $index',
        };
      }
      final (controller, _) = await _mount(tester, store, '/community');
      await _tap(
        tester,
        find.byKey(const ValueKey('community-filter-feedback')),
      );
      await _tap(tester, find.widgetWithText(SeraButton, '加载更多'));
      await _tap(tester, find.widgetWithText(SeraButton, '加载更多'));
      expect(controller.posts, hasLength(3));
      expect(controller.nextCursor, isNull);
      final feed = find.byKey(const PageStorageKey('community-feed'));
      final scroll = tester.widget<CustomScrollView>(feed).controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final originalOffset = scroll.offset;
      final before = store.listRequests.length;
      store.records['feedback-0']!['likeCount'] = 4;
      store.records['feedback-3'] = {
        ..._post('feedback-3'),
        'category': 'feedback',
      };
      final gate = store.listGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) {
          gate.complete();
        }
      });
      final drag = await tester.startGesture(tester.getCenter(feed));
      await drag.moveBy(const Offset(0, -100));
      await tester.pump();
      await drag.moveBy(const Offset(0, -60));
      await tester.pump();
      expect(store.listRequests.skip(before), [('feedback', null)]);
      expect(controller.posts, hasLength(3));
      expect(controller.loading, isTrue);
      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(controller.posts.map((post) => post.id), [
        'feedback-0',
        'feedback-1',
        'feedback-2',
        'feedback-3',
      ]);
      expect(controller.posts.first.likeCount, 4);
      expect(controller.filter, 'feedback');
      expect(scroll.offset, closeTo(originalOffset, 1));
      expect(store.listRequests.skip(before), [
        ('feedback', null),
        ('feedback', '1'),
        ('feedback', '2'),
        ('feedback', '3'),
      ]);
      await drag.moveBy(const Offset(0, -80));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(store.listRequests, hasLength(before + 4));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed upward pagination retries the same cursor without losing posts',
    (tester) async {
      final store = _CommunityStore();
      final (controller, _) = await _mount(tester, store, '/community');
      store.failList = true;
      await tester.drag(
        find.byKey(const PageStorageKey('community-feed')),
        const Offset(0, -180),
      );
      await tester.pumpAndSettle();
      expect(controller.posts.map((post) => post.id), ['post']);
      expect(controller.nextCursor, '1');
      expect(controller.error, isNotNull);
      store.failList = false;
      await _tap(tester, find.widgetWithText(SeraButton, '重试'));
      expect(store.listRequests, [('all', null), ('all', '1'), ('all', '1')]);
      expect(controller.posts.map((post) => post.id), ['post', 'event']);
      expect(controller.error, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  for (final total in [300, 1000]) {
    testWidgets(
      'two-column feed lazily builds $total posts at 320px large text',
      (tester) async {
        final store = _CommunityStore()..pageSize = total;
        store.records.clear();
        for (var index = 0; index < total; index++) {
          store.records['post-$index'] = {
            ..._post('post-$index'),
            'title': '保留完整中文输入与清晰的浏览顺序 $index',
            'content': '今天把复习任务拆小后，完成了最重要的一件事，也给明天留出了时间。',
          };
        }
        final (controller, _) = await _mount(
          tester,
          store,
          '/community',
          narrow: true,
        );
        expect(controller.posts, hasLength(total));
        final builtPosts = find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'community-post-',
              ),
        );
        expect(builtPosts.evaluate().length, greaterThan(0));
        expect(builtPosts.evaluate().length, lessThan(20));
        expect(
          find.byKey(ValueKey('community-post-post-${total - 1}')),
          findsNothing,
        );
        final grid = tester.widget<SliverMasonryGrid>(
          find.byType(SliverMasonryGrid),
        );
        expect(
          (grid.gridDelegate as SliverSimpleGridDelegateWithFixedCrossAxisCount)
              .crossAxisCount,
          2,
        );
        final feed = find.byKey(const PageStorageKey('community-feed'));
        final scroll = tester.widget<CustomScrollView>(feed).controller!;
        final lastPost = find.byKey(
          ValueKey('community-post-post-${total - 1}'),
        );
        // A masonry sliver estimates remaining extent from measured items.
        // Visit successive windows rather than treating the initial estimate
        // as an exact coordinate for an unmeasured child.
        for (var step = 0; step < 400 && lastPost.evaluate().isEmpty; step++) {
          scroll.jumpTo(
            (scroll.offset + 1400)
                .clamp(0, scroll.position.maxScrollExtent)
                .toDouble(),
          );
          await tester.pumpAndSettle();
          expect(builtPosts.evaluate().length, greaterThan(0));
          expect(builtPosts.evaluate().length, lessThan(20));
        }
        expect(lastPost, findsOneWidget);
        expect(builtPosts.evaluate().length, greaterThan(0));
        expect(builtPosts.evaluate().length, lessThan(20));
        expect(store.listRequests, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final width in [320.0, 390.0]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets(
        'text covers retain readable type at ${width}px and ${scale}x without overflow',
        (tester) async {
          final store = _CommunityStore()..pageSize = 5;
          store.records
            ..clear()
            ..addAll({
              'short': {..._post('short'), 'title': '先休息一下'},
              'long': {
                ..._post('long'),
                'title': '今天不赶着做完所有的事情，认真完成最重要的一件，再给自己留一点空白',
              },
              'untitled': {
                ..._post('untitled'),
                'title': '',
                'content': '没有写标题的动态也可以直接分享今天的想法与生活。\n\n这里是详情中保留的第二段。',
              },
              'symbols': {
                ..._post('symbols'),
                'title': 'ABCDEFGHIJKLMN0123456789🧑‍💻🌿✨' * 4,
              },
              'activity': _post('activity', activity: true),
            });
          await _mount(
            tester,
            store,
            '/community',
            width: width,
            textScale: scale,
          );
          expect(
            tester
                .widget<Scaffold>(find.byType(Scaffold).first)
                .backgroundColor,
            Colors.white,
          );
          for (final id in store.records.keys) {
            final cover = find.byKey(ValueKey('community-cover-$id'));
            await tester.scrollUntilVisible(
              cover,
              180,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            final headline = find.byKey(
              ValueKey('community-cover-headline-$id'),
            );
            final text = tester.widget<Text>(headline);
            expect(text.style!.fontSize, greaterThanOrEqualTo(26));
            expect(
              MediaQuery.textScalerOf(tester.element(headline)).scale(20),
              closeTo(20 * scale, .001),
            );
            expect(text.maxLines, inInclusiveRange(1, 5));
            final size = tester.getSize(cover);
            expect(size.width / size.height, closeTo(.75, .001));
            expect(
              tester.getRect(headline).height,
              lessThanOrEqualTo(size.height),
            );
            expect(
              find.descendant(
                of: find.byKey(ValueKey('community-post-$id')),
                matching: find.byType(SeraCard),
              ),
              findsNothing,
            );
            expect(tester.takeException(), isNull);
          }
        },
      );
    }
  }

  testWidgets(
    'text cover opens the same complete post and like stays an independent action',
    (tester) async {
      final store = _CommunityStore();
      const title = '留点时间给自己';
      const body = '散步、发呆，或者什么也不安排。\n\n这段内容在封面之后，打开详情仍然完整保留。';
      store.records['post'] = {
        ..._post('post'),
        'title': title,
        'content': body,
      };
      final (controller, router) = await _mount(tester, store, '/community');
      final headline = tester.widget<Text>(
        find.byKey(const ValueKey('community-cover-headline-post')),
      );
      final caption = tester.widget<Text>(
        find.byKey(const ValueKey('community-caption-post')),
      );
      expect(headline.data, title);
      expect(caption.data, body.split('\n\n').first);
      final like = find.byKey(const ValueKey('community-like-post'));
      final likeSize = tester.getSize(like);
      expect(likeSize.width, greaterThanOrEqualTo(40));
      expect(likeSize.height, greaterThanOrEqualTo(44));
      await _tap(tester, like);
      expect(router.state.uri.path, '/community');
      expect(controller.posts.single.likeCount, 1);
      expect(store.records['post']!['liked'], isTrue);
      await _tap(tester, find.byKey(const ValueKey('community-cover-post')));
      expect(router.state.uri.path, '/community/post/post');
      expect(controller.detail('post')!.post.content, body);
      expect(find.text(body), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a text cover keeps its ID based color after edits refresh and reordering',
    (tester) async {
      final store = _CommunityStore()..pageSize = 2;
      store.records
        ..clear()
        ..addAll({'post-a': _post('post-a'), 'post-b': _post('post-b')});
      final (controller, _) = await _mount(tester, store, '/community');
      Color color(String id) =>
          (tester
                      .widget<DecoratedBox>(
                        find.byKey(ValueKey('community-text-cover-$id')),
                      )
                      .decoration
                  as BoxDecoration)
              .color!;
      final original = color('post-a');
      expect(color('post-b'), isNot(original));
      final first = store.records.remove('post-a')!;
      first['title'] = '标题改了，封面颜色依旧属于这条动态';
      store.records['post-a'] = first;
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(controller.posts.map((post) => post.id), ['post-b', 'post-a']);
      expect(color('post-a'), original);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancelled photo selection leaves no draft and no upload', (
    tester,
  ) async {
    final store = _CommunityStore();
    final limits = <int>[];
    final (_, router) = await _mount(
      tester,
      store,
      '/community/compose',
      imagePicker: (limit) async {
        limits.add(limit);
        return [];
      },
    );
    await _tap(tester, find.byKey(const ValueKey('community-add-images')));
    expect(limits, [3]);
    expect(store.uploadRequests, isEmpty);
    expect(store.creates, 0);
    await _tap(tester, find.byTooltip('返回'));
    expect(find.byType(AlertDialog), findsNothing);
    expect(router.state.uri.path, '/community');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'image uploads retry one failed item and publish only three confirmed media IDs',
    (tester) async {
      final store = _CommunityStore()..uploadFailures.add('two');
      final limits = <int>[];
      final (controller, router) = await _mount(
        tester,
        store,
        '/community/compose',
        narrow: true,
        imagePicker: (limit) async {
          limits.add(limit);
          return ['one', 'two', 'three', 'extra'].map(_selection).toList();
        },
      );
      await tester.enterText(
        find.byKey(const ValueKey('community-content-input')),
        '记录今天认真完成的事情。',
      );
      await _tap(tester, find.byKey(const ValueKey('community-add-images')));
      expect(limits, [3]);
      expect(store.uploadRequests, ['one', 'two', 'three']);
      expect(store.uploaded.keys, ['one', 'three']);
      final publish = find.widgetWithText(SeraButton, '发布');
      expect(tester.widget<SeraButton>(publish).onPressed, isNull);
      expect(store.creates, 0);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('community-add-images')),
            )
            .onPressed,
        isNull,
      );
      store.uploadFailures.clear();
      await _tap(
        tester,
        find.byKey(const ValueKey('community-upload-retry-two')),
      );
      expect(store.uploadRequests, ['one', 'two', 'three', 'two']);
      expect(tester.widget<SeraButton>(publish).onPressed, isNotNull);
      await _tap(tester, publish);
      expect(store.creates, 1);
      expect(controller.detail('new')!.post.media.map((image) => image.id), [
        'media-one',
        'media-two',
        'media-three',
      ]);
      expect(router.state.uri.path, '/community/post/new');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'uploaded images require confirmation before leaving and can be removed',
    (tester) async {
      final store = _CommunityStore();
      final (_, router) = await _mount(
        tester,
        store,
        '/community/compose',
        imagePicker: (_) async => [_selection('photo')],
      );
      await _tap(tester, find.byKey(const ValueKey('community-add-images')));
      expect(store.uploadRequests, ['photo']);
      await _tap(tester, find.byTooltip('返回'));
      expect(find.byType(AlertDialog), findsOneWidget);
      await _tap(tester, find.widgetWithText(TextButton, '继续编辑'));
      expect(
        find.byKey(const ValueKey('community-selected-photo')),
        findsOneWidget,
      );
      await _tap(tester, find.byTooltip('移除图片 1'));
      expect(
        find.byKey(const ValueKey('community-selected-photo')),
        findsNothing,
      );
      await _tap(tester, find.byTooltip('返回'));
      expect(router.state.uri.path, '/community');
      expect(store.creates, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'expired image recovery keeps the other uploaded images and original text',
    (tester) async {
      final store = _CommunityStore()..expiredMedia.add('media-two');
      final (controller, _) = await _mount(
        tester,
        store,
        '/community/compose',
        imagePicker: (_) async => [_selection('one'), _selection('two')],
      );
      final content = find.byKey(const ValueKey('community-content-input'));
      await tester.enterText(content, '图片过期后保留这段输入。');
      await _tap(tester, find.byKey(const ValueKey('community-add-images')));
      await _tap(tester, find.widgetWithText(SeraButton, '发布'));
      expect(store.records.containsKey('new'), isFalse);
      expect(
        tester.widget<TextFormField>(content).controller!.text,
        '图片过期后保留这段输入。',
      );
      expect(
        find.byKey(const ValueKey('community-upload-retry-one')),
        findsNothing,
      );
      store.expiredMedia.clear();
      await _tap(
        tester,
        find.byKey(const ValueKey('community-upload-retry-two')),
      );
      expect(store.uploadRequests, hasLength(3));
      expect(store.uploadRequests.last, startsWith('two-'));
      await _tap(tester, find.widgetWithText(SeraButton, '发布'));
      expect(controller.detail('new')!.post.media.first.id, 'media-one');
      expect(controller.detail('new')!.post.media.last.id, isNot('media-two'));
      expect(controller.detail('new')!.post.content, '图片过期后保留这段输入。');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'recovered image selection remains unpublished until explicit confirmation',
    (tester) async {
      final store = _CommunityStore()..recoveredSession = 'owner-session';
      await _mount(
        tester,
        store,
        '/community/compose',
        imageRecovery: (_) async => [_selection('restored')],
      );
      expect(store.uploadRequests, ['restored']);
      expect(store.creates, 0);
      expect(
        find.byKey(const ValueKey('community-selected-restored')),
        findsOneWidget,
      );
      await _tap(tester, find.widgetWithText(SeraButton, '发布'));
      expect(
        store.creates,
        0,
        reason: 'Recovered photos do not bypass required text.',
      );
      await tester.enterText(
        find.byKey(const ValueKey('community-content-input')),
        '确认恢复后的内容，再由我发布。',
      );
      await _tap(tester, find.widgetWithText(SeraButton, '发布'));
      expect(store.creates, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late photo recovery cannot transfer images to another account', (
    tester,
  ) async {
    final store = _CommunityStore()..recoveredSession = 'owner-A';
    final recovered = Completer<List<CommunityImageSelection>>();
    var recoveryCalls = 0;
    final (controller, _) = await _mount(
      tester,
      store,
      '/community/compose',
      imageRecovery: (_) {
        recoveryCalls++;
        return recoveryCalls == 1 ? recovered.future : Future.value([]);
      },
    );
    store.owner++;
    store.recoveredSession = 'owner-B';
    await controller.load();
    await tester.pumpAndSettle();
    recovered.complete([_selection('private-A')]);
    await tester.pumpAndSettle();
    expect(store.uploadRequests, isEmpty);
    expect(store.creates, 0);
    expect(
      find.byKey(const ValueKey('community-selected-private-A')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('anonymous discussion returns to the exact post after login', (
    tester,
  ) async {
    final store = _CommunityStore(authenticated: false);
    final (_, router) = await _mount(tester, store, '/community/post/event');
    await _tap(tester, find.widgetWithText(SeraButton, '登录后参与讨论'));
    expect(router.state.uri.path, '/login');
    expect(
      router.state.uri.queryParameters['returnTo'],
      '/community/post/event',
    );
    expect(store.comments, isEmpty);
    expect(store.records['event']!['liked'], isFalse);
  });

  testWidgets(
    'like, join and comment retry update the same post and retain failed input',
    (tester) async {
      final store = _CommunityStore()..failComment = true;
      final (controller, _) = await _mount(
        tester,
        store,
        '/community/post/event',
        narrow: true,
      );
      await _tap(tester, find.byKey(const ValueKey('community-detail-like')));
      expect(controller.detail('event')!.post.liked, isTrue);
      final join = find.widgetWithText(SeraButton, '报名参加');
      final discussionScroll = find.byType(CustomScrollView);
      for (
        var drag = 0;
        drag < 12 && join.hitTestable().evaluate().isEmpty;
        drag++
      ) {
        await tester.drag(discussionScroll, const Offset(0, -160));
        await tester.pumpAndSettle();
      }
      expect(join.hitTestable(), findsOneWidget);
      await tester.tap(join.hitTestable());
      await tester.pumpAndSettle();
      expect(controller.detail('event')!.post.participantCount, 1);
      await tester.tap(find.widgetWithText(SeraButton, '取消报名').hitTestable());
      await tester.pumpAndSettle();
      expect(store.records['event']!['joined'], isFalse);
      final input = find.byKey(const ValueKey('community-comment-input'));
      await tester.enterText(input, '想一起交流怎样安排复习时间。');
      await _tap(tester, find.byTooltip('发送评论'));
      expect(
        tester.widget<TextField>(input).controller!.text,
        '想一起交流怎样安排复习时间。',
      );
      expect(controller.detail('event')!.comments, isEmpty);
      store.failComment = false;
      await _tap(tester, find.byTooltip('发送评论'));
      expect(store.commentIds.toSet(), hasLength(1));
      expect(
        controller.detail('event')!.comments.single.content,
        '想一起交流怎样安排复习时间。',
      );
      expect(controller.detail('event')!.post.commentCount, 1);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed publication keeps input and rapid retry creates only one post',
    (tester) async {
      final store = _CommunityStore()..failCreate = true;
      final (_, router) = await _mount(
        tester,
        store,
        '/community/compose',
        narrow: true,
      );
      expect(find.widgetWithText(ChoiceChip, '官方动态'), findsNothing);
      final input = find.byKey(const ValueKey('community-content-input'));
      await tester.enterText(input, '今天练习了番茄专注，准备明天继续。');
      await _tap(tester, find.widgetWithText(SeraButton, '发布'));
      expect(store.records.containsKey('new'), isFalse);
      expect(
        tester.widget<TextFormField>(input).controller!.text,
        '今天练习了番茄专注，准备明天继续。',
      );
      store.failCreate = false;
      final gate = store.createGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final publish = find.widgetWithText(SeraButton, '发布');
      await tester.ensureVisible(publish);
      await tester.tap(publish);
      await tester.tap(publish);
      await tester.pump();
      expect(
        store.creates,
        2,
        reason: 'One failed request and one in-flight retry.',
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(store.createIds.toSet(), hasLength(1));
      expect(store.records['new']!['title'], '');
      expect(store.records['new']!['content'], '今天练习了番茄专注，准备明天继续。');
      expect(router.state.uri.path, '/community/post/new');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'leaving the composer protects unsaved input until explicit discard',
    (tester) async {
      final store = _CommunityStore();
      final (_, router) = await _mount(tester, store, '/community');
      await _tap(tester, find.byTooltip('发布'));
      final input = find.byKey(const ValueKey('community-content-input'));
      await tester.enterText(input, '还要整理一下再发布。');
      await _tap(tester, find.byTooltip('返回'));
      await _tap(tester, find.widgetWithText(TextButton, '继续编辑'));
      expect(
        tester.widget<TextFormField>(input).controller!.text,
        '还要整理一下再发布。',
      );
      await _tap(tester, find.byTooltip('返回'));
      await _tap(tester, find.widgetWithText(TextButton, '放弃'));
      expect(router.state.uri.path, '/community');
      expect(store.creates, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late publication cannot navigate over a newer page', (
    tester,
  ) async {
    final store = _CommunityStore();
    final gate = store.createGate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final (_, router) = await _mount(tester, store, '/community/compose');
    await tester.enterText(
      find.byKey(const ValueKey('community-content-input')),
      '只发布一次',
    );
    await tester.tap(find.widgetWithText(SeraButton, '发布'));
    await tester.pump();
    unawaited(router.push('/covered'));
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/covered');
    expect(store.creates, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'admin application failure preserves the reason and retry creates one pending application',
    (tester) async {
      final store = _CommunityStore()..failApplication = true;
      final (controller, _) = await _mount(
        tester,
        store,
        '/community/manage',
        narrow: true,
      );
      expect(
        find.byKey(const ValueKey('community-admin-identifier')),
        findsNothing,
      );
      final reason = find.byKey(const ValueKey('community-admin-reason'));
      await tester.enterText(reason, '愿意帮助整理经验帖、维护友善的讨论。');
      await _tap(tester, find.widgetWithText(SeraButton, '提交申请'));
      expect(store.myApplication, isNull);
      expect(
        tester.widget<TextFormField>(reason).controller!.text,
        '愿意帮助整理经验帖、维护友善的讨论。',
      );
      store.failApplication = false;
      await _tap(tester, find.widgetWithText(SeraButton, '提交申请'));
      expect(store.applicationIds.toSet(), hasLength(1));
      expect(controller.management!.myApplication!.status, 'pending');
      expect(find.widgetWithText(SeraButton, '提交申请'), findsNothing);
      expect(store.managementChanges, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a removed administrator can submit a new application after an earlier approval',
    (tester) async {
      final store = _CommunityStore();
      store.myApplication = CommunityAdminApplication(
        id: 'earlier-approved-application',
        userId: 'applicant',
        username: '申请者',
        reason: '上一次申请',
        status: 'approved',
        createdAt: DateTime(2026, 11, 1),
      );
      final (controller, _) = await _mount(tester, store, '/community/manage');
      expect(controller.viewer.isAdmin, isFalse);
      expect(find.text('当前未担任管理员'), findsOneWidget);
      final reason = find.byKey(const ValueKey('community-admin-reason'));
      await tester.enterText(reason, '现在有时间，希望重新参与评论管理。');
      await _tap(tester, find.widgetWithText(SeraButton, '重新申请'));
      final application = controller.management!.myApplication!;
      expect(application.id, isNot('earlier-approved-application'));
      expect(application.reason, '现在有时间，希望重新参与评论管理。');
      expect(application.status, 'pending');
      expect(store.applicationIds, hasLength(1));
      expect(controller.viewer.isAdmin, isFalse);
      expect(find.widgetWithText(SeraButton, '重新申请'), findsNothing);
      expect(
        find.byKey(const ValueKey('community-admin-identifier')),
        findsNothing,
      );
      expect(store.managementChanges, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'owner grants edits and revokes four independent permissions in one editor',
    (tester) async {
      final store = _CommunityStore(official: true);
      final (controller, _) = await _mount(
        tester,
        store,
        '/community/manage',
        narrow: true,
      );
      await tester.enterText(
        find.byKey(const ValueKey('community-admin-identifier')),
        'exact.member@example.test',
      );
      await _tap(tester, find.widgetWithText(SeraButton, '添加管理员'));
      await _tap(tester, find.widgetWithText(SwitchListTile, '发布活动'));
      await _tap(tester, find.widgetWithText(SwitchListTile, '管理评论'));
      await _tap(tester, find.widgetWithText(SeraButton, '确认添加'));
      expect(store.managementChanges, ['add:exact.member@example.test']);
      var permissions = controller.management!.admins.single.permissions;
      expect(permissions.publishActivity, isTrue);
      expect(permissions.moderateComments, isTrue);
      expect(permissions.publishOfficial, isFalse);
      expect(permissions.moderatePosts, isFalse);
      await _tap(tester, find.widgetWithText(TextButton, '设置权限'));
      await _tap(tester, find.widgetWithText(SwitchListTile, '发布活动'));
      await _tap(tester, find.widgetWithText(SwitchListTile, '管理帖子'));
      await _tap(tester, find.widgetWithText(SeraButton, '保存权限'));
      permissions = controller.management!.admins.single.permissions;
      expect(permissions.publishActivity, isFalse);
      expect(permissions.moderatePosts, isTrue);
      expect(permissions.moderateComments, isTrue);
      await _tap(tester, find.widgetWithText(TextButton, '移除'));
      await _tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, '移除'),
        ),
      );
      expect(controller.management!.admins, isEmpty);
      expect(store.managementChanges, [
        'add:exact.member@example.test',
        'update:member',
        'remove:member',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'owner approval grants only the permissions explicitly selected',
    (tester) async {
      final store = _CommunityStore(official: true);
      store.applications.add(
        CommunityAdminApplication(
          id: 'pending-1',
          userId: 'applicant',
          username: '申请者',
          reason: '希望参与评论管理',
          status: 'pending',
          createdAt: DateTime(2026, 11, 9),
        ),
      );
      final (controller, _) = await _mount(tester, store, '/community/manage');
      await _tap(tester, find.widgetWithText(TextButton, '审核并授权'));
      await _tap(tester, find.widgetWithText(SwitchListTile, '管理评论'));
      await _tap(tester, find.widgetWithText(SeraButton, '批准申请'));
      expect(controller.management!.applications.single.status, 'approved');
      expect(controller.management!.admins.single.permissions.toJson(), {
        'publishOfficial': false,
        'publishActivity': false,
        'moderatePosts': false,
        'moderateComments': true,
      });
      expect(store.managementChanges, ['review:pending-1:approved']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'activity permission alone publishes an activity without exposing owner management',
    (tester) async {
      final store = _CommunityStore(
        admin: true,
        permissions: const CommunityPermissions(publishActivity: true),
      );
      final (_, router) = await _mount(tester, store, '/community/manage');
      expect(
        find.byKey(const ValueKey('community-admin-identifier')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('community-admin-reason')),
        findsNothing,
      );
      router.go('/community/compose');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, '官方动态'), findsNothing);
      await _tap(tester, find.widgetWithText(ChoiceChip, '活动'));
      await tester.enterText(
        find.byKey(const ValueKey('community-title-input')),
        '一起整理本周计划',
      );
      await tester.enterText(
        find.byKey(const ValueKey('community-content-input')),
        '分享计划与进展',
      );
      await _tap(tester, find.widgetWithText(SeraButton, '发布'));
      expect(
        store.creates,
        0,
        reason: 'Activities require an explicitly selected start time.',
      );
      await _tap(tester, find.widgetWithText(OutlinedButton, '选择活动开始时间'));
      await _tap(tester, find.widgetWithText(TextButton, '继续'));
      await _tap(tester, find.widgetWithText(TextButton, '确定'));
      await _tap(tester, find.widgetWithText(SeraButton, '发布'));
      expect(store.records['new']!['kind'], 'activity');
      expect(store.records['new']!['isOfficial'], isTrue);
      expect(store.records['new']!['startsAt'], isNotNull);
      expect(store.creates, 1);
      expect(router.state.uri.path, '/community/post/new');
      expect(tester.takeException(), isNull);
    },
  );
}
