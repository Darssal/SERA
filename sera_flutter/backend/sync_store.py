"""Object-versioned, idempotent SQLite operations. All user writes are atomic."""
import copy
import hashlib
import json
import time
from workspace_validation import (preserve_change_metadata, validate_workspace,
                    validate_planning_result_changes, ValidationError)
from auth_store import AuthStore

COLLECTIONS = {'tasks', 'entries', 'goals', 'drafts', 'planningSessions', 'focusRecords',
               'reviews', 'externalBusyEntries', 'history'}
SINGLETONS = {'preferences', 'focusSession', 'reminderStates', 'platformSettings'}


def migrate_workspace(value):
    value = copy.deepcopy(value)
    value['schemaVersion'] = 2
    for name in ('externalBusyEntries', 'planningSessions', 'reviews'):
        value.setdefault(name, [])
    for name in ('reminderStates', 'platformSettings', 'entityVersions'):
        value.setdefault(name, {})
    value.setdefault('focusSession', None)
    versions = value['entityVersions']
    for kind in COLLECTIONS:
        for item in value.get(kind, []):
            versions.setdefault(f'{kind}/{item["id"]}', item.get('revision', 1))
    for kind in SINGLETONS:
        versions.setdefault(f'{kind}/singleton', 1)
    return value


def versions_for_replacement(previous, incoming):
    saved = migrate_workspace(incoming)
    if previous is None: return saved
    previous = migrate_workspace(previous)
    versions = dict(previous['entityVersions'])
    for kind in COLLECTIONS | SINGLETONS:
        before = ({item['id']: item for item in previous.get(kind, [])} if kind in COLLECTIONS else {'singleton': previous.get(kind)})
        after = ({item['id']: item for item in saved.get(kind, [])} if kind in COLLECTIONS else {'singleton': saved.get(kind)})
        for eid in before.keys() | after.keys():
            key = f'{kind}/{eid}'
            current = versions.get(key, 0)
            if before.get(eid) != after.get(eid): versions[key] = current + 1
            else: versions.setdefault(key, max(current, 1))
    saved['entityVersions'] = versions
    return saved


class SyncConflict(Exception):
    def __init__(self, conflicts, workspace):
        self.conflicts, self.workspace = conflicts, workspace


class SyncStore:
    def __init__(self, path):
        self.accounts = AuthStore(path)
        with self.accounts.connection() as db:
            db.execute('PRAGMA journal_mode=WAL')
            db.executescript('''
              CREATE TABLE IF NOT EXISTS sync_operations(user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                operation_id TEXT NOT NULL, digest TEXT NOT NULL, applied_at INTEGER NOT NULL,
                PRIMARY KEY(user_id,operation_id));
            ''')

    def load(self, uid):
        with self.accounts.connection() as db:
            row = db.execute('SELECT body FROM account_workspaces WHERE user_id=?', (uid,)).fetchone()
            return migrate_workspace(json.loads(row['body'])) if row else None

    def apply(self, uid, body):
        if not isinstance(body, dict) or not isinstance(body.get('operations'), list) or not 1 <= len(body['operations']) <= 5000:
            raise ValidationError('operations must contain 1 to 5000 operations')
        with self.accounts.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT body FROM account_workspaces WHERE user_id=?', (uid,)).fetchone()
            if not row:
                raise ValidationError('Initialize workspace before submitting operations')
            workspace = migrate_workspace(json.loads(row['body']))
            candidate = copy.deepcopy(workspace)
            versions = candidate['entityVersions']
            applied, replayed, conflicts = [], [], []
            seen = set()
            for operation in body['operations']:
                if not isinstance(operation, dict): raise ValidationError('Invalid operation')
                oid = operation.get('id') or operation.get('operationId')
                kind, eid = operation.get('entityType'), operation.get('entityId')
                action, expected = operation.get('action'), operation.get('expectedVersion')
                if not isinstance(oid, str) or not 1 <= len(oid) <= 128 or oid in seen:
                    raise ValidationError('Operation ids must be unique non-empty strings')
                seen.add(oid)
                if kind not in COLLECTIONS | SINGLETONS or not isinstance(eid, str) or len(eid) > 128 or not eid:
                    raise ValidationError('Unsupported entity type/id')
                if kind in SINGLETONS and eid != 'singleton': raise ValidationError('Singleton entityId must be singleton')
                if action not in ('upsert', 'delete') or type(expected) is not int or expected < 0:
                    raise ValidationError('Invalid action or expectedVersion')
                digest = hashlib.sha256(json.dumps(operation, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
                prior = db.execute('SELECT digest FROM sync_operations WHERE user_id=? AND operation_id=?', (uid, oid)).fetchone()
                if prior:
                    if prior['digest'] != digest:
                        conflicts.append({'operationId': oid, 'reason': 'idempotency_key_reused'})
                    else: replayed.append(oid)
                    continue
                key = f'{kind}/{eid}'
                actual = versions.get(key, 0)
                current = (candidate.get(kind) if kind in SINGLETONS else
                           next((item for item in candidate.get(kind, []) if item['id'] == eid), None))
                if expected != actual:
                    conflicts.append({'operationId': oid, 'entityType': kind, 'entityId': eid,
                        'expectedVersion': expected, 'currentVersion': actual, 'serverValue': current})
                    continue
                value = copy.deepcopy(operation.get('value'))
                if action == 'upsert' and kind in COLLECTIONS and (not isinstance(value, dict) or value.get('id') != eid):
                    raise ValidationError('Entity value id must match entityId')
                if action == 'upsert' and kind == 'history':
                    value = preserve_change_metadata(current, value)
                if action == 'delete' and kind in SINGLETONS and kind != 'focusSession':
                    raise ValidationError('Only focusSession may be deleted as singleton')
                if kind in SINGLETONS:
                    candidate[kind] = value if action == 'upsert' else None
                else:
                    candidate[kind] = [item for item in candidate.get(kind, []) if item['id'] != eid]
                    if action == 'upsert':
                        if 'revision' in value: value['revision'] = actual + 1
                        candidate[kind].append(value)
                versions[key] = actual + 1
                applied.append((oid, digest))
            if conflicts: raise SyncConflict(conflicts, workspace)
            if applied:
                candidate['revision'] = workspace['revision'] + 1
                validate_workspace(candidate)
                validate_planning_result_changes(workspace, candidate)
                from placement_policy import validate_placement_changes
                validate_placement_changes(workspace, candidate)
                db.execute('UPDATE account_workspaces SET revision=?,body=? WHERE user_id=?',
                           (candidate['revision'], json.dumps(candidate, ensure_ascii=False), uid))
                db.executemany('INSERT INTO sync_operations VALUES(?,?,?,?)',
                               [(uid, oid, digest, int(time.time())) for oid, digest in applied])
            return {'workspace': candidate, 'applied': [item[0] for item in applied], 'replayed': replayed,
                    'entityVersions': candidate['entityVersions']}
