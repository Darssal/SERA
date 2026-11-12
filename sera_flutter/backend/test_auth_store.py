import hashlib
import json
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from auth_store import AuthError, AuthStore
from server import WorkspaceStore, make_server
from test_server import empty_workspace


class AuthStoreTests(unittest.TestCase):
    def test_hashes_password_and_token_expiry_logout_and_duplicate_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            store = AuthStore(Path(directory) / 'auth.db')
            session = store.register({'username': 'alice', 'email': 'alice@example.test', 'password': 'CorrectPassword123'})
            with store.connection() as db:
                row = db.execute('SELECT * FROM users').fetchone()
                self.assertNotEqual(row['password_hash'], b'CorrectPassword123')
                self.assertEqual(len(row['salt']), 16)
                self.assertEqual(db.execute('SELECT token_hash FROM sessions').fetchone()[0], hashlib.sha256(session['token'].encode()).hexdigest())
            self.assertEqual(store.login({'identifier': 'ALICE@example.test', 'password': 'CorrectPassword123'})['user'], session['user'])
            with self.assertRaises(AuthError):
                store.login({'identifier': 'alice', 'password': 'wrong'})
            with self.assertRaises(AuthError):
                store.register({'username': 'alice', 'email': 'another@example.test', 'password': 'CorrectPassword123'})
            store.logout(session['token'])
            with self.assertRaises(AuthError):
                store.authenticate(session['token'])
            fresh = store.login({'identifier': 'alice', 'password': 'CorrectPassword123'})
            with store.connection() as db:
                db.execute('UPDATE sessions SET expires_at=0')
            with self.assertRaises(AuthError):
                store.authenticate(fresh['token'])

    def test_account_http_isolation_guest_import_export_and_account_deletion(self):
        class FakeAi:
            configured = True
            model = 'unit'
            calls = 0
            def generate(self, body):
                self.calls += 1
                return {'tasks': [], 'model': self.model, 'source': 'siliconflow'}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'users.db'
            legacy = WorkspaceStore(path)
            old = legacy.save(empty_workspace(), 0)
            ai = FakeAi()
            server = make_server('127.0.0.1', 0, path, ai_service=ai)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = f'http://127.0.0.1:{server.server_port}'
            def request(method, route, data=None, token=None):
                headers = {'Content-Type': 'application/json'}
                if token: headers['Authorization'] = 'Bearer ' + token
                with urlopen(Request(base + route, method=method, headers=headers,
                    data=json.dumps(data).encode() if data is not None else None), timeout=4) as response:
                    return json.load(response)
            try:
                with self.assertRaises(HTTPError) as caught:
                    request('POST', '/api/v1/ai/plan', {})
                self.assertEqual(caught.exception.code, 401)
                self.assertEqual(ai.calls, 0)
                a = request('POST', '/api/v1/auth/register', {'username': 'alice', 'email': 'alice@example.test', 'password': 'CorrectPassword123'})
                b = request('POST', '/api/v1/auth/register', {'username': 'bob', 'email': 'bob@example.test', 'password': 'CorrectPassword123'})
                self.assertIsNone(request('GET', '/api/v1/workspace', token=a['token'])['workspace'])
                self.assertIsNone(request('GET', '/api/v1/workspace', token=b['token'])['workspace'])
                self.assertEqual(request('GET', '/api/v1/guest-workspace', token=a['token'])['workspace'], old)
                imported = request('POST', '/api/v1/workspace/import-guest', {'workspace': old, 'expectedRevision': 0}, a['token'])['workspace']
                self.assertEqual(imported['revision'], 1)
                self.assertIsNone(request('GET', '/api/v1/workspace', token=b['token'])['workspace'])
                self.assertEqual(legacy.load(), old)
                request('PUT', '/api/v1/workspace', {'workspace': empty_workspace(), 'expectedRevision': 0}, b['token'])
                request('DELETE', '/api/v1/workspace', token=b['token'])
                self.assertEqual(request('GET', '/api/v1/workspace', token=a['token'])['workspace'], imported)
                exported = request('GET', '/api/v1/account/export', token=a['token'])
                self.assertEqual(exported['user']['id'], a['user']['id'])
                self.assertNotIn('password', json.dumps(exported))
                request('DELETE', '/api/v1/account', {'password': 'CorrectPassword123'}, a['token'])
                with self.assertRaises(HTTPError) as caught:
                    request('GET', '/api/v1/auth/me', token=a['token'])
                self.assertEqual(caught.exception.code, 401)
                self.assertEqual(request('GET', '/api/v1/auth/me', token=b['token'])['user']['id'], b['user']['id'])
                self.assertEqual(legacy.load(), old)
                with AuthStore(path).connection() as db:
                    self.assertIsNone(db.execute('SELECT * FROM account_workspaces WHERE user_id=?', (a['user']['id'],)).fetchone())
            finally:
                server.shutdown(); server.server_close(); thread.join(timeout=3)


if __name__ == '__main__':
    unittest.main()
