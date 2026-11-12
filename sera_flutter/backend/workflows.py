"""Persistent jobs, Web Push, bounded ICS preview and one-use ASR tickets."""
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import time
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo

from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool
from auth_store import AuthError, AuthStore


def b64(value): return base64.urlsafe_b64encode(value).decode().rstrip('=')


def _job_payloads_equivalent(kind, stored, incoming):
    if stored == incoming:
        return True
    if kind != 'plan' or not isinstance(stored, dict) or not isinstance(incoming, dict):
        return False
    # Historical plans omitted the then-implicit Hong Kong time zone. Compare
    # that one default in memory only; never migrate the durable request or
    # treat other time zones, reference instants, or changed goals as equal.
    return {**stored, 'timeZone': stored.get('timeZone', 'Asia/Hong_Kong')} == {
        **incoming, 'timeZone': incoming.get('timeZone', 'Asia/Hong_Kong')}


class WorkflowStore:
    def __init__(self, path):
        self.accounts = AuthStore(path)
        with self.accounts.connection() as db:
            db.executescript('''
              CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,payload TEXT NOT NULL,status TEXT NOT NULL,result TEXT,error TEXT,
                created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL,lease_until INTEGER NOT NULL DEFAULT 0,
                request_key TEXT,UNIQUE(user_id,request_key));
              CREATE TABLE IF NOT EXISTS push_subscriptions(endpoint TEXT PRIMARY KEY,
                user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,body TEXT NOT NULL,created_at INTEGER NOT NULL);
              CREATE TABLE IF NOT EXISTS push_deliveries(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                logical_key TEXT NOT NULL,payload TEXT NOT NULL,fire_at INTEGER NOT NULL,status TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,error TEXT,UNIQUE(user_id,logical_key));
              CREATE TABLE IF NOT EXISTS asr_tickets(nonce_hash TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                session_hash TEXT NOT NULL,expires_at INTEGER NOT NULL,used INTEGER NOT NULL DEFAULT 0);
              CREATE TABLE IF NOT EXISTS service_heartbeats(service TEXT PRIMARY KEY,updated_at INTEGER NOT NULL,status TEXT NOT NULL);
            ''')
            if 'session_hash' not in [row[1] for row in db.execute('PRAGMA table_info(push_subscriptions)')]:
                db.execute('ALTER TABLE push_subscriptions ADD COLUMN session_hash TEXT')

    def enqueue(self, uid, kind, payload, request_key=None):
        if request_key is not None and (not isinstance(request_key, str) or not 1 <= len(request_key) <= 128):
            raise AuthError('Invalid job idempotency key')
        with self.accounts.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            if request_key:
                row = db.execute('SELECT * FROM jobs WHERE user_id=? AND request_key=?', (uid, request_key)).fetchone()
                if row:
                    if row['kind'] != kind or not _job_payloads_equivalent(kind, json.loads(row['payload']), payload):
                        raise AuthError('此作业请求标识已用于其他内容。', 409, 'idempotency_conflict')
                    return self.job_json(row)
            count = db.execute("SELECT count(*) FROM jobs WHERE user_id=? AND status IN ('queued','pending','running')", (uid,)).fetchone()[0]
            if count >= 5: raise AuthError('待处理作业过多，请稍后重试。', 429, 'job_limit')
            jid, now = secrets.token_hex(16), int(time.time())
            db.execute('INSERT INTO jobs(id,user_id,kind,payload,status,created_at,updated_at,request_key) VALUES(?,?,?,?,?,?,?,?)',
                       (jid, uid, kind, json.dumps(payload, ensure_ascii=False), 'queued', now, now, request_key))
            return self.job_json(db.execute('SELECT * FROM jobs WHERE id=?', (jid,)).fetchone())

    @staticmethod
    def job_json(row):
        return {'id': row['id'], 'kind': row['kind'], 'status': row['status'],
            'result': json.loads(row['result']) if row['result'] else None, 'error': row['error'],
            'createdAt': row['created_at'], 'updatedAt': row['updated_at']}

    def ticket(self, uid, session_token, secret):
        nonce, expiry = secrets.token_urlsafe(24), int(time.time()) + 120
        session_hash = hashlib.sha256(session_token.encode()).hexdigest()
        payload = b64(json.dumps({'userId': uid, 'nonce': nonce, 'exp': expiry,
                                  'sessionHash': session_hash, 'sampleRate': 16000}, separators=(',', ':')).encode())
        signed = payload + '.' + b64(hmac.new(secret, payload.encode(), hashlib.sha256).digest())
        with self.accounts.connection() as db:
            db.execute('DELETE FROM asr_tickets WHERE expires_at<?', (int(time.time()),))
            db.execute('INSERT INTO asr_tickets VALUES(?,?,?,?,0)',
                (hashlib.sha256(nonce.encode()).hexdigest(), uid, session_hash, expiry))
        return {'ticket': signed, 'expiresAt': expiry,
                'websocketUrl': os.environ.get('SERA_ASR_WS_URL', 'ws://127.0.0.1:8790/ws')}


def ensure_vapid(path):
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import serialization
    path = Path(path)
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        key = ec.generate_private_key(ec.SECP256R1())
        path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    key = serialization.load_pem_private_key(path.read_bytes(), password=None)
    public = key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    return b64(public)


def preview_ics(raw, start, end, zone='Asia/Hong_Kong'):
    from icalendar import Calendar
    from dateutil.rrule import rrulestr
    if len(raw) > 2 * 1024 * 1024: raise AuthError('ICS exceeds 2 MiB', 413)
    if end <= start or end - start > timedelta(days=366): raise AuthError('ICS range must be at most 366 days')
    calendar = Calendar.from_ical(raw)
    tz = ZoneInfo(zone)
    def aware(value):
        if isinstance(value, datetime): return value.replace(tzinfo=tz) if value.tzinfo is None else value
        return datetime.combine(value, datetime.min.time(), tzinfo=tz)
    events, warnings, identities = [], [], set()
    components = list(calendar.walk('VEVENT'))
    overrides = {}
    for component in components:
        if 'RECURRENCE-ID' in component:
            if component['RECURRENCE-ID'].params.get('RANGE'):
                raise AuthError('ICS recurrence RANGE overrides are not supported')
            key = (str(component.get('UID', '')), aware(component.decoded('RECURRENCE-ID')).isoformat())
            if key in overrides: raise AuthError('Duplicate ICS recurrence override')
            overrides[key] = component
    for component in components:
        if len(events) > 2000: raise AuthError('ICS expansion exceeds 2000 occurrences')
        uid = str(component.get('UID', ''))
        if not uid or 'DTSTART' not in component: warnings.append('Skipped event without UID/DTSTART'); continue
        if str(component.get('STATUS', '')).upper() == 'CANCELLED': continue
        base = aware(component.decoded('DTSTART'))
        finish = aware(component.decoded('DTEND')) if 'DTEND' in component else base + (component.decoded('DURATION') if 'DURATION' in component else (timedelta(0) if isinstance(component.decoded('DTSTART'), datetime) else timedelta(days=1)))
        duration = finish - base
        if duration <= timedelta(0): warnings.append(f'Skipped invalid duration: {uid}'); continue
        occurrences = [base]
        if 'RRULE' in component and 'RECURRENCE-ID' not in component:
            raw_rule = component['RRULE'].to_ical().decode()
            if not any('FREQ=' + frequency in raw_rule for frequency in ('DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY')) or any(
                    field in raw_rule for field in ('BYSECOND=', 'BYMINUTE=', 'BYHOUR=')):
                raise AuthError('Sub-daily ICS expansion is not supported')
            rule = rrulestr(raw_rule, dtstart=base)
            occurrences = []
            for occurrence in rule.xafter(start - duration, count=2002, inc=True):
                if occurrence > end: break
                occurrences.append(occurrence)
            if len(occurrences) > 2000: raise AuthError('ICS expansion exceeds 2000 occurrences')
        exclusions = set()
        for value in component.get('EXDATE', []) if isinstance(component.get('EXDATE'), list) else [component.get('EXDATE')]:
            if value: exclusions.update(aware(item.dt) for item in value.dts)
        rdates = component.get('RDATE', [])
        for value in rdates if isinstance(rdates, list) else [rdates]:
            if value: occurrences.extend(aware(item.dt) for item in value.dts)
        for occurrence in occurrences:
            if occurrence in exclusions or occurrence >= end or occurrence + duration <= start: continue
            recurrence = aware(component.decoded('RECURRENCE-ID')) if 'RECURRENCE-ID' in component else occurrence
            key = (uid, recurrence.isoformat())
            if 'RECURRENCE-ID' not in component and key in overrides: continue
            if key in identities: continue
            identities.add(key)
            events.append({'id': 'ics-' + hashlib.sha256('|'.join(key).encode()).hexdigest()[:24],
                'title': str(component.get('SUMMARY', '日历事项')), 'start': occurrence.isoformat(),
                'end': (occurrence + duration).isoformat(), 'source': 'ics', 'externalId': uid,
                'allDay': not isinstance(component.decoded('DTSTART'), datetime), 'timeZone': zone, 'locked': True})
            if len(events) > 2000: raise AuthError('ICS expansion exceeds 2000 occurrences')
    return {'entries': events, 'warnings': warnings, 'fingerprint': hashlib.sha256(raw).hexdigest()}


def attach_workflows(app):
    store = WorkflowStore(app.state.db_path)
    app.state.workflows = store
    vapid_path = app.state.db_path.with_suffix('.vapid.pem')
    public_key = ensure_vapid(vapid_path)
    app.state.vapid_path = vapid_path

    @app.post('/api/v1/jobs')
    @app.post('/api/v1/jobs/planning')
    async def enqueue_job(request: Request):
        uid = app.state.require(request)['user']['id']
        body = await request.json()
        kind = body.get('kind', 'plan')
        if kind not in ('plan', 'understand'): raise AuthError('Unsupported job kind')
        from ai_service import validate_goal_request, validate_understanding_request
        validator = validate_goal_request if kind == 'plan' else validate_understanding_request
        payload = validator(body.get('input', body))
        job = store.enqueue(uid, kind, payload, request.headers.get('idempotency-key') or body.get('requestId'))
        return JSONResponse({'job': job}, status_code=202)

    @app.get('/api/v1/jobs/{job_id}')
    async def job_status(job_id: str, request: Request):
        uid = app.state.require(request)['user']['id']
        with store.accounts.connection() as db:
            row = db.execute('SELECT * FROM jobs WHERE id=? AND user_id=?', (job_id, uid)).fetchone()
        if row is None: raise AuthError('Job not found', 404)
        return {'job': store.job_json(row)}

    @app.post('/api/v1/jobs/{job_id}/cancel')
    async def cancel_job(job_id: str, request: Request):
        uid = app.state.require(request)['user']['id']
        with store.accounts.connection() as db:
            db.execute("UPDATE jobs SET status='canceled',updated_at=? WHERE id=? AND user_id=? AND status IN ('queued','pending','running')",
                       (int(time.time()), job_id, uid))
            row = db.execute('SELECT * FROM jobs WHERE id=? AND user_id=?', (job_id, uid)).fetchone()
        if row is None: raise AuthError('Job not found', 404)
        return {'job': store.job_json(row)}

    @app.get('/api/push/public-key')
    @app.get('/api/v1/push/config')
    async def push_config(): return {'publicKey': public_key, 'enabled': True}

    @app.post('/api/push/subscriptions')
    @app.post('/api/v1/push/subscriptions')
    async def subscribe(request: Request):
        uid = app.state.require(request)['user']['id']
        body = await request.json()
        endpoint = body.get('endpoint', '')
        if not isinstance(endpoint, str) or len(endpoint) > 4096: raise AuthError('Invalid push endpoint')
        parsed = urlsplit(endpoint)
        trusted = ('fcm.googleapis.com', 'updates.push.services.mozilla.com', 'web.push.apple.com', 'notify.windows.com')
        if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.port not in (None, 443) or not any(parsed.hostname == host or parsed.hostname.endswith('.' + host) for host in trusted):
            raise AuthError('Unsupported push endpoint host')
        keys = body.get('keys', {})
        if not isinstance(keys, dict): raise AuthError('Invalid push subscription keys')
        try:
            from cryptography.hazmat.primitives.asymmetric import ec
            decoded = {}
            for name in ('p256dh', 'auth'):
                raw = keys.get(name)
                if not isinstance(raw, str) or not 8 <= len(raw) <= 256: raise ValueError()
                decoded[name] = base64.b64decode(raw + '=' * (-len(raw) % 4), altchars=b'-_', validate=True)
            if len(decoded['auth']) != 16 or len(decoded['p256dh']) != 65 or decoded['p256dh'][0] != 4: raise ValueError()
            ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), decoded['p256dh'])
        except (ValueError, TypeError): raise AuthError('Invalid push subscription keys') from None
        with store.accounts.connection() as db:
            db.execute('INSERT INTO push_subscriptions(endpoint,user_id,body,created_at,session_hash) VALUES(?,?,?,?,?) ON CONFLICT(endpoint) DO UPDATE SET user_id=excluded.user_id,body=excluded.body,session_hash=excluded.session_hash',
                (endpoint, uid, json.dumps(body), int(time.time()), hashlib.sha256(app.state.token(request).encode()).hexdigest()))
        return {'subscribed': True, 'scope': uid}

    @app.delete('/api/push/subscriptions')
    @app.delete('/api/v1/push/subscriptions')
    async def unsubscribe(request: Request):
        uid = app.state.require(request)['user']['id']
        body = await request.json()
        with store.accounts.connection() as db:
            db.execute('DELETE FROM push_subscriptions WHERE user_id=? AND endpoint=?', (uid, body.get('endpoint')))
        return {'unsubscribed': True}

    @app.post('/api/push/test')
    @app.post('/api/v1/push/test')
    async def push_test(request: Request):
        uid = app.state.require(request)['user']['id']
        with store.accounts.connection() as db:
            if not db.execute('SELECT 1 FROM push_subscriptions WHERE user_id=?', (uid,)).fetchone():
                raise AuthError('请先开启并注册浏览器后台提醒。', 409, 'push_subscription_required')
        now, pid = int(time.time() * 1000), secrets.token_hex(12)
        payload = {'id': pid, 'kind': 'test', 'title': 'SERA 测试提醒', 'body': '后台推送服务测试', 'route': '/27',
            'scope': uid, 'generation': 0, 'fireAt': now, 'expiresAt': now + 60000, 'quietStart': 0, 'quietEnd': 0}
        with store.accounts.connection() as db:
            db.execute('INSERT INTO push_deliveries(id,user_id,logical_key,payload,fire_at,status) VALUES(?,?,?,?,?,?)',
                (pid, uid, pid, json.dumps(payload), now, 'pending'))
        return JSONResponse({'queued': True, 'id': pid}, status_code=202)

    @app.get('/api/push/validate')
    @app.get('/api/v1/push/validate')
    async def validate_push(request: Request):
        uid = app.state.require(request)['user']['id']
        with store.accounts.connection() as db:
            row = db.execute('SELECT * FROM push_deliveries WHERE id=? AND user_id=?', (request.query_params.get('id'), uid)).fetchone()
        payload = json.loads(row['payload']) if row else {}
        workspace = app.state.sync.load(uid)
        valid = bool(row and payload.get('expiresAt', 0) > time.time() * 1000 and
            row['status'] not in ('cancelled', 'failed') and
            str(payload.get('generation')) == request.query_params.get('generation') and
            ((payload.get('generation') == 0 and payload.get('kind') == 'test') or
             (payload.get('generation') != 0 and workspace and workspace['revision'] == payload['generation'])))
        return {'valid': valid, 'scope': uid}

    @app.post('/api/v1/calendar/ics/preview')
    async def ics_preview(request: Request):
        app.state.require(request)
        body = await request.json()
        raw = body.get('content', '').encode('utf-8')
        start, end = datetime.fromisoformat(body['start']), datetime.fromisoformat(body['end'])
        tz = ZoneInfo(body.get('timeZone', 'Asia/Hong_Kong'))
        if start.tzinfo is None: start = start.replace(tzinfo=tz)
        if end.tzinfo is None: end = end.replace(tzinfo=tz)
        return await run_in_threadpool(preview_ics, raw, start, end, str(tz))

    @app.post('/api/v1/asr/tickets')
    async def asr_ticket(request: Request):
        session = app.state.require(request)
        body = await request.json()
        if body.get('sampleRate', 16000) != 16000: raise AuthError('Streaming ASR requires 16 kHz PCM')
        return store.ticket(session['user']['id'], app.state.token(request), app.state.secret)
