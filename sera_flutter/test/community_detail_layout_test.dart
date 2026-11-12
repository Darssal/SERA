import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:sera_flutter/application/community_controller.dart';
import 'package:sera_flutter/data/community_repository.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/community_models.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:sera_flutter/ui/screens/community_screens.dart';

class _DetailStore extends CommunityRepository {
  _DetailStore() : super(apiBaseUrl: 'http://community.test');
  bool liked = false, failComment = false;
  String title = '今天只做一件小事';
  final deleted = <String>[];
  final sentRequests = <String>[];
  final comments = <CommunityComment>[
    CommunityComment(
      id: 'public-comment',
      postId: 'post',
      authorId: 'companion',
      authorName: '学习同伴_模拟',
      content: '我也会先从一件小事开始，完成之后再继续。',
      createdAt: DateTime.utc(2026, 11, 9, 2),
    ),
    CommunityComment(
      id: 'own-comment',
      postId: 'post',
      authorId: 'me',
      authorName: '我的模拟账号',
      content: '今天准备先完成提纲。',
      canDelete: true,
      createdAt: DateTime.utc(2026, 11, 9, 3),
    ),
  ];

  CommunityPost get post => CommunityPost(
    id: 'post',
    authorId: 'author',
    authorName: '慢慢来_模拟',
    title: title,
    content:
        '把事情拆成能开始的一小步。\n\n'
        '${List.filled(5, '没有完成整件事也没关系，留下真实的进展。').join()}\n\n'
        '这段结尾需要完整保留。',
    createdAt: DateTime.utc(2026, 11, 9, 1),
    liked: liked,
    likeCount: liked ? 1 : 0,
    commentCount: comments.length,
  );

  @override
  bool get signedIn => true;
  @override
  Object get sessionOwner => this;

  @override
  Future<CommunityDetail> getDetail(String id, {String? commentCursor}) async =>
      CommunityDetail(
        post: post,
        comments: List.of(comments),
        viewer: const CommunityViewer(signedIn: true),
      );

  @override
  Future<CommunityPost> setLike(String id, bool value) async {
    liked = value;
    return post;
  }

  @override
  Future<void> deleteComment(String commentId) async {
    deleted.add(commentId);
    comments.removeWhere((comment) => comment.id == commentId);
  }

  @override
  Future<CommunityCommentResult> comment(
    String id,
    String content, {
    required String requestId,
  }) async {
    sentRequests.add(requestId);
    if (failComment) throw const RepositoryException('评论暂未发出，请重试。');
    final comment = CommunityComment(
      id: 'sent-comment',
      postId: id,
      authorId: 'me',
      authorName: '我的模拟账号',
      content: content,
      createdAt: DateTime.utc(2026, 11, 9, 4),
      canDelete: true,
    );
    comments.add(comment);
    return CommunityCommentResult(comment: comment, post: post);
  }
}

Future<CommunityController> _mountDetail(
  WidgetTester tester,
  _DetailStore store, {
  bool largeText = false,
  double textScale = 1.5,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(largeText ? 320 : 390, 760);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  if (largeText) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  final controller = CommunityController(repository: store);
  final router = GoRouter(
    initialLocation: '/community/post/post',
    routes: [
      GoRoute(
        path: '/community/post/:postId',
        builder: (_, state) =>
            CommunityDetailScreen(postId: state.pathParameters['postId']!),
      ),
      GoRoute(
        path: '/community',
        builder: (_, _) => const Scaffold(body: Text('社区信息流')),
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
      child: MaterialApp.router(routerConfig: router, theme: seraTheme()),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets(
    'a long title remains fully readable in a naturally taller cover at 2x text',
    (tester) async {
      final store = _DetailStore()
        ..title =
            '如果今天只能完成一件事，我会先把课程作业拆成容易开始的一小步，'
            '再留一点时间给散步和休息，这是一段需要全部读到结尾的长标题';
      await _mountDetail(tester, store, largeText: true, textScale: 2);
      final cover = find.byKey(const ValueKey('community-text-cover-post'));
      final headline = find.byKey(
        const ValueKey('community-cover-headline-post'),
      );
      final paragraph = tester.renderObject<RenderParagraph>(headline);
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(paragraph.text.toPlainText(), store.title);
      expect(
        tester.getSize(cover).height,
        greaterThan(tester.getSize(cover).width * 5 / 4),
      );
      expect(
        tester.getBottomRight(headline).dy,
        lessThanOrEqualTo(tester.getBottomRight(cover).dy - 15),
      );
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        endsWith('这段结尾需要完整保留。'),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'detail keeps complete body and uses flat comments with permission-safe deletion',
    (tester) async {
      final store = _DetailStore();
      final controller = await _mountDetail(tester, store);
      final author = find.byKey(const ValueKey('community-detail-author'));
      expect(
        find.ancestor(of: author, matching: find.byType(AppBar)),
        findsOneWidget,
      );
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        endsWith('这段结尾需要完整保留。'),
      );
      expect(
        find.byKey(const ValueKey('community-detail-like')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('community-detail-like')));
      await tester.pumpAndSettle();
      expect(controller.detail('post')!.post.liked, isTrue);

      final ownComment = find.byKey(
        const ValueKey('community-comment-own-comment'),
      );
      await tester.scrollUntilVisible(
        ownComment,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: ownComment, matching: find.byType(SeraCard)),
        findsNothing,
      );
      expect(find.text('删除评论'), findsOneWidget);
      await tester.tap(find.text('删除评论'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(store.deleted, isEmpty);
      expect(controller.detail('post')!.post.commentCount, 2);

      await tester.tap(find.text('删除评论'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '删除'));
      await tester.pumpAndSettle();
      expect(store.deleted, ['own-comment']);
      expect(controller.detail('post')!.comments.map((comment) => comment.id), [
        'public-comment',
      ]);
      expect(controller.detail('post')!.post.commentCount, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '320px large text keeps comment editing and retry above the keyboard',
    (tester) async {
      final store = _DetailStore()..failComment = true;
      final controller = await _mountDetail(tester, store, largeText: true);
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('community-comment-input'));
      await tester.enterText(input, '我想先做一份容易开始的提纲。');
      await tester.tap(find.byTooltip('发送评论'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        '我想先做一份容易开始的提纲。',
      );
      expect(store.comments, hasLength(2));
      final footer = find.byKey(const ValueKey('community-detail-footer'));
      expect(tester.getBottomRight(footer).dy, lessThanOrEqualTo(540));
      expect(tester.getTopLeft(input).dy, greaterThan(56));
      store.failComment = false;
      await tester.tap(find.byTooltip('发送评论'));
      await tester.pumpAndSettle();
      expect(store.sentRequests.toSet(), hasLength(1));
      expect(controller.detail('post')!.post.commentCount, 3);
      expect(
        controller.detail('post')!.comments.last.content,
        '我想先做一份容易开始的提纲。',
      );
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
