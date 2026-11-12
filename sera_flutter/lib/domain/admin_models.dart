import 'community_models.dart';
import 'models.dart';

class AdminCounts {
  const AdminCounts({
    this.posts = 0,
    this.comments = 0,
    this.feedback = 0,
    this.activities = 0,
    this.pendingApplications,
    this.users,
    this.admins,
  });
  final int posts, comments, feedback, activities;
  final int? pendingApplications, users, admins;
  factory AdminCounts.fromJson(Json json) => AdminCounts(
    posts: (json['posts'] as num?)?.toInt() ?? 0,
    comments: (json['comments'] as num?)?.toInt() ?? 0,
    feedback: (json['feedback'] as num?)?.toInt() ?? 0,
    activities: (json['activities'] as num?)?.toInt() ?? 0,
    pendingApplications: (json['pendingApplications'] as num?)?.toInt(),
    users: (json['users'] as num?)?.toInt(),
    admins: (json['admins'] as num?)?.toInt(),
  );
}

class AdminBootstrap {
  const AdminBootstrap({required this.viewer, required this.counts});
  final CommunityViewer viewer;
  final AdminCounts counts;
  factory AdminBootstrap.fromJson(Json json) => AdminBootstrap(
    viewer: CommunityViewer.fromJson(
      Map<String, dynamic>.from(json['viewer'] as Map),
    ),
    counts: AdminCounts.fromJson(
      Map<String, dynamic>.from(json['counts'] as Map),
    ),
  );
}

class AdminPage<T> {
  AdminPage({required List<T> items, required this.total, this.nextCursor})
    : items = List.unmodifiable(items);
  final List<T> items;
  final int total;
  final String? nextCursor;
}

class AdminComment {
  const AdminComment({required this.comment, required this.postTitle});
  final CommunityComment comment;
  final String postTitle;
  String get id => comment.id;
  String get postId => comment.postId;
  String get authorName => comment.authorName;
  String get content => comment.content;
  DateTime get createdAt => comment.createdAt;
  bool get canDelete => comment.canDelete;
  factory AdminComment.fromJson(Json json) => AdminComment(
    comment: CommunityComment.fromJson(json),
    postTitle: json['postTitle'] as String? ?? '',
  );
}

class AdminUser {
  const AdminUser({
    required this.id,
    required this.username,
    required this.createdAt,
    this.emailMasked = '',
    this.phoneMasked = '',
    this.emailVerified = false,
    this.disabled = false,
    this.postCount = 0,
    this.commentCount = 0,
  });
  final String id, username, emailMasked, phoneMasked;
  final DateTime createdAt;
  final bool emailVerified, disabled;
  final int postCount, commentCount;
  factory AdminUser.fromJson(Json json) => AdminUser(
    id: json['id'] as String,
    username: json['username'] as String,
    emailMasked: json['emailMasked'] as String? ?? '',
    phoneMasked: json['phoneMasked'] as String? ?? '',
    emailVerified: json['emailVerified'] == true,
    createdAt: DateTime.parse(json['createdAt'] as String),
    disabled: json['disabled'] == true,
    postCount: (json['postCount'] as num?)?.toInt() ?? 0,
    commentCount: (json['commentCount'] as num?)?.toInt() ?? 0,
  );
}

class AdminAuditEntry {
  const AdminAuditEntry({
    required this.id,
    required this.actorName,
    required this.action,
    required this.targetType,
    required this.targetId,
    required this.targetLabel,
    required this.createdAt,
    this.reason = '',
  });
  final String id, actorName, action, targetType, targetId, targetLabel, reason;
  final DateTime createdAt;
  factory AdminAuditEntry.fromJson(Json json) => AdminAuditEntry(
    id: json['id'] as String,
    actorName: json['actorName'] as String,
    action: json['action'] as String,
    targetType: json['targetType'] as String,
    targetId: json['targetId'] as String,
    targetLabel: json['targetLabel'] as String? ?? '',
    reason: json['reason'] as String? ?? '',
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

class AdminStatusComponent {
  const AdminStatusComponent({
    required this.id,
    required this.name,
    required this.status,
    required this.configured,
    required this.healthy,
    required this.detail,
    this.lastHeartbeatAt,
  });
  final String id, name, status, detail;
  final bool configured;
  final bool? healthy;
  final DateTime? lastHeartbeatAt;
  factory AdminStatusComponent.fromJson(Json json) => AdminStatusComponent(
    id: json['id'] as String,
    name: json['name'] as String,
    status: json['status'] as String,
    configured: json['configured'] == true,
    healthy: json['healthy'] as bool?,
    detail: json['detail'] as String,
    lastHeartbeatAt: json['lastHeartbeatAt'] == null
        ? null
        : DateTime.parse(json['lastHeartbeatAt'] as String),
  );
}

class AdminStatus {
  AdminStatus({required List<AdminStatusComponent> components})
    : components = List.unmodifiable(components);
  final List<AdminStatusComponent> components;
  factory AdminStatus.fromJson(Json json) => AdminStatus(
    components: readList(json['components'], AdminStatusComponent.fromJson),
  );
}

Json _analyticsObject(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const FormatException('Invalid analytics object.');
  }
  return Map<String, dynamic>.from(value);
}

int _analyticsCount(Object? value) {
  if (value is! int || value < 0) {
    throw const FormatException(
      'Analytics counts must be non-negative integers.',
    );
  }
  return value;
}

String _analyticsDate(Object? value) {
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throw const FormatException('Invalid analytics date.');
  }
  final parts = value.split('-').map(int.parse).toList();
  final date = DateTime.utc(parts[0], parts[1], parts[2]);
  if (date.year != parts[0] || date.month != parts[1] || date.day != parts[2]) {
    throw const FormatException('Invalid analytics calendar date.');
  }
  return value;
}

DateTime _analyticsInstant(Object? value) {
  if (value is! String) {
    throw const FormatException('Invalid analytics instant.');
  }
  final match = RegExp(
    r'^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$',
  ).firstMatch(value);
  if (match == null ||
      int.parse(match[2]!) > 23 ||
      int.parse(match[3]!) > 59 ||
      int.parse(match[4]!) > 59) {
    throw const FormatException('Invalid analytics instant.');
  }
  _analyticsDate(match[1]);
  final offset = match[5]!;
  if (offset != 'Z') {
    final hours = int.parse(offset.substring(1, 3));
    final minutes = int.parse(offset.substring(4, 6));
    if (hours > 14 || minutes > 59 || (hours == 14 && minutes != 0)) {
      throw const FormatException('Invalid analytics offset.');
    }
  }
  return DateTime.parse(value).toUtc();
}

List<T> _analyticsList<T>(Object? value, T Function(Json) decode) {
  if (value is! List) throw const FormatException('Invalid analytics list.');
  return List.unmodifiable(value.map((item) => decode(_analyticsObject(item))));
}

String _analyticsHongKongDate(DateTime instant) => instant
    .toUtc()
    .add(const Duration(hours: 8))
    .toIso8601String()
    .substring(0, 10);

class AdminAnalyticsMetric {
  const AdminAnalyticsMetric({required this.value, required this.previous});
  final int value, previous;
  factory AdminAnalyticsMetric.fromJson(Json json) => AdminAnalyticsMetric(
    value: _analyticsCount(json['value']),
    previous: _analyticsCount(json['previous']),
  );
}

class AdminAnalyticsSummary {
  const AdminAnalyticsSummary({
    required this.newUsers,
    required this.contributors,
    required this.posts,
    required this.comments,
  });
  final AdminAnalyticsMetric newUsers, contributors, posts, comments;
  factory AdminAnalyticsSummary.fromJson(Json json) => AdminAnalyticsSummary(
    newUsers: AdminAnalyticsMetric.fromJson(_analyticsObject(json['newUsers'])),
    contributors: AdminAnalyticsMetric.fromJson(
      _analyticsObject(json['contributors']),
    ),
    posts: AdminAnalyticsMetric.fromJson(_analyticsObject(json['posts'])),
    comments: AdminAnalyticsMetric.fromJson(_analyticsObject(json['comments'])),
  );
}

class AdminAnalyticsPeriod {
  const AdminAnalyticsPeriod({
    required this.startDate,
    required this.endDate,
    required this.endAt,
  });
  final String startDate, endDate;
  final DateTime endAt;
  factory AdminAnalyticsPeriod.fromJson(Json json) => AdminAnalyticsPeriod(
    startDate: _analyticsDate(json['startDate']),
    endDate: _analyticsDate(json['endDate']),
    endAt: _analyticsInstant(json['endAt']),
  );
}

class AdminAnalyticsDay {
  const AdminAnalyticsDay({
    required this.date,
    required this.newUsers,
    required this.contributors,
    required this.posts,
    required this.comments,
  });
  final String date;
  final int newUsers, contributors, posts, comments;
  factory AdminAnalyticsDay.fromJson(Json json) => AdminAnalyticsDay(
    date: _analyticsDate(json['date']),
    newUsers: _analyticsCount(json['newUsers']),
    contributors: _analyticsCount(json['contributors']),
    posts: _analyticsCount(json['posts']),
    comments: _analyticsCount(json['comments']),
  );
}

class AdminAnalyticsCategory {
  const AdminAnalyticsCategory({
    required this.key,
    required this.label,
    required this.count,
  });
  final String key, label;
  final int count;
  factory AdminAnalyticsCategory.fromJson(Json json) {
    final key = json['key'], label = json['label'];
    if (!const {'daily', 'feedback', 'activity'}.contains(key) ||
        label is! String ||
        label.trim().isEmpty) {
      throw const FormatException('Invalid analytics content category.');
    }
    return AdminAnalyticsCategory(
      key: key as String,
      label: label,
      count: _analyticsCount(json['count']),
    );
  }
}

class AdminAnalyticsInteractions {
  const AdminAnalyticsInteractions({
    required this.likes,
    required this.participants,
  });
  final int likes, participants;
  factory AdminAnalyticsInteractions.fromJson(Json json) =>
      AdminAnalyticsInteractions(
        likes: _analyticsCount(json['likes']),
        participants: _analyticsCount(json['participants']),
      );
}

class AdminAnalyticsPost {
  const AdminAnalyticsPost({required this.post, required this.interactions});
  final CommunityPost post;
  final int interactions;
  factory AdminAnalyticsPost.fromJson(Json json) {
    final raw = _analyticsObject(json['post']);
    final likes = _analyticsCount(raw['likeCount']);
    final comments = _analyticsCount(raw['commentCount']);
    final participants = _analyticsCount(raw['participantCount']);
    final interactions = _analyticsCount(json['interactions']);
    if (interactions == 0 || interactions != likes + comments + participants) {
      throw const FormatException('Invalid analytics interaction total.');
    }
    _analyticsInstant(raw['createdAt']);
    final post = CommunityPost.fromJson(raw);
    if (post.id.isEmpty || (!post.isActivity && participants != 0)) {
      throw const FormatException('Invalid analytics ranked post.');
    }
    return AdminAnalyticsPost(post: post, interactions: interactions);
  }
}

class AdminAnalytics {
  AdminAnalytics({
    required this.days,
    required this.timeZone,
    required this.generatedAt,
    required this.period,
    required this.previousPeriod,
    required this.summary,
    required List<AdminAnalyticsDay> daily,
    required List<AdminAnalyticsCategory> contentTypes,
    required this.currentInteractions,
    required List<AdminAnalyticsPost> topPosts,
  }) : daily = List.unmodifiable(daily),
       contentTypes = List.unmodifiable(contentTypes),
       topPosts = List.unmodifiable(topPosts);
  final int days;
  final String timeZone;
  final DateTime generatedAt;
  final AdminAnalyticsPeriod period, previousPeriod;
  final AdminAnalyticsSummary summary;
  final List<AdminAnalyticsDay> daily;
  final List<AdminAnalyticsCategory> contentTypes;
  final AdminAnalyticsInteractions currentInteractions;
  final List<AdminAnalyticsPost> topPosts;

  factory AdminAnalytics.fromJson(Json json) {
    final days = json['days'];
    if (days is! int ||
        !const {7, 30, 90}.contains(days) ||
        json['timeZone'] != 'Asia/Hong_Kong') {
      throw const FormatException('Invalid analytics range or time zone.');
    }
    final value = AdminAnalytics(
      days: days,
      timeZone: 'Asia/Hong_Kong',
      generatedAt: _analyticsInstant(json['generatedAt']),
      period: AdminAnalyticsPeriod.fromJson(_analyticsObject(json['period'])),
      previousPeriod: AdminAnalyticsPeriod.fromJson(
        _analyticsObject(json['previousPeriod']),
      ),
      summary: AdminAnalyticsSummary.fromJson(
        _analyticsObject(json['summary']),
      ),
      daily: _analyticsList(json['daily'], AdminAnalyticsDay.fromJson),
      contentTypes: _analyticsList(
        json['contentTypes'],
        AdminAnalyticsCategory.fromJson,
      ),
      currentInteractions: AdminAnalyticsInteractions.fromJson(
        _analyticsObject(json['currentInteractions']),
      ),
      topPosts: _analyticsList(json['topPosts'], AdminAnalyticsPost.fromJson),
    );
    value._validate();
    return value;
  }

  void _validate() {
    final start = DateTime.parse('${period.startDate}T00:00:00Z');
    final end = DateTime.parse('${period.endDate}T00:00:00Z');
    final previousStart = DateTime.parse(
      '${previousPeriod.startDate}T00:00:00Z',
    );
    final previousEnd = DateTime.parse('${previousPeriod.endDate}T00:00:00Z');
    if (daily.length != days ||
        end.difference(start).inDays != days - 1 ||
        previousEnd.difference(previousStart).inDays != days - 1 ||
        previousEnd.add(const Duration(days: 1)) != start ||
        period.endAt != generatedAt ||
        previousPeriod.endAt != generatedAt.subtract(Duration(days: days)) ||
        _analyticsHongKongDate(generatedAt) != period.endDate ||
        _analyticsHongKongDate(previousPeriod.endAt) !=
            previousPeriod.endDate) {
      throw const FormatException(
        'Analytics periods do not match the selected range.',
      );
    }
    var newUsers = 0, posts = 0, comments = 0, authors = 0, largestAuthors = 0;
    for (var index = 0; index < daily.length; index++) {
      final day = daily[index];
      if (day.date !=
              start
                  .add(Duration(days: index))
                  .toIso8601String()
                  .substring(0, 10) ||
          day.contributors > day.posts + day.comments) {
        throw const FormatException(
          'Analytics days are missing, duplicated, or inconsistent.',
        );
      }
      newUsers += day.newUsers;
      posts += day.posts;
      comments += day.comments;
      authors += day.contributors;
      if (day.contributors > largestAuthors) largestAuthors = day.contributors;
    }
    final unique = summary.contributors.value;
    final previousActivity = summary.posts.previous + summary.comments.previous;
    if (newUsers != summary.newUsers.value ||
        posts != summary.posts.value ||
        comments != summary.comments.value ||
        unique < largestAuthors ||
        unique > authors ||
        unique > posts + comments ||
        summary.contributors.previous > previousActivity) {
      throw const FormatException(
        'Analytics summary and daily counts disagree.',
      );
    }
    if (contentTypes.length != 3 ||
        contentTypes.map((item) => item.key).toSet().length != 3 ||
        contentTypes.fold<int>(0, (sum, item) => sum + item.count) != posts ||
        topPosts.length > 5 ||
        topPosts.length > posts) {
      throw const FormatException('Analytics content totals disagree.');
    }
    final ids = <String>{}, rankedAuthors = <String>{};
    var previousRank = -1, rankedLikes = 0, rankedParticipants = 0;
    final firstInstant = start.subtract(const Duration(hours: 8));
    for (final item in topPosts) {
      if (!ids.add(item.post.id) ||
          (previousRank >= 0 && item.interactions > previousRank) ||
          item.post.createdAt.isBefore(firstInstant) ||
          item.post.createdAt.isAfter(period.endAt)) {
        throw const FormatException(
          'Analytics ranking has invalid items or order.',
        );
      }
      previousRank = item.interactions;
      if (item.post.authorId case final author?) rankedAuthors.add(author);
      rankedLikes += item.post.likeCount;
      rankedParticipants += item.post.participantCount;
    }
    if (rankedAuthors.length > unique ||
        rankedLikes > currentInteractions.likes ||
        rankedParticipants > currentInteractions.participants) {
      throw const FormatException('Analytics current interactions disagree.');
    }
  }
}
