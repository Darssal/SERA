"""Email/password and verified phone identities with expiring opaque sessions.

Phone proof callbacks are server-only closures. They must validate and consume a
purpose-, account- and session-bound proof using the supplied SQLite connection;
the enclosing transaction makes proof consumption and identity mutation atomic.
"""
from datetime import datetime, timezone
from email.errors import HeaderParseError
from email.headerregistry import Address
import hashlib
import hmac
import re
import secrets
import sqlite3
import time
from contextlib import contextmanager


class AuthError(Exception):
    def __init__(self, message, status=400, code='invalid_auth_request'):
        super().__init__(message)
        self.status, self.code = status, code


class AuthStore:
    SCHEMA_VERSION = 2
    USER_SCHEMA = '''(
      id TEXT PRIMARY KEY, username TEXT NOT NULL COLLATE NOCASE UNIQUE,
      email TEXT COLLATE NOCASE UNIQUE, salt BLOB, password_hash BLOB,
      iterations INTEGER NOT NULL DEFAULT 600000, created_at INTEGER NOT NULL,
      email_verified INTEGER NOT NULL DEFAULT 0, phone TEXT UNIQUE,
      CHECK(email IS NOT NULL OR phone IS NOT NULL),
      CHECK((salt IS NULL AND password_hash IS NULL) OR
            (salt IS NOT NULL AND password_hash IS NOT NULL)))'''

    def __init__(self, path):
        self.path = str(path)
        self._migrate_identities()
        with self.connection() as db:
            db.executescript('''
              CREATE TABLE IF NOT EXISTS sessions (
                token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                expires_at INTEGER NOT NULL);
              CREATE TABLE IF NOT EXISTS account_workspaces (
                user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
                revision INTEGER NOT NULL, body TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS auth_account_status (
                user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
                disabled INTEGER NOT NULL CHECK(disabled IN (0,1)),
                reason TEXT NOT NULL, updated_at INTEGER NOT NULL,
                updated_by TEXT REFERENCES users(id) ON DELETE SET NULL);
            ''')
            db.execute('''CREATE TABLE IF NOT EXISTS email_actions(
              token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
              kind TEXT NOT NULL, expires_at INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0)''')
            db.execute('''CREATE TABLE IF NOT EXISTS mail_request_limits(
              source_hash TEXT NOT NULL, requested_at INTEGER NOT NULL)''')
            db.execute('CREATE INDEX IF NOT EXISTS mail_request_source ON mail_request_limits(source_hash,requested_at)')
            db.executescript('''
              CREATE TABLE IF NOT EXISTS email_bindings(
                token_hash TEXT PRIMARY KEY,
                user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                session_hash TEXT NOT NULL REFERENCES sessions(token_hash) ON DELETE CASCADE,
                email TEXT NOT NULL COLLATE NOCASE, created_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0);
              CREATE UNIQUE INDEX IF NOT EXISTS email_binding_reserved_email
                ON email_bindings(email) WHERE used=0;
              CREATE UNIQUE INDEX IF NOT EXISTS email_binding_current_user
                ON email_bindings(user_id) WHERE used=0;
            ''')

    def _migrate_identities(self):
        """Rebuild only users in one transaction without renaming FK targets.

        Foreign keys must be disabled *before* BEGIN so DROP does not cascade.
        Child tables keep REFERENCES users(id), and foreign_key_check validates
        the rebuilt parent before commit. A failed migration rolls back the DDL.
        """
        db = sqlite3.connect(self.path, timeout=10)
        try:
            db.execute('PRAGMA foreign_keys=OFF')
            db.execute('BEGIN IMMEDIATE')
            columns = {row[1]: row for row in db.execute('PRAGMA table_info(users)')}
            if not columns:
                db.execute('CREATE TABLE users ' + self.USER_SCHEMA)
            elif 'phone' not in columns or any(columns[name][3] for name in ('email', 'salt', 'password_hash')):
                expected = {'id', 'username', 'email', 'salt', 'password_hash', 'iterations',
                            'created_at', 'email_verified', 'phone'}
                if set(columns) - expected:
                    raise sqlite3.DatabaseError('Unsupported users schema; identity migration refused to discard unknown columns')
                definitions = [row[0] for row in db.execute(
                    "SELECT sql FROM sqlite_master WHERE tbl_name='users' AND type IN ('index','trigger') AND sql IS NOT NULL")]
                db.execute('CREATE TABLE users_identity_v2 ' + self.USER_SCHEMA)
                verified = 'email_verified' if 'email_verified' in columns else '0'
                phone = 'phone' if 'phone' in columns else 'NULL'
                db.execute('''INSERT INTO users_identity_v2
                    (id,username,email,salt,password_hash,iterations,created_at,email_verified,phone)
                    SELECT id,username,email,salt,password_hash,iterations,created_at,'''
                    + verified + ',' + phone + ' FROM users')
                db.execute('DROP TABLE users')
                db.execute('ALTER TABLE users_identity_v2 RENAME TO users')
                for definition in definitions:
                    db.execute(definition)
                if db.execute('PRAGMA foreign_key_check').fetchone():
                    raise sqlite3.IntegrityError('Identity migration failed foreign key validation')
            db.execute('''CREATE TABLE IF NOT EXISTS auth_schema_migrations(
                version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL)''')
            db.execute('INSERT OR IGNORE INTO auth_schema_migrations VALUES(?,?)',
                       (self.SCHEMA_VERSION, int(time.time())))
            db.commit()
        except Exception:
            db.rollback()
            raise
        finally:
            db.close()

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

    @staticmethod
    def public(row):
        return {'id': row['id'], 'username': row['username'], 'email': row['email'],
                'emailVerified': bool(row['email_verified']), 'phone': row['phone'],
                'hasPassword': row['password_hash'] is not None}

    @staticmethod
    def phone(value):
        if not isinstance(value, str) or len(value) > 32:
            raise AuthError('请填写中国大陆手机号。', 400, 'invalid_phone')
        value = re.sub(r'[ -]', '', value.strip())
        if value.startswith('+86'):
            value = value[3:]
        if not re.fullmatch(r'1[3-9][0-9]{9}', value):
            raise AuthError('请填写有效的中国大陆手机号。', 400, 'invalid_phone')
        return '+86' + value

    @staticmethod
    def _token_hash(token):
        if not isinstance(token, str) or not 1 <= len(token) <= 512:
            raise AuthError('请先登录账号。', 401, 'authentication_required')
        return hashlib.sha256(token.encode()).hexdigest()

    def _session_user(self, db, token):
        digest = self._token_hash(token)
        user = db.execute('''SELECT u.* FROM sessions s JOIN users u ON u.id=s.user_id
            WHERE s.token_hash=? AND s.expires_at>?''', (digest, int(time.time()))).fetchone()
        if user is None:
            raise AuthError('登录已过期，请重新登录。', 401, 'session_expired')
        self._ensure_active(db, user['id'])
        return user, digest

    @staticmethod
    def _ensure_active(db, uid):
        status = db.execute('SELECT disabled FROM auth_account_status WHERE user_id=?', (uid,)).fetchone()
        if status and status['disabled']:
            raise AuthError('此账号已被停用，请联系 SERA 官方。', 403, 'account_disabled')

    @staticmethod
    def _password_matches(user, password):
        if not isinstance(password, str) or len(password) > 128:
            return False
        actual = hashlib.pbkdf2_hmac('sha256', password.encode(),
            user['salt'] if user and user['salt'] is not None else b'\0' * 16,
            user['iterations'] if user else 600000)
        return bool(user and user['password_hash'] is not None and
                    hmac.compare_digest(actual, user['password_hash']))

    @staticmethod
    def _consume_proof(db, callback):
        if not callable(callback):
            raise AuthError('请先验证当前手机号。', 401, 'recent_phone_verification_required')
        if callback(db) is False:
            raise AuthError('手机号验证已失效，请重新验证。', 401, 'recent_phone_verification_required')

    def _require_identity(self, db, user, password, consume_proof):
        if self._password_matches(user, password):
            return
        if user['phone'] is not None and callable(consume_proof):
            self._consume_proof(db, consume_proof)
            return
        if user['password_hash'] is None:
            raise AuthError('请先验证当前手机号。', 401, 'recent_phone_verification_required')
        raise AuthError('当前密码不正确，请重新验证。', 401, 'invalid_credentials')

    @staticmethod
    def password(value):
        if not isinstance(value, str) or not 10 <= len(value) <= 128:
            raise AuthError('密码需为 10 至 128 位。')
        return value

    def _session(self, db, user):
        self._ensure_active(db, user['id'])
        token = secrets.token_urlsafe(32)
        expires = int(time.time()) + 7 * 86400
        db.execute('DELETE FROM sessions WHERE expires_at <= ?', (int(time.time()),))
        db.execute('INSERT INTO sessions VALUES(?,?,?)', (hashlib.sha256(token.encode()).hexdigest(), user['id'], expires))
        return {'token': token, 'expiresAt': datetime.fromtimestamp(expires, timezone.utc).isoformat(), 'user': self.public(user)}

    def register(self, body):
        if not isinstance(body, dict):
            raise AuthError('注册信息无效。')
        username, email = body.get('username'), body.get('email')
        password = self.password(body.get('password'))
        if not isinstance(username, str) or not re.fullmatch(r'[\w\-]{3,40}', username, re.UNICODE):
            raise AuthError('用户名需为 3 至 40 位字母、数字、中文、下划线或连字符。')
        email = self.action_email(email)
        salt, iterations = secrets.token_bytes(16), 600000
        hashed = hashlib.pbkdf2_hmac('sha256', password.encode(), salt, iterations)
        uid = secrets.token_hex(16)
        try:
            with self.connection() as db:
                db.execute('INSERT INTO users(id,username,email,salt,password_hash,iterations,created_at) VALUES(?,?,?,?,?,?,?)', (uid, username, email.lower(), salt, hashed, iterations, int(time.time())))
                return self._session(db, db.execute('SELECT * FROM users WHERE id=?', (uid,)).fetchone())
        except sqlite3.IntegrityError:
            raise AuthError('用户名或邮箱已被使用。', 409, 'account_exists') from None

    def login(self, body):
        if not isinstance(body, dict):
            raise AuthError('登录信息无效。')
        identifier, password = body.get('identifier'), body.get('password')
        if not isinstance(identifier, str) or len(identifier) > 254 or not isinstance(password, str) or len(password) > 128:
            raise AuthError('用户名、邮箱或密码错误。', 401, 'invalid_credentials')
        with self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            user = db.execute('SELECT * FROM users WHERE username=? COLLATE NOCASE OR email=? COLLATE NOCASE', (identifier, identifier)).fetchone()
            if not self._password_matches(user, password):
                raise AuthError('用户名、邮箱或密码错误。', 401, 'invalid_credentials')
            return self._session(db, user)

    def phone_registered(self, phone):
        phone = self.phone(phone)
        with self.connection() as db:
            return db.execute('SELECT 1 FROM users WHERE phone=?', (phone,)).fetchone() is not None

    def login_phone(self, phone, *, consent=False, consume_proof):
        phone = self.phone(phone)
        with self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            user = db.execute('SELECT * FROM users WHERE phone=?', (phone,)).fetchone()
            created = user is None
            if user is None and consent is not True:
                raise AuthError('首次使用该手机号需同意注册账号。', 409, 'phone_registration_consent_required')
            self._consume_proof(db, consume_proof)
            if user is None:
                uid, now = secrets.token_hex(16), int(time.time())
                db.execute('''INSERT INTO users(id,username,phone,iterations,created_at)
                    VALUES(?,?,?,?,?)''', (uid, 'sera_' + secrets.token_hex(8), phone, 600000, now))
                user = db.execute('SELECT * FROM users WHERE id=?', (uid,)).fetchone()
            return {**self._session(db, user), 'created': created}

    def preflight_phone_binding(self, token, phone, password=None):
        phone = self.phone(phone)
        with self.connection() as db:
            user, _ = self._session_user(db, token)
            if user['phone'] is not None:
                raise AuthError('当前账号已绑定手机号，本轮暂不支持更换。', 409, 'phone_already_bound')
            self._require_identity(db, user, password, None)
            if db.execute('SELECT 1 FROM users WHERE phone=?', (phone,)).fetchone():
                raise AuthError('该手机号已属于其他账号，不能合并账号。', 409, 'phone_in_use')
            return self.public(user)

    def bind_phone(self, token, phone, *, password=None, consume_proof, consume_current_proof=None):
        phone = self.phone(phone)
        with self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            user, _ = self._session_user(db, token)
            if user['phone'] is not None:
                raise AuthError('当前账号已绑定手机号，本轮暂不支持更换。', 409, 'phone_already_bound')
            self._require_identity(db, user, password, consume_current_proof)
            if db.execute('SELECT 1 FROM users WHERE phone=?', (phone,)).fetchone():
                raise AuthError('该手机号已属于其他账号，不能合并账号。', 409, 'phone_in_use')
            self._consume_proof(db, consume_proof)
            db.execute('UPDATE users SET phone=? WHERE id=?', (phone, user['id']))
            return self.public(db.execute('SELECT * FROM users WHERE id=?', (user['id'],)).fetchone())

    def set_password(self, token, new_password, *, password=None, consume_proof=None):
        new_password = self.password(new_password)
        salt, iterations = secrets.token_bytes(16), 600000
        hashed = hashlib.pbkdf2_hmac('sha256', new_password.encode(), salt, iterations)
        with self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            user, session_hash = self._session_user(db, token)
            self._require_identity(db, user, password, consume_proof)
            db.execute('UPDATE users SET salt=?,password_hash=?,iterations=? WHERE id=?',
                       (salt, hashed, iterations, user['id']))
            db.execute('UPDATE email_actions SET used=1 WHERE user_id=?', (user['id'],))
            db.execute('UPDATE email_bindings SET used=1 WHERE user_id=?', (user['id'],))
            self._revoke_other_sessions(db, user['id'], session_hash)
            return self.public(db.execute('SELECT * FROM users WHERE id=?', (user['id'],)).fetchone())

    @staticmethod
    def _revoke_other_sessions(db, uid, keep_hash=None):
        if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='push_subscriptions'").fetchone():
            has_session_hash = 'session_hash' in {row[1] for row in db.execute('PRAGMA table_info(push_subscriptions)')}
            if keep_hash is None or not has_session_hash:
                db.execute('DELETE FROM push_subscriptions WHERE user_id=?', (uid,))
            else:
                db.execute('DELETE FROM push_subscriptions WHERE user_id=? AND (session_hash IS NULL OR session_hash<>?)',
                           (uid, keep_hash))
        if keep_hash is None:
            db.execute('DELETE FROM sessions WHERE user_id=?', (uid,))
        else:
            db.execute('DELETE FROM sessions WHERE user_id=? AND token_hash<>?', (uid, keep_hash))

    def start_email_binding(self, token, email, *, password=None, consume_proof=None):
        email, now = self.action_email(email), int(time.time())
        try:
            with self.connection() as db:
                db.execute('BEGIN IMMEDIATE')
                user, session_hash = self._session_user(db, token)
                if user['email'] is not None:
                    raise AuthError('当前账号已绑定邮箱，本轮暂不支持更换。', 409, 'email_already_bound')
                if db.execute('SELECT 1 FROM users WHERE email=? COLLATE NOCASE', (email,)).fetchone():
                    raise AuthError('该邮箱已属于其他账号，不能合并账号。', 409, 'email_in_use')
                db.execute('UPDATE email_bindings SET used=1 WHERE expires_at<=?', (now,))
                if db.execute('''SELECT 1 FROM email_bindings WHERE email=? COLLATE NOCASE
                    AND used=0 AND user_id<>?''', (email, user['id'])).fetchone():
                    raise AuthError('该邮箱正在验证中，请稍后重试。', 409, 'email_reserved')
                recent = db.execute('SELECT count(*) FROM email_bindings WHERE user_id=? AND created_at>?',
                                    (user['id'], now - 3600)).fetchone()[0]
                if recent >= 5:
                    raise AuthError('邮件请求过于频繁，请一小时后重试。', 429, 'mail_rate_limited')
                self._require_identity(db, user, password, consume_proof)
                action_token = secrets.token_urlsafe(32)
                db.execute('UPDATE email_bindings SET used=1 WHERE user_id=?', (user['id'],))
                db.execute('INSERT INTO email_bindings VALUES(?,?,?,?,?,?,0)',
                           (hashlib.sha256(action_token.encode()).hexdigest(), user['id'], session_hash, email, now, now + 1800))
                return {'email': email, 'token': action_token}
        except sqlite3.IntegrityError:
            raise AuthError('该邮箱正在验证中，请稍后重试。', 409, 'email_reserved') from None

    def confirm_email_binding(self, token, action_token):
        if not isinstance(action_token, str) or not 1 <= len(action_token) <= 512:
            raise AuthError('验证链接无效。', 400, 'invalid_email_binding')
        with self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            user, session_hash = self._session_user(db, token)
            action = db.execute('''SELECT * FROM email_bindings WHERE token_hash=? AND used=0
                AND expires_at>?''', (hashlib.sha256(action_token.encode()).hexdigest(), int(time.time()))).fetchone()
            if action is None:
                raise AuthError('验证链接已过期或已使用。', 400, 'action_expired')
            if action['user_id'] != user['id'] or action['session_hash'] != session_hash:
                raise AuthError('请在发起邮箱绑定的原账号页面完成验证。', 403, 'action_account_mismatch')
            if user['email'] is not None:
                raise AuthError('当前账号已绑定邮箱。', 409, 'email_already_bound')
            if db.execute('SELECT 1 FROM users WHERE email=? COLLATE NOCASE', (action['email'],)).fetchone():
                raise AuthError('该邮箱已属于其他账号，不能合并账号。', 409, 'email_in_use')
            db.execute('UPDATE users SET email=?,email_verified=1 WHERE id=?', (action['email'], user['id']))
            db.execute('UPDATE email_bindings SET used=1 WHERE token_hash=?', (action['token_hash'],))
            return self.public(db.execute('SELECT * FROM users WHERE id=?', (user['id'],)).fetchone())

    def authenticate(self, token):
        if not token or len(token) > 512:
            raise AuthError('请先登录账号。', 401, 'authentication_required')
        with self.connection() as db:
            row = db.execute('SELECT u.*,s.expires_at FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=? AND s.expires_at>?',
                             (hashlib.sha256(token.encode()).hexdigest(), int(time.time()))).fetchone()
            if not row:
                raise AuthError('登录已过期，请重新登录。', 401, 'session_expired')
            self._ensure_active(db, row['id'])
            return {'user': self.public(row), 'expiresAt': datetime.fromtimestamp(row['expires_at'], timezone.utc).isoformat()}

    def logout(self, token):
        with self.connection() as db:
            digest = hashlib.sha256(token.encode()).hexdigest()
            if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='push_subscriptions'").fetchone():
                db.execute('DELETE FROM push_subscriptions WHERE session_hash=?', (digest,))
            db.execute('DELETE FROM sessions WHERE token_hash=?', (digest,))

    def delete_account(self, token, password=None, *, consume_proof=None):
        with self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            user, _ = self._session_user(db, token)
            self._require_identity(db, user, password, consume_proof)
            if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='sms_auth_challenges'").fetchone():
                from sms_auth_store import SmsAuthStore
                SmsAuthStore.delete_account_data(db, user['id'])
            db.execute('DELETE FROM users WHERE id=?', (user['id'],))

    def create_email_action(self, *, kind, uid=None, email=None):
        if kind not in ('verify', 'reset'): raise AuthError('Invalid action')
        if uid is None: email = self.action_email(email)
        with self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            user = (db.execute('SELECT * FROM users WHERE id=?', (uid,)).fetchone() if uid else
                    db.execute('SELECT * FROM users WHERE email=? COLLATE NOCASE', (email,)).fetchone())
            if user is None: return None
            if user['email'] is None:
                raise AuthError('当前账号尚未绑定邮箱，请先验证并绑定邮箱。', 409, 'email_not_bound')
            recent = db.execute('SELECT count(*) FROM email_actions WHERE user_id=? AND kind=? AND expires_at>?',
                (user['id'], kind, int(time.time()) - 1800)).fetchone()[0]
            if recent >= 5: raise AuthError('邮件请求过于频繁，请一小时后重试。', 429, 'mail_rate_limited')
            token = secrets.token_urlsafe(32)
            db.execute('UPDATE email_actions SET used=1 WHERE user_id=? AND kind=?', (user['id'], kind))
            db.execute('INSERT INTO email_actions VALUES(?,?,?,?,0)',
                       (hashlib.sha256(token.encode()).hexdigest(), user['id'], kind, int(time.time()) + 1800))
            return {'email': user['email'], 'token': token}

    def limit_reset_requests(self, source):
        # This limit depends only on the source, never the submitted email.
        digest = hashlib.sha256(source.encode()).hexdigest()
        now = int(time.time())
        with self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            db.execute('DELETE FROM mail_request_limits WHERE requested_at<=?', (now - 900,))
            count = db.execute('SELECT count(*) FROM mail_request_limits WHERE source_hash=?', (digest,)).fetchone()[0]
            if count >= 30:
                raise AuthError('重置申请过于频繁，请 15 分钟后重试。', 429, 'reset_request_rate_limited')
            db.execute('INSERT INTO mail_request_limits VALUES(?,?)', (digest, now))

    @staticmethod
    def action_email(email):
        if (not isinstance(email, str) or len(email) > 254 or
                not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', email)):
            raise AuthError('请填写有效邮箱。')
        try:
            Address(addr_spec=email)  # Reject lists and header syntax masquerading as one recipient.
        except (ValueError, HeaderParseError):
            raise AuthError('请填写有效邮箱。') from None
        return email.lower()

    def active_verification_action(self, uid, token):
        """Only the authenticated owner's current, unconsumed verification action."""
        if not isinstance(token, str) or not 1 <= len(token) <= 512:
            return None
        with self.connection() as db:
            action = db.execute('''SELECT a.expires_at FROM email_actions a JOIN users u ON u.id=a.user_id
                WHERE a.user_id=? AND a.kind='verify' AND a.token_hash=? AND a.used=0
                  AND a.expires_at>? AND u.email_verified=0''',
                (uid, hashlib.sha256(token.encode()).hexdigest(), int(time.time()))).fetchone()
        return datetime.fromtimestamp(action['expires_at'], timezone.utc).isoformat() if action else None

    def confirm_email_action(self, *, token, kind, password=None, uid=None):
        if kind not in ('verify', 'reset'): raise AuthError('Invalid action')
        if not isinstance(token, str) or len(token) > 512: raise AuthError('验证链接无效。')
        if kind == 'reset': password = self.password(password)
        with self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            action = db.execute('SELECT * FROM email_actions WHERE token_hash=? AND kind=? AND used=0 AND expires_at>?',
                (hashlib.sha256(token.encode()).hexdigest(), kind, int(time.time()))).fetchone()
            if not action: raise AuthError('验证链接已过期或已使用。', 400, 'action_expired')
            if uid is not None and action['user_id'] != uid:
                raise AuthError('此验证链接属于其他账号，请切换到对应账号后重试。', 403, 'action_account_mismatch')
            if kind == 'verify':
                db.execute('UPDATE users SET email_verified=1 WHERE id=?', (action['user_id'],))
            else:
                salt, iterations = secrets.token_bytes(16), 600000
                hashed = hashlib.pbkdf2_hmac('sha256', password.encode(), salt, iterations)
                db.execute('UPDATE users SET salt=?,password_hash=?,iterations=? WHERE id=?', (salt, hashed, iterations, action['user_id']))
                db.execute('DELETE FROM sessions WHERE user_id=?', (action['user_id'],))
                if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='push_subscriptions'").fetchone():
                    db.execute('DELETE FROM push_subscriptions WHERE user_id=?', (action['user_id'],))
            db.execute('UPDATE email_actions SET used=1 WHERE token_hash=?', (action['token_hash'],))
