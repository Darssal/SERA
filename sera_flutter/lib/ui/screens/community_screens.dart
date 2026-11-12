import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../application/community_controller.dart';
import '../../data/workspace_repository.dart';
import '../../domain/community_models.dart';
import '../../platform/community_image_picker.dart';
import '../core/sera_motion.dart';
import '../core/sera_widgets.dart';

part 'community_gallery.dart';

const _communityGap = SizedBox(height: 16);
const _communitySmallGap = SizedBox(height: 8);

String _postLocation(String id) => '/community/post/${Uri.encodeComponent(id)}';

int _communityIdentityHash(String identity) => identity.codeUnits.fold<int>(
  0,
  (hash, unit) => (hash * 31 + unit) & 0x7fffffff,
);

String _communityFirstParagraph(String value) => value
    .trim()
    .split(RegExp(r'\r?\n\s*\r?\n'))
    .first
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

void _communityLogin(BuildContext context, String destination) {
  context.push(
    Uri(path: '/login', queryParameters: {'returnTo': destination}).toString(),
  );
}

void _communityBack(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go('/community');
  }
}

String _communityDate(DateTime value) {
  final date = value.toLocal();
  final now = DateTime.now();
  final prefix = date.year == now.year ? '' : '${date.year}年';
  return '$prefix${date.month}月${date.day}日 ${formatTime(date)}';
}

class _CommunityStatus extends StatelessWidget {
  const _CommunityStatus(this.message, {this.retry, this.busy = false});
  final String message;
  final VoidCallback? retry;
  final bool busy;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (busy) ...[
          const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          _communitySmallGap,
        ],
        Semantics(
          liveRegion: true,
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: SeraColors.muted),
          ),
        ),
        if (retry != null) ...[
          _communitySmallGap,
          SeraButton('重试', variant: 'quiet', onPressed: retry),
        ],
      ],
    ),
  );
}

class _OfficialTag extends StatelessWidget {
  const _OfficialTag();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: SeraColors.mint,
      borderRadius: BorderRadius.circular(6),
    ),
    child: const Text(
      '官方',
      style: TextStyle(color: SeraColors.brand, fontSize: 12),
    ),
  );
}

class _CommunityAvatar extends StatelessWidget {
  const _CommunityAvatar({
    required this.name,
    this.id,
    this.authorIsOfficial = false,
    this.radius = 18,
  });
  final String name;
  final String? id;
  final bool authorIsOfficial;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final identity = id?.isNotEmpty == true ? id! : name.trim();
    // The same author keeps the same color across records and app restarts.
    final hash = _communityIdentityHash(identity);
    const colors = [
      SeraColors.brand,
      SeraColors.blue,
      SeraColors.amber,
      SeraColors.muted,
    ];
    final color = colors[hash % colors.length];
    final initial = name.trim().isEmpty ? '友' : name.trim().characters.first;
    return Semantics(
      image: true,
      label: '$name的头像',
      child: ExcludeSemantics(
        child: CircleAvatar(
          key: ValueKey('community-avatar:$identity'),
          radius: radius,
          backgroundColor: authorIsOfficial
              ? SeraColors.mint
              : color.withValues(alpha: .1),
          foregroundColor: color,
          child: authorIsOfficial
              ? Image.asset(
                  'assets/brand/brand-sera-mark@3x.png',
                  width: radius * 1.05,
                  height: radius * 1.17,
                )
              : Text(
                  initial,
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    fontSize: radius * .84,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        ),
      ),
    );
  }
}

class _EventInformation extends StatelessWidget {
  const _EventInformation({required this.post});
  final CommunityPost post;

  @override
  Widget build(BuildContext context) {
    final date = post.startsAt?.toLocal();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: SeraColors.mint,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (date != null) ...[
            ExcludeSemantics(
              child: SizedBox(
                width: 48,
                child: Column(
                  children: [
                    Text(
                      '${date.month}月',
                      style: const TextStyle(fontSize: 12),
                    ),
                    Text(
                      '${date.day}',
                      style: const TextStyle(
                        fontSize: 28,
                        height: 1.15,
                        fontWeight: FontWeight.w600,
                        color: SeraColors.brand,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(date == null ? '活动' : _communityDate(date)),
                if (post.place.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    post.place,
                    style: const TextStyle(color: SeraColors.mutedOnMint),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

bool _communityOwns(
  BuildContext context,
  CommunityController controller,
  Object owner, {
  ModalRoute<dynamic>? route,
}) =>
    context.mounted &&
    identical(context.read<CommunityController>(), controller) &&
    controller.sessionOwner == owner &&
    (route == null || route.isCurrent);

class _PostContent extends StatelessWidget {
  const _PostContent({required this.post});
  final CommunityPost post;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (post.media.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _CommunityTextCover(post: post, fullText: true),
        )
      else
        _CommunityGallery(
          key: ValueKey('community-gallery-${post.id}'),
          post: post,
          controller: context.read<CommunityController>(),
          owner: context.read<CommunityController>().sessionOwner,
        ),
      const SizedBox(height: 20),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (post.category == 'feedback' || post.isOfficial) ...[
              Wrap(
                spacing: 8,
                children: [
                  if (post.category == 'feedback') const SeraTag('使用反馈'),
                  if (post.isOfficial && !post.authorIsOfficial)
                    const _OfficialTag(),
                ],
              ),
              _communitySmallGap,
            ],
            if (post.media.isNotEmpty && post.title.trim().isNotEmpty) ...[
              Text(
                post.title,
                style: const TextStyle(
                  fontSize: 20,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
              _communitySmallGap,
            ],
            SelectableText(
              post.content,
              style: const TextStyle(fontSize: 16, height: 1.65),
            ),
            const SizedBox(height: 14),
            Text(
              _communityDate(post.createdAt),
              style: const TextStyle(fontSize: 12, color: SeraColors.muted),
            ),
            if (post.isActivity) ...[
              _communityGap,
              _EventInformation(post: post),
            ],
          ],
        ),
      ),
    ],
  );
}

class _CommunityCommentRow extends StatelessWidget {
  const _CommunityCommentRow({super.key, required this.comment, this.onDelete});
  final CommunityComment comment;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CommunityAvatar(
          id: comment.authorId,
          name: comment.authorName,
          authorIsOfficial: comment.authorIsOfficial,
          radius: 17,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 7,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    comment.authorName,
                    style: const TextStyle(
                      color: SeraColors.muted,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (comment.isOfficial) const _OfficialTag(),
                  if (!comment.isOfficial && comment.isAdmin)
                    const Text(
                      '社区管理员',
                      style: TextStyle(fontSize: 11, color: SeraColors.muted),
                    ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                comment.content,
                style: const TextStyle(fontSize: 15, height: 1.55),
              ),
              const SizedBox(height: 7),
              Wrap(
                spacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    _communityDate(comment.createdAt),
                    style: const TextStyle(
                      fontSize: 12,
                      color: SeraColors.muted,
                    ),
                  ),
                  if (comment.canDelete)
                    TextButton(
                      onPressed: onDelete,
                      style: TextButton.styleFrom(
                        foregroundColor: SeraColors.muted,
                        textStyle: const TextStyle(fontSize: 12),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: const Text('删除评论'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _CommunityImage extends StatefulWidget {
  const _CommunityImage({
    required this.media,
    this.fit = BoxFit.cover,
    this.backgroundColor = SeraColors.mint,
  });
  final CommunityMedia media;
  final BoxFit fit;
  final Color backgroundColor;

  @override
  State<_CommunityImage> createState() => _CommunityImageState();
}

class _CommunityImageState extends State<_CommunityImage> {
  int _attempt = 0;

  Future<void> _retry(String url) async {
    await NetworkImage(url).evict();
    if (mounted) {
      setState(() => _attempt++);
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = context.read<CommunityController>().resolveMediaUrl(
      widget.media.url,
    );
    return ColoredBox(
      color: widget.backgroundColor,
      child: Image.network(
        url,
        key: ValueKey('${widget.media.id}:$_attempt'),
        fit: widget.fit,
        width: double.infinity,
        height: double.infinity,
        semanticLabel: '动态图片',
        loadingBuilder: (context, child, progress) => progress == null
            ? child
            : const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
        errorBuilder: (context, error, stack) => Center(
          child: IconButton(
            tooltip: '重新加载图片',
            onPressed: () => _retry(url),
            icon: const Icon(Icons.refresh, color: SeraColors.muted),
          ),
        ),
      ),
    );
  }
}

class _CommunityFeedCard extends StatelessWidget {
  const _CommunityFeedCard({
    super.key,
    required this.post,
    required this.onOpen,
    required this.onLike,
  });
  final CommunityPost post;
  final VoidCallback onOpen;
  final VoidCallback? onLike;

  @override
  Widget build(BuildContext context) {
    // A text cover already carries the title. The caption adds the beginning of
    // the actual post instead of repeating the same headline below it.
    final excerpt = post.media.isEmpty && post.title.trim().isNotEmpty
        ? _communityFirstParagraph(post.content)
        : post.title.trim().isNotEmpty
        ? post.title.trim()
        : _communityFirstParagraph(post.content);
    final caption = post.isActivity && post.startsAt != null
        ? '${_communityDate(post.startsAt!)} · $excerpt'
        : excerpt;
    final photo = post.media.isEmpty ? null : post.media.first;
    // Let each photograph set its own height. Only malformed dimensions and
    // extreme strips need a bound so a cover cannot consume many screens.
    final coverRatio = photo == null || photo.width <= 0 || photo.height <= 0
        ? .75
        : (photo.width / photo.height).clamp(.25, 4.0).toDouble();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: coverRatio,
              child: ClipRRect(
                key: ValueKey('community-cover-${post.id}'),
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (post.media.isNotEmpty)
                      _CommunityImage(media: post.media.first)
                    else
                      _CommunityTextCover(post: post),
                    if (post.media.length > 1 ||
                        post.isActivity ||
                        post.isOfficial ||
                        post.category == 'feedback')
                      Positioned(
                        top: 8,
                        left: 8,
                        right: 8,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (post.isActivity ||
                                post.isOfficial ||
                                post.category == 'feedback')
                              Flexible(
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Container(
                                    key: ValueKey(
                                      'community-post-type-${post.id}',
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(
                                        alpha: .94,
                                      ),
                                      borderRadius: BorderRadius.circular(5),
                                    ),
                                    child: Text(
                                      post.isActivity
                                          ? '活动'
                                          : post.category == 'feedback'
                                          ? '使用反馈'
                                          : '官方',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: SeraColors.brand,
                                      ),
                                    ),
                                  ),
                                ),
                              )
                            else
                              const Spacer(),
                            if (post.media.length > 1) ...[
                              const SizedBox(width: 6),
                              Semantics(
                                key: ValueKey('community-multi-${post.id}'),
                                label: '${post.media.length} 张图片',
                                child: Container(
                                  key: ValueKey(
                                    'community-media-count-${post.id}',
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: .45),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: ExcludeSemantics(
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          Icons.photo_library_outlined,
                                          size: 12,
                                          color: Colors.white,
                                        ),
                                        const SizedBox(width: 3),
                                        Text(
                                          '${post.media.length}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 11,
                                            height: 1.2,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
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
            Padding(
              padding: const EdgeInsets.fromLTRB(3, 7, 3, 0),
              child: Text(
                caption,
                key: ValueKey('community-caption-${post.id}'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Row(
                  children: [
                    _CommunityAvatar(
                      id: post.authorId,
                      name: post.authorName,
                      authorIsOfficial: post.authorIsOfficial,
                      radius: 10,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        post.authorName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: SeraColors.muted,
                        ),
                      ),
                    ),
                    Tooltip(
                      message: post.liked ? '取消点赞' : '点赞',
                      child: TextButton(
                        key: ValueKey('community-like-${post.id}'),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          minimumSize: const Size(40, 44),
                        ),
                        onPressed: onLike,
                        child: Semantics(
                          label:
                              '${post.liked ? '已赞' : '点赞'} ${post.likeCount}',
                          child: ExcludeSemantics(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  post.liked
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  size: 14,
                                ),
                                const SizedBox(width: 2),
                                Text(
                                  '${post.likeCount}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

/// Text stays selectable by accessibility services and scales with the device.
/// Only the preview is shortened; the post detail retains the complete content.
class _CommunityTextCover extends StatelessWidget {
  const _CommunityTextCover({required this.post, this.fullText = false});
  final CommunityPost post;
  final bool fullText;

  @override
  Widget build(BuildContext context) {
    const colors = [
      Color(0xFFFFFCF4),
      Color(0xFFF3F6F0),
      Color(0xFFFAF2E9),
      Color(0xFFF2F5F5),
    ];
    final headline = post.title.trim().isNotEmpty
        ? post.title.trim()
        : _communityFirstParagraph(post.content);
    final color = colors[_communityIdentityHash(post.id) % colors.length];
    final hasTag =
        post.isActivity || post.isOfficial || post.category == 'feedback';
    final scaler = MediaQuery.textScalerOf(context);
    final tagHeight = hasTag && !fullText ? scaler.scale(11) * 1.5 + 18 : 0.0;
    final fontSize = headline.characters.length <= 12
        ? 32.0
        : headline.characters.length <= 24
        ? 28.0
        : 26.0;
    final style = DefaultTextStyle.of(context).style.copyWith(
      color: SeraColors.ink,
      fontSize: fontSize,
      height: 1.22,
      fontWeight: FontWeight.w700,
    );
    return LayoutBuilder(
      builder: (context, coverConstraints) => DecoratedBox(
        key: ValueKey('community-text-cover-${post.id}'),
        decoration: BoxDecoration(
          color: color,
          border: Border.all(color: const Color(0xFFE8E9E2)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: fullText ? coverConstraints.maxWidth * 5 / 4 : 0,
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, tagHeight + 16, 16, 16),
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (fullText) {
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      headline,
                      key: ValueKey('community-cover-headline-${post.id}'),
                      style: style,
                    ),
                  );
                }
                // Measure with the real font and system scaling. Fewer lines at
                // large text sizes preserve readable type instead of shrinking it.
                var maxLines = 5;
                final painter = TextPainter(
                  text: TextSpan(text: headline, style: style),
                  textDirection: Directionality.of(context),
                  textScaler: scaler,
                  locale: Localizations.maybeLocaleOf(context),
                  ellipsis: '…',
                );
                while (maxLines > 1) {
                  painter.maxLines = maxLines;
                  painter.layout(maxWidth: constraints.maxWidth);
                  if (painter.height <= constraints.maxHeight) break;
                  maxLines--;
                }
                painter.dispose();
                return Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    headline,
                    key: ValueKey('community-cover-headline-${post.id}'),
                    maxLines: maxLines,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Public reading stays available without an account. Mutations require login.
class CommunityFeedScreen extends StatefulWidget {
  const CommunityFeedScreen({super.key});

  @override
  State<CommunityFeedScreen> createState() => _CommunityFeedScreenState();
}

class _CommunityFeedScreenState extends State<CommunityFeedScreen> {
  final _scrollController = ScrollController();
  CommunityController? _controller;
  Object? _owner;
  String? _error;
  bool _userScroll = false, _gestureHandled = false, _readQueued = false;
  bool _retryMore = false;
  double _bottomPull = 0;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = context.read<CommunityController>();
    if (identical(controller, _controller) &&
        _owner == controller.sessionOwner) {
      return;
    }
    _controller = controller;
    _owner = controller.sessionOwner;
    _error = null;
    _userScroll = _gestureHandled = _readQueued = false;
    _bottomPull = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_controller, controller)) {
        unawaited(_read(() => controller.load()));
      }
    });
  }

  Future<void> _read(
    Future<void> Function() action, {
    bool more = false,
  }) async {
    final controller = context.read<CommunityController>();
    final owner = controller.sessionOwner;
    if (mounted) {
      setState(() {
        _error = null;
        _retryMore = more;
      });
    }
    try {
      await action();
    } catch (error) {
      if (mounted && _communityOwns(context, controller, owner)) {
        setState(() => _error = '$error');
      }
    }
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _userScroll = true;
      _gestureHandled = false;
      _bottomPull = 0;
    }
    if (notification is UserScrollNotification &&
        notification.direction != ScrollDirection.idle) {
      if (!_userScroll) {
        _gestureHandled = false;
        _bottomPull = 0;
      }
      _userScroll = true;
    }
    if (notification is ScrollEndNotification) {
      _userScroll = false;
      return false;
    }
    if (!_userScroll || _gestureHandled || _readQueued) {
      return false;
    }
    final controller = context.read<CommunityController>();
    if (controller.loading || controller.loadingMore) {
      return false;
    }
    final movingUp =
        notification is ScrollUpdateNotification &&
            (notification.scrollDelta ?? 0) > 0 ||
        notification is OverscrollNotification && notification.overscroll > 0;
    if (!movingUp) {
      return false;
    }
    if (controller.nextCursor != null &&
        notification.metrics.extentAfter <= 160) {
      _queueScrollRead(controller, more: true);
    } else if (controller.nextCursor == null) {
      if (notification is OverscrollNotification &&
          notification.dragDetails != null) {
        _bottomPull += notification.overscroll;
      } else if (notification is ScrollUpdateNotification &&
          notification.dragDetails != null) {
        // Bouncing platforms report a dragged position beyond the boundary.
        _bottomPull =
            notification.metrics.pixels - notification.metrics.maxScrollExtent;
      }
      if (_bottomPull >= 32) {
        _queueScrollRead(controller, more: false);
      }
    }
    return false;
  }

  void _queueScrollRead(CommunityController controller, {required bool more}) {
    _gestureHandled = true;
    _readQueued = true;
    final owner = controller.sessionOwner;
    final filter = controller.filter;
    final route = ModalRoute.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _readQueued = false;
      if (!mounted ||
          !_communityOwns(context, controller, owner, route: route) ||
          controller.filter != filter ||
          controller.loading ||
          controller.loadingMore) {
        return;
      }
      unawaited(
        _read(
          more
              ? controller.loadMore
              : () => controller.refresh(preserveLoaded: true),
          more: more,
        ),
      );
    });
  }

  void _compose(CommunityController controller) {
    if (!controller.viewer.signedIn) {
      _communityLogin(context, '/community/compose');
    } else {
      context.push('/community/compose');
    }
  }

  Future<void> _like(CommunityController controller, CommunityPost post) async {
    if (!controller.viewer.signedIn) {
      _communityLogin(context, _postLocation(post.id));
      return;
    }
    final owner = controller.sessionOwner;
    final route = ModalRoute.of(context);
    try {
      await controller.setLike(post.id, !post.liked);
    } catch (error) {
      if (mounted && _communityOwns(context, controller, owner, route: route)) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<CommunityController>();
    final error = _error ?? controller.error;
    final postIndices = {
      for (var index = 0; index < controller.posts.length; index++)
        ValueKey('community-post-${controller.posts[index].id}'): index,
    };
    return RefreshIndicator(
      onRefresh: () => _read(() => controller.refresh(preserveLoaded: true)),
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            physics: AlwaysScrollableScrollPhysics(
              parent: ScrollConfiguration.of(context).getScrollPhysics(context),
            ),
          ),
          child: SeraScaffold(
            title: '社区',
            surfaceColor: Colors.white,
            contentPadding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
            navIndex: 3,
            showBack: false,
            actions: [
              if (controller.viewer.isOfficial || controller.viewer.isAdmin)
                IconButton(
                  tooltip: '社区管理',
                  onPressed: () => context.push('/community/manage'),
                  icon: const Icon(Icons.admin_panel_settings_outlined),
                ),
              IconButton(
                tooltip: '发布',
                onPressed: () => _compose(controller),
                icon: const Icon(Icons.edit_outlined),
              ),
            ],
            scrollKey: const PageStorageKey('community-feed'),
            scrollController: _scrollController,
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final option in const {
                        'all': '最新',
                        'feedback': '使用反馈',
                        'official': '官方',
                      }.entries)
                        Semantics(
                          selected: controller.filter == option.key,
                          child: TextButton(
                            key: ValueKey('community-filter-${option.key}'),
                            style: TextButton.styleFrom(
                              foregroundColor: controller.filter == option.key
                                  ? SeraColors.brand
                                  : SeraColors.muted,
                              shape: const RoundedRectangleBorder(),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                            ),
                            onPressed: controller.loading
                                ? null
                                : () => _read(
                                    () => controller.load(filter: option.key),
                                  ),
                            child: Container(
                              padding: const EdgeInsets.only(bottom: 6),
                              decoration: BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(
                                    width: 2,
                                    color: controller.filter == option.key
                                        ? SeraColors.brand
                                        : Colors.transparent,
                                  ),
                                ),
                              ),
                              child: Text(option.value),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (controller.loading && controller.posts.isEmpty)
                const SliverToBoxAdapter(
                  child: _CommunityStatus('正在加载社区', busy: true),
                )
              else if (controller.posts.isEmpty && error == null)
                SliverToBoxAdapter(
                  child: _CommunityStatus(
                    controller.filter == 'official'
                        ? '还没有官方动态'
                        : controller.filter == 'feedback'
                        ? '还没有使用反馈'
                        : '还没有动态，分享你的第一条想法吧。',
                  ),
                ),
              SliverMasonryGrid(
                gridDelegate:
                    const SliverSimpleGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                    ),
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final post = controller.posts[index];
                    return _CommunityFeedCard(
                      key: ValueKey('community-post-${post.id}'),
                      post: post,
                      onOpen: () => context.push(_postLocation(post.id)),
                      onLike: controller.isBusy(post.id)
                          ? null
                          : () => _like(controller, post),
                    );
                  },
                  childCount: controller.posts.length,
                  findChildIndexCallback: (key) => postIndices[key],
                ),
              ),
              if (error != null)
                SliverToBoxAdapter(
                  child: _CommunityStatus(
                    error,
                    retry: () => _retryMore && controller.nextCursor != null
                        ? _read(controller.loadMore, more: true)
                        : _read(() => controller.refresh(preserveLoaded: true)),
                  ),
                )
              else if (controller.nextCursor != null)
                SliverToBoxAdapter(
                  child: SeraButton(
                    '加载更多',
                    variant: 'quiet',
                    busy: controller.loading || controller.loadingMore,
                    onPressed: controller.loading || controller.loadingMore
                        ? null
                        : () => _read(controller.loadMore, more: true),
                  ),
                )
              else if (!controller.loading || controller.posts.isNotEmpty)
                SliverToBoxAdapter(
                  child: TextButton(
                    key: const ValueKey('community-refresh-bottom'),
                    onPressed: controller.loading
                        ? null
                        : () => _read(
                            () => controller.refresh(preserveLoaded: true),
                          ),
                    child: Text(controller.loading ? '正在更新' : '上拉更新'),
                  ),
                ),
              if (!controller.viewer.isOfficial && !controller.viewer.isAdmin)
                SliverToBoxAdapter(
                  child: TextButton(
                    onPressed: () => controller.viewer.signedIn
                        ? context.push('/community/manage')
                        : _communityLogin(context, '/community/manage'),
                    child: const Text('申请管理社区'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class CommunityDetailScreen extends StatefulWidget {
  const CommunityDetailScreen({super.key, required this.postId});
  final String postId;

  @override
  State<CommunityDetailScreen> createState() => _CommunityDetailScreenState();
}

class _CommunityDetailScreenState extends State<CommunityDetailScreen> {
  final _comment = TextEditingController();
  CommunityController? _controller;
  Object? _owner;
  String? _error;
  String _commentRequest = '';
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _comment.addListener(() {
      if (mounted) {
        setState(() {
          _commentRequest = 'comment-${DateTime.now().microsecondsSinceEpoch}';
        });
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = context.read<CommunityController>();
    if (identical(controller, _controller) &&
        _owner == controller.sessionOwner) {
      return;
    }
    _controller = controller;
    _owner = controller.sessionOwner;
    _comment.clear();
    _sending = false;
    _error = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(controller, _controller)) {
        unawaited(_read(() => controller.loadDetail(widget.postId)));
      }
    });
  }

  @override
  void didUpdateWidget(CommunityDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.postId != widget.postId) {
      _comment.clear();
      _error = null;
      _sending = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_read(() => _controller!.loadDetail(widget.postId)));
        }
      });
    }
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _read(Future<void> Function() action) async {
    final controller = context.read<CommunityController>();
    final owner = controller.sessionOwner;
    final postId = widget.postId;
    setState(() => _error = null);
    try {
      await action();
    } catch (error) {
      if (mounted &&
          _communityOwns(context, controller, owner) &&
          widget.postId == postId) {
        setState(() => _error = '$error');
      }
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    final controller = context.read<CommunityController>();
    if (!controller.viewer.signedIn) {
      _communityLogin(context, _postLocation(widget.postId));
      return;
    }
    final owner = controller.sessionOwner;
    final route = ModalRoute.of(context);
    final postId = widget.postId;
    if (controller.isBusy(postId)) return;
    setState(() => _error = null);
    try {
      await action();
    } catch (error) {
      if (mounted &&
          _communityOwns(context, controller, owner, route: route) &&
          widget.postId == postId) {
        setState(() => _error = '$error');
      }
    }
  }

  Future<void> _send() async {
    final controller = context.read<CommunityController>();
    final content = _comment.text.trim();
    if (_sending ||
        content.isEmpty ||
        content.length > 1000 ||
        controller.isBusy(widget.postId)) {
      return;
    }
    if (!controller.viewer.signedIn) {
      _communityLogin(context, _postLocation(widget.postId));
      return;
    }
    final owner = controller.sessionOwner;
    final route = ModalRoute.of(context);
    final postId = widget.postId;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await controller.comment(postId, content, requestId: _commentRequest);
      if (mounted &&
          _communityOwns(context, controller, owner, route: route) &&
          widget.postId == postId) {
        _comment.clear();
        FocusManager.instance.primaryFocus?.unfocus();
      }
    } catch (error) {
      if (mounted &&
          _communityOwns(context, controller, owner, route: route) &&
          widget.postId == postId) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted &&
          _communityOwns(context, controller, owner) &&
          widget.postId == postId) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _delete({CommunityComment? comment}) async {
    final controller = context.read<CommunityController>();
    final owner = controller.sessionOwner;
    final route = ModalRoute.of(context);
    final postId = widget.postId;
    final confirmed = await showDialog<bool>(
      context: context,
      animationStyle: SeraMotion.dialogStyle(context),
      builder: (context) => AlertDialog(
        title: Text(comment == null ? '删除这条动态？' : '删除这条评论？'),
        content: Text(comment == null ? '动态及其评论、报名记录会一并删除，无法恢复。' : '删除后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        !_communityOwns(context, controller, owner, route: route) ||
        widget.postId != postId) {
      return;
    }
    await _act(() async {
      if (comment == null) {
        await controller.deletePost(postId);
        if (mounted &&
            _communityOwns(context, controller, owner, route: route) &&
            widget.postId == postId) {
          context.go('/community');
        }
      } else {
        await controller.deleteComment(postId, comment.id);
      }
    });
  }

  Widget _detailFooter({
    required CommunityController controller,
    required CommunityPost post,
    required bool busy,
  }) {
    final like = TextButton.icon(
      key: const ValueKey('community-detail-like'),
      onPressed: busy
          ? null
          : () => _act(() => controller.setLike(post.id, !post.liked)),
      style: TextButton.styleFrom(
        foregroundColor: post.liked ? SeraColors.brand : SeraColors.ink,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(48, 48),
        textStyle: const TextStyle(fontSize: 13),
      ),
      icon: Icon(post.liked ? Icons.favorite : Icons.favorite_border, size: 22),
      label: Text('${post.liked ? '已赞' : '点赞'} ${post.likeCount}'),
    );
    final input = !controller.viewer.signedIn
        ? SeraButton(
            '登录后参与讨论',
            variant: 'secondary',
            onPressed: () => _communityLogin(context, _postLocation(post.id)),
          )
        : TextField(
            key: const ValueKey('community-comment-input'),
            controller: _comment,
            enabled: !_sending,
            minLines: 1,
            maxLines: 3,
            maxLength: 1000,
            style: const TextStyle(fontSize: 14, height: 1.5),
            decoration: InputDecoration(
              labelText: '写评论',
              hintText: '说点什么…',
              counterText: '',
              filled: true,
              fillColor: const Color(0xFFF5F6F4),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(22),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(22),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(22),
                borderSide: const BorderSide(color: SeraColors.brand),
              ),
            ),
          );
    final inputRow = Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(child: input),
        if (controller.viewer.signedIn) ...[
          const SizedBox(width: 4),
          IconButton(
            tooltip: '发送评论',
            onPressed: busy || _comment.text.trim().isEmpty ? null : _send,
            icon: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send_outlined, color: SeraColors.brand),
          ),
        ],
      ],
    );
    // Make room for readable input at large font sizes rather than squeezing
    // the editor between fixed actions on a narrow screen.
    if (MediaQuery.textScalerOf(context).scale(14) > 18) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          inputRow,
          Align(alignment: Alignment.centerRight, child: like),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(child: inputRow),
        const SizedBox(width: 4),
        like,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<CommunityController>();
    final detail = controller.detail(widget.postId);
    final post = detail?.post;
    final loading = controller.isDetailLoading(widget.postId);
    final busy = controller.isBusy(widget.postId) || _sending;
    final error = _error ?? controller.error;
    return SeraScaffold(
      title: post?.isActivity == true ? '活动详情' : '动态详情',
      titleContent: post == null
          ? null
          : Row(
              key: const ValueKey('community-detail-author'),
              children: [
                _CommunityAvatar(
                  id: post.authorId,
                  name: post.authorName,
                  authorIsOfficial: post.authorIsOfficial,
                  radius: 16,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    post.authorName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (post.authorIsOfficial) const _OfficialTag(),
              ],
            ),
      surfaceColor: Colors.white,
      onBack: () => _communityBack(context),
      contentPadding: const EdgeInsets.only(top: 4, bottom: 24),
      actions: [
        if (post?.canDelete == true)
          TextButton(
            onPressed: busy ? null : () => _delete(),
            style: TextButton.styleFrom(foregroundColor: SeraColors.muted),
            child: const Text('删除动态'),
          ),
      ],
      slivers: [
        if (post == null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _CommunityStatus(
                loading ? '正在加载动态' : error ?? '这条动态暂时无法查看',
                busy: loading,
                retry: loading
                    ? null
                    : () => _read(() => controller.loadDetail(widget.postId)),
              ),
            ),
          )
        else ...[
          SliverToBoxAdapter(child: _PostContent(post: post)),
          if (post.isActivity)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${post.participantCount} 人报名',
                      style: const TextStyle(
                        color: SeraColors.muted,
                        fontSize: 13,
                      ),
                    ),
                    _communitySmallGap,
                    SeraButton(
                      post.joined ? '取消报名' : '报名参加',
                      variant: post.joined ? 'secondary' : 'primary',
                      busy: busy,
                      onPressed: busy
                          ? null
                          : () => _act(
                              () => controller.setJoin(post.id, !post.joined),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Divider(height: 1, color: SeraColors.line),
                  const SizedBox(height: 18),
                  Text(
                    '共 ${post.commentCount} 条评论',
                    key: const ValueKey('community-comment-count'),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (detail!.comments.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 22, horizontal: 20),
                child: Text(
                  '还没有评论，聊聊你的想法吧',
                  style: TextStyle(color: SeraColors.muted, fontSize: 14),
                ),
              ),
            ),
          SliverList.builder(
            itemCount: detail.comments.length,
            itemBuilder: (context, index) {
              final comment = detail.comments[index];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: _CommunityCommentRow(
                  key: ValueKey('community-comment-${comment.id}'),
                  comment: comment,
                  onDelete: busy ? null : () => _delete(comment: comment),
                ),
              );
            },
          ),
          if (detail.commentsNextCursor != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: SeraButton(
                  '更多评论',
                  variant: 'quiet',
                  busy: loading,
                  onPressed: loading
                      ? null
                      : () => _read(() => controller.loadMoreComments(post.id)),
                ),
              ),
            ),
          if (error != null && !controller.viewer.signedIn)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: _CommunityStatus(
                  error,
                  retry: () => _read(() => controller.loadDetail(post.id)),
                ),
              ),
            ),
        ],
      ],
      footer: post == null
          ? null
          : Column(
              key: const ValueKey('community-detail-footer'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (error != null && controller.viewer.signedIn) ...[
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      error,
                      style: const TextStyle(
                        color: SeraColors.red,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  _communitySmallGap,
                ],
                _detailFooter(controller: controller, post: post, busy: busy),
              ],
            ),
    );
  }
}

class CommunityComposeScreen extends StatefulWidget {
  const CommunityComposeScreen({
    super.key,
    this.imagePicker,
    this.imageRecovery,
    this.desktopMode = false,
    this.onPublished,
    this.onDirtyChanged,
  });
  final Future<List<CommunityImageSelection>> Function(int limit)? imagePicker;
  final Future<List<CommunityImageSelection>> Function(int limit)?
  imageRecovery;
  final bool desktopMode;
  final ValueChanged<CommunityPost>? onPublished;
  final ValueChanged<bool>? onDirtyChanged;

  @override
  State<CommunityComposeScreen> createState() => _CommunityComposeScreenState();
}

class _CommunityImageDraft {
  _CommunityImageDraft(this.selection) : requestId = selection.id;
  final CommunityImageSelection selection;
  String requestId;
  CommunityMedia? media;
  String? error;
  bool uploading = false;
}

class _CommunityComposeScreenState extends State<CommunityComposeScreen> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _content = TextEditingController();
  final _place = TextEditingController();
  CommunityController? _controller;
  Object? _owner;
  String _type = 'post';
  DateTime? _startsAt;
  String? _error;
  String _requestId = '';
  bool _saving = false, _leaving = false, _allowExit = false;
  bool _pickingImages = false;
  final _images = <_CommunityImageDraft>[];
  String? _imageNotice;
  bool get _uploading => _images.any((image) => image.uploading);
  bool get _imagesReady => _images.every((image) => image.media != null);

  bool get _hasInput =>
      _title.text.trim().isNotEmpty ||
      _content.text.trim().isNotEmpty ||
      _place.text.trim().isNotEmpty ||
      _startsAt != null ||
      _images.isNotEmpty;

  @override
  void initState() {
    super.initState();
    for (final field in [_title, _content, _place]) {
      field.addListener(_changed);
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      _requestId = 'post-${DateTime.now().microsecondsSinceEpoch}';
    });
    _notifyDirty();
  }

  void _notifyDirty() {
    final owner = _owner;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && owner == _owner) {
        widget.onDirtyChanged?.call(_hasInput);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = context.read<CommunityController>();
    if (identical(controller, _controller) &&
        _owner == controller.sessionOwner) {
      return;
    }
    _controller = controller;
    _owner = controller.sessionOwner;
    _title.clear();
    _content.clear();
    _place.clear();
    _type = widget.desktopMode ? 'official' : 'post';
    _startsAt = null;
    _saving = false;
    _error = null;
    _allowExit = false;
    _images.clear();
    _pickingImages = false;
    _imageNotice = null;
    _notifyDirty();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final owner = controller.sessionOwner;
      try {
        if (mounted && identical(controller, _controller)) {
          await controller.load();
          if (mounted && _communityOwns(context, controller, owner)) {
            if (widget.desktopMode &&
                !controller.viewer.permissions.publishOfficial &&
                controller.viewer.permissions.publishActivity) {
              setState(() => _type = 'activity');
            }
            await _recoverImages(controller);
          }
        }
      } catch (error) {
        if (mounted && _communityOwns(context, controller, owner)) {
          setState(() => _error = '$error');
        }
      }
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    _place.dispose();
    super.dispose();
  }

  Future<void> _recoverImages(CommunityController controller) async {
    final owner = controller.sessionOwner;
    final scope = controller.stableSessionScope;
    final route = ModalRoute.of(context);
    if (scope == null || _images.isNotEmpty || _pickingImages) {
      return;
    }
    setState(() => _pickingImages = true);
    try {
      final selected =
          await (widget.imageRecovery?.call(3) ??
              recoverCommunityImages(scope, limit: 3));
      if (!mounted ||
          !_communityOwns(context, controller, owner, route: route) ||
          controller.stableSessionScope != scope) {
        return;
      }
      if (selected.isNotEmpty) {
        setState(() {
          _imageNotice = '已恢复上次选择的图片，请检查后发布。';
        });
        await _addImages(selected, controller, owner);
      }
    } catch (error) {
      if (mounted && _communityOwns(context, controller, owner, route: route)) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted && _communityOwns(context, controller, owner)) {
        setState(() => _pickingImages = false);
      }
    }
  }

  Future<void> _pickImages() async {
    if (_saving || _pickingImages || _uploading || _images.length >= 3) {
      return;
    }
    final controller = context.read<CommunityController>();
    final owner = controller.sessionOwner;
    final scope = controller.stableSessionScope;
    final route = ModalRoute.of(context);
    setState(() {
      _pickingImages = true;
      _error = null;
    });
    try {
      final selected = widget.imagePicker != null
          ? await widget.imagePicker!(3 - _images.length)
          : scope == null
          ? <CommunityImageSelection>[]
          : await pickCommunityImages(owner: scope, limit: 3 - _images.length);
      if (!mounted ||
          !_communityOwns(context, controller, owner, route: route) ||
          controller.stableSessionScope != scope) {
        return;
      }
      await _addImages(selected, controller, owner);
    } catch (error) {
      if (mounted && _communityOwns(context, controller, owner, route: route)) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted && _communityOwns(context, controller, owner)) {
        setState(() => _pickingImages = false);
      }
    }
  }

  Future<void> _addImages(
    List<CommunityImageSelection> selected,
    CommunityController controller,
    Object owner,
  ) async {
    if (selected.isEmpty) {
      return;
    }
    final remaining = 3 - _images.length;
    final added = selected
        .take(remaining)
        .map(_CommunityImageDraft.new)
        .toList();
    setState(() {
      _images.addAll(added);
      _requestId = 'post-${DateTime.now().microsecondsSinceEpoch}';
      if (selected.length > remaining) {
        _imageNotice = '每条动态最多 3 张图片，已保留前 3 张。';
      }
    });
    _notifyDirty();
    for (final image in added) {
      if (!mounted || !_communityOwns(context, controller, owner)) {
        return;
      }
      await _uploadImage(image);
    }
  }

  Future<void> _uploadImage(_CommunityImageDraft image) async {
    if (image.uploading || !_images.contains(image)) {
      return;
    }
    final controller = context.read<CommunityController>();
    final owner = controller.sessionOwner;
    setState(() {
      image.uploading = true;
      image.error = null;
    });
    try {
      final media = await controller.uploadImage(
        image.selection.bytes,
        mimeType: image.selection.mimeType,
        requestId: image.requestId,
      );
      if (mounted &&
          _communityOwns(context, controller, owner) &&
          _images.contains(image)) {
        setState(() => image.media = media);
      }
    } catch (error) {
      if (mounted &&
          _communityOwns(context, controller, owner) &&
          _images.contains(image)) {
        setState(() {
          image.error = '$error';
          if (error is RepositoryException &&
              error.details['code'] == 'community_media_expired') {
            image.requestId =
                '${image.selection.id}-${DateTime.now().microsecondsSinceEpoch}';
          }
        });
      }
    } finally {
      if (mounted &&
          _communityOwns(context, controller, owner) &&
          _images.contains(image)) {
        setState(() => image.uploading = false);
      }
    }
  }

  Widget _imageFields() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final (index, image) in _images.indexed)
            SizedBox(
              key: ValueKey('community-selected-${image.selection.id}'),
              width: 96,
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.memory(
                            image.selection.bytes,
                            fit: BoxFit.cover,
                            semanticLabel: '已选图片 ${index + 1}',
                            errorBuilder: (_, _, _) => const ColoredBox(
                              color: SeraColors.mint,
                              child: Icon(Icons.broken_image_outlined),
                            ),
                          ),
                          if (image.uploading)
                            const Center(child: CircularProgressIndicator()),
                          Positioned(
                            right: 0,
                            top: 0,
                            child: IconButton(
                              tooltip: '移除图片 ${index + 1}',
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.white,
                                minimumSize: const Size(44, 44),
                              ),
                              onPressed: _saving
                                  ? null
                                  : () {
                                      setState(() => _images.remove(image));
                                      _changed();
                                    },
                              icon: const Icon(Icons.close, size: 18),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (image.error != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      image.error!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: SeraColors.muted,
                      ),
                    ),
                    TextButton(
                      key: ValueKey(
                        'community-upload-retry-${image.selection.id}',
                      ),
                      onPressed: _saving ? null : () => _uploadImage(image),
                      child: const Text('重试上传'),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
      if (_images.isNotEmpty) _communitySmallGap,
      OutlinedButton.icon(
        key: const ValueKey('community-add-images'),
        onPressed:
            _saving || _pickingImages || _uploading || _images.length >= 3
            ? null
            : _pickImages,
        icon: const Icon(Icons.add_photo_alternate_outlined),
        label: Text(
          _uploading
              ? '正在上传图片'
              : _pickingImages
              ? '正在读取图片'
              : '添加图片（${_images.length}/3）',
        ),
      ),
      if (_imageNotice != null) ...[
        _communitySmallGap,
        Text(_imageNotice!, style: const TextStyle(color: SeraColors.muted)),
      ],
    ],
  );

  Future<void> _pickDate() async {
    final controller = context.read<CommunityController>();
    final owner = controller.sessionOwner;
    final route = ModalRoute.of(context);
    final today = DateUtils.dateOnly(DateTime.now());
    final date = await SeraMotion.pickDate(
      context: context,
      initialDate: _startsAt ?? today,
      firstDate: today,
      lastDate: DateTime(today.year + 2, today.month, today.day),
      confirmText: '继续',
      cancelText: '取消',
    );
    if (date == null ||
        !mounted ||
        !_communityOwns(context, controller, owner, route: route)) {
      return;
    }
    final time = await SeraMotion.pickTime(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_startsAt ?? DateTime.now()),
      confirmText: '确定',
      cancelText: '取消',
    );
    if (time == null ||
        !mounted ||
        !_communityOwns(context, controller, owner, route: route)) {
      return;
    }
    setState(() {
      _startsAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
      _requestId = 'post-${DateTime.now().microsecondsSinceEpoch}';
    });
    _notifyDirty();
  }

  Future<void> _publish() async {
    final controller = context.read<CommunityController>();
    final owner = controller.sessionOwner;
    final route = ModalRoute.of(context);
    if (_saving ||
        _pickingImages ||
        _uploading ||
        !_imagesReady ||
        _leaving ||
        !mounted ||
        !_communityOwns(context, controller, owner, route: route)) {
      return;
    }
    if (!controller.viewer.signedIn) {
      _communityLogin(context, '/community/compose');
      return;
    }
    final invalid = _form.currentState!.validateGranularly();
    if (invalid.isNotEmpty) {
      await Scrollable.ensureVisible(
        invalid.first.context,
        duration: SeraMotion.scrollDuration(context),
        alignment: .1,
      );
      return;
    }
    if (_type == 'activity' && _startsAt == null) {
      setState(() => _error = '请选择活动开始时间。');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final post = await controller.createPost(
        title: _title.text.trim(),
        content: _content.text.trim(),
        kind: _type == 'activity' ? 'activity' : 'post',
        category: _type == 'feedback' ? 'feedback' : 'daily',
        official: _type == 'official' || _type == 'activity',
        startsAt: _type == 'activity' ? _startsAt : null,
        place: _type == 'activity' ? _place.text.trim() : '',
        mediaIds: [for (final image in _images) image.media!.id],
        requestId: _requestId,
      );
      if (mounted && _communityOwns(context, controller, owner, route: route)) {
        setState(() => _allowExit = true);
        FocusManager.instance.primaryFocus?.unfocus();
        if (widget.desktopMode) {
          _title.clear();
          _content.clear();
          _place.clear();
          setState(() {
            _images.clear();
            _startsAt = null;
            _imageNotice = null;
          });
          _notifyDirty();
          widget.onPublished?.call(post);
        } else {
          context.replace(_postLocation(post.id));
        }
      }
    } catch (error) {
      if (mounted && _communityOwns(context, controller, owner, route: route)) {
        setState(() {
          _error = '$error';
          if (error is RepositoryException &&
              error.details['code'] == 'community_media_expired') {
            final expiredIds = error.details['mediaIds'];
            for (final image in _images) {
              if (expiredIds is! List || expiredIds.contains(image.media?.id)) {
                image.media = null;
                image.error = '图片已过期，请重新上传。';
                image.requestId =
                    '${image.selection.id}-${DateTime.now().microsecondsSinceEpoch}';
              }
            }
            _requestId = 'post-${DateTime.now().microsecondsSinceEpoch}';
          }
        });
      }
    } finally {
      if (mounted && _communityOwns(context, controller, owner)) {
        setState(() => _saving = false);
      }
    }
  }

  Widget _composeLayout({
    required String title,
    required VoidCallback onBack,
    required Widget body,
    Widget? footer,
  }) {
    if (!widget.desktopMode) {
      return SeraScaffold(
        title: title,
        onBack: onBack,
        body: body,
        footer: footer,
      );
    }
    return SingleChildScrollView(
      key: const ValueKey('admin-publish-form-scroll'),
      padding: const EdgeInsets.all(24),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              body,
              if (footer != null) ...[const SizedBox(height: 24), footer],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _leave() async {
    final controller = context.read<CommunityController>();
    final owner = controller.sessionOwner;
    final route = ModalRoute.of(context);
    if (_saving ||
        _leaving ||
        !mounted ||
        !_communityOwns(context, controller, owner, route: route)) {
      return;
    }
    _leaving = true;
    if (_hasInput) {
      final leave = await showDialog<bool>(
        context: context,
        animationStyle: SeraMotion.dialogStyle(context),
        builder: (context) => AlertDialog(
          title: const Text('放弃尚未发布的内容？'),
          content: const Text('离开后，未发布的文字和图片会被放弃。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续编辑'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('放弃'),
            ),
          ],
        ),
      );
      if (leave != true ||
          !mounted ||
          !_communityOwns(context, controller, owner, route: route)) {
        _leaving = false;
        return;
      }
    }
    if (!mounted || !_communityOwns(context, controller, owner, route: route)) {
      return;
    }
    setState(() => _allowExit = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _communityOwns(context, controller, owner, route: route)) {
        _communityBack(context);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<CommunityController>();
    final signedIn = controller.viewer.signedIn;
    final error = _error ?? controller.error;
    return PopScope(
      canPop: widget.desktopMode || (!_saving && (_allowExit || !_hasInput)),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !widget.desktopMode) unawaited(_leave());
      },
      child: _composeLayout(
        title: '发布',
        onBack: _leave,
        body: !signedIn
            ? controller.loading
                  ? const _CommunityStatus('正在加载', busy: true)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (error != null)
                          _CommunityStatus(error, retry: controller.load),
                        SeraButton(
                          '登录后发布',
                          onPressed: () =>
                              _communityLogin(context, '/community/compose'),
                        ),
                      ],
                    )
            : Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final type in {
                          if (!widget.desktopMode) 'post': '日常动态',
                          if (!widget.desktopMode) 'feedback': '使用反馈',
                          if (controller.viewer.permissions.publishOfficial)
                            'official': '官方动态',
                          if (controller.viewer.permissions.publishActivity)
                            'activity': '活动',
                        }.entries)
                          ChoiceChip(
                            label: Text(type.value),
                            selected: _type == type.key,
                            onSelected: _saving
                                ? null
                                : (_) {
                                    setState(() => _type = type.key);
                                    _changed();
                                  },
                          ),
                      ],
                    ),
                    _communityGap,
                    TextFormField(
                      key: const ValueKey('community-title-input'),
                      controller: _title,
                      enabled: !_saving,
                      maxLength: 120,
                      decoration: InputDecoration(
                        labelText: _type == 'activity' ? '活动名称' : '标题（选填）',
                      ),
                      validator: (value) =>
                          _type == 'activity' && (value?.trim().isEmpty ?? true)
                          ? '请填写活动名称'
                          : null,
                    ),
                    _communitySmallGap,
                    TextFormField(
                      key: const ValueKey('community-content-input'),
                      controller: _content,
                      enabled: !_saving,
                      minLines: 5,
                      maxLines: 10,
                      maxLength: 5000,
                      decoration: const InputDecoration(
                        labelText: '正文',
                        alignLabelWithHint: true,
                        hintText: '分享进展、经验，或一个想法',
                      ),
                      validator: (value) =>
                          value?.trim().isNotEmpty == true ? null : '请写下要发布的内容',
                    ),
                    _communitySmallGap,
                    _imageFields(),
                    if (_type == 'activity') ...[
                      _communityGap,
                      OutlinedButton.icon(
                        onPressed: _saving ? null : _pickDate,
                        icon: const Icon(Icons.event_outlined),
                        label: Text(
                          _startsAt == null
                              ? '选择活动开始时间'
                              : _communityDate(_startsAt!),
                        ),
                      ),
                      _communityGap,
                      TextFormField(
                        key: const ValueKey('community-place-input'),
                        controller: _place,
                        enabled: !_saving,
                        maxLength: 120,
                        decoration: const InputDecoration(
                          labelText: '活动地点（选填）',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
        footer: !signedIn
            ? null
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (error != null) ...[
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        error,
                        style: const TextStyle(color: SeraColors.red),
                      ),
                    ),
                    _communitySmallGap,
                  ],
                  SeraButton(
                    '发布',
                    busy: _saving,
                    onPressed:
                        _saving || _pickingImages || _uploading || !_imagesReady
                        ? null
                        : _publish,
                  ),
                ],
              ),
      ),
    );
  }
}

const _permissionLabels = {
  'publishOfficial': '发布官方动态',
  'publishActivity': '发布活动',
  'moderatePosts': '管理帖子',
  'moderateComments': '管理评论',
};

String _applicationStatus(String status) => switch (status) {
  'pending' => '等待审核',
  'approved' => '申请已通过',
  'rejected' => '申请未通过',
  _ => '申请处理中',
};

class _PermissionSummary extends StatelessWidget {
  const _PermissionSummary(this.permissions);
  final CommunityPermissions permissions;

  @override
  Widget build(BuildContext context) {
    final labels = [
      for (final entry in permissions.toJson().entries)
        if (entry.value == true) _permissionLabels[entry.key]!,
    ];
    return Text(
      labels.isEmpty ? '尚未分配操作权限' : labels.join(' · '),
      style: const TextStyle(color: SeraColors.muted, fontSize: 13),
    );
  }
}

class _CommunityPermissionEditor extends StatefulWidget {
  const _CommunityPermissionEditor({
    required this.initial,
    required this.title,
    required this.confirmLabel,
  });
  final CommunityPermissions initial;
  final String title, confirmLabel;

  @override
  State<_CommunityPermissionEditor> createState() =>
      _CommunityPermissionEditorState();
}

class _CommunityPermissionEditorState
    extends State<_CommunityPermissionEditor> {
  late CommunityPermissions _permissions = widget.initial;

  void _set(String key, bool value) {
    setState(() {
      _permissions = _permissions.copyWith(
        publishOfficial: key == 'publishOfficial' ? value : null,
        publishActivity: key == 'publishActivity' ? value : null,
        moderatePosts: key == 'moderatePosts' ? value : null,
        moderateComments: key == 'moderateComments' ? value : null,
      );
    });
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
            _communitySmallGap,
            for (final entry in _permissionLabels.entries)
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(entry.value),
                value: _permissions.toJson()[entry.key] == true,
                onChanged: (value) => _set(entry.key, value),
              ),
            _communityGap,
            SeraButton(
              widget.confirmLabel,
              onPressed: () => Navigator.pop(context, _permissions),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    ),
  );
}

class CommunityManagementScreen extends StatefulWidget {
  const CommunityManagementScreen({super.key});

  @override
  State<CommunityManagementScreen> createState() =>
      _CommunityManagementScreenState();
}

class _CommunityManagementScreenState extends State<CommunityManagementScreen> {
  final _applicationForm = GlobalKey<FormState>();
  final _adminForm = GlobalKey<FormState>();
  final _reason = TextEditingController();
  final _identifier = TextEditingController();
  CommunityController? _controller;
  Object? _owner;
  String? _error;
  bool _editing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = context.read<CommunityController>();
    if (identical(controller, _controller) &&
        _owner == controller.sessionOwner) {
      return;
    }
    _controller = controller;
    _owner = controller.sessionOwner;
    _reason.clear();
    _identifier.clear();
    _error = null;
    _editing = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          identical(controller, _controller) &&
          controller.viewer.signedIn) {
        unawaited(controller.loadManagement());
      }
    });
  }

  @override
  void dispose() {
    _reason.dispose();
    _identifier.dispose();
    super.dispose();
  }

  Future<void> _act(
    Future<void> Function() action, {
    VoidCallback? onSaved,
  }) async {
    final controller = context.read<CommunityController>();
    final owner = controller.sessionOwner;
    final route = ModalRoute.of(context);
    if (controller.isBusy('management')) return;
    setState(() => _error = null);
    try {
      await action();
      if (mounted && _communityOwns(context, controller, owner, route: route)) {
        onSaved?.call();
      }
    } catch (error) {
      if (mounted && _communityOwns(context, controller, owner, route: route)) {
        setState(() => _error = '$error');
      }
    }
  }

  Future<void> _permissions({
    CommunityAdmin? admin,
    CommunityAdminApplication? application,
  }) async {
    final controller = context.read<CommunityController>();
    final owner = controller.sessionOwner;
    final route = ModalRoute.of(context);
    if (_editing ||
        controller.isBusy('management') ||
        !controller.viewer.canManageAdmins) {
      return;
    }
    if (admin == null &&
        application == null &&
        !_adminForm.currentState!.validate()) {
      return;
    }
    setState(() => _editing = true);
    final identifier = _identifier.text.trim();
    final permissions = await showModalBottomSheet<CommunityPermissions>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      sheetAnimationStyle: SeraMotion.sheetStyle(context),
      builder: (context) => _CommunityPermissionEditor(
        initial: admin?.permissions ?? const CommunityPermissions(),
        title: admin != null
            ? '${admin.username}的权限'
            : application != null
            ? '批准${application.username}的申请'
            : '分配管理员权限',
        confirmLabel: admin != null
            ? '保存权限'
            : application != null
            ? '批准申请'
            : '确认添加',
      ),
    );
    if (!mounted || !_communityOwns(context, controller, owner)) return;
    setState(() => _editing = false);
    if (!mounted || !_communityOwns(context, controller, owner, route: route)) {
      return;
    }
    if (permissions == null || !controller.viewer.canManageAdmins) return;
    await _act(
      () => admin != null
          ? controller.updateAdmin(admin.userId, permissions)
          : application != null
          ? controller.reviewApplication(
              application.id,
              status: 'approved',
              permissions: permissions,
            )
          : controller.addAdmin(identifier, permissions),
      onSaved: () {
        if (admin == null && application == null) _identifier.clear();
      },
    );
  }

  Future<void> _remove(CommunityAdmin admin) async {
    final controller = context.read<CommunityController>();
    final owner = controller.sessionOwner;
    final route = ModalRoute.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      animationStyle: SeraMotion.dialogStyle(context),
      builder: (context) => AlertDialog(
        title: const Text('移除管理员？'),
        content: Text('${admin.username}将失去社区管理权限，已发布的内容保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (mounted &&
        confirmed == true &&
        _communityOwns(context, controller, owner, route: route) &&
        controller.viewer.canManageAdmins) {
      await _act(() => controller.removeAdmin(admin.userId));
    }
  }

  Widget _personal(CommunityController controller, CommunityManagement data) {
    final application = data.myApplication;
    if (data.viewer.isAdmin) {
      return SeraCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('社区管理员', style: TextStyle(fontWeight: FontWeight.w600)),
            _communitySmallGap,
            _PermissionSummary(data.viewer.permissions),
          ],
        ),
      );
    }
    final canApply = application == null || application.status != 'pending';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (application != null) ...[
          SeraCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  application.status == 'approved'
                      ? '当前未担任管理员'
                      : _applicationStatus(application.status),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                _communitySmallGap,
                Text(application.reason),
                _communitySmallGap,
                Text(
                  _communityDate(application.createdAt),
                  style: const TextStyle(color: SeraColors.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          _communityGap,
        ],
        if (canApply)
          Form(
            key: _applicationForm,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const ValueKey('community-admin-reason'),
                  controller: _reason,
                  enabled: !controller.isBusy('management'),
                  minLines: 3,
                  maxLines: 6,
                  maxLength: 500,
                  decoration: const InputDecoration(
                    labelText: '申请理由',
                    hintText: '介绍你希望怎样参与社区管理',
                    alignLabelWithHint: true,
                  ),
                  validator: (value) =>
                      value?.trim().isNotEmpty == true ? null : '请填写申请理由',
                ),
                _communitySmallGap,
                SeraButton(
                  application == null ? '提交申请' : '重新申请',
                  busy: controller.isBusy('management'),
                  onPressed: () {
                    if (_applicationForm.currentState!.validate()) {
                      _act(() => controller.applyForAdmin(_reason.text.trim()));
                    }
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _management(CommunityController controller, CommunityManagement data) {
    final busy = controller.isBusy('management') || _editing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SeraSection('管理员'),
        if (data.admins.isEmpty)
          const Text('还没有社区管理员', style: TextStyle(color: SeraColors.muted)),
        for (final admin in data.admins) ...[
          SeraCard(
            key: ValueKey('community-admin-${admin.userId}'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  admin.username,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const Text(
                  '社区管理员',
                  style: TextStyle(fontSize: 12, color: SeraColors.muted),
                ),
                _communitySmallGap,
                _PermissionSummary(admin.permissions),
                Wrap(
                  spacing: 12,
                  children: [
                    TextButton(
                      onPressed: busy ? null : () => _permissions(admin: admin),
                      child: const Text('设置权限'),
                    ),
                    TextButton(
                      onPressed: busy ? null : () => _remove(admin),
                      child: const Text('移除'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _communitySmallGap,
        ],
        _communityGap,
        Form(
          key: _adminForm,
          child: SeraCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const ValueKey('community-admin-identifier'),
                  controller: _identifier,
                  enabled: !busy,
                  maxLength: 254,
                  decoration: const InputDecoration(
                    labelText: '用户名或邮箱',
                    hintText: '输入完整用户名或邮箱',
                    counterText: '',
                  ),
                  validator: (value) =>
                      value?.trim().isNotEmpty == true ? null : '请输入完整用户名或邮箱',
                ),
                _communitySmallGap,
                SeraButton(
                  '添加管理员',
                  variant: 'secondary',
                  onPressed: busy ? null : _permissions,
                ),
              ],
            ),
          ),
        ),
        const SeraSection('管理申请'),
        if (data.applications.isEmpty)
          const Text('暂时没有申请', style: TextStyle(color: SeraColors.muted)),
        for (final application in data.applications) ...[
          SeraCard(
            key: ValueKey('community-application-${application.id}'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  application.username,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                _communitySmallGap,
                Text(application.reason),
                _communitySmallGap,
                Text(
                  _applicationStatus(application.status),
                  style: const TextStyle(color: SeraColors.muted),
                ),
                if (application.status == 'pending')
                  Wrap(
                    spacing: 12,
                    children: [
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => _permissions(application: application),
                        child: const Text('审核并授权'),
                      ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => _act(
                                () => controller.reviewApplication(
                                  application.id,
                                  status: 'rejected',
                                ),
                              ),
                        child: const Text('拒绝申请'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          _communitySmallGap,
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<CommunityController>();
    final data = controller.management;
    final error = _error ?? controller.managementError;
    return SeraScaffold(
      title: controller.viewer.canManageAdmins || controller.viewer.isAdmin
          ? '社区管理'
          : '申请管理社区',
      onBack: () => _communityBack(context),
      body: !controller.viewer.signedIn
          ? SeraButton(
              '登录后申请',
              onPressed: () => _communityLogin(context, '/community/manage'),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (kIsWeb &&
                    (controller.viewer.canManageAdmins ||
                        controller.viewer.isAdmin)) ...[
                  SeraButton(
                    '打开 Web 管理后台',
                    variant: 'secondary',
                    onPressed: () => context.go('/admin/posts'),
                  ),
                  _communityGap,
                ],
                if (controller.managementLoading && data == null)
                  const _CommunityStatus('正在加载', busy: true)
                else if (data != null)
                  data.viewer.canManageAdmins
                      ? _management(controller, data)
                      : _personal(controller, data),
                if (error != null)
                  _CommunityStatus(
                    error,
                    retry: () {
                      setState(() => _error = null);
                      unawaited(controller.loadManagement());
                    },
                  ),
              ],
            ),
    );
  }
}
