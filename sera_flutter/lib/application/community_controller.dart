import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../data/auth_repository.dart';
import '../data/community_repository.dart';
import '../data/workspace_repository.dart';
import '../domain/community_models.dart';

class CommunityController extends ChangeNotifier {
  CommunityController({CommunityRepository? repository, AuthRepository? auth})
    : repository = repository ?? CommunityRepository(auth: auth),
      _ownsRepository = repository == null {
    _identity = _currentIdentity;
    viewer = CommunityViewer(signedIn: this.repository.signedIn);
    this.repository.auth?.addListener(_accountChanged);
  }
  final CommunityRepository repository;
  final bool _ownsRepository;
  late Object _identity;
  bool _disposed = false;
  int _epoch = 0, _feedRequest = 0, _contentVersion = 0;
  List<CommunityPost> posts = const [];
  String filter = 'all';
  String? nextCursor, error;
  bool loading = false, loadingMore = false;
  CommunityViewer viewer = const CommunityViewer();
  final _details = <String, CommunityDetail>{};
  final _detailRequests = <String, int>{};
  final _detailLoading = <String>{};
  final _busy = <String>{};
  final _retryIds = <String, String>{};
  CommunityManagement? management;
  bool managementLoading = false;
  String? managementError;
  int _managementRequest = 0;
  Object get _currentIdentity => (repository.sessionOwner, repository.signedIn);
  Object get sessionOwner => _currentIdentity;
  String? get stableSessionScope => repository.stableSessionScope;
  bool get saving => _busy.isNotEmpty;
  bool get canPublishOfficial => viewer.canPublishOfficial;
  bool get available => repository.available;
  String resolveMediaUrl(String url) => repository.resolveMediaUrl(url);
  bool isBusy(String id) => _busy.contains(id);
  bool isDetailLoading(String id) => _detailLoading.contains(id);
  CommunityDetail? detail(String id) => _details[id];

  void _accountChanged() {
    if (_disposed || _identity == _currentIdentity) return;
    _identity = _currentIdentity;
    _epoch++;
    _feedRequest++;
    _contentVersion++;
    posts = const [];
    nextCursor = error = null;
    viewer = CommunityViewer(signedIn: repository.signedIn);
    loading = loadingMore = false;
    _details.clear();
    _detailRequests.clear();
    _detailLoading.clear();
    _busy.clear();
    _retryIds.clear();
    management = null;
    managementLoading = false;
    managementError = null;
    _managementRequest++;
    notifyListeners();
  }

  bool _current(int epoch) {
    _accountChanged();
    return !_disposed && epoch == _epoch;
  }

  String _message(Object failure) =>
      failure is RepositoryException ? failure.message : '操作未完成，请重试。';

  Future<void> load({String? filter, bool preserveLoaded = false}) async {
    _accountChanged();
    if (_disposed) return;
    final selected = filter ?? this.filter;
    if (!const ['all', 'official', 'feedback'].contains(selected)) {
      throw const RepositoryException('请选择全部、官方或使用反馈。');
    }
    final retainLoaded =
        preserveLoaded && selected == this.filter && posts.isNotEmpty;
    final previousCount = posts.length;
    final hadReachedEnd = nextCursor == null;
    if (selected != this.filter) {
      this.filter = selected;
      posts = const [];
      nextCursor = null;
    }
    final epoch = _epoch;
    final request = ++_feedRequest;
    final version = _contentVersion;
    loading = true;
    loadingMore = false;
    error = null;
    notifyListeners();
    try {
      var page = await repository.list(filter: selected);
      bool isCurrent() =>
          _current(epoch) &&
          request == _feedRequest &&
          version == _contentVersion;
      if (!isCurrent()) return;
      var refreshed = _mergePosts(const [], page.posts);
      final visited = <String>{};
      // Replace only after the previously browsed range has been refreshed.
      // Keeping old pages would retain deleted posts and obsolete server counts.
      while (retainLoaded &&
          page.nextCursor != null &&
          (hadReachedEnd || refreshed.length < previousCount)) {
        final cursor = page.nextCursor!;
        if (!visited.add(cursor)) {
          throw const RepositoryException('社区内容暂时未能刷新，请重试。');
        }
        page = await repository.list(filter: selected, cursor: cursor);
        if (!isCurrent()) return;
        refreshed = _mergePosts(refreshed, page.posts);
      }
      posts = refreshed;
      nextCursor = page.nextCursor;
      viewer = page.viewer;
    } catch (failure) {
      if (_current(epoch) && request == _feedRequest) error = _message(failure);
    } finally {
      if (_current(epoch) && request == _feedRequest) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> refresh({bool preserveLoaded = false}) =>
      load(preserveLoaded: preserveLoaded);

  Future<void> loadMore() async {
    _accountChanged();
    final cursor = nextCursor;
    if (_disposed || loading || loadingMore || cursor == null) return;
    final epoch = _epoch;
    final request = _feedRequest;
    final version = _contentVersion;
    loadingMore = true;
    error = null;
    notifyListeners();
    try {
      final page = await repository.list(filter: filter, cursor: cursor);
      if (!_current(epoch) ||
          request != _feedRequest ||
          version != _contentVersion) {
        return;
      }
      posts = _mergePosts(posts, page.posts);
      nextCursor = page.nextCursor == cursor ? null : page.nextCursor;
      viewer = page.viewer;
    } catch (failure) {
      if (_current(epoch) && request == _feedRequest) error = _message(failure);
    } finally {
      if (_current(epoch) && request == _feedRequest) {
        loadingMore = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadDetail(String id) => _loadDetail(id, append: false);
  Future<void> loadMoreComments(String id) => _loadDetail(id, append: true);
  Future<void> _loadDetail(String id, {required bool append}) async {
    _accountChanged();
    final previous = _details[id];
    if (_disposed ||
        (append &&
            (_detailLoading.contains(id) ||
                previous?.commentsNextCursor == null))) {
      return;
    }
    final epoch = _epoch;
    final version = _contentVersion;
    final request = (_detailRequests[id] ?? 0) + 1;
    _detailRequests[id] = request;
    _detailLoading.add(id);
    error = null;
    notifyListeners();
    try {
      final value = await repository.getDetail(
        id,
        commentCursor: append ? previous!.commentsNextCursor : null,
      );
      if (!_current(epoch) ||
          request != _detailRequests[id] ||
          version != _contentVersion) {
        return;
      }
      _details[id] = CommunityDetail(
        post: value.post,
        comments: _mergeComments(
          append ? previous!.comments : const [],
          value.comments,
        ),
        commentsNextCursor: value.commentsNextCursor,
        viewer: value.viewer,
      );
      viewer = value.viewer;
      _updatePost(value.post);
    } catch (failure) {
      if (_current(epoch) && request == _detailRequests[id]) {
        error = _message(failure);
      }
    } finally {
      if (_current(epoch) && request == _detailRequests[id]) {
        _detailLoading.remove(id);
        notifyListeners();
      }
    }
  }

  List<CommunityPost> _mergePosts(
    List<CommunityPost> before,
    List<CommunityPost> after,
  ) => List.unmodifiable(
    {
      for (final post in before) post.id: post,
      for (final post in after) post.id: post,
    }.values,
  );

  List<CommunityComment> _mergeComments(
    List<CommunityComment> before,
    List<CommunityComment> after,
  ) {
    final result =
        {
          for (final comment in before) comment.id: comment,
          for (final comment in after) comment.id: comment,
        }.values.toList()..sort((a, b) {
          final byTime = a.createdAt.compareTo(b.createdAt);
          return byTime == 0 ? a.id.compareTo(b.id) : byTime;
        });
    return List.unmodifiable(result);
  }

  void _updatePost(CommunityPost post, {bool insert = false}) {
    final matches = switch (filter) {
      'official' => post.isOfficial,
      'feedback' => post.kind == 'post' && post.category == 'feedback',
      _ => true,
    };
    posts = List.unmodifiable([
      if (insert && matches && !posts.any((item) => item.id == post.id)) post,
      for (final current in posts)
        if (current.id != post.id) current else if (matches) post,
    ]);
    final cached = _details[post.id];
    if (cached != null) {
      _details[post.id] = CommunityDetail(
        post: post,
        comments: cached.comments,
        commentsNextCursor: cached.commentsNextCursor,
        viewer: cached.viewer,
      );
    }
  }

  Future<T> _write<T>(
    String key,
    Future<T> Function() action,
    void Function(T) apply,
  ) async {
    _accountChanged();
    if (_disposed) throw const RepositoryException('页面已关闭，操作已停止。');
    if (!repository.signedIn) throw const RepositoryException('请登录后再参与社区。');
    if (_busy.contains(key)) throw const RepositoryException('正在处理，请稍候。');
    final epoch = _epoch;
    _busy.add(key);
    error = null;
    notifyListeners();
    try {
      final value = await action();
      if (!_current(epoch)) throw const RepositoryException('账号已变化，原操作结果已忽略。');
      _contentVersion++;
      apply(value);
      return value;
    } catch (failure) {
      if (_current(epoch)) error = _message(failure);
      if (failure is RepositoryException) rethrow;
      throw RepositoryException(_message(failure));
    } finally {
      if (_current(epoch)) {
        _busy.remove(key);
        notifyListeners();
      }
    }
  }

  String _retryId(String payload, String? supplied) =>
      supplied ??
      _retryIds.putIfAbsent(payload, () {
        final random = Random.secure();
        return List.generate(
          16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
      });

  Future<CommunityPost> createPost({
    required String title,
    required String content,
    String kind = 'post',
    String category = 'daily',
    bool official = false,
    DateTime? startsAt,
    String place = '',
    String? requestId,
    List<String> mediaIds = const [],
  }) {
    _accountChanged();
    final images = List<String>.unmodifiable(mediaIds);
    final payload = jsonEncode([
      'post',
      title,
      content,
      kind,
      category,
      official,
      startsAt?.toUtc().toIso8601String(),
      place,
      images,
    ]);
    final id = _retryId(payload, requestId);
    return _write(
      'create',
      () => repository.createPost(
        requestId: id,
        title: title,
        content: content,
        kind: kind,
        category: category,
        official: official,
        startsAt: startsAt,
        place: place,
        mediaIds: images,
      ),
      (post) {
        _retryIds.remove(payload);
        _updatePost(post, insert: true);
      },
    );
  }

  Future<CommunityMedia> uploadImage(
    Uint8List bytes, {
    required String mimeType,
    String? requestId,
  }) async {
    _accountChanged();
    if (bytes.isEmpty || bytes.length > communityImageMaxBytes) {
      throw const RepositoryException('每张图片需大于 0 且不超过 8 MiB，请缩小图片后重试。');
    }
    if (!communityImageMimeTypes.contains(mimeType)) {
      throw const RepositoryException('请选择 JPG、PNG 或 WebP 图片。');
    }
    final image = Uint8List.fromList(bytes);
    final payload = jsonEncode([
      'image',
      mimeType,
      sha256.convert(image).toString(),
    ]);
    final id = _retryId(payload, requestId);
    return _write(
      'upload:$id',
      () => repository.uploadImage(image, mimeType: mimeType, requestId: id),
      (_) => _retryIds.remove(payload),
    );
  }

  Future<CommunityPost> setLike(String id, bool liked) =>
      _write(id, () => repository.setLike(id, liked), _updatePost);
  Future<CommunityPost> setJoin(String id, bool joined) =>
      _write(id, () => repository.setJoin(id, joined), _updatePost);
  Future<CommunityComment> comment(
    String id,
    String content, {
    String? requestId,
  }) async {
    _accountChanged();
    final payload = jsonEncode(['comment', id, content]);
    final retryId = _retryId(payload, requestId);
    final result = await _write(
      id,
      () => repository.comment(id, content, requestId: retryId),
      (value) {
        _retryIds.remove(payload);
        _updatePost(value.post);
        final cached = _details[id];
        if (cached != null) {
          _details[id] = CommunityDetail(
            post: value.post,
            comments: _mergeComments(cached.comments, [value.comment]),
            commentsNextCursor: cached.commentsNextCursor,
            viewer: cached.viewer,
          );
        }
      },
    );
    return result.comment;
  }

  Future<void> deletePost(String id) =>
      _write<void>(id, () => repository.deletePost(id), (_) {
        posts = List.unmodifiable(posts.where((post) => post.id != id));
        _details.remove(id);
      });

  Future<void> deleteComment(String postId, String commentId) async {
    _accountChanged();
    final epoch = _epoch;
    await _write(
      postId,
      () async {
        await repository.deleteComment(commentId);
        if (!_current(epoch)) {
          throw const RepositoryException('账号已变化，原操作结果已忽略。');
        }
        return repository.getDetail(postId);
      },
      (value) {
        _details[postId] = value;
        viewer = value.viewer;
        _updatePost(value.post);
      },
    );
  }

  Future<void> loadManagement() async {
    _accountChanged();
    if (_disposed) return;
    final epoch = _epoch;
    final request = ++_managementRequest;
    final version = _contentVersion;
    managementLoading = true;
    managementError = null;
    notifyListeners();
    try {
      final value = await repository.getManagement();
      if (!_current(epoch) ||
          request != _managementRequest ||
          version != _contentVersion) {
        return;
      }
      management = value;
      viewer = value.viewer;
    } catch (failure) {
      if (_current(epoch) && request == _managementRequest) {
        managementError = _message(failure);
      }
    } finally {
      if (_current(epoch) && request == _managementRequest) {
        managementLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _manage(
    Future<void> Function() action, {
    bool ownerOnly = true,
    String? retryPayload,
  }) async {
    _accountChanged();
    if (ownerOnly && !viewer.canManageAdmins) {
      throw const RepositoryException('只有官方账号可以管理管理员。');
    }
    final epoch = _epoch;
    managementError = null;
    try {
      await _write(
        'management',
        () async {
          await action();
          if (!_current(epoch)) {
            throw const RepositoryException('账号已变化，原操作结果已忽略。');
          }
          return repository.getManagement();
        },
        (value) {
          management = value;
          viewer = value.viewer;
          if (retryPayload != null) _retryIds.remove(retryPayload);
        },
      );
    } catch (failure) {
      if (_current(epoch)) {
        managementError = _message(failure);
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<void> applyForAdmin(String reason, {String? requestId}) {
    _accountChanged();
    final payload = jsonEncode(['admin-application', reason]);
    final id = _retryId(payload, requestId);
    return _manage(
      () => repository.applyForAdmin(reason, requestId: id),
      ownerOnly: false,
      retryPayload: payload,
    );
  }

  Future<void> addAdmin(String identifier, CommunityPermissions permissions) =>
      _manage(() => repository.addAdmin(identifier, permissions));

  Future<void> updateAdmin(String userId, CommunityPermissions permissions) =>
      _manage(() => repository.updateAdmin(userId, permissions));

  Future<void> removeAdmin(String userId) =>
      _manage(() => repository.removeAdmin(userId));

  Future<void> reviewApplication(
    String id, {
    required String status,
    CommunityPermissions? permissions,
  }) => _manage(
    () => repository.reviewApplication(
      id,
      status: status,
      permissions: permissions,
    ),
  );

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    repository.auth?.removeListener(_accountChanged);
    if (_ownsRepository) repository.dispose();
    super.dispose();
  }
}
