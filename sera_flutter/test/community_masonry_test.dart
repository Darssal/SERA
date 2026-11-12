import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:sera_flutter/application/community_controller.dart';
import 'package:sera_flutter/data/community_repository.dart';
import 'package:sera_flutter/domain/community_models.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:sera_flutter/ui/screens/community_screens.dart';

CommunityPost _post(int index, {int? imageWidth, int? imageHeight}) =>
    CommunityPost(
      id: 'masonry-$index',
      authorId: 'reader-$index',
      authorName: '分享者 $index',
      title: index.isEven ? '今天的小事 $index' : '今天没有把时间排满，留一点空白给散步和休息 $index',
      content: index.isEven
          ? '给自己留一点空白。'
          : '今天慢慢完成了一件要紧的事，剩下的时间就留给散步和休息，不把日程排满。',
      createdAt: DateTime.utc(2026, 11, 9),
      media: imageWidth == null
          ? const []
          : [
              CommunityMedia(
                id: 'image-$index',
                url: '/api/v1/community/media/image-$index',
                width: imageWidth,
                height: imageHeight!,
                mimeType: 'image/jpeg',
                bytes: 100,
              ),
            ],
    );

class _MasonryRepository extends CommunityRepository {
  _MasonryRepository(this.posts) : super(apiBaseUrl: 'http://community.test');
  List<CommunityPost> posts;
  int reads = 0;
  @override
  bool get signedIn => true;
  @override
  Object get sessionOwner => 'masonry-test-owner';
  @override
  Future<CommunityFeed> list({String filter = 'all', String? cursor}) async {
    reads++;
    return CommunityFeed(
      posts: posts,
      viewer: const CommunityViewer(signedIn: true),
    );
  }

  @override
  Future<CommunityPost> setLike(String id, bool liked) async {
    final index = posts.indexWhere((post) => post.id == id);
    final previous = posts[index];
    final next = CommunityPost(
      id: previous.id,
      authorId: previous.authorId,
      authorName: previous.authorName,
      title: previous.title,
      content: previous.content,
      createdAt: previous.createdAt,
      media: previous.media,
      liked: liked,
      likeCount: liked ? 1 : 0,
    );
    posts[index] = next;
    return next;
  }
}

Future<(CommunityController, GoRouter)> _mount(
  WidgetTester tester,
  _MasonryRepository repository, {
  double width = 390,
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final controller = CommunityController(repository: repository);
  final router = GoRouter(
    initialLocation: '/community',
    routes: [
      GoRoute(
        path: '/community',
        builder: (_, _) => const CommunityFeedScreen(),
      ),
      GoRoute(
        path: '/community/post/:id',
        builder: (_, state) => Scaffold(
          key: ValueKey('masonry-detail-${state.pathParameters['id']}'),
          body: Text('完整动态 ${state.pathParameters['id']}'),
        ),
      ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    controller.dispose();
    repository.dispose();
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

Finder _card(int index) =>
    find.byKey(ValueKey('community-post-masonry-$index'));

Finder _cover(int index) =>
    find.byKey(ValueKey('community-cover-masonry-$index'));

Finder get _builtPosts => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('community-post-'),
);

List<CommunityPost> _mixedPosts() => [
  _post(0, imageWidth: 600, imageHeight: 1200),
  _post(1, imageWidth: 1600, imageHeight: 500),
  _post(2),
  _post(3, imageWidth: 1000, imageHeight: 1000),
  _post(4, imageWidth: 800, imageHeight: 1000),
  _post(5),
];

void main() {
  testWidgets(
    'masonry places the next post directly below the shorter column',
    (tester) async {
      final repository = _MasonryRepository(_mixedPosts());
      final (controller, router) = await _mount(tester, repository);
      expect(find.byType(SliverMasonryGrid), findsOneWidget);
      expect(find.byType(CustomScrollView), findsOneWidget);
      final first = tester.getRect(_card(0));
      final second = tester.getRect(_card(1));
      final third = tester.getRect(_card(2));
      final fourth = tester.getRect(_card(3));
      expect(first.top, second.top);
      expect(first.height, greaterThan(second.height + 80));
      expect(third.left, second.left);
      expect(third.top, closeTo(second.bottom + 12, .01));
      expect(third.top, lessThan(first.bottom));
      expect(fourth.left, first.left);
      expect(fourth.top, closeTo(first.bottom + 12, .01));
      expect(tester.getSize(_cover(0)).aspectRatio, closeTo(.5, .001));
      expect(tester.getSize(_cover(1)).aspectRatio, closeTo(3.2, .001));
      expect(tester.getSize(_cover(2)).aspectRatio, closeTo(.75, .001));
      expect(tester.getSize(_cover(3)).aspectRatio, closeTo(1, .001));
      expect(
        tester
            .getSize(find.byKey(const ValueKey('community-caption-masonry-0')))
            .height,
        lessThan(
          tester
              .getSize(
                find.byKey(const ValueKey('community-caption-masonry-1')),
              )
              .height,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('community-like-masonry-1')));
      await tester.pumpAndSettle();
      expect(controller.posts[1].liked, isTrue);
      expect(router.state.uri.path, '/community');
      expect(tester.getRect(_card(2)), third);
      expect(repository.reads, 1);
      // The test HTTP client rejects network images, so the center of the cover
      // is the image retry button. Tap the actual card area beside that button.
      await tester.tapAt(tester.getTopLeft(_cover(1)) + const Offset(18, 18));
      await tester.pumpAndSettle();
      final detail = find.byKey(const ValueKey('masonry-detail-masonry-1'));
      expect(detail, findsOneWidget);
      expect(find.text('完整动态 masonry-1'), findsOneWidget);
      expect(
        GoRouterState.of(tester.element(detail)).uri.path,
        '/community/post/masonry-1',
      );
      expect(router.canPop(), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [1.5, 2.0]) {
    testWidgets('mixed masonry cards stay usable at 320px and ${scale}x', (
      tester,
    ) async {
      final repository = _MasonryRepository(_mixedPosts());
      await _mount(tester, repository, width: 320, textScale: scale);
      for (var index = 0; index < repository.posts.length; index++) {
        await tester.scrollUntilVisible(
          _card(index),
          140,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        final like = find.byKey(ValueKey('community-like-masonry-$index'));
        expect(tester.getSize(like).height, greaterThanOrEqualTo(44));
        expect(tester.getSize(like).width, greaterThanOrEqualTo(40));
        final rect = tester.getRect(_card(index));
        expect(rect.left, inInclusiveRange(12, 166));
        expect(rect.width, closeTo(142, .001));
        expect(tester.takeException(), isNull);
      }
    });
  }

  for (final total in [300, 1000]) {
    testWidgets('mixed masonry lazily retains $total posts while scrolling', (
      tester,
    ) async {
      final repository = _MasonryRepository([
        for (var index = 0; index < total; index++)
          _post(
            index,
            imageWidth: index % 3 == 0 ? 800 : null,
            imageHeight: index % 2 == 0 ? 1100 : 640,
          ),
      ]);
      final (_, router) = await _mount(
        tester,
        repository,
        width: 320,
        textScale: 1.5,
      );
      expect(_builtPosts.evaluate().length, inInclusiveRange(1, 20));
      expect(_card(total - 1), findsNothing);
      final feed = find.byKey(const PageStorageKey('community-feed'));
      final scroll = tester.widget<CustomScrollView>(feed).controller!;
      for (
        var step = 0;
        step < 400 && _card(total - 1).evaluate().isEmpty;
        step++
      ) {
        scroll.jumpTo(
          (scroll.offset + 1400)
              .clamp(0, scroll.position.maxScrollExtent)
              .toDouble(),
        );
        await tester.pumpAndSettle();
      }
      expect(_card(total - 1), findsOneWidget);
      expect(_builtPosts.evaluate().length, inInclusiveRange(1, 20));
      expect(repository.reads, 1);
      final lastId = 'masonry-${total - 1}';
      final lastCaption = find.byKey(ValueKey('community-caption-$lastId'));
      await tester.ensureVisible(lastCaption);
      await tester.pumpAndSettle();
      await tester.tap(lastCaption);
      await tester.pumpAndSettle();
      final detail = find.byKey(ValueKey('masonry-detail-$lastId'));
      expect(detail, findsOneWidget);
      expect(
        GoRouterState.of(tester.element(detail)).uri.path,
        '/community/post/$lastId',
      );
      expect(router.canPop(), isTrue);
      router.pop();
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/community');
      expect(_card(total - 1), findsOneWidget);
      expect(_builtPosts.evaluate().length, inInclusiveRange(1, 20));
      final originalOffset = scroll.offset;
      await tester.drag(feed, const Offset(0, 280));
      await tester.pumpAndSettle();
      expect(scroll.offset, lessThan(originalOffset));
      expect(_builtPosts.evaluate().length, lessThanOrEqualTo(20));
      expect(tester.takeException(), isNull);
    });
  }
}
