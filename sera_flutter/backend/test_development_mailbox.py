"""Authenticated development verification preview; never an anonymous password mailbox."""
import json
import os
from pathlib import Path
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


class DevelopmentMailboxTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.environment = patch.dict(os.environ, {'SERA_MAIL_MODE': 'local', 'SERA_PUBLIC_ORIGIN': 'https://sera.example.test'})
        self.environment.start()
        self.app = create_app(db_path=Path(self.temp.name) / 'mailbox.db', ai_service=StubAi())
        self.client = TestClient(self.app)
        self.client.__enter__()
        self.a = self.register('mailbox-a')
        self.b = self.register('mailbox-b')
        self.headers = {'Authorization': 'Bearer ' + self.a['token']}
    def register(self, name):
        return self.client.post('/api/v1/auth/register', json={'username': name,
            'email': name + '@example.test', 'password': 'CorrectPassword123'}).json()
    def tearDown(self):
        self.client.__exit__(None, None, None)
        self.environment.stop()
        self.temp.cleanup()
    def send_verification(self, headers=None):
        result = self.client.post('/api/v1/auth/email/verification/request', headers=headers or self.headers, json={})
        self.assertEqual(result.status_code, 200)
        return result
    def preview(self, headers=None, query='purpose=verify-email'):
        return self.client.get('/api/v1/auth/development-mailbox?' + query, headers=headers or self.headers)
    @staticmethod
    def token(mail):
        return parse_qs(urlsplit(mail['verificationUrl']).fragment.split('?', 1)[1])['token'][0]

    def test_real_local_send_preview_resend_verify_and_no_store(self):
        sent = self.send_verification().json()
        self.assertEqual(sent['deliveryMode'], 'local')
        self.assertEqual(sent['deliveryStatus'], 'development_only')
        self.assertTrue(sent['developmentPreview'])
        self.assertIn('未投递', sent['message'])
        preview = self.preview()
        self.assertEqual(preview.headers['cache-control'], 'no-store')
        first = preview.json()['mail']
        self.assertEqual(set(first), {'subject', 'verificationUrl', 'expiresAt'})
        self.assertTrue(first['verificationUrl'].startswith('https://sera.example.test/#/verify-email?token='))
        self.send_verification()
        current = self.preview().json()['mail']
        self.assertNotEqual(self.token(first), self.token(current))
        self.assertEqual(self.client.post('/api/v1/auth/email/verification/confirm', json={'token': self.token(first)}).status_code, 400)
        self.assertEqual(self.client.post('/api/v1/auth/email/verification/confirm', json={'token': self.token(current)}).status_code, 200)
        self.assertIsNone(self.preview().json()['mail'])
        self.assertTrue(self.client.get('/api/v1/auth/me', headers=self.headers).json()['user']['emailVerified'])

    def test_authenticated_own_recipient_only_and_expired_token_hidden(self):
        self.send_verification()
        own = self.preview().json()['mail']
        other = {'Authorization': 'Bearer ' + self.b['token']}
        result = self.preview(other, 'purpose=verify-email&email=mailbox-a@example.test&userId=' + self.a['user']['id'])
        self.assertIsNone(result.json()['mail'])
        self.assertNotIn(self.token(own), result.text)
        self.assertNotIn('mailbox-a@example.test', result.text)
        with self.app.state.accounts.connection() as db:
            db.execute('UPDATE email_actions SET expires_at=?', (int(time.time()) - 1,))
        self.assertIsNone(self.preview().json()['mail'])

    def test_no_anonymous_or_reset_preview_and_reset_spool_is_ignored(self):
        anonymous = self.client.get('/api/v1/auth/development-mailbox?purpose=verify-email')
        self.assertEqual(anonymous.status_code, 401)
        self.assertEqual(self.preview(query='purpose=reset-password').status_code, 400)
        action = self.app.state.accounts.create_email_action(kind='reset', uid=self.a['user']['id'])
        self.app.state.mail.send_action(action['email'], 'reset', action['token'])
        value = self.preview()
        self.assertIsNone(value.json()['mail'])
        self.assertNotIn(action['token'], value.text)

    def test_spool_recipient_and_action_are_both_required_and_link_origin_is_reconstructed(self):
        self.send_verification()
        path = next((Path(self.temp.name) / 'mail').glob('*.json'))
        value = json.loads(path.read_text(encoding='utf-8'))
        value['to'] = self.b['user']['email']
        path.write_text(json.dumps(value), encoding='utf-8')
        self.assertIsNone(self.preview().json()['mail'])
        # B's recipient match cannot grant B access to a token owned by A.
        self.assertIsNone(self.preview({'Authorization': 'Bearer ' + self.b['token']}).json()['mail'])
        value['to'] = self.a['user']['email']
        value['link'] = value['link'].replace('https://sera.example.test', 'https://evil.example')
        path.write_text(json.dumps(value), encoding='utf-8')
        self.assertTrue(self.preview().json()['mail']['verificationUrl'].startswith('https://sera.example.test/'))
        (path.parent / 'malformed.json').write_text('[]', encoding='utf-8')
        (path.parent / 'oversized.json').write_text('x' * 70000, encoding='utf-8')
        self.assertEqual(self.preview().status_code, 200)

    def test_smtp_and_mailpit_never_expose_existing_local_tokens(self):
        self.send_verification()
        existing = self.token(self.preview().json()['mail'])
        for mode in ('smtp', 'mailpit'):
            self.app.state.mail.mode = mode
            response = self.preview()
            self.assertEqual(response.status_code, 403)
            self.assertEqual(response.json()['code'], 'development_mailbox_disabled')
            self.assertNotIn(existing, response.text)

    def test_send_failure_is_explicit_and_origin_configuration_cannot_use_request_host(self):
        self.app.state.mail.mode = 'smtp'
        with patch('mail_service.smtplib.SMTP', side_effect=OSError('private upstream message')):
            response = self.client.post('/api/v1/auth/email/verification/request', headers=self.headers, json={})
        self.assertEqual(response.status_code, 503)
        self.assertNotIn('private upstream message', response.text)
        self.assertNotIn('sent', response.json())
        schema = self.client.get('/openapi.json').json()
        self.assertIn('/api/v1/auth/development-mailbox', schema['paths'])
        for origin in ('https://user:password@sera.example.test', 'https://sera.example.test/unsafe',
                       'https://sera.example.test/#/fake', 'http://remote.example.test', 'https://sera.example.test:99999'):
            with patch.dict(os.environ, {'SERA_PUBLIC_ORIGIN': origin}), self.assertRaises(AuthError):
                MailService.public_origin()

    @patch('mail_service.smtplib.SMTP')
    def test_bad_tls_or_port_fails_before_plaintext_connection(self, smtp):
        for config in ({'SMTP_TLS': 'invalid', 'SMTP_PORT': '587'}, {'SMTP_TLS': 'none', 'SMTP_PORT': 'not-a-port'},
                       {'SMTP_TLS': 'none', 'SMTP_PORT': '0'}):
            with patch.dict(os.environ, {'SMTP_HOST': '127.0.0.1', 'SMTP_FROM': 'sera@example.test', **config}), self.assertRaises(AuthError):
                MailService('unused', mode='smtp').send_action('mailbox-a@example.test', 'verify', 'fake-token')
        smtp.assert_not_called()


if __name__ == '__main__': unittest.main(verbosity=2)
