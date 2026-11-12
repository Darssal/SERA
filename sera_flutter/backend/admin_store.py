"""Permission-bound desktop administration of shared community data only.

It deliberately never opens personal workspace payloads or exposes identity
credentials. Session checks, moderation, idempotency and audit share transactions.
"""
import base64
from datetime import datetime, timezone
import hashlib
import json
import re
import secrets
import time

from auth_store import AuthError
from community_store import identifier, page_limit, _created_at, _public_name


def _invalid(message):
    raise AuthError(message, 400, 'invalid_admin_request')


def _text(value, label, maximum=200, minimum=0):
    if not isinstance(value, str) or len(value) > maximum or re.search(r'[\x00-\x1f\x7f]', value):
        _invalid(f'{label}需为 {minimum} 至 {maximum} 字。')
    try:
        value.encode('utf-8')
    except UnicodeError:
        _invalid(f'{label}包含无效字符。')
    value = value.strip()
    if len(value) < minimum:
        _invalid(f'{label}需为 {minimum} 至 {maximum} 字。')
    return value


def _like(value):
    return '%' + value.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_') + '%'


def _scope(kind, filters):
    return kind + ':' + hashlib.sha256(json.dumps(filters, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def _cursor(scope, position):
    return base64.urlsafe_b64encode(json.dumps({'v': 1, 'scope': scope, 'position': position},
        separators=(',', ':')).encode()).decode().rstrip('=')


def _position(value, scope, *, user=False):
    if value in (None, ''):
        return None
    if not isinstance(value, str) or not 1 <= len(value) <= 512 or not re.fullmatch(r'[A-Za-z0-9_-]+', value):
        _invalid('分页位置无效，请重新载入列表。')
    try:
        parsed = json.loads(base64.b64decode(value + '=' * (-len(value) % 4), altchars=b'-_', validate=True))
        if (not isinstance(parsed, dict) or set(parsed) != {'v', 'scope', 'position'}
                or type(parsed['v']) is not int or parsed['v'] != 1 or parsed['scope'] != scope):
            raise ValueError()
        result = parsed['position']
        if user:
            if (not isinstance(result, list) or len(result) != 2 or type(result[0]) is not int
                    or not 0 <= result[0] <= 2**63 - 1 or not isinstance(result[1], str)
                    or not re.fullmatch(r'[A-Za-z0-9._:-]{1,128}', result[1])):
                raise ValueError()
        elif type(result) is not int or not 1 <= result <= 2**63 - 1:
            raise ValueError()
        return result
    except (ValueError, TypeError, UnicodeError):
        _invalid('分页位置无效，请重新载入列表。')


def _choice(value, choices, label):
    if value not in choices:
        _invalid(f'{label}无效。')
    return value


class AdminStore:
    def __init__(self, community):
        self.community = community
        self.accounts = community.accounts
        with self.accounts.connection() as db:
            db.executescript('''
                BEGIN IMMEDIATE;
                CREATE TABLE IF NOT EXISTS admin_audit (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    actor_id TEXT REFERENCES users(id) ON DELETE SET NULL,
                    actor_name TEXT NOT NULL, action TEXT NOT NULL,
                    target_type TEXT NOT NULL, target_id TEXT NOT NULL,
                    target_label TEXT NOT NULL, reason TEXT NOT NULL,
                    created_at INTEGER NOT NULL);
                CREATE INDEX IF NOT EXISTS admin_audit_actor ON admin_audit(actor_id,sequence);
                CREATE TABLE IF NOT EXISTS admin_operations (
                    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    request_id TEXT NOT NULL, operation TEXT NOT NULL,
                    payload_hash TEXT NOT NULL,
                    PRIMARY KEY(user_id,request_id));
            ''')
        community.audit_handler = self.record_audit

    @staticmethod
    def record_audit(db, uid, action, target_type, target_id, label, reason=''):
        actor = db.execute('SELECT username FROM users WHERE id=?', (uid,)).fetchone()
        db.execute('''INSERT INTO admin_audit
            (id,actor_id,actor_name,action,target_type,target_id,target_label,reason,created_at)
            VALUES(?,?,?,?,?,?,?,?,?)''',
            (secrets.token_hex(16), uid, _public_name(actor['username']) if actor else '已注销账号',
             action, target_type, target_id, label[:160], reason[:500], time.time_ns() // 1000))

    def _access(self, db, uid, token, *, owner=False, permission=None):
        self.community._actor(db, uid, token)
        viewer = self.community._viewer(db, uid)
        if not viewer['isOfficial'] and not viewer['isAdmin']:
            raise AuthError('此账号没有后台管理权限。', 403, 'admin_required')
        if owner and not viewer['isOfficial']:
            raise AuthError('只有官方账号可以使用此管理功能。', 403, 'admin_owner_required')
        if permission and not viewer['permissions'][permission]:
            raise AuthError('当前账号没有执行此操作的权限。', 403, 'admin_permission_required')
        return viewer

    def _author_search(self, db):
        # Search the same public name that the DTO shows, never an email-shaped
        # legacy login identifier hidden by the community identity boundary.
        db.create_function('admin_author_name', 2, lambda uid, name:
            'SERA 官方' if uid is None or uid in self.community.official_user_ids else _public_name(name),
            deterministic=True)

    def bootstrap(self, uid, token):
        with self.accounts.connection() as db:
            db.execute('BEGIN')
            viewer = self._access(db, uid, token)
            counts = {
                'posts': db.execute('SELECT count(*) FROM community_posts').fetchone()[0],
                'comments': db.execute('SELECT count(*) FROM community_comments').fetchone()[0],
                'feedback': db.execute("SELECT count(*) FROM community_posts WHERE category='feedback'").fetchone()[0],
                'activities': db.execute("SELECT count(*) FROM community_posts WHERE kind='activity'").fetchone()[0],
                'pendingApplications': None, 'users': None, 'admins': None,
            }
            if viewer['isOfficial']:
                counts.update({
                    'pendingApplications': db.execute("SELECT count(*) FROM community_admin_applications WHERE status='pending'").fetchone()[0],
                    'users': db.execute('SELECT count(*) FROM users').fetchone()[0],
                    'admins': db.execute('SELECT count(*) FROM community_admins').fetchone()[0],
                })
            return {'viewer': viewer, 'counts': counts}

    def posts(self, uid, token, *, q='', category='all', kind='all', official='all', cursor=None, limit=None):
        q = _text(q, '查询内容')
        _choice(category, ('all', 'daily', 'feedback'), '分类')
        _choice(kind, ('all', 'post', 'activity'), '内容类型')
        official = {'true': 'yes', 'false': 'all'}.get(official, official)
        _choice(official, ('all', 'yes'), '官方身份筛选')
        limit = page_limit(limit, default=30)
        scope = _scope('admin-posts', [q, category, kind, official])
        position = _position(cursor, scope)
        conditions, args = ['1=1'], []
        if q:
            conditions.append("(p.title LIKE ? ESCAPE '\\' OR p.content LIKE ? ESCAPE '\\' "
                              "OR admin_author_name(p.author_id,u.username) LIKE ? ESCAPE '\\' OR p.id=?)")
            args.extend([_like(q), _like(q), _like(q), q])
        for field, value in (('category', category), ('kind', kind)):
            if value != 'all':
                conditions.append(f'p.{field}=?')
                args.append(value)
        if official == 'yes':
            conditions.append('p.is_official=1')
        with self.accounts.connection() as db:
            db.execute('BEGIN')
            viewer = self._access(db, uid, token)
            self._author_search(db)
            total = db.execute('SELECT count(*) FROM community_posts p LEFT JOIN users u ON u.id=p.author_id WHERE '
                               + ' AND '.join(conditions), args).fetchone()[0]
            if position is not None:
                conditions.append('p.sequence<?')
                args.append(position)
            rows = self.community._post_rows(db, uid, ' AND '.join(conditions), args,
                                            order=' ORDER BY p.sequence DESC', limit=limit + 1)
            return {'posts': [self.community._post_json(row, uid, viewer) for row in rows[:limit]],
                    'total': total, 'nextCursor': _cursor(scope, rows[limit - 1]['sequence']) if len(rows) > limit else None}

    def comments(self, uid, token, *, q='', post_id='', cursor=None, limit=None):
        q = _text(q, '查询内容')
        if post_id:
            identifier(post_id, '动态标识')
        limit = page_limit(limit, default=30)
        scope = _scope('admin-comments', [q, post_id])
        position = _position(cursor, scope)
        conditions, args = ['1=1'], []
        if q:
            conditions.append("(c.content LIKE ? ESCAPE '\\' OR admin_author_name(c.author_id,u.username) LIKE ? ESCAPE '\\' OR c.id=?)")
            args.extend([_like(q), _like(q), q])
        if post_id:
            conditions.append('c.post_id=?')
            args.append(post_id)
        with self.accounts.connection() as db:
            db.execute('BEGIN')
            viewer = self._access(db, uid, token, permission='moderateComments')
            self._author_search(db)
            total = db.execute('SELECT count(*) FROM community_comments c JOIN users u ON u.id=c.author_id WHERE '
                               + ' AND '.join(conditions), args).fetchone()[0]
            if position is not None:
                conditions.append('c.sequence<?')
                args.append(position)
            rows = db.execute('''SELECT c.*,u.username,p.title AS post_title,
                EXISTS(SELECT 1 FROM community_admins a WHERE a.user_id=c.author_id) AS author_is_admin
                FROM community_comments c JOIN users u ON u.id=c.author_id
                JOIN community_posts p ON p.id=c.post_id WHERE ''' + ' AND '.join(conditions)
                + ' ORDER BY c.sequence DESC LIMIT ?', [*args, limit + 1]).fetchall()
            return {'comments': [{**self.community._comment_json(row, uid, viewer), 'postTitle': row['post_title']}
                                 for row in rows[:limit]],
                    'total': total, 'nextCursor': _cursor(scope, rows[limit - 1]['sequence']) if len(rows) > limit else None}

    @staticmethod
    def _user_json(row):
        email = row['email']
        if email:
            local, _, domain = email.partition('@')
            email = local[:1] + '***@' + domain
        phone = row['phone']
        if phone:
            phone = phone[:-8] + '****' + phone[-4:]
        return {'id': row['id'], 'username': _public_name(row['username']),
                'emailMasked': email, 'phoneMasked': phone, 'emailVerified': bool(row['email_verified']),
                'createdAt': datetime.fromtimestamp(row['created_at'], timezone.utc).isoformat(),
                'disabled': bool(row['disabled']), 'postCount': row['post_count'], 'commentCount': row['comment_count']}

    def users(self, uid, token, *, q='', status='all', cursor=None, limit=None):
        q = _text(q, '查询内容')
        _choice(status, ('all', 'active', 'disabled'), '账号状态')
        limit = page_limit(limit, default=30)
        scope = _scope('admin-users', [q, status])
        position = _position(cursor, scope, user=True)
        conditions, args = ['1=1'], []
        if q:
            conditions.append("(u.username LIKE ? ESCAPE '\\' OR u.email=? COLLATE NOCASE OR u.phone=? OR u.id=?)")
            args.extend([_like(q), q, q, q])
        if status != 'all':
            conditions.append('COALESCE(s.disabled,0)=?')
            args.append(int(status == 'disabled'))
        join = ' FROM users u LEFT JOIN auth_account_status s ON s.user_id=u.id WHERE '
        with self.accounts.connection() as db:
            db.execute('BEGIN')
            self._access(db, uid, token, owner=True)
            total = db.execute('SELECT count(*)' + join + ' AND '.join(conditions), args).fetchone()[0]
            if position:
                conditions.append('(u.created_at<? OR (u.created_at=? AND u.id<?))')
                args.extend([position[0], position[0], position[1]])
            rows = db.execute('''SELECT u.id,u.username,u.email,u.phone,u.email_verified,u.created_at,
                COALESCE(s.disabled,0) AS disabled,
                (SELECT count(*) FROM community_posts p WHERE p.author_id=u.id) AS post_count,
                (SELECT count(*) FROM community_comments c WHERE c.author_id=u.id) AS comment_count'''
                + join + ' AND '.join(conditions) + ' ORDER BY u.created_at DESC,u.id DESC LIMIT ?', [*args, limit + 1]).fetchall()
            return {'users': [self._user_json(row) for row in rows[:limit]], 'total': total,
                    'nextCursor': _cursor(scope, [rows[limit - 1]['created_at'], rows[limit - 1]['id']]) if len(rows) > limit else None}

    @staticmethod
    def _mutation(body, allowed):
        if not isinstance(body, dict) or set(body) != allowed:
            _invalid('请完整填写操作信息，不要添加其他字段。')
        return identifier(body.get('requestId'), '提交标识'), _text(body.get('reason'), '操作原因', 500, 1)

    @staticmethod
    def _operation(db, uid, request_id, operation, payload):
        digest = hashlib.sha256(json.dumps(payload, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
        previous = db.execute('SELECT operation,payload_hash FROM admin_operations WHERE user_id=? AND request_id=?',
                              (uid, request_id)).fetchone()
        if previous:
            if previous['operation'] != operation or previous['payload_hash'] != digest:
                raise AuthError('提交标识已用于其他操作，请重新提交。', 409, 'idempotency_conflict')
            return True
        db.execute('INSERT INTO admin_operations VALUES(?,?,?,?)', (uid, request_id, operation, digest))
        return False

    def set_user_status(self, target_id, uid, token, body):
        identifier(target_id, '账号标识')
        request_id, reason = self._mutation(body, {'requestId', 'reason', 'disabled'})
        if type(body['disabled']) is not bool:
            _invalid('请明确选择启用或停用账号。')
        disabled = body['disabled']
        with self.accounts.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            self._access(db, uid, token, owner=True)
            if target_id == uid or target_id in self.community.official_user_ids:
                raise AuthError('不能在后台停用或修改官方账号。', 403, 'admin_account_protected')
            target = db.execute('SELECT username FROM users WHERE id=?', (target_id,)).fetchone()
            if target is None:
                raise AuthError('这个账号已不存在。', 404, 'admin_user_not_found')
            if self._operation(db, uid, request_id, 'user-status', {'id': target_id, 'disabled': disabled, 'reason': reason}):
                return {'updated': True}
            previous = db.execute('SELECT disabled FROM auth_account_status WHERE user_id=?', (target_id,)).fetchone()
            if bool(previous and previous['disabled']) != disabled:
                db.execute('''INSERT INTO auth_account_status VALUES(?,?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET
                    disabled=excluded.disabled,reason=excluded.reason,updated_at=excluded.updated_at,updated_by=excluded.updated_by''',
                    (target_id, int(disabled), reason, int(time.time()), uid))
                if disabled:
                    self.accounts._revoke_other_sessions(db, target_id)
                    for table in ('asr_tickets',):
                        if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone():
                            db.execute(f'DELETE FROM {table} WHERE user_id=?', (target_id,))
                    if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='jobs'").fetchone():
                        db.execute("UPDATE jobs SET status='canceled',updated_at=? WHERE user_id=? AND status IN ('queued','pending','running')",
                                   (int(time.time()), target_id))
                    if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='push_deliveries'").fetchone():
                        db.execute("UPDATE push_deliveries SET status='cancelled' WHERE user_id=? AND status IN ('pending','no_subscription')", (target_id,))
                self.record_audit(db, uid, 'disable_user' if disabled else 'enable_user', 'user', target_id,
                                  _public_name(target['username']), reason)
            return {'updated': True}

    def delete(self, item_id, uid, token, body, *, comment=False):
        identifier(item_id)
        request_id, reason = self._mutation(body, {'requestId', 'reason'})
        permission = 'moderateComments' if comment else 'moderatePosts'
        table = 'community_comments' if comment else 'community_posts'
        with self.accounts.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            self._access(db, uid, token, permission=permission)
            if not self._operation(db, uid, request_id, 'delete-comment' if comment else 'delete-post', {'id': item_id, 'reason': reason}):
                self.community._delete_in_transaction(db, item_id, uid, table, reason=reason)
            return {'deleted': True}

    def audit(self, uid, token, *, q='', cursor=None, limit=None):
        q = _text(q, '查询内容')
        limit = page_limit(limit, default=30)
        scope = _scope('admin-audit', [q])
        position = _position(cursor, scope)
        conditions, args = ['1=1'], []
        if q:
            conditions.append("(actor_name LIKE ? ESCAPE '\\' OR target_label LIKE ? ESCAPE '\\' OR action=? OR target_id=?)")
            args.extend([_like(q), _like(q), q, q])
        with self.accounts.connection() as db:
            db.execute('BEGIN')
            self._access(db, uid, token, owner=True)
            total = db.execute('SELECT count(*) FROM admin_audit WHERE ' + ' AND '.join(conditions), args).fetchone()[0]
            if position is not None:
                conditions.append('sequence<?')
                args.append(position)
            rows = db.execute('SELECT * FROM admin_audit WHERE ' + ' AND '.join(conditions) + ' ORDER BY sequence DESC LIMIT ?',
                              [*args, limit + 1]).fetchall()
            return {'entries': [{'id': row['id'], 'actorName': row['actor_name'], 'action': row['action'],
                'targetType': row['target_type'], 'targetId': row['target_id'], 'targetLabel': row['target_label'],
                'reason': row['reason'], 'createdAt': _created_at(row['created_at'])} for row in rows[:limit]],
                'total': total, 'nextCursor': _cursor(scope, rows[limit - 1]['sequence']) if len(rows) > limit else None}

    def status(self, uid, token, *, ai, mail):
        with self.accounts.connection() as db:
            db.execute('BEGIN')
            self._access(db, uid, token, owner=True)
            db.execute('SELECT 1').fetchone()
            heartbeat = db.execute("SELECT updated_at,status FROM service_heartbeats WHERE service='worker'").fetchone()
        def component(key, name, configured, healthy, detail, **extra):
            return {'id': key, 'name': name, 'configured': configured, 'healthy': healthy,
                    'status': 'not_configured' if not configured else 'configured' if healthy is None else 'healthy' if healthy else 'unavailable',
                    'detail': detail, **extra}
        worker_ok = bool(heartbeat and 0 <= int(time.time()) - heartbeat['updated_at'] < 150 and heartbeat['status'] == 'ok')
        mail_configured = True
        try:
            mail.check_configuration()
        except AuthError:
            mail_configured = False
        ai_configured = bool(getattr(ai, 'configured', False))
        # The existing app has a default local ASR endpoint. Configuration here
        # deliberately does not claim the model is loaded or the endpoint live.
        return {'components': [
            component('database', '数据库', True, True, '数据库可读取。'),
            component('worker', '后台作业', True, worker_ok,
                      '最近心跳正常。' if worker_ok else '尚未收到有效心跳，或作业服务需要检查。',
                      lastHeartbeatAt=datetime.fromtimestamp(heartbeat['updated_at'], timezone.utc).isoformat() if heartbeat else None),
            component('ai', '在线 AI', ai_configured, None, '已配置；本页不调用付费模型，尚未检查外部连通性。' if ai_configured else '尚未配置在线模型。'),
            component('mail', '验证邮件', mail_configured, None,
                      '本地开发邮件，不向外部邮箱投递。' if mail.mode == 'local' else '仅检查邮件配置，实际送达需发送验证邮件。'),
            component('asr', '语音识别', True, None, '应用已配置本地识别入口；本页不连接或加载识别模型。'),
            component('push', '提醒推送', True, worker_ok, '由后台作业执行；本页不向用户发送测试通知。'),
        ]}

    def analytics(self, uid, token, *, days=30):
        from admin_analytics import aggregate
        with self.accounts.connection() as db:
            db.execute('BEGIN')
            viewer = self._access(db, uid, token, owner=True)
            result, ranked = aggregate(db, days)
            by_id = {}
            if ranked:
                ids = [row['id'] for row in ranked]
                placeholders = ','.join('?' for _ in ids)
                rows = self.community._post_rows(db, uid, 'p.id IN (' + placeholders + ')', ids)
                by_id = {row['id']: self.community._post_json(row, uid, viewer) for row in rows}
            result['topPosts'] = [{'post': by_id[row['id']], 'interactions': row['interactions']} for row in ranked]
            return result
