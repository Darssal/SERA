import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sera_flutter/application/admin_controller.dart';
import 'package:sera_flutter/data/admin_repository.dart';
import 'package:sera_flutter/data/auth_repository.dart';
import 'package:sera_flutter/data/workspace_repository.dart';
import 'package:sera_flutter/domain/admin_models.dart';
import 'package:sera_flutter/domain/community_models.dart';
import 'package:sera_flutter/domain/models.dart';

Json _analyticsJson({int days = 30}) {
  final end = DateTime.utc(2026, 11, 9);
  final start = end.subtract(Duration(days: days - 1));
  final previousEnd = end.subtract(Duration(days: days));
  final generatedAt = DateTime.utc(2026, 11, 9, 6, 23, 4);
  String date(DateTime value) => value.toIso8601String().substring(0, 10);
  Json post(
    String id, {
    required int likes,
    required int comments,
    required int participants,
    required String kind,
  }) => {
    'id': id,
    'authorId': 'author',
    'authorName': '同学',
    'title': '真实统计 $id',
    'content': '按实际数据统计',
    'kind': kind,
    'category': 'daily',
    'createdAt': '2026-11-08T06:00:00Z',
    'likeCount': likes,
    'commentCount': comments,
    'participantCount': participants,
    'media': [],
  };
  return {
    'days': days,
    'timeZone': 'Asia/Hong_Kong',
    'generatedAt': generatedAt.toIso8601String(),
    'period': {
      'startDate': date(start),
      'endDate': date(end),
      'endAt': generatedAt.toIso8601String(),
    },
    'previousPeriod': {
      'startDate': date(start.subtract(Duration(days: days))),
      'endDate': date(previousEnd),
      'endAt': generatedAt.subtract(Duration(days: days)).toIso8601String(),
    },
    'summary': {
      'newUsers': {'value': 3, 'previous': 2},
      'contributors': {'value': 2, 'previous': 1},
      'posts': {'value': 3, 'previous': 2},
      'comments': {'value': 3, 'previous': 0},
    },
    'daily': [
      for (var index = 0; index < days; index++)
        {
          'date': date(start.add(Duration(days: index))),
          'newUsers': index == 0
              ? 2
              : index == days - 1
              ? 1
              : 0,
          'contributors': index == 0
              ? 1
              : index == days - 1
              ? 2
              : 0,
          'posts': index == 0
              ? 2
              : index == days - 1
              ? 1
              : 0,
          'comments': index == 0
              ? 1
              : index == days - 1
              ? 2
              : 0,
        },
    ],
    'contentTypes': [
      {'key': 'daily', 'label': '日常动态', 'count': 1},
      {'key': 'feedback', 'label': '使用反馈', 'count': 1},
      {'key': 'activity', 'label': '活动', 'count': 1},
    ],
    'currentInteractions': {'likes': 10, 'participants': 3},
    'topPosts': [
      {
        'post': post(
          'event',
          likes: 2,
          comments: 3,
          participants: 1,
          kind: 'activity',
        ),
        'interactions': 6,
      },
      {
        'post': post(
          'post',
          likes: 1,
          comments: 1,
          participants: 0,
          kind: 'post',
        ),
        'interactions': 2,
      },
    ],
  };
}

class _Storage implements AuthSessionStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Auth extends AuthRepository {
  _Auth({super.client})
    : super(apiBaseUrl: 'https://admin.test', storage: _Storage());
  void use(String? id, {String sessionId = 'one', bool cookie = false}) {
    session = id == null
        ? null
        : AuthSession(
            token: cookie ? '' : 'token-$id-$sessionId',
            csrfToken: 'csrf-$id-$sessionId',
            sessionId: '$id-$sessionId',
            cookieSession: cookie,
            expiresAt: DateTime.now().add(const Duration(days: 1)),
            user: AuthUser(id: id, username: id, email: '$id@example.test'),
          );
    notifyListeners();
  }
}

const _owner = CommunityViewer(
  signedIn: true,
  isOfficial: true,
  canManageAdmins: true,
  permissions: CommunityPermissions(moderatePosts: true),
);
const _moderator = CommunityViewer(
  signedIn: true,
  isAdmin: true,
  permissions: CommunityPermissions(moderateComments: true),
);

class _Repo extends AdminRepository {
  _Repo({required super.auth});
  CommunityViewer viewer = _owner;
  final ranges = <int>[];
  int deletes = 0;
  bool failWrite = false;
  Future<AdminAnalytics> Function(int days)? onAnalytics;
  @override
  Future<AdminBootstrap> bootstrap() async => AdminBootstrap(
    viewer: viewer,
    counts: const AdminCounts(posts: 3, comments: 3),
  );
  @override
  Future<AdminAnalytics> getAnalytics({int days = 30}) {
    ranges.add(days);
    return onAnalytics?.call(days) ??
        Future.value(AdminAnalytics.fromJson(_analyticsJson(days: days)));
  }

  @override
  Future<void> deletePost(
    String id, {
    required String requestId,
    required String reason,
  }) async {
    deletes++;
    if (failWrite) throw const RepositoryException('网络断开');
  }
}

({AdminController controller, _Repo repo, _Auth auth}) _fixture() {
  final auth = _Auth()..use('official');
  final repo = _Repo(auth: auth);
  final controller = AdminController(auth: auth, repository: repo);
  addTearDown(() {
    controller.dispose();
    auth.dispose();
  });
  return (controller: controller, repo: repo, auth: auth);
}

void main() {
  test(
    'official seed posts with no account author do not fabricate contributors',
    () {
      final json = _analyticsJson();
      for (final day in json['daily'] as List) {
        day['contributors'] = 0;
      }
      (json['summary'] as Map)['contributors'] = {'value': 0, 'previous': 0};
      for (final item in json['topPosts'] as List) {
        item['post']['authorId'] = null;
        item['post']['isOfficial'] = true;
      }
      final analytics = AdminAnalytics.fromJson(json);
      expect(analytics.summary.posts.value, 3);
      expect(analytics.summary.contributors.value, 0);
      expect(analytics.topPosts.length, 2);
    },
  );

  test('analytics separates range uniqueness from daily counts and current all-time interaction totals', () {
    final value = AdminAnalytics.fromJson(_analyticsJson());
    expect(value.days, 30);
    expect(value.summary.contributors.value, 2);
    expect(value.daily.fold<int>(0, (sum, row) => sum + row.contributors), 3);
    expect(
      value.contentTypes.fold<int>(0, (sum, row) => sum + row.count),
      value.summary.posts.value,
    );
    expect(value.currentInteractions.likes, 10);
    expect(value.topPosts.first.interactions, 6);
    expect(
      value.previousPeriod.endAt,
      value.period.endAt.subtract(const Duration(days: 30)),
    );
    expect(value.previousPeriod.endAt.hour, 6);
    expect(value.daily, hasLength(30));
    expect(() => value.daily.clear(), throwsUnsupportedError);
  });

  final corruptions = <String, void Function(Json)>{
    'unsupported range': (json) => json['days'] = 14,
    'wrong zone': (json) => json['timeZone'] = 'UTC',
    'impossible calendar date': (json) =>
        (json['daily'] as List).first['date'] = '2026-02-30',
    'missing day': (json) => (json['daily'] as List).removeLast(),
    'duplicate day': (json) =>
        (json['daily'] as List)[1]['date'] = (json['daily'] as List)[0]['date'],
    'fractional counter': (json) =>
        (json['summary'] as Map)['posts']['value'] = 3.5,
    'negative counter': (json) =>
        (json['currentInteractions'] as Map)['likes'] = -1,
    'missing counter': (json) =>
        (json['summary'] as Map)['newUsers'].remove('value'),
    'daily sum mismatch': (json) =>
        (json['summary'] as Map)['posts']['value'] = 4,
    'duplicate exclusive category': (json) =>
        (json['contentTypes'] as List)[1]['key'] = 'daily',
    'category total mismatch': (json) =>
        (json['contentTypes'] as List)[0]['count'] = 2,
    'unique count below a daily maximum': (json) =>
        (json['summary'] as Map)['contributors']['value'] = 1,
    'unique count exceeds daily authors': (json) =>
        (json['summary'] as Map)['contributors']['value'] = 4,
    'previous authors without any activity': (json) {
      (json['summary'] as Map)['posts']['previous'] = 0;
      (json['summary'] as Map)['comments']['previous'] = 0;
    },
    'daily authors exceed all daily activity': (json) =>
        (json['daily'] as List).first['contributors'] = 4,
    'non-aligned comparison instant': (json) =>
        (json['previousPeriod'] as Map)['endAt'] = '2026-10-10T23:59:59Z',
    'timezone-free instant': (json) =>
        json['generatedAt'] = '2026-11-09T06:23:04',
    'normalized invalid instant': (json) =>
        json['generatedAt'] = '2026-02-30T06:23:04Z',
    'non-current end date': (json) =>
        (json['period'] as Map)['endAt'] = '2026-11-08T06:23:04Z',
    'ranked interaction mismatch': (json) =>
        (json['topPosts'] as List).first['interactions'] = 7,
    'ranked fractional post count': (json) =>
        (json['topPosts'] as List).first['post']['likeCount'] = 2.5,
    'zero-only ranked item': (json) {
      final top = (json['topPosts'] as List).first;
      top['post']['likeCount'] = top['post']['commentCount'] =
          top['post']['participantCount'] = 0;
      top['interactions'] = 0;
    },
    'duplicate ranked post': (json) =>
        (json['topPosts'] as List)[1] = (json['topPosts'] as List).first,
    'incorrect rank order': (json) =>
        json['topPosts'] = (json['topPosts'] as List).reversed.toList(),
    'future ranked post': (json) =>
        (json['topPosts'] as List).first['post']['createdAt'] =
            '2026-11-10T00:00:00Z',
    'out-of-period ranked post': (json) =>
        (json['topPosts'] as List).first['post']['createdAt'] =
            '2026-09-01T00:00:00Z',
    'global likes below ranked subset': (json) =>
        (json['currentInteractions'] as Map)['likes'] = 2,
  };
  for (final corruption in corruptions.entries) {
    test('analytics rejects ${corruption.key}', () {
      // Match decoded HTTP JSON instead of Dart-inferred Map<String, int>
      // literals, so malformed numeric values reach the production decoder.
      final json = jsonDecode(jsonEncode(_analyticsJson())) as Json;
      corruption.value(json);
      expect(
        () => AdminAnalytics.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });
  }

  test('all supported ranges retain exactly contiguous Hong Kong dates', () {
    for (final days in [7, 30, 90]) {
      final analytics = AdminAnalytics.fromJson(_analyticsJson(days: days));
      expect(analytics.daily.length, days);
      expect(analytics.daily.first.date, analytics.period.startDate);
      expect(analytics.daily.last.date, analytics.period.endDate);
    }
  });

  test('same-range pending reads are deduplicated and a newer range wins over a late result', () async {
    final f = _fixture();
    await f.controller.loadBootstrap();
    final older = Completer<AdminAnalytics>();
    f.repo.onAnalytics = (_) => older.future;
    final first = f.controller.loadAnalytics();
    await f.controller.loadAnalytics();
    expect(f.repo.ranges, [30]);
    f.repo.onAnalytics = (days) async =>
        AdminAnalytics.fromJson(_analyticsJson(days: days));
    await f.controller.loadAnalytics(days: 7);
    older.complete(AdminAnalytics.fromJson(_analyticsJson()));
    await first;
    expect(f.repo.ranges, [30, 7]);
    expect(f.controller.analyticsDays, 7);
    expect(f.controller.analytics!.days, 7);
    expect(f.controller.analyticsLoading, isFalse);
  });

  test('failed new range preserves valid old data with its own label and permits a retry', () async {
    final f = _fixture();
    await f.controller.loadBootstrap();
    await f.controller.loadAnalytics();
    f.repo.onAnalytics = (_) async => throw const RepositoryException('暂时离线');
    await f.controller.loadAnalytics(days: 7);
    expect(f.controller.analyticsDays, 7);
    expect(f.controller.analytics!.days, 30);
    expect(f.controller.analyticsError, isNotNull);
    expect(f.controller.analyticsLoading, isFalse);
    f.repo.onAnalytics = (days) async =>
        AdminAnalytics.fromJson(_analyticsJson(days: days));
    await f.controller.loadAnalytics(days: 7);
    expect(f.controller.analytics!.days, 7);
    expect(f.controller.analyticsError, isNull);
  });

  test('account or same-account session replacement clears analytics and rejects its late response', () async {
    for (final next in [('other', 'one'), ('official', 'renewed')]) {
      final f = _fixture();
      await f.controller.loadBootstrap();
      await f.controller.loadAnalytics();
      final pending = Completer<AdminAnalytics>();
      f.repo.onAnalytics = (_) => pending.future;
      final read = f.controller.loadAnalytics(days: 7);
      f.auth.use(next.$1, sessionId: next.$2);
      expect(f.controller.analytics, isNull);
      pending.complete(AdminAnalytics.fromJson(_analyticsJson(days: 7)));
      await read;
      expect(f.controller.analytics, isNull);
      expect(f.controller.analyticsError, isNull);
      expect(f.controller.analyticsLoading, isFalse);
    }
  });

  test(
    'owner role removal clears aggregates and prevents a new owner-only read',
    () async {
      final f = _fixture();
      await f.controller.loadBootstrap();
      await f.controller.loadAnalytics();
      f.repo.viewer = _moderator;
      await f.controller.loadBootstrap();
      await f.controller.loadAnalytics(days: 7);
      expect(f.controller.analytics, isNull);
      expect(f.controller.analyticsError, isNotNull);
      expect(f.repo.ranges, [30]);
    },
  );

  test('forbidden analytics response clears cached privileged data and notifies observers', () async {
    final f = _fixture();
    await f.controller.loadBootstrap();
    await f.controller.loadAnalytics();
    var notifications = 0;
    f.controller.addListener(() => notifications++);
    f.repo.onAnalytics = (_) async => throw const RepositoryException(
      '权限已变化',
      details: {'code': 'admin_owner_required'},
    );
    await f.controller.loadAnalytics(days: 7);
    expect(f.controller.analytics, isNull);
    expect(f.controller.analyticsError, isNotNull);
    expect(f.controller.analyticsLoading, isFalse);
    expect(notifications, greaterThanOrEqualTo(2));
  });

  test('confirmed writes invalidate and refresh opened analytics; failed writes retain valid data', () async {
    final f = _fixture();
    await f.controller.loadBootstrap();
    await f.controller.loadAnalytics(days: 7);
    f.repo.failWrite = true;
    await expectLater(
      f.controller.deletePost('post', reason: '重复'),
      throwsA(isA<RepositoryException>()),
    );
    expect(f.controller.analytics!.days, 7);
    expect(f.repo.ranges, [7]);
    final fresh = Completer<AdminAnalytics>();
    f.repo.failWrite = false;
    f.repo.onAnalytics = (_) => fresh.future;
    final write = f.controller.deletePost('post', reason: '重复');
    while (f.repo.ranges.length < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(f.controller.analytics, isNull);
    expect(f.controller.analyticsDays, 7);
    expect(f.controller.analyticsLoading, isTrue);
    fresh.complete(AdminAnalytics.fromJson(_analyticsJson(days: 7)));
    await write;
    expect(f.controller.analytics!.days, 7);
    expect(f.repo.ranges, [7, 7]);
  });

  test(
    'unopened analytics never adds requests to ordinary write reconciliation',
    () async {
      final f = _fixture();
      await f.controller.loadBootstrap();
      await f.controller.deletePost('post', reason: '重复');
      expect(f.repo.ranges, isEmpty);
    },
  );

  test('mismatched range response is rejected without relabeling a valid previous range', () async {
    final f = _fixture();
    await f.controller.loadBootstrap();
    await f.controller.loadAnalytics();
    f.repo.onAnalytics = (_) async =>
        AdminAnalytics.fromJson(_analyticsJson(days: 90));
    await f.controller.loadAnalytics(days: 7);
    expect(f.controller.analytics!.days, 30);
    expect(f.controller.analyticsDays, 7);
    expect(f.controller.analyticsError, isNotNull);
  });

  test('repository uses the real native and Cookie account binding and an explicit days query', () async {
    final dio = Dio();
    final auth = _Auth(client: dio)..use('official');
    final repository = AdminRepository(auth: auth);
    addTearDown(() {
      auth.dispose();
      dio.close();
    });
    final requests = <RequestOptions>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: jsonDecode(
                jsonEncode(
                  _analyticsJson(
                    days: int.parse(options.uri.queryParameters['days']!),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
    await repository.getAnalytics(days: 7);
    expect(requests.first.uri.path, '/api/v1/admin/analytics');
    expect(requests.first.uri.queryParameters, {'days': '7'});
    expect(
      requests.first.headers['Authorization'],
      'Bearer token-official-one',
    );
    auth.use('official', sessionId: 'web', cookie: true);
    await repository.getAnalytics(days: 90);
    expect(requests.last.headers.containsKey('Authorization'), isFalse);
    expect(requests.last.headers['X-CSRF-Token'], 'csrf-official-web');
    await expectLater(
      repository.getAnalytics(days: 14),
      throwsA(isA<RepositoryException>()),
    );
    expect(requests.length, 2);
  });

  test(
    'repository rejects an analytics response bound to an old account',
    () async {
      final dio = Dio();
      final auth = _Auth(client: dio)..use('official');
      final repository = AdminRepository(auth: auth);
      addTearDown(() {
        auth.dispose();
        dio.close();
      });
      RequestInterceptorHandler? delayed;
      RequestOptions? request;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            request = options;
            delayed = handler;
          },
        ),
      );
      final read = repository.getAnalytics(days: 7);
      final rejected = expectLater(read, throwsA(isA<RepositoryException>()));
      while (delayed == null) {
        await Future<void>.delayed(Duration.zero);
      }
      auth.use('other');
      delayed!.resolve(
        Response<dynamic>(
          requestOptions: request!,
          statusCode: 200,
          data: _analyticsJson(days: 7),
        ),
      );
      await rejected;
      expect(auth.session!.user.id, 'other');
    },
  );
}
