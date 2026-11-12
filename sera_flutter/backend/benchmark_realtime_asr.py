"""Real loopback WebSocket experiment with paced PCM; no user DB or cloud API."""
import argparse
import asyncio
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import sys
import tempfile
import time
from urllib.request import urlopen
import wave
from websockets.asyncio.client import connect

from app import create_app
from local_asr import DEFAULT_MODEL


def p95(values):
    values = sorted(values)
    position = (len(values) - 1) * .95
    lower = int(position)
    return values[lower] + (values[min(lower + 1, len(values) - 1)] - values[lower]) * (position - lower)


async def experiment(port, app, identities, audio):
    async def run(identity, label):
        ticket = app.state.workflows.ticket(identity['user']['id'], identity['token'], app.state.secret)['ticket']
        async with connect(f'ws://127.0.0.1:{port}/ws?ticket={ticket}', max_size=1024*1024) as ws:
            await ws.send(json.dumps({'type': 'start', 'sampleRate': 16000, 'format': 's16le', 'channels': 1}))
            status = json.loads(await ws.recv())
            if status.get('status') != 'listening': raise RuntimeError('Recognizer did not start')
            started, finish_at = time.perf_counter(), None
            first_partial, count = None, 0
            async def receive():
                nonlocal first_partial, count
                while True:
                    value = json.loads(await ws.recv())
                    received_at = time.perf_counter()
                    if value['type'] == 'partial':
                        count += 1
                        if first_partial is None: first_partial = received_at - started
                    elif value['type'] == 'final':
                        duration = len(audio) / 32000
                        return {'run': label, 'audioSeconds': duration, 'firstPartialWallSeconds': first_partial,
                            'finishToFinalWallSeconds': received_at - finish_at, 'totalWallSeconds': received_at - started,
                            'wallRtfIncludingPacing': (received_at - started) / duration,
                            'serverDecodeWallSeconds': value['decodeWallSeconds'],
                            'serverDecodeWallRtf': value['decodeWallSeconds'] / duration,
                            'partialCount': count, 'text': value['text']}
                    elif value['type'] == 'error': raise RuntimeError('ASR returned ' + value.get('code', 'error'))
            receiver = asyncio.create_task(receive())
            for offset in range(0, len(audio), 3200):
                chunk = audio[offset:offset+3200]
                await asyncio.sleep(max(0, started + (offset + len(chunk)) / 32000 - time.perf_counter()))
                await ws.send(chunk)
            finish_at = time.perf_counter()
            await ws.send('{"type":"finish"}')
            return await asyncio.wait_for(receiver, 30)
    single = []
    for i in range(5):
        single.append(await run(identities[0], f'single-{i+1}'))
        print(f'Single stream {i+1}/5 completed', flush=True)
    dual = []
    for i in range(3):
        dual.extend(await asyncio.gather(run(identities[0], f'dual-{i+1}-a'), run(identities[1], f'dual-{i+1}-b')))
        print(f'Two-account concurrent round {i+1}/3 completed', flush=True)
    return single, dual


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', default='docs/qa/asr-realtime-latency.json')
    args = parser.parse_args()
    wav_path = DEFAULT_MODEL / 'test_wavs/0.wav'
    with wave.open(str(wav_path)) as source:
        assert source.getframerate() == 16000 and source.getnchannels() == 1 and source.getsampwidth() == 2
        audio = source.readframes(source.getnframes())
    with tempfile.TemporaryDirectory() as temporary:
        db = Path(temporary) / 'experiment.sqlite3'
        app = create_app(db_path=db)
        identities = [app.state.accounts.register({'username': f'latency-{i}', 'email': f'latency-{i}@example.test',
            'password': 'IsolatedBenchmarkOnly123'}) for i in range(2)]
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        with open(os.devnull, 'w') as log:
            process = subprocess.Popen([sys.executable, str(Path(__file__).with_name('local_asr.py')), '--db', str(db), '--port', str(port)],
                stdout=log, stderr=log, creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
            try:
                for _ in range(100):
                    try:
                        with urlopen(f'http://127.0.0.1:{port}/health', timeout=1) as response: health = json.load(response)
                        break
                    except OSError:
                        if process.poll() is not None: raise RuntimeError('Isolated ASR service exited')
                        time.sleep(.1)
                else: raise RuntimeError('Isolated ASR did not become ready')
                single, dual = asyncio.run(experiment(port, app, identities, audio))
            finally:
                process.terminate()
                process.wait(timeout=15)
    def summary(runs):
        return {'sampleCount': len(runs), **{name+'P95': p95([run[name] for run in runs]) for name in
            ('firstPartialWallSeconds', 'finishToFinalWallSeconds', 'serverDecodeWallRtf', 'wallRtfIncludingPacing')}}
    result = {'recordedAt': datetime.now(timezone.utc).isoformat(), 'runtime': platform.platform(),
        'cpu': platform.processor(), 'logicalCpuCount': os.cpu_count(), 'inferenceThreads': 2,
        'model': health['model'], 'loadSeconds': health['loadSeconds'], 'sampleRate': 16000, 'frameMilliseconds': 100,
        'audioSha256': hashlib.sha256(wav_path.read_bytes()).hexdigest(), 'audioSeconds': len(audio)/32000,
        'method': 'Actual loopback TCP WebSocket, 100ms PCM paced by monotonic clock; first frame after first100ms. Five single sessions and three rounds with two distinct accounts concurrently.',
        'metricNotes': 'serverDecodeWallRtf sums server inference waits including thread scheduling/lock contention; wallRtfIncludingPacing includes intentional audio pacing. P95 is linear interpolation; small samples and one fixed mixed-language clip, not corpus accuracy or phone end-to-end latency.',
        'single': summary(single), 'twoAccountConcurrent': summary(dual), 'runs': single+dual}
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'output':str(output),'single':result['single'],'twoAccountConcurrent':result['twoAccountConcurrent']},indent=2))


if __name__ == '__main__': main()
