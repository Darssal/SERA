"""Transactional SQLite workspace storage shared by HTTP adapters."""
import copy
import json
import sqlite3
from contextlib import contextmanager
from workspace_validation import (integer, validate_workspace, ValidationError,
    ConflictError, preserve_change_metadata, validate_planning_result_changes)


class WorkspaceStore:
    def __init__(self, db_path):
        self.db_path = str(db_path)
        with self.connection() as connection:
            connection.execute('CREATE TABLE IF NOT EXISTS workspace (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL, body TEXT NOT NULL)')

    @contextmanager
    def connection(self):
        connection = sqlite3.connect(self.db_path, timeout=10)
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def load(self, user_id=None):
        with self.connection() as connection:
            row = (connection.execute('SELECT body FROM workspace WHERE id=1').fetchone() if user_id is None else
                   connection.execute('SELECT body FROM account_workspaces WHERE user_id=?', (user_id,)).fetchone())
            return json.loads(row[0]) if row else None

    def save(self, workspace, expected_revision, user_id=None, *, legacy_import=False):
        integer(expected_revision, 'expectedRevision')
        validate_workspace(workspace)
        if workspace['revision'] != expected_revision:
            raise ValidationError('workspace.revision must match expectedRevision')
        saved = copy.deepcopy(workspace)
        with self.connection() as connection:
            connection.execute('BEGIN IMMEDIATE')
            row = (connection.execute('SELECT revision FROM workspace WHERE id=1').fetchone() if user_id is None else
                   connection.execute('SELECT revision,body FROM account_workspaces WHERE user_id=?', (user_id,)).fetchone())
            current = row[0] if row else 0
            if current != expected_revision:
                raise ConflictError('Workspace changed. Reload before saving.')
            previous = json.loads(row[1]) if row and user_id is not None else None
            if user_id is None:
                prior_body = connection.execute('SELECT body FROM workspace WHERE id=1').fetchone()
                previous = json.loads(prior_body[0]) if prior_body else None
            prior_history = {item['id']: item for item in (previous or {}).get('history', [])}
            saved['history'] = [preserve_change_metadata(prior_history.get(item['id']), item)
                                for item in saved['history']]
            validate_planning_result_changes(previous, saved, allow_imported_tombstones=legacy_import)
            if user_id is not None and not legacy_import:
                from placement_policy import validate_placement_changes
                validate_placement_changes(json.loads(row[1]) if row else None, saved)
            saved['revision'] = current + 1
            if user_id is not None:
                from sync_store import versions_for_replacement
                saved = versions_for_replacement(json.loads(row[1]) if row else None, saved)
            body = json.dumps(saved, ensure_ascii=False, separators=(',', ':'))
            if user_id is None:
                connection.execute('INSERT INTO workspace(id,revision,body) VALUES(1,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,body=excluded.body', (saved['revision'], body))
            else:
                connection.execute('INSERT INTO account_workspaces(user_id,revision,body) VALUES(?,?,?) ON CONFLICT(user_id) DO UPDATE SET revision=excluded.revision,body=excluded.body', (user_id, saved['revision'], body))
        return saved

    def clear(self, user_id=None):
        with self.connection() as connection:
            if user_id is None:
                connection.execute('DELETE FROM workspace WHERE id=1')
            else:
                connection.execute('DELETE FROM account_workspaces WHERE user_id=?', (user_id,))
