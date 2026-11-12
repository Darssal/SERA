"""Explicit OpenAPI contracts for native Bearer and browser cookie clients.

The compatibility endpoints retain the existing runtime validation/error codes;
these schemas describe the same payloads without exposing catchall routes as API.
"""
from copy import deepcopy

from fastapi import Request
from fastapi.openapi.utils import get_openapi

from understanding_contract import UNDERSTANDING_OUTPUT_SCHEMA


def ref(name): return {'$ref': '#/components/schemas/' + name}
def obj(properties, required=(), **extra):
    return {'type': 'object', 'properties': properties, 'required': list(required), **extra}
def string(**kw): return {'type': 'string', **kw}
def integer(minimum=0, **kw): return {'type': 'integer', 'minimum': minimum, **kw}
def array(items, **kw): return {'type': 'array', 'items': items, **kw}


def understanding_response_schema():
    # Current provider output and public OpenAPI share one contract. Metadata is
    # supplied by the server; history decoding may remain more permissive.
    schema = deepcopy(UNDERSTANDING_OUTPUT_SCHEMA)
    schema['properties'].update({
        'source': string(enum=['siliconflow']),
        'model': string(minLength=1, maxLength=200),
        'references': array(obj({'url': string(format='uri'), 'title': string(),
            'retrievedAt': string(format='date-time')}, ['url']), maxItems=2),
        'research': obj({'modelCalls': integer(1, maximum=4),
            'requestedToolCalls': integer(0, maximum=4), 'toolCalls': integer(0, maximum=4),
            'searchCalls': integer(0, maximum=2), 'readCalls': integer(0, maximum=2),
            'errors': array(string()), 'status': string(enum=['pages_read', 'unverified']),
            'usage': obj({}, additionalProperties=integer()), 'wallMilliseconds': integer()},
            ['modelCalls', 'toolCalls', 'status']),
    })
    schema['required'].extend(['source', 'model'])
    return schema


def community_schemas():
    """Describe community_store validation; these schemas never register routes."""
    boolean = {'type': 'boolean'}
    permission_names = ['publishOfficial', 'publishActivity', 'moderatePosts', 'moderateComments']
    single_line = r'^[^\x00-\x1f\x7f]*$'
    nonempty_text = r'^(?=[\s\S]*\S)[^\x00-\x08\x0b\x0c\x0e-\x1f\x7f]*$'
    post = {
        'id': ref('CommunityIdentifier'), 'authorId': {'type': ['string', 'null']},
        'authorName': string(), 'authorIsOfficial': boolean, 'isOfficial': boolean, 'isAdmin': boolean,
        'kind': string(enum=['post', 'activity']), 'category': string(enum=['daily', 'feedback'], default='daily'),
        'title': string(maxLength=120),
        'content': string(minLength=1, maxLength=5000), 'createdAt': string(format='date-time'),
        'startsAt': {'type': ['string', 'null'], 'format': 'date-time'}, 'place': string(maxLength=120),
        'likeCount': integer(), 'commentCount': integer(), 'participantCount': integer(),
        'liked': boolean, 'joined': boolean, 'canDelete': boolean,
        'media': array(ref('CommunityMedia'), maxItems=3),
    }
    comment = {'id': ref('CommunityIdentifier'), 'postId': ref('CommunityIdentifier'),
        'authorId': string(), 'authorName': string(), 'authorIsOfficial': boolean, 'isOfficial': boolean, 'isAdmin': boolean,
        'content': string(minLength=1, maxLength=1000), 'createdAt': string(format='date-time'), 'canDelete': boolean}
    viewer = {'signedIn': boolean, 'isOfficial': boolean, 'isAdmin': boolean,
        'canManageAdmins': boolean, 'permissions': ref('CommunityPermissions'),
        'canPublishOfficial': {'type': 'boolean',
            'description': 'Compatibility flag: publishOfficial OR publishActivity. Check the individual permission for the chosen content kind.'}}
    application = {'id': ref('CommunityIdentifier'), 'userId': string(), 'username': string(),
        'reason': string(minLength=1, maxLength=500), 'status': string(enum=['pending', 'approved', 'rejected']),
        'createdAt': string(format='date-time')}
    cursor = {'type': ['string', 'null'], 'maxLength': 512}
    create_post = obj({
        'requestId': ref('CommunityIdentifier'),
        'title': string(maxLength=120, pattern=single_line, default=''),
        'content': string(minLength=1, maxLength=5000, pattern=nonempty_text),
        'kind': string(enum=['post', 'activity'], default='post'),
        'category': string(enum=['daily', 'feedback'], default='daily'),
        'official': {'type': 'boolean', 'default': False},
        'startsAt': {'type': ['string', 'null'], 'format': 'date-time', 'maxLength': 64},
        'place': string(maxLength=120, pattern=single_line, default=''),
        'mediaIds': array(ref('CommunityIdentifier'), maxItems=3, uniqueItems=True, default=[],
                          description='Ordered IDs uploaded by this account. Pending uploads expire after 24 hours; each image may be attached to one post.'),
    }, ['requestId', 'content'], additionalProperties=False, allOf=[{
        'if': {'properties': {'kind': {'const': 'activity'}}, 'required': ['kind']},
        'then': {'required': ['title', 'startsAt', 'official'], 'properties': {
            'title': string(minLength=1, pattern=r'\S'),
            'startsAt': string(format='date-time', maxLength=64), 'official': {'const': True},
            'category': {'const': 'daily'}}},
        'else': {'properties': {'startsAt': {'type': 'null'}, 'place': string(pattern=r'^\s*$')}},
    }], description='Text is trimmed before saving; limits also apply before trimming. Activity time must include a timezone and is returned in UTC. Activities require publishActivity and official=true, independently of publishOfficial; official posts require publishOfficial. Activities always use category=daily; posts may use daily or feedback. Ordinary posts have no activity time or nonblank place. requestId is scoped to the account across all create operations; changing category is a different payload.')
    return {
        'CommunityMedia': obj({
            'id': ref('CommunityIdentifier'),
            'url': string(format='uri-reference', description='Relative API URL; published images are publicly readable, pending images require their uploader session.'),
            'width': integer(1, maximum=1600), 'height': integer(1, maximum=1600),
            'mimeType': string(enum=['image/jpeg', 'image/png']), 'bytes': integer(1),
        }, ['id', 'url', 'width', 'height', 'mimeType', 'bytes'], additionalProperties=False,
            description='Server-normalized image with orientation applied and metadata removed. Transparency is preserved as PNG.'),
        'CommunityMediaResult': obj({'media': ref('CommunityMedia')}, ['media'], additionalProperties=False),
        'CommunityMediaError': obj({'error': string(), 'code': string(),
            'details': obj({'mediaIds': array(ref('CommunityIdentifier'), maxItems=3)}, ['mediaIds'])},
            ['error', 'code'], description='Expired post attachments identify the affected media IDs so other successful uploads can be retained.'),
        'CommunityIdentifier': string(minLength=1, maxLength=128, pattern=r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'),
        'CommunityPermissions': obj({name: boolean for name in permission_names}, permission_names, additionalProperties=False),
        'CommunityViewer': obj(viewer, viewer, additionalProperties=False,
            description='isOfficial/canManageAdmins identify an allowlisted owner. Administrators cannot grant or review administrator permissions.'),
        'CommunityPost': obj(post, post, additionalProperties=False,
            description='isOfficial describes official content. authorIsOfficial identifies the actual allowlisted owner or seeded system author, independently of whether an administrator published official content; isAdmin describes the current author role. Counts and viewer flags are computed by the server, including canDelete for authors or permitted moderators. Seeded system posts have authorId=null.'),
        'CommunityComment': obj(comment, comment, additionalProperties=False,
            description='authorIsOfficial identifies the actual allowlisted owner or system author. Ordinary administrator comments retain their own author identity.'),
        'CommunityFeed': obj({'posts': array(ref('CommunityPost'), maxItems=100), 'nextCursor': cursor,
            'viewer': ref('CommunityViewer')}, ['posts', 'nextCursor', 'viewer'], additionalProperties=False),
        'CommunityDetail': obj({'post': ref('CommunityPost'), 'comments': array(ref('CommunityComment'), maxItems=100),
            'commentsNextCursor': cursor, 'viewer': ref('CommunityViewer')},
            ['post', 'comments', 'commentsNextCursor', 'viewer'], additionalProperties=False),
        'CommunityCreatePost': create_post,
        'CommunityPostResult': obj({'post': ref('CommunityPost')}, ['post'], additionalProperties=False),
        'CommunityCreateComment': obj({'requestId': ref('CommunityIdentifier'),
            'content': string(minLength=1, maxLength=1000, pattern=nonempty_text)},
            ['requestId', 'content'], additionalProperties=False),
        'CommunityCommentResult': obj({'comment': ref('CommunityComment'), 'post': ref('CommunityPost')},
            ['comment', 'post'], additionalProperties=False),
        'CommunityLike': obj({'liked': boolean}, ['liked'], additionalProperties=False),
        'CommunityJoin': obj({'joined': boolean}, ['joined'], additionalProperties=False),
        'CommunityDeleted': obj({'deleted': {'type': 'boolean', 'const': True}}, ['deleted'], additionalProperties=False),
        'CommunityUpdated': obj({'updated': {'type': 'boolean', 'const': True}}, ['updated'], additionalProperties=False),
        'CommunityAdmin': obj({'userId': string(), 'username': string(), 'permissions': ref('CommunityPermissions')},
            ['userId', 'username', 'permissions'], additionalProperties=False),
        'CommunityApplication': obj(application, application, additionalProperties=False),
        'CommunityManagement': obj({'viewer': ref('CommunityViewer'), 'admins': array(ref('CommunityAdmin')),
            'applications': array(ref('CommunityApplication')),
            'myApplication': {'anyOf': [ref('CommunityApplication'), {'type': 'null'}]}},
            ['viewer', 'admins', 'applications', 'myApplication'], additionalProperties=False,
            description='Only owners receive admins and applications; other signed-in readers receive empty lists and their own latest application or null.'),
        'CommunityApplyAdmin': obj({'requestId': ref('CommunityIdentifier'),
            'reason': string(minLength=1, maxLength=500, pattern=nonempty_text)},
            ['requestId', 'reason'], additionalProperties=False),
        'CommunityApplicationResult': obj({'application': ref('CommunityApplication')}, ['application'], additionalProperties=False),
        'CommunityAddAdmin': obj({'identifier': string(minLength=1, maxLength=254, pattern=single_line,
            description='Exact existing username or email, compared case-insensitively; must resolve to one account.'),
            'permissions': ref('CommunityPermissions')}, ['identifier', 'permissions'], additionalProperties=False),
        'CommunityUpdateAdmin': obj({'permissions': ref('CommunityPermissions')}, ['permissions'], additionalProperties=False),
        'CommunityReviewApplication': {'oneOf': [
            obj({'status': {'type': 'string', 'const': 'approved'}, 'permissions': ref('CommunityPermissions')},
                ['status', 'permissions'], additionalProperties=False),
            obj({'status': {'type': 'string', 'const': 'rejected'}}, ['status'], additionalProperties=False)],
            'description': 'Approval supplies all four permissions; rejection must omit permissions. Identical review retries are safe and do not restore subsequently revoked permissions.'},
    }


def describe_community(schema):
    # These explicit endpoints already exist in community_api. Do not create
    # compatibility forwarders, including on minimal apps used by legacy tests.
    prefix = '/api/v1/community'
    contracts = [
        ('/media', 'post', None, 'CommunityMediaResult', 201, (409, 410, 415), 'Upload raw JPEG, PNG or WebP bytes, at most 8 MiB and 16 million decoded pixels. Animated images are rejected. The server strips metadata and normalizes size and format. Account-scoped Idempotency-Key retries return the same upload; pending uploads expire after 24 hours.'),
        ('/media/{media_id}', 'get', None, None, 200, (404,), 'Read normalized image bytes. Published images are public; pending images require the uploading account session. Missing, expired or another account pending images return 404.'),
        ('/posts', 'get', None, 'CommunityFeed', 200, (), 'Read posts in descending insertion order; cursor is bound to the selected filter.'),
        ('/posts/{post_id}', 'get', None, 'CommunityDetail', 200, (404,), 'Read one post and comments in ascending insertion order; commentCursor belongs to this post.'),
        ('/posts', 'post', 'CommunityCreatePost', 'CommunityPostResult', 201, (409, 410), 'Publish a post or permitted official activity. Repeating requestId with the same content returns the original result; a deleted result is never recreated.'),
        ('/posts/{post_id}/comments', 'post', 'CommunityCreateComment', 'CommunityCommentResult', 201, (404, 409, 410), 'Publish a comment with account-scoped requestId idempotency.'),
        ('/posts/{post_id}/like', 'put', 'CommunityLike', 'CommunityPostResult', 200, (404,), 'Set liked to the requested boolean; repeating the same value is idempotent.'),
        ('/posts/{post_id}/join', 'put', 'CommunityJoin', 'CommunityPostResult', 200, (404,), 'Set joined for an activity; ordinary posts cannot be joined.'),
        ('/posts/{post_id}', 'delete', None, 'CommunityDeleted', 200, (), 'Author or moderatePosts permission required. Already absent content returns deleted=true.'),
        ('/comments/{comment_id}', 'delete', None, 'CommunityDeleted', 200, (), 'Author or moderateComments permission required. Already absent content returns deleted=true.'),
        ('/management', 'get', None, 'CommunityManagement', 200, (), 'Signed-in management view; the server restricts lists to owners and exposes only the current reader\'s latest application otherwise.'),
        ('/admin-applications', 'post', 'CommunityApplyAdmin', 'CommunityApplicationResult', 201, (409, 410), 'Apply for administrator status. One pending application per account; existing administrators/owners cannot apply.'),
        ('/admins', 'post', 'CommunityAddAdmin', 'CommunityUpdated', 200, (404,), 'Owner only. Add or update the exact account\'s four permissions and approve its pending applications.'),
        ('/admins/{user_id}', 'put', 'CommunityUpdateAdmin', 'CommunityUpdated', 200, (404,), 'Owner only. Replace all four permissions for an existing account; owner permissions are protected.'),
        ('/admins/{user_id}', 'delete', None, 'CommunityUpdated', 200, (404,), 'Owner only. Revoke administrator membership; removing it twice is safe if the account still exists.'),
        ('/admin-applications/{application_id}', 'put', 'CommunityReviewApplication', 'CommunityApplicationResult', 200, (404, 409), 'Owner only. Approve with explicit permissions or reject; conflicting decisions return 409.'),
    ]
    errors = {400: 'Invalid JSON, fields, identifier, pagination, or operation for this content kind.',
        401: 'Missing/expired login or a stale cookie account binding. Invalid supplied credentials are not treated as a guest.',
        403: 'Origin/CSRF rejected, insufficient permissions, or protected official owner.',
        404: 'Requested post, account, or application does not exist.',
        409: 'Idempotency key conflict, image already attached to another post, existing administrator, or conflicting application review.',
        410: 'The original idempotent result was deleted, or an uploaded image expired; expired images must be uploaded again with a new key.',
        413: 'Request exceeds its size limit: 64 KiB JSON, or 8 MiB / 16 million pixels for image upload.',
        415: 'Unsupported Content-Type or image bytes inconsistent with their declared format.'}
    for suffix, method, request_name, result_name, status, extra_errors, description in contracts:
        operation = schema['paths'].get(prefix + suffix, {}).get(method)
        if operation is None:
            continue
        public = method == 'get' and (suffix.startswith('/posts') or suffix.startswith('/media/'))
        operation['tags'] = ['Community']
        operation['description'] = description
        operation['security'] = ([{}] if public else []) + [{'BearerAuth': []}, {'CookieAuth': []}]
        operation['responses'] = {str(status): {'description': 'Success',
            'headers': {'Cache-Control': {'schema': {'type': 'string', 'const': 'no-store'}}},
            'content': {'application/json': {'schema': ref(result_name) if result_name else {}}}}}
        if suffix == '/media/{media_id}':
            operation['responses']['200'] = {'description': 'Normalized image bytes',
                'headers': {'Cache-Control': {'schema': {'type': 'string', 'const': 'private, no-store'}},
                            'X-Content-Type-Options': {'schema': {'type': 'string', 'const': 'nosniff'}}},
                'content': {mime: {'schema': {'type': 'string', 'format': 'binary'}}
                            for mime in ('image/jpeg', 'image/png')}}
        codes = {400, 401, 403, 413, *extra_errors, *([415] if request_name else [])}
        operation['responses'].update({str(code): {'description': errors[code],
            'content': {'application/json': {'schema': ref('Error')}}} for code in sorted(codes)})
        if suffix in ('/posts', '/media') and method == 'post':
            operation['responses']['410']['content']['application/json']['schema'] = ref('CommunityMediaError')
        if request_name:
            operation['requestBody'] = {'required': True, 'content': {'application/json': {'schema': ref(request_name)}}}
        if suffix == '/media' and method == 'post':
            operation['requestBody'] = {'required': True, 'description': 'Raw image body, not multipart or JSON; maximum 8 MiB.',
                'content': {mime: {'schema': {'type': 'string', 'format': 'binary', 'maxLength': 8 * 1024 * 1024}}
                            for mime in ('image/jpeg', 'image/png', 'image/webp')}}
        parameters = operation.setdefault('parameters', [])
        for parameter in parameters:
            if parameter['in'] == 'path': parameter['schema'] = ref('CommunityIdentifier')
        parameters.append({'in': 'header', 'name': 'X-CSRF-Token', 'required': False, 'schema': string(),
            'description': 'Required on cookie-authenticated mutations. Optional on reads, but when supplied must match the current cookie session. Not required for Bearer authentication.'})
        if suffix == '/media' and method == 'post':
            parameters.append({'in': 'header', 'name': 'Idempotency-Key', 'required': True,
                               'schema': ref('CommunityIdentifier')})
        if method == 'get' and suffix == '/posts':
            parameters.extend([
                {'in': 'query', 'name': 'filter', 'required': False, 'schema': string(enum=['all', 'official', 'feedback'], default='all'),
                 'description': 'feedback selects posts with category=feedback, including official feedback posts. all and official retain their existing content scope.'},
                {'in': 'query', 'name': 'cursor', 'required': False, 'schema': string(maxLength=512, pattern=r'^[A-Za-z0-9_-]*$'), 'description': 'Opaque nextCursor from the same filter; omit or use empty string for the first page.'},
                {'in': 'query', 'name': 'limit', 'required': False, 'schema': integer(1, maximum=100, default=20)},
            ])
        elif method == 'get' and suffix == '/posts/{post_id}':
            parameters.extend([
                {'in': 'query', 'name': 'commentCursor', 'required': False, 'schema': string(maxLength=512, pattern=r'^[A-Za-z0-9_-]*$'), 'description': 'Opaque commentsNextCursor for this post; omit or use empty string for the first page.'},
                {'in': 'query', 'name': 'commentLimit', 'required': False, 'schema': integer(1, maximum=100, default=50)},
            ])


def install_contract(app, compatibility):
    schemas = {
        'Error': obj({'error': string(), 'code': string()}, ['error']),
        'User': obj({'id': string(), 'username': string(), 'email': {'type': ['string', 'null'], 'format': 'email'},
            'phone': {'type': ['string', 'null']}, 'hasPassword': {'type': 'boolean'},
            'emailVerified': {'type': 'boolean'}}, ['id', 'username', 'email', 'emailVerified']),
        'RegisterRequest': obj({'username': string(minLength=3, maxLength=40),
            'email': string(format='email', maxLength=254), 'password': string(minLength=10, maxLength=128)},
            ['username', 'email', 'password']),
        'LoginRequest': obj({'identifier': string(maxLength=254), 'password': string(maxLength=128)}, ['identifier', 'password']),
        'AuthSession': obj({'token': string(description='Native Bearer token; empty for X-Sera-Client:web.'),
            'expiresAt': string(format='date-time'), 'user': ref('User'), 'sessionId': string(),
            'csrfToken': string(description='Send X-CSRF-Token on cookie-authenticated mutations.'),
            'cookieSession': {'type': 'boolean'}}, ['token', 'expiresAt', 'user', 'sessionId', 'csrfToken', 'cookieSession']),
        'EmailRequest': obj({'email': string(format='email')}, ['email']),
        'ActionToken': obj({'token': string()}, ['token']),
        'VerificationDelivery': obj({'sent': {'type': 'boolean'}, 'delivery': string(enum=['local', 'mailpit', 'smtp']),
            'deliveryMode': string(enum=['local', 'mailpit', 'smtp']), 'developmentPreview': {'type': 'boolean'},
            'deliveryStatus': string(enum=['development_only', 'mailpit_accepted', 'smtp_accepted', 'already_verified']), 'message': string()},
            ['sent', 'deliveryMode', 'developmentPreview', 'deliveryStatus', 'message']),
        'ResetRequestAccepted': obj({'accepted': {'type': 'boolean', 'const': True},
            'delivery': string(), 'deliveryMode': string(), 'developmentPreview': {'type': 'boolean', 'const': False},
            'deliveryStatus': string(enum=['request_accepted']), 'message': string()},
            ['accepted', 'deliveryMode', 'developmentPreview', 'deliveryStatus', 'message']),
        'DevelopmentMailbox': obj({'deliveryMode': string(enum=['local']), 'message': string(),
            'mail': {'anyOf': [obj({'subject': string(), 'verificationUrl': string(format='uri'),
                'expiresAt': string(format='date-time')}, ['subject', 'verificationUrl', 'expiresAt']), {'type': 'null'}]}},
            ['deliveryMode', 'message', 'mail']),
        'ResetPassword': obj({'token': string(), 'password': string(minLength=10, maxLength=128)}, ['token', 'password']),
        'DeleteAccount': obj({'password': string(maxLength=128), 'phoneProof': string(maxLength=512)}, []),
        'PhoneCapabilities': obj({'enabled': {'type': 'boolean'}, 'message': string(),
            'codeLength': integer(4, maximum=6), 'cooldownSeconds': integer(1)}, ['enabled', 'message']),
        'PhoneChallengeRequest': obj({'phone': string(maxLength=16),
            'purpose': string(enum=['login', 'bind_phone', 'sensitive'], default='login'),
            'currentPassword': string(maxLength=128)}, ['phone']),
        'PhoneChallenge': obj({'challengeId': string(), 'maskedPhone': string(),
            'expiresAt': string(format='date-time'), 'resendAt': string(format='date-time'),
            'message': string(), 'deliveryStatus': string()}, ['challengeId', 'expiresAt', 'resendAt', 'message']),
        'PhoneCode': obj({'challengeId': string(), 'code': string(pattern='^[0-9]{6}$'),
            'acceptRegistration': {'type': 'boolean'}, 'currentPassword': string(maxLength=128)}, ['challengeId', 'code']),
        'PhoneProof': obj({'phoneProof': string(), 'expiresIn': integer(1)}, ['phoneProof', 'expiresIn']),
        'BindEmailRequest': obj({'email': string(format='email'), 'phoneProof': string(maxLength=512),
            'currentPassword': string(maxLength=128)}, ['email']),
        'SetPasswordRequest': obj({'password': string(minLength=10, maxLength=128),
            'phoneProof': string(maxLength=512), 'currentPassword': string(maxLength=128)}, ['password']),
        'Task': obj({'id': string(), 'title': string(maxLength=200), 'notes': string(maxLength=10000),
            'phase': string(maxLength=100), 'notBefore': {'type': ['string', 'null'], 'format': 'date-time'},
            'dueAt': {'type': ['string', 'null'], 'format': 'date-time'},
            'estimatedMinutes': integer(1, maximum=1440), 'revision': integer(1),
            'status': string(enum=['todo', 'in_progress', 'blocked', 'done', 'canceled']),
            'dueDate': {'type': ['string', 'null'], 'format': 'date'},
            'dependencyIds': array(string()), 'remainingMinutes': integer(-1),
            'splittable': {'type': 'boolean'}, 'minBlockMinutes': integer(5, maximum=240)}, ['id', 'title']),
        'CalendarEntry': obj({'id': string(), 'title': string(), 'start': string(format='date-time'),
            'end': string(format='date-time'), 'taskId': {'type': ['string', 'null']},
            'allDay': {'type': 'boolean'}, 'startDate': {'type': ['string', 'null'], 'format': 'date'},
            'endDate': {'type': ['string', 'null'], 'format': 'date'}, 'source': string(), 'timeZone': string(),
            'revision': integer(1)}, ['id', 'title', 'start', 'end']),
        'PlanningResultRef': obj({'kind': string(enum=['task', 'event']),
            'id': string(minLength=1, maxLength=128)}, ['kind', 'id'], additionalProperties=False),
        'PlanningMessage': obj({'id': string(minLength=1, maxLength=128),
            'role': string(enum=['user', 'assistant']), 'text': string(maxLength=10000),
            'understanding': {'type': ['object', 'null'],
                'description': 'Assistant-only display snapshot, at most 64000 UTF-8 bytes in compact JSON. Text may be empty only when this snapshot exists.'}},
            ['id', 'role', 'text'], additionalProperties=False),
        'PlanningSession': obj({'id': string(minLength=1, maxLength=128),
            'prompt': string(maxLength=10000), 'title': string(maxLength=10000), 'notes': string(maxLength=10000),
            'dailyBudget': integer(15, maximum=480), 'stage': string(maxLength=64),
            'updatedAt': string(format='date-time'),
            'messages': {'anyOf': [array(ref('PlanningMessage'), maxItems=100), {'type': 'null'}],
                'description': 'Optional ordered conversation. Message IDs are unique within a session. Missing/null means legacy history; no schema upgrade is required.'},
            'composerDraft': {'type': ['string', 'null'], 'maxLength': 10000,
                'description': 'Optional unsent composer text. Missing/null means empty. Display/persistence only; not AI input until explicitly sent.'},
            'resultEntity': {'anyOf': [ref('PlanningResultRef'), {'type': 'null'}],
                'description': 'Optional confirmed task/event result. Stable ID is planning-<kind>-sha256(UTF-8 session id). Missing preserves legacy sessions.'}},
            ['id', 'updatedAt']),
        'PlanDraft': obj({'id': string(), 'goal': {'type': 'object'},
            'items': array({'type': 'object'}), 'status': string(enum=['draft', 'committed']),
            'originalDailyBudget': {'type': ['integer', 'null'], 'minimum': 15, 'maximum': 480},
            'suggestedDailyBudget': {'type': ['integer', 'null'], 'minimum': 16, 'maximum': 1440,
                'description': 'Optional finite per-plan daily limit, strictly greater than originalDailyBudget. Other placement constraints still apply.'},
            'budgetOverrideConfirmed': {'type': 'boolean', 'default': False,
                'description': 'Explicit user approval for this plan only. An unconfirmed suggestion cannot be committed.'},
            'capacityLimited': {'type': 'boolean', 'default': False,
                'description': 'Optional soft capacity warning. All tasks are retained; tasks without calendar blocks remain unscheduled. Missing means legacy/default false.'},
            'capacityConfirmed': {'type': 'boolean', 'default': False,
                'description': 'Explicit approval of a capacity-limited plan. Requires capacityLimited=true; a committed plan with unscheduled active tasks must be confirmed. Actual calendar placement constraints still apply.'}},
            ['id', 'goal', 'items', 'status']),
        'FocusSession': obj({'id': string(minLength=1, maxLength=128), 'taskId': string(),
            'startedAt': string(format='date-time'),
            'lastResumedAt': {'type': ['string', 'null'], 'format': 'date-time'},
            'accumulatedSeconds': integer(0, maximum=86400), 'isRunning': {'type': 'boolean'},
            'targetMinutes': {'type': ['integer', 'null'], 'minimum': 1, 'maximum': 1440,
                'description': 'Optional fixed target chosen when this focus starts. Missing/null preserves legacy sessions; later task/calendar edits do not retime a saved target.'}},
            ['id', 'taskId', 'startedAt']),
        'ChangeRecord': obj({'id': string(minLength=1, maxLength=128),
            'label': string(minLength=1, maxLength=200), 'at': string(format='date-time'),
            'before': {'type': 'object'}, 'after': {'type': 'object'}, 'undone': {'type': 'boolean'},
            'format': string(enum=['entity-delta-v1'],
                description='Optional. Missing means legacy full snapshots. Delta snapshots contain only changed entity values plus changed preferences; they are never complete workspaces.'),
            'afterDigest': string(pattern='^[0-9a-f]{64}$',
                description='Required for delta records. SHA-256 of canonical full undoable business state; root entity collections sort by ID, nested ordered lists retain order.'),
            'beforeOrder': {'type': 'object', 'additionalProperties': array(string(minLength=1, maxLength=128)),
                'description': 'Required for delta records. Original entity ID order for each changed collection.'},
            'afterTaskEntries': {'type': 'object', 'additionalProperties': {'type': 'object',
                'additionalProperties': string(pattern='^[0-9a-f]{64}$')},
                'description': 'Completion-only task ID to entry ID/digest read set, including unchanged past blocks; guards selective completion undo.'}},
            ['id', 'label', 'at', 'before', 'after', 'undone']),
        'Workspace': obj({'schemaVersion': integer(1, maximum=2), 'revision': integer(),
            'tasks': array(ref('Task'), maxItems=2000), 'entries': array(ref('CalendarEntry'), maxItems=4000),
            'goals': array({'type': 'object'}), 'drafts': array(ref('PlanDraft')),
            'preferences': {'type': 'object'}, 'focusRecords': array({'type': 'object'}),
            'history': array(ref('ChangeRecord'), maxItems=30), 'externalBusyEntries': array(ref('CalendarEntry')),
            'planningSessions': array(ref('PlanningSession')),
            'focusSession': {'anyOf': [ref('FocusSession'), {'type': 'null'}]},
            'reviews': array({'type': 'object'}), 'reminderStates': {'type': 'object'},
            'platformSettings': {'type': 'object'}, 'entityVersions': {'type': 'object', 'additionalProperties': integer()}},
            ['schemaVersion', 'revision', 'tasks', 'entries', 'goals', 'drafts', 'preferences', 'focusRecords', 'history']),
        'WorkspaceEnvelope': obj({'workspace': {'anyOf': [ref('Workspace'), {'type': 'null'}]}}, ['workspace']),
        'SaveWorkspace': obj({'workspace': ref('Workspace'), 'expectedRevision': integer()}, ['workspace', 'expectedRevision']),
        'ImportGuest': obj({'workspace': ref('Workspace'), 'expectedRevision': integer()}, ['workspace', 'expectedRevision']),
        'PlanInput': obj({'title': string(maxLength=200), 'deadline': string(format='date-time'),
            'dailyBudget': integer(15, maximum=480), 'notes': string(maxLength=10000),
            'prompt': string(maxLength=10000), 'referenceNow': string(format='date-time'),
            'timeZone': string(maxLength=100)}, ['title', 'deadline', 'dailyBudget']),
        'AiPlan': obj({'source': string(), 'model': string(), 'tasks': array(obj({'title': string(),
            'notes': string(), 'estimatedMinutes': integer(5, maximum=240), 'checklist': array(string()),
            'phase': string(maxLength=100), 'notBefore': string(format='date-time'),
            'deadline': string(format='date-time'), 'phaseId': string()},
            ['title', 'notes', 'estimatedMinutes', 'checklist']), minItems=1, maxItems=96),
            'phases': array(obj({'id': string(), 'title': string(), 'start': string(format='date-time'),
                'end': string(format='date-time'), 'outcome': string()}, ['id', 'title', 'start', 'end', 'outcome']), maxItems=12)},
            ['source', 'model', 'tasks']),
        'UnderstandingInput': obj({'prompt': string(minLength=1, maxLength=10000),
            'notes': string(maxLength=10000), 'referenceNow': string(format='date-time'),
            'timeZone': string(maxLength=100), 'dailyBudget': integer(15, maximum=480),
            'previous': {'type': ['object', 'null'], 'description': 'Previous model fields and user clarification answers; bounded to 16000 JSON characters.'}},
            ['prompt', 'referenceNow', 'timeZone', 'dailyBudget']),
        'AiUnderstanding': understanding_response_schema(),
        'SyncOperation': obj({'id': string(), 'entityType': string(enum=['tasks', 'entries', 'goals', 'drafts',
            'planningSessions', 'focusRecords', 'reviews', 'externalBusyEntries', 'history', 'preferences',
            'focusSession', 'reminderStates', 'platformSettings']), 'entityId': string(),
            'expectedVersion': integer(), 'action': string(enum=['upsert', 'delete']),
            'value': {}}, ['id', 'entityType', 'entityId', 'expectedVersion', 'action']),
        'SyncBatch': obj({'clientId': string(), 'batchId': string(), 'baseRevision': integer(),
            'operations': array(ref('SyncOperation'), minItems=1, maxItems=5000)}, ['operations']),
        'SyncResult': obj({'workspace': ref('Workspace'), 'applied': array(string()), 'replayed': array(string()),
            'entityVersions': {'type': 'object', 'additionalProperties': integer()}}, ['workspace', 'applied', 'replayed', 'entityVersions']),
        'CreateJob': obj({'kind': string(enum=['plan', 'understand'], default='plan'),
            'input': {'anyOf': [ref('PlanInput'), ref('UnderstandingInput')]}, 'requestId': string()}, ['input']),
        'Job': obj({'id': string(), 'kind': string(), 'status': string(enum=['queued', 'running', 'succeeded', 'failed', 'canceled']),
            'result': {'anyOf': [ref('AiPlan'), ref('AiUnderstanding'), {'type': 'null'}]}, 'error': {'type': ['string', 'null']},
            'createdAt': integer(), 'updatedAt': integer()}, ['id', 'kind', 'status', 'result', 'error', 'createdAt', 'updatedAt']),
        'JobEnvelope': obj({'job': ref('Job')}, ['job']),
        'PushSubscription': obj({'endpoint': string(format='uri'), 'keys': obj({'p256dh': string(), 'auth': string()}, ['p256dh', 'auth'])}, ['endpoint', 'keys']),
        'PushEndpoint': obj({'endpoint': string(format='uri')}, ['endpoint']),
        'IcsPreview': obj({'content': string(maxLength=2097152), 'start': string(format='date-time'),
            'end': string(format='date-time'), 'timeZone': string(default='Asia/Hong_Kong')}, ['content', 'start', 'end']),
        'AsrTicketRequest': obj({'sampleRate': integer(16000, maximum=16000, default=16000)}),
        'AsrTicket': obj({'ticket': string(), 'expiresAt': integer(), 'websocketUrl': string(format='uri')}, ['ticket', 'expiresAt', 'websocketUrl']),
        'Transcript': obj({'text': string(), 'source': string(), 'model': string(), 'durationSeconds': {'type': 'number'}}, ['text']),
    }
    schemas.update(community_schemas())
    # path, method, request schema, success schema, success status, public
    contracts = [
        ('/api/v1/auth/register', 'post', 'RegisterRequest', 'AuthSession', 201, True),
        ('/api/v1/auth/login', 'post', 'LoginRequest', 'AuthSession', 200, True),
        ('/api/v1/auth/me', 'get', None, 'SessionState', 200, False),
        ('/api/v1/auth/logout', 'post', None, None, 200, False),
        ('/api/v1/workspace', 'get', None, 'WorkspaceEnvelope', 200, False),
        ('/api/v1/workspace', 'put', 'SaveWorkspace', 'WorkspaceEnvelope', 200, False),
        ('/api/v1/workspace', 'delete', None, 'WorkspaceEnvelope', 200, False),
        ('/api/v1/guest-workspace', 'get', None, 'WorkspaceEnvelope', 200, False),
        ('/api/v1/workspace/import-guest', 'post', 'ImportGuest', 'WorkspaceEnvelope', 200, False),
        ('/api/v1/account', 'delete', 'DeleteAccount', None, 200, False),
        ('/api/v1/account/export', 'get', None, None, 200, False),
        ('/api/v1/auth/phone/capabilities', 'get', None, 'PhoneCapabilities', 200, True),
        ('/api/v1/auth/phone/challenge', 'post', 'PhoneChallengeRequest', 'PhoneChallenge', 200, True),
        ('/api/v1/auth/phone/login', 'post', 'PhoneCode', 'AuthSession', 200, True),
        ('/api/v1/auth/phone/bind', 'post', 'PhoneCode', None, 200, False),
        ('/api/v1/auth/phone/verify-sensitive', 'post', 'PhoneCode', 'PhoneProof', 200, False),
        ('/api/v1/auth/email/bind/request', 'post', 'BindEmailRequest', 'VerificationDelivery', 200, False),
        ('/api/v1/auth/email/bind/confirm', 'post', 'ActionToken', None, 200, False),
        ('/api/v1/auth/password/set', 'post', 'SetPasswordRequest', None, 200, False),
        ('/api/v1/ai/plan', 'post', 'PlanInput', 'AiPlan', 200, False),
        ('/api/v1/ai/transcribe', 'post', None, 'Transcript', 200, False),
        ('/api/v1/auth/email/verification/request', 'post', None, 'VerificationDelivery', 200, False),
        ('/api/v1/auth/development-mailbox', 'get', None, 'DevelopmentMailbox', 200, False),
        ('/api/v1/auth/email/verification/confirm', 'post', 'ActionToken', None, 200, True),
        ('/api/v1/auth/password/reset/request', 'post', 'EmailRequest', 'ResetRequestAccepted', 200, True),
        ('/api/v1/auth/password/reset/confirm', 'post', 'ResetPassword', None, 200, True),
        ('/api/v1/sync/operations', 'post', 'SyncBatch', 'SyncResult', 200, False),
        ('/api/v1/sync/state', 'get', None, 'WorkspaceEnvelope', 200, False),
        ('/api/v1/jobs', 'post', 'CreateJob', 'JobEnvelope', 202, False),
        ('/api/v1/jobs/{job_id}', 'get', None, 'JobEnvelope', 200, False),
        ('/api/v1/jobs/{job_id}/cancel', 'post', None, 'JobEnvelope', 200, False),
        ('/api/v1/push/config', 'get', None, None, 200, True),
        ('/api/v1/push/subscriptions', 'post', 'PushSubscription', None, 200, False),
        ('/api/v1/push/subscriptions', 'delete', 'PushEndpoint', None, 200, False),
        ('/api/v1/push/test', 'post', None, None, 202, False),
        ('/api/v1/push/validate', 'get', None, None, 200, False),
        ('/api/v1/calendar/ics/preview', 'post', 'IcsPreview', None, 200, False),
        ('/api/v1/asr/tickets', 'post', 'AsrTicketRequest', 'AsrTicket', 200, False),
    ]
    schemas['SessionState'] = obj(schemas['AuthSession']['properties'],
        ['expiresAt', 'user', 'sessionId', 'csrfToken', 'cookieSession'])
    # Real explicit routes use the original validator, never a catchall in docs.
    registered = {(route.path, method.lower()) for route in app.routes for method in getattr(route, 'methods', [])}
    async def forward(request: Request): return await compatibility(request, request.url.path.lstrip('/'))
    for path, method, *_ in contracts:
        if (path, method) not in registered:
            app.add_api_route(path, forward, methods=[method.upper()], name=method + '_' + path.replace('/', '_'))

    def openapi():
        if app.openapi_schema: return app.openapi_schema
        schema = get_openapi(title=app.title, version=app.version, routes=app.routes,
            description='Schema v2 personal workspaces. Cookie mutations require X-CSRF-Token; native clients use Bearer. Request limits and conflict rules are documented in docs/API.md.')
        schema.setdefault('components', {}).setdefault('schemas', {}).update(schemas)
        schema['components']['securitySchemes'] = {'BearerAuth': {'type': 'http', 'scheme': 'bearer'},
            'CookieAuth': {'type': 'apiKey', 'in': 'cookie', 'name': 'sera_session'}}
        for path, method, request_name, result_name, status, public in contracts:
            operation = schema['paths'][path][method]
            operation['security'] = [] if public else [{'BearerAuth': []}, {'CookieAuth': []}]
            operation['responses'] = {str(status): {'description': 'Success', 'content': {'application/json': {
                'schema': ref(result_name) if result_name else {'type': 'object'}}}}, **{
                str(code): {'description': description, 'content': {'application/json': {'schema': ref('Error')}}}
                for code, description in ((400, 'Invalid input'), (401, 'Login required or expired'),
                    (403, 'Origin or CSRF denied'), (409, 'Revision or object version conflict'), (413, 'Request too large'), (429, 'Rate limited'))}}
            if request_name: operation['requestBody'] = {'required': True, 'content': {'application/json': {'schema': ref(request_name)}}}
            if path == '/api/v1/ai/transcribe': operation['requestBody'] = {'required': True, 'content': {'multipart/form-data': {
                'schema': obj({'file': string(format='binary'), 'durationMilliseconds': integer()}, ['file'])}}}
            if path == '/api/v1/auth/development-mailbox': operation.setdefault('parameters', []).append({
                'in': 'query', 'name': 'purpose', 'required': False, 'schema': string(enum=['verify-email'], default='verify-email'),
                'description': 'Local development only; current account verification links. Password reset mail is never exposed.'})
            if not public: operation.setdefault('parameters', []).append({'in': 'header', 'name': 'X-CSRF-Token',
                'required': False, 'schema': string(), 'description': 'Required for cookie-authenticated mutations; not required for native Bearer.'})
        describe_community(schema)
        from admin_api import describe_admin
        describe_admin(schema)
        app.openapi_schema = schema
        return schema
    app.openapi = openapi
