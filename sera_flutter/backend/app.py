"""FastAPI front controller; the reviewed v1 handler remains the compatibility layer."""
import asyncio
import base64
from contextlib import asynccontextmanager
import hashlib
import hmac
import io
import json
import logging
import os
from pathlib import Path
import secrets
import time
from types import SimpleNamespace
from urllib.parse import urlsplit

from fastapi import BackgroundTasks, FastAPI, Request
from fastapi.responses import JSONResponse, Response
from starlette.concurrency import run_in_threadpool

from auth_store import AuthError, AuthStore
from ai_service import SiliconFlowPlanner, load_api_key, AiServiceError, DEFAULT_MODEL
from model_runtime import create_planner
from asr_service import SiliconFlowTranscriber
from mail_service import MailService
from server import make_server, DEV_ORIGINS
from workspace_validation import (ValidationError, validate_workspace,
                                  validate_planning_result_changes)
from sync_store import SyncStore, SyncConflict, migrate_workspace
from guest_workflows import (attach_device_workflows, device_scope,
                             is_device_api_path, read_device_body)


class InMemorySocket:
    def __init__(self, raw): self.input, self.output = io.BytesIO(raw), bytearray()
    def makefile(self, *args, **kwargs): return self.input
    def sendall(self, value): self.output.extend(value)
    def setsockopt(self, *args): pass


def create_app(*, db_path=None, web_dir=None, ai_key_file=None, ai_model=None, asr_model=None, ai_service=None, transcriber=None, sms_service=None):
    db_path = Path(db_path or os.environ.get('SERA_DB', Path(__file__).with_name('sera.sqlite3')))
    db_path.parent.mkdir(parents=True, exist_ok=True)
    secret_path = db_path.with_suffix('.session-secret')
    if not secret_path.exists(): secret_path.write_bytes(secrets.token_bytes(32))
    secret = secret_path.read_bytes()
    accounts, sync = AuthStore(db_path), SyncStore(db_path)
    mail = MailService(db_path.parent / 'mail')
    ai = ai_service or create_planner(load_api_key(ai_key_file or os.environ.get('SILICONFLOW_API_KEY_FILE')),
        ai_model or os.environ.get('SILICONFLOW_MODEL', DEFAULT_MODEL))
    speech = transcriber or SiliconFlowTranscriber(load_api_key(ai_key_file or os.environ.get('SILICONFLOW_API_KEY_FILE')),
        asr_model or os.environ.get('SILICONFLOW_ASR_MODEL', 'FunAudioLLM/SenseVoiceSmall'))
    legacy = make_server('127.0.0.1', 0, db_path, ai_service=ai, web_dir=web_dir, transcriber=speech)
    legacy.server_close()  # Handler metadata only; no hidden listening service.
    @asynccontextmanager
    async def lifespan(app):
        try:
            yield
        finally:
            await app.state.device_jobs.close()
            legacy.server_close()
    app = FastAPI(title='SERA personal workspace API', version='2.0', lifespan=lifespan)
    app.state.accounts, app.state.sync, app.state.mail = accounts, sync, mail
    app.state.secret, app.state.db_path, app.state.ai = secret, db_path, ai
    app.state.transcriber = speech
    def auth_error_response(error):
        body = {'error': str(error), 'code': error.code}
        headers = {'Cache-Control': 'no-store', 'Pragma': 'no-cache'}
        retry = getattr(error, 'retry_after_seconds', None)
        if isinstance(retry, int) and retry > 0:
            body['retryAfterSeconds'] = retry
            headers['Retry-After'] = str(retry)
        return JSONResponse(body, status_code=error.status, headers=headers)
    @app.exception_handler(AuthError)
    async def auth_failure(request, error): return auth_error_response(error)
    @app.exception_handler(AiServiceError)
    async def ai_failure(request, error): return JSONResponse({'error': str(error), 'code': error.code}, status_code=error.status)
    @app.exception_handler(ValueError)
    async def invalid_request(request, error): return JSONResponse({'error': 'Invalid request data'}, status_code=400)
    @app.exception_handler(KeyError)
    async def missing_field(request, error): return JSONResponse({'error': 'Missing required request field'}, status_code=400)
    def csrf(token): return hmac.new(secret, ('csrf:' + token).encode(), hashlib.sha256).hexdigest()
    def token(request):
        authorization = request.headers.get('authorization', '').split()
        return authorization[1] if len(authorization) == 2 and authorization[0].lower() == 'bearer' else request.cookies.get('sera_session', '')
    def require(request): return accounts.authenticate(token(request))
    def action_owner(request):
        # Logout deliberately leaves the shared-origin cookie untouched. A stale
        # or expired cookie must not prevent anonymous recovery via a valid link.
        if not token(request): return None
        try: return require(request)['user']['id']
        except AuthError as error:
            if error.status == 401: return None
            raise
    app.state.require, app.state.token = require, token

    def session_response(request, result):
        result = dict(result)
        current_token = result['token']
        web = request.headers.get('x-sera-client') == 'web' or bool(request.cookies.get('sera_session'))
        result['sessionId'] = hashlib.sha256(current_token.encode()).hexdigest()[:24]
        result['cookieSession'], result['csrfToken'] = web, csrf(current_token) if web else ''
        if web: result['token'] = ''
        response = JSONResponse(result, headers={'Cache-Control': 'no-store', 'Pragma': 'no-cache'})
        if web:
            response.set_cookie('sera_session', current_token, httponly=True, secure=request.url.scheme == 'https',
                                samesite='strict', max_age=7 * 86400, path='/')
        return response

    @app.middleware('http')
    async def security(request, call_next):
        try:
            if int(request.headers.get('content-length', '0')) > 11 * 1024 * 1024:
                return JSONResponse({'error': 'Request too large'}, status_code=413)
        except ValueError: return JSONResponse({'error': 'Invalid Content-Length'}, status_code=400)
        origin = request.headers.get('origin')
        public_origin = os.environ.get('SERA_PUBLIC_ORIGIN', '').rstrip('/')
        host = request.headers.get('host', '')
        allowed = set(DEV_ORIGINS)
        if public_origin: allowed.add(public_origin)
        host_parsed = urlsplit('//' + host)
        if host_parsed.hostname in ('127.0.0.1', 'localhost', '::1'):
            allowed.add(f'{request.url.scheme}://{host}')
        if origin and origin not in allowed:
            return JSONResponse({'error': 'Browser origin is not allowed.', 'code': 'origin_forbidden'}, status_code=403)
        device_request = is_device_api_path(request.url.path)
        if device_request and request.method != 'OPTIONS':
            try:
                device_scope(request.headers.get('x-sera-device'))
                # GET/HEAD and unmatched device paths can reach compatibility,
                # which also reads the body. Bound every device method here.
                request._body = await read_device_body(request, app.state.device_body_gate)
            except AuthError as error:
                return auth_error_response(error)
        if request.url.path.startswith('/api/') and request.method in ('POST', 'PUT', 'DELETE'):
            if not device_request:
                chunks, total = [], 0
                async for chunk in request.stream():
                    total += len(chunk)
                    if total > 11 * 1024 * 1024:
                        return JSONResponse({'error': 'Request too large'}, status_code=413)
                    chunks.append(chunk)
                # WrappedRequest replays its cached body to downstream handlers.
                request._body = b''.join(chunks)
            if 'application/json' in request.headers.get('content-type', ''):
                try:
                    if not isinstance(json.loads(request._body or b'{}'), dict):
                        raise ValueError()
                except ValueError:
                    return JSONResponse({'error': 'Request body must be a JSON object'}, status_code=400)
        if request.method == 'OPTIONS':
            response = Response(status_code=204)
        else:
            authorization_parts = request.headers.get('authorization', '').split()
            bearer = len(authorization_parts) == 2 and authorization_parts[0].lower() == 'bearer'
            public_mutation = request.url.path in ('/api/v1/auth/login', '/api/v1/auth/register',
                '/api/v1/auth/email/verification/confirm', '/api/v1/auth/password/reset/request',
                '/api/v1/auth/password/reset/confirm', '/api/v1/auth/phone/login')
            if request.url.path == '/api/v1/auth/phone/challenge':
                # Anonymous login remains usable after a logged-out cookie;
                # current-account SMS requests retain the normal CSRF checks.
                try: public_mutation = json.loads(getattr(request, '_body', b'{}')).get('purpose', 'login') == 'login'
                except ValueError: pass
            if request.cookies.get('sera_session') and not bearer and not public_mutation and not device_request:
                supplied_csrf = request.headers.get('x-csrf-token')
                # A stale tab must not read a newly signed-in account into its
                # previous account cache. SW validation has no stored CSRF and
                # separately validates its payload scope in the response.
                check_read = request.method in ('GET', 'HEAD') and supplied_csrf is not None and request.url.path.startswith('/api/')
                if request.method not in ('GET', 'HEAD') or check_read:
                    if not supplied_csrf:
                        return JSONResponse({'error': 'CSRF validation failed.', 'code': 'csrf_required'}, status_code=403)
                    if not hmac.compare_digest(supplied_csrf, csrf(request.cookies['sera_session'])):
                        return JSONResponse({'error': '账号已在其他页面切换，请重新确认登录。', 'code': 'account_changed'}, status_code=401)
            try: response = await call_next(request)
            except AuthError as exc:
                response = auth_error_response(exc)
        if origin:
            response.headers['Access-Control-Allow-Origin'] = origin
            response.headers['Access-Control-Allow-Credentials'] = 'true'
            response.headers['Vary'] = 'Origin'
        response.headers['Access-Control-Allow-Headers'] = 'Content-Type, Authorization, X-CSRF-Token, X-Sera-Client, Idempotency-Key, X-Sera-Device'
        response.headers['Access-Control-Allow-Methods'] = 'GET, POST, PUT, DELETE, OPTIONS'
        response.headers['X-Content-Type-Options'] = 'nosniff'
        response.headers['Referrer-Policy'] = 'same-origin'
        return response

    @app.post('/api/v1/auth/email/verification/request')
    async def verification_request(request: Request):
        session = require(request)
        if session['user']['emailVerified']:
            return {'sent': False, **mail.delivery_metadata(), 'developmentPreview': False,
                    'deliveryStatus': 'already_verified', 'message': '当前账号邮箱已验证，无需重新发送。'}
        action = accounts.create_email_action(kind='verify', uid=session['user']['id'])
        await run_in_threadpool(mail.send_action, action['email'], 'verify', action['token'])
        return {'sent': True, **mail.delivery_metadata()}

    @app.get('/api/v1/auth/development-mailbox')
    async def development_mailbox(request: Request):
        session = require(request)
        if not session['user'].get('email'):
            raise AuthError('当前账户尚未绑定邮箱，请先绑定并验证邮箱。', 400, 'email_not_bound')
        if request.query_params.get('purpose', 'verify-email') != 'verify-email':
            raise AuthError('开发邮箱仅支持当前账号的邮箱验证。', 400, 'invalid_mailbox_purpose')
        result = await run_in_threadpool(mail.development_verification, accounts, session['user'])
        return JSONResponse(result, headers={'Cache-Control': 'no-store', 'Pragma': 'no-cache'})

    @app.post('/api/v1/auth/email/verification/confirm')
    async def verification_confirm(request: Request):
        body = await request.json()
        uid = action_owner(request)
        accounts.confirm_email_action(token=body.get('token'), kind='verify', uid=uid)
        return {'verified': True}

    def deliver_reset(email):
        # Execute after sending the generic response: SMTP latency, account
        # throttling and delivery failures must not reveal whether a user exists.
        try:
            action = accounts.create_email_action(kind='reset', email=email)
            if action: mail.send_action(action['email'], 'reset', action['token'])
        except AuthError as error:
            logging.getLogger(__name__).warning('Password reset processing failed: %s', error.code)

    @app.post('/api/v1/auth/password/reset/request')
    async def reset_request(request: Request, background_tasks: BackgroundTasks):
        body = await request.json()
        await run_in_threadpool(accounts.limit_reset_requests, request.client.host if request.client else 'unknown')
        email = accounts.action_email(body.get('email'))
        background_tasks.add_task(deliver_reset, email)
        return JSONResponse(mail.reset_request_metadata(), headers={'Cache-Control': 'no-store'})

    @app.post('/api/v1/auth/password/reset/confirm')
    async def reset_confirm(request: Request):
        body = await request.json()
        uid = action_owner(request)
        accounts.confirm_email_action(token=body.get('token'), kind='reset', password=body.get('password'), uid=uid)
        response = JSONResponse({'reset': True})
        return response

    @app.post('/api/v1/sync/operations')
    async def operations(request: Request):
        uid = require(request)['user']['id']
        if len(await request.body()) > 8 * 1024 * 1024: return JSONResponse({'error': 'Sync batch exceeds 8 MiB'}, status_code=413)
        try: return await run_in_threadpool(sync.apply, uid, await request.json())
        except SyncConflict as exc:
            return JSONResponse({'error': 'Object version conflict', 'code': 'object_conflict',
                'conflicts': exc.conflicts, 'serverWorkspace': exc.workspace,
                'entityVersions': exc.workspace['entityVersions']}, status_code=409)
        except ValidationError as exc: return JSONResponse({'error': str(exc)}, status_code=400)

    @app.post('/api/v1/workspace/validate-merge')
    async def validate_merge(request: Request):
        uid = require(request)['user']['id']
        if len(await request.body()) > 8 * 1024 * 1024:
            return JSONResponse({'error': '合并内容过大。', 'code': 'invalid_merge'}, status_code=413)
        body = await request.json()
        if not isinstance(body, dict):
            return JSONResponse({'error': '合并请求需为 JSON 对象。', 'code': 'invalid_merge'}, status_code=400)
        def inspect():
            expected = body.get('expectedRevision')
            candidate = body.get('workspace')
            if type(expected) is not int or expected < 0:
                raise ValidationError('Invalid expected revision')
            previous = sync.load(uid)
            revision = (previous or {}).get('revision', 0)
            if revision != expected:
                return JSONResponse({'error': '云端记录已有更新，请刷新后重试。',
                    'code': 'revision_conflict', 'revision': revision}, status_code=409,
                    headers={'Cache-Control': 'no-store', 'Pragma': 'no-cache'})
            # This is the current sync contract, never the legacy import bypass.
            if not isinstance(candidate, dict) or candidate.get('schemaVersion') != 2:
                raise ValidationError('Merge requires schema 2')
            if candidate.get('revision') != expected:
                raise ValidationError('Merge revision mismatch')
            validate_workspace(candidate)
            validate_planning_result_changes(previous, candidate)
            from placement_policy import validate_placement_changes
            validate_placement_changes(previous, candidate)
            return JSONResponse({'valid': True, 'revision': revision},
                headers={'Cache-Control': 'no-store', 'Pragma': 'no-cache'})
        try:
            return await run_in_threadpool(inspect)
        except (ValidationError, ValueError, TypeError, KeyError, OverflowError, RecursionError):
            return JSONResponse({'error': '合并内容暂不能同步，请检查任务与安排后重试。',
                'code': 'invalid_merge'}, status_code=400,
                headers={'Cache-Control': 'no-store', 'Pragma': 'no-cache'})

    @app.get('/api/v1/sync/state')
    async def sync_state(request: Request):
        workspace = sync.load(require(request)['user']['id'])
        return {'workspace': workspace, 'entityVersions': workspace.get('entityVersions', {}) if workspace else {}}

    @app.get('/api/v1/account/export')
    async def account_export(request: Request):
        session = require(request)
        uid = session['user']['id']
        with accounts.connection() as db:
            jobs = [dict(row) for row in db.execute('SELECT id,kind,payload,status,result,error,created_at,updated_at FROM jobs WHERE user_id=?', (uid,))]
            push = [{'endpoint': json.loads(row['body']).get('endpoint'), 'createdAt': row['created_at']}
                    for row in db.execute('SELECT body,created_at FROM push_subscriptions WHERE user_id=?', (uid,))]
        return JSONResponse({'schemaVersion': 2, 'user': session['user'], 'workspace': sync.load(uid),
                'jobs': jobs, 'pushSubscriptions': push}, headers={'Cache-Control': 'no-store', 'Pragma': 'no-cache'})

    from workflows import attach_workflows
    attach_workflows(app)
    attach_device_workflows(app)
    from community_api import attach_community
    attach_community(app)
    from admin_api import attach_admin
    attach_admin(app)
    from sms_auth_service import SmsAuthService
    from sms_auth_routes import attach_sms_auth
    attach_sms_auth(app, accounts=accounts, service=sms_service or SmsAuthService.from_env(db_path),
                    mail=mail, session_response=session_response)

    @app.get('/health')
    @app.get('/health/live')
    async def live():
        return {'status': 'ok', 'service': 'sera-fastapi', 'schemaVersion': 2,
                'aiConfigured': bool(ai.configured), 'model': ai.model}

    @app.get('/health/ready')
    async def ready():
        def inspect():
            from urllib.request import urlopen
            components = {}
            try:
                with accounts.connection() as db:
                    db.execute('SELECT 1').fetchone()
                    heartbeat = db.execute("SELECT updated_at,status FROM service_heartbeats WHERE service='worker'").fetchone()
                components['database'] = {'status': 'ok'}
                age = int(time.time()) - heartbeat['updated_at'] if heartbeat else None
                components['worker'] = {'status': 'ok' if heartbeat and age < 150 and heartbeat['status'] == 'ok' else 'unavailable', 'heartbeatAgeSeconds': age}
            except Exception:
                components['database'] = {'status': 'unavailable'}
                components['worker'] = {'status': 'unavailable'}
            try:
                with urlopen(os.environ.get('SERA_ASR_HEALTH_URL', 'http://127.0.0.1:8790/health'), timeout=1) as response:
                    speech = json.load(response)
                components['asr'] = {'status': 'ok' if speech.get('status') == 'ok' else 'unavailable',
                    'model': speech.get('model'), 'loadSeconds': speech.get('loadSeconds')}
            except Exception: components['asr'] = {'status': 'unavailable'}
            try:
                mail.check_configuration()
                configured_mail = True
            except AuthError:
                configured_mail = False
            components['mail'] = {'status': 'ok' if configured_mail else 'unavailable', 'mode': mail.mode,
                'check': 'configuration_only; external delivery requires send verification'}
            components['ai'] = {'status': 'ok' if ai.configured else 'unavailable'}
            return components
        components = await run_in_threadpool(inspect)
        available = all(item['status'] == 'ok' for item in components.values())
        return JSONResponse({'status': 'ready' if available else 'degraded', 'schemaVersion': 2,
                             'components': components}, status_code=200 if available else 503)

    async def compatibility(request: Request, path: str):
        body = await request.body()
        if len(body) > 11 * 1024 * 1024: return JSONResponse({'error': 'Request too large'}, status_code=413)
        headers = dict(request.headers)
        request_token = token(request)
        supplied = headers.get('authorization', '').split()
        valid_bearer = len(supplied) == 2 and supplied[0].lower() == 'bearer'
        if request_token and not valid_bearer: headers['authorization'] = 'Bearer ' + request_token
        # Origin/CSRF was checked above. Legacy handler remains for validation,
        # persistence, media validation, static assets and existing contracts.
        headers.pop('origin', None)
        headers['connection'], headers['content-length'] = 'close', str(len(body))
        raw_path = request.scope.get('raw_path', request.url.path.encode()).decode('ascii')
        raw = (f'{request.method} {raw_path}' + (('?' + request.url.query) if request.url.query else '') +
            ' HTTP/1.1\r\n' + ''.join(f'{k}: {v}\r\n' for k, v in headers.items()) + '\r\n').encode() + body
        def dispatch():
            sock = InMemorySocket(raw)
            legacy.RequestHandlerClass(sock, (request.client.host if request.client else '127.0.0.1', 0), legacy)
            return bytes(sock.output)
        result = await run_in_threadpool(dispatch)
        head, payload = result.split(b'\r\n\r\n', 1)
        lines = head.decode('latin-1').split('\r\n')
        status = int(lines[0].split()[1])
        response_headers = {}
        for line in lines[1:]:
            name, value = line.split(':', 1)
            if name.lower() not in ('content-length', 'server', 'date', 'connection'): response_headers[name] = value.strip()
        json_body = None
        if request.url.path.startswith('/api/') and 'application/json' in response_headers.get('Content-Type', ''):
            try: json_body = json.loads(payload)
            except ValueError: pass
        auth_path = request.url.path in ('/api/v1/auth/login', '/api/v1/auth/register', '/api/v1/auth/me')
        if isinstance(json_body, dict) and status < 300 and auth_path:
            current_token = json_body.get('token') or request_token
            web = request.headers.get('x-sera-client') == 'web' or bool(request.cookies.get('sera_session'))
            json_body['sessionId'] = hashlib.sha256(current_token.encode()).hexdigest()[:24]
            json_body['cookieSession'], json_body['csrfToken'] = web, csrf(current_token) if web else ''
            if web:
                json_body['token'] = ''
                response = JSONResponse(json_body, status_code=status)
                # Reading /me must not overwrite a newer login cookie when an
                # old session's response arrives late in another tab/request.
                if request.url.path != '/api/v1/auth/me':
                    response.set_cookie('sera_session', current_token, httponly=True, secure=request.url.scheme == 'https',
                        samesite='strict', max_age=7 * 86400, path='/')
                return response
        if isinstance(json_body, dict) and isinstance(json_body.get('workspace'), dict):
            json_body['workspace'] = migrate_workspace(json_body['workspace'])
        if json_body is not None:
            response = JSONResponse(json_body, status_code=status)
            # Revocation in SQLite is authoritative. Deleting the shared-origin
            # cookie here could erase a newer login if this response arrives late.
            return response
        return Response(payload, status_code=status, headers=response_headers)
    from api_contract import install_contract
    install_contract(app, compatibility)
    app.add_api_route('/{path:path}', compatibility,
        methods=['GET', 'POST', 'PUT', 'DELETE', 'HEAD'], include_in_schema=False)
    return app
