import '../domain/admin_models.dart';
import '../domain/community_models.dart';
import '../domain/models.dart';
import 'auth_repository.dart';
import 'workspace_repository.dart';

/// The administration surface shares the account's Cookie/CSRF or Bearer
/// transport. It does not create or persist another authenticated session.
class AdminRepository {
  AdminRepository({required this.auth});
  final AuthRepository auth;

  Future<Json> _request(
    String method,
    String path, {
    Json? data,
    String? requestId,
  }) => auth.authenticatedRequest(
    method,
    '/api/v1/admin$path',
    data: data,
    idempotencyKey: requestId,
  );

  Future<T> _read<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on RepositoryException {
      rethrow;
    } catch (_) {
      throw const RepositoryException('管理内容暂时无法读取，请重试。');
    }
  }

  String _pagePath(
    String path, {
    String q = '',
    String? cursor,
    int limit = 30,
    Map<String, String> filters = const {},
  }) => Uri(
    path: path,
    queryParameters: {
      if (q.trim().isNotEmpty) 'q': q.trim(),
      'cursor': ?cursor,
      'limit': '$limit',
      for (final entry in filters.entries)
        if (entry.value.isNotEmpty) entry.key: entry.value,
    },
  ).toString();

  AdminPage<T> _page<T>(Json json, String key, T Function(Json) decode) {
    final rows = json[key], total = json['total'], cursor = json['nextCursor'];
    if (rows is! List ||
        rows.any((row) => row is! Map) ||
        total is! int ||
        total < 0 ||
        (cursor != null && (cursor is! String || cursor.isEmpty))) {
      throw const RepositoryException('管理列表返回的内容无效，请重试。');
    }
    return AdminPage(
      items: readList(rows, decode),
      total: total,
      nextCursor: cursor as String?,
    );
  }

  Future<AdminBootstrap> bootstrap() => _read(
    () async => AdminBootstrap.fromJson(await _request('GET', '/bootstrap')),
  );

  Future<AdminAnalytics> getAnalytics({int days = 30}) => _read(() async {
    if (!const {7, 30, 90}.contains(days)) {
      throw const RepositoryException('请选择最近 7 天、30 天或 90 天。');
    }
    final value = AdminAnalytics.fromJson(
      await _request('GET', '/analytics?days=$days'),
    );
    if (value.days != days) {
      throw const RepositoryException('统计区间已变化，请重新加载。');
    }
    return value;
  });

  Future<AdminPage<CommunityPost>> listPosts({
    String q = '',
    String category = '',
    String kind = '',
    bool? official,
    String? cursor,
    int limit = 30,
  }) => _read(() async {
    final json = await _request(
      'GET',
      _pagePath(
        '/posts',
        q: q,
        cursor: cursor,
        limit: limit,
        filters: {
          'category': category,
          'kind': kind,
          if (official == true) 'official': 'yes',
        },
      ),
    );
    return _page(json, 'posts', CommunityPost.fromJson);
  });

  Future<AdminPage<AdminComment>> listComments({
    String q = '',
    String postId = '',
    String? cursor,
    int limit = 30,
  }) => _read(() async {
    final json = await _request(
      'GET',
      _pagePath(
        '/comments',
        q: q,
        cursor: cursor,
        limit: limit,
        filters: {'postId': postId},
      ),
    );
    return _page(json, 'comments', AdminComment.fromJson);
  });

  Future<AdminPage<AdminUser>> listUsers({
    String q = '',
    String status = '',
    String? cursor,
    int limit = 30,
  }) => _read(() async {
    final json = await _request(
      'GET',
      _pagePath(
        '/users',
        q: q,
        cursor: cursor,
        limit: limit,
        filters: {'status': status},
      ),
    );
    return _page(json, 'users', AdminUser.fromJson);
  });

  Future<AdminPage<AdminAuditEntry>> listAudit({
    String q = '',
    String? cursor,
    int limit = 30,
  }) => _read(() async {
    final json = await _request(
      'GET',
      _pagePath('/audit', q: q, cursor: cursor, limit: limit),
    );
    return _page(json, 'entries', AdminAuditEntry.fromJson);
  });

  Future<AdminStatus> getStatus() =>
      _read(() async => AdminStatus.fromJson(await _request('GET', '/status')));

  Future<void> deletePost(
    String id, {
    required String requestId,
    required String reason,
  }) async {
    await _request(
      'DELETE',
      '/posts/${Uri.encodeComponent(id)}',
      data: {'requestId': requestId, 'reason': reason},
      requestId: requestId,
    );
  }

  Future<void> deleteComment(
    String id, {
    required String requestId,
    required String reason,
  }) async {
    await _request(
      'DELETE',
      '/comments/${Uri.encodeComponent(id)}',
      data: {'requestId': requestId, 'reason': reason},
      requestId: requestId,
    );
  }

  Future<void> setUserDisabled(
    String id, {
    required bool disabled,
    required String reason,
    required String requestId,
  }) async {
    await _request(
      'PUT',
      '/users/${Uri.encodeComponent(id)}/status',
      data: {'disabled': disabled, 'reason': reason, 'requestId': requestId},
      requestId: requestId,
    );
  }
}
