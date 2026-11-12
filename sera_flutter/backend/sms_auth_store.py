"""Durable, one-use SMS challenges. No verification codes are persisted here.

The authentication mutation must call ``consume_claim`` using the SAME SQLite
transaction that creates/binds/deletes an account. Network calls never hold a
SQLite write transaction. Every reservation and check attempt commits first.
"""
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
import hashlib
import hmac
import re
import secrets
import sqlite3
import time

from auth_store import AuthError


class SmsAuthError(AuthError):
    def __init__(self, message, status=400, code='invalid_sms_request', retry_after_seconds=None):
        super().__init__(message, status, code)
        self.retry_after_seconds = retry_after_seconds


def normalize_phone(value):
    """The PNVS SMS API currently supports mainland China mobile numbers only."""
    if not isinstance(value, str) or len(value) > 32:
        raise SmsAuthError('请输入有效的中国大陆手机号。', code='invalid_phone')
    value = re.sub(r'[ -]', '', value.strip())
    if value.startswith('+86'):
        value = value[3:]
    if not re.fullmatch(r'1[3-9][0-9]{9}', value):
        raise SmsAuthError('请输入有效的中国大陆手机号。', code='invalid_phone')
    return '+86' + value


def masked_phone(phone):
    return '+86 ' + phone[3:6] + '****' + phone[-4:]


def timestamp(value):
    return datetime.fromtimestamp(value, timezone.utc).isoformat()


def session_digest(token):
    if not isinstance(token, str) or not 1 <= len(token) <= 512:
        raise SmsAuthError('请重新登录后再验证手机号。', 401, 'authentication_required')
    return hashlib.sha256(token.encode()).hexdigest()


@dataclass(frozen=True)
class SmsPolicy:
    valid_seconds: int = 300
    cooldown_seconds: int = 60
    max_attempts: int = 5
    phone_hour_limit: int = 5
    phone_day_limit: int = 10
    ip_minute_limit: int = 5
    ip_hour_limit: int = 20
    global_hour_limit: int = 50
    global_day_limit: int = 100
    claim_seconds: int = 60

    def __post_init__(self):
        if not 60 <= self.valid_seconds <= 600 or not 60 <= self.cooldown_seconds <= 600:
            raise ValueError('SMS validity and cooldown are outside supported bounds')
        if not 1 <= self.max_attempts <= 10 or not 1 <= self.claim_seconds <= 300:
            raise ValueError('SMS attempt and claim limits are outside supported bounds')
        for name in ('phone_hour_limit', 'phone_day_limit', 'ip_minute_limit',
                     'ip_hour_limit', 'global_hour_limit', 'global_day_limit'):
            if not isinstance(getattr(self, name), int) or not 1 <= getattr(self, name) <= 10000:
                raise ValueError('SMS quotas must be between 1 and 10000')


@dataclass(frozen=True)
class VerifiedSmsClaim:
    """Internal proof: never serialize this object or expose its secret to a client."""
    challenge_id: str
    phone: str
    purpose: str
    owner_uid: str | None
    session_hash: str | None = field(repr=False)
    secret: str = field(repr=False)


class SmsAuthStore:
    purposes = frozenset(('login', 'bind_phone', 'sensitive'))

    def __init__(self, path, *, policy=None, clock=None):
        self.path = str(path)
        self.policy = policy or SmsPolicy()
        self.clock = clock or time.time
        with self.connection() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS sms_auth_challenges (
                    id TEXT PRIMARY KEY, phone TEXT NOT NULL, purpose TEXT NOT NULL,
                    owner_uid TEXT, session_hash TEXT, out_id TEXT NOT NULL UNIQUE,
                    source_hash TEXT NOT NULL, created_at INTEGER NOT NULL,
                    expires_at INTEGER NOT NULL, resend_at INTEGER NOT NULL,
                    status TEXT NOT NULL, delivery_status TEXT NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0, verify_nonce TEXT,
                    verified_until INTEGER, claim_hash TEXT);
                CREATE INDEX IF NOT EXISTS sms_auth_phone_time
                    ON sms_auth_challenges(phone, created_at);
                CREATE INDEX IF NOT EXISTS sms_auth_source_time
                    ON sms_auth_challenges(source_hash, created_at);
                CREATE INDEX IF NOT EXISTS sms_auth_time ON sms_auth_challenges(created_at);
            ''')

    @contextmanager
    def connection(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA foreign_keys=ON')
        try:
            with db:
                yield db
        finally:
            db.close()

    def _scope(self, purpose, owner_uid, session_token):
        if purpose not in self.purposes:
            raise SmsAuthError('短信验证用途无效。', code='invalid_sms_purpose')
        if purpose == 'login':
            if owner_uid is not None or session_token is not None:
                raise SmsAuthError('登录验证不能用作账号绑定。', code='sms_scope_mismatch')
            return None
        if not isinstance(owner_uid, str) or not 1 <= len(owner_uid) <= 128:
            raise SmsAuthError('请先登录账号。', 401, 'authentication_required')
        return session_digest(session_token)

    def reserve_send(self, phone, *, purpose='login', source_ip, owner_uid=None, session_token=None):
        phone = normalize_phone(phone)
        scope_hash = self._scope(purpose, owner_uid, session_token)
        if not isinstance(source_ip, str) or not 1 <= len(source_ip) <= 256:
            raise SmsAuthError('无法确认请求来源，请稍后重试。', code='sms_source_required')
        source_hash = hashlib.sha256(source_ip.encode()).hexdigest()
        now, policy = int(self.clock()), self.policy
        with self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            if purpose != 'login':
                # Route preflight can become stale while a different worker
                # logs out/deletes the account. Serialize live-session and
                # phone-state validation with the paid-send reservation.
                try:
                    user = db.execute('''SELECT u.phone FROM users u JOIN sessions s ON s.user_id=u.id
                        WHERE u.id=? AND s.token_hash=? AND s.expires_at>?''',
                        (owner_uid, scope_hash, now)).fetchone()
                except sqlite3.OperationalError:
                    # An independent store without an account schema is never
                    # permitted to authorize an authenticated-purpose send.
                    user = None
                if user is None:
                    raise SmsAuthError('账号会话已失效，请重新登录后获取验证码。', 401, 'session_expired')
                if purpose == 'sensitive' and user['phone'] != phone:
                    raise SmsAuthError('请使用当前账号已绑定的手机号。', 403, 'sms_scope_mismatch')
                if purpose == 'bind_phone' and user['phone'] is not None:
                    raise SmsAuthError('当前账号已有绑定手机号，请刷新账号状态后重试。', 409, 'phone_already_bound')
            # Reservations, rejected sends, and uncertain sends all count. Never
            # free paid quotas merely because the HTTP request failed locally.
            db.execute('DELETE FROM sms_auth_challenges WHERE created_at<=?', (now - 172800,))
            latest = db.execute('SELECT resend_at FROM sms_auth_challenges WHERE phone=? '
                                'ORDER BY created_at DESC LIMIT 1', (phone,)).fetchone()
            if latest and latest['resend_at'] > now:
                raise SmsAuthError('请等待倒计时结束后再获取验证码。', 429, 'sms_cooldown', latest['resend_at'] - now)
            checks = (
                ('phone=? AND created_at>?', (phone, now - 3600), policy.phone_hour_limit),
                ('phone=? AND created_at>?', (phone, now - 86400), policy.phone_day_limit),
                ('source_hash=? AND created_at>?', (source_hash, now - 60), policy.ip_minute_limit),
                ('source_hash=? AND created_at>?', (source_hash, now - 3600), policy.ip_hour_limit),
                ('created_at>?', (now - 3600,), policy.global_hour_limit),
                ('created_at>?', (now - 86400,), policy.global_day_limit),
            )
            for where, values, maximum in checks:
                if db.execute('SELECT count(*) FROM sms_auth_challenges WHERE ' + where, values).fetchone()[0] >= maximum:
                    raise SmsAuthError('短信请求过于频繁，请稍后再试或使用邮箱登录。', 429, 'sms_rate_limited')
            challenge_id, out_id = secrets.token_urlsafe(32), secrets.token_hex(24)
            # PNVS overwrite applies across purposes within a scheme. Invalidate
            # all local challenges for the same number, including in-flight ones.
            db.execute("UPDATE sms_auth_challenges SET status='superseded',claim_hash=NULL "
                       "WHERE phone=? AND status NOT IN ('consumed','failed','superseded','exhausted')", (phone,))
            db.execute('''INSERT INTO sms_auth_challenges
                (id,phone,purpose,owner_uid,session_hash,out_id,source_hash,created_at,expires_at,
                 resend_at,status,delivery_status) VALUES(?,?,?,?,?,?,?,?,?,?,'sending','pending')''',
                (challenge_id, phone, purpose, owner_uid, scope_hash, out_id, source_hash,
                 now, now + policy.valid_seconds, now + policy.cooldown_seconds))
            return dict(db.execute('SELECT * FROM sms_auth_challenges WHERE id=?', (challenge_id,)).fetchone())

    def complete_send(self, challenge_id, delivery_status):
        if delivery_status not in ('submitted', 'unknown', 'failed'):
            raise ValueError('Invalid SMS delivery state')
        state = {'submitted': 'sent', 'unknown': 'unknown', 'failed': 'failed'}[delivery_status]
        with self.connection() as db:
            db.execute('UPDATE sms_auth_challenges SET status=?,delivery_status=? WHERE id=? AND status=\'sending\'',
                       (state, delivery_status, challenge_id))

    def _challenge(self, db, challenge_id, purpose, owner_uid, scope_hash):
        if not isinstance(challenge_id, str) or not 32 <= len(challenge_id) <= 128:
            raise SmsAuthError('验证码请求已失效，请重新获取。', code='sms_challenge_expired')
        row = db.execute('SELECT * FROM sms_auth_challenges WHERE id=?', (challenge_id,)).fetchone()
        if not row or row['expires_at'] <= int(self.clock()):
            raise SmsAuthError('验证码请求已过期，请重新获取。', code='sms_challenge_expired')
        if (row['purpose'] != purpose or row['owner_uid'] != owner_uid or row['session_hash'] != scope_hash):
            raise SmsAuthError('验证码不适用于当前操作或账号，请重新获取。', 403, 'sms_scope_mismatch')
        if row['status'] in ('superseded', 'consumed', 'failed', 'exhausted'):
            raise SmsAuthError('验证码已失效、已使用或次数已用完，请重新获取。', code='sms_challenge_expired')
        return row

    def challenge_phone(self, challenge_id, *, purpose='login', owner_uid=None, session_token=None):
        scope_hash = self._scope(purpose, owner_uid, session_token)
        with self.connection() as db:
            return self._challenge(db, challenge_id, purpose, owner_uid, scope_hash)['phone']

    def begin_verification(self, challenge_id, *, purpose='login', owner_uid=None, session_token=None):
        scope_hash = self._scope(purpose, owner_uid, session_token)
        with self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            row = self._challenge(db, challenge_id, purpose, owner_uid, scope_hash)
            # There is deliberately no expiring/reacquirable lease. A worker
            # that died during a provider check may still have a live request;
            # reopening it would permit parallel successful checks. Resend is
            # the recovery path, after the persisted cooldown.
            if row['status'] in ('verifying', 'verified', 'sending'):
                raise SmsAuthError('验证码正在处理或已验证，请稍后重试；若仍无结果请重新获取。', 409, 'sms_verification_busy')
            if row['attempts'] >= self.policy.max_attempts:
                raise SmsAuthError('验证码尝试次数已用完，请重新获取。', 429, 'sms_attempts_exhausted')
            nonce = secrets.token_urlsafe(32)
            db.execute("UPDATE sms_auth_challenges SET status='verifying', attempts=attempts+1,verify_nonce=? WHERE id=?",
                       (nonce, challenge_id))
            result = dict(row)
            result['verify_nonce'] = nonce
            result['attempts'] += 1
            return result

    def complete_verification(self, challenge, *, passed=False, provider_error=False):
        now, error, claim = int(self.clock()), None, None
        with self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT * FROM sms_auth_challenges WHERE id=?', (challenge['id'],)).fetchone()
            if (not row or row['status'] != 'verifying' or row['verify_nonce'] != challenge['verify_nonce']
                    or row['expires_at'] <= now):
                raise SmsAuthError('验证码已失效，请重新获取。', code='sms_challenge_expired')
            if passed:
                secret = secrets.token_urlsafe(32)
                db.execute("UPDATE sms_auth_challenges SET status='verified',verify_nonce=NULL,claim_hash=?,verified_until=? WHERE id=?",
                           (hashlib.sha256(secret.encode()).hexdigest(), min(now + self.policy.claim_seconds, row['expires_at']), row['id']))
                claim = VerifiedSmsClaim(row['id'], row['phone'], row['purpose'], row['owner_uid'], row['session_hash'], secret)
            else:
                exhausted = row['attempts'] >= self.policy.max_attempts
                db.execute('UPDATE sms_auth_challenges SET status=?,verify_nonce=NULL WHERE id=?',
                           ('exhausted' if exhausted else ('unknown' if provider_error else 'sent'), row['id']))
                if not provider_error:
                    error = SmsAuthError('验证码尝试次数已用完，请重新获取。' if exhausted else '验证码不正确，请检查后重试。',
                                         429 if exhausted else 400, 'sms_attempts_exhausted' if exhausted else 'invalid_sms_code')
        # Raise AFTER commit: incorrect attempts must survive handled AuthErrors.
        if error:
            raise error
        return claim

    def consume_claim(self, db, claim):
        """Call inside caller's BEGIN IMMEDIATE account transaction; returns phone."""
        if not isinstance(claim, VerifiedSmsClaim) or not db.in_transaction:
            raise ValueError('SMS claim must be consumed inside an account transaction')
        now = int(self.clock())
        row = db.execute('SELECT * FROM sms_auth_challenges WHERE id=?', (claim.challenge_id,)).fetchone()
        digest = hashlib.sha256(claim.secret.encode()).hexdigest()
        if (not row or row['status'] != 'verified' or row['verified_until'] <= now or row['expires_at'] <= now
                or row['phone'] != claim.phone or row['purpose'] != claim.purpose
                or row['owner_uid'] != claim.owner_uid or row['session_hash'] != claim.session_hash
                or not hmac.compare_digest(row['claim_hash'] or '', digest)):
            raise SmsAuthError('手机号验证已失效或已使用，请重新获取验证码。', code='sms_claim_expired')
        db.execute("UPDATE sms_auth_challenges SET status='consumed',claim_hash=NULL WHERE id=?", (row['id'],))
        return row['phone']

    @staticmethod
    def delete_account_data(db, owner_uid):
        # Keep only anonymous send quota records until normal 48-hour pruning;
        # removing them would let delete/recreate bypass global/number limits.
        db.execute("UPDATE sms_auth_challenges SET owner_uid=NULL,session_hash=NULL,status='consumed',claim_hash=NULL "
                   'WHERE owner_uid=?', (owner_uid,))
