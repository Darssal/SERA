"""Recovery contracts, token ownership and privacy against real isolated data."""
import hashlib
import json
import os
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import ssl
import tempfile
import time
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from fastapi.testclient import TestClient
from app import create_app
from auth_store import AuthError
from mail_service import MailService
from test_app import StubAi
from test_server import empty_workspace


class AccountRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.environment = patch.dict(os.environ, {'SERA_MAIL_MODE': 'local',
            'SERA_PUBLIC_ORIGIN': 'https://sera.example.test'})
        self.environment.start()
        self.db_path = Path(self.temp.name) / 'recovery.db'
        self.app = create_app(db_path=self.db_path, ai_service=StubAi())
        self.client = TestClient(self.app)
        self.client.__enter__()
        self.a = self.register('recovery-a')
        self.b = self.register('recovery-b')
        self.headers_a = {'Authorization': 'Bearer ' + self.a['token']}
        self.headers_b = {'Authorization': 'Bearer ' + self.b['token']}

    def tearDown(self):
        self.client.__exit__(None, None, None)
        self.environment.stop()
        self.temp.cleanup()

    def register(self, name):
        response = self.client.post('/api/v1/auth/register', json={'username': name,
            'email': name + '@example.test', 'password': 'CorrectPassword123'})
        self.assertEqual(response.status_code, 201)
        return response.json()

    def request_reset(self, email='recovery-a@example.test'):
        return self.client.post('/api/v1/auth/password/reset/request', json={'email': email})

    def action(self, kind='reset'):
        return self.app.state.accounts.create_email_action(kind=kind, uid=self.a['user']['id'])['token']

    def test_existing_unknown_and_account_throttled_reset_requests_are_identical(self):
        initial = self.request_reset()
        self.assertEqual(initial.status_code, 200)
        self.assertEqual(initial.headers['cache-control'], 'no-store')
        expected = initial.json()
        self.assertTrue(expected['accepted'])
        self.assertEqual(expected['deliveryMode'], 'local')
        self.assertEqual(expected['deliveryStatus'], 'request_accepted')
        self.assertFalse(expected['developmentPreview'])
        self.assertNotIn('sent', expected)
        self.assertNotIn('token', expected)
        self.assertIn('不会投递到外部收件箱', expected['message'])
        for _ in range(4):
            self.assertEqual(self.request_reset('RECOVERY-A@example.test').json(), expected)
        with self.assertLogs('app', level='WARNING') as records:
            self.assertEqual(self.request_reset().json(), expected)
        self.assertIn('mail_rate_limited', records.output[0])
        self.assertEqual(self.request_reset('unknown@example.test').json(), expected)
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM email_actions WHERE kind='reset'").fetchone()[0], 5)
        messages = list((Path(self.temp.name) / 'mail').glob('*.json'))
        self.assertEqual(len(messages), 5)

    def test_delivery_failures_and_bad_configuration_do_not_enumerate_accounts(self):
        for mode in ('local', 'smtp', 'mailpit'):
            self.app.state.mail.mode = mode
            with patch.object(self.app.state.mail, 'send_action', side_effect=AuthError(
                    'private SMTP details', 503, 'mail_delivery_failed')), self.assertLogs('app', level='WARNING') as logs:
                known = self.request_reset()
            unknown = self.request_reset('unknown@example.test')
            self.assertEqual(known.status_code, unknown.status_code)
            self.assertEqual(known.json(), unknown.json())
            self.assertNotIn('private SMTP details', known.text + ''.join(logs.output))
            self.assertFalse(known.json()['developmentPreview'])
        self.app.state.mail.mode = 'smtp'
        with patch.dict(os.environ, {'SMTP_HOST': '127.0.0.1', 'SMTP_FROM': 'sera@example.test',
                'SMTP_TLS': 'invalid'}), self.assertLogs('app', level='WARNING'):
            known = self.request_reset()
            unknown = self.request_reset('unknown@example.test')
            self.assertEqual(known.status_code, 200)
            self.assertEqual(known.json(), unknown.json())
            mail = self.client.get('/health/ready').json()['components']['mail']
            self.assertEqual(mail['status'], 'unavailable')

    def test_source_rate_limit_is_independent_of_account_and_expires(self):
        digest = hashlib.sha256(b'testclient').hexdigest()
        with self.app.state.accounts.connection() as db:
            db.executemany('INSERT INTO mail_request_limits VALUES(?,?)', [(digest, int(time.time()))] * 29)
        self.assertEqual(self.request_reset('unknown@example.test').status_code, 200)
        known, unknown = self.request_reset(), self.request_reset('unknown@example.test')
        self.assertEqual(known.status_code, 429)
        self.assertEqual(known.json(), unknown.json())
        self.assertEqual(known.json()['code'], 'reset_request_rate_limited')
        with self.app.state.accounts.connection() as db:
            db.execute('UPDATE mail_request_limits SET requested_at=?', (int(time.time()) - 901,))
        self.assertEqual(self.request_reset().status_code, 200)

    def test_wrong_logged_in_account_cannot_consume_verification_or_reset(self):
        for kind, route, extra in (
                ('verify', 'email/verification/confirm', {}),
                ('reset', 'password/reset/confirm', {'password': 'NewCorrectPassword123'})):
            token = self.action(kind)
            body = {'token': token, **extra}
            wrong = self.client.post('/api/v1/auth/' + route, headers=self.headers_b, json=body)
            self.assertEqual(wrong.status_code, 403)
            self.assertEqual(wrong.json()['code'], 'action_account_mismatch')
            correct = self.client.post('/api/v1/auth/' + route, headers=self.headers_a, json=body)
            self.assertEqual(correct.status_code, 200)
        self.assertFalse(self.client.get('/api/v1/auth/me', headers=self.headers_b).json()['user']['emailVerified'])
        self.assertEqual(self.client.get('/api/v1/auth/me', headers=self.headers_b).status_code, 200)

    def test_expired_used_wrong_kind_and_superseded_links_never_change_password(self):
        first = self.action()
        current = self.action()
        verification = self.action('verify')
        for token in (first, verification, 'malformed-token'):
            result = self.client.post('/api/v1/auth/password/reset/confirm',
                json={'token': token, 'password': 'NewCorrectPassword123'})
            self.assertEqual(result.status_code, 400)
            self.assertEqual(result.json()['code'], 'action_expired')
        weak = self.client.post('/api/v1/auth/password/reset/confirm', json={'token': current, 'password': 'short'})
        self.assertEqual(weak.status_code, 400)
        with self.app.state.accounts.connection() as db:
            db.execute('UPDATE email_actions SET expires_at=?', (int(time.time()) - 1,))
        for route, token, extra in (('password/reset/confirm', current, {'password': 'NewCorrectPassword123'}),
                                    ('email/verification/confirm', verification, {})):
            expired = self.client.post('/api/v1/auth/' + route, json={'token': token, **extra})
            self.assertEqual(expired.status_code, 400)
            self.assertEqual(expired.json()['code'], 'action_expired')
        self.assertEqual(self.client.post('/api/v1/auth/login', json={
            'identifier': 'recovery-a', 'password': 'CorrectPassword123'}).status_code, 200)

    def test_reset_revokes_all_own_sessions_preserves_workspace_and_other_account(self):
        extra_session = self.client.post('/api/v1/auth/login', json={
            'identifier': 'recovery-a', 'password': 'CorrectPassword123'}).json()
        workspace = empty_workspace()
        workspace['tasks'] = [{'id': 'preserved-task', 'title': 'Recovery must keep this task'}]
        saved = self.client.put('/api/v1/workspace', headers=self.headers_a,
            json={'workspace': workspace, 'expectedRevision': 0})
        self.assertEqual(saved.status_code, 200)
        token = self.action()
        weak = self.client.post('/api/v1/auth/password/reset/confirm', json={'token': token, 'password': 'short'})
        self.assertEqual(weak.status_code, 400)
        confirmed = self.client.post('/api/v1/auth/password/reset/confirm',
            json={'token': token, 'password': 'NewCorrectPassword123'})
        self.assertEqual(confirmed.json(), {'reset': True})
        for session in (self.a, extra_session):
            self.assertEqual(self.client.get('/api/v1/auth/me', headers={
                'Authorization': 'Bearer ' + session['token']}).status_code, 401)
        self.assertEqual(self.client.get('/api/v1/auth/me', headers=self.headers_b).status_code, 200)
        replay = self.client.post('/api/v1/auth/password/reset/confirm',
            json={'token': token, 'password': 'AnotherCorrectPassword123'})
        self.assertEqual(replay.status_code, 400)
        self.assertEqual(self.client.post('/api/v1/auth/login', json={
            'identifier': 'recovery-a', 'password': 'CorrectPassword123'}).status_code, 401)
        recovered = self.client.post('/api/v1/auth/login', json={
            'identifier': 'recovery-a@example.test', 'password': 'NewCorrectPassword123'}).json()
        restored = self.client.get('/api/v1/workspace', headers={
            'Authorization': 'Bearer ' + recovered['token']}).json()['workspace']
        self.assertEqual(restored['tasks'][0]['id'], 'preserved-task')

    def test_revoked_web_cookie_does_not_block_anonymous_email_actions(self):
        web_session = self.client.post('/api/v1/auth/login', headers={'X-Sera-Client': 'web'},
            json={'identifier': 'recovery-a', 'password': 'CorrectPassword123'}).json()
        self.client.post('/api/v1/auth/logout', headers={'X-CSRF-Token': web_session['csrfToken']}, json={})
        self.assertEqual(self.client.get('/api/v1/auth/me').status_code, 401)
        verification = self.action('verify')
        self.assertEqual(self.client.post('/api/v1/auth/email/verification/confirm',
            json={'token': verification}).status_code, 200)
        reset = self.action()
        self.assertEqual(self.client.post('/api/v1/auth/password/reset/confirm',
            json={'token': reset, 'password': 'NewCorrectPassword123'}).status_code, 200)

    def test_verified_send_is_idempotent_and_restart_keeps_real_verification_state(self):
        self.client.post('/api/v1/auth/email/verification/request', headers=self.headers_a, json={})
        preview = self.client.get('/api/v1/auth/development-mailbox', headers=self.headers_a).json()['mail']
        token = parse_qs(urlsplit(preview['verificationUrl']).fragment.partition('?')[2])['token'][0]
        with TestClient(create_app(db_path=self.db_path, ai_service=StubAi())) as restarted:
            self.assertEqual(restarted.get('/api/v1/auth/development-mailbox', headers=self.headers_a).json()['mail'], preview)
            self.assertEqual(restarted.post('/api/v1/auth/email/verification/confirm',
                headers=self.headers_a, json={'token': token}).json(), {'verified': True})
        response = self.client.post('/api/v1/auth/email/verification/request', headers=self.headers_a, json={})
        self.assertEqual(response.json()['deliveryStatus'], 'already_verified')
        self.assertFalse(response.json()['sent'])
        self.assertTrue(self.client.get('/api/v1/auth/me', headers=self.headers_a).json()['user']['emailVerified'])
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM email_actions WHERE kind='verify'").fetchone()[0], 1)

    def test_local_disk_failure_is_explicit_for_verification_and_generic_for_reset(self):
        with patch('mail_service.Path.write_text', side_effect=OSError('private disk path')):
            failed = self.client.post('/api/v1/auth/email/verification/request', headers=self.headers_a, json={})
            self.assertEqual(failed.status_code, 503)
            self.assertEqual(failed.json()['code'], 'mail_delivery_failed')
            self.assertNotIn('private disk path', failed.text)
            with self.assertLogs('app', level='WARNING'):
                known = self.request_reset()
            unknown = self.request_reset('unknown@example.test')
        self.assertEqual(known.status_code, 200)
        self.assertEqual(known.json(), unknown.json())

    def test_malformed_email_is_rejected_before_any_delivery(self):
        with patch.object(self.app.state.mail, 'send_action') as send:
            for value in (None, '', 'missing-at', 'a@b', 'a\nb@example.test', 'a,b@example.test',
                          'name<target@example.test>', ['a@example.test']):
                self.assertEqual(self.request_reset(value).status_code, 400)
        send.assert_not_called()

    def test_registration_rejects_address_lists_before_creating_an_account(self):
        for email in ('a,b@example.test', 'name<target@example.test>', 'a@example.test\r\nBcc:other@example.test'):
            response = self.client.post('/api/v1/auth/register', json={
                'username': 'unsafe-mail', 'email': email, 'password': 'CorrectPassword123'})
            self.assertEqual(response.status_code, 400)
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM users').fetchone()[0], 2)

    def test_concurrent_reset_confirmation_consumes_token_exactly_once(self):
        token = self.action()
        def confirm():
            try:
                self.app.state.accounts.confirm_email_action(token=token, kind='reset', password='NewCorrectPassword123')
                return 'reset'
            except AuthError as error:
                return error.code
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: confirm(), range(2)))
        self.assertCountEqual(results, ['reset', 'action_expired'])
        self.assertEqual(self.client.post('/api/v1/auth/login', json={
            'identifier': 'recovery-a', 'password': 'NewCorrectPassword123'}).status_code, 200)


class MailTransportConfigurationTests(unittest.TestCase):
    def test_tls_modes_require_verified_context_and_invalid_config_never_connects(self):
        with patch.dict(os.environ, {'SMTP_HOST': 'smtp.example.test', 'SMTP_PORT': '587',
                'SMTP_FROM': 'sera@example.test', 'SMTP_USERNAME': '', 'SMTP_TLS': 'starttls'}):
            with patch('mail_service.smtplib.SMTP') as smtp:
                MailService('unused', mode='smtp').send_action('recipient@example.test', 'verify', 'test-token')
                context = smtp.return_value.__enter__.return_value.starttls.call_args.kwargs['context']
                self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
                self.assertTrue(context.check_hostname)
            with patch.dict(os.environ, {'SMTP_TLS': 'ssl'}), patch('mail_service.smtplib.SMTP_SSL') as smtp_ssl:
                MailService('unused', mode='smtp').send_action('recipient@example.test', 'reset', 'test-token')
                context = smtp_ssl.call_args.kwargs['context']
                self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
                self.assertTrue(context.check_hostname)
            with patch('mail_service.smtplib.SMTP') as smtp:
                for change in ({'SMTP_TLS': 'none'}, {'SMTP_TLS': 'invalid'}, {'SMTP_PORT': '65536'},
                               {'SMTP_FROM': ''}, {'SMTP_USERNAME': 'user', 'SMTP_PASSWORD': ''}):
                    with patch.dict(os.environ, change), self.assertRaises(AuthError) as raised:
                        MailService('unused', mode='smtp').send_action('recipient@example.test', 'verify', 'test-token')
                    self.assertEqual(raised.exception.code, 'mail_configuration_error')
                smtp.assert_not_called()


if __name__ == '__main__': unittest.main(verbosity=2)
