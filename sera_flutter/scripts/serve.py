"""Run API, durable jobs and local streaming ASR as one supervised local stack."""
import argparse
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
PRIVATE_ENV_KEYS = frozenset({
    'SMTP_HOST', 'SMTP_PORT', 'SMTP_TLS', 'SMTP_USERNAME', 'SMTP_PASSWORD',
    'SMTP_FROM', 'SERA_MAIL_MODE', 'SERA_PUBLIC_ORIGIN',
    'SERA_SMS_AUTH_ENABLED', 'SERA_SMS_ACCESS_KEY_ID',
    'SERA_SMS_ACCESS_KEY_SECRET', 'SERA_SMS_SECURITY_TOKEN',
    'SERA_SMS_SIGN_NAME', 'SERA_SMS_SCHEME_NAME',
    'SERA_SMS_TEMPLATE_LOGIN', 'SERA_SMS_TEMPLATE_BIND',
    'SERA_SMS_TEMPLATE_SENSITIVE', 'SERA_SMS_ALLOWED_TEST_PHONES',
    'SERA_SMS_PHONE_HOUR_LIMIT', 'SERA_SMS_PHONE_DAY_LIMIT',
    'SERA_SMS_IP_MINUTE_LIMIT', 'SERA_SMS_IP_HOUR_LIMIT',
    'SERA_SMS_GLOBAL_HOUR_LIMIT', 'SERA_SMS_GLOBAL_DAY_LIMIT',
    'SERA_PUBLIC_WEB_PROXY',
    'SERA_COMMUNITY_OFFICIAL_USER_IDS',
})
PRIVATE_ENV_MAX_BYTES = 64 * 1024


class PrivateEnvironmentError(ValueError):
    """Safe configuration diagnostics that never contain a key or value."""


def load_private_environment(path):
    """Read an explicit, allowlisted KEY=value file without executing its text.

    Blank lines and full-line comments are accepted. Values may be surrounded
    by matching single or double quotes. They are otherwise literal: no shell
    evaluation, escaping, interpolation, inline comments or multiline values.
    The caller chooses whether and where to apply the returned configuration.
    """
    try:
        with Path(path).open('rb') as handle:
            data = handle.read(PRIVATE_ENV_MAX_BYTES + 1)
    except (OSError, ValueError, TypeError):
        raise PrivateEnvironmentError('Cannot read private environment file.') from None
    if len(data) > PRIVATE_ENV_MAX_BYTES:
        raise PrivateEnvironmentError('Private environment file exceeds the size limit.')
    try:
        source = data.decode('utf-8-sig')
    except UnicodeError:
        raise PrivateEnvironmentError('Private environment file must use UTF-8.') from None
    result = {}
    for number, raw in enumerate(source.split('\n'), 1):
        line = raw.removesuffix('\r').strip()
        if not line or line.startswith('#'):
            continue
        failure = f'Invalid private environment configuration at line {number}.'
        if any(ord(character) < 32 for character in line):
            raise PrivateEnvironmentError(failure)
        match = re.fullmatch(r'([A-Z][A-Z0-9_]*)\s*=(.*)', line)
        if not match:
            raise PrivateEnvironmentError(failure)
        key, value = match.groups()
        if key not in PRIVATE_ENV_KEYS or key in result:
            raise PrivateEnvironmentError(failure)
        value = value.strip()
        if value.startswith(('\"', "'")):
            if len(value) < 2 or value[-1] != value[0] or value[0] in value[1:-1]:
                raise PrivateEnvironmentError(failure)
            value = value[1:-1]
        elif value.endswith(('\"', "'")):
            raise PrivateEnvironmentError(failure)
        result[key] = value
    return result

def load_private_environments(paths):
    """Merge explicitly selected files in order; a later file takes priority."""
    result = {}
    for path in paths:
        result.update(load_private_environment(path))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8787)
    parser.add_argument('--asr-port', type=int, default=8790)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--db', default=str(ROOT / 'backend/sera.sqlite3'))
    parser.add_argument('--ai-key-file', default=os.environ.get('SILICONFLOW_API_KEY_FILE'))
    parser.add_argument('--ai-model', default=None, help='Override the AI model for both API and durable worker.')
    parser.add_argument('--web-dir', default=str(ROOT / 'build/web'))
    parser.add_argument('--no-asr', action='store_true')
    parser.add_argument('--env-file', type=Path, action='append', default=[],
                        help='Explicit private configuration; repeat to merge files in order. Values are never logged.')
    args = parser.parse_args()
    env = os.environ.copy()
    if args.env_file:
        try:
            env.update(load_private_environments(args.env_file))
        except PrivateEnvironmentError as error:
            parser.error(str(error))
    env.setdefault('SERA_PUBLIC_ORIGIN', f'http://127.0.0.1:{args.port}')
    env.setdefault('SERA_ASR_WS_URL', f'ws://127.0.0.1:{args.asr_port}/ws')
    env.setdefault('SERA_ASR_HEALTH_URL', f'http://127.0.0.1:{args.asr_port}/health')
    if args.ai_key_file:
        env['SILICONFLOW_API_KEY_FILE'] = str(Path(args.ai_key_file).resolve())
    if args.ai_model:
        env['SILICONFLOW_MODEL'] = args.ai_model
    ffprobe = Path('D:/development/ffmpeg/ffmpeg-9.0.2-essentials_build/bin/ffprobe.exe')
    if ffprobe.exists():
        env.setdefault('FFPROBE_PATH', str(ffprobe))
    db = str(Path(args.db).resolve())
    commands = [
        [sys.executable, 'backend/server.py', '--host', args.host, '--port', str(args.port), '--db', db, '--web-dir', str(Path(args.web_dir).resolve())],
        [sys.executable, 'backend/worker.py', '--db', db],
    ]
    if not args.no_asr:
        commands.append([sys.executable, 'backend/local_asr.py', '--db', db, '--host', args.host, '--port', str(args.asr_port)])
    processes = []
    stopped = False
    def stop(signum=None, frame=None):
        nonlocal stopped
        stopped = True
    signal.signal(signal.SIGINT, stop)
    if hasattr(signal, 'SIGTERM'):
        signal.signal(signal.SIGTERM, stop)
    try:
        # Initialize shared schema/secret before independent worker/ASR start.
        sys.path.insert(0, str(ROOT / 'backend'))
        from app import create_app
        initialized = create_app(db_path=db, ai_key_file=args.ai_key_file,
                                 ai_model=env.get('SILICONFLOW_MODEL'))
        del initialized
        for command in commands:
            processes.append(subprocess.Popen(command, cwd=ROOT, env=env,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0))
        print(f'SERA: http://127.0.0.1:{args.port}/ ; ASR port {args.asr_port}. Ctrl+C stops all children.', flush=True)
        while not stopped:
            failed = next((p for p in processes if p.poll() is not None), None)
            if failed:
                raise RuntimeError(f'A stack service exited with code {failed.returncode}')
            time.sleep(0.5)
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
        for process in processes:
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                process.kill()
        print('SERA local stack stopped.', flush=True)

if __name__ == '__main__':
    main()
