"""Isolated device capability tests; all AI and speech adapters are synthetic."""
import asyncio
from copy import deepcopy
import io
import json
from pathlib import Path
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import wave

from fastapi.testclient import TestClient

from ai_service import AiServiceError
from app import create_app
from auth_store import AuthError
from guest_workflows import (DEVICE_ASR_PATH, DEVICE_JOB_PATH, DEVICE_UPLOAD_PATH,
                             DeviceJobStore, device_scope)
from local_asr import consume_ticket, create_asr_app, ticket_is_active
from sync_store import migrate_workspace
from test_server import empty_workspace


TOKEN_A, TOKEN_B = 'a1' * 32, 'b2' * 32  # Synthetic device fixtures, never accounts.
OWNER_A, OWNER_B = device_scope(TOKEN_A), device_scope(TOKEN_B)
UNDERSTAND = {'prompt': '明天开会', 'notes': '', 'referenceNow': '2026-11-08T04:00:00Z',
              'timeZone': 'Asia/Hong_Kong', 'dailyBudget': 60}
PLAN = {'title': '整理房间', 'deadline': '2026-11-15T12:00:00Z', 'dailyBudget': 30,
        'notes': '', 'prompt': '', 'referenceNow': '2026-11-08T04:00:00Z',
        'timeZone': 'Asia/Hong_Kong'}


def understanding(title='明天开会'):
    return {'intent': 'task', 'title': title, 'summary': '', 'outcome': '',
            'deadline': None, 'deadlineIsDateOnly': False, 'start': None, 'end': None,
            'dailyBudget': None, 'estimatedMinutes': 30, 'questions': [],
            'source': 'siliconflow', 'model': 'isolated-unit-adapter'}


class StubPlanner:
    configured = True
    model = 'isolated-unit-adapter'
    def __init__(self): self.calls = []
    def understand(self, payload):
        self.calls.append(('understand', deepcopy(payload)))
        return understanding(payload['prompt'])
    def generate(self, payload):
        self.calls.append(('plan', deepcopy(payload)))
        return {'tasks': [{'title': payload['title'], 'notes': '',
                'estimatedMinutes': 30, 'checklist': ['整理书桌'], 'phase': '收拾',
                'notBefore': '2026-11-08T04:00:00Z', 'deadline': '2026-11-15T12:00:00Z'}],
                'source': 'siliconflow', 'model': self.model}


class StubTranscriber:
    def __init__(self): self.calls = 0
    def transcribe(self, audio, filename, mime):
        self.calls += 1
        return {'text': '整理明天的事情', 'source': 'siliconflow',
                'model': 'isolated-unit-speech', 'durationSeconds': 1}


class StubRecognizer:
    load_seconds = 0
    def create_stream(self): return object()
    def accept(self, stream, samples, finish=False):
        return '本机语音' if finish else '本机'


def wav_bytes(seconds=1):
    output = io.BytesIO()
    with wave.open(output, 'wb') as value:
        value.setnchannels(1)
        value.setsampwidth(2)
        value.setframerate(8000)
        value.writeframes(bytes(int(8000 * seconds) * 2))
    return output.getvalue()


class DeviceJobStoreTests(unittest.TestCase):
    def setUp(self):
        self.now = 1000.0
        self.planner = StubPlanner()
        self.store = DeviceJobStore(self.planner, clock=lambda: self.now)

    def enqueue(self, key='request-1', *, owner=OWNER_A, ip='ip-a', kind='understand', payload=None):
        return self.store.enqueue(owner, ip, kind, key, payload or deepcopy(UNDERSTAND))

    def test_device_capability_requires_exact_high_entropy_shape(self):
        for value in (None, '', 'abc', 'f' * 63, 'g' * 64, 'f' * 65, 'A' * 64):
            with self.assertRaises(AuthError): device_scope(value)
        self.assertNotEqual(OWNER_A, TOKEN_A)
        self.assertEqual(len(OWNER_A), 64)

    def test_result_and_cancel_are_scoped_and_response_omits_capability_and_input(self):
        job, created = self.enqueue()
        self.assertTrue(created)
        with self.assertRaises(AuthError) as denied:
            self.store.read(OWNER_B, job['id'], cancel=True)
        self.assertEqual(denied.exception.status, 404)
        self.store.execute(job['id'])
        result = self.store.read(OWNER_A, job['id'])
        self.assertEqual(result['status'], 'succeeded')
        self.assertIsNone(result['errorCode'])
        self.assertEqual(result['result']['source'], 'siliconflow')
        for secret in (TOKEN_A, OWNER_A, 'request-1', 'referenceNow'):
            self.assertNotIn(secret, json.dumps(result))
        self.assertIsNone(self.store._jobs[job['id']]['payload'])

    def test_same_request_recovers_one_job_and_changed_payload_conflicts(self):
        job, _ = self.enqueue()
        repeated, created = self.enqueue()
        self.assertEqual(repeated['id'], job['id'])
        self.assertFalse(created)
        changed = {**UNDERSTAND, 'prompt': '改成后天'}
        with self.assertRaises(AuthError) as conflict: self.enqueue(payload=changed)
        self.assertEqual(conflict.exception.code, 'idempotency_conflict')
        other, _ = self.enqueue(owner=OWNER_B)
        self.assertNotEqual(other['id'], job['id'])
        self.assertEqual(len(self.store._rates[('device', OWNER_A)]), 1)

    def test_cancel_before_execution_never_calls_provider(self):
        job, _ = self.enqueue()
        self.store.read(OWNER_A, job['id'], cancel=True)
        self.store.execute(job['id'])
        self.assertEqual(self.planner.calls, [])
        result = self.store.read(OWNER_A, job['id'])
        self.assertEqual(result['status'], 'canceled')
        self.assertEqual(result['errorCode'], 'ai_canceled')
        self.assertIsNone(result['error'])

    def test_cancel_during_execution_discards_late_result_and_keeps_slot(self):
        began, release = threading.Event(), threading.Event()
        def blocked(payload):
            began.set()
            if not release.wait(3): raise RuntimeError('test release timeout')
            return understanding()
        self.planner.understand = blocked
        self.store.max_device_running = 1
        job, _ = self.enqueue()
        thread = threading.Thread(target=self.store.execute, args=(job['id'],))
        thread.start()
        try:
            self.assertTrue(began.wait(1))
            self.store.read(OWNER_A, job['id'], cancel=True)
            with self.assertRaises(AuthError) as busy: self.enqueue('another')
            self.assertEqual(busy.exception.code, 'device_ai_busy')
        finally:
            release.set()
            thread.join(2)
        self.assertEqual(self.store.read(OWNER_A, job['id'])['status'], 'canceled')
        self.assertEqual(self.store.read(OWNER_A, job['id'])['errorCode'], 'ai_canceled')
        self.assertIsNone(self.store.read(OWNER_A, job['id'])['result'])
        self.enqueue('after-release')

    def test_expired_queued_job_does_not_call_provider_and_recovery_expires(self):
        job, _ = self.enqueue()
        self.now += 121
        self.store.execute(job['id'])
        self.assertEqual(self.planner.calls, [])
        self.assertEqual(self.store.read(OWNER_A, job['id'])['status'], 'failed')
        self.assertEqual(self.store.read(OWNER_A, job['id'])['errorCode'], 'ai_timeout')
        self.now += 800
        with self.assertRaises(AuthError): self.store.read(OWNER_A, job['id'])
        self.assertNotIn(job['id'], self.store._jobs)

    def test_device_and_ip_limits_survive_token_rotation_but_recovery_is_free(self):
        self.store.rate_limits = {'device': (1, 10), 'ip': (1, 10)}
        job, _ = self.enqueue()
        self.store.execute(job['id'])
        self.assertFalse(self.enqueue()[1])
        for owner, ip in ((OWNER_A, 'ip-b'), (OWNER_B, 'ip-a')):
            with self.assertRaises(AuthError) as limit: self.enqueue('new', owner=owner, ip=ip)
            self.assertEqual(limit.exception.code, 'device_ai_rate_limited')
        self.now += 61
        self.enqueue('new')

    def test_global_and_ip_concurrency_and_cache_are_bounded(self):
        self.store.max_running = 1
        job, _ = self.enqueue()
        with self.assertRaises(AuthError): self.enqueue('other', owner=OWNER_B, ip='ip-b')
        self.store.execute(job['id'])
        self.store.max_jobs = 1
        with self.assertRaises(AuthError) as full: self.enqueue('other', owner=OWNER_B, ip='ip-b')
        self.assertEqual(full.exception.code, 'device_ai_capacity')
        self.now += 901
        self.enqueue('other', owner=OWNER_B, ip='ip-b')

    def test_payload_is_frozen_and_plan_extra_fields_are_preserved(self):
        payload = deepcopy(PLAN)
        job, _ = self.enqueue(kind='plan', payload=payload)
        payload['title'] = '不应进入已提交的请求'
        self.store.execute(job['id'])
        result = self.store.read(OWNER_A, job['id'])['result']
        self.assertEqual(result['tasks'][0]['title'], PLAN['title'])
        self.assertEqual(result['tasks'][0]['phase'], '收拾')
        self.assertEqual(self.planner.calls[0][0], 'plan')

    def test_invalid_or_provider_exception_has_no_raw_leak_or_template_fallback(self):
        for output in ({'source': 'local-template'}, {'source': 'siliconflow', 'model': 'unit', 'intent': 'invalid'}):
            self.planner.understand = lambda body, result=output: result
            job, _ = self.enqueue(str(len(self.store._jobs)))
            self.store.execute(job['id'])
            self.assertEqual(self.store.read(OWNER_A, job['id'])['status'], 'failed')
        def broken(body): raise RuntimeError('private-provider-body')
        self.planner.understand = broken
        job, _ = self.enqueue('broken')
        self.store.execute(job['id'])
        result = self.store.read(OWNER_A, job['id'])
        self.assertIsNone(result['result'])
        self.assertEqual(result['errorCode'], 'ai_processing_error')
        self.assertNotIn('private-provider-body', json.dumps(result))

    def test_known_failures_have_safe_codes_messages_and_never_retry(self):
        messages = {
            'ai_empty_response': 'AI 暂未返回内容，请重试。',
            'ai_timeout': 'AI 响应超时，请稍后重试。',
            'ai_connection_error': '暂时无法连接 AI，请稍后重试。',
            'ai_provider_error': 'AI 服务暂时不可用，请稍后重试。',
            'ai_rate_limited': 'AI 请求较多，请稍后重试。',
            'ai_not_configured': 'AI 服务暂时不可用，请稍后重试。',
            'invalid_ai_output': 'AI 返回内容暂时无法使用，请重试。',
            'invalid_ai_request': '这次 AI 输入暂时无法处理，请调整后重试。',
            'ai_tool_limit': 'AI 查询暂未完成，请稍后重试。',
        }
        secret = 'synthetic-private-provider-body-and-key'
        for code, message in messages.items():
            with self.subTest(code=code):
                store, calls = DeviceJobStore(self.planner), []
                def fail_once(payload):
                    calls.append(True)
                    raise AiServiceError(secret, code=code)
                self.planner.understand = fail_once
                job, _ = store.enqueue(OWNER_A, 'synthetic-private-ip', 'understand',
                                       'synthetic-private-request', UNDERSTAND)
                with self.assertLogs('guest_workflows', level='WARNING') as logged:
                    store.execute(job['id'])
                    result = store.read(OWNER_A, job['id'])
                    repeated, created = store.enqueue(OWNER_A, 'synthetic-private-ip',
                        'understand', 'synthetic-private-request', UNDERSTAND)
                    store.execute(job['id'])
                self.assertEqual(result['status'], 'failed')
                self.assertEqual(result['errorCode'], code)
                self.assertEqual(result['error'], message)
                self.assertIsNone(result['result'])
                self.assertIsNone(store._jobs[job['id']]['payload'])
                self.assertEqual(repeated, result)
                self.assertFalse(created)
                self.assertEqual(len(calls), 1)
                self.assertEqual(len(logged.records), 1)
                record = logged.records[0]
                self.assertEqual(record.msg, 'device_ai kind=%s code=%s stage=%s elapsed_ms=%d')
                self.assertEqual(record.args[:3], ('understand', code, 'provider'))
                self.assertIs(type(record.args[3]), int)
                self.assertGreaterEqual(record.args[3], 0)
                self.assertIsNone(record.exc_info)
                self.assertIsNone(record.stack_info)
                serialized = json.dumps(result) + record.getMessage()
                for private in (secret, OWNER_A, TOKEN_A, 'synthetic-private-ip',
                                'synthetic-private-request', UNDERSTAND['prompt']):
                    self.assertNotIn(private, serialized)
                self.assertNotIn(job['id'], record.getMessage())

    def test_unknown_exception_or_unreviewed_code_is_generic_and_redacted(self):
        secret = 'synthetic-private-error-content'
        failures = [RuntimeError(secret), AiServiceError(secret, code=secret),
                    AiServiceError(secret, code=[secret])]
        for failure in failures:
            with self.subTest(exception=type(failure).__name__):
                store, calls = DeviceJobStore(self.planner), []
                def broken(payload):
                    calls.append(True)
                    raise failure
                self.planner.understand = broken
                job, _ = store.enqueue(OWNER_A, 'ip-a', 'understand', 'once', UNDERSTAND)
                with self.assertLogs('guest_workflows', level='WARNING') as logged:
                    store.execute(job['id'])
                result = store.read(OWNER_A, job['id'])
                self.assertEqual(result['errorCode'], 'ai_processing_error')
                self.assertEqual(result['error'], 'AI 暂时未能完成，请稍后重试。')
                self.assertEqual(len(calls), 1)
                self.assertIsNone(logged.records[0].exc_info)
                self.assertNotIn(secret, json.dumps(result) + ''.join(logged.output))

    def test_validation_failures_are_classified_without_logging_result(self):
        for output in ({'source': 'synthetic-private-output'},
                       {**understanding(), 'synthetic-private-extra': float('nan')}):
            with self.subTest(output_shape='invalid-or-unserializable'):
                self.planner.understand = lambda payload: output
                store = DeviceJobStore(self.planner)
                job, _ = store.enqueue(OWNER_A, 'ip-a', 'understand', 'validation', UNDERSTAND)
                with self.assertLogs('guest_workflows', level='WARNING') as logged:
                    store.execute(job['id'])
                result = store.read(OWNER_A, job['id'])
                self.assertEqual(result['errorCode'], 'invalid_ai_output')
                self.assertEqual(logged.records[0].args[:3],
                                 ('understand', 'invalid_ai_output', 'validation'))
                self.assertNotIn('synthetic-private', json.dumps(result) + ''.join(logged.output))

    def test_canceled_job_keeps_code_when_provider_later_fails(self):
        job, _ = self.enqueue()
        def canceled_then_failed(payload):
            self.store.read(OWNER_A, job['id'], cancel=True)
            raise AiServiceError('synthetic-private-late-failure', code='ai_empty_response')
        self.planner.understand = canceled_then_failed
        with self.assertLogs('guest_workflows', level='WARNING') as logged:
            self.store.execute(job['id'])
        result = self.store.read(OWNER_A, job['id'])
        self.assertEqual(result['status'], 'canceled')
        self.assertEqual(result['errorCode'], 'ai_canceled')
        self.assertIsNone(result['result'])
        self.assertIsNone(result['error'])
        self.assertEqual(len(logged.records), 1)
        self.assertEqual(logged.records[0].args[:3], ('understand', 'ai_canceled', 'cancel'))

    def test_expiration_keeps_timeout_code_and_discards_late_success(self):
        job, _ = self.enqueue()
        def expired_then_succeeded(payload):
            self.now += 121
            self.store.read(OWNER_A, job['id'])
            return understanding()
        self.planner.understand = expired_then_succeeded
        with self.assertLogs('guest_workflows', level='WARNING') as logged:
            self.store.execute(job['id'])
            self.store.read(OWNER_A, job['id'])
        result = self.store.read(OWNER_A, job['id'])
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['errorCode'], 'ai_timeout')
        self.assertIsNone(result['result'])
        self.assertEqual(len(logged.records), 1)
        self.assertEqual(logged.records[0].args, ('understand', 'ai_timeout', 'expiration', 121000))

    def test_error_code_is_nullable_for_legacy_records_and_success(self):
        job, _ = self.enqueue()
        self.store._jobs[job['id']].pop('errorCode')
        self.assertIsNone(self.store.read(OWNER_A, job['id'])['errorCode'])
        self.store.execute(job['id'])
        self.assertIsNone(self.store.read(OWNER_A, job['id'])['errorCode'])


class DeviceWorkflowHttpTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db = Path(self.temp.name) / 'device-tests.db'
        self.planner, self.transcriber = StubPlanner(), StubTranscriber()
        self.app = create_app(db_path=self.db, ai_service=self.planner,
                              transcriber=self.transcriber, sms_service=SimpleNamespace())
        self.client = TestClient(self.app)
        self.client.__enter__()
        self.headers = {'X-Sera-Device': TOKEN_A}

    def tearDown(self):
        self.client.__exit__(None, None, None)
        self.temp.cleanup()

    def submit(self, key='http-request-1', **options):
        return self.client.post(DEVICE_JOB_PATH, headers=options.pop('headers', self.headers),
            json={'kind': options.pop('kind', 'understand'), 'requestId': key,
                  'input': options.pop('input', UNDERSTAND)}, **options)

    def finished(self, jid):
        for _ in range(100):
            response = self.client.get(DEVICE_JOB_PATH + '/' + jid, headers=self.headers)
            if response.json()['job']['status'] in ('succeeded', 'failed', 'canceled'):
                return response.json()['job']
            time.sleep(.01)
        self.fail('isolated adapter did not finish')

    def ticket(self, token=TOKEN_A):
        response = self.client.post(DEVICE_ASR_PATH, headers={'X-Sera-Device': token}, json={'sampleRate': 16000})
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()['ticket']

    def test_anonymous_understanding_recovery_no_account_or_durable_records(self):
        response = self.submit()
        self.assertEqual(response.status_code, 202, response.text)
        jid = response.json()['job']['id']
        self.assertEqual(self.finished(jid)['result']['title'], UNDERSTAND['prompt'])
        repeated = self.submit()
        self.assertEqual(repeated.json()['job']['id'], jid)
        self.assertEqual(len(self.planner.calls), 1)
        with self.app.state.accounts.connection() as db:
            for table in ('users', 'sessions', 'account_workspaces', 'jobs'):
                self.assertEqual(db.execute('SELECT count(*) FROM ' + table).fetchone()[0], 0)
        self.assertEqual(response.headers['cache-control'], 'no-store')

    def test_empty_response_code_survives_http_poll_and_same_request_recovery(self):
        calls = []
        def empty(payload):
            calls.append(True)
            raise AiServiceError('synthetic-private-empty-body-detail', code='ai_empty_response')
        self.planner.understand = empty
        with self.assertLogs('guest_workflows', level='WARNING'):
            response = self.submit()
            self.assertEqual(response.status_code, 202)
            first = self.finished(response.json()['job']['id'])
        repeated = self.submit()
        self.assertEqual(repeated.status_code, 202)
        self.assertEqual(repeated.json()['job'], first)
        self.assertEqual(first['status'], 'failed')
        self.assertEqual(first['errorCode'], 'ai_empty_response')
        self.assertEqual(first['error'], 'AI 暂未返回内容，请重试。')
        self.assertEqual(len(calls), 1)
        self.assertNotIn('synthetic-private', json.dumps(first))

    def test_missing_capability_origin_invalid_input_and_limits_precede_provider(self):
        self.assertEqual(self.submit(headers={}).status_code, 401)
        self.assertEqual(self.submit(headers={'X-Sera-Device': 'short'}).status_code, 401)
        self.assertEqual(self.submit(headers={**self.headers, 'Origin': 'https://evil.example'}).status_code, 403)
        self.assertEqual(self.submit(input={}).status_code, 400)
        self.assertEqual(self.submit(kind='export').status_code, 400)
        array = self.client.post(DEVICE_JOB_PATH, headers=self.headers, json=[])
        self.assertEqual(array.status_code, 400)
        over = self.client.post(DEVICE_JOB_PATH, headers=self.headers, json={'input': 'x' * 65537})
        self.assertEqual(over.status_code, 413)
        self.assertEqual(self.planner.calls, [])

    def test_device_does_not_authorize_account_api_or_other_device_jobs(self):
        job = self.submit().json()['job']
        self.finished(job['id'])
        for suffix in ('', '/cancel'):
            method = self.client.get if not suffix else self.client.post
            response = method(DEVICE_JOB_PATH + '/' + job['id'] + suffix,
                              headers={'X-Sera-Device': TOKEN_B})
            self.assertEqual(response.status_code, 404)
        for path in ('/api/v1/workspace', '/api/v1/account/export', '/api/v1/sync/state'):
            self.assertEqual(self.client.get(path, headers=self.headers).status_code, 401)
        self.assertEqual(self.client.post('/api/v1/jobs', headers=self.headers,
            json={'kind': 'understand', 'input': UNDERSTAND}).status_code, 401)

    def test_stale_login_cookie_cannot_expand_scope_or_block_device_and_csrf_stays_on_account(self):
        self.client.cookies.set('sera_session', 'synthetic-stale-cookie')
        response = self.submit()
        self.assertEqual(response.status_code, 202)
        self.assertEqual(self.finished(response.json()['job']['id'])['status'], 'succeeded')
        self.assertEqual(self.client.post('/api/v1/auth/logout', headers=self.headers, json={}).status_code, 403)
        self.assertEqual(self.client.post(DEVICE_JOB_PATH, json={}).status_code, 401)
        self.assertNotIn('set-cookie', response.headers)

    def test_cors_preflight_includes_device_header_without_requiring_token(self):
        # TestClient's Host is testserver; use an explicit allowed dev origin,
        # rather than a production loopback origin with a different Host.
        response = self.client.options(DEVICE_JOB_PATH, headers={'Origin': 'http://127.0.0.1:4180',
            'Access-Control-Request-Method': 'POST', 'Access-Control-Request-Headers': 'X-Sera-Device'})
        self.assertEqual(response.status_code, 204)
        self.assertIn('X-Sera-Device', response.headers['access-control-allow-headers'])

    def test_process_restart_has_no_durable_ai_result(self):
        jid = self.submit().json()['job']['id']
        self.finished(jid)
        restarted = create_app(db_path=self.db, ai_service=StubPlanner(),
            transcriber=StubTranscriber(), sms_service=SimpleNamespace())
        with TestClient(restarted) as other:
            self.assertEqual(other.get(DEVICE_JOB_PATH + '/' + jid, headers=self.headers).status_code, 404)

    def test_device_ticket_one_use_tamper_expiry_and_hash_only_persistence(self):
        value = self.ticket()
        ticket = consume_ticket(value, self.app.state.secret, self.app.state.accounts)
        self.assertEqual(ticket['kind'], 'device')
        self.assertTrue(ticket_is_active(ticket, self.app.state.accounts))
        self.assertLessEqual(ticket['streamExp'] - time.time(), 90)
        with self.assertRaises(ValueError): consume_ticket(value, self.app.state.secret, self.app.state.accounts)
        with self.assertRaises(ValueError): consume_ticket(value + 'a', self.app.state.secret, self.app.state.accounts)
        with patch('local_asr.time.time', return_value=ticket['streamExp'] + 1):
            self.assertFalse(ticket_is_active(ticket, self.app.state.accounts))
        with self.app.state.accounts.connection() as db:
            row = dict(db.execute('SELECT * FROM device_asr_tickets').fetchone())
            self.assertEqual(set(row), {'nonce_hash', 'device_hash', 'expires_at', 'used'})
            self.assertNotIn(TOKEN_A, json.dumps(row))
            for table in ('users', 'sessions', 'jobs', 'account_workspaces'):
                self.assertEqual(db.execute('SELECT count(*) FROM ' + table).fetchone()[0], 0)

    def test_device_stream_final_single_device_slot_expiry_and_cancel(self):
        first, duplicate, other, resumed = self.ticket(), self.ticket(), self.ticket(TOKEN_B), self.ticket()
        start = {'type': 'start', 'sampleRate': 16000, 'format': 's16le', 'channels': 1}
        with TestClient(create_asr_app(self.db, recognizer=StubRecognizer())) as speech:
            with speech.websocket_connect('/ws?ticket=' + first) as stream:
                stream.send_json(start)
                self.assertEqual(stream.receive_json()['status'], 'listening')
                with speech.websocket_connect('/ws?ticket=' + duplicate) as denied:
                    self.assertEqual(denied.receive_json()['code'], 'device_stream_active')
                with speech.websocket_connect('/ws?ticket=' + other) as second:
                    second.send_json(start)
                    self.assertEqual(second.receive_json()['status'], 'listening')
                    second.send_bytes(bytes(3200))
                    self.assertEqual(second.receive_json()['type'], 'partial')
                    second.send_json({'type': 'finish'})
                    final = second.receive_json()
                    self.assertEqual(final['type'], 'final')
                    self.assertEqual(final['source'], 'sherpa-onnx')
                stream.send_json({'type': 'cancel'})
                self.assertEqual(stream.receive_json()['status'], 'cancelled')
            with speech.websocket_connect('/ws?ticket=' + resumed) as stream:
                stream.send_json(start)
                self.assertEqual(stream.receive_json()['status'], 'listening')
                with self.app.state.accounts.connection() as db:
                    db.execute('DELETE FROM device_asr_tickets')
                stream.send_bytes(bytes(3200))
                self.assertEqual(stream.receive_json()['code'], 'device_ticket_expired')

    def test_upload_preserves_real_source_rejects_duration_and_invalid_media_before_adapter(self):
        response = self.client.post(DEVICE_UPLOAD_PATH, headers=self.headers,
            files={'file': ('recording.wav', wav_bytes(), 'audio/wav')})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()['source'], 'siliconflow')
        self.assertEqual(self.transcriber.calls, 1)
        for audio in (b'forged', wav_bytes(61)):
            rejected = self.client.post(DEVICE_UPLOAD_PATH, headers=self.headers,
                files={'file': ('recording.wav', audio, 'audio/wav')})
            self.assertEqual(rejected.status_code, 400)
        self.assertEqual(self.transcriber.calls, 1)
        self.assertEqual(list(Path(self.temp.name).glob('*.wav')), [])
        self.assertEqual(self.client.post(DEVICE_UPLOAD_PATH, files={
            'file': ('recording.wav', wav_bytes(), 'audio/wav')}).status_code, 401)

    def test_upload_capacity_is_not_released_until_actual_provider_finishes(self):
        speech = self.app.state.device_speech
        speech.reserve_upload(OWNER_A, 'ip-a')
        with self.assertRaises(AuthError): speech.reserve_upload(OWNER_A, 'ip-b')
        speech.reserve_upload(OWNER_B, 'ip-b')
        with self.assertRaises(AuthError): speech.reserve_upload(device_scope('c3' * 32), 'ip-c')
        with self.assertRaises(Exception): speech.transcribe(OWNER_A, b'bad', 'audio/wav')
        speech.reserve_upload(OWNER_A, 'ip-a')


class MergePreflightTests(unittest.TestCase):
    tearDown = DeviceWorkflowHttpTests.tearDown

    def setUp(self):
        DeviceWorkflowHttpTests.setUp(self)
        identity = self.client.post('/api/v1/auth/register', json={
            'username': 'isolated-merge', 'email': 'isolated-merge@example.test',
            'password': 'OnlySyntheticFixture123'}).json()
        self.account_headers = {'Authorization': 'Bearer ' + identity['token']}
        self.uid = identity['user']['id']
        initialized = self.client.put('/api/v1/workspace', headers=self.account_headers,
            json={'workspace': migrate_workspace(empty_workspace()), 'expectedRevision': 0})
        self.assertEqual(initialized.status_code, 200, initialized.text)
        self.cloud = initialized.json()['workspace']

    def snapshot(self):
        with self.app.state.accounts.connection() as db:
            return (list(map(tuple, db.execute('SELECT * FROM account_workspaces'))),
                    list(map(tuple, db.execute('SELECT * FROM sync_operations'))))

    def validate(self, candidate, *, headers=None, expected=None):
        return self.client.post('/api/v1/workspace/validate-merge',
            headers=self.account_headers if headers is None else headers,
            json={'workspace': candidate, 'expectedRevision': self.cloud['revision'] if expected is None else expected})

    def test_valid_merge_preflight_has_no_workspace_or_operation_writes(self):
        candidate = deepcopy(self.cloud)
        candidate['tasks'].append({'id': 'local-todo', 'title': 'Local todo', 'estimatedMinutes': 30})
        before = self.snapshot()
        response = self.validate(candidate)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json(), {'valid': True, 'revision': self.cloud['revision']})
        self.assertEqual(self.snapshot(), before)

    def test_overlap_and_unconfirmed_draft_reject_without_writes(self):
        before = self.snapshot()
        overlap = deepcopy(self.cloud)
        overlap['tasks'] = [{'id': 'local-task', 'title': 'Work', 'estimatedMinutes': 30}]
        overlap['entries'] = [
            {'id': 'work', 'title': 'Work', 'taskId': 'local-task',
             'start': '2030-11-08T14:00:00+08:00', 'end': '2030-11-08T14:30:00+08:00'},
            {'id': 'meeting', 'title': 'Meeting',
             'start': '2030-11-08T14:15:00+08:00', 'end': '2030-11-08T14:45:00+08:00'}]
        draft = deepcopy(self.cloud)
        draft['drafts'] = [{'id': 'unconfirmed-draft', 'status': 'committed', 'items': [],
            'goal': {'id': 'draft-goal', 'title': 'Goal', 'deadline': '2030-11-15T12:00:00Z'},
            'originalDailyBudget': 30, 'suggestedDailyBudget': 60, 'budgetOverrideConfirmed': False}]
        for candidate in (overlap, draft):
            response = self.validate(candidate)
            self.assertEqual(response.status_code, 400, response.text)
            self.assertEqual(response.json()['code'], 'invalid_merge')
            self.assertEqual(self.snapshot(), before)

    def test_stale_revision_device_capability_and_cookie_without_csrf_cannot_validate(self):
        before = self.snapshot()
        self.assertEqual(self.validate(self.cloud, expected=0).status_code, 409)
        self.assertEqual(self.validate(self.cloud, headers=self.headers).status_code, 401)
        login = self.client.post('/api/v1/auth/login', headers={'X-Sera-Client': 'web'}, json={
            'identifier': 'isolated-merge', 'password': 'OnlySyntheticFixture123'}).json()
        self.assertEqual(self.validate(self.cloud, headers=self.headers).status_code, 403)
        self.assertEqual(self.validate(self.cloud, headers={'X-CSRF-Token': login['csrfToken']}).status_code, 200)
        self.assertEqual(self.snapshot(), before)


if __name__ == '__main__': unittest.main()
