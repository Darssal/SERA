import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/admin_repository.dart';
import '../data/auth_repository.dart';
import '../data/community_repository.dart';
import '../data/workspace_repository.dart';
import '../domain/admin_models.dart';
import '../domain/community_models.dart';

/// Each list owns its request generation, error, and cursor. A failed refresh
/// keeps the last successful rows available without mixing two account scopes.
class AdminPageState<T> {
  List<T> items = const [];
  int total = 0;
  String? nextCursor, error;
  bool loading = false, loadingMore = false;
  bool get hasMore => nextCursor != null;
  int _request = 0;
  bool _requested = false;
  void _clear() {
    items = const [];
    total = 0;
    nextCursor = error = null;
    loading = loadingMore = _requested = false;
    _request++;
  }
}

class AdminController extends ChangeNotifier {
  AdminController({
    required this.auth,
    AdminRepository? repository,
    CommunityRepository? communityRepository,
  }) : repository = repository ?? AdminRepository(auth: auth),
       communityRepository =
           communityRepository ?? CommunityRepository(auth: auth),
       _ownsCommunityRepository = communityRepository == null {
    _identity = _currentIdentity;
    auth.addListener(_accountChanged);
  }
  final AuthRepository auth;
  final AdminRepository repository;
  final CommunityRepository communityRepository;
  final bool _ownsCommunityRepository;
  late Object _identity;
  bool _disposed = false;
  int _epoch = 0, _bootstrapRequest = 0, _contentVersion = 0;
  AdminBootstrap? bootstrap;
  CommunityViewer get viewer => bootstrap?.viewer ?? const CommunityViewer();
  AdminCounts get counts => bootstrap?.counts ?? const AdminCounts();
  bool loading = false, saving = false;
  String? error;
  final posts = AdminPageState<CommunityPost>();
  final comments = AdminPageState<AdminComment>();
  final users = AdminPageState<AdminUser>();
  final audit = AdminPageState<AdminAuditEntry>();
  String _postQuery = '', _postCategory = '', _postKind = '';
  bool? _postOfficial;
  String _commentQuery = '', _commentPostId = '';
  String _userQuery = '', _userStatus = '', _auditQuery = '';
  AdminStatus? status;
  bool statusLoading = false;
  String? statusError;
  int _statusRequest = 0;
  bool _statusRequested = false;
  AdminAnalytics? analytics;
  int analyticsDays = 30;
  bool analyticsLoading = false;
  String? analyticsError;
  int _analyticsRequest = 0;
  int? _analyticsPendingDays;
  bool _analyticsRequested = false;
  final _details = <String, CommunityDetail>{};
  final _detailRequests = <String, int>{};
  final _detailLoading = <String>{};
  final _detailErrors = <String, String>{};
  final _retryIds = <String, String>{};
  Object get _currentIdentity => (auth.sessionOwner, auth.signedIn);
  Object get sessionOwner => _currentIdentity;
  CommunityDetail? detail(String id) => _details[id];
  bool isDetailLoading(String id) => _detailLoading.contains(id);
  String? detailError(String id) => _detailErrors[id];
  String resolveMediaUrl(String url) =>
      communityRepository.resolveMediaUrl(url);

  void _accountChanged() {
    if (_disposed || _identity == _currentIdentity) return;
    _identity = _currentIdentity;
    _epoch++;
    _bootstrapRequest++;
    _contentVersion++;
    bootstrap = null;
    loading = saving = false;
    error = null;
    posts._clear();
    comments._clear();
    _clearOwnerData();
    _postQuery = _postCategory = _postKind = '';
    _postOfficial = null;
    _commentQuery = _commentPostId = '';
    _userQuery = _userStatus = _auditQuery = '';
    _details.clear();
    _detailRequests.clear();
    _detailLoading.clear();
    _detailErrors.clear();
    _retryIds.clear();
    notifyListeners();
  }

  void _clearOwnerData() {
    users._clear();
    audit._clear();
    status = null;
    statusLoading = _statusRequested = false;
    statusError = null;
    _statusRequest++;
    analytics = null;
    analyticsDays = 30;
    analyticsLoading = _analyticsRequested = false;
    analyticsError = null;
    _analyticsPendingDays = null;
    _analyticsRequest++;
  }

  bool _current(int epoch) {
    _accountChanged();
    return !_disposed && epoch == _epoch;
  }

  String _message(Object failure) =>
      failure is RepositoryException ? failure.message : '操作未完成，请重试。';

  Future<void> loadBootstrap() async {
    _accountChanged();
    if (_disposed) return;
    final epoch = _epoch, version = _contentVersion;
    final request = ++_bootstrapRequest;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final value = await repository.bootstrap();
      if (!_current(epoch) ||
          request != _bootstrapRequest ||
          version != _contentVersion) {
        return;
      }
      bootstrap = value;
      if (!value.viewer.canManageAdmins) _clearOwnerData();
    } catch (failure) {
      if (_current(epoch) && request == _bootstrapRequest) {
        error = _message(failure);
        if (failure is RepositoryException &&
            const {
              'admin_required',
              'admin_owner_required',
              'admin_permission_required',
            }.contains(failure.details['code'])) {
          bootstrap = null;
          posts._clear();
          comments._clear();
          _clearOwnerData();
          _details.clear();
          _detailRequests.clear();
          _detailLoading.clear();
          _detailErrors.clear();
        }
      }
    } finally {
      if (_current(epoch) && request == _bootstrapRequest) {
        loading = false;
        notifyListeners();
      }
    }
  }

  /// Refresh only lists that have been opened, retaining their active filters.
  Future<void> refresh() async {
    _accountChanged();
    if (_disposed) return;
    final epoch = _epoch;
    final refreshPosts = posts._requested;
    final refreshComments = comments._requested;
    final refreshUsers = users._requested;
    final refreshAudit = audit._requested;
    final refreshStatus = _statusRequested;
    final refreshAnalytics = _analyticsRequested;
    await loadBootstrap();
    if (!_current(epoch)) return;
    await Future.wait([
      if (refreshPosts) _loadPosts(),
      if (refreshComments) _loadComments(),
      if (refreshUsers && viewer.canManageAdmins) _loadUsers(),
      if (refreshAudit && viewer.canManageAdmins) _loadAudit(),
      if (refreshStatus && viewer.canManageAdmins) loadStatus(),
      if (refreshAnalytics && viewer.canManageAdmins)
        loadAnalytics(days: analyticsDays),
    ]);
  }

  /// Clear a stale aggregate after a confirmed write. The next refresh only
  /// fetches analytics when the owner has already opened that section.
  void invalidateAnalytics() {
    if (_disposed) return;
    analytics = null;
    analyticsLoading = false;
    analyticsError = null;
    _analyticsPendingDays = null;
    _analyticsRequest++;
    notifyListeners();
  }

  Future<void> loadAnalytics({int days = 30}) async {
    _accountChanged();
    if (_disposed) return;
    if (!const {7, 30, 90}.contains(days)) {
      analyticsError = '请选择最近 7 天、30 天或 90 天。';
      notifyListeners();
      return;
    }
    if (!viewer.canManageAdmins) {
      _clearOwnerData();
      analyticsError = '只有官方账号可以查看运营统计。';
      notifyListeners();
      return;
    }
    if (analyticsLoading && _analyticsPendingDays == days) return;
    final epoch = _epoch, version = _contentVersion;
    final request = ++_analyticsRequest;
    analyticsDays = days;
    _analyticsPendingDays = days;
    _analyticsRequested = true;
    analyticsLoading = true;
    analyticsError = null;
    notifyListeners();
    try {
      final value = await repository.getAnalytics(days: days);
      if (!_current(epoch) ||
          request != _analyticsRequest ||
          version != _contentVersion) {
        return;
      }
      if (value.days != days) {
        throw const RepositoryException('统计区间已变化，请重新加载。');
      }
      analytics = value;
    } catch (failure) {
      if (_current(epoch) && request == _analyticsRequest) {
        analyticsError = _message(failure);
        if (failure is RepositoryException &&
            const {
              'admin_required',
              'admin_owner_required',
              'admin_permission_required',
            }.contains(failure.details['code'])) {
          _clearOwnerData();
          analyticsError = _message(failure);
          notifyListeners();
        }
      }
    } finally {
      if (_current(epoch) && request == _analyticsRequest) {
        analyticsLoading = false;
        _analyticsPendingDays = null;
        notifyListeners();
      }
    }
  }

  Future<void> _loadPage<T>(
    AdminPageState<T> state,
    Future<AdminPage<T>> Function(String? cursor) fetch,
    String Function(T item) id, {
    bool append = false,
  }) async {
    _accountChanged();
    final cursor = append ? state.nextCursor : null;
    if (_disposed ||
        (append && (state.loading || state.loadingMore || cursor == null))) {
      return;
    }
    final epoch = _epoch, version = _contentVersion;
    final request = ++state._request;
    state._requested = true;
    state.loading = !append;
    state.loadingMore = append;
    state.error = null;
    notifyListeners();
    try {
      final page = await fetch(cursor);
      if (!_current(epoch) ||
          request != state._request ||
          version != _contentVersion) {
        return;
      }
      state.items = List.unmodifiable(
        {
          if (append)
            for (final item in state.items) id(item): item,
          for (final item in page.items) id(item): item,
        }.values,
      );
      state.total = page.total;
      state.nextCursor = page.nextCursor == cursor ? null : page.nextCursor;
    } catch (failure) {
      if (_current(epoch) && request == state._request) {
        state.error = _message(failure);
      }
    } finally {
      if (_current(epoch) && request == state._request) {
        state.loading = state.loadingMore = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadPosts({
    String q = '',
    String category = '',
    String kind = '',
    bool? official,
  }) {
    _accountChanged();
    if (_postQuery != q.trim() ||
        _postCategory != category ||
        _postKind != kind ||
        _postOfficial != official) {
      posts.nextCursor = null;
    }
    _postQuery = q.trim();
    _postCategory = category;
    _postKind = kind;
    _postOfficial = official;
    return _loadPosts();
  }

  Future<void> _loadPosts({bool append = false}) {
    final q = _postQuery, category = _postCategory, kind = _postKind;
    final official = _postOfficial;
    return _loadPage(
      posts,
      (cursor) => repository.listPosts(
        q: q,
        category: category,
        kind: kind,
        official: official,
        cursor: cursor,
      ),
      (item) => item.id,
      append: append,
    );
  }

  Future<void> loadMorePosts() => _loadPosts(append: true);

  Future<void> loadComments({String q = '', String postId = ''}) {
    _accountChanged();
    if (_commentQuery != q.trim() || _commentPostId != postId) {
      comments.nextCursor = null;
    }
    _commentQuery = q.trim();
    _commentPostId = postId;
    return _loadComments();
  }

  Future<void> _loadComments({bool append = false}) {
    final q = _commentQuery, postId = _commentPostId;
    return _loadPage(
      comments,
      (cursor) => repository.listComments(q: q, postId: postId, cursor: cursor),
      (item) => item.id,
      append: append,
    );
  }

  Future<void> loadMoreComments() => _loadComments(append: true);

  Future<void> loadUsers({String q = '', String status = ''}) {
    _accountChanged();
    if (_userQuery != q.trim() || _userStatus != status) {
      users.nextCursor = null;
    }
    _userQuery = q.trim();
    _userStatus = status;
    return _loadUsers();
  }

  Future<void> _loadUsers({bool append = false}) {
    final q = _userQuery, status = _userStatus;
    return _loadPage(
      users,
      (cursor) => repository.listUsers(q: q, status: status, cursor: cursor),
      (item) => item.id,
      append: append,
    );
  }

  Future<void> loadMoreUsers() => _loadUsers(append: true);

  Future<void> loadAudit({String q = ''}) {
    _accountChanged();
    if (_auditQuery != q.trim()) audit.nextCursor = null;
    _auditQuery = q.trim();
    return _loadAudit();
  }

  Future<void> _loadAudit({bool append = false}) {
    final q = _auditQuery;
    return _loadPage(
      audit,
      (cursor) => repository.listAudit(q: q, cursor: cursor),
      (item) => item.id,
      append: append,
    );
  }

  Future<void> loadMoreAudit() => _loadAudit(append: true);

  Future<void> loadStatus() async {
    _accountChanged();
    if (_disposed) return;
    final epoch = _epoch, version = _contentVersion;
    final request = ++_statusRequest;
    _statusRequested = true;
    statusLoading = true;
    statusError = null;
    notifyListeners();
    try {
      final value = await repository.getStatus();
      if (_current(epoch) &&
          request == _statusRequest &&
          version == _contentVersion) {
        status = value;
      }
    } catch (failure) {
      if (_current(epoch) && request == _statusRequest) {
        statusError = _message(failure);
      }
    } finally {
      if (_current(epoch) && request == _statusRequest) {
        statusLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadDetail(String id) async {
    _accountChanged();
    if (_disposed) return;
    final epoch = _epoch, version = _contentVersion;
    final request = (_detailRequests[id] ?? 0) + 1;
    _detailRequests[id] = request;
    _detailLoading.add(id);
    _detailErrors.remove(id);
    notifyListeners();
    try {
      final value = await communityRepository.getDetail(id);
      if (_current(epoch) &&
          request == _detailRequests[id] &&
          version == _contentVersion) {
        if (value.post.id != id) {
          throw const RepositoryException('帖子已变化，请重新打开。');
        }
        _details[id] = value;
      }
    } catch (failure) {
      if (_current(epoch) && request == _detailRequests[id]) {
        _detailErrors[id] = _message(failure);
      }
    } finally {
      if (_current(epoch) && request == _detailRequests[id]) {
        _detailLoading.remove(id);
        notifyListeners();
      }
    }
  }

  String _retryId(String payload) => _retryIds.putIfAbsent(payload, () {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  });

  Future<void> _write(
    List<Object> payload,
    Future<void> Function(String requestId) action,
    VoidCallback apply,
  ) async {
    _accountChanged();
    if (_disposed) throw const RepositoryException('页面已关闭，操作已停止。');
    if (!auth.signedIn) throw const RepositoryException('请先登录。');
    if (saving) throw const RepositoryException('正在处理，请稍候。');
    final epoch = _epoch;
    final key = jsonEncode(payload);
    final requestId = _retryId(key);
    saving = true;
    error = null;
    // Reads started before a write cannot restore a deleted or outdated row.
    _contentVersion++;
    notifyListeners();
    try {
      await action(requestId);
      if (!_current(epoch)) {
        throw const RepositoryException('账号已变化，原操作结果已忽略。');
      }
      _contentVersion++;
      _retryIds.remove(key);
      invalidateAnalytics();
      apply();
      await refresh();
    } catch (failure) {
      if (_current(epoch)) error = _message(failure);
      if (failure is RepositoryException) rethrow;
      throw RepositoryException(_message(failure));
    } finally {
      if (_current(epoch)) {
        saving = false;
        notifyListeners();
      }
    }
  }

  String _reason(String reason) {
    final value = reason.trim();
    if (value.isEmpty || value.length > 500) {
      throw const RepositoryException('请填写处理原因，最多 500 字。');
    }
    return value;
  }

  Future<void> deletePost(String id, {required String reason}) {
    final explanation = _reason(reason);
    return _write(
      ['delete-post', id, explanation],
      (requestId) =>
          repository.deletePost(id, reason: explanation, requestId: requestId),
      () {
        posts.items = List.unmodifiable(
          posts.items.where((item) => item.id != id),
        );
        comments.items = List.unmodifiable(
          comments.items.where((item) => item.postId != id),
        );
        _details.remove(id);
      },
    );
  }

  Future<void> deleteComment(String id, {required String reason}) {
    final explanation = _reason(reason);
    return _write(
      ['delete-comment', id, explanation],
      (requestId) => repository.deleteComment(
        id,
        reason: explanation,
        requestId: requestId,
      ),
      () {
        comments.items = List.unmodifiable(
          comments.items.where((item) => item.id != id),
        );
        _details.clear();
      },
    );
  }

  Future<void> setUserDisabled(
    String id, {
    required bool disabled,
    required String reason,
  }) {
    final explanation = _reason(reason);
    return _write(
      ['user-status', id, disabled, explanation],
      (requestId) => repository.setUserDisabled(
        id,
        disabled: disabled,
        reason: explanation,
        requestId: requestId,
      ),
      _details.clear,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    auth.removeListener(_accountChanged);
    if (_ownsCommunityRepository) communityRepository.dispose();
    super.dispose();
  }
}
