import copy
from http.client import HTTPConnection
import json
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from concurrent.futures import ThreadPoolExecutor

from server import ConflictError, ValidationError, WorkspaceStore, make_server


def empty_workspace():
    return {'schemaVersion': 1, 'revision': 0, 'tasks': [], 'entries': [], 'goals': [], 'drafts': [],
            'focusRecords': [], 'history': [], 'preferences': {'weekdays': [1, 2, 3, 4, 5],
            'dailyBudget': 90, 'bufferMinutes': 15, 'startMinute': 840, 'endMinute': 1020,
            'quietStart': 1320, 'quietEnd': 480, 'notifications': True, 'followUp': True}}


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / 'workspace.db'
        self.store = WorkspaceStore(self.path)

    def tearDown(self):
        self.temp.cleanup()

    def test_persists_and_rejects_stale_revision_without_overwriting(self):
        saved = self.store.save(empty_workspace(), 0)
        self.assertEqual(saved['revision'], 1)
        self.assertEqual(WorkspaceStore(self.path).load(), saved)
        with self.assertRaises(ConflictError):
            self.store.save(empty_workspace(), 0)
        self.assertEqual(self.store.load(), saved)

    def test_concurrent_writers_have_exactly_one_winner(self):
        def write(_):
            try:
                self.store.save(empty_workspace(), 0)
                return 'saved'
            except ConflictError:
                return 'conflict'
        with ThreadPoolExecutor(max_workers=6) as executor:
            outcomes = list(executor.map(write, range(6)))
        self.assertEqual(outcomes.count('saved'), 1)
        self.assertEqual(outcomes.count('conflict'), 5)
        self.assertEqual(self.store.load()['revision'], 1)

    def test_validation_rejects_orphan_entry_and_leaves_database_empty(self):
        workspace = empty_workspace()
        workspace['entries'] = [{'id': 'entry', 'title': 'Orphan', 'start': '2026-11-02T14:00:00',
                                 'end': '2026-11-02T14:30:00', 'taskId': 'missing'}]
        with self.assertRaises(ValidationError):
            self.store.save(workspace, 0)
        self.assertIsNone(self.store.load())

    def test_rejects_duplicate_and_invalid_fields(self):
        for mutate in (
            lambda w: w.update(schemaVersion=3),
            lambda w: w['preferences'].update(weekdays=[1, 1]),
            lambda w: w['preferences'].update(dailyBudget=True),
            lambda w: w['preferences'].update(endMinute=800),
        ):
            workspace = empty_workspace()
            mutate(workspace)
            with self.assertRaises(ValidationError):
                self.store.save(workspace, 0)


class HttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.server = make_server('127.0.0.1', 0, Path(cls.temp.name) / 'api.db')
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f'http://127.0.0.1:{cls.server.server_port}'
        with urlopen(Request(cls.base + '/api/v1/auth/register', data=json.dumps({'username': 'http-test', 'email': 'http@example.test', 'password': 'TestPassword123'}).encode(), method='POST'), timeout=3) as response:
            cls.authorization = 'Bearer ' + json.load(response)['token']

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=3)
        cls.temp.cleanup()

    def test_full_rest_cycle_and_visible_conflict(self):
        def request(method, body=None):
            encoded = None if body is None else json.dumps(body).encode()
            return urlopen(Request(self.base + '/api/v1/workspace', data=encoded, method=method,
                                   headers={'Content-Type': 'application/json', 'Authorization': self.authorization}), timeout=3)
        with request('DELETE') as response:
            self.assertEqual(response.status, 200)
        with request('GET') as response:
            self.assertIsNone(json.load(response)['workspace'])
        body = {'workspace': empty_workspace(), 'expectedRevision': 0}
        with request('PUT', body) as response:
            saved = json.load(response)['workspace']
            self.assertEqual(saved['revision'], 1)
            self.assertIsNone(response.headers.get('Access-Control-Allow-Origin'))
        with self.assertRaises(HTTPError) as caught:
            request('PUT', body)
        self.assertEqual(caught.exception.code, 409)
        self.assertEqual(json.load(caught.exception)['code'], 'revision_conflict')
        invalid = copy.deepcopy(saved)
        invalid['tasks'] = 'invalid'
        with self.assertRaises(HTTPError) as caught:
            request('PUT', {'workspace': invalid, 'expectedRevision': 1})
        self.assertEqual(caught.exception.code, 400)
        with request('GET') as response:
            self.assertEqual(json.load(response)['workspace'], saved)
        with request('OPTIONS') as response:
            self.assertEqual(response.status, 204)
        with request('DELETE') as response:
            self.assertIsNone(json.load(response)['workspace'])

    def test_invalid_json_and_body_limit(self):
        bad = Request(self.base + '/api/v1/workspace', data=b'{broken', method='PUT', headers={'Authorization': self.authorization})
        with self.assertRaises(HTTPError) as caught:
            urlopen(bad, timeout=3)
        self.assertEqual(caught.exception.code, 400)
        connection = HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
        connection.request('PUT', '/api/v1/workspace', body=b'', headers={'Content-Length': str(8 * 1024 * 1024 + 1), 'Authorization': self.authorization})
        response = connection.getresponse()
        self.assertEqual(response.status, 413)
        response.read()
        connection.close()

    def test_ai_missing_configuration_is_visible(self):
        goal = {'title': '课程报告', 'deadline': '2026-11-20T18:00:00', 'dailyBudget': 90}
        request = Request(self.base + '/api/v1/ai/plan', data=json.dumps(goal).encode(), method='POST', headers={'Authorization': self.authorization})
        with self.assertRaises(HTTPError) as caught:
            urlopen(request, timeout=3)
        self.assertEqual(caught.exception.code, 503)
        self.assertEqual(json.load(caught.exception)['code'], 'ai_not_configured')


class StaticTests(unittest.TestCase):
    def test_web_root_only_and_unknown_api_cannot_fallback_to_html(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            web = root / 'web'
            web.mkdir()
            (web / 'index.html').write_text('<html>Flutter entry</html>')
            (root / 'private.txt').write_text('not public')
            server = make_server('127.0.0.1', 0, root / 'api.db', web_dir=web)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = f'http://127.0.0.1:{server.server_port}'
            try:
                with urlopen(base + '/', timeout=3) as response:
                    self.assertIn(b'Flutter entry', response.read())
                for path in ('/%2e%2e/private.txt', '/api/v1/unknown', '/missing.js', '/%5c..%5cprivate.txt'):
                    with self.assertRaises(HTTPError) as caught:
                        urlopen(base + path, timeout=3)
                    self.assertEqual(caught.exception.code, 404)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=3)


class OriginTests(unittest.TestCase):
    def test_only_trusted_browser_origins_can_call_ai_and_preflight(self):
        class CountingPlanner:
            configured = True
            model = 'unit-model'
            calls = 0

            def generate(self, body):
                self.calls += 1
                return {'tasks': [], 'source': 'siliconflow', 'model': self.model}

        with tempfile.TemporaryDirectory() as directory:
            planner = CountingPlanner()
            server = make_server('127.0.0.1', 0, Path(directory) / 'api.db', ai_service=planner)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = f'http://127.0.0.1:{server.server_port}'
            payload = json.dumps({'title': '单位测试目标'}).encode()
            with urlopen(Request(base + '/api/v1/auth/register', data=json.dumps({'username': 'origin-test', 'email': 'origin@example.test', 'password': 'TestPassword123'}).encode(), method='POST'), timeout=3) as response:
                authorization = 'Bearer ' + json.load(response)['token']
            try:
                for origin in (base, 'http://localhost:4180', 'http://127.0.0.1:4180',
                               'http://localhost:4181', 'http://127.0.0.1:4181'):
                    request = Request(base + '/api/v1/ai/plan', data=payload, method='POST', headers={'Origin': origin, 'Authorization': authorization})
                    with urlopen(request, timeout=3) as response:
                        self.assertEqual(response.status, 200)
                        self.assertEqual(response.headers['Access-Control-Allow-Origin'], origin)
                        self.assertEqual(response.headers['Vary'], 'Origin')
                    preflight = Request(base + '/api/v1/ai/plan', method='OPTIONS', headers={'Origin': origin})
                    with urlopen(preflight, timeout=3) as response:
                        self.assertEqual(response.status, 204)
                        self.assertEqual(response.headers['Access-Control-Allow-Origin'], origin)
                trusted_calls = planner.calls
                for origin in ('https://untrusted.example', 'http://localhost:4999', 'null',
                               f'http://evil.example:{server.server_port}', 'http://localhost:4180.attacker.test'):
                    for method in ('POST', 'OPTIONS'):
                        request = Request(base + '/api/v1/ai/plan', method=method,
                                          # Origin is rejected from headers before body parsing.
                                          # Do not race a second TCP body write against that early
                                          # close: Windows can surface10053 instead of the403.
                                          data=b'' if method == 'POST' else None,
                                          headers={'Origin': origin})
                        with self.assertRaises(HTTPError) as caught:
                            urlopen(request, timeout=3)
                        self.assertEqual(caught.exception.code, 403)
                        self.assertIsNone(caught.exception.headers.get('Access-Control-Allow-Origin'))
                        self.assertEqual(json.load(caught.exception)['code'], 'origin_forbidden')
                self.assertEqual(planner.calls, trusted_calls)
                # A hostile matching Host/Origin cannot become trusted through
                # DNS rebinding, even though the TCP destination is loopback.
                connection = HTTPConnection('127.0.0.1', server.server_port, timeout=3)
                connection.request('POST', '/api/v1/ai/plan', body=payload,
                                   headers={'Host': f'evil.example:{server.server_port}',
                                            'Origin': f'http://evil.example:{server.server_port}'})
                response = connection.getresponse()
                self.assertEqual(response.status, 403)
                response.read()
                connection.close()
                self.assertEqual(planner.calls, trusted_calls)
                with urlopen(Request(base + '/api/v1/ai/plan', data=payload, method='POST', headers={'Authorization': authorization}), timeout=3) as response:
                    self.assertEqual(response.status, 200)
                    self.assertIsNone(response.headers.get('Access-Control-Allow-Origin'))
                self.assertEqual(planner.calls, trusted_calls + 1)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=3)


if __name__ == '__main__':
    unittest.main(verbosity=2)
