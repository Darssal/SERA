from email.parser import BytesParser
from contextlib import contextmanager
import os
from pathlib import Path
import socketserver
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from fastapi.testclient import TestClient
from app import create_app
from auth_store import AuthStore
from mail_service import MailService
from test_app import StubAi
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'deploy'))
from backup import backup, restore


@contextmanager
def local_smtp_sink():
    messages = []
    class Smtp(socketserver.StreamRequestHandler):
        def handle(self):
            self.wfile.write(b'220 localhost test SMTP\r\n')
            while line := self.rfile.readline():
                command = line.split(b' ', 1)[0].strip().upper()
                if command in (b'EHLO', b'HELO'): self.wfile.write(b'250 localhost\r\n')
                elif command == b'DATA':
                    self.wfile.write(b'354 End with dot\r\n')
                    payload = b''
                    while (chunk := self.rfile.readline()) not in (b'.\r\n', b''): payload += chunk
                    messages.append(BytesParser().parsebytes(payload))
                    self.wfile.write(b'250 accepted\r\n')
                elif command == b'QUIT': self.wfile.write(b'221 bye\r\n'); break
                else: self.wfile.write(b'250 ok\r\n')
    with socketserver.TCPServer(('127.0.0.1', 0), Smtp) as sink:
        worker = threading.Thread(target=sink.serve_forever, daemon=True)
        worker.start()
        try: yield sink.server_address[1], messages
        finally:
            sink.shutdown()
            worker.join(timeout=3)


class OperationsTests(unittest.TestCase):
    def test_consistent_online_backup_restore_keeps_identity_and_private_session_state(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            db = directory / 'original.sqlite3'
            app = create_app(db_path=db)
            session = app.state.accounts.register({'username': 'backup-user', 'email': 'backup@example.test', 'password': 'CorrectPassword123'})
            target = backup(db, directory / 'backup.zip')
            restored = restore(target, directory / 'restore')
            self.assertEqual(AuthStore(restored).authenticate(session['token'])['user']['id'], session['user']['id'])
            self.assertEqual(db.with_suffix('.session-secret').read_bytes(), restored.with_suffix('.session-secret').read_bytes())
            with self.assertRaises(ValueError): restore(target, directory / 'restore')
            with self.assertRaises(ValueError): backup(db, target)

    def test_smtp_transport_delivers_real_message_to_isolated_local_sink(self):
        with local_smtp_sink() as (port, messages):
            with patch.dict(os.environ, {'SMTP_HOST': '127.0.0.1', 'SMTP_PORT': str(port),
                'SMTP_FROM': 'sera@example.test', 'SMTP_TLS': 'none', 'SMTP_USERNAME': '', 'SERA_PUBLIC_ORIGIN': 'http://127.0.0.1:8787'}):
                MailService('unused', mode='smtp').send_action('recipient@example.test', 'verify', 'test-action-token')
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0]['To'], 'recipient@example.test')
        body = messages[0].get_payload(decode=True).decode('utf-8')
        self.assertIn('/#/verify-email?token=test-action-token', body)

    def test_api_smtp_verification_and_recovery_deliver_only_to_isolated_local_sink(self):
        with tempfile.TemporaryDirectory() as directory, local_smtp_sink() as (port, messages):
            with patch.dict(os.environ, {'SERA_MAIL_MODE': 'smtp', 'SMTP_HOST': '127.0.0.1',
                    'SMTP_PORT': str(port), 'SMTP_FROM': 'sera@example.test', 'SMTP_TLS': 'none',
                    'SMTP_USERNAME': '', 'SERA_PUBLIC_ORIGIN': 'https://sera.example.test'}):
                app = create_app(db_path=Path(directory) / 'smtp.db', ai_service=StubAi())
                with TestClient(app) as client:
                    registered = client.post('/api/v1/auth/register', json={'username': 'smtp-isolated',
                        'email': 'smtp-isolated@example.test', 'password': 'CorrectPassword123'}).json()
                    headers = {'Authorization': 'Bearer ' + registered['token']}
                    sent = client.post('/api/v1/auth/email/verification/request', headers=headers, json={})
                    self.assertEqual(sent.json()['deliveryStatus'], 'smtp_accepted')
                    self.assertFalse(sent.json()['developmentPreview'])
                    self.assertEqual(client.get('/api/v1/auth/development-mailbox', headers=headers).status_code, 403)
                    self.assertEqual(len(messages), 1)
                    def delivered_token(message):
                        text = message.get_payload(decode=True).decode('utf-8')
                        line = next(line for line in text.splitlines() if 'https://sera.example.test/' in line)
                        link = line[line.index('https://sera.example.test/'):].strip()
                        return parse_qs(urlsplit(link).fragment.partition('?')[2])['token'][0]
                    verified = client.post('/api/v1/auth/email/verification/confirm',
                        json={'token': delivered_token(messages[0])})
                    self.assertEqual(verified.json(), {'verified': True})
                    self.assertTrue(client.get('/api/v1/auth/me', headers=headers).json()['user']['emailVerified'])
                    accepted = client.post('/api/v1/auth/password/reset/request', json={'email': 'smtp-isolated@example.test'})
                    self.assertEqual(accepted.json()['deliveryStatus'], 'request_accepted')
                    self.assertEqual(len(messages), 2)
                    reset = client.post('/api/v1/auth/password/reset/confirm', json={
                        'token': delivered_token(messages[1]), 'password': 'NewCorrectPassword123'})
                    self.assertEqual(reset.json(), {'reset': True})
                    self.assertEqual(client.get('/api/v1/auth/me', headers=headers).status_code, 401)
                    recovered = client.post('/api/v1/auth/login', json={
                        'identifier': 'smtp-isolated@example.test', 'password': 'NewCorrectPassword123'})
                    self.assertEqual(recovered.status_code, 200)
                self.assertFalse((Path(directory) / 'mail').exists())
                self.assertEqual([message['To'] for message in messages], ['smtp-isolated@example.test'] * 2)


if __name__ == '__main__': unittest.main()
