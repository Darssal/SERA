import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../domain/community_models.dart';
import '../domain/models.dart';
import 'auth_repository.dart';
import 'workspace_repository.dart';

String _defaultBaseUrl() {
  const configured = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'same-origin',
  );
  return configured == 'same-origin'
      ? (kIsWeb ? Uri.base.origin : 'http://127.0.0.1:8787')
      : configured;
}

/// Uses the existing account transport, including bound Cookie/CSRF sessions.
/// A separate Dio is only needed for anonymous access or transport tests.
class CommunityRepository {
  CommunityRepository({this.auth, Dio? client, String? apiBaseUrl})
    : apiBaseUrl = apiBaseUrl ?? auth?.apiBaseUrl ?? _defaultBaseUrl(),
      _client = client ?? Dio() {
    if (auth == null) {
      _client.options.baseUrl = this.apiBaseUrl.replaceFirst(
        RegExp(r'/+$'),
        '',
      );
      _client.options.connectTimeout = const Duration(seconds: 8);
      _client.options.receiveTimeout = const Duration(seconds: 30);
      configureAuthDio(_client);
    }
  }
  final AuthRepository? auth;
  final String apiBaseUrl;
  final Dio _client;
  bool get available => apiBaseUrl.trim().isNotEmpty;
  bool get signedIn => auth?.signedIn == true;
  Object get sessionOwner => auth?.sessionOwner ?? this;
  String? get stableSessionScope {
    final session = auth?.session;
    if (!signedIn || session == null) return null;
    return jsonEncode([
      apiBaseUrl.replaceFirst(RegExp(r'/+$'), ''),
      session.user.id,
      session.sessionId,
    ]);
  }

  Future<Json> _request(
    String method,
    String path, {
    Object? data,
    String? contentType,
    String? idempotencyKey,
  }) async {
    if (!available) throw const RepositoryException('社区需要连接服务器，请连接网络后重试。');
    try {
      if (auth case final account?) {
        return await account.authenticatedRequest(
          method,
          '/api/v1/community$path',
          data: data,
          contentType: contentType,
          idempotencyKey: idempotencyKey,
        );
      }
      final response = await _client.request<dynamic>(
        '/api/v1/community$path',
        data: data,
        options: Options(
          method: method,
          contentType: contentType,
          headers: {'Idempotency-Key': ?idempotencyKey},
        ),
      );
      if (response.data is! Map) throw const FormatException();
      return Map<String, dynamic>.from(response.data as Map);
    } on DioException catch (error) {
      final body = error.response?.data;
      throw RepositoryException(
        body is Map && body['error'] is String
            ? body['error'] as String
            : '暂时无法连接社区，请检查网络后重试。',
        details: {
          if (body is Map && body['details'] is Map)
            ...Map<String, dynamic>.from(body['details'] as Map),
          if (body is Map && body['code'] is String) 'code': body['code'],
        },
      );
    }
  }

  Future<T> _read<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on RepositoryException {
      rethrow;
    } catch (_) {
      throw const RepositoryException('社区返回的内容无法读取，请重试。');
    }
  }

  Future<CommunityFeed> list({String filter = 'all', String? cursor}) =>
      _read(() async {
        final path = Uri(
          path: '/posts',
          queryParameters: {'filter': filter, 'limit': '20', 'cursor': ?cursor},
        );
        return CommunityFeed.fromJson(await _request('GET', '$path'));
      });

  Future<CommunityDetail> getDetail(String id, {String? commentCursor}) =>
      _read(() async {
        final path = Uri(
          pathSegments: ['', 'posts', id],
          queryParameters: {
            'commentLimit': '50',
            'commentCursor': ?commentCursor,
          },
        );
        return CommunityDetail.fromJson(await _request('GET', '$path'));
      });

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
  }) => _read(() async {
    final body = await _request(
      'POST',
      '/posts',
      data: {
        'requestId': requestId,
        'title': title,
        'content': content,
        'kind': kind,
        'category': category,
        'official': official,
        'place': place,
        'mediaIds': List<String>.of(mediaIds),
        if (startsAt != null) 'startsAt': startsAt.toUtc().toIso8601String(),
      },
    );
    return CommunityPost.fromJson(
      Map<String, dynamic>.from(body['post'] as Map),
    );
  });

  String resolveMediaUrl(String url) =>
      Uri.parse(apiBaseUrl).resolve(url).toString();

  Future<CommunityMedia> uploadImage(
    Uint8List bytes, {
    required String mimeType,
    required String requestId,
  }) => _read(() async {
    if (bytes.isEmpty || bytes.length > communityImageMaxBytes) {
      throw const RepositoryException('每张图片需大于 0 且不超过 8 MiB，请缩小图片后重试。');
    }
    if (!communityImageMimeTypes.contains(mimeType)) {
      throw const RepositoryException('请选择 JPG、PNG 或 WebP 图片。');
    }
    final body = await _request(
      'POST',
      '/media',
      data: Stream<Uint8List>.value(bytes),
      contentType: mimeType,
      idempotencyKey: requestId,
    );
    return CommunityMedia.fromJson(
      Map<String, dynamic>.from(body['media'] as Map),
    );
  });

  Future<CommunityPost> setLike(String id, bool liked) =>
      _postAction(id, 'like', {'liked': liked});
  Future<CommunityPost> setJoin(String id, bool joined) =>
      _postAction(id, 'join', {'joined': joined});
  Future<CommunityPost> _postAction(String id, String action, Json data) =>
      _read(() async {
        final body = await _request(
          'PUT',
          '/posts/${Uri.encodeComponent(id)}/$action',
          data: data,
        );
        return CommunityPost.fromJson(
          Map<String, dynamic>.from(body['post'] as Map),
        );
      });
  Future<CommunityCommentResult> comment(
    String id,
    String content, {
    required String requestId,
  }) => _read(() async {
    final body = await _request(
      'POST',
      '/posts/${Uri.encodeComponent(id)}/comments',
      data: {'requestId': requestId, 'content': content},
    );
    return CommunityCommentResult(
      comment: CommunityComment.fromJson(
        Map<String, dynamic>.from(body['comment'] as Map),
      ),
      post: CommunityPost.fromJson(
        Map<String, dynamic>.from(body['post'] as Map),
      ),
    );
  });
  Future<void> deletePost(String id) async {
    await _request('DELETE', '/posts/${Uri.encodeComponent(id)}');
  }

  Future<void> deleteComment(String id) async {
    await _request('DELETE', '/comments/${Uri.encodeComponent(id)}');
  }

  Future<CommunityManagement> getManagement() => _read(
    () async =>
        CommunityManagement.fromJson(await _request('GET', '/management')),
  );

  Future<void> applyForAdmin(String reason, {required String requestId}) async {
    await _request(
      'POST',
      '/admin-applications',
      data: {'reason': reason, 'requestId': requestId},
    );
  }

  Future<void> addAdmin(
    String identifier,
    CommunityPermissions permissions,
  ) async {
    await _request(
      'POST',
      '/admins',
      data: {'identifier': identifier, 'permissions': permissions.toJson()},
    );
  }

  Future<void> updateAdmin(
    String userId,
    CommunityPermissions permissions,
  ) async {
    await _request(
      'PUT',
      '/admins/${Uri.encodeComponent(userId)}',
      data: {'permissions': permissions.toJson()},
    );
  }

  Future<void> removeAdmin(String userId) async {
    await _request('DELETE', '/admins/${Uri.encodeComponent(userId)}');
  }

  Future<void> reviewApplication(
    String id, {
    required String status,
    CommunityPermissions? permissions,
  }) async {
    await _request(
      'PUT',
      '/admin-applications/${Uri.encodeComponent(id)}',
      data: {
        'status': status,
        if (permissions != null) 'permissions': permissions.toJson(),
      },
    );
  }

  void dispose() => _client.close();
}
