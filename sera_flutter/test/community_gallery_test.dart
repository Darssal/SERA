import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind, SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:sera_flutter/application/community_controller.dart';
import 'package:sera_flutter/data/community_repository.dart';
import 'package:sera_flutter/domain/community_models.dart';
import 'package:sera_flutter/ui/core/sera_widgets.dart';
import 'package:sera_flutter/ui/screens/community_screens.dart';

// Valid PNGs with different decoded proportions, rather than failing network
// placeholders. This lets the tests exercise both retry and image rendering.
final _landscapePng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAIAAADwyuo0AAAAEElEQVR4nGPQaIqCIwZkDgBoKgghnvDuigAAAABJRU5ErkJggg==',
);
final _portraitPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAAECAIAAAArjXluAAAAEElEQVR4nGPQaIoCIgZsFABwTAghJ9tUsAAAAABJRU5ErkJggg==',
);
final _squarePng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAMAAAADCAIAAADZSiLoAAAAEElEQVR4nGPQaIqCIAYsLACHeAklZa8ThAAAAABJRU5ErkJggg==',
);

class _ImageTransport implements HttpClient {
  final requests = <String, int>{};
  final failures = <String>{};

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final id = url.pathSegments.last;
    requests.update(id, (value) => value + 1, ifAbsent: () => 1);
    final pixels = switch (id) {
      'landscape' => _landscapePng,
      'portrait' => _portraitPng,
      _ => _squarePng,
    };
    return _ImageRequest(
      _ImageResponse(pixels, failures.contains(id) ? 503 : 200),
    );
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageRequest implements HttpClientRequest {
  _ImageRequest(this.response);
  final HttpClientResponse response;

  @override
  Future<HttpClientResponse> close() async => response;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageResponse extends Stream<List<int>> implements HttpClientResponse {
  _ImageResponse(this.bytes, this.statusCode);
  final Uint8List bytes;

  @override
  final int statusCode;

  @override
  int get contentLength => bytes.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _landscape = CommunityMedia(
  id: 'landscape',
  url: '/media/landscape',
  width: 4,
  height: 2,
  mimeType: 'image/png',
  bytes: 73,
);
const _portrait = CommunityMedia(
  id: 'portrait',
  url: '/media/portrait',
  width: 2,
  height: 4,
  mimeType: 'image/png',
  bytes: 73,
);
const _square = CommunityMedia(
  id: 'square',
  url: '/media/square',
  width: 3,
  height: 3,
  mimeType: 'image/png',
  bytes: 73,
);

class _GalleryStore extends CommunityRepository {
  _GalleryStore({this.media = const [_landscape, _portrait, _square]})
    : super(apiBaseUrl: 'http://gallery.test');
  List<CommunityMedia> media;
  int owner = 1;

  @override
  bool get signedIn => true;

  @override
  Object get sessionOwner => owner;

  @override
  Future<CommunityDetail> getDetail(String id, {String? commentCursor}) async =>
      CommunityDetail(
        post: CommunityPost(
          id: id,
          authorId: 'photographer',
          authorName: '记录生活_模拟',
          title: '一天的三个片段',
          content: '先去散步，再准备晚饭。\n\n图片下方仍然只有这一份完整正文。',
          media: List.of(media),
          createdAt: DateTime.utc(2026, 11, 9),
        ),
        comments: const [],
        viewer: const CommunityViewer(signedIn: true),
      );
}

class _GalleryHarness {
  _GalleryHarness(this.store, this.controller, this.router, this.images);
  final _GalleryStore store;
  final CommunityController controller;
  final GoRouter router;
  final _ImageTransport images;
}

Future<_GalleryHarness> _mount(
  WidgetTester tester, {
  List<CommunityMedia> media = const [_landscape, _portrait, _square],
  double width = 390,
  double textScale = 1,
  Set<String> failures = const {},
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 844);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  PaintingBinding.instance.imageCache.clear();
  PaintingBinding.instance.imageCache.clearLiveImages();
  final transport = _ImageTransport()..failures.addAll(failures);
  final previous = debugNetworkImageHttpClientProvider;
  debugNetworkImageHttpClientProvider = () => transport;
  final store = _GalleryStore(media: media);
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
    debugNetworkImageHttpClientProvider = previous;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: controller,
      child: MaterialApp.router(routerConfig: router, theme: seraTheme()),
    ),
  );
  await _settle(tester);
  return _GalleryHarness(store, controller, router, transport);
}

Future<void> _settle(WidgetTester tester) async {
  // Image codec work completes outside fake frame time.
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pumpAndSettle();
}

Finder _key(String key) => find.byKey(ValueKey(key));
Finder get _gallery => _key('community-gallery-post');
Finder get _pages => _key('community-gallery-pages-post');
Finder get _fullScreen => _key('community-gallery-fullscreen-post');
Finder get _fullPages => _key('community-gallery-fullscreen-pages-post');

double _page(WidgetTester tester, Finder finder) =>
    tester.widget<PageView>(finder).controller!.page!;

Future<void> _next(WidgetTester tester, Finder pages) async {
  await tester.drag(pages, const Offset(-300, 0));
  await _settle(tester);
}

ScrollPosition _detailPosition(WidgetTester tester) => tester
    .stateList<ScrollableState>(
      find.descendant(
        of: find.byType(CustomScrollView).first,
        matching: find.byType(Scrollable),
      ),
    )
    .firstWhere((state) => state.widget.axisDirection == AxisDirection.down)
    .position;

void _galleryTest(String name, WidgetTesterCallback body) {
  testWidgets(name, (tester) async {
    final previousImageClient = debugNetworkImageHttpClientProvider;
    try {
      await body(tester);
    } finally {
      // Flutter verifies debug globals before package:test addTearDown runs.
      // Release consumers before restoring this hook so a later image decode
      // cannot accidentally use the binding's default HTTP 400 transport.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugNetworkImageHttpClientProvider = previousImageClient;
    }
  });
}

void main() {
  _galleryTest(
    'three photos share one horizontal stage and select real pages',
    (tester) async {
      await _mount(tester);
      expect(_gallery, findsOneWidget);
      expect(_pages, findsOneWidget);
      final height = tester.getSize(_gallery).height;
      expect(_page(tester, _pages), closeTo(0, .01));
      final pagination = _key('community-gallery-dots-post');
      final paginationSize = tester.getSize(pagination);
      expect(paginationSize.width, greaterThanOrEqualTo(72));
      expect(paginationSize.height, greaterThanOrEqualTo(40));
      final firstDot = _key('community-gallery-dot-post-0');
      final middleDot = _key('community-gallery-dot-post-1');
      final lastDot = _key('community-gallery-dot-post-2');
      expect(tester.getSize(firstDot), const Size(6, 6));
      expect(tester.getSize(middleDot), const Size(6, 6));
      expect(tester.getSize(lastDot), const Size(6, 6));
      expect(
        tester.getCenter(middleDot).dx - tester.getCenter(firstDot).dx,
        closeTo(12, .01),
      );
      expect(
        tester.getCenter(lastDot).dx - tester.getCenter(middleDot).dx,
        closeTo(12, .01),
      );
      final initialSemantics = tester
          .getSemantics(pagination)
          .getSemanticsData();
      expect(initialSemantics.value, '第 1 张，共 3 张');
      expect(initialSemantics.flagsCollection.isSlider, isTrue);
      expect(initialSemantics.hasAction(SemanticsAction.increase), isTrue);
      expect(initialSemantics.hasAction(SemanticsAction.decrease), isFalse);

      await _next(tester, _pages);
      expect(_page(tester, _pages), closeTo(1, .01));
      expect(tester.getSize(_gallery).height, height);
      final middleSemantics = tester
          .getSemantics(pagination)
          .getSemanticsData();
      expect(middleSemantics.value, '第 2 张，共 3 张');
      expect(middleSemantics.hasAction(SemanticsAction.increase), isTrue);
      expect(middleSemantics.hasAction(SemanticsAction.decrease), isTrue);
      await tester.tap(lastDot);
      await _settle(tester);
      expect(_page(tester, _pages), closeTo(2, .01));
      final lastNode = tester.getSemantics(pagination);
      final lastSemantics = lastNode.getSemanticsData();
      expect(lastSemantics.value, '第 3 张，共 3 张');
      expect(lastSemantics.hasAction(SemanticsAction.increase), isFalse);
      expect(lastSemantics.hasAction(SemanticsAction.decrease), isTrue);
      lastNode.owner!.performAction(lastNode.id, SemanticsAction.decrease);
      await _settle(tester);
      expect(_page(tester, _pages), closeTo(1, .01));
      expect(
        tester.getSemantics(pagination).getSemanticsData().value,
        '第 2 张，共 3 张',
      );
      final middleNode = tester.getSemantics(pagination);
      middleNode.owner!.performAction(middleNode.id, SemanticsAction.increase);
      await _settle(tester);
      expect(_page(tester, _pages), closeTo(2, .01));
      expect(
        tester.getSemantics(pagination).getSemanticsData().value,
        '第 3 张，共 3 张',
      );
      expect(tester.getSize(_gallery).height, height);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  _galleryTest(
    'adding photos does not stack three large images above the body',
    (tester) async {
      final harness = await _mount(tester, media: const [_landscape]);
      final singleHeight = tester.getSize(_gallery).height;
      final singleBodyTop = tester.getTopLeft(find.byType(SelectableText)).dy;
      harness.store.media = const [_landscape, _portrait, _square];
      await harness.controller.loadDetail('post');
      await _settle(tester);
      expect(
        tester.getSize(_gallery).height,
        lessThanOrEqualTo(singleHeight + 48),
      );
      expect(
        tester.getTopLeft(find.byType(SelectableText)).dy,
        lessThanOrEqualTo(singleBodyTop + 48),
      );
      expect(find.byType(PageView), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  _galleryTest(
    'landscape and portrait retain decoded ratios with contain fit',
    (tester) async {
      await _mount(tester, media: const [_landscape, _portrait]);
      final stageSize = tester.getSize(_pages);
      Image image(String id) => tester.widget<Image>(
        find.descendant(
          of: _pages,
          matching: find.byWidgetPredicate(
            (widget) => widget is Image && widget.key == ValueKey('$id:0'),
          ),
        ),
      );
      expect(image('landscape').fit, BoxFit.contain);
      final landscapePixels = tester
          .widget<RawImage>(
            find.descendant(
              of: _key('community-gallery-image-post-0'),
              matching: find.byType(RawImage),
            ),
          )
          .image!;
      expect(landscapePixels.width / landscapePixels.height, 2);
      await _next(tester, _pages);
      expect(image('portrait').fit, BoxFit.contain);
      final portraitPixels = tester
          .widget<RawImage>(
            find.descendant(
              of: _key('community-gallery-image-post-1'),
              matching: find.byType(RawImage),
            ),
          )
          .image!;
      expect(portraitPixels.width / portraitPixels.height, .5);
      expect(tester.getSize(_pages), stageSize);
      expect(tester.takeException(), isNull);
    },
  );

  _galleryTest(
    'full-screen starts at the tapped image and returns page and input',
    (tester) async {
      final harness = await _mount(tester);
      final input = _key('community-comment-input');
      await tester.enterText(input, '这张窗边照片真好看。');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.drag(_pages, const Offset(0, -55));
      await tester.pumpAndSettle();
      final offset = _detailPosition(tester).pixels;
      await _next(tester, _pages);
      await tester.tap(_key('community-gallery-image-post-1'));
      await _settle(tester);
      expect(_fullScreen, findsOneWidget);
      expect(
        tester.widget<Text>(_key('community-gallery-count-post')).data,
        '2/3',
      );
      expect(_page(tester, _fullPages), closeTo(1, .01));
      await _next(tester, _fullPages);
      expect(
        tester.widget<Text>(_key('community-gallery-count-post')).data,
        '3/3',
      );
      await tester.tap(_key('community-gallery-close-post'));
      await _settle(tester);
      expect(_fullScreen, findsNothing);
      expect(_page(tester, _pages), closeTo(2, .01));
      expect(_detailPosition(tester).pixels, closeTo(offset, .1));
      expect(tester.widget<TextField>(input).controller!.text, '这张窗边照片真好看。');
      expect(
        harness.router.routeInformationProvider.value.uri.path,
        '/community/post/post',
      );
      expect(tester.takeException(), isNull);
    },
  );

  _galleryTest(
    'system back and Escape close only the full-screen image route',
    (tester) async {
      final harness = await _mount(tester);
      await tester.enterText(_key('community-comment-input'), '稍后发送');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(_key('community-gallery-image-post-0'));
      await _settle(tester);
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(_fullScreen, findsNothing);
      expect(_gallery, findsOneWidget);
      expect(
        harness.router.routeInformationProvider.value.uri.path,
        '/community/post/post',
      );
      await tester.tap(_key('community-gallery-image-post-0'));
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(_fullScreen, findsNothing);
      expect(_gallery, findsOneWidget);
      expect(
        tester
            .widget<TextField>(_key('community-comment-input'))
            .controller!
            .text,
        '稍后发送',
      );
      expect(tester.takeException(), isNull);
    },
  );

  _galleryTest(
    'a single photo has no page dots but can still open full-screen',
    (tester) async {
      await _mount(tester, media: const [_portrait]);
      expect(_key('community-gallery-dots-post'), findsNothing);
      await tester.tap(_key('community-gallery-image-post-0'));
      await _settle(tester);
      expect(_fullScreen, findsOneWidget);
      expect(
        tester.widget<Text>(_key('community-gallery-count-post')).data,
        '1/1',
      );
      expect(_key('community-gallery-previous-post'), findsNothing);
      expect(_key('community-gallery-next-post'), findsNothing);
      await tester.tap(_key('community-gallery-close-post'));
      await _settle(tester);
      expect(_gallery, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  _galleryTest('retry reloads the failed photo without opening a viewer', (
    tester,
  ) async {
    final harness = await _mount(tester, failures: {'landscape'});
    expect(find.byTooltip('重新加载图片'), findsWidgets);
    expect(harness.images.requests['landscape'], 1);
    harness.images.failures.clear();
    await tester.tap(find.byTooltip('重新加载图片').first);
    await _settle(tester);
    expect(harness.images.requests['landscape'], 2);
    expect(_fullScreen, findsNothing);
    final pixels = tester
        .widget<RawImage>(
          find.descendant(
            of: _key('community-gallery-image-post-0'),
            matching: find.byType(RawImage),
          ),
        )
        .image;
    expect(pixels, isNotNull);
    expect(tester.takeException(), isNull);
  });

  _galleryTest(
    '320px and large fonts keep gallery and full-screen controls usable',
    (tester) async {
      await _mount(tester, width: 320, textScale: 2);
      expect(tester.getSize(_pages).width, lessThanOrEqualTo(320));
      await _next(tester, _pages);
      await tester.tap(_key('community-gallery-image-post-1'));
      await _settle(tester);
      final close = _key('community-gallery-close-post');
      final count = _key('community-gallery-count-post');
      final bounds = Offset.zero & const Size(320, 844);
      expect(bounds.contains(tester.getCenter(close)), isTrue);
      expect(bounds.contains(tester.getCenter(count)), isTrue);
      expect(tester.getSize(close).shortestSide, greaterThanOrEqualTo(44));
      expect(tester.getRect(close).overlaps(tester.getRect(count)), isFalse);
      await tester.tap(close);
      await _settle(tester);
      expect(_gallery, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  _galleryTest(
    'double-tap zoom protects the image pan and restores horizontal paging',
    (tester) async {
      await _mount(tester);
      await tester.tap(_key('community-gallery-image-post-0'));
      await _settle(tester);
      final zoom = find.descendant(
        of: _key('community-gallery-zoom-landscape'),
        matching: find.byType(InteractiveViewer),
      );
      Future<void> doubleTap() async {
        await tester.tap(zoom);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tap(zoom);
        await _settle(tester);
      }

      await doubleTap();
      expect(
        tester
            .widget<InteractiveViewer>(zoom)
            .transformationController!
            .value
            .getMaxScaleOnAxis(),
        greaterThan(1),
      );
      expect(
        tester.widget<PageView>(_fullPages).physics,
        isA<NeverScrollableScrollPhysics>(),
      );
      await tester.drag(zoom, const Offset(-180, 0));
      await _settle(tester);
      expect(_page(tester, _fullPages), closeTo(0, .01));
      await doubleTap();
      expect(
        tester
            .widget<InteractiveViewer>(zoom)
            .transformationController!
            .value
            .getMaxScaleOnAxis(),
        1,
      );
      expect(
        tester.widget<PageView>(_fullPages).physics,
        isNot(isA<NeverScrollableScrollPhysics>()),
      );
      await _next(tester, _fullPages);
      expect(_page(tester, _fullPages), closeTo(1, .01));
      expect(tester.takeException(), isNull);
    },
  );

  _galleryTest(
    'mouse drag pages full-screen photos and respects zoom before paging again',
    (tester) async {
      await _mount(tester);
      await tester.tap(
        _key('community-gallery-image-post-0'),
        kind: PointerDeviceKind.mouse,
      );
      await _settle(tester);
      expect(_fullScreen, findsOneWidget);
      Future<void> mouseDrag(Offset offset) async {
        await tester.drag(_fullPages, offset, kind: PointerDeviceKind.mouse);
        await _settle(tester);
      }

      await mouseDrag(const Offset(-300, 0));
      expect(_page(tester, _fullPages), closeTo(1, .01));
      expect(
        tester.widget<Text>(_key('community-gallery-count-post')).data,
        '2/3',
      );
      await mouseDrag(const Offset(-300, 0));
      expect(_page(tester, _fullPages), closeTo(2, .01));
      expect(
        tester.widget<Text>(_key('community-gallery-count-post')).data,
        '3/3',
      );
      await mouseDrag(const Offset(300, 0));
      expect(_page(tester, _fullPages), closeTo(1, .01));

      final zoom = find.descendant(
        of: _key('community-gallery-zoom-portrait'),
        matching: find.byType(InteractiveViewer),
      );
      Future<void> mouseDoubleClick() async {
        await tester.tap(zoom, kind: PointerDeviceKind.mouse);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tap(zoom, kind: PointerDeviceKind.mouse);
        await _settle(tester);
      }

      await mouseDoubleClick();
      expect(
        tester
            .widget<InteractiveViewer>(zoom)
            .transformationController!
            .value
            .getMaxScaleOnAxis(),
        greaterThan(1),
      );
      await tester.drag(
        zoom,
        const Offset(-180, 0),
        kind: PointerDeviceKind.mouse,
      );
      await _settle(tester);
      expect(_page(tester, _fullPages), closeTo(1, .01));
      await mouseDoubleClick();
      expect(
        tester
            .widget<InteractiveViewer>(zoom)
            .transformationController!
            .value
            .getMaxScaleOnAxis(),
        1,
      );
      await mouseDrag(const Offset(-300, 0));
      expect(_page(tester, _fullPages), closeTo(2, .01));
      expect(
        tester.widget<Text>(_key('community-gallery-count-post')).data,
        '3/3',
      );
      expect(tester.takeException(), isNull);
    },
  );

  _galleryTest('switching accounts removes a stale full-screen photo route', (
    tester,
  ) async {
    final harness = await _mount(tester);
    await tester.enterText(_key('community-comment-input'), '属于原账号的草稿');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.tap(_key('community-gallery-image-post-0'));
    await _settle(tester);
    harness.store.owner++;
    await harness.controller.loadDetail('post');
    await _settle(tester);
    expect(_fullScreen, findsNothing);
    expect(
      harness.router.routeInformationProvider.value.uri.path,
      '/community/post/post',
    );
    expect(
      tester
          .widget<TextField>(_key('community-comment-input'))
          .controller!
          .text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  _galleryTest('account change removes only its viewer beneath a newer route', (
    tester,
  ) async {
    final harness = await _mount(tester);
    await tester.tap(_key('community-gallery-image-post-0'));
    await _settle(tester);
    final navigator = Navigator.of(tester.element(_fullScreen));
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(
            key: ValueKey('newer-community-route'),
            body: Text('新的页面'),
          ),
        ),
      ),
    );
    await _settle(tester);
    harness.store.owner++;
    await harness.controller.loadDetail('post');
    await _settle(tester);
    expect(_key('newer-community-route'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey('community-gallery-fullscreen-post'),
        skipOffstage: false,
      ),
      findsNothing,
    );
    navigator.pop();
    await _settle(tester);
    expect(_gallery, findsOneWidget);
    expect(
      harness.router.routeInformationProvider.value.uri.path,
      '/community/post/post',
    );
    expect(tester.takeException(), isNull);
  });

  _galleryTest('replacing the same post media closes the old photo route', (
    tester,
  ) async {
    final harness = await _mount(tester);
    await tester.tap(_key('community-gallery-image-post-0'));
    await _settle(tester);
    harness.store.media = const [_square, _portrait];
    await harness.controller.loadDetail('post');
    await _settle(tester);
    expect(_fullScreen, findsNothing);
    expect(_gallery, findsOneWidget);
    expect(_page(tester, _pages), closeTo(0, .01));
    expect(
      harness.controller.detail('post')!.post.media.map((media) => media.id),
      ['square', 'portrait'],
    );
    expect(tester.takeException(), isNull);
  });
}
