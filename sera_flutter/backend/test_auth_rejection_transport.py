"""Raw HTTP authentication rejection remains bounded and delivers its 401."""
from email.message import Message
import http.client
import io
import json
from pathlib import Path
import socket
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from app import InMemorySocket
from auth_store import AuthStore
from server import (AUTH_REJECT_DRAIN_MAX_BYTES, AUTH_REJECT_DRAIN_SECONDS,
                    make_server)


class FakeAi:
    configured = True
    model = 'isolated-transport-test'
    calls = 0

    def generate(self, body):
        self.calls += 1
        return {'tasks': []}


class AuthRejectionTransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'transport.db'
        self.ai = FakeAi()
        self.server = make_server('127.0.0.1', 0, self.path, ai_service=self.ai)
        self.addCleanup(self.server.server_close)
        self.handler_type = self.server.RequestHandlerClass
        self.handler_type.log_message = lambda *args: None

    def start_server(self):
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 3)
        self.addCleanup(self.server.shutdown)
        return f'http://127.0.0.1:{self.server.server_port}'

    def isolated_handler(self, *lengths):
        local, peer = socket.socketpair()
        self.addCleanup(peer.close)
        self.addCleanup(local.close)
        handler = object.__new__(self.handler_type)
        handler.connection = local
        handler.headers = Message()
        for length in lengths:
            handler.headers['Content-Length'] = length
        handler.rfile = local.makefile('rb')
        self.addCleanup(handler.rfile.close)
        return handler, peer

    def test_delayed_body_still_receives_401_without_provider_calls(self):
        base = self.start_server()
        original_send = http.client.HTTPConnection.send
        for delay_ms in (1, 5, 20):
            def send(connection, data):
                if data == b'{}':
                    time.sleep(delay_ms / 1000)
                return original_send(connection, data)

            for attempt in range(10):
                with self.subTest(delay_ms=delay_ms, attempt=attempt):
                    with patch.object(http.client.HTTPConnection, 'send', send):
                        with self.assertRaises(HTTPError) as caught:
                            urlopen(Request(base + '/api/v1/ai/plan', data=b'{}',
                                            headers={'Content-Type': 'application/json'},
                                            method='POST'), timeout=2)
                        self.assertEqual(caught.exception.code, 401)
                        self.assertIn(b'authentication_required', caught.exception.read())
                        caught.exception.close()
        self.assertEqual(self.ai.calls, 0)

    def test_missing_zero_invalid_duplicate_or_oversized_length_never_reads(self):
        for lengths in ((), ('0',), ('-1',), ('+2',), ('2.0',), ('2,2',),
                        ('two',), ('2', '2'), ('2\t3',),
                        (str(AUTH_REJECT_DRAIN_MAX_BYTES + 1),), ('9' * 30,)):
            with self.subTest(lengths=lengths):
                handler, _ = self.isolated_handler(*lengths)
                reader = Mock()
                handler.rfile = reader
                handler.connection.settimeout(0.75)
                handler.discard_rejected_auth_body()
                reader.read1.assert_not_called()
                self.assertEqual(handler.connection.gettimeout(), 0.75)

    def test_transfer_encoding_never_drains_even_with_a_valid_length(self):
        handler, _ = self.isolated_handler('2')
        handler.headers['Transfer-Encoding'] = 'chunked'
        handler.rfile = Mock()
        handler.discard_rejected_auth_body()
        handler.rfile.read1.assert_not_called()

    def test_socket_timeout_is_restored_after_success_and_exact_length_is_respected(self):
        handler, peer = self.isolated_handler(str(AUTH_REJECT_DRAIN_MAX_BYTES))
        handler.connection.settimeout(0.75)
        payload = b'a' * AUTH_REJECT_DRAIN_MAX_BYTES + b'!'
        writer = threading.Thread(target=peer.sendall, args=(payload,), daemon=True)
        writer.start()
        handler.discard_rejected_auth_body()
        writer.join(timeout=1)
        self.assertFalse(writer.is_alive())
        self.assertEqual(handler.connection.gettimeout(), 0.75)
        self.assertEqual(handler.rfile.read(1), b'!')

    def test_missing_body_has_a_short_total_deadline_and_restores_timeout(self):
        handler, _ = self.isolated_handler('2')
        handler.connection.settimeout(0.75)
        started = time.monotonic()
        handler.discard_rejected_auth_body()
        elapsed = time.monotonic() - started
        self.assertGreaterEqual(elapsed, AUTH_REJECT_DRAIN_SECONDS * 0.7)
        self.assertLess(elapsed, 0.4)
        self.assertEqual(handler.connection.gettimeout(), 0.75)
        self.assertEqual(self.ai.calls, 0)
        print(json.dumps({'case': 'auth-reject-missing-body', 'elapsedMs': round(elapsed * 1000, 2),
                          'deadlineMs': AUTH_REJECT_DRAIN_SECONDS * 1000}))

    def test_slow_trickle_does_not_restart_the_total_deadline(self):
        handler, peer = self.isolated_handler('100')
        stop = threading.Event()

        def trickle():
            while not stop.wait(0.03):
                try:
                    peer.sendall(b'x')
                except OSError:
                    return

        writer = threading.Thread(target=trickle, daemon=True)
        writer.start()
        try:
            started = time.monotonic()
            handler.discard_rejected_auth_body()
            elapsed = time.monotonic() - started
            self.assertLess(elapsed, 0.4)
            self.assertIsNone(handler.connection.gettimeout())
            print(json.dumps({'case': 'auth-reject-slow-trickle', 'elapsedMs': round(elapsed * 1000, 2),
                              'deadlineMs': AUTH_REJECT_DRAIN_SECONDS * 1000}))
        finally:
            stop.set()
            writer.join(timeout=1)

    def test_body_already_read_by_read_json_is_not_read_again(self):
        handler, _ = self.isolated_handler('2')
        handler.rfile = io.BytesIO(b'{}')
        self.assertEqual(handler.read_json(), {})
        handler.rfile = Mock()
        handler.discard_rejected_auth_body()
        handler.rfile.read1.assert_not_called()

    def test_fastapi_in_memory_socket_is_not_touched(self):
        handler = object.__new__(self.handler_type)
        handler.connection = InMemorySocket(b'{}')
        handler.headers = Message()
        handler.headers['Content-Length'] = '2'
        handler.rfile = Mock()
        handler.discard_rejected_auth_body()
        handler.rfile.read1.assert_not_called()

    def test_successful_authentication_never_invokes_rejection_drain(self):
        session = AuthStore(self.path).register({'username': 'transport-user',
            'email': 'transport@example.test', 'password': 'SyntheticTransport123'})
        handler, _ = self.isolated_handler('2')
        handler.headers['Authorization'] = 'Bearer ' + session['token']
        handler.discard_rejected_auth_body = Mock(side_effect=AssertionError('Successful auth must not drain'))
        self.assertEqual(handler.session()['user']['id'], session['user']['id'])
        handler.discard_rejected_auth_body.assert_not_called()

    def test_no_body_http_request_receives_401(self):
        base = self.start_server()
        with self.assertRaises(HTTPError) as caught:
            urlopen(Request(base + '/api/v1/auth/me'), timeout=2)
        self.assertEqual(caught.exception.code, 401)
        caught.exception.close()

    def test_keep_alive_next_request_resets_the_body_read_marker(self):
        identity = AuthStore(self.path).register({'username': 'keepalive-user',
            'email': 'keepalive@example.test', 'password': 'SyntheticTransport123'})
        self.start_server()
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=2)
        self.addCleanup(connection.close)
        connection.request('POST', '/api/v1/ai/plan', body=b'{}',
                           headers={'Authorization': 'Bearer ' + identity['token']})
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        response.read()
        original_send = http.client.HTTPConnection.send

        def send(client, data):
            if data == b'{}':
                time.sleep(0.02)
            return original_send(client, data)

        with patch.object(http.client.HTTPConnection, 'send', send):
            connection.request('POST', '/api/v1/ai/plan', body=b'{}')
            rejected = connection.getresponse()
            self.assertEqual(rejected.status, 401)
            rejected.read()
        self.assertEqual(self.ai.calls, 1)


if __name__ == '__main__':
    unittest.main()
