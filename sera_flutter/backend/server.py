"""SERA account-isolated SQLite API with server-side SiliconFlow AI/ASR.
Default loopback deployment; use HTTPS and hardened operations before public hosting.
"""
from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import mimetypes
import os
import re
from pathlib import Path
import socket
import sqlite3
import threading
import time
from collections import deque
from urllib.parse import unquote, urlsplit
from ai_service import AiServiceError, DEFAULT_MODEL, SiliconFlowPlanner, load_api_key
from model_runtime import create_planner
from auth_store import AuthError, AuthStore

MAX_BODY = 8 * 1024 * 1024
AUTH_REJECT_DRAIN_MAX_BYTES = 64 * 1024
AUTH_REJECT_DRAIN_SECONDS = 0.1
LOOPBACK_HOSTS = frozenset(('localhost', '127.0.0.1', '::1'))
DEV_ORIGINS = frozenset(('http://localhost:4180', 'http://127.0.0.1:4180',
                         'http://localhost:4181', 'http://127.0.0.1:4181'))


# Compatibility exports: existing v1 imports keep the same objects.
from workspace_validation import (
    ValidationError,
    ConflictError,
    integer,
    text,
    date,
    calendar_date,
    time_zone,
    objects,
    identifiers,
    validate_planning_messages,
    strings,
    validate_task,
    validate_entry,
    validate_goal,
    HISTORY_COLLECTION_LIMITS,
    HISTORY_LEGACY_FIELDS,
    HISTORY_DELTA_METADATA,
    preserve_change_metadata,
    validate_change_record,
    validate_workspace,
    planning_result_id,
    validate_planning_result_changes
)
from workspace_store import WorkspaceStore


def make_server(host, port, db_path, *, ai_service=None, web_dir=None, transcriber=None):
    store = WorkspaceStore(db_path)
    accounts = AuthStore(db_path)
    planner = ai_service or create_planner()
    web_root = Path(web_dir).resolve() if web_dir else None
    auth_attempts = {}
    auth_attempts_lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def parse_request(self):
            self._request_body_started = False
            if not super().parse_request():
                return False
            self._cors_origin = None
            origins = self.headers.get_all('Origin', [])
            if not origins:
                return True  # Native Android/Dart clients do not send Origin.
            if len(origins) == 1 and self.allowed_origin(origins[0]):
                self._cors_origin = origins[0]
                return True
            # Reject before reading a body, mutating SQLite, or calling paid AI.
            self.close_connection = True
            self.respond(403, {'error': 'Browser origin is not allowed.', 'code': 'origin_forbidden'})
            return False

        def allowed_origin(self, origin):
            try:
                parsed = urlsplit(origin)
                hosts = self.headers.get_all('Host', [])
                if len(hosts) != 1:
                    return False
                host = urlsplit('//' + hosts[0])
                # Do not derive trust from an arbitrary Host: this also rejects
                # DNS-rebinding hostnames even when Origin matches that name.
                if (host.hostname not in LOOPBACK_HOSTS or host.username or host.password or
                        host.path or host.query or host.fragment or host.port != self.server.server_port):
                    return False
                if (parsed.scheme != 'http' or parsed.hostname not in LOOPBACK_HOSTS or
                        parsed.username or parsed.password or parsed.path or parsed.query or parsed.fragment):
                    return False
                if origin in DEV_ORIGINS:
                    return True
                return parsed.hostname == host.hostname and parsed.port == self.server.server_port
            except ValueError:
                return False

        def cors_headers(self):
            self.send_header('Vary', 'Origin')
            origin = getattr(self, '_cors_origin', None)
            if origin:
                self.send_header('Access-Control-Allow-Origin', origin)
                self.send_header('Access-Control-Allow-Methods', 'GET, PUT, POST, DELETE, OPTIONS')
                self.send_header('Access-Control-Allow-Headers', 'Content-Type, Authorization')

        def token(self):
            parts = self.headers.get('Authorization', '').split()
            return parts[1] if len(parts) == 2 and parts[0].lower() == 'bearer' else ''

        def session(self):
            try:
                return accounts.authenticate(self.token())
            except AuthError as exc:
                if exc.status == 401:
                    self.discard_rejected_auth_body()
                self.respond(exc.status, {'error': str(exc), 'code': exc.code})
                self.close_connection = True
                return None

        def discard_rejected_auth_body(self):
            # A raw Windows socket can reset a written 401 when a separately sent
            # body arrives during close. Drain only a small, explicitly sized body.
            # FastAPI has already buffered its body into an InMemorySocket.
            if (not isinstance(self.connection, socket.socket)
                    or getattr(self, '_request_body_started', False)):
                return
            lengths = self.headers.get_all('Content-Length', [])
            if len(lengths) != 1 or self.headers.get_all('Transfer-Encoding', []):
                return
            value = lengths[0].strip()
            if not re.fullmatch(r'[0-9]{1,10}', value):
                return
            remaining = int(value)
            if not 0 < remaining <= AUTH_REJECT_DRAIN_MAX_BYTES:
                return
            self._request_body_started = True
            original_timeout = self.connection.gettimeout()
            deadline = time.monotonic() + AUTH_REJECT_DRAIN_SECONDS
            try:
                while remaining:
                    wait = deadline - time.monotonic()
                    if wait <= 0:
                        break
                    self.connection.settimeout(wait)
                    chunk = self.rfile.read1(min(remaining, 8192))
                    if not chunk:
                        break
                    remaining -= len(chunk)
            except OSError:
                pass  # A slow or disconnected unauthenticated peer is still denied.
            finally:
                self.connection.settimeout(original_timeout)

        def read_json(self, limit=64 * 1024):
            length = int(self.headers.get('Content-Length', '-1'))
            if length < 0 or length > limit:
                raise AuthError('请求长度无效或超过限制。', 413, 'body_too_large')
            self._request_body_started = True
            value = json.loads(self.rfile.read(length).decode('utf-8'))
            if not isinstance(value, dict):
                raise AuthError('请求需为 JSON 对象。')
            return value

        def check_auth_rate(self):
            now = time.monotonic()
            with auth_attempts_lock:
                attempts = auth_attempts.setdefault(self.client_address[0], deque())
                while attempts and attempts[0] < now - 900:
                    attempts.popleft()
                if len(attempts) >= 30:
                    raise AuthError('账号请求过于频繁，请 15 分钟后重试。', 429, 'auth_rate_limited')
                attempts.append(now)

        def handle(self):
            try:
                super().handle()
            except (ConnectionResetError, BrokenPipeError):
                pass  # Browser reloads routinely close keep-alive sockets.

        def respond(self, status, body=None):
            encoded = b'' if body is None else json.dumps(body, ensure_ascii=False).encode('utf-8')
            self.send_response(status)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(encoded)))
            self.cors_headers()
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            if encoded:
                self.wfile.write(encoded)

        def do_OPTIONS(self):
            self.respond(204)

        def do_GET(self):
            if urlsplit(self.path).path == '/health':
                self.respond(200, {'status': 'ok', 'service': 'sera-local-reference-api', 'schemaVersion': 2,
                                   'aiConfigured': planner.configured, 'aiModel': planner.model if planner.configured else None})
            elif urlsplit(self.path).path in ('/api/v1/workspace', '/api/v1/auth/me', '/api/v1/account/export', '/api/v1/guest-workspace'):
                session = self.session()
                if session is None: return
                path = urlsplit(self.path).path
                if path == '/api/v1/auth/me':
                    self.respond(200, session)
                elif path == '/api/v1/account/export':
                    self.respond(200, {'user': session['user'], 'workspace': store.load(session['user']['id'])})
                elif path == '/api/v1/guest-workspace':
                    if self.client_address[0] not in ('127.0.0.1', '::1'):
                        return self.respond(403, {'error': 'Legacy guest export is local-only.'})
                    self.respond(200, {'workspace': store.load(), 'source': 'legacy-local-guest'})
                else:
                    self.respond(200, {'workspace': store.load(session['user']['id'])})
            elif web_root and urlsplit(self.path).path != '/api' and not urlsplit(self.path).path.startswith('/api/'):
                self.serve_static()
            else:
                self.respond(404, {'error': 'Route not found'})

        def serve_static(self):
            try:
                requested = unquote(urlsplit(self.path).path)
                if '\\' in requested or '\x00' in requested:
                    return self.respond(404, {'error': 'File not found'})
                target = (web_root / requested.lstrip('/')).resolve()
                if not target.is_relative_to(web_root):
                    return self.respond(404, {'error': 'File not found'})
                if target.is_dir():
                    target = target / 'index.html'
                if not target.is_file():
                    # go_router uses hash URLs by default. A clean extensionless
                    # route may also enter the application; API/file misses do not.
                    if not target.suffix and not requested.startswith('/api'):
                        target = web_root / 'index.html'
                    else:
                        return self.respond(404, {'error': 'File not found'})
                target = target.resolve()
                if not target.is_relative_to(web_root) or not target.is_file():
                    return self.respond(404, {'error': 'File not found'})
                payload = target.read_bytes()
                content_type = 'application/wasm' if target.suffix == '.wasm' else mimetypes.guess_type(target.name)[0] or 'application/octet-stream'
                self.send_response(200)
                self.send_header('Content-Type', content_type)
                self.send_header('Content-Length', str(len(payload)))
                self.send_header('Cache-Control', 'no-cache')
                self.cors_headers()
                self.end_headers()
                self.wfile.write(payload)
            except (OSError, ValueError):
                self.respond(404, {'error': 'File not found'})

        def do_PUT(self):
            if urlsplit(self.path).path != '/api/v1/workspace':
                self.close_connection = True
                return self.respond(404, {'error': 'Route not found'})
            session = self.session()
            if session is None: return
            try:
                length = int(self.headers.get('Content-Length', '-1'))
                if length < 0:
                    raise ValidationError('Content-Length is required')
                if length > MAX_BODY:
                    self.close_connection = True
                    return self.respond(413, {'error': 'Request exceeds 8 MiB limit'})
                raw = self.rfile.read(length)
                body = json.loads(raw.decode('utf-8'))
                if not isinstance(body, dict):
                    raise ValidationError('Request body must be an object')
                saved = store.save(body.get('workspace'), body.get('expectedRevision'), session['user']['id'])
                self.respond(200, {'workspace': saved})
            except ConflictError as exc:
                self.respond(409, {'error': str(exc), 'code': 'revision_conflict'})
            except (ValidationError, ValueError, TypeError, KeyError, OverflowError, RecursionError) as exc:
                self.close_connection = True
                self.respond(400, {'error': str(exc) or 'Invalid JSON workspace'})
            except sqlite3.Error:
                self.respond(503, {'error': 'Database unavailable. Retry after checking server storage.'})

        def do_POST(self):
            try:
                path = urlsplit(self.path).path
                if path == '/api/v1/auth/register':
                    self.check_auth_rate()
                    return self.respond(201, accounts.register(self.read_json(16 * 1024)))
                if path == '/api/v1/auth/login':
                    self.check_auth_rate()
                    return self.respond(200, accounts.login(self.read_json(16 * 1024)))
                if path not in ('/api/v1/auth/logout', '/api/v1/workspace/import-guest', '/api/v1/ai/plan', '/api/v1/ai/transcribe'):
                    self.close_connection = True
                    return self.respond(404, {'error': 'Route not found'})
                session = self.session()
                if session is None: return
                if path == '/api/v1/auth/logout':
                    self.read_json(1024)
                    accounts.logout(self.token())
                    return self.respond(200, {'loggedOut': True})
                if path == '/api/v1/workspace/import-guest':
                    body = self.read_json(MAX_BODY)
                    incoming = body.get('workspace')
                    if not isinstance(incoming, dict): raise ValidationError('workspace is required')
                    expected = body.get('expectedRevision')
                    incoming = {**incoming, 'revision': expected}
                    return self.respond(200, {'workspace': store.save(incoming, expected, session['user']['id'], legacy_import=True)})
                if path == '/api/v1/ai/transcribe':
                    from asr_service import parse_audio_upload
                    length = int(self.headers.get('Content-Length', '-1'))
                    audio, filename, content_type = parse_audio_upload(self.headers.get('Content-Type', ''), self.rfile, length)
                    if transcriber is None:
                        raise AiServiceError('语音服务尚未配置。', 503, 'asr_not_configured')
                    return self.respond(200, transcriber.transcribe(audio, filename, content_type))
                self.respond(200, planner.generate(self.read_json()))
            except AuthError as exc:
                self.close_connection = True
                self.respond(exc.status, {'error': str(exc), 'code': exc.code})
            except ConflictError as exc:
                self.respond(409, {'error': str(exc), 'code': 'revision_conflict'})
            except AiServiceError as exc:
                self.respond(exc.status, {'error': str(exc), 'code': exc.code})
            except (ValueError, TypeError, RecursionError):
                self.close_connection = True
                self.respond(400, {'error': 'Invalid JSON AI request', 'code': 'invalid_ai_request'})
            except sqlite3.Error:
                self.respond(503, {'error': 'Database unavailable. Check server storage.'})

        def do_DELETE(self):
            path = urlsplit(self.path).path
            if path not in ('/api/v1/workspace', '/api/v1/account'):
                return self.respond(404, {'error': 'Route not found'})
            session = self.session()
            if session is None: return
            if path == '/api/v1/account':
                try:
                    accounts.delete_account(self.token(), self.read_json(1024).get('password'))
                    self.respond(200, {'deleted': True})
                except AuthError as exc:
                    self.respond(exc.status, {'error': str(exc), 'code': exc.code})
                except (ValueError, TypeError):
                    self.respond(400, {'error': 'Invalid JSON request'})
            else:
                store.clear(session['user']['id'])
                self.respond(200, {'workspace': None})

    server = ThreadingHTTPServer((host, port), Handler)
    server.daemon_threads = True
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=8787)
    parser.add_argument('--db', default=str(Path(__file__).with_name('sera.sqlite3')))
    parser.add_argument('--ai-key-file', default=os.environ.get('SILICONFLOW_API_KEY_FILE'))
    parser.add_argument('--ai-model', default=os.environ.get('SILICONFLOW_MODEL', DEFAULT_MODEL))
    parser.add_argument('--asr-model', default=os.environ.get('SILICONFLOW_ASR_MODEL', 'FunAudioLLM/SenseVoiceSmall'))
    parser.add_argument('--web-dir', help='Serve only this Flutter build/web directory at the same origin')
    args = parser.parse_args()
    if args.web_dir and not (Path(args.web_dir).resolve() / 'index.html').is_file():
        parser.error('--web-dir must contain a built index.html; run flutter build web first')
    import uvicorn
    from app import create_app
    app = create_app(db_path=args.db, web_dir=args.web_dir, ai_key_file=args.ai_key_file,
                     ai_model=args.ai_model, asr_model=args.asr_model)
    uvicorn.run(app, host=args.host, port=args.port, proxy_headers=True,
                forwarded_allow_ips=os.environ.get('SERA_TRUSTED_PROXIES', '127.0.0.1'))


if __name__ == '__main__':
    main()
