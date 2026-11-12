"""No-network tests for anonymous body reception and capability log redaction."""
import asyncio
import io
import logging
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

from starlette.requests import ClientDisconnect

from auth_store import AuthError
from guest_workflows import (DEVICE_ASR_PATH, DEVICE_JOB_PATH, DEVICE_UPLOAD_PATH,
                             DeviceBodyGate, device_body_limit, read_device_body)
from local_asr import (AsrTicketLogFilter, asr_log_config,
                       install_asr_log_filters)


class FakeRequest:
    def __init__(self, stream, *, path=DEVICE_JOB_PATH, headers=None, ip='unit-ip'):
        self.url = SimpleNamespace(path=path)
        self.client = SimpleNamespace(host=ip)
        self.headers = headers or {}
        self.stream = stream


class DeviceReceptionTests(unittest.IsolatedAsyncioTestCase):
    async def test_middleware_bounds_chunked_get_head_even_on_unmatched_device_paths(self):
        from app import create_app
        with tempfile.TemporaryDirectory() as directory:
            app = create_app(db_path=Path(directory) / 'bounded-read.db',
                ai_service=SimpleNamespace(configured=True, model='no-provider-called'),
                transcriber=SimpleNamespace(), sms_service=SimpleNamespace())
            try:
                for method in ('GET', 'HEAD'):
                    messages, reads = [], []
                    async def receive():
                        reads.append(True)
                        if len(reads) == 1:
                            return {'type': 'http.request', 'body': bytes(4096), 'more_body': True}
                        if len(reads) == 2:
                            return {'type': 'http.request', 'body': b'x', 'more_body': True}
                        self.fail('middleware read beyond the device byte limit')
                    async def send(message): messages.append(message)
                    path = DEVICE_JOB_PATH + '/unmatched/route'
                    await app({'type': 'http', 'asgi': {'version': '3.0', 'spec_version': '2.4'},
                        'http_version': '1.1', 'method': method, 'scheme': 'http',
                        'path': path, 'raw_path': path.encode(), 'query_string': b'',
                        'headers': [(b'host', b'127.0.0.1:8787'), (b'x-sera-device', b'a1' * 32)],
                        'client': ('unit-ip', 1234), 'server': ('127.0.0.1', 8787)}, receive, send)
                    self.assertEqual(next(m['status'] for m in messages if m['type'] == 'http.response.start'), 413)
                    self.assertEqual(len(reads), 2)
                    self.assertEqual(app.state.device_body_gate._active, 0)
            finally:
                await app.state.device_jobs.close()

    async def test_declared_endpoint_limits_reject_before_first_receive(self):
        for path, limit in ((DEVICE_JOB_PATH, 65536), (DEVICE_ASR_PATH, 4096),
                            (DEVICE_JOB_PATH + '/opaque/cancel', 4096),
                            (DEVICE_UPLOAD_PATH, 11 * 1024 * 1024)):
            self.assertEqual(device_body_limit(path), limit)
            touched = []
            async def stream():
                touched.append(True)
                yield b'{}'
            gate = DeviceBodyGate()
            request = FakeRequest(stream, path=path, headers={'content-length': str(limit + 1)})
            with self.assertRaises(AuthError) as denied:
                await read_device_body(request, gate)
            self.assertEqual(denied.exception.status, 413)
            self.assertEqual(touched, [])
            self.assertEqual((gate._active, gate._ips), (0, {}))

    async def test_unknown_length_and_underreported_body_stop_at_limit_and_release(self):
        for headers in ({}, {'content-length': '1'}):
            touched = []
            async def stream():
                touched.append(1)
                yield b'a' * 4096
                touched.append(2)
                yield b'b'
                touched.append(3)
                yield b'not-read'
            gate = DeviceBodyGate()
            with self.assertRaises(AuthError) as denied:
                await read_device_body(FakeRequest(stream, path=DEVICE_ASR_PATH, headers=headers), gate)
            self.assertEqual(denied.exception.status, 413)
            self.assertEqual(touched, [1, 2])
            self.assertEqual((gate._active, gate._ips), (0, {}))

    async def test_total_body_timeout_releases_slot(self):
        wait = asyncio.Event()
        async def stream():
            yield b'{'  # Activity does not reset the overall reception budget.
            await wait.wait()
            yield b'}'
        gate = DeviceBodyGate(timeout=.02)
        with self.assertRaises(AuthError) as denied:
            await read_device_body(FakeRequest(stream), gate)
        self.assertEqual(denied.exception.code, 'device_body_timeout')
        self.assertEqual((gate._active, gate._ips), (0, {}))

    async def test_disconnect_exception_and_cancellation_release_slot(self):
        gate = DeviceBodyGate()
        for error in (ClientDisconnect(), RuntimeError('synthetic receive failure')):
            async def stream():
                yield b'part'
                raise error
            expected = AuthError if isinstance(error, ClientDisconnect) else RuntimeError
            with self.assertRaises(expected):
                await read_device_body(FakeRequest(stream), gate)
            self.assertEqual((gate._active, gate._ips), (0, {}))
        began, release = asyncio.Event(), asyncio.Event()
        async def canceled_stream():
            began.set()
            await release.wait()
            yield b'{}'
        task = asyncio.create_task(read_device_body(FakeRequest(canceled_stream), gate))
        await began.wait()
        task.cancel()
        with self.assertRaises(asyncio.CancelledError): await task
        self.assertEqual((gate._active, gate._ips), (0, {}))

    async def test_global_and_ip_reception_limits_reject_without_reading_and_recover(self):
        gate = DeviceBodyGate(global_limit=2, ip_limit=1)
        release, began_a, began_b = asyncio.Event(), asyncio.Event(), asyncio.Event()
        async def stream_a():
            began_a.set()
            await release.wait()
            yield b'a'
        async def stream_b():
            began_b.set()
            await release.wait()
            yield b'b'
        tasks = [asyncio.create_task(read_device_body(FakeRequest(stream_a, ip='a'), gate))]
        await began_a.wait()
        touched = []
        async def rejected_stream():
            touched.append(True)
            yield b'not-read'
        try:
            with self.assertRaises(AuthError):
                await read_device_body(FakeRequest(rejected_stream, ip='a'), gate)
            tasks.append(asyncio.create_task(read_device_body(FakeRequest(stream_b, ip='b'), gate)))
            await began_b.wait()
            with self.assertRaises(AuthError):
                await read_device_body(FakeRequest(rejected_stream, ip='c'), gate)
            self.assertEqual(touched, [])
        finally:
            release.set()
            await asyncio.gather(*tasks)
        self.assertEqual((gate._active, gate._ips), (0, {}))
        self.assertEqual(await read_device_body(FakeRequest(rejected_stream, ip='a'), gate), b'not-read')


class AsrLogBoundaryTests(unittest.TestCase):
    def test_actual_uvicorn_access_formatter_preserves_tuple_and_redacts_only_path(self):
        from uvicorn.logging import AccessFormatter
        fixture = 'synthetic-ticket-value-not-a-real-capability'
        formatter = AccessFormatter(fmt='%(client_addr)s - "%(request_line)s" %(status_code)s', use_colors=False)
        redactor = AsrTicketLogFilter()
        for path in ('/health', '/ws?ticket=' + fixture, '/ws?%74icket=' + fixture):
            record = logging.LogRecord('uvicorn.access', logging.INFO, __file__, 1,
                '%s - "%s %s HTTP/%s" %d', ('unit-peer', 'GET', path, '1.1', 200), None)
            redactor.filter(record)
            # Both logger and handler may filter the same record.
            redactor.filter(record)
            self.assertEqual(len(record.args), 5)
            self.assertEqual(record.args[:2], ('unit-peer', 'GET'))
            self.assertEqual(record.args[3:], ('1.1', 200))
            rendered = formatter.format(record)
            self.assertNotIn(fixture, rendered)
            self.assertIn('200 OK', rendered)
            self.assertIn('/health' if path == '/health' else '/ws?[redacted]', rendered)

    def test_actual_handshake_info_and_rejection_keep_info_without_ticket_values(self):
        fixture = 'synthetic-ticket-value-not-a-real-capability'
        logger = logging.getLogger('uvicorn.error')
        previous = (list(logger.handlers), list(logger.filters), logger.level, logger.propagate)
        output = io.StringIO()
        handler = logging.StreamHandler(output)
        handler.setFormatter(logging.Formatter('%(levelname)s %(message)s'))
        try:
            logger.handlers, logger.filters, logger.propagate = [handler], [], False
            logger.setLevel(logging.INFO)
            install_asr_log_filters()
            logger.info('%s - "WebSocket %s" [accepted]', 'unit-peer', '/ws?ticket=' + fixture)
            logger.info('%s - "WebSocket %s" 403', 'unit-peer', '/ws?%74icket=' + fixture + '&other=value')
            logger.info('Started server process [%d]', 123)
            text = output.getvalue()
            self.assertNotIn(fixture, text)
            self.assertIn('INFO unit-peer', text)
            self.assertIn('/ws?[redacted]', text)
            self.assertIn('Started server process [123]', text)
        finally:
            logger.handlers, logger.filters, logger.level, logger.propagate = previous

    def test_exception_text_stack_and_structured_ticket_are_redacted(self):
        fixture = 'synthetic-ticket-value-not-a-real-capability'
        try:
            raise ValueError('handshake /ws?ticket=' + fixture)
        except ValueError as error:
            record = logging.LogRecord('uvicorn.error', logging.ERROR, __file__, 1,
                'Rejected ticket=%s', (fixture,), (type(error), error, error.__traceback__))
        record.stack_info = 'request /ws?ticket=' + fixture
        AsrTicketLogFilter().filter(record)
        rendered = logging.Formatter('%(message)s').format(record)
        self.assertNotIn(fixture, rendered)
        self.assertEqual(record.args, ())
        self.assertIsNone(record.exc_info)
        self.assertIn('[redacted]', rendered)

    def test_cli_config_protects_every_handler_and_does_not_suppress_ordinary_info(self):
        config = asr_log_config()
        self.assertIs(config['filters']['sera_asr_ticket_redaction']['()'], AsrTicketLogFilter)
        for handler in config['handlers'].values():
            self.assertIn('sera_asr_ticket_redaction', handler['filters'])
        self.assertEqual(config['loggers']['uvicorn.error']['level'], 'INFO')


if __name__ == '__main__': unittest.main()
