"""Shared community records, separate from every personal workspace.

All counters are derived from real rows. Writes and idempotency claims share a
SQLite transaction; account deletion cascades through user-owned content and
interactions without leaving a public copy of the account's identity.
"""
import base64
from datetime import datetime, timedelta, timezone
import hashlib
from io import BytesIO
import json
import re
import secrets
import time

from PIL import Image, ImageOps, UnidentifiedImageError

from auth_store import AuthError, AuthStore


_IDENTIFIER = re.compile(r'[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\Z')
_CONTROL = re.compile(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]')
_POST_FIELDS = {'requestId', 'title', 'content', 'kind', 'category', 'official', 'startsAt', 'place', 'mediaIds'}
MEDIA_MAX_BYTES = 8 * 1024 * 1024
_MEDIA_MAX_PIXELS = 16_000_000
_MEDIA_PENDING_US = 24 * 60 * 60 * 1_000_000
_MEDIA_FORMATS = {'image/jpeg': 'JPEG', 'image/png': 'PNG', 'image/webp': 'WEBP'}
_WELCOME_ID = 'official-welcome-v1'
_DEMO_ID = 'official-seven-day-focus-demo-v1'
_PERMISSIONS = {
    'publishOfficial': 'publish_official',
    'publishActivity': 'publish_activity',
    'moderatePosts': 'moderate_posts',
    'moderateComments': 'moderate_comments',
}


def _permission_input(value):
    if not isinstance(value, dict) or set(value) != set(_PERMISSIONS) or any(type(flag) is not bool for flag in value.values()):
        _invalid('请明确设置管理员的四项权限。')
    return {key: value[key] for key in _PERMISSIONS}


def _invalid(message):
    raise AuthError(message, 400, 'invalid_community_request')


def identifier(value, label='内容标识'):
    if not isinstance(value, str) or not _IDENTIFIER.fullmatch(value):
        _invalid(f'{label}无效。')
    return value


def page_limit(value, *, default=20, maximum=100):
    if value is None:
        return default
    if isinstance(value, str) and re.fullmatch(r'[0-9]{1,3}', value):
        value = int(value)
    if type(value) is not int or not 1 <= value <= maximum:
        _invalid(f'每次读取数量需为 1 至 {maximum}。')
    return value


def _text(value, label, maximum, *, minimum=0, multiline=False):
    if not isinstance(value, str) or len(value) > maximum or _CONTROL.search(value):
        _invalid(f'{label}需为 {minimum} 至 {maximum} 字。')
    try:
        value.encode('utf-8')
    except UnicodeError:
        _invalid(f'{label}包含无效字符。')
    value = value.strip()
    if len(value) < minimum or (not multiline and ('\n' in value or '\r' in value or '\t' in value)):
        _invalid(f'{label}需为 {minimum} 至 {maximum} 字。')
    return value


def _object(body, allowed):
    if not isinstance(body, dict) or set(body) - allowed:
        _invalid('请求中包含无法识别的字段。')


def _utc(value):
    if not isinstance(value, str) or len(value) > 64 or 'T' not in value:
        _invalid('请选择包含时区的活动开始时间。')
    try:
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
        if parsed.tzinfo is None or parsed.utcoffset() is None:
            raise ValueError()
        return parsed.astimezone(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')
    except (ValueError, OverflowError):
        _invalid('请选择包含时区的活动开始时间。')


def _created_at(value):
    return datetime.fromtimestamp(value / 1_000_000, timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')


def _cursor(scope, sequence):
    raw = json.dumps({'v': 1, 'scope': scope, 'sequence': sequence}, separators=(',', ':')).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip('=')


def _read_cursor(value, scope):
    if value is None or value == '':
        return None
    if not isinstance(value, str) or not 1 <= len(value) <= 512 or not re.fullmatch(r'[A-Za-z0-9_-]+', value):
        _invalid('分页位置无效，请重新载入列表。')
    try:
        raw = base64.b64decode(value + '=' * (-len(value) % 4), altchars=b'-_', validate=True)
        parsed = json.loads(raw)
        if (not isinstance(parsed, dict) or set(parsed) != {'v', 'scope', 'sequence'}
                or type(parsed['v']) is not int or parsed['v'] != 1 or parsed['scope'] != scope
                or type(parsed['sequence']) is not int or not 1 <= parsed['sequence'] <= 2**63 - 1):
            raise ValueError()
        return parsed['sequence']
    except (ValueError, TypeError, UnicodeError):
        _invalid('分页位置无效，请重新载入列表。')


def _public_name(name):
    # Do not turn a legacy email/phone-shaped login name into a public identity.
    if not name or '@' in name or re.search(r'(?<![0-9])(?:\+?86[- ]?)?1[3-9][0-9]{9}(?![0-9])', name):
        return '社区用户'
    return name


def _image_bytes(raw, mime_type):
    if mime_type not in _MEDIA_FORMATS:
        raise AuthError('请选择 JPEG、PNG 或 WebP 图片。', 415, 'community_media_type')
    if not isinstance(raw, bytes) or not raw:
        _invalid('请选择有效的图片。')
    if len(raw) > MEDIA_MAX_BYTES:
        raise AuthError('每张图片不能超过 8 MiB。', 413, 'community_media_too_large')
    try:
        # Check dimensions before decoding. Pillow's own bomb guard remains on;
        # our lower per-upload bound does not mutate its global process setting.
        with Image.open(BytesIO(raw), formats=list(_MEDIA_FORMATS.values())) as source:
            if source.format != _MEDIA_FORMATS[mime_type]:
                raise AuthError('图片内容与格式不一致，请重新选择。', 415, 'community_media_type')
            if source.width * source.height > _MEDIA_MAX_PIXELS:
                raise AuthError('图片像素过大，请缩小到 1600 万像素以内。', 413, 'community_media_pixels')
            if getattr(source, 'n_frames', 1) != 1:
                _invalid('暂不支持动图，请选择静态图片。')
            source.verify()
        with Image.open(BytesIO(raw), formats=list(_MEDIA_FORMATS.values())) as source:
            oriented = ImageOps.exif_transpose(source)
            try:
                mode = 'RGBA' if 'A' in oriented.getbands() or 'transparency' in oriented.info else 'RGB'
                with oriented.convert(mode) as converted:
                    converted.thumbnail((1600, 1600), Image.Resampling.LANCZOS)
                    # A fresh pixel-only image prevents EXIF/GPS/XMP/ICC/text
                    # metadata from being copied into the public image.
                    with Image.new(mode, converted.size) as clean:
                        clean.paste(converted)
                        output = BytesIO()
                        if mode == 'RGBA':
                            clean.save(output, 'PNG', compress_level=6)
                            output_mime = 'image/png'
                        else:
                            clean.save(output, 'JPEG', quality=88, optimize=True)
                            output_mime = 'image/jpeg'
                        return output.getvalue(), output_mime, clean.width, clean.height
            finally:
                oriented.close()
    except Image.DecompressionBombError:
        raise AuthError('图片像素过大，请缩小到 1600 万像素以内。', 413, 'community_media_pixels') from None
    except (UnidentifiedImageError, OSError, ValueError, SyntaxError):
        raise AuthError('图片无法读取，请重新选择有效图片。', 400, 'invalid_community_media') from None


class CommunityStore:
    def __init__(self, accounts, *, official_user_ids=()):
        self.accounts = accounts
        self.official_user_ids = frozenset(official_user_ids)
        self.audit_handler = None
        with accounts.connection() as db:
            db.executescript('''
                BEGIN IMMEDIATE;
                CREATE TABLE IF NOT EXISTS community_schema_migrations(
                    version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS community_meta(
                    key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS community_posts(
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    author_id TEXT REFERENCES users(id) ON DELETE CASCADE,
                    is_official INTEGER NOT NULL CHECK(is_official IN (0,1)),
                    kind TEXT NOT NULL CHECK(kind IN ('post','activity')),
                    title TEXT NOT NULL, content TEXT NOT NULL,
                    created_at INTEGER NOT NULL, starts_at TEXT, place TEXT NOT NULL DEFAULT '',
                    CHECK(author_id IS NOT NULL OR is_official=1),
                    CHECK(kind!='activity' OR (is_official=1 AND starts_at IS NOT NULL)),
                    CHECK(kind!='post' OR (starts_at IS NULL AND place='')));
                CREATE INDEX IF NOT EXISTS community_posts_official
                    ON community_posts(is_official,sequence);
                CREATE INDEX IF NOT EXISTS community_posts_author ON community_posts(author_id);
                CREATE TABLE IF NOT EXISTS community_comments(
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    post_id TEXT NOT NULL REFERENCES community_posts(id) ON DELETE CASCADE,
                    author_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    is_official INTEGER NOT NULL CHECK(is_official IN (0,1)),
                    content TEXT NOT NULL, created_at INTEGER NOT NULL);
                CREATE INDEX IF NOT EXISTS community_comments_post ON community_comments(post_id,sequence);
                CREATE INDEX IF NOT EXISTS community_comments_author ON community_comments(author_id);
                CREATE TABLE IF NOT EXISTS community_likes(
                    post_id TEXT NOT NULL REFERENCES community_posts(id) ON DELETE CASCADE,
                    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    PRIMARY KEY(post_id,user_id));
                CREATE INDEX IF NOT EXISTS community_likes_user ON community_likes(user_id);
                CREATE TABLE IF NOT EXISTS community_participants(
                    post_id TEXT NOT NULL REFERENCES community_posts(id) ON DELETE CASCADE,
                    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    PRIMARY KEY(post_id,user_id));
                CREATE INDEX IF NOT EXISTS community_participants_user ON community_participants(user_id);
                CREATE TABLE IF NOT EXISTS community_requests(
                    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    request_id TEXT NOT NULL, operation TEXT NOT NULL,
                    payload_hash TEXT NOT NULL, result_id TEXT NOT NULL,
                    PRIMARY KEY(user_id,request_id));
                CREATE TABLE IF NOT EXISTS community_admins(
                    user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
                    publish_official INTEGER NOT NULL CHECK(publish_official IN (0,1)),
                    publish_activity INTEGER NOT NULL CHECK(publish_activity IN (0,1)),
                    moderate_posts INTEGER NOT NULL CHECK(moderate_posts IN (0,1)),
                    moderate_comments INTEGER NOT NULL CHECK(moderate_comments IN (0,1)),
                    updated_at INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS community_admin_applications(
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    reason TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('pending','approved','rejected')),
                    created_at INTEGER NOT NULL, reviewed_at INTEGER, review_permissions TEXT);
                CREATE UNIQUE INDEX IF NOT EXISTS community_application_pending
                    ON community_admin_applications(user_id) WHERE status='pending';
                CREATE INDEX IF NOT EXISTS community_application_user
                    ON community_admin_applications(user_id,sequence);
                CREATE TABLE IF NOT EXISTS community_media(
                    id TEXT PRIMARY KEY,
                    owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    post_id TEXT REFERENCES community_posts(id) ON DELETE CASCADE,
                    position INTEGER CHECK(position IS NULL OR position BETWEEN 0 AND 2),
                    mime_type TEXT NOT NULL CHECK(mime_type IN ('image/jpeg','image/png')),
                    width INTEGER NOT NULL CHECK(width>0 AND width<=1600),
                    height INTEGER NOT NULL CHECK(height>0 AND height<=1600),
                    byte_count INTEGER NOT NULL CHECK(byte_count>0),
                    data BLOB NOT NULL,created_at INTEGER NOT NULL,
                    CHECK((post_id IS NULL AND position IS NULL) OR (post_id IS NOT NULL AND position IS NOT NULL)),
                    UNIQUE(post_id,position));
                CREATE INDEX IF NOT EXISTS community_media_owner ON community_media(owner_id);
                CREATE INDEX IF NOT EXISTS community_media_pending ON community_media(created_at) WHERE post_id IS NULL;
            ''')
            if 'category' not in {row['name'] for row in db.execute('PRAGMA table_info(community_posts)')}:
                db.execute("""ALTER TABLE community_posts ADD COLUMN category TEXT NOT NULL
                    DEFAULT 'daily' CHECK(category IN ('daily','feedback'))""")
            db.execute('''CREATE INDEX IF NOT EXISTS community_posts_category
                ON community_posts(category,sequence)''')
            if not db.execute("SELECT 1 FROM community_meta WHERE key='seed-v1'").fetchone():
                now = time.time_ns() // 1000
                starts = (datetime.now(timezone.utc) + timedelta(days=1)).isoformat(timespec='seconds').replace('+00:00', 'Z')
                db.execute('''INSERT OR IGNORE INTO community_posts
                    (id,author_id,is_official,kind,title,content,created_at) VALUES(?,NULL,1,'post',?,?,?)''',
                    (_WELCOME_ID, '欢迎来到 SERA 社区',
                     '在这里记录日常进展，分享自己的做事方法，也可以参加官方活动。'
                     '发布的内容会在社区公开，个人任务和日程不会自动分享。', now))
                db.execute('''INSERT OR IGNORE INTO community_posts
                    (id,author_id,is_official,kind,title,content,created_at,starts_at,place)
                    VALUES(?,NULL,1,'activity',?,?,?,?,?)''',
                    (_DEMO_ID, '7 天专注练习 · 课设演示活动',
                     '这是课程项目的演示活动，可自愿报名。在接下来的 7 天，每天选择一件想完成的事，'
                     '专注一段时间后，在评论里记录自己的进展。报名不会自动创建个人任务或发送提醒。'
                     '你可以随时取消报名。', now + 1, starts, '线上 · SERA 社区'))
                db.execute("INSERT INTO community_meta VALUES('seed-v1','created')")
            db.execute('INSERT OR IGNORE INTO community_schema_migrations VALUES(1,?)', (int(time.time()),))
            db.execute('INSERT OR IGNORE INTO community_schema_migrations VALUES(2,?)', (int(time.time()),))
            db.execute('INSERT OR IGNORE INTO community_schema_migrations VALUES(3,?)', (int(time.time()),))
            db.execute('INSERT OR IGNORE INTO community_schema_migrations VALUES(4,?)', (int(time.time()),))

    def viewer(self, uid):
        with self.accounts.connection() as db:
            return self._viewer(db, uid)

    def _audit(self, db, uid, action, target_type, target_id, label, reason=''):
        if self.audit_handler is not None:
            self.audit_handler(db, uid, action, target_type, target_id, label, reason)

    def _viewer(self, db, uid):
        owner = uid is not None and uid in self.official_user_ids
        admin = db.execute('SELECT * FROM community_admins WHERE user_id=?', (uid,)).fetchone() if uid else None
        permissions = {key: owner or bool(admin and admin[column]) for key, column in _PERMISSIONS.items()}
        return {'signedIn': uid is not None, 'isOfficial': owner, 'isAdmin': admin is not None and not owner,
                'canManageAdmins': owner, 'permissions': permissions,
                'canPublishOfficial': permissions['publishOfficial'] or permissions['publishActivity']}

    @staticmethod
    def _actor(db, uid, token):
        if not isinstance(token, str) or not token or len(token) > 512:
            raise AuthError('请先登录账号。', 401, 'authentication_required')
        actor = db.execute('''SELECT u.id,u.username FROM users u JOIN sessions s ON s.user_id=u.id
            WHERE u.id=? AND s.token_hash=? AND s.expires_at>?''',
            (uid, hashlib.sha256(token.encode()).hexdigest(), int(time.time()))).fetchone()
        if actor is None:
            raise AuthError('登录已过期，请重新登录。', 401, 'session_expired')
        AuthStore._ensure_active(db, uid)
        return actor

    @staticmethod
    def _can_delete(uid, author_id, viewer, permission):
        return uid is not None and (uid == author_id or viewer['permissions'][permission])

    def _post_rows(self, db, uid, condition, arguments=(), *, order='', limit=None):
        # Conditions/table names here are private constants, never client SQL.
        sql = '''SELECT p.*,u.username,
            EXISTS(SELECT 1 FROM community_admins a WHERE a.user_id=p.author_id) AS author_is_admin,
            (SELECT count(*) FROM community_likes l WHERE l.post_id=p.id) AS like_count,
            (SELECT count(*) FROM community_comments c WHERE c.post_id=p.id) AS comment_count,
            (SELECT count(*) FROM community_participants j WHERE j.post_id=p.id) AS participant_count,
            EXISTS(SELECT 1 FROM community_likes l WHERE l.post_id=p.id AND l.user_id=?) AS liked,
            EXISTS(SELECT 1 FROM community_participants j WHERE j.post_id=p.id AND j.user_id=?) AS joined
            FROM community_posts p LEFT JOIN users u ON u.id=p.author_id WHERE ''' + condition + order
        args = [uid, uid, *arguments]
        if limit is not None:
            sql += ' LIMIT ?'
            args.append(limit)
        rows = [dict(row) for row in db.execute(sql, args)]
        if rows:
            by_post = {row['id']: [] for row in rows}
            # Fetch metadata once per page; never load image blobs into a feed.
            placeholders = ','.join('?' for _ in by_post)
            for media in db.execute('''SELECT id,post_id,width,height,mime_type,byte_count FROM community_media
                WHERE post_id IN (''' + placeholders + ') ORDER BY position', list(by_post)):
                by_post[media['post_id']].append(self._media_json(media))
            for row in rows:
                row['media'] = by_post[row['id']]
        return rows

    def _post_json(self, row, uid, viewer):
        author_is_official = row['author_id'] is None or row['author_id'] in self.official_user_ids
        return {
            'id': row['id'], 'authorId': row['author_id'],
            'authorName': 'SERA 官方' if author_is_official else _public_name(row['username']),
            'authorIsOfficial': author_is_official,
            'isOfficial': bool(row['is_official']), 'kind': row['kind'], 'category': row['category'],
            'isAdmin': bool(row['author_is_admin']) and row['author_id'] not in self.official_user_ids,
            'title': row['title'], 'content': row['content'],
            'createdAt': _created_at(row['created_at']), 'startsAt': row['starts_at'],
            'place': row['place'], 'likeCount': row['like_count'],
            'commentCount': row['comment_count'], 'participantCount': row['participant_count'],
            'liked': bool(row['liked']), 'joined': bool(row['joined']),
            'canDelete': self._can_delete(uid, row['author_id'], viewer, 'moderatePosts'),
            'media': row['media'],
        }

    def _post(self, db, post_id, uid, viewer=None):
        rows = self._post_rows(db, uid, 'p.id=?', (post_id,))
        if not rows:
            raise AuthError('这条动态已不存在。', 404, 'community_post_not_found')
        return self._post_json(rows[0], uid, viewer or self._viewer(db, uid))

    def _comment_rows(self, db, condition, arguments=(), *, limit=None):
        sql = '''SELECT c.*,u.username,
            EXISTS(SELECT 1 FROM community_admins a WHERE a.user_id=c.author_id) AS author_is_admin
            FROM community_comments c
            JOIN users u ON u.id=c.author_id WHERE ''' + condition + ' ORDER BY c.sequence ASC'
        if limit is not None:
            return db.execute(sql + ' LIMIT ?', (*arguments, limit)).fetchall()
        return db.execute(sql, arguments).fetchall()

    def _comment_json(self, row, uid, viewer):
        author_is_official = row['author_id'] in self.official_user_ids
        return {
            'id': row['id'], 'postId': row['post_id'], 'authorId': row['author_id'],
            'authorName': 'SERA 官方' if author_is_official else _public_name(row['username']),
            'authorIsOfficial': author_is_official,
            'isOfficial': bool(row['is_official']), 'content': row['content'],
            'isAdmin': bool(row['author_is_admin']) and row['author_id'] not in self.official_user_ids,
            'createdAt': _created_at(row['created_at']),
            'canDelete': self._can_delete(uid, row['author_id'], viewer, 'moderateComments'),
        }

    def list_posts(self, uid=None, *, filter='all', cursor=None, limit=20):
        if filter not in ('all', 'official', 'feedback'):
            _invalid('请选择全部动态、使用反馈或官方动态。')
        limit = page_limit(limit)
        position = _read_cursor(cursor, 'posts:' + filter)
        conditions, args = ['1=1'], []
        if filter == 'official':
            conditions.append('p.is_official=1')
        elif filter == 'feedback':
            conditions.append("p.kind='post' AND p.category='feedback'")
        if position is not None:
            conditions.append('p.sequence<?')
            args.append(position)
        with self.accounts.connection() as db:
            db.execute('BEGIN')
            viewer = self._viewer(db, uid)
            rows = self._post_rows(db, uid, ' AND '.join(conditions), args,
                                   order=' ORDER BY p.sequence DESC', limit=limit + 1)
            return {
                'posts': [self._post_json(row, uid, viewer) for row in rows[:limit]],
                'nextCursor': _cursor('posts:' + filter, rows[limit - 1]['sequence']) if len(rows) > limit else None,
                'viewer': viewer,
            }

    def detail(self, post_id, uid=None, *, comment_cursor=None, comment_limit=50):
        identifier(post_id)
        limit = page_limit(comment_limit, default=50)
        position = _read_cursor(comment_cursor, 'comments:' + post_id)
        with self.accounts.connection() as db:
            db.execute('BEGIN')
            viewer = self._viewer(db, uid)
            post = self._post(db, post_id, uid, viewer)
            rows = self._comment_rows(db, 'c.post_id=? AND c.sequence>?',
                                      (post_id, position or 0), limit=limit + 1)
            return {
                'post': post, 'comments': [self._comment_json(row, uid, viewer) for row in rows[:limit]],
                'commentsNextCursor': _cursor('comments:' + post_id, rows[limit - 1]['sequence']) if len(rows) > limit else None,
                'viewer': viewer,
            }

    @staticmethod
    def _request(db, uid, request_id, operation, payload):
        digest = hashlib.sha256(json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()
        previous = db.execute('SELECT * FROM community_requests WHERE user_id=? AND request_id=?',
                              (uid, request_id)).fetchone()
        accepted_digests = {digest}
        if operation == 'post' and payload.get('mediaIds') == []:
            # Version 3 posts carried category but no media. Version 2 carried
            # neither. Never accept an old digest for a newly attached image.
            legacy_payload = {key: value for key, value in payload.items() if key != 'mediaIds'}
            accepted_digests.add(hashlib.sha256(json.dumps(legacy_payload, sort_keys=True,
                ensure_ascii=False, separators=(',', ':')).encode()).hexdigest())
            if payload.get('category') == 'daily':
                legacy_payload.pop('category')
                accepted_digests.add(hashlib.sha256(json.dumps(legacy_payload, sort_keys=True,
                    ensure_ascii=False, separators=(',', ':')).encode()).hexdigest())
        if previous and (previous['operation'] != operation or previous['payload_hash'] not in accepted_digests):
            raise AuthError('这次提交标识已用于其他内容，请重新提交。', 409, 'idempotency_conflict')
        return previous, digest

    @staticmethod
    def _claim(db, uid, request_id, operation, digest, result_id):
        db.execute('INSERT INTO community_requests VALUES(?,?,?,?,?)', (uid, request_id, operation, digest, result_id))

    @staticmethod
    def _deleted():
        raise AuthError('这次提交的内容已删除，不会再次发布。', 410, 'community_content_deleted')

    def create_post(self, uid, token, body):
        _object(body, _POST_FIELDS)
        request_id = identifier(body.get('requestId'), '提交标识')
        kind, official = body.get('kind', 'post'), body.get('official', False)
        if kind not in ('post', 'activity') or type(official) is not bool:
            _invalid('动态类型或发布身份无效。')
        category = body.get('category', 'daily')
        if category not in ('daily', 'feedback') or (kind == 'activity' and category != 'daily'):
            _invalid('请选择日常动态或使用反馈；活动不能归为使用反馈。')
        media_ids = body.get('mediaIds', [])
        if not isinstance(media_ids, list) or len(media_ids) > 3:
            _invalid('每条动态最多添加 3 张图片。')
        media_ids = [identifier(value, '图片标识') for value in media_ids]
        if len(set(media_ids)) != len(media_ids):
            _invalid('同一张图片不能重复添加。')
        title = _text(body.get('title', ''), '标题', 120, minimum=1 if kind == 'activity' else 0)
        content = _text(body.get('content'), '正文', 5000, minimum=1, multiline=True)
        place = _text(body.get('place', ''), '地点', 120)
        starts_at = _utc(body.get('startsAt')) if kind == 'activity' else None
        if kind == 'post' and (body.get('startsAt') is not None or place):
            _invalid('动态不能设置活动时间或地点。')
        payload = {'title': title, 'content': content, 'kind': kind, 'category': category,
                   'official': official, 'startsAt': starts_at, 'place': place, 'mediaIds': media_ids}
        with self.accounts.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            self._actor(db, uid, token)
            previous, digest = self._request(db, uid, request_id, 'post', payload)
            if previous:
                if not db.execute('SELECT 1 FROM community_posts WHERE id=?', (previous['result_id'],)).fetchone():
                    self._deleted()
                return {'post': self._post(db, previous['result_id'], uid)}
            permissions = self._viewer(db, uid)['permissions']
            if ((kind == 'activity' and not permissions['publishActivity']) or
                    (kind == 'post' and official and not permissions['publishOfficial'])):
                raise AuthError('当前账号没有发布这类官方内容的权限。', 403, 'community_official_required')
            if kind == 'activity' and not official:
                _invalid('活动需以官方身份发布。')
            expired_media_ids = []
            for media_id in media_ids:
                media = db.execute('SELECT owner_id,post_id,created_at FROM community_media WHERE id=?', (media_id,)).fetchone()
                if media is None or (media['post_id'] is None and media['created_at'] <= time.time_ns() // 1000 - _MEDIA_PENDING_US):
                    expired_media_ids.append(media_id)
                    continue
                if media['owner_id'] != uid:
                    raise AuthError('只能发布自己上传的图片。', 403, 'community_media_forbidden')
                if media['post_id'] is not None:
                    raise AuthError('图片已用于另一条动态，请重新上传。', 409, 'community_media_attached')
            if expired_media_ids:
                error = AuthError('部分图片已过期或已删除，请重新上传。', 410, 'community_media_expired')
                error.media_ids = expired_media_ids
                raise error
            post_id = secrets.token_hex(16)
            db.execute('''INSERT INTO community_posts
                (id,author_id,is_official,kind,category,title,content,created_at,starts_at,place)
                VALUES(?,?,?,?,?,?,?,?,?,?)''',
                (post_id, uid, int(official), kind, category, title, content, time.time_ns() // 1000, starts_at, place))
            for position, media_id in enumerate(media_ids):
                db.execute('UPDATE community_media SET post_id=?,position=? WHERE id=?', (post_id, position, media_id))
            self._claim(db, uid, request_id, 'post', digest, post_id)
            if official:
                self._audit(db, uid, 'publish_activity' if kind == 'activity' else 'publish_official',
                            'post', post_id, title or content[:120])
            return {'post': self._post(db, post_id, uid)}

    @staticmethod
    def _media_json(row):
        return {'id': row['id'], 'url': '/api/v1/community/media/' + row['id'],
                'width': row['width'], 'height': row['height'],
                'mimeType': row['mime_type'], 'bytes': row['byte_count']}

    def upload_media(self, uid, token, request_id, raw, mime_type):
        request_id = identifier(request_id, '提交标识')
        if not isinstance(raw, bytes) or len(raw) > MEDIA_MAX_BYTES:
            raise AuthError('每张图片不能超过 8 MiB。', 413, 'community_media_too_large')
        payload = {'sha256': hashlib.sha256(raw).hexdigest(), 'mimeType': mime_type}
        with self.accounts.connection() as db:
            db.execute('BEGIN')
            self._actor(db, uid, token)
            previous, _ = self._request(db, uid, request_id, 'media', payload)
            if previous:
                return {'media': self._uploaded_media(db, previous['result_id'])}
        # Decode outside the SQLite write lock, then recheck the account and
        # idempotency claim atomically before saving or returning a racing upload.
        data, output_mime, width, height = _image_bytes(raw, mime_type)
        with self.accounts.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            self._actor(db, uid, token)
            db.execute('DELETE FROM community_media WHERE post_id IS NULL AND created_at<=?',
                       (time.time_ns() // 1000 - _MEDIA_PENDING_US,))
            previous, digest = self._request(db, uid, request_id, 'media', payload)
            if previous:
                return {'media': self._uploaded_media(db, previous['result_id'])}
            media_id = secrets.token_hex(16)
            db.execute('''INSERT INTO community_media(id,owner_id,mime_type,width,height,byte_count,data,created_at)
                VALUES(?,?,?,?,?,?,?,?)''', (media_id, uid, output_mime, width, height, len(data), data, time.time_ns() // 1000))
            self._claim(db, uid, request_id, 'media', digest, media_id)
            return {'media': self._uploaded_media(db, media_id)}

    def _uploaded_media(self, db, media_id):
        row = db.execute('''SELECT id,post_id,width,height,mime_type,byte_count,created_at
            FROM community_media WHERE id=?''', (media_id,)).fetchone()
        if row is None or (row['post_id'] is None and row['created_at'] <= time.time_ns() // 1000 - _MEDIA_PENDING_US):
            raise AuthError('图片已过期或已删除，请重新上传。', 410, 'community_media_expired')
        return self._media_json(row)

    def read_media(self, media_id, uid=None, token=''):
        identifier(media_id, '图片标识')
        with self.accounts.connection() as db:
            db.execute('BEGIN')
            row = db.execute('SELECT * FROM community_media WHERE id=?', (media_id,)).fetchone()
            if row is None or (row['post_id'] is None and
                    (row['owner_id'] != uid or row['created_at'] <= time.time_ns() // 1000 - _MEDIA_PENDING_US)):
                raise AuthError('图片不存在或已过期。', 404, 'community_media_not_found')
            if row['post_id'] is None:
                self._actor(db, uid, token)
            return row['data'], row['mime_type']

    def create_comment(self, post_id, uid, token, body):
        identifier(post_id)
        _object(body, {'requestId', 'content'})
        request_id = identifier(body.get('requestId'), '提交标识')
        content = _text(body.get('content'), '评论', 1000, minimum=1, multiline=True)
        with self.accounts.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            self._actor(db, uid, token)
            viewer = self._viewer(db, uid)
            previous, digest = self._request(db, uid, request_id, 'comment', {'postId': post_id, 'content': content})
            if previous:
                rows = self._comment_rows(db, 'c.id=?', (previous['result_id'],))
                if not rows:
                    self._deleted()
                return {'comment': self._comment_json(rows[0], uid, viewer), 'post': self._post(db, post_id, uid, viewer)}
            self._post(db, post_id, uid)
            comment_id = secrets.token_hex(16)
            db.execute('''INSERT INTO community_comments(id,post_id,author_id,is_official,content,created_at)
                VALUES(?,?,?,?,?,?)''', (comment_id, post_id, uid, int(uid in self.official_user_ids), content, time.time_ns() // 1000))
            self._claim(db, uid, request_id, 'comment', digest, comment_id)
            comment = self._comment_rows(db, 'c.id=?', (comment_id,))[0]
            return {'comment': self._comment_json(comment, uid, viewer), 'post': self._post(db, post_id, uid, viewer)}

    def set_like(self, post_id, uid, token, body):
        return self._set_membership(post_id, uid, token, body, 'liked')

    def set_join(self, post_id, uid, token, body):
        return self._set_membership(post_id, uid, token, body, 'joined')

    def _set_membership(self, post_id, uid, token, body, field):
        identifier(post_id)
        _object(body, {field})
        if type(body.get(field)) is not bool:
            _invalid('请选择明确的操作状态。')
        table = 'community_likes' if field == 'liked' else 'community_participants'
        with self.accounts.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            self._actor(db, uid, token)
            post = self._post(db, post_id, uid)
            if field == 'joined' and post['kind'] != 'activity':
                raise AuthError('只有活动可以报名。', 400, 'community_activity_required')
            if body[field]:
                db.execute(f'INSERT OR IGNORE INTO {table}(post_id,user_id) VALUES(?,?)', (post_id, uid))
            else:
                db.execute(f'DELETE FROM {table} WHERE post_id=? AND user_id=?', (post_id, uid))
            return {'post': self._post(db, post_id, uid)}

    def delete_post(self, post_id, uid, token):
        return self._delete(post_id, uid, token, 'community_posts')

    def delete_comment(self, comment_id, uid, token):
        return self._delete(comment_id, uid, token, 'community_comments')

    def _delete(self, item_id, uid, token, table):
        identifier(item_id)
        with self.accounts.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            self._actor(db, uid, token)
            self._delete_in_transaction(db, item_id, uid, table)
            return {'deleted': True}

    def _delete_in_transaction(self, db, item_id, uid, table, *, reason=''):
        # Shared by the app and desktop administration: deletion, cascades and
        # its audit entry must commit or roll back together.
        if table not in ('community_posts', 'community_comments'):
            raise ValueError('Unsupported community deletion table')
        row = db.execute(f'SELECT * FROM {table} WHERE id=?', (item_id,)).fetchone()
        if row is not None:
            permission = 'moderatePosts' if table == 'community_posts' else 'moderateComments'
            if not self._can_delete(uid, row['author_id'], self._viewer(db, uid), permission):
                raise AuthError('只能删除自己发布的内容。', 403, 'community_delete_forbidden')
            label = (row['title'] or row['content']) if table == 'community_posts' else row['content']
            db.execute(f'DELETE FROM {table} WHERE id=?', (item_id,))
            self._audit(db, uid, 'delete_post' if table == 'community_posts' else 'delete_comment',
                        'post' if table == 'community_posts' else 'comment', item_id, label[:120], reason)

    def _owner(self, db, uid, token):
        self._actor(db, uid, token)
        if uid not in self.official_user_ids:
            raise AuthError('只有官方账号可以管理管理员。', 403, 'community_owner_required')

    def _admin_target(self, db, target_id):
        identifier(target_id, '账号标识')
        if target_id in self.official_user_ids:
            raise AuthError('官方账号的权限不能在社区中修改。', 403, 'community_owner_protected')
        if not db.execute('SELECT 1 FROM users WHERE id=?', (target_id,)).fetchone():
            raise AuthError('这个账号已不存在。', 404, 'community_user_not_found')

    @staticmethod
    def _grant(db, target_id, permissions):
        db.execute('''INSERT INTO community_admins
            (user_id,publish_official,publish_activity,moderate_posts,moderate_comments,updated_at)
            VALUES(?,?,?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET
              publish_official=excluded.publish_official,publish_activity=excluded.publish_activity,
              moderate_posts=excluded.moderate_posts,moderate_comments=excluded.moderate_comments,
              updated_at=excluded.updated_at''',
            (target_id, *(int(permissions[key]) for key in _PERMISSIONS), time.time_ns() // 1000))

    @staticmethod
    def _application_json(row):
        return {'id': row['id'], 'userId': row['user_id'], 'username': _public_name(row['username']),
                'reason': row['reason'], 'status': row['status'], 'createdAt': _created_at(row['created_at'])}

    @staticmethod
    def _application_rows(db, condition, arguments=()):
        return db.execute('''SELECT a.*,u.username FROM community_admin_applications a
            JOIN users u ON u.id=a.user_id WHERE ''' + condition + ' ORDER BY a.sequence DESC', arguments).fetchall()

    def management(self, uid, token):
        with self.accounts.connection() as db:
            db.execute('BEGIN')
            self._actor(db, uid, token)
            viewer = self._viewer(db, uid)
            own = self._application_rows(db, 'a.user_id=?', (uid,))
            result = {'viewer': viewer, 'admins': [], 'applications': [],
                      'myApplication': self._application_json(own[0]) if own else None}
            if viewer['canManageAdmins']:
                rows = db.execute('''SELECT a.*,u.username FROM community_admins a
                    JOIN users u ON u.id=a.user_id ORDER BY u.username COLLATE NOCASE,a.user_id''').fetchall()
                result['admins'] = [
                    {'userId': row['user_id'], 'username': _public_name(row['username']),
                     'permissions': {key: bool(row[column]) for key, column in _PERMISSIONS.items()}}
                    for row in rows if row['user_id'] not in self.official_user_ids]
                result['applications'] = [self._application_json(row) for row in self._application_rows(db, '1=1')]
            return result

    def apply_admin(self, uid, token, body):
        _object(body, {'requestId', 'reason'})
        request_id = identifier(body.get('requestId'), '提交标识')
        reason = _text(body.get('reason'), '申请说明', 500, minimum=1, multiline=True)
        with self.accounts.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            self._actor(db, uid, token)
            previous, digest = self._request(db, uid, request_id, 'application', {'reason': reason})
            if previous:
                rows = self._application_rows(db, 'a.id=?', (previous['result_id'],))
                if not rows:
                    self._deleted()
                return {'application': self._application_json(rows[0])}
            viewer = self._viewer(db, uid)
            if viewer['isOfficial'] or viewer['isAdmin']:
                raise AuthError('当前账号已经具有社区管理身份。', 409, 'community_already_admin')
            pending = self._application_rows(db, "a.user_id=? AND a.status='pending'", (uid,))
            if pending:
                self._claim(db, uid, request_id, 'application', digest, pending[0]['id'])
                return {'application': self._application_json(pending[0])}
            application_id = secrets.token_hex(16)
            db.execute('''INSERT INTO community_admin_applications(id,user_id,reason,status,created_at)
                VALUES(?,?,?,'pending',?)''', (application_id, uid, reason, time.time_ns() // 1000))
            self._claim(db, uid, request_id, 'application', digest, application_id)
            return {'application': self._application_json(self._application_rows(db, 'a.id=?', (application_id,))[0])}

    def add_admin(self, uid, token, body):
        _object(body, {'identifier', 'permissions'})
        target = _text(body.get('identifier'), '准确用户名或邮箱', 254, minimum=1)
        permissions = _permission_input(body.get('permissions'))
        with self.accounts.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            self._owner(db, uid, token)
            users = db.execute('SELECT id FROM users WHERE username=? COLLATE NOCASE OR email=? COLLATE NOCASE',
                               (target, target)).fetchall()
            if len(users) != 1:
                raise AuthError('未找到这个准确用户名或邮箱。', 404, 'community_user_not_found')
            self._admin_target(db, users[0]['id'])
            self._grant(db, users[0]['id'], permissions)
            self._approve_pending(db, users[0]['id'], permissions)
            self._audit(db, uid, 'grant_admin', 'user', users[0]['id'], self._target_label(db, users[0]['id']),
                        self._permission_summary(permissions))
            return {'updated': True}

    def update_admin(self, target_id, uid, token, body):
        _object(body, {'permissions'})
        permissions = _permission_input(body.get('permissions'))
        with self.accounts.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            self._owner(db, uid, token)
            self._admin_target(db, target_id)
            self._grant(db, target_id, permissions)
            self._approve_pending(db, target_id, permissions)
            self._audit(db, uid, 'update_admin', 'user', target_id, self._target_label(db, target_id),
                        self._permission_summary(permissions))
            return {'updated': True}

    @staticmethod
    def _target_label(db, uid):
        row = db.execute('SELECT username FROM users WHERE id=?', (uid,)).fetchone()
        return _public_name(row['username']) if row else '已注销账号'

    @staticmethod
    def _permission_summary(permissions):
        names = {'publishOfficial': '官方动态', 'publishActivity': '官方活动',
                 'moderatePosts': '管理帖子', 'moderateComments': '管理评论'}
        enabled = [names[key] for key, allowed in permissions.items() if allowed]
        return '授予：' + ('、'.join(enabled) if enabled else '无操作权限')

    @staticmethod
    def _approve_pending(db, target_id, permissions):
        db.execute('''UPDATE community_admin_applications SET status='approved',reviewed_at=?,review_permissions=?
            WHERE user_id=? AND status='pending' ''',
            (time.time_ns() // 1000, json.dumps(permissions, sort_keys=True), target_id))

    def remove_admin(self, target_id, uid, token):
        with self.accounts.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            self._owner(db, uid, token)
            self._admin_target(db, target_id)
            changed = db.execute('DELETE FROM community_admins WHERE user_id=?', (target_id,)).rowcount
            if changed:
                self._audit(db, uid, 'remove_admin', 'user', target_id, self._target_label(db, target_id))
            return {'updated': True}

    def review_application(self, application_id, uid, token, body):
        identifier(application_id, '申请标识')
        _object(body, {'status', 'permissions'})
        status = body.get('status')
        if status not in ('approved', 'rejected'):
            _invalid('请选择通过或拒绝申请。')
        permissions = _permission_input(body.get('permissions')) if status == 'approved' else None
        if status == 'rejected' and 'permissions' in body:
            _invalid('拒绝申请时不应授予管理员权限。')
        with self.accounts.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            self._owner(db, uid, token)
            rows = self._application_rows(db, 'a.id=?', (application_id,))
            if not rows:
                raise AuthError('这条申请或申请账号已不存在。', 404, 'community_application_not_found')
            row = rows[0]
            if row['status'] != 'pending':
                saved = json.loads(row['review_permissions']) if row['review_permissions'] else None
                if row['status'] != status or saved != permissions:
                    raise AuthError('这条申请已经处理，请查看最新结果。', 409, 'community_application_reviewed')
                # Retrying a completed approval must not restore permissions
                # revoked or edited later through the administrator settings.
                return {'application': self._application_json(row)}
            self._admin_target(db, row['user_id'])
            if status == 'approved':
                self._grant(db, row['user_id'], permissions)
            db.execute('''UPDATE community_admin_applications SET status=?,reviewed_at=?,review_permissions=? WHERE id=?''',
                       (status, time.time_ns() // 1000, json.dumps(permissions, sort_keys=True) if permissions is not None else None, application_id))
            self._audit(db, uid, 'approve_application' if status == 'approved' else 'reject_application',
                        'application', application_id, self._target_label(db, row['user_id']),
                        self._permission_summary(permissions) if permissions else '')
            return {'application': self._application_json(self._application_rows(db, 'a.id=?', (application_id,))[0])}
