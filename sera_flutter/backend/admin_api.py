"""Private admin endpoints; same-origin cookie CSRF is enforced by app middleware."""
import json

from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

from admin_store import AdminStore
from auth_store import AuthError


def attach_admin(app):
    store = AdminStore(app.state.community)
    app.state.admin = store

    def response(body):
        return JSONResponse(body, headers={'Cache-Control': 'no-store', 'Pragma': 'no-cache'})

    async def actor(request):
        session = await run_in_threadpool(app.state.require, request)
        return session['user']['id'], app.state.token(request)

    async def body(request):
        if request.headers.get('content-type', '').split(';', 1)[0].strip().lower() != 'application/json':
            raise AuthError('请以 JSON 格式提交操作。', 415, 'invalid_content_type')
        raw = await request.body()
        if len(raw) > 64 * 1024:
            raise AuthError('提交内容过大。', 413, 'admin_request_too_large')
        try:
            parsed = json.loads(raw)
        except (ValueError, UnicodeError):
            raise AuthError('提交内容不是有效的 JSON。', 400, 'invalid_admin_request') from None
        if not isinstance(parsed, dict):
            raise AuthError('提交内容需为 JSON 对象。', 400, 'invalid_admin_request')
        return parsed

    @app.get('/api/v1/admin/bootstrap')
    async def bootstrap(request: Request):
        uid, token = await actor(request)
        return response(await run_in_threadpool(store.bootstrap, uid, token))

    @app.get('/api/v1/admin/posts')
    async def posts(request: Request):
        uid, token = await actor(request)
        values = request.query_params
        return response(await run_in_threadpool(store.posts, uid, token, q=values.get('q', ''),
            category=values.get('category', 'all'), kind=values.get('kind', 'all'),
            official=values.get('official', 'all'), cursor=values.get('cursor'), limit=values.get('limit')))

    @app.get('/api/v1/admin/comments')
    async def comments(request: Request):
        uid, token = await actor(request)
        values = request.query_params
        return response(await run_in_threadpool(store.comments, uid, token, q=values.get('q', ''),
            post_id=values.get('postId', ''), cursor=values.get('cursor'), limit=values.get('limit')))

    @app.get('/api/v1/admin/users')
    async def users(request: Request):
        uid, token = await actor(request)
        values = request.query_params
        return response(await run_in_threadpool(store.users, uid, token, q=values.get('q', ''),
            status=values.get('status', 'all'), cursor=values.get('cursor'), limit=values.get('limit')))

    @app.put('/api/v1/admin/users/{user_id}/status')
    async def user_status(user_id: str, request: Request):
        uid, token = await actor(request)
        return response(await run_in_threadpool(store.set_user_status, user_id, uid, token, await body(request)))

    @app.delete('/api/v1/admin/posts/{post_id}')
    async def delete_post(post_id: str, request: Request):
        uid, token = await actor(request)
        return response(await run_in_threadpool(store.delete, post_id, uid, token, await body(request)))

    @app.delete('/api/v1/admin/comments/{comment_id}')
    async def delete_comment(comment_id: str, request: Request):
        uid, token = await actor(request)
        return response(await run_in_threadpool(store.delete, comment_id, uid, token, await body(request), comment=True))

    @app.get('/api/v1/admin/audit')
    async def audit(request: Request):
        uid, token = await actor(request)
        values = request.query_params
        return response(await run_in_threadpool(store.audit, uid, token, q=values.get('q', ''),
            cursor=values.get('cursor'), limit=values.get('limit')))

    @app.get('/api/v1/admin/status')
    async def status(request: Request):
        uid, token = await actor(request)
        return response(await run_in_threadpool(store.status, uid, token, ai=app.state.ai,
            mail=app.state.mail))

    @app.get('/api/v1/admin/analytics')
    async def analytics(request: Request):
        uid, token = await actor(request)
        return response(await run_in_threadpool(store.analytics, uid, token, days=request.query_params.get('days', '30')))


def describe_admin(document):
    """Document only registered admin routes, without compatibility forwarders."""
    from api_contract import array, integer, obj, ref, string

    schemas = document['components']['schemas']
    boolean = {'type': 'boolean'}
    nullable_count = {'type': ['integer', 'null'], 'minimum': 0}
    cursor = {'type': ['string', 'null'], 'maxLength': 512}
    user = {
        'id': ref('CommunityIdentifier'), 'username': string(),
        'emailMasked': {'type': ['string', 'null']}, 'phoneMasked': {'type': ['string', 'null']},
        'emailVerified': boolean, 'createdAt': string(format='date-time'), 'disabled': boolean,
        'postCount': integer(), 'commentCount': integer(),
    }
    audit = {
        'id': ref('CommunityIdentifier'), 'actorName': string(), 'action': string(),
        'targetType': string(enum=['post', 'comment', 'user', 'application']),
        'targetId': ref('CommunityIdentifier'), 'targetLabel': string(maxLength=160),
        'reason': string(maxLength=500), 'createdAt': string(format='date-time'),
    }
    comment = {**schemas['CommunityComment']['properties'], 'postTitle': string(maxLength=120)}
    counts = {name: integer() for name in ('posts', 'comments', 'feedback', 'activities')}
    counts.update({name: nullable_count for name in ('pendingApplications', 'users', 'admins')})
    mutation = {'requestId': ref('CommunityIdentifier'),
                'reason': string(minLength=1, maxLength=500, pattern=r'^(?=.*\S)[^\x00-\x1f\x7f]*$')}
    schemas.update({
        'AdminBootstrap': obj({'viewer': ref('CommunityViewer'), 'counts': obj(counts, counts, additionalProperties=False)},
                              ['viewer', 'counts'], additionalProperties=False),
        'AdminComment': obj(comment, comment, additionalProperties=False),
        'AdminUser': obj(user, user, additionalProperties=False,
                         description='Owner-only account summary; identities are masked. No password, session, or private workspace fields.'),
        'AdminAuditEntry': obj(audit, audit, additionalProperties=False),
        'AdminMutation': obj(mutation, mutation, additionalProperties=False),
        'AdminAccountStatus': obj({**mutation, 'disabled': boolean}, [*mutation, 'disabled'], additionalProperties=False,
            description='Owner-only. Disabling revokes existing sessions and push subscriptions and cancels active jobs. Re-enabling never restores sessions. Official/self accounts are protected.'),
        'AdminComponent': obj({'id': string(), 'name': string(), 'configured': boolean,
            'healthy': {'type': ['boolean', 'null']},
            'status': string(enum=['healthy', 'unavailable', 'not_configured', 'configured']),
            'detail': string(), 'lastHeartbeatAt': {'type': ['string', 'null'], 'format': 'date-time'}},
            ['id', 'name', 'configured', 'healthy', 'status', 'detail'], additionalProperties=False),
        'AdminStatus': obj({'components': array(ref('AdminComponent'))}, ['components'], additionalProperties=False,
            description='Owner-only, sanitized configuration and persisted heartbeat inspection. No external AI/mail/ASR request is made; configured is not a successful live-provider test.'),
    })
    period = {'startDate': string(format='date'), 'endDate': string(format='date'), 'endAt': string(format='date-time')}
    daily = {'date': string(format='date'), **{key: integer() for key in ('newUsers', 'contributors', 'posts', 'comments')}}
    schemas.update({
        'AdminAnalyticsPeriod': obj(period, period, additionalProperties=False),
        'AdminAnalyticsMetric': obj({'value': integer(), 'previous': integer()}, ['value', 'previous'], additionalProperties=False),
        'AdminAnalyticsDay': obj(daily, daily, additionalProperties=False),
        'AdminAnalytics': obj({
            'days': integer(7, enum=[7, 30, 90]), 'timeZone': {'type': 'string', 'const': 'Asia/Hong_Kong'},
            'generatedAt': string(format='date-time'), 'period': ref('AdminAnalyticsPeriod'),
            'previousPeriod': ref('AdminAnalyticsPeriod'),
            'summary': obj({key: ref('AdminAnalyticsMetric') for key in ('newUsers', 'contributors', 'posts', 'comments')},
                           ['newUsers', 'contributors', 'posts', 'comments'], additionalProperties=False),
            'daily': array(ref('AdminAnalyticsDay'), minItems=7, maxItems=90),
            'contentTypes': array(obj({'key': string(enum=['daily', 'feedback', 'activity']), 'label': string(), 'count': integer()},
                                      ['key', 'label', 'count'], additionalProperties=False), minItems=3, maxItems=3),
            'currentInteractions': obj({'likes': integer(), 'participants': integer()}, ['likes', 'participants'], additionalProperties=False),
            'topPosts': array(obj({'post': ref('CommunityPost'), 'interactions': integer(1)}, ['post', 'interactions'], additionalProperties=False), maxItems=5),
        }, ['days', 'timeZone', 'generatedAt', 'period', 'previousPeriod', 'summary', 'daily', 'contentTypes', 'currentInteractions', 'topPosts'],
            additionalProperties=False,
            description='Owner-only snapshot of existing records, fixed Hong Kong days through generatedAt inclusive. Previous endAt is generatedAt minus days, at the same time of day. Contributors count unique post/comment authors, not login/visit activity. Likes/participants lack timestamps: currentInteractions is sitewide existing totals and topPosts shows current interactions for posts created in the selected period. Deletions and cancellations change totals; demo records are included when present. No workspace content or raw tracking events are read.'),
    })
    for name, field, item in (('AdminPosts', 'posts', 'CommunityPost'), ('AdminComments', 'comments', 'AdminComment'),
                              ('AdminUsers', 'users', 'AdminUser'), ('AdminAudit', 'entries', 'AdminAuditEntry')):
        schemas[name] = obj({field: array(ref(item), maxItems=100), 'total': integer(), 'nextCursor': cursor},
                            [field, 'total', 'nextCursor'], additionalProperties=False)
    specs = [
        ('/bootstrap', 'get', None, 'AdminBootstrap', 'A current official or delegated administrator session is required.'),
        ('/posts', 'get', None, 'AdminPosts', 'All administrators may inspect public posts. Deletion requires moderatePosts.'),
        ('/comments', 'get', None, 'AdminComments', 'Requires official owner or current moderateComments permission.'),
        ('/users', 'get', None, 'AdminUsers', 'Official owner only; does not expose personal workspace content.'),
        ('/users/{user_id}/status', 'put', 'AdminAccountStatus', 'CommunityUpdated', 'Official owner only; current session is rechecked inside the status transaction.'),
        ('/posts/{post_id}', 'delete', 'AdminMutation', 'CommunityDeleted', 'Requires moderatePosts. Permanently deletes content and related media/comments/interactions; atomic idempotency and audit.'),
        ('/comments/{comment_id}', 'delete', 'AdminMutation', 'CommunityDeleted', 'Requires moderateComments. Permanently deletes the comment; atomic idempotency and audit.'),
        ('/audit', 'get', None, 'AdminAudit', 'Official owner only. Actions use the same write transaction as the audited change.'),
        ('/status', 'get', None, 'AdminStatus', 'Official owner only. Never returns server paths, credentials or subscription payloads.'),
        ('/analytics', 'get', None, 'AdminAnalytics', 'Official owner only. Read-only existing-row community aggregates in one transaction; no DAU, retention, raw-event tracking or private workspace inspection.'),
    ]
    filters = {
        '/posts': [('category', string(enum=['all', 'daily', 'feedback'], default='all')),
                   ('kind', string(enum=['all', 'post', 'activity'], default='all')),
                   ('official', string(enum=['all', 'yes'], default='all'))],
        '/comments': [('postId', ref('CommunityIdentifier'))],
        '/users': [('status', string(enum=['all', 'active', 'disabled'], default='all'))],
        '/audit': [],
    }
    for suffix, method, request_schema, result_schema, description in specs:
        operation = document.get('paths', {}).get('/api/v1/admin' + suffix, {}).get(method)
        if operation is None:
            continue
        operation['tags'] = ['Administration']
        operation['description'] = description
        operation['security'] = [{'BearerAuth': []}, {'CookieAuth': []}]
        operation['responses'] = {'200': {'description': 'Success',
            'headers': {'Cache-Control': {'schema': {'type': 'string', 'const': 'no-store'}}},
            'content': {'application/json': {'schema': ref(result_schema)}}}, **{
                str(code): {'description': detail, 'content': {'application/json': {'schema': ref('Error')}}}
                for code, detail in ((400, 'Invalid input'), (401, 'Expired or missing session'),
                    (403, 'Permission or CSRF denied'), (404, 'Account not found'),
                    (409, 'Idempotency conflict'), (413, 'Request too large'), (415, 'JSON required'))}}
        parameters = operation.setdefault('parameters', [])
        for parameter in parameters:
            if parameter['in'] == 'path':
                parameter['schema'] = ref('CommunityIdentifier')
        parameters.append({'in': 'header', 'name': 'X-CSRF-Token', 'required': False, 'schema': string(),
            'description': 'Required for cookie-authenticated mutations; supplied read headers must match the current cookie session. Bearer clients need no CSRF header.'})
        if suffix in filters:
            parameters.extend({'in': 'query', 'name': name, 'required': False, 'schema': schema} for name, schema in [
                ('q', string(maxLength=200, default='', description='Literal search; wildcard characters are escaped.')),
                *filters[suffix],
                ('cursor', string(maxLength=512, pattern=r'^[A-Za-z0-9_-]*$', description='Opaque nextCursor from the same query and filters.')),
                ('limit', integer(1, maximum=100, default=30)),
            ])
        if suffix == '/analytics':
            parameters.append({'in': 'query', 'name': 'days', 'required': False,
                'schema': integer(7, enum=[7, 30, 90], default=30),
                'description': 'Inclusive Hong Kong calendar dates ending today, cut off at generatedAt. Previous period has the same elapsed duration.'})
        if request_schema:
            operation['requestBody'] = {'required': True, 'content': {'application/json': {'schema': ref(request_schema)}}}
