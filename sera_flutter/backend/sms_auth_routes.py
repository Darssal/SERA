"""Phone identity endpoints. Provider credentials and verification claims stay server-side."""
import hashlib
import secrets
import time

from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

from auth_store import AuthError


class PhoneProofs:
    """One-use recent identity proofs bound to the exact live session and phone."""
    def __init__(self, accounts):
        self.accounts = accounts
        with accounts.connection() as db:
            db.execute('''CREATE TABLE IF NOT EXISTS phone_identity_proofs(
                token_hash TEXT PRIMARY KEY,
                user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                session_hash TEXT NOT NULL REFERENCES sessions(token_hash) ON DELETE CASCADE,
                phone TEXT NOT NULL, expires_at INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0)''')

    @staticmethod
    def digest(value):
        return hashlib.sha256(value.encode()).hexdigest()

    def issue(self, claim, *, uid, token, consume):
        now = int(time.time())
        value = secrets.token_urlsafe(32)
        with self.accounts.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            self._session(db, uid, token, claim.phone)
            consume(db, claim)
            db.execute('DELETE FROM phone_identity_proofs WHERE expires_at<=? OR used=1', (now,))
            db.execute('INSERT INTO phone_identity_proofs VALUES(?,?,?,?,?,0)',
                (self.digest(value), uid, self.digest(token), claim.phone, now + 300))
        return {'phoneProof': value, 'expiresIn': 300}

    def _session(self, db, uid, token, phone=None):
        user = db.execute('''SELECT u.phone FROM users u JOIN sessions s ON s.user_id=u.id
            WHERE u.id=? AND s.token_hash=? AND s.expires_at>?''',
            (uid, self.digest(token), int(time.time()))).fetchone()
        if not user or not user['phone'] or (phone is not None and user['phone'] != phone):
            raise AuthError('账号会话或已绑定手机号已变化，请重新验证。', 401, 'phone_proof_invalid')
        return user['phone']

    def consumer(self, value, *, uid, token):
        def consume(db):
            if not isinstance(value, str) or not 20 <= len(value) <= 512:
                raise AuthError('请先验证当前绑定手机号。', 401, 'phone_proof_required')
            phone = self._session(db, uid, token)
            changed = db.execute('''UPDATE phone_identity_proofs SET used=1
                WHERE token_hash=? AND user_id=? AND session_hash=? AND phone=?
                  AND expires_at>? AND used=0''',
                (self.digest(value), uid, self.digest(token), phone, int(time.time()))).rowcount
            if changed != 1:
                raise AuthError('手机号验证已过期、已使用或属于其他会话，请重新验证。', 401, 'phone_proof_invalid')
        return consume


def attach_sms_auth(app, *, accounts, service, mail, session_response):
    require, token = app.state.require, app.state.token
    proofs = PhoneProofs(accounts)
    app.state.sms, app.state.phone_proofs = service, proofs

    def private_json(body, status=200):
        return JSONResponse(body, status_code=status, headers={'Cache-Control': 'no-store', 'Pragma': 'no-cache'})

    def current(request):
        session = require(request)
        return session['user'], token(request)

    def consume_recent(body, user, session_token):
        return proofs.consumer(body.get('phoneProof'), uid=user['id'], token=session_token)

    @app.get('/api/v1/auth/phone/capabilities')
    async def capabilities():
        return private_json(service.capabilities())

    @app.post('/api/v1/auth/phone/challenge')
    async def challenge(request: Request):
        body = await request.json()
        purpose = body.get('purpose', 'login')
        if purpose not in ('login', 'bind_phone', 'sensitive'):
            raise AuthError('验证码用途无效。', 400, 'invalid_phone_purpose')
        user, session_token = (None, None) if purpose == 'login' else current(request)
        phone = body.get('phone')
        if purpose == 'bind_phone':
            await run_in_threadpool(accounts.preflight_phone_binding, session_token, phone,
                                    password=body.get('currentPassword'))
        elif purpose == 'sensitive':
            # The caller cannot select another phone for current-account proof.
            from sms_auth_store import normalize_phone
            if not user.get('phone') or normalize_phone(phone) != user['phone']:
                raise AuthError('请使用当前账户已绑定的手机号。', 403, 'phone_account_mismatch')
        # Only the actual peer address is trusted. Forwarded headers require a
        # separately configured reverse proxy, never arbitrary client input.
        result = await run_in_threadpool(service.send, phone, purpose=purpose,
            source_ip=request.client.host if request.client else 'unknown',
            owner_uid=user['id'] if user else None, session_token=session_token)
        return private_json(result)

    @app.post('/api/v1/auth/phone/login')
    async def phone_login(request: Request):
        body = await request.json()
        challenge_id = body.get('challengeId')
        phone = await run_in_threadpool(service.challenge_phone, challenge_id, purpose='login')
        consent = body.get('acceptRegistration') is True
        if not consent and not accounts.phone_registered(phone):
            raise AuthError('此手机号尚未注册，请明确同意创建账户后继续。', 409, 'registration_required')
        claim = await run_in_threadpool(service.verify, challenge_id, body.get('code'), purpose='login')
        result = await run_in_threadpool(accounts.login_phone, phone, consent=consent,
            consume_proof=lambda db: service.store.consume_claim(db, claim))
        return session_response(request, result)

    @app.post('/api/v1/auth/phone/bind')
    async def bind_phone(request: Request):
        user, session_token = current(request)
        body = await request.json()
        challenge_id = body.get('challengeId')
        phone = await run_in_threadpool(service.challenge_phone, challenge_id,
            purpose='bind_phone', owner_uid=user['id'], session_token=session_token)
        await run_in_threadpool(accounts.preflight_phone_binding, session_token, phone,
                                password=body.get('currentPassword'))
        claim = await run_in_threadpool(service.verify, challenge_id, body.get('code'),
            purpose='bind_phone', owner_uid=user['id'], session_token=session_token)
        await run_in_threadpool(accounts.bind_phone, session_token, phone,
            password=body.get('currentPassword'), consume_proof=lambda db: service.store.consume_claim(db, claim))
        return private_json({'bound': True})

    @app.post('/api/v1/auth/phone/verify-sensitive')
    async def verify_sensitive(request: Request):
        user, session_token = current(request)
        body = await request.json()
        claim = await run_in_threadpool(service.verify, body.get('challengeId'), body.get('code'),
            purpose='sensitive', owner_uid=user['id'], session_token=session_token)
        result = await run_in_threadpool(proofs.issue, claim, uid=user['id'], token=session_token,
                                        consume=service.store.consume_claim)
        return private_json(result)

    @app.post('/api/v1/auth/email/bind/request')
    async def bind_email_request(request: Request):
        user, session_token = current(request)
        body = await request.json()
        action = await run_in_threadpool(accounts.start_email_binding, session_token, body.get('email'),
            password=body.get('currentPassword'), consume_proof=consume_recent(body, user, session_token))
        await run_in_threadpool(mail.send_action, action['email'], 'bind', action['token'])
        return private_json({'sent': True, **mail.delivery_metadata(), 'developmentPreview': False})

    @app.post('/api/v1/auth/email/bind/confirm')
    async def bind_email_confirm(request: Request):
        _, session_token = current(request)
        body = await request.json()
        await run_in_threadpool(accounts.confirm_email_binding, session_token, body.get('token'))
        return private_json({'verified': True})

    @app.post('/api/v1/auth/password/set')
    async def password_set(request: Request):
        user, session_token = current(request)
        body = await request.json()
        await run_in_threadpool(accounts.set_password, session_token, body.get('password'),
            password=body.get('currentPassword'), consume_proof=consume_recent(body, user, session_token))
        return private_json({'passwordSet': True})

    @app.delete('/api/v1/account')
    async def delete_account(request: Request):
        user, session_token = current(request)
        body = await request.json()
        await run_in_threadpool(accounts.delete_account, session_token, body.get('password'),
            consume_proof=consume_recent(body, user, session_token))
        return private_json({'deleted': True})
