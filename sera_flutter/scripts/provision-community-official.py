"""Create a new course community owner; write credentials only to private files.

This local operator command never promotes a user through a public API, resets
an existing password, sends mail, or marks an email as verified.
"""
import argparse
from contextlib import closing
from datetime import datetime, timezone
import json
from pathlib import Path
import secrets
import sqlite3
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'backend'))
from auth_store import AuthStore


def provision(db_path, private_path, username, email):
    db_path = Path(db_path).resolve(strict=True)
    private_path = Path(private_path).resolve()
    private_path.mkdir(parents=True, exist_ok=True)
    credentials_path = private_path / 'official-account.json'
    env_path = private_path / 'official.env'
    if credentials_path.exists():
        saved = json.loads(credentials_path.read_text(encoding='utf-8'))
        if saved['database'] != str(db_path):
            raise ValueError('Existing private credentials belong to another database.')
        with closing(sqlite3.connect(db_path)) as connection:
            row = connection.execute('SELECT username FROM users WHERE id=?',
                                     (saved['userId'],)).fetchone()
        if not row or row[0] != saved['username'] or not env_path.exists():
            raise ValueError('Existing official account needs manual recovery; nothing was changed.')
        return credentials_path, False

    # Preserve the full database before additive account/schema changes.
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    backup = private_path / f'before-official-{stamp}.sqlite3'
    with closing(sqlite3.connect(db_path)) as source, closing(sqlite3.connect(backup)) as target:
        source.backup(target)
    auth = AuthStore(db_path)
    password = secrets.token_urlsafe(24)
    result = auth.register({'username': username, 'email': email, 'password': password})
    auth.logout(result['token'])
    saved = {'username': username, 'email': email, 'password': password,
             'userId': result['user']['id'], 'database': str(db_path),
             'emailVerified': False, 'createdAt': datetime.now(timezone.utc).isoformat(),
             'purpose': 'Course community official account; reserved email has no mailbox.'}
    with credentials_path.open('x', encoding='utf-8') as handle:
        json.dump(saved, handle, ensure_ascii=False, indent=2)
        handle.write('\n')
    with env_path.open('x', encoding='utf-8') as handle:
        handle.write('SERA_COMMUNITY_OFFICIAL_USER_IDS=' + saved['userId'] + '\n')
    return credentials_path, True


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--db', type=Path, default=ROOT / 'backend/sera.sqlite3')
    parser.add_argument('--private-dir', type=Path, default=ROOT / '.local/community-private')
    parser.add_argument('--username', default='序日官方')
    parser.add_argument('--email', default='official@sera.example')
    args = parser.parse_args()
    try:
        destination, created = provision(args.db, args.private_dir, args.username, args.email)
    except Exception:
        sys.exit('Official provisioning failed. Check local account/configuration; credentials were not logged.')
    print(('Created' if created else 'Retained') + ' official account; private credentials: ' + str(destination))
