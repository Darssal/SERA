"""Consistent SQLite online backup and checksum-verified isolated restore.

Archives contain private account/session data. Store them outside the web root.
Restore refuses non-empty destinations; it never replaces a running database.
"""
import argparse
from contextlib import closing
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import zipfile


def backup(database, output):
    database, output = Path(database).resolve(), Path(output).resolve()
    if not database.is_file(): raise ValueError('Database does not exist')
    if output.exists(): raise ValueError('Backup output already exists')
    if output.is_relative_to(database.parent / 'mail'): raise ValueError('Do not write backups into the mail sink')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as directory:
        snapshot = Path(directory) / 'workspace.sqlite3'
        with closing(sqlite3.connect(database)) as source, closing(sqlite3.connect(snapshot)) as destination:
            source.backup(destination)
            if destination.execute('PRAGMA integrity_check').fetchone()[0] != 'ok': raise ValueError('Database integrity check failed')
        files = {'workspace.sqlite3': snapshot}
        for suffix in ('.session-secret', '.vapid.pem'):
            source = database.with_suffix(suffix)
            if source.is_file(): files['workspace' + suffix] = source
        manifest = {'schemaVersion': 1, 'createdAt': datetime.now(timezone.utc).isoformat(), 'files': {}}
        partial = output.with_name(output.name + '.partial')
        with zipfile.ZipFile(partial, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for name, file in files.items():
                data = file.read_bytes()
                manifest['files'][name] = hashlib.sha256(data).hexdigest()
                archive.writestr(name, data)
            archive.writestr('manifest.json', json.dumps(manifest, indent=2))
        partial.replace(output)
    return output


def restore(archive_path, directory):
    directory = Path(directory).resolve()
    if directory.exists() and any(directory.iterdir()): raise ValueError('Restore destination must be empty')
    allowed = {'workspace.sqlite3', 'workspace.session-secret', 'workspace.vapid.pem'}
    with zipfile.ZipFile(archive_path) as archive:
        manifest = json.loads(archive.read('manifest.json'))
        files = manifest.get('files', {})
        if manifest.get('schemaVersion') != 1 or not isinstance(files, dict) or not files or 'workspace.sqlite3' not in files or set(files) - allowed:
            raise ValueError('Invalid backup manifest')
        if len(set(archive.namelist())) != len(archive.namelist()) or set(archive.namelist()) != set(files) | {'manifest.json'}:
            raise ValueError('Unexpected backup members')
        contents = {}
        for name, expected in files.items():
            info = archive.getinfo(name)
            if info.file_size > 512 * 1024 * 1024: raise ValueError('Backup member is too large')
            data = archive.read(name)
            if hashlib.sha256(data).hexdigest() != expected: raise ValueError('Backup checksum failed')
            contents[name] = data
    # Verify the restored database before publishing any restored files.
    with tempfile.TemporaryDirectory() as staging:
        check = Path(staging) / 'workspace.sqlite3'
        check.write_bytes(contents['workspace.sqlite3'])
        with closing(sqlite3.connect(check)) as db:
            if db.execute('PRAGMA integrity_check').fetchone()[0] != 'ok': raise ValueError('Restored database is corrupt')
        directory.mkdir(parents=True, exist_ok=True)
        for name, data in contents.items(): (directory / name).write_bytes(data)
    return directory / 'workspace.sqlite3'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    save = commands.add_parser('backup')
    save.add_argument('--db', required=True)
    save.add_argument('--output', required=True)
    load = commands.add_parser('restore')
    load.add_argument('--archive', required=True)
    load.add_argument('--destination', required=True)
    args = parser.parse_args()
    result = backup(args.db, args.output) if args.command == 'backup' else restore(args.archive, args.destination)
    print('Backup operation completed:', result)
