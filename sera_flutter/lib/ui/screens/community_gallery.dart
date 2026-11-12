part of 'community_screens.dart';

String _communityMediaSignature(List<CommunityMedia> media) => media
    .map((item) => '${item.id}:${item.url}:${item.width}:${item.height}')
    .join('|');

class _CommunityGalleryScrollBehavior extends MaterialScrollBehavior {
  const _CommunityGalleryScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.trackpad,
  };
}

/// One media viewport keeps the story and comments close to the photographs.
/// PageStorage is intentionally disabled: this state belongs to one account,
/// post and media revision rather than a shared scroll position.
class _CommunityGallery extends StatefulWidget {
  const _CommunityGallery({
    super.key,
    required this.post,
    required this.controller,
    required this.owner,
  });

  final CommunityPost post;
  final CommunityController controller;
  final Object owner;

  @override
  State<_CommunityGallery> createState() => _CommunityGalleryState();
}

class _CommunityGalleryState extends State<_CommunityGallery> {
  PageController _pages = PageController(keepPage: false);
  int _index = 0;
  Route<int>? _viewerRoute;

  @override
  void didUpdateWidget(covariant _CommunityGallery oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller) ||
        oldWidget.owner != widget.owner ||
        oldWidget.post.id != widget.post.id ||
        _communityMediaSignature(oldWidget.post.media) !=
            _communityMediaSignature(widget.post.media)) {
      _dismissViewer();
      final previous = _pages;
      _pages = PageController(keepPage: false);
      _index = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
  }

  void _dismissViewer() {
    final route = _viewerRoute;
    _viewerRoute = null;
    if (route == null) return;
    // A gallery can leave the tree during a router/account rebuild. Removing
    // its exact route after that frame cannot accidentally pop a newer page.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = route.navigator;
      if (navigator != null && navigator.mounted && route.isActive) {
        navigator.removeRoute(route);
      }
    });
  }

  @override
  void dispose() {
    _dismissViewer();
    _pages.dispose();
    super.dispose();
  }

  void _goTo(int index) {
    if (index < 0 || index >= widget.post.media.length || !_pages.hasClients) {
      return;
    }
    if (SeraMotion.reduced(context)) {
      _pages.jumpToPage(index);
    } else {
      unawaited(
        _pages.animateToPage(
          index,
          duration: SeraMotion.primaryDuration,
          curve: SeraMotion.curve,
        ),
      );
    }
  }

  Future<void> _open(int index) async {
    if (_viewerRoute != null ||
        widget.controller.sessionOwner != widget.owner) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final controller = widget.controller;
    final owner = widget.owner;
    final post = widget.post;
    final signature = _communityMediaSignature(post.media);
    final route = PageRouteBuilder<int>(
      settings: const RouteSettings(name: 'community-image-viewer'),
      transitionDuration: SeraMotion.reduced(context)
          ? Duration.zero
          : SeraMotion.primaryDuration,
      reverseTransitionDuration: SeraMotion.reduced(context)
          ? Duration.zero
          : SeraMotion.reverseDuration,
      pageBuilder: (_, animation, secondaryAnimation) =>
          ChangeNotifierProvider.value(
            value: controller,
            child: _CommunityFullscreenGallery(
              post: post,
              owner: owner,
              controller: controller,
              initialIndex: index,
            ),
          ),
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          SeraRouteTransition(
            animation: animation,
            type: SeraRouteMotion.primary,
            child: child,
          ),
    );
    _viewerRoute = route;
    final selected = await Navigator.of(context).push<int>(route);
    if (!mounted || !identical(route, _viewerRoute)) return;
    _viewerRoute = null;
    if (selected == null ||
        controller.sessionOwner != owner ||
        !identical(widget.controller, controller) ||
        widget.post.id != post.id ||
        _communityMediaSignature(widget.post.media) != signature ||
        selected < 0 ||
        selected >= widget.post.media.length) {
      return;
    }
    setState(() => _index = selected);
    if (_pages.hasClients) _pages.jumpToPage(selected);
  }

  Widget _pagination() {
    final post = widget.post;
    final count = post.media.length;
    // Keep the marks together, while the complete strip remains an easy
    // touch target. A tap selects the nearest visual dot, not a hidden button.
    final width = (count * 12.0 + 24).clamp(72.0, double.infinity).toDouble();
    final firstCenter = (width - (count - 1) * 12) / 2;
    return Center(
      child: Semantics(
        key: ValueKey('community-gallery-dots-${post.id}'),
        label: '动态图片',
        value: '第 ${_index + 1} 张，共 $count 张',
        slider: true,
        onIncrease: _index < count - 1 ? () => _goTo(_index + 1) : null,
        onDecrease: _index > 0 ? () => _goTo(_index - 1) : null,
        increasedValue: _index < count - 1
            ? '第 ${_index + 2} 张，共 $count 张'
            : null,
        decreasedValue: _index > 0 ? '第 $_index 张，共 $count 张' : null,
        child: ExcludeSemantics(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) {
              final index = ((details.localPosition.dx - firstCenter) / 12)
                  .round()
                  .clamp(0, count - 1)
                  .toInt();
              _goTo(index);
            },
            child: SizedBox(
              width: width,
              height: 40,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var index = 0; index < count; index++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Container(
                        key: ValueKey(
                          'community-gallery-dot-${post.id}-$index',
                        ),
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: _index == index
                              ? SeraColors.brand
                              : SeraColors.muted,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final first = post.media.first;
    final ratio = (first.width / first.height).clamp(.65, 1.8).toDouble();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: ratio,
          child: ScrollConfiguration(
            behavior: const _CommunityGalleryScrollBehavior(),
            child: PageView.builder(
              key: ValueKey('community-gallery-pages-${post.id}'),
              controller: _pages,
              itemCount: post.media.length,
              allowImplicitScrolling: true,
              onPageChanged: (index) => setState(() => _index = index),
              itemBuilder: (context, index) => Semantics(
                button: true,
                label: '查看大图，第 ${index + 1} 张，共 ${post.media.length} 张',
                child: GestureDetector(
                  key: ValueKey('community-gallery-image-${post.id}-$index'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _open(index),
                  child: _CommunityImage(
                    media: post.media[index],
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
          ),
        ),
        if (post.media.length > 1)
          Padding(padding: const EdgeInsets.only(top: 2), child: _pagination()),
      ],
    );
  }
}

class _CommunityFullscreenGallery extends StatefulWidget {
  const _CommunityFullscreenGallery({
    required this.post,
    required this.owner,
    required this.controller,
    required this.initialIndex,
  });

  final CommunityPost post;
  final Object owner;
  final CommunityController controller;
  final int initialIndex;

  @override
  State<_CommunityFullscreenGallery> createState() =>
      _CommunityFullscreenGalleryState();
}

class _CommunityFullscreenGalleryState
    extends State<_CommunityFullscreenGallery> {
  late final _pages = PageController(
    initialPage: widget.initialIndex,
    keepPage: false,
  );
  late int _index = widget.initialIndex;
  bool _zoomed = false;
  bool _invalid = false;
  Drag? _mouseDrag;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_checkIdentity);
  }

  bool _matchesCurrentMedia() {
    final current = widget.controller.detail(widget.post.id)?.post;
    return widget.controller.sessionOwner == widget.owner &&
        current != null &&
        _communityMediaSignature(current.media) ==
            _communityMediaSignature(widget.post.media);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The identity can change between pushing this route and its first build,
    // before initState attached the listener. Never paint that old snapshot.
    if (!_invalid && !_matchesCurrentMedia()) {
      _invalid = true;
      _removeInvalidRoute();
    }
  }

  void _checkIdentity() {
    if (_invalid || _matchesCurrentMedia()) return;
    _invalid = true;
    if (mounted) setState(() {});
    _removeInvalidRoute();
  }

  void _removeInvalidRoute() {
    _mouseDrag?.cancel();
    _mouseDrag = null;
    // Account changes and deleted/replaced attachments must not leave their
    // previous photographs over the new account, even beneath another route.
    final route = ModalRoute.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = route?.navigator;
      if (route != null &&
          navigator != null &&
          navigator.mounted &&
          route.isActive) {
        navigator.removeRoute(route);
      }
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_checkIdentity);
    _mouseDrag?.cancel();
    _mouseDrag = null;
    _pages.dispose();
    super.dispose();
  }

  void _close() {
    final route = ModalRoute.of(context);
    if (route?.isCurrent == true) Navigator.of(context).pop(_index);
  }

  void _goTo(int index) {
    if (_invalid ||
        index < 0 ||
        index >= widget.post.media.length ||
        !_pages.hasClients) {
      return;
    }
    if (SeraMotion.reduced(context)) {
      _pages.jumpToPage(index);
    } else {
      unawaited(
        _pages.animateToPage(
          index,
          duration: SeraMotion.primaryDuration,
          curve: SeraMotion.curve,
        ),
      );
    }
  }

  void _startMousePan(ScaleStartDetails details) {
    if (_zoomed || _invalid || !_pages.hasClients) return;
    _mouseDrag?.cancel();
    _mouseDrag = _pages.position.drag(
      DragStartDetails(
        sourceTimeStamp: details.sourceTimeStamp,
        globalPosition: details.focalPoint,
        localPosition: details.localFocalPoint,
        kind: details.kind,
      ),
      () => _mouseDrag = null,
    );
  }

  void _updateMousePan(ScaleUpdateDetails details) {
    _mouseDrag?.update(
      DragUpdateDetails(
        sourceTimeStamp: details.sourceTimeStamp,
        delta: Offset(details.focalPointDelta.dx, 0),
        primaryDelta: details.focalPointDelta.dx,
        globalPosition: details.focalPoint,
        localPosition: details.localFocalPoint,
      ),
    );
  }

  void _endMousePan(ScaleEndDetails details) {
    final drag = _mouseDrag;
    _mouseDrag = null;
    drag?.end(
      DragEndDetails(
        velocity: details.velocity,
        primaryVelocity: details.velocity.pixelsPerSecond.dx,
      ),
    );
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _close();
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _goTo(_index - 1);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _goTo(_index + 1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    if (_invalid) return const ColoredBox(color: Colors.black);
    return PopScope<int>(
      // System back should return the same photograph as closing X.
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _close();
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: _key,
        child: Scaffold(
          key: ValueKey('community-gallery-fullscreen-${post.id}'),
          backgroundColor: const Color(0xFF101312),
          body: SafeArea(
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      key: ValueKey('community-gallery-close-${post.id}'),
                      tooltip: '关闭图片',
                      onPressed: _close,
                      color: Colors.white,
                      icon: const Icon(Icons.close),
                    ),
                    Expanded(
                      child: Semantics(
                        liveRegion: true,
                        label: '第 ${_index + 1} 张，共 ${post.media.length} 张',
                        child: Text(
                          '${_index + 1}/${post.media.length}',
                          key: ValueKey('community-gallery-count-${post.id}'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 16,
                            height: 1.5,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ScrollConfiguration(
                        behavior: const _CommunityGalleryScrollBehavior(),
                        child: PageView.builder(
                          key: ValueKey(
                            'community-gallery-fullscreen-pages-${post.id}',
                          ),
                          controller: _pages,
                          itemCount: post.media.length,
                          physics: _zoomed
                              ? const NeverScrollableScrollPhysics()
                              : null,
                          allowImplicitScrolling: true,
                          onPageChanged: (index) => setState(() {
                            _index = index;
                            _zoomed = false;
                          }),
                          itemBuilder: (context, index) => _CommunityZoomImage(
                            key: ValueKey(
                              'community-gallery-zoom-${post.media[index].id}',
                            ),
                            media: post.media[index],
                            active: _index == index,
                            onMousePanStart: _startMousePan,
                            onMousePanUpdate: _updateMousePan,
                            onMousePanEnd: _endMousePan,
                            onZoomChanged: (zoomed) {
                              if (mounted &&
                                  _index == index &&
                                  _zoomed != zoomed) {
                                setState(() => _zoomed = zoomed);
                              }
                            },
                          ),
                        ),
                      ),
                      if (MediaQuery.sizeOf(context).width >= 600 &&
                          post.media.length > 1) ...[
                        Align(
                          alignment: Alignment.centerLeft,
                          child: IconButton.filledTonal(
                            key: ValueKey(
                              'community-gallery-previous-${post.id}',
                            ),
                            tooltip: '上一张',
                            onPressed: _index == 0
                                ? null
                                : () => _goTo(_index - 1),
                            icon: const Icon(Icons.chevron_left),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: IconButton.filledTonal(
                            key: ValueKey('community-gallery-next-${post.id}'),
                            tooltip: '下一张',
                            onPressed: _index == post.media.length - 1
                                ? null
                                : () => _goTo(_index + 1),
                            icon: const Icon(Icons.chevron_right),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CommunityZoomImage extends StatefulWidget {
  const _CommunityZoomImage({
    super.key,
    required this.media,
    required this.active,
    required this.onZoomChanged,
    required this.onMousePanStart,
    required this.onMousePanUpdate,
    required this.onMousePanEnd,
  });

  final CommunityMedia media;
  final bool active;
  final ValueChanged<bool> onZoomChanged;
  final ValueChanged<ScaleStartDetails> onMousePanStart;
  final ValueChanged<ScaleUpdateDetails> onMousePanUpdate;
  final ValueChanged<ScaleEndDetails> onMousePanEnd;

  @override
  State<_CommunityZoomImage> createState() => _CommunityZoomImageState();
}

class _CommunityZoomImageState extends State<_CommunityZoomImage> {
  final _transform = TransformationController();
  Offset _doubleTapPosition = Offset.zero;
  bool _zoomed = false;
  bool _forwardMousePan = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_changed);
  }

  void _changed() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed == _zoomed || !mounted) return;
    setState(() => _zoomed = zoomed);
    widget.onZoomChanged(zoomed);
  }

  @override
  void didUpdateWidget(covariant _CommunityZoomImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      // Do not notify the parent while its PageView is being rebuilt.
      _transform.removeListener(_changed);
      _transform.value = Matrix4.identity();
      _zoomed = false;
      _transform.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _transform.removeListener(_changed);
    _transform.dispose();
    super.dispose();
  }

  void _doubleTap() {
    if (_zoomed) {
      _transform.value = Matrix4.identity();
    } else {
      const scale = 2.5;
      _transform.value = Matrix4.identity()
        ..translateByDouble(
          -_doubleTapPosition.dx * (scale - 1),
          -_doubleTapPosition.dy * (scale - 1),
          0,
          1,
        )
        ..scaleByDouble(scale, scale, 1, 1);
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onDoubleTapDown: (details) => _doubleTapPosition = details.localPosition,
    onDoubleTap: _doubleTap,
    child: InteractiveViewer(
      transformationController: _transform,
      minScale: 1,
      maxScale: 4,
      panEnabled: _zoomed,
      // InteractiveViewer still claims scale gestures with panEnabled=false.
      // A mouse move can cross both recognizers' tiny thresholds in one event,
      // letting the inner recognizer win before PageView. Forward only that
      // unzoomed mouse gesture to PageView's own drag/physics implementation.
      onInteractionStart: (details) {
        _forwardMousePan =
            widget.active &&
            !_zoomed &&
            details.kind == PointerDeviceKind.mouse;
        if (_forwardMousePan) widget.onMousePanStart(details);
      },
      onInteractionUpdate: (details) {
        if (_forwardMousePan) widget.onMousePanUpdate(details);
      },
      onInteractionEnd: (details) {
        if (_forwardMousePan) widget.onMousePanEnd(details);
        _forwardMousePan = false;
      },
      child: _CommunityImage(
        media: widget.media,
        fit: BoxFit.contain,
        backgroundColor: const Color(0xFF101312),
      ),
    ),
  );
}
