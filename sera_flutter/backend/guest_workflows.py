"""Bounded, ephemeral device AI jobs; never an anonymous cloud workspace.

The client-held random capability authorizes only its own short-lived AI jobs.
No users, sessions, workspace rows or durable job records are created here.
Process restart/expiry loses recovery; clients keep their input locally.
"""
import asyncio
from collections import deque
from copy import deepcopy
import hashlib
import hmac
import io
import json
import logging
import os
import re
import secrets
import threading
import time

from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.requests import ClientDisconnect

from ai_service import (AiServiceError, validate_ai_tasks, validate_goal_request,
                        validate_understanding, validate_understanding_request)
from auth_store import AuthError


DEVICE_JOB_PATH = '/api/v1/device/jobs'
DEVICE_ASR_PATH = '/api/v1/device/asr/tickets'
DEVICE_UPLOAD_PATH = '/api/v1/device/ai/transcribe'
MAX_REQUEST_BYTES = 64 * 1024

# Only reviewed codes/messages cross the device boundary. Provider exception
# messages can contain private data and must never be serialized or logged.
DEVICE_AI_ERRORS = {
    'ai_empty_response': 'AI 暂未返回内容，请重试。',
    'ai_timeout': 'AI 响应超时，请稍后重试。',
    'ai_connection_error': '暂时无法连接 AI，请稍后重试。',
    'ai_provider_error': 'AI 服务暂时不可用，请稍后重试。',
    'ai_rate_limited': 'AI 请求较多，请稍后重试。',
    'ai_not_configured': 'AI 服务暂时不可用，请稍后重试。',
    'invalid_ai_output': 'AI 返回内容暂时无法使用，请重试。',
    'invalid_ai_request': '这次 AI 输入暂时无法处理，请调整后重试。',
    'ai_tool_limit': 'AI 查询暂未完成，请稍后重试。',
    'ai_processing_error': 'AI 暂时未能完成，请稍后重试。',
}
_logger = logging.getLogger(__name__)


def _safe_ai_failure(error):
    code = error.code if isinstance(error, AiServiceError) else None
    if type(code) is not str or code not in DEVICE_AI_ERRORS:
        code = 'ai_processing_error'
    return code, DEVICE_AI_ERRORS[code]


def _log_device_job(kind, code, stage, elapsed_seconds):
    # No job/device/request identity, exception repr, input or output. These
    # fields are server-owned enums and a duration, not provider text.
    _logger.warning('device_ai kind=%s code=%s stage=%s elapsed_ms=%d',
                    kind, code, stage, max(0, round(elapsed_seconds * 1000)))


def is_device_job_path(path):
    return path == DEVICE_JOB_PATH or path.startswith(DEVICE_JOB_PATH + '/')


def is_device_api_path(path):
    return is_device_job_path(path) or path in (DEVICE_ASR_PATH, DEVICE_UPLOAD_PATH)


def device_body_limit(path):
    if path == DEVICE_UPLOAD_PATH:
        return 11 * 1024 * 1024
    if path == DEVICE_JOB_PATH:
        return MAX_REQUEST_BYTES
    return 4096


class DeviceBodyGate:
    """Reception limits are separate from provider slots and reject, not queue."""
    def __init__(self, *, global_limit=8, ip_limit=4, timeout=10):
        self.global_limit, self.ip_limit, self.timeout = global_limit, ip_limit, timeout
        self._lock = threading.Lock()
        self._active = 0
        self._ips = {}

    def acquire(self, ip):
        with self._lock:
            if self._active >= self.global_limit or self._ips.get(ip, 0) >= self.ip_limit:
                raise AuthError('本机 AI 请求较多，请稍后再试。', 429, 'device_body_busy')
            self._active += 1
            self._ips[ip] = self._ips.get(ip, 0) + 1

    def release(self, ip):
        with self._lock:
            self._active -= 1
            count = self._ips[ip] - 1
            if count:
                self._ips[ip] = count
            else:
                self._ips.pop(ip)


async def read_device_body(request, gate):
    """Reject declared oversize before receive; bound chunked/lying clients too."""
    limit = device_body_limit(request.url.path)
    try:
        declared = int(request.headers.get('content-length', '0'))
    except ValueError:
        raise AuthError('请求长度无效。', 400, 'invalid_content_length') from None
    if declared < 0:
        raise AuthError('请求长度无效。', 400, 'invalid_content_length')
    if declared > limit:
        raise AuthError('AI 请求过长。', 413, 'device_body_too_large')
    ip = request.client.host if request.client else 'unknown'
    gate.acquire(ip)
    try:
        chunks, total = [], 0
        async with asyncio.timeout(gate.timeout):
            async for chunk in request.stream():
                total += len(chunk)
                if total > limit:
                    raise AuthError('AI 请求过长。', 413, 'device_body_too_large')
                chunks.append(chunk)
        return b''.join(chunks)
    except TimeoutError:
        raise AuthError('AI 输入接收超时，请重试。', 408, 'device_body_timeout') from None
    except ClientDisconnect:
        raise AuthError('AI 输入接收已中断，请重试。', 400, 'device_body_interrupted') from None
    finally:
        gate.release(ip)


def device_scope(value):
    if not isinstance(value, str) or re.fullmatch(r'[0-9a-f]{64}', value) is None:
        raise AuthError('本机 AI 标识无效，请刷新后重试。', 401, 'device_identity_required')
    return hashlib.sha256(value.encode('ascii')).hexdigest()


class DeviceJobStore:
    def __init__(self, planner, *, clock=time.time, ttl=900, active_timeout=120,
                 max_jobs=256, max_device_jobs=32, max_running=4,
                 max_device_running=2, max_ip_running=4,
                 device_minute_limit=15, ip_minute_limit=45,
                 device_hour_limit=120, ip_hour_limit=360):
        self.planner, self.clock = planner, clock
        self.ttl, self.active_timeout = ttl, active_timeout
        self.max_jobs, self.max_device_jobs = max_jobs, max_device_jobs
        self.max_running, self.max_device_running = max_running, max_device_running
        self.max_ip_running = max_ip_running
        self.rate_limits = {'device': (device_minute_limit, device_hour_limit),
                            'ip': (ip_minute_limit, ip_hour_limit)}
        self._jobs, self._keys, self._inflight, self._rates = {}, {}, {}, {}
        self._lock = threading.RLock()
        self._tasks = set()
        self._janitor = None
        self._closed = False

    def _prune(self, now):
        for jid, job in list(self._jobs.items()):
            if job['status'] in ('queued', 'running') and now >= job['activeUntil']:
                job.update(status='failed', error=DEVICE_AI_ERRORS['ai_timeout'],
                           errorCode='ai_timeout',
                           payload=None, result=None, updatedAt=int(now))
                _log_device_job(job['kind'], 'ai_timeout', 'expiration', now - job['createdAt'])
            if now >= job['expiresAt']:
                self._jobs.pop(jid)
                self._keys.pop((job['owner'], job['requestKey']), None)
        for key, attempts in list(self._rates.items()):
            while attempts and attempts[0] <= now - 3600:
                attempts.popleft()
            if not attempts:
                self._rates.pop(key)

    def _check_rate(self, owner, ip, now):
        keys = [('device', owner), ('ip', ip)]
        for key in keys:
            attempts = self._rates.get(key, ())
            minute, hour = self.rate_limits[key[0]]
            if len(attempts) >= hour or sum(t > now - 60 for t in attempts) >= minute:
                raise AuthError('AI 请求较多，请稍后再试。', 429, 'device_ai_rate_limited')
        if len(self._rates) + sum(key not in self._rates for key in keys) > 4096:
            raise AuthError('AI 服务繁忙，请稍后再试。', 429, 'device_ai_capacity')
        for key in keys:
            self._rates.setdefault(key, deque()).append(now)

    @staticmethod
    def _public(job):
        public = {key: job[key] for key in
                  ('id', 'kind', 'status', 'result', 'error',
                   'createdAt', 'updatedAt', 'expiresAt')}
        # Nullable and additive: older in-memory records need no migration.
        public['errorCode'] = job.get('errorCode')
        return deepcopy(public)

    def enqueue(self, owner, ip, kind, request_key, payload):
        if kind not in ('understand', 'plan'):
            raise AuthError('不支持的 AI 请求。', 400, 'invalid_ai_request')
        if (not isinstance(request_key, str) or not 1 <= len(request_key) <= 128 or
                any(ord(c) < 32 for c in request_key)):
            raise AuthError('AI 请求标识无效。', 400, 'invalid_ai_request')
        fingerprint = hashlib.sha256(json.dumps(
            [kind, payload], sort_keys=True, ensure_ascii=False,
            separators=(',', ':'), allow_nan=False).encode('utf-8')).hexdigest()
        with self._lock:
            now = self.clock()
            self._prune(now)
            if self._closed:
                raise AuthError('AI 服务正在重启，请稍后重试。', 503, 'device_ai_unavailable')
            previous = self._keys.get((owner, request_key))
            if previous:
                job = self._jobs[previous]
                if job['fingerprint'] != fingerprint:
                    raise AuthError('此请求标识已用于其他内容。', 409, 'idempotency_conflict')
                return self._public(job), False
            running = list(self._inflight.values())
            if (len(running) >= self.max_running or
                    sum(value[0] == owner for value in running) >= self.max_device_running or
                    sum(value[1] == ip for value in running) >= self.max_ip_running):
                raise AuthError('AI 正在处理其他请求，请稍后再试。', 429, 'device_ai_busy')
            if (len(self._jobs) >= self.max_jobs or
                    sum(job['owner'] == owner for job in self._jobs.values()) >= self.max_device_jobs):
                raise AuthError('本机 AI 请求缓存已满，请稍后再试。', 429, 'device_ai_capacity')
            self._check_rate(owner, ip, now)
            jid = secrets.token_hex(16)
            job = {'id': jid, 'owner': owner, 'requestKey': request_key,
                   'fingerprint': fingerprint, 'kind': kind,
                   'payload': deepcopy(payload), 'status': 'queued',
                   'result': None, 'error': None, 'errorCode': None, 'createdAt': int(now),
                   'updatedAt': int(now), 'expiresAt': int(now + self.ttl),
                   'activeUntil': now + min(self.ttl, self.active_timeout)}
            self._jobs[jid], self._keys[(owner, request_key)] = job, jid
            # Cancel/expiry cannot release a real provider call's slot early.
            self._inflight[jid] = (owner, ip)
            return self._public(job), True

    def read(self, owner, jid, *, cancel=False):
        with self._lock:
            now = self.clock()
            self._prune(now)
            job = self._jobs.get(jid)
            if job is None or job['owner'] != owner:
                raise AuthError('这次 AI 请求已过期或不存在，请使用保留的输入重试。', 404, 'device_job_not_found')
            if cancel and job['status'] in ('queued', 'running'):
                job.update(status='canceled', payload=None, result=None,
                           error=None, errorCode='ai_canceled', updatedAt=int(now))
                _log_device_job(job['kind'], 'ai_canceled', 'cancel', now - job['createdAt'])
            return self._public(job)

    def execute(self, jid):
        """Runs in a bounded background thread; canceled results never publish."""
        with self._lock:
            self._prune(self.clock())
            job = self._jobs.get(jid)
            if job is None or job['status'] != 'queued' or self._closed:
                self._inflight.pop(jid, None)
                return
            job.update(status='running', updatedAt=int(self.clock()))
            payload, kind = deepcopy(job['payload']), job['kind']
        started, stage = time.monotonic(), 'provider'
        try:
            # Deliberately never call generate_for_workspace/read an account.
            result = (self.planner.understand(payload) if kind == 'understand'
                      else self.planner.generate(payload))
            stage = 'validation'
            if (not isinstance(result, dict) or result.get('source') != 'siliconflow' or
                    not isinstance(result.get('model'), str) or
                    not 1 <= len(result['model']) <= 200):
                raise AiServiceError('Invalid device AI result', code='invalid_ai_output')
            if kind == 'understand':
                validate_understanding(result)
            else:
                # Existing runtime checks phase dates/constraints; preserve its
                # validated extra fields instead of dropping phase placement.
                validate_ai_tasks(result)
            try:
                encoded = json.dumps(result, ensure_ascii=False, allow_nan=False)
                output_bytes = len(encoded.encode('utf-8'))
            except (ValueError, TypeError, OverflowError, RecursionError):
                raise AiServiceError('Invalid device AI result', code='invalid_ai_output') from None
            if output_bytes > 256 * 1024:
                raise AiServiceError('Device AI result too large', code='invalid_ai_output')
            result, status, error, error_code = json.loads(encoded), 'succeeded', None, None
        except Exception as failure:
            error_code, error = _safe_ai_failure(failure)
            result, status = None, 'failed'
        finally:
            with self._lock:
                now = self.clock()
                self._prune(now)
                job = self._jobs.get(jid)
                if job and job['status'] == 'running' and not self._closed:
                    job.update(result=result, status=status, error=error,
                               errorCode=error_code, payload=None, updatedAt=int(now))
                    if status == 'failed':
                        _log_device_job(kind, error_code, stage, time.monotonic() - started)
                self._inflight.pop(jid, None)

    def start(self, jid):
        async def run():
            await asyncio.to_thread(self.execute, jid)
        task = asyncio.create_task(run())
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        if self._janitor is None or self._janitor.done():
            self._janitor = asyncio.create_task(self._expire())

    async def _expire(self):
        while not self._closed:
            await asyncio.sleep(30)
            with self._lock:
                self._prune(self.clock())
                if not self._jobs and not self._inflight and not self._rates:
                    return

    async def close(self):
        with self._lock:
            self._closed = True
            self._jobs.clear()
            self._keys.clear()
            self._rates.clear()
        tasks = list(self._tasks)
        if self._janitor:
            tasks.append(self._janitor)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


class DeviceSpeech:
    """Only ticket hashes persist; audio/text never enter a database or log."""
    def __init__(self, app, jobs):
        self.app, self.jobs = app, jobs
        self._uploads = set()
        self._lock = threading.RLock()
        with app.state.accounts.connection() as db:
            db.execute('''CREATE TABLE IF NOT EXISTS device_asr_tickets(
                nonce_hash TEXT PRIMARY KEY,device_hash TEXT NOT NULL,
                expires_at INTEGER NOT NULL,used INTEGER NOT NULL DEFAULT 0)''')

    def ticket(self, owner, ip):
        from workflows import b64
        with self.jobs._lock:
            now = self.jobs.clock()
            self.jobs._prune(now)
            self.jobs._check_rate(owner, ip, now)
        now = int(time.time())
        nonce, stream_exp = secrets.token_urlsafe(24), now + 90
        payload = b64(json.dumps({'kind': 'device', 'deviceHash': owner,
            'nonce': nonce, 'exp': now + 30, 'streamExp': stream_exp,
            'sampleRate': 16000}, separators=(',', ':')).encode())
        ticket = payload + '.' + b64(hmac.new(
            self.app.state.secret, payload.encode(), hashlib.sha256).digest())
        with self.app.state.accounts.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            db.execute('DELETE FROM device_asr_tickets WHERE expires_at<=?', (now,))
            count = db.execute('SELECT count(*) FROM device_asr_tickets').fetchone()[0]
            own = db.execute('SELECT count(*) FROM device_asr_tickets WHERE device_hash=?', (owner,)).fetchone()[0]
            if count >= 512 or own >= 10:
                raise AuthError('语音请求较多，请稍后重试。', 429, 'device_asr_busy')
            db.execute('INSERT INTO device_asr_tickets VALUES(?,?,?,0)',
                (hashlib.sha256(nonce.encode()).hexdigest(), owner, stream_exp))
        return {'ticket': ticket, 'expiresAt': now + 30,
                'websocketUrl': os.environ.get('SERA_ASR_WS_URL', 'ws://127.0.0.1:8790/ws')}

    def reserve_upload(self, owner, ip):
        with self._lock:
            if owner in self._uploads or len(self._uploads) >= 2:
                raise AuthError('语音正在处理中，请稍后再试。', 429, 'device_asr_busy')
            with self.jobs._lock:
                now = self.jobs.clock()
                self.jobs._prune(now)
                self.jobs._check_rate(owner, ip, now)
            self._uploads.add(owner)

    def transcribe(self, owner, raw, content_type):
        from asr_service import parse_audio_upload, validate_audio
        try:
            audio, filename, mime = parse_audio_upload(content_type, io.BytesIO(raw), len(raw))
            # Bound duration before either real provider or a test adapter runs.
            validate_audio(audio, filename)
            result = self.app.state.transcriber.transcribe(audio, filename, mime)
            if (not isinstance(result, dict) or result.get('source') != 'siliconflow' or
                    not isinstance(result.get('text'), str) or
                    not 1 <= len(result['text'].strip()) <= 20000):
                raise AiServiceError('没有识别到有效文字，请重新录制。', 502, 'invalid_asr_output')
            return result
        finally:
            # Release only once the actual provider thread stops, even if its
            # HTTP caller has already disconnected/canceled.
            with self._lock:
                self._uploads.discard(owner)


def attach_device_workflows(app):
    store = DeviceJobStore(app.state.ai)
    app.state.device_jobs = store
    app.state.device_body_gate = DeviceBodyGate()
    speech = DeviceSpeech(app, store)
    app.state.device_speech = speech

    def scope(request):
        # Account cookies/Authorization never widen a device capability.
        return device_scope(request.headers.get('x-sera-device'))

    @app.post(DEVICE_JOB_PATH)
    async def enqueue(request: Request):
        owner = scope(request)
        raw = await request.body()
        if len(raw) > MAX_REQUEST_BYTES:
            raise AuthError('AI 输入过长。', 413, 'invalid_ai_request')
        body = await request.json()
        if not isinstance(body, dict):
            raise AuthError('AI 请求需为 JSON 对象。', 400, 'invalid_ai_request')
        kind = body.get('kind')
        validator = {'plan': validate_goal_request,
                     'understand': validate_understanding_request}.get(kind)
        if validator is None:
            raise AuthError('不支持的 AI 请求。', 400, 'invalid_ai_request')
        payload = validator(body.get('input'))
        ip = request.client.host if request.client else 'unknown'
        job, created = store.enqueue(owner, ip, kind, body.get('requestId'), payload)
        if created:
            store.start(job['id'])
        return JSONResponse({'job': job}, status_code=202,
                            headers={'Cache-Control': 'no-store', 'Pragma': 'no-cache'})

    @app.get(DEVICE_JOB_PATH + '/{job_id}')
    async def status(job_id: str, request: Request):
        return JSONResponse({'job': store.read(scope(request), job_id)},
                            headers={'Cache-Control': 'no-store', 'Pragma': 'no-cache'})

    @app.post(DEVICE_JOB_PATH + '/{job_id}/cancel')
    async def cancel(job_id: str, request: Request):
        return JSONResponse({'job': store.read(scope(request), job_id, cancel=True)},
                            headers={'Cache-Control': 'no-store', 'Pragma': 'no-cache'})

    @app.post(DEVICE_ASR_PATH)
    async def asr_ticket(request: Request):
        owner = scope(request)
        raw = await request.body()
        if len(raw) > 4096:
            raise AuthError('语音请求无效。', 413, 'invalid_audio')
        body = await request.json()
        if not isinstance(body, dict) or body.get('sampleRate', 16000) != 16000:
            raise AuthError('语音需要 16 kHz PCM。', 400, 'invalid_audio')
        ip = request.client.host if request.client else 'unknown'
        result = await asyncio.to_thread(speech.ticket, owner, ip)
        return JSONResponse(result, headers={'Cache-Control': 'no-store', 'Pragma': 'no-cache'})

    @app.post(DEVICE_UPLOAD_PATH)
    async def transcribe(request: Request):
        from asr_service import MAX_AUDIO
        owner = scope(request)
        raw = await request.body()
        if not 1 <= len(raw) <= MAX_AUDIO + 16384:
            raise AuthError('录音为空或超过 10 MiB。', 413, 'audio_too_large')
        ip = request.client.host if request.client else 'unknown'
        speech.reserve_upload(owner, ip)
        result = await asyncio.to_thread(speech.transcribe, owner, raw, request.headers.get('content-type', ''))
        return JSONResponse(result, headers={'Cache-Control': 'no-store', 'Pragma': 'no-cache'})
