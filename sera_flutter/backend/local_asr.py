"""Independent CPU streaming ASR service; accepts one-use HMAC tickets only."""
import argparse
import asyncio
import base64
from contextlib import asynccontextmanager
from copy import deepcopy
import hashlib
import hmac
import json
import logging
import os
from pathlib import Path
import re
import sqlite3
import threading
import time
import traceback
import wave

import numpy as np
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from starlette.concurrency import run_in_threadpool
from auth_store import AuthStore
from download_asr_model import RUNTIME_FILES, RUNTIME_SHA256, SHA256, CONFIGURATION

MODEL_NAME = 'sherpa-onnx-streaming-zipformer-small-bilingual-zh-en-2023-02-16'
DEFAULT_MODEL = Path(__file__).with_name('models') / MODEL_NAME


def redact_asr_ticket_text(value):
    # Uvicorn logs successful and failed WebSocket handshakes on uvicorn.error
    # at INFO, independently of access_log=False. Remove the entire /ws query
    # (including percent-encoded parameter names), rather than guessing its
    # token syntax. Also cover structured/text exception forms of ticket=.
    value = re.sub(r'''(?i)(/ws\?)[^\s"'<>]*''', r'\1[redacted]', str(value))
    return re.sub(r'''(?i)(\bticket["']?\s*[=:]\s*["']?)[^\s"'&<>]+''',
                  r'\1[redacted]', value)


class AsrTicketLogFilter(logging.Filter):
    def filter(self, record):
        if record.name == 'uvicorn.access' and isinstance(record.args, tuple) and len(record.args) == 5:
            # AccessFormatter unpacks this exact typed five-tuple. Flattening
            # it breaks ordinary HTTP access logging in embedded deployments.
            peer, method, path, version, status = record.args
            record.args = (peer, method, redact_asr_ticket_text(path), version, status)
        else:
            try:
                message = record.getMessage()
            except (TypeError, ValueError):
                message = str(record.msg)
            record.msg, record.args = redact_asr_ticket_text(message), ()
        if record.exc_info:
            record.exc_text = redact_asr_ticket_text(''.join(traceback.format_exception(*record.exc_info)))
            record.exc_info = None
        elif record.exc_text:
            record.exc_text = redact_asr_ticket_text(record.exc_text)
        if record.stack_info:
            record.stack_info = redact_asr_ticket_text(record.stack_info)
        return True


def install_asr_log_filters():
    # Logger filters survive Uvicorn's normal dictConfig and also protect an
    # embedded create_asr_app() with a caller-owned logging configuration.
    for name in ('uvicorn.error', 'uvicorn.access', 'uvicorn.asgi', 'websockets.server'):
        logger = logging.getLogger(name)
        if not any(isinstance(value, AsrTicketLogFilter) for value in logger.filters):
            logger.addFilter(AsrTicketLogFilter())
        for handler in logger.handlers:
            if not any(isinstance(value, AsrTicketLogFilter) for value in handler.filters):
                handler.addFilter(AsrTicketLogFilter())


def asr_log_config():
    from uvicorn.config import LOGGING_CONFIG
    config = deepcopy(LOGGING_CONFIG)
    config.setdefault('filters', {})['sera_asr_ticket_redaction'] = {'()': AsrTicketLogFilter}
    for handler in config.get('handlers', {}).values():
        handler.setdefault('filters', []).append('sera_asr_ticket_redaction')
    return config


class StreamingRecognizer:
    def __init__(self, directory, threads=2):
        import sherpa_onnx
        directory = Path(directory)
        manifest = directory / 'manifest.json'
        if not manifest.is_file():
            raise ValueError('ASR model manifest is missing; run the checksum-verified download script')
        if manifest.exists():
            document = json.loads(manifest.read_text(encoding='utf-8'))
            expected = document['files']
            if document.get('archiveSha256') != SHA256:
                raise ValueError('ASR model archive is not the pinned official release')
            for name in RUNTIME_FILES:
                if expected.get(name) != RUNTIME_SHA256[name] or not (directory / name).is_file():
                    raise ValueError('ASR requires verified encoder.int8 + decoder.float + joiner.int8; refresh the pinned model: ' + name)
                with (directory / name).open('rb') as source:
                    if hashlib.file_digest(source, 'sha256').hexdigest() != RUNTIME_SHA256[name]: raise ValueError('ASR model integrity check failed: ' + name)
        started = time.perf_counter()
        self.recognizer = sherpa_onnx.OnlineRecognizer.from_transducer(
            tokens=str(directory / 'tokens.txt'), encoder=str(directory / 'encoder-epoch-99-avg-1.int8.onnx'),
            decoder=str(directory / 'decoder-epoch-99-avg-1.onnx'), joiner=str(directory / 'joiner-epoch-99-avg-1.int8.onnx'),
            num_threads=threads, sample_rate=16000, feature_dim=80, decoding_method='greedy_search',
            enable_endpoint_detection=False, model_type='zipformer', provider='cpu')
        self.load_seconds = time.perf_counter() - started
        self.lock = threading.Lock()

    def create_stream(self): return self.recognizer.create_stream()
    def accept(self, stream, samples, finish=False):
        with self.lock:
            stream.accept_waveform(16000, samples)
            if finish:
                stream.accept_waveform(16000, np.zeros(8000, dtype=np.float32))
                stream.input_finished()
            while self.recognizer.is_ready(stream): self.recognizer.decode_stream(stream)
            return self.recognizer.get_result(stream)


def consume_ticket(ticket, secret, accounts):
    try:
        if not isinstance(ticket, str) or len(ticket) > 4096: raise ValueError()
        payload, signature = ticket.split('.')
        expected = base64.urlsafe_b64encode(hmac.new(secret, payload.encode(), hashlib.sha256).digest()).decode().rstrip('=')
        if not hmac.compare_digest(signature, expected): raise ValueError()
        value = json.loads(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4)))
        if value['exp'] <= time.time() or value['sampleRate'] != 16000: raise ValueError()
        if value.get('kind') == 'device':
            if (not isinstance(value.get('deviceHash'), str) or
                    re.fullmatch(r'[0-9a-f]{64}', value['deviceHash']) is None or
                    not isinstance(value.get('nonce'), str) or len(value['nonce']) > 128 or
                    type(value.get('streamExp')) is not int or
                    not value['exp'] <= value['streamExp'] <= time.time() + 90):
                raise ValueError()
            with accounts.connection() as db:
                db.execute('BEGIN IMMEDIATE')
                changed = db.execute('''UPDATE device_asr_tickets SET used=1
                    WHERE nonce_hash=? AND device_hash=? AND used=0
                    AND expires_at=? AND expires_at>?''',
                    (hashlib.sha256(value['nonce'].encode()).hexdigest(), value['deviceHash'],
                     value['streamExp'], int(time.time()))).rowcount
                if not changed: raise ValueError()
            return value
        if 'kind' in value: raise ValueError()
        with accounts.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            session = db.execute('SELECT 1 FROM sessions WHERE token_hash=? AND user_id=? AND expires_at>?',
                (value['sessionHash'], value['userId'], int(time.time()))).fetchone()
            changed = db.execute('UPDATE asr_tickets SET used=1 WHERE nonce_hash=? AND user_id=? AND used=0 AND expires_at>?',
                (hashlib.sha256(value['nonce'].encode()).hexdigest(), value['userId'], int(time.time()))).rowcount
            if not session or not changed: raise ValueError()
        return value
    except (ValueError, KeyError, TypeError, sqlite3.Error): raise ValueError('ASR ticket is invalid, expired or already used') from None


def ticket_is_active(ticket, accounts):
    """Check every frame; a device ticket never authenticates as an account."""
    with accounts.connection() as db:
        if ticket.get('kind') == 'device':
            if ticket['streamExp'] <= time.time(): return False
            return bool(db.execute('''SELECT 1 FROM device_asr_tickets WHERE
                nonce_hash=? AND device_hash=? AND used=1 AND expires_at=? AND expires_at>?''',
                (hashlib.sha256(ticket['nonce'].encode()).hexdigest(), ticket['deviceHash'],
                 ticket['streamExp'], int(time.time()))).fetchone())
        return bool(db.execute('SELECT 1 FROM sessions WHERE token_hash=? AND expires_at>?',
            (ticket['sessionHash'], int(time.time()))).fetchone())


def create_asr_app(db_path, model_dir=DEFAULT_MODEL, recognizer=None):
    install_asr_log_filters()
    accounts = AuthStore(db_path)
    secret = Path(db_path).with_suffix('.session-secret').read_bytes()
    engine = recognizer or StreamingRecognizer(model_dir)
    app = FastAPI(title='SERA local streaming ASR')
    app.state.engine = engine
    capacity = asyncio.Semaphore(2)
    active_users = set()
    @app.get('/health')
    async def health(): return {'status': 'ok', 'provider': 'sherpa-onnx', 'model': MODEL_NAME,
                               'configuration': CONFIGURATION, 'loadSeconds': engine.load_seconds}

    @app.websocket('/ws')
    async def audio(websocket: WebSocket):
        try: ticket = consume_ticket(websocket.query_params.get('ticket', ''), secret, accounts)
        except ValueError:
            await websocket.close(code=4401); return
        await websocket.accept()
        acquired = False
        user_acquired = False
        device = ticket.get('kind') == 'device'
        stream_owner = ('device', ticket['deviceHash']) if device else ('account', ticket['userId'])
        try:
            # This check and insertion run without an await on the service's event
            # loop. One account cannot occupy both inference slots.
            if stream_owner in active_users:
                await websocket.send_json({'type': 'error', 'code': 'device_stream_active' if device else 'account_stream_active',
                    'message': '本机已有进行中的录音，请先结束。' if device else '此账号已有进行中的录音，请先结束。'})
                return
            active_users.add(stream_owner)
            user_acquired = True
            try: await asyncio.wait_for(capacity.acquire(), 1); acquired = True
            except TimeoutError:
                await websocket.send_json({'type': 'error', 'code': 'asr_busy', 'message': '语音服务忙，请稍后重试。'})
                return
            first = await asyncio.wait_for(websocket.receive_json(), 10)
            if device and not ticket_is_active(ticket, accounts):
                await websocket.send_json({'type': 'error', 'code': 'device_ticket_expired', 'message': '本次录音已过期，请重新开始。'}); return
            if first != {'type': 'start', 'sampleRate': 16000, 'format': 's16le', 'channels': 1}:
                await websocket.send_json({'type': 'error', 'code': 'invalid_audio_format', 'message': '需要 16kHz 单声道 PCM16。'}); return
            stream, total, previous, decode_seconds = engine.create_stream(), 0, '', 0.0
            started = time.monotonic()
            await websocket.send_json({'type': 'status', 'status': 'listening', 'model': MODEL_NAME})
            while True:
                message = await asyncio.wait_for(websocket.receive(), 15)
                if message['type'] == 'websocket.disconnect': break
                valid = ticket_is_active(ticket, accounts)
                if not valid:
                    await websocket.send_json({'type': 'error', 'code': 'device_ticket_expired' if device else 'session_expired',
                        'message': '本次录音已过期，请重新开始。' if device else '登录已过期。'}); break
                if message.get('bytes') is not None:
                    chunk = message['bytes']
                    if len(chunk) % 2 or len(chunk) > 32000:
                        await websocket.send_json({'type': 'error', 'code': 'invalid_audio_frame', 'message': '音频帧无效。'}); break
                    total += len(chunk)
                    if total > 16000 * 2 * 60 or time.monotonic() - started > 90:
                        await websocket.send_json({'type': 'error', 'code': 'audio_limit', 'message': '录音最长 60 秒。'}); break
                    samples = np.frombuffer(chunk, dtype='<i2').astype(np.float32) / 32768
                    decode_started = time.perf_counter()
                    text = await run_in_threadpool(engine.accept, stream, samples)
                    decode_seconds += time.perf_counter() - decode_started
                    if text != previous:
                        await websocket.send_json({'type': 'partial', 'text': text}); previous = text
                elif message.get('text'):
                    decoded = json.loads(message['text'])
                    if not isinstance(decoded, dict): raise ValueError('Audio command must be an object')
                    command = decoded.get('type')
                    if command == 'cancel':
                        await websocket.send_json({'type': 'status', 'status': 'cancelled'}); break
                    if command == 'finish':
                        decode_started = time.perf_counter()
                        text = await run_in_threadpool(engine.accept, stream, np.zeros(0, dtype=np.float32), True)
                        decode_seconds += time.perf_counter() - decode_started
                        await websocket.send_json({'type': 'final', 'text': text, 'durationSeconds': total / 32000,
                            'decodeWallSeconds': decode_seconds, 'source': 'sherpa-onnx'}); break
                    await websocket.send_json({'type': 'error', 'code': 'invalid_command', 'message': '无效的语音命令。'}); break
        except (WebSocketDisconnect, asyncio.TimeoutError): pass
        except (ValueError, RuntimeError):
            try: await websocket.send_json({'type': 'error', 'code': 'asr_stream_error', 'message': '语音流处理失败，请重新录制。'})
            except RuntimeError: pass
        finally:
            if acquired: capacity.release()
            if user_acquired: active_users.discard(stream_owner)
            try: await websocket.close()
            except RuntimeError: pass
    return app


def benchmark(model_dir, wav_path):
    engine = StreamingRecognizer(model_dir)
    with wave.open(str(wav_path)) as wav:
        if wav.getframerate() != 16000 or wav.getnchannels() != 1 or wav.getsampwidth() != 2: raise ValueError('Benchmark WAV must be 16 kHz mono PCM16')
        samples = np.frombuffer(wav.readframes(wav.getnframes()), dtype='<i2').astype(np.float32) / 32768
    stream, first_partial, first_partial_audio, partials = engine.create_stream(), None, None, 0
    start = time.perf_counter()
    previous = ''
    for pos in range(0, len(samples), 1600):
        text = engine.accept(stream, samples[pos:pos + 1600])
        if text and first_partial is None:
            first_partial = time.perf_counter() - start
            first_partial_audio = min(pos + 1600, len(samples)) / 16000
        if text != previous: partials += 1
        previous = text
    text = engine.accept(stream, np.zeros(0, dtype=np.float32), True)
    elapsed = time.perf_counter() - start
    return {'model': MODEL_NAME, 'provider': 'cpu', 'loadSeconds': engine.load_seconds,
        'audioSeconds': len(samples) / 16000, 'decodeSeconds': elapsed,
        'realTimeFactor': elapsed / (len(samples) / 16000), 'firstPartialComputeSeconds': first_partial,
        'firstPartialAudioSeconds': first_partial_audio,
        'partialCount': partials, 'text': text, 'audioSha256': hashlib.sha256(Path(wav_path).read_bytes()).hexdigest()}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--db', default=str(Path(__file__).with_name('sera.sqlite3')))
    parser.add_argument('--model-dir', default=str(DEFAULT_MODEL))
    parser.add_argument('--port', type=int, default=8790)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--benchmark')
    args = parser.parse_args()
    if args.benchmark:
        print(json.dumps(benchmark(args.model_dir, args.benchmark), ensure_ascii=False))
    else:
        import uvicorn
        # Handshake INFO messages use uvicorn.error, so access_log alone cannot
        # protect query capabilities. Filter both loggers and every CLI handler.
        uvicorn.run(create_asr_app(args.db, args.model_dir), host=args.host, port=args.port,
                    access_log=False, log_config=asr_log_config())
