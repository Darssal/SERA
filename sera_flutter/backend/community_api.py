"""Community HTTP routes using the existing session and CSRF boundary."""
import json
import os

from fastapi import Request
from fastapi.responses import JSONResponse, Response
from starlette.concurrency import run_in_threadpool

from auth_store import AuthError
from community_store import CommunityStore, MEDIA_MAX_BYTES, identifier, page_limit


def attach_community(app):
    official_ids = {value.strip() for value in os.environ.get('SERA_COMMUNITY_OFFICIAL_USER_IDS', '').split(',') if value.strip()}
    store = CommunityStore(app.state.accounts, official_user_ids=official_ids)
    app.state.community = store

    def response(body, status=200):
        # GET includes viewer-specific flags: it must never become a shared or
        # service-worker cached response, even when the current reader is a guest.
        return JSONResponse(body, status_code=status, headers={'Cache-Control': 'no-store', 'Pragma': 'no-cache'})

    async def current(request, *, required=False):
        token = app.state.token(request)
        if not token and not required:
            return None, ''
        try:
            session = await run_in_threadpool(app.state.require, request)
        except AuthError as error:
            # Public community reads stay available when a browser carries an
            # expired same-host Cookie from another port. Do not replace/delete
            # that Cookie or retain any viewer identity; private reads and every
            # mutation still require a valid session. CSRF guards run upstream.
            if not required and request.method in ('GET', 'HEAD') and error.status == 401:
                return None, ''
            raise
        return session['user']['id'], token

    async def body(request):
        if request.headers.get('content-type', '').split(';', 1)[0].strip().lower() != 'application/json':
            raise AuthError('请以 JSON 格式提交内容。', 415, 'invalid_content_type')
        raw = await request.body()
        if len(raw) > 64 * 1024:
            raise AuthError('提交内容过大，请缩短后重试。', 413, 'community_request_too_large')
        try:
            result = json.loads(raw)
        except (ValueError, UnicodeError):
            raise AuthError('提交内容不是有效的 JSON。', 400, 'invalid_community_request') from None
        if not isinstance(result, dict):
            raise AuthError('提交内容需为 JSON 对象。', 400, 'invalid_community_request')
        return result

    @app.post('/api/v1/community/media')
    async def upload_media(request: Request):
        uid, token = await current(request, required=True)
        request_id = identifier(request.headers.get('idempotency-key'), '提交标识')
        mime_type = request.headers.get('content-type', '').split(';', 1)[0].strip().lower()
        if mime_type not in ('image/jpeg', 'image/png', 'image/webp'):
            raise AuthError('请选择 JPEG、PNG 或 WebP 图片。', 415, 'community_media_type')
        raw = bytearray()
        async for chunk in request.stream():
            if len(raw) + len(chunk) > MEDIA_MAX_BYTES:
                raise AuthError('每张图片不能超过 8 MiB。', 413, 'community_media_too_large')
            raw.extend(chunk)
        result = await run_in_threadpool(store.upload_media, uid, token, request_id, bytes(raw), mime_type)
        return response(result, 201)

    @app.get('/api/v1/community/media/{media_id}')
    async def read_media(media_id: str, request: Request):
        uid, token = await current(request)
        data, mime_type = await run_in_threadpool(store.read_media, media_id, uid, token)
        return Response(data, media_type=mime_type, headers={
            'Cache-Control': 'private, no-store', 'Pragma': 'no-cache', 'X-Content-Type-Options': 'nosniff',
        })

    @app.get('/api/v1/community/posts')
    async def list_posts(request: Request):
        uid, _ = await current(request)
        values = request.query_params
        result = await run_in_threadpool(store.list_posts, uid, filter=values.get('filter', 'all'),
                                        cursor=values.get('cursor'), limit=page_limit(values.get('limit')))
        return response(result)

    @app.get('/api/v1/community/posts/{post_id}')
    async def detail(post_id: str, request: Request):
        uid, _ = await current(request)
        values = request.query_params
        result = await run_in_threadpool(store.detail, post_id, uid,
                                        comment_cursor=values.get('commentCursor'),
                                        comment_limit=page_limit(values.get('commentLimit'), default=50))
        return response(result)

    @app.post('/api/v1/community/posts')
    async def create_post(request: Request):
        uid, token = await current(request, required=True)
        try:
            return response(await run_in_threadpool(store.create_post, uid, token, await body(request)), 201)
        except AuthError as error:
            if error.code != 'community_media_expired' or not getattr(error, 'media_ids', None):
                raise
            return response({'error': str(error), 'code': error.code,
                             'details': {'mediaIds': error.media_ids}}, error.status)

    @app.post('/api/v1/community/posts/{post_id}/comments')
    async def create_comment(post_id: str, request: Request):
        uid, token = await current(request, required=True)
        return response(await run_in_threadpool(store.create_comment, post_id, uid, token, await body(request)), 201)

    @app.put('/api/v1/community/posts/{post_id}/like')
    async def like(post_id: str, request: Request):
        uid, token = await current(request, required=True)
        return response(await run_in_threadpool(store.set_like, post_id, uid, token, await body(request)))

    @app.put('/api/v1/community/posts/{post_id}/join')
    async def join(post_id: str, request: Request):
        uid, token = await current(request, required=True)
        return response(await run_in_threadpool(store.set_join, post_id, uid, token, await body(request)))

    @app.delete('/api/v1/community/posts/{post_id}')
    async def delete_post(post_id: str, request: Request):
        uid, token = await current(request, required=True)
        return response(await run_in_threadpool(store.delete_post, post_id, uid, token))

    @app.delete('/api/v1/community/comments/{comment_id}')
    async def delete_comment(comment_id: str, request: Request):
        uid, token = await current(request, required=True)
        return response(await run_in_threadpool(store.delete_comment, comment_id, uid, token))

    @app.get('/api/v1/community/management')
    async def management(request: Request):
        uid, token = await current(request, required=True)
        return response(await run_in_threadpool(store.management, uid, token))

    @app.post('/api/v1/community/admin-applications')
    async def apply_admin(request: Request):
        uid, token = await current(request, required=True)
        return response(await run_in_threadpool(store.apply_admin, uid, token, await body(request)), 201)

    @app.post('/api/v1/community/admins')
    async def add_admin(request: Request):
        uid, token = await current(request, required=True)
        return response(await run_in_threadpool(store.add_admin, uid, token, await body(request)))

    @app.put('/api/v1/community/admins/{user_id}')
    async def update_admin(user_id: str, request: Request):
        uid, token = await current(request, required=True)
        return response(await run_in_threadpool(store.update_admin, user_id, uid, token, await body(request)))

    @app.delete('/api/v1/community/admins/{user_id}')
    async def remove_admin(user_id: str, request: Request):
        uid, token = await current(request, required=True)
        return response(await run_in_threadpool(store.remove_admin, user_id, uid, token))

    @app.put('/api/v1/community/admin-applications/{application_id}')
    async def review_application(application_id: str, request: Request):
        uid, token = await current(request, required=True)
        return response(await run_in_threadpool(store.review_application, application_id, uid, token, await body(request)))
