import json
from pathlib import Path
import tempfile
import unittest
import wave

from fastapi.testclient import TestClient
from app import create_app
from local_asr import create_asr_app, DEFAULT_MODEL


@unittest.skipUnless((DEFAULT_MODEL / 'encoder-epoch-99-avg-1.int8.onnx').is_file(), 'Download the pinned local ASR model to run inference integration')
class LocalAsrTests(unittest.TestCase):
    def test_same_account_single_stream_other_account_capacity_and_release(self):
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / 'concurrency.db'
            with TestClient(create_app(db_path=db)) as client:
                def account(name):
                    value = client.post('/api/v1/auth/register', json={'username': name,
                        'email': name + '@example.test', 'password': 'CorrectPassword123'}).json()
                    return {'Authorization': 'Bearer ' + value['token']}
                first_headers, second_headers = account('speech-one'), account('speech-two')
                def ticket(headers): return client.post('/api/v1/asr/tickets', headers=headers, json={}).json()['ticket']
                first, duplicate, other, resumed = ticket(first_headers), ticket(first_headers), ticket(second_headers), ticket(first_headers)
                with TestClient(create_asr_app(db)) as speech:
                    with speech.websocket_connect('/ws?ticket=' + first) as socket:
                        start = {'type': 'start', 'sampleRate': 16000, 'format': 's16le', 'channels': 1}
                        socket.send_json(start)
                        self.assertEqual(socket.receive_json()['status'], 'listening')
                        with speech.websocket_connect('/ws?ticket=' + duplicate) as denied:
                            self.assertEqual(denied.receive_json()['code'], 'account_stream_active')
                        with speech.websocket_connect('/ws?ticket=' + other) as allowed:
                            allowed.send_json(start)
                            self.assertEqual(allowed.receive_json()['status'], 'listening')
                            allowed.send_bytes(bytes(3200))
                            allowed.send_json({'type': 'finish'})
                            while allowed.receive_json()['type'] != 'final': pass
                        socket.send_json({'type': 'cancel'})
                        self.assertEqual(socket.receive_json()['status'], 'cancelled')
                    with speech.websocket_connect('/ws?ticket=' + resumed) as reopened:
                        reopened.send_json(start)
                        self.assertEqual(reopened.receive_json()['status'], 'listening')
                        client.post('/api/v1/auth/logout', headers=first_headers, json={})
                        reopened.send_bytes(bytes(3200))
                        self.assertEqual(reopened.receive_json()['code'], 'session_expired')

    def test_real_model_one_use_ticket_partial_final_and_cancel(self):
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / 'asr.db'
            api = create_app(db_path=db)
            with TestClient(api) as client:
                auth = client.post('/api/v1/auth/register', json={'username': 'asr-user',
                    'email': 'asr@example.test', 'password': 'CorrectPassword123'}).json()
                headers = {'Authorization': 'Bearer ' + auth['token']}
                ticket = client.post('/api/v1/asr/tickets', headers=headers, json={'sampleRate': 16000}).json()['ticket']
                cancel_ticket = client.post('/api/v1/asr/tickets', headers=headers, json={'sampleRate': 16000}).json()['ticket']
            asr = create_asr_app(db)
            with TestClient(asr) as speech:
                with speech.websocket_connect('/ws?ticket=' + ticket) as socket:
                    socket.send_json({'type': 'start', 'sampleRate': 16000, 'format': 's16le', 'channels': 1})
                    self.assertEqual(socket.receive_json()['status'], 'listening')
                    with wave.open(str(DEFAULT_MODEL / 'test_wavs' / '0.wav')) as wav:
                        data = wav.readframes(wav.getnframes())
                    for offset in range(0, len(data), 3200): socket.send_bytes(data[offset:offset + 3200])
                    socket.send_json({'type': 'finish'})
                    partials, final = [], None
                    while final is None:
                        message = socket.receive_json()
                        if message['type'] == 'partial': partials.append(message['text'])
                        elif message['type'] == 'final': final = message
                        else: self.fail(str(message))
                    self.assertGreater(len(partials), 1)
                    self.assertTrue(final['text'])
                    self.assertEqual(final['source'], 'sherpa-onnx')
                with self.assertRaises(Exception):
                    with speech.websocket_connect('/ws?ticket=' + ticket): pass
                with speech.websocket_connect('/ws?ticket=' + cancel_ticket) as socket:
                    socket.send_json({'type': 'start', 'sampleRate': 16000, 'format': 's16le', 'channels': 1})
                    socket.receive_json()
                    socket.send_json({'type': 'cancel'})
                    self.assertEqual(socket.receive_json()['status'], 'cancelled')


if __name__ == '__main__': unittest.main()
