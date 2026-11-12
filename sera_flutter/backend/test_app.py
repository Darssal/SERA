from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from fastapi.testclient import TestClient
from app import create_app
from test_server import empty_workspace
from worker import process_job, schedule_reminders, dispatch_pushes


class StubAi:
    configured = True
    model = 'stub-only-no-provider'
    calls = 0
    def generate(self, body):
        self.calls += 1
        return {'source': 'siliconflow', 'model': self.model, 'tasks': [
            {'title': body['title'], 'notes': 'stub task', 'estimatedMinutes': 30, 'checklist': ['verify']}]}


class AppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.ai = StubAi()
        self.app = create_app(db_path=Path(self.temp.name) / 'app.db', ai_service=self.ai)
        self.client = TestClient(self.app)
        self.client.__enter__()
        self.identity = self.client.post('/api/v1/auth/register', json={
            'username': 'account-a', 'email': 'account-a@example.test', 'password': 'CorrectPassword123'}).json()
        self.headers = {'Authorization': 'Bearer ' + self.identity['token']}

    def tearDown(self):
        self.client.__exit__(None, None, None)
        self.temp.cleanup()

    def init_workspace(self):
        response = self.client.put('/api/v1/workspace', headers=self.headers,
            json={'workspace': empty_workspace(), 'expectedRevision': 0})
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()['workspace']

    def subscription(self, suffix='test'):
        return {'endpoint': 'https://fcm.googleapis.com/push/' + suffix, 'keys': {
            'p256dh': self.client.get('/api/v1/push/config').json()['publicKey'],
            'auth': 'AAAAAAAAAAAAAAAAAAAAAA'}}

    def test_cookie_http_only_csrf_and_origin_before_provider(self):
        response = self.client.post('/api/v1/auth/login', headers={'X-Sera-Client': 'web'},
            json={'identifier': 'account-a', 'password': 'CorrectPassword123'})
        self.assertEqual(response.status_code, 200)
        self.assertIn('HttpOnly', response.headers['set-cookie'])
        self.assertEqual(response.json()['token'], '')
        csrf = response.json()['csrfToken']
        self.assertTrue(response.json()['sessionId'])
        self.assertEqual(self.client.post('/api/v1/auth/logout', json={}).status_code, 403)
        blocked = self.client.post('/api/v1/ai/plan', headers={'Origin': 'https://evil.example', 'X-CSRF-Token': csrf}, json={})
        self.assertEqual(blocked.status_code, 403)
        self.assertEqual(self.ai.calls, 0)
        self.assertEqual(self.client.get('/api/v1/auth/me').json()['csrfToken'], csrf)
        restored = self.client.get('/api/v1/auth/me', headers={'Authorization': 'Bearer '})
        self.assertEqual(restored.status_code, 200)
        self.assertEqual(restored.json()['sessionId'], response.json()['sessionId'])
        self.assertEqual(restored.json()['csrfToken'], csrf)
        self.assertNotIn('set-cookie', restored.headers)
        self.assertEqual(self.client.get('/api/v1/auth/me', headers={'Authorization': 'Bearer wrong-token'}).status_code, 401)
        self.assertEqual(self.client.post('/api/v1/auth/logout', headers={'X-CSRF-Token': csrf}, json={}).status_code, 200)
        self.assertEqual(self.client.get('/api/v1/auth/me').status_code, 401)

    def test_old_tab_csrf_cannot_read_new_cookie_account_or_erase_new_login(self):
        a = self.client.post('/api/v1/auth/login', headers={'X-Sera-Client':'web'},
            json={'identifier':'account-a','password':'CorrectPassword123'}).json()
        b_response = self.client.post('/api/v1/auth/register', headers={'X-Sera-Client':'web'},
            json={'username':'account-b','email':'other@example.test','password':'CorrectPassword123'})
        b = b_response.json()
        stale = self.client.get('/api/v1/workspace', headers={'X-CSRF-Token':a['csrfToken']})
        self.assertEqual(stale.status_code,401)
        self.assertEqual(stale.json()['code'],'account_changed')
        self.assertEqual(self.client.get('/api/v1/auth/me',headers={'X-CSRF-Token':b['csrfToken']}).json()['user']['id'],b['user']['id'])
        # The real SW sends no CSRF, then checks returned scope itself.
        validation=self.client.get('/api/v1/push/validate',params={'id':'old','generation':0})
        self.assertEqual(validation.status_code,200)
        self.assertEqual(validation.json(),{'valid':False,'scope':b['user']['id']})
        with TestClient(self.app) as native:
            extra_a=native.post('/api/v1/auth/login',json={'identifier':'account-a','password':'CorrectPassword123'}).json()['token']
        # Simulate an old native/tab request completing after another login:
        # successful revocation must not emit a cookie deletion for the new one.
        old_logout=self.client.post('/api/v1/auth/logout',headers=self.headers,json={})
        self.assertEqual(old_logout.status_code,200)
        self.assertNotIn('set-cookie',old_logout.headers)
        self.assertEqual(self.client.get('/api/v1/auth/me').json()['user']['id'],b['user']['id'])
        old_delete=self.client.request('DELETE','/api/v1/account',headers={'Authorization':'Bearer '+extra_a},
            json={'password':'CorrectPassword123'})
        self.assertEqual(old_delete.status_code,200)
        self.assertNotIn('set-cookie',old_delete.headers)
        self.assertEqual(self.client.get('/api/v1/auth/me').json()['user']['id'],b['user']['id'])

    def test_email_verification_reset_expiry_and_session_revocation(self):
        self.assertFalse(self.identity['user']['emailVerified'])
        self.assertEqual(self.client.post('/api/v1/auth/email/verification/request', headers=self.headers, json={}).status_code, 200)
        mail_path = next((Path(self.temp.name) / 'mail').glob('*.json'))
        mail = json.loads(mail_path.read_text(encoding='utf-8'))
        self.assertEqual(urlsplit(mail['link']).fragment.split('?', 1)[0], '/verify-email')
        action = parse_qs(urlsplit(mail['link']).fragment.split('?', 1)[1])['token'][0]
        self.assertEqual(self.client.post('/api/v1/auth/email/verification/confirm', json={'token': action}).status_code, 200)
        self.assertEqual(self.client.post('/api/v1/auth/email/verification/confirm', json={'token': action}).status_code, 400)
        self.assertTrue(self.client.get('/api/v1/auth/me', headers=self.headers).json()['user']['emailVerified'])
        self.client.post('/api/v1/auth/password/reset/request', json={'email': 'account-a@example.test'})
        self.client.post('/api/v1/push/subscriptions', headers=self.headers, json=self.subscription())
        messages = [json.loads(p.read_text(encoding='utf-8')) for p in (Path(self.temp.name) / 'mail').glob('*.json')]
        reset = next(m for m in messages if m['kind'] == 'reset')
        self.assertEqual(urlsplit(reset['link']).fragment.split('?', 1)[0], '/reset-password')
        token = parse_qs(urlsplit(reset['link']).fragment.split('?', 1)[1])['token'][0]
        result = self.client.post('/api/v1/auth/password/reset/confirm', json={'token': token, 'password': 'NewCorrectPassword123'})
        self.assertEqual(result.status_code, 200)
        self.assertEqual(self.client.get('/api/v1/auth/me', headers=self.headers).status_code, 401)
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM push_subscriptions').fetchone()[0], 0)
        self.assertEqual(self.client.post('/api/v1/auth/login', json={'identifier': 'account-a', 'password': 'CorrectPassword123'}).status_code, 401)
        self.assertEqual(self.client.post('/api/v1/auth/login', json={'identifier': 'account-a', 'password': 'NewCorrectPassword123'}).status_code, 200)

    def test_atomic_object_sync_idempotency_and_independent_singletons(self):
        workspace = self.init_workspace()
        self.assertEqual(workspace['schemaVersion'], 2)
        self.assertEqual(workspace['entityVersions']['preferences/singleton'], 1)
        one = {'id': 'op-a', 'entityType': 'tasks', 'entityId': 't-a', 'expectedVersion': 0,
               'action': 'upsert', 'value': {'id': 't-a', 'title': 'Task A'}}
        result = self.client.post('/api/v1/sync/operations', headers=self.headers, json={'operations': [one]})
        self.assertEqual(result.status_code, 200, result.text)
        revision = result.json()['workspace']['revision']
        replay = self.client.post('/api/v1/sync/operations', headers=self.headers, json={'operations': [one]}).json()
        self.assertEqual(replay['workspace']['revision'], revision)
        self.assertEqual(replay['replayed'], ['op-a'])
        independent = {'id': 'op-p', 'entityType': 'platformSettings', 'entityId': 'singleton',
            'expectedVersion': 1, 'action': 'upsert', 'value': {'calendarEnabled': True}}
        self.assertEqual(self.client.post('/api/v1/sync/operations', headers=self.headers, json={'operations': [independent]}).status_code, 200)
        stale = {**one, 'id': 'op-stale', 'value': {'id': 't-a', 'title': 'Overwrite'}}
        second = {**one, 'id': 'op-b', 'entityId': 't-b', 'value': {'id': 't-b', 'title': 'Task B'}}
        conflict = self.client.post('/api/v1/sync/operations', headers=self.headers, json={'operations': [second, stale]})
        self.assertEqual(conflict.status_code, 409)
        saved = self.client.get('/api/v1/workspace', headers=self.headers).json()['workspace']
        self.assertEqual([t['id'] for t in saved['tasks']], ['t-a'])

    def test_persistent_jobs_restart_result_and_cancel_no_provider(self):
        payload = {'title': 'Prepare course demo', 'dailyBudget': 90, 'deadline': '2026-11-20T18:00:00'}
        response = self.client.post('/api/v1/jobs', headers=self.headers, json={'kind': 'plan', 'input': payload, 'requestId': 'once'})
        self.assertEqual(response.status_code, 202)
        job = response.json()['job']
        self.assertEqual(job['status'], 'queued')
        self.assertEqual(self.client.post('/api/v1/jobs', headers=self.headers, json={'kind': 'plan', 'input': payload, 'requestId': 'once'}).json()['job']['id'], job['id'])
        different = self.client.post('/api/v1/jobs', headers=self.headers,
            json={'kind': 'plan', 'input': {**payload, 'title': 'Different'}, 'requestId': 'once'})
        self.assertEqual(different.status_code, 409)
        self.assertTrue(process_job(self.app.state.workflows, self.ai))
        done = self.client.get('/api/v1/jobs/' + job['id'], headers=self.headers).json()['job']
        self.assertEqual(done['status'], 'succeeded')
        self.assertEqual(done['result']['tasks'][0]['title'], payload['title'])
        second = self.client.post('/api/v1/jobs', headers=self.headers, json={'input': payload}).json()['job']
        self.client.post('/api/v1/jobs/' + second['id'] + '/cancel', headers=self.headers, json={})
        self.assertFalse(process_job(self.app.state.workflows, self.ai))
        self.assertEqual(self.ai.calls, 1)

    def test_ics_rrule_bounded_preview_and_push_real_send_contract(self):
        content = 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:meeting\r\nDTSTART;TZID=Asia/Hong_Kong:20261102T140000\r\nDTEND;TZID=Asia/Hong_Kong:20261102T150000\r\nRRULE:FREQ=DAILY;COUNT=3\r\nSUMMARY:Meeting\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n'
        response = self.client.post('/api/v1/calendar/ics/preview', headers=self.headers,
            json={'content': content, 'start': '2026-11-01T00:00:00+08:00', 'end': '2026-11-10T00:00:00+08:00'})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(len(response.json()['entries']), 3)
        subscription = self.subscription()
        self.assertEqual(self.client.post('/api/v1/push/subscriptions', headers=self.headers, json=subscription).status_code, 200)
        push = self.client.post('/api/v1/push/test', headers=self.headers, json={}).json()
        calls = []
        dispatch_pushes(self.app.state.workflows, self.app.state.sync, self.app.state.vapid_path, sender=lambda **kwargs: calls.append(kwargs))
        self.assertEqual(len(calls), 1)
        sent = json.loads(calls[0]['data'])
        self.assertEqual(sent['scope'], self.identity['user']['id'])
        self.assertEqual(sent['kind'], 'test')
        self.assertEqual(self.client.get('/api/v1/push/validate', params={'id': push['id'], 'generation': 0}, headers=self.headers).json()['valid'], True)

    def test_explicit_openapi_and_truthful_component_readiness(self):
        document = self.client.get('/openapi.json').json()
        self.assertNotIn('/{path}', document['paths'])
        registration = document['paths']['/api/v1/auth/register']['post']
        self.assertEqual(registration['requestBody']['content']['application/json']['schema']['$ref'], '#/components/schemas/RegisterRequest')
        self.assertIn('AuthSession', document['components']['schemas'])
        self.assertEqual(document['paths']['/api/v1/sync/operations']['post']['requestBody']['content']['application/json']['schema']['$ref'], '#/components/schemas/SyncBatch')
        self.assertEqual(self.client.get('/health').json()['schemaVersion'], 2)
        with patch('urllib.request.urlopen', side_effect=OSError('offline')):
            readiness = self.client.get('/health/ready')
        self.assertEqual(readiness.status_code, 503)
        self.assertEqual(readiness.json()['components']['database']['status'], 'ok')
        self.assertEqual(readiness.json()['components']['asr']['status'], 'unavailable')
        self.assertEqual(readiness.json()['components']['worker']['status'], 'unavailable')
        self.assertEqual(self.client.post('/api/v1/jobs', headers=self.headers, json=[]).status_code, 400)
        self.assertEqual(self.client.post('/api/v1/calendar/ics/preview', headers=self.headers, json={}).status_code, 400)

    def test_static_json_font_array_and_manifest_scalar_keep_exact_bytes(self):
        web = Path(self.temp.name) / 'web'
        (web / 'assets').mkdir(parents=True)
        (web / 'index.html').write_text('<html>Flutter</html>', encoding='utf-8')
        values = {'FontManifest.json': b'[{"family":"NotoSansSC","fonts":[{"asset":"font.otf"}]}]',
                  'AssetManifest.bin.json': b'"YWJjZA=="'}
        for filename, content in values.items(): (web / 'assets' / filename).write_bytes(content)
        with TestClient(create_app(db_path=Path(self.temp.name) / 'static.db', web_dir=web, ai_service=self.ai)) as client:
            for filename, content in values.items():
                response = client.get('/assets/' + filename)
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.content, content)
                self.assertIn('application/json', response.headers['content-type'])

    def test_asgi_multipart_replay_preserves_audio_for_validated_transcriber(self):
        from test_asr_service import wav_data
        calls = []
        class Transcriber:
            def transcribe(self, audio, filename, content_type):
                calls.append((audio, filename, content_type))
                return {'text': '真实上传流程的供应商测试桩', 'source': 'test-only'}
        with TestClient(create_app(db_path=Path(self.temp.name) / 'media.db', ai_service=self.ai,
                transcriber=Transcriber())) as client:
            auth = client.post('/api/v1/auth/register', json={'username': 'media-user',
                'email': 'media@example.test', 'password': 'CorrectPassword123'}).json()
            response = client.post('/api/v1/ai/transcribe', headers={'Authorization': 'Bearer ' + auth['token']},
                files={'file': ('voice.wav', wav_data(), 'audio/wav')})
            self.assertEqual(response.status_code, 200, response.text)
            self.assertEqual(calls, [(wav_data(), 'recording.wav', 'audio/wav')])
            self.assertEqual(client.post('/api/v1/ai/transcribe', headers={'Authorization': 'Bearer ' + auth['token']},
                files={'file': ('voice.wav', b'forged', 'audio/wav')}).status_code, 400)
            self.assertEqual(len(calls), 1)

    def test_large_sync_batch_tombstones_and_cross_account_cascade(self):
        self.init_workspace()
        operations = [{'id': f'bulk-{i}', 'entityType': 'tasks', 'entityId': f't-{i}',
            'expectedVersion': 0, 'action': 'upsert', 'value': {'id': f't-{i}', 'title': f'Task {i}'}} for i in range(501)]
        saved = self.client.post('/api/v1/sync/operations', headers=self.headers, json={'operations': operations})
        self.assertEqual(saved.status_code, 200, saved.text)
        delete = {'id': 'remove', 'entityType': 'tasks', 'entityId': 't-0', 'expectedVersion': 1, 'action': 'delete'}
        self.assertEqual(self.client.post('/api/v1/sync/operations', headers=self.headers, json={'operations': [delete]}).status_code, 200)
        self.assertEqual(self.client.post('/api/v1/sync/operations', headers=self.headers,
            json={'operations': [{**operations[0], 'id': 'stale-recreate'}]}).status_code, 409)
        other = self.client.post('/api/v1/auth/register', json={'username': 'account-b', 'email': 'b@example.test', 'password': 'CorrectPassword123'}).json()
        other_headers = {'Authorization': 'Bearer ' + other['token']}
        self.assertIsNone(self.client.get('/api/v1/workspace', headers=other_headers).json()['workspace'])
        job = self.client.post('/api/v1/jobs', headers=self.headers, json={'input': {
            'title': 'Private', 'dailyBudget': 90, 'deadline': '2026-11-20T18:00:00'}}).json()['job']
        self.assertEqual(self.client.get('/api/v1/jobs/' + job['id'], headers=other_headers).status_code, 404)
        self.client.post('/api/v1/asr/tickets', headers=self.headers, json={'sampleRate': 16000})
        self.client.post('/api/v1/push/subscriptions', headers=self.headers, json=self.subscription())
        self.client.post('/api/v1/push/test', headers=self.headers, json={})
        uid = self.identity['user']['id']
        self.assertEqual(self.client.request('DELETE', '/api/v1/account', headers=self.headers,
            json={'password': 'CorrectPassword123'}).status_code, 200)
        with self.app.state.accounts.connection() as db:
            for table in ('sessions', 'account_workspaces', 'jobs', 'push_subscriptions', 'push_deliveries', 'asr_tickets', 'sync_operations'):
                self.assertEqual(db.execute(f'SELECT count(*) FROM {table} WHERE user_id=?', (uid,)).fetchone()[0], 0)
        self.assertEqual(self.client.get('/api/v1/auth/me', headers=other_headers).status_code, 200)

    def test_push_valid_keys_missing_registration_and_logout_only_current_device(self):
        self.assertEqual(self.client.post('/api/v1/push/test', headers=self.headers, json={}).status_code, 409)
        malformed = self.subscription()
        malformed['keys'] = {'p256dh': 'unit-key-long-enough', 'auth': 'unit-auth-value'}
        self.assertEqual(self.client.post('/api/v1/push/subscriptions', headers=self.headers, json=malformed).status_code, 400)
        self.assertEqual(self.client.post('/api/v1/push/subscriptions', headers=self.headers, json=self.subscription('device-one')).status_code, 200)
        second = self.client.post('/api/v1/auth/login', json={'identifier': 'account-a', 'password': 'CorrectPassword123'}).json()
        second_headers = {'Authorization': 'Bearer ' + second['token']}
        self.assertEqual(self.client.post('/api/v1/push/subscriptions', headers=second_headers, json=self.subscription('device-two')).status_code, 200)
        self.assertEqual(self.client.post('/api/v1/auth/logout', headers=self.headers, json={}).status_code, 200)
        with self.app.state.accounts.connection() as db:
            endpoints = [row[0] for row in db.execute('SELECT endpoint FROM push_subscriptions')]
        self.assertEqual(endpoints, [self.subscription('device-two')['endpoint']])
        self.assertEqual(self.client.get('/api/v1/auth/me', headers=second_headers).status_code, 200)
        self.assertEqual(self.client.post('/api/v1/push/test', headers=second_headers, json={}).status_code, 202)
        with self.app.state.accounts.connection() as db: db.execute('UPDATE sessions SET expires_at=0')
        calls = []
        dispatch_pushes(self.app.state.workflows, self.app.state.sync, self.app.state.vapid_path, sender=lambda **kwargs: calls.append(kwargs))
        self.assertEqual(calls, [])
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM push_subscriptions').fetchone()[0], 0)

    def test_reminders_multiblock_ack_snooze_reschedule_and_canceled_task(self):
        workspace = self.init_workspace()
        workspace['preferences'].update(quietStart=0, quietEnd=0, timeZone='Asia/Hong_Kong')
        workspace['tasks'] = [{'id': 'task', 'title': 'Two blocks', 'reminderMinutes': 10, 'estimatedMinutes': 60, 'splittable': True}]
        workspace['entries'] = [{'id': 'one', 'taskId': 'task', 'title': 'First',
            'start': '2026-11-02T14:00:00+08:00', 'end': '2026-11-02T14:30:00+08:00'},
            {'id': 'two', 'taskId': 'task', 'title': 'Second',
            'start': '2026-11-02T16:00:00+08:00', 'end': '2026-11-02T16:30:00+08:00'}]
        def save():
            response = self.client.put('/api/v1/workspace', headers=self.headers,
                json={'workspace': workspace, 'expectedRevision': workspace['revision']})
            self.assertEqual(response.status_code, 200, response.text)
            workspace.update(response.json()['workspace'])
        def pending():
            with self.app.state.accounts.connection() as db:
                return [json.loads(row[0]) for row in db.execute("SELECT payload FROM push_deliveries WHERE status='pending'")]
        now = datetime(2026, 11, 1, tzinfo=timezone.utc).timestamp()
        save()
        schedule_reminders(self.app.state.workflows, self.app.state.sync, now)
        self.assertEqual(len(pending()), 4)
        workspace['preferences']['notifications'] = False
        save()
        schedule_reminders(self.app.state.workflows, self.app.state.sync, now)
        self.assertEqual(pending(), [])
        workspace['preferences']['notifications'] = True
        save()
        schedule_reminders(self.app.state.workflows, self.app.state.sync, now)
        self.assertEqual(len(pending()), 4)
        workspace['reminderStates'] = {
            'one:start': {'status': 'ack', 'at': '2026-11-02T13:50:00+08:00', 'scheduledAt': '2026-11-02T13:50:00+08:00'},
            'two:start': {'status': 'snoozed', 'at': '2026-11-02T15:50:00+08:00',
                'scheduledAt': '2026-11-02T15:50:00+08:00', 'snoozeUntil': '2026-11-02T15:55:00+08:00'}}
        save()
        schedule_reminders(self.app.state.workflows, self.app.state.sync, now)
        self.assertEqual(len(pending()), 3)
        snoozed = next(p for p in pending() if p['reminderId'] == 'two:start')
        self.assertEqual(snoozed['fireAt'], int(datetime.fromisoformat('2026-11-02T15:55:00+08:00').timestamp() * 1000))
        self.assertEqual(snoozed['timeZone'], 'Asia/Hong_Kong')
        workspace['entries'][0].update(start='2026-11-02T14:05:00+08:00', end='2026-11-02T14:35:00+08:00')
        save()
        schedule_reminders(self.app.state.workflows, self.app.state.sync, now)
        self.assertTrue(any(p['reminderId'] == 'one:start' for p in pending()))
        workspace['tasks'][0]['status'] = 'canceled'
        save()
        schedule_reminders(self.app.state.workflows, self.app.state.sync, now)
        self.assertEqual(pending(), [])


if __name__ == '__main__': unittest.main()
