import 'models.dart';

const communityImageMaxBytes = 8 * 1024 * 1024;
const communityImageMimeTypes = {'image/jpeg', 'image/png', 'image/webp'};

class CommunityMedia {
  const CommunityMedia({
    required this.id,
    required this.url,
    required this.width,
    required this.height,
    required this.mimeType,
    required this.bytes,
  });
  final String id, url, mimeType;
  final int width, height, bytes;
  factory CommunityMedia.fromJson(Json json) => CommunityMedia(
    id: json['id'] as String,
    url: json['url'] as String,
    width: (json['width'] as num).toInt(),
    height: (json['height'] as num).toInt(),
    mimeType: json['mimeType'] as String,
    bytes: (json['bytes'] as num).toInt(),
  );
}

class CommunityPermissions {
  const CommunityPermissions({
    this.publishOfficial = false,
    this.publishActivity = false,
    this.moderatePosts = false,
    this.moderateComments = false,
  });
  final bool publishOfficial, publishActivity, moderatePosts, moderateComments;
  factory CommunityPermissions.fromJson(Json json) => CommunityPermissions(
    publishOfficial: json['publishOfficial'] == true,
    publishActivity: json['publishActivity'] == true,
    moderatePosts: json['moderatePosts'] == true,
    moderateComments: json['moderateComments'] == true,
  );
  Json toJson() => {
    'publishOfficial': publishOfficial,
    'publishActivity': publishActivity,
    'moderatePosts': moderatePosts,
    'moderateComments': moderateComments,
  };
  CommunityPermissions copyWith({
    bool? publishOfficial,
    bool? publishActivity,
    bool? moderatePosts,
    bool? moderateComments,
  }) => CommunityPermissions(
    publishOfficial: publishOfficial ?? this.publishOfficial,
    publishActivity: publishActivity ?? this.publishActivity,
    moderatePosts: moderatePosts ?? this.moderatePosts,
    moderateComments: moderateComments ?? this.moderateComments,
  );
}

class CommunityViewer {
  const CommunityViewer({
    this.signedIn = false,
    this.canPublishOfficial = false,
    this.isOfficial = false,
    this.isAdmin = false,
    this.canManageAdmins = false,
    this.permissions = const CommunityPermissions(),
  });
  final bool signedIn, canPublishOfficial, isOfficial, isAdmin, canManageAdmins;
  final CommunityPermissions permissions;
  factory CommunityViewer.fromJson(Json json) => CommunityViewer(
    signedIn: json['signedIn'] == true,
    canPublishOfficial:
        json['canPublishOfficial'] == true ||
        (json['permissions'] is Map &&
            (json['permissions'] as Map)['publishOfficial'] == true),
    isOfficial: json['isOfficial'] == true,
    isAdmin: json['isAdmin'] == true,
    canManageAdmins: json['canManageAdmins'] == true,
    permissions: CommunityPermissions.fromJson(
      json['permissions'] is Map
          ? Map<String, dynamic>.from(json['permissions'] as Map)
          : const {},
    ),
  );
}

class CommunityPost {
  const CommunityPost({
    required this.id,
    this.authorId,
    required this.authorName,
    this.authorIsOfficial = false,
    this.isOfficial = false,
    this.isAdmin = false,
    this.kind = 'post',
    this.category = 'daily',
    required this.title,
    required this.content,
    required this.createdAt,
    this.startsAt,
    this.place = '',
    this.likeCount = 0,
    this.commentCount = 0,
    this.participantCount = 0,
    this.liked = false,
    this.joined = false,
    this.canDelete = false,
    this.media = const [],
  });
  final String id, authorName, kind, category, title, content, place;
  final String? authorId;
  final bool authorIsOfficial, isOfficial, isAdmin, liked, joined, canDelete;
  final DateTime createdAt;
  final DateTime? startsAt;
  final int likeCount, commentCount, participantCount;
  final List<CommunityMedia> media;
  bool get isActivity => kind == 'activity';

  factory CommunityPost.fromJson(Json json) => CommunityPost(
    id: json['id'] as String,
    authorId: json['authorId'] as String?,
    authorName: json['authorName'] as String,
    authorIsOfficial: json['authorIsOfficial'] == true,
    isOfficial: json['isOfficial'] == true,
    isAdmin: json['isAdmin'] == true,
    kind: json['kind'] as String? ?? 'post',
    category: json['category'] as String? ?? 'daily',
    title: json['title'] as String,
    content: json['content'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    startsAt: json['startsAt'] == null
        ? null
        : DateTime.parse(json['startsAt'] as String),
    place: json['place'] as String? ?? '',
    likeCount: (json['likeCount'] as num?)?.toInt() ?? 0,
    commentCount: (json['commentCount'] as num?)?.toInt() ?? 0,
    participantCount: (json['participantCount'] as num?)?.toInt() ?? 0,
    liked: json['liked'] == true,
    joined: json['joined'] == true,
    canDelete: json['canDelete'] == true,
    media: List.unmodifiable(readList(json['media'], CommunityMedia.fromJson)),
  );
}

class CommunityComment {
  const CommunityComment({
    required this.id,
    required this.postId,
    this.authorId,
    required this.authorName,
    this.authorIsOfficial = false,
    this.isOfficial = false,
    this.isAdmin = false,
    required this.content,
    required this.createdAt,
    this.canDelete = false,
  });
  final String id, postId, authorName, content;
  final String? authorId;
  final bool authorIsOfficial, isOfficial, isAdmin, canDelete;
  final DateTime createdAt;
  factory CommunityComment.fromJson(Json json) => CommunityComment(
    id: json['id'] as String,
    postId: json['postId'] as String,
    authorId: json['authorId'] as String?,
    authorName: json['authorName'] as String,
    authorIsOfficial: json['authorIsOfficial'] == true,
    isOfficial: json['isOfficial'] == true,
    isAdmin: json['isAdmin'] == true,
    content: json['content'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    canDelete: json['canDelete'] == true,
  );
}

class CommunityFeed {
  CommunityFeed({
    required List<CommunityPost> posts,
    this.nextCursor,
    this.viewer = const CommunityViewer(),
  }) : posts = List.unmodifiable(posts);
  final List<CommunityPost> posts;
  final String? nextCursor;
  final CommunityViewer viewer;
  factory CommunityFeed.fromJson(Json json) => CommunityFeed(
    posts: readList(json['posts'], CommunityPost.fromJson),
    nextCursor: json['nextCursor'] as String?,
    viewer: CommunityViewer.fromJson(
      Map<String, dynamic>.from(json['viewer'] as Map),
    ),
  );
}

class CommunityDetail {
  CommunityDetail({
    required this.post,
    required List<CommunityComment> comments,
    this.commentsNextCursor,
    this.viewer = const CommunityViewer(),
  }) : comments = List.unmodifiable(comments);
  final CommunityPost post;
  final List<CommunityComment> comments;
  final String? commentsNextCursor;
  final CommunityViewer viewer;
  factory CommunityDetail.fromJson(Json json) => CommunityDetail(
    post: CommunityPost.fromJson(
      Map<String, dynamic>.from(json['post'] as Map),
    ),
    comments: readList(json['comments'], CommunityComment.fromJson),
    commentsNextCursor: json['commentsNextCursor'] as String?,
    viewer: CommunityViewer.fromJson(
      Map<String, dynamic>.from(json['viewer'] as Map),
    ),
  );
}

class CommunityCommentResult {
  const CommunityCommentResult({required this.comment, required this.post});
  final CommunityComment comment;
  final CommunityPost post;
}

class CommunityAdmin {
  const CommunityAdmin({
    required this.userId,
    required this.username,
    this.permissions = const CommunityPermissions(),
  });
  final String userId, username;
  final CommunityPermissions permissions;
  factory CommunityAdmin.fromJson(Json json) => CommunityAdmin(
    userId: json['userId'] as String,
    username: json['username'] as String,
    permissions: CommunityPermissions.fromJson(
      Map<String, dynamic>.from(json['permissions'] as Map),
    ),
  );
}

class CommunityAdminApplication {
  const CommunityAdminApplication({
    required this.id,
    required this.userId,
    required this.username,
    required this.reason,
    required this.status,
    required this.createdAt,
  });
  final String id, userId, username, reason, status;
  final DateTime createdAt;
  factory CommunityAdminApplication.fromJson(Json json) =>
      CommunityAdminApplication(
        id: json['id'] as String,
        userId: json['userId'] as String,
        username: json['username'] as String,
        reason: json['reason'] as String,
        status: json['status'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}

class CommunityManagement {
  CommunityManagement({
    required this.viewer,
    List<CommunityAdmin> admins = const [],
    List<CommunityAdminApplication> applications = const [],
    this.myApplication,
  }) : admins = List.unmodifiable(admins),
       applications = List.unmodifiable(applications);
  final CommunityViewer viewer;
  final List<CommunityAdmin> admins;
  final List<CommunityAdminApplication> applications;
  final CommunityAdminApplication? myApplication;
  factory CommunityManagement.fromJson(Json json) => CommunityManagement(
    viewer: CommunityViewer.fromJson(
      Map<String, dynamic>.from(json['viewer'] as Map),
    ),
    admins: readList(json['admins'], CommunityAdmin.fromJson),
    applications: readList(
      json['applications'],
      CommunityAdminApplication.fromJson,
    ),
    myApplication: json['myApplication'] == null
        ? null
        : CommunityAdminApplication.fromJson(
            Map<String, dynamic>.from(json['myApplication'] as Map),
          ),
  );
}
