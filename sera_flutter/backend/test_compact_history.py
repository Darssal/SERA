"""Compact undo history, isolated SQLite only; no service or provider calls."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

from fastapi import FastAPI
from api_contract import install_contract
from auth_store import AuthStore
from server import (ConflictError, HISTORY_COLLECTION_LIMITS, ValidationError, WorkspaceStore,
                    validate_change_record, validate_workspace)
from sync_store import SyncConflict, SyncStore, migrate_workspace
from test_server import empty_workspace


def delta():
    return {'id': 'change', 'label': '保存任务', 'at': '2026-11-02T09:00:00+08:00',
            'undone': False, 'format': 'entity-delta-v1', 'afterDigest': 'a' * 64,
            'beforeOrder': {'tasks': []},
            'before': {kind: [] for kind in HISTORY_COLLECTION_LIMITS},
            'after': {kind: ([{'id': 'task', 'title': 'Task'}] if kind == 'tasks' else [])
                      for kind in HISTORY_COLLECTION_LIMITS}}


def old_client_record(record):
    return {key: copy.deepcopy(record[key])
            for key in ('id', 'label', 'at', 'before', 'after', 'undone')}


class CompactHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / 'compact.db'
        self.store = WorkspaceStore(self.path)

    def tearDown(self):
        self.temp.cleanup()

    def test_legacy_and_delta_roundtrip_in_schema2_without_changing_record_ids(self):
        value = migrate_workspace(empty_workspace())
        legacy = {'id': 'legacy', 'label': '旧记录', 'at': '2026-11-01T09:00:00Z',
                  'before': empty_workspace(), 'after': empty_workspace(), 'undone': True}
        value['history'] = [legacy, delta()]
        saved = self.store.save(value, 0)
        self.assertEqual(self.store.load(), saved)
        self.assertEqual(saved['history'], value['history'])
        self.assertEqual(saved['schemaVersion'], 2)

    def test_unknown_format_and_metadata_without_format_are_rejected(self):
        for mutate in (
            lambda item: item.update(format='entity-delta-v2'),
            lambda item: item.pop('format'),
            lambda item: item.update(afterDigest='wrong'),
            lambda item: item.update(afterDigest=None),
        ):
            item = delta()
            mutate(item)
            with self.subTest(item=item), self.assertRaises(ValidationError):
                validate_change_record(item)

    def test_missing_collection_unknown_key_and_duplicate_entity_ids_are_rejected(self):
        for mutate in (
            lambda item: item['after'].pop('entries'),
            lambda item: item['after'].update(unknown=[]),
            lambda item: item['after']['tasks'].append({'id': 'task', 'title': 'Duplicate'}),
            lambda item: item['before'].update(entries=[{'id': 1}]),
            lambda item: item['before'].update(preferences={}),
        ):
            item = delta()
            mutate(item)
            with self.subTest(item=item), self.assertRaises(ValidationError):
                validate_change_record(item)

    def test_changed_collections_require_valid_before_order(self):
        for order in (None, {}, {'unknown': []}, {'tasks': ['x', 'x']}, {'tasks': [3]}):
            item = delta()
            item['beforeOrder'] = order
            with self.subTest(order=order), self.assertRaises(ValidationError):
                validate_change_record(item)
        item = delta()
        item['before']['tasks'] = [{'id': 'existing', 'title': 'Before'}]
        with self.assertRaises(ValidationError):
            validate_change_record(item)
        item['beforeOrder']['tasks'] = ['existing']
        validate_change_record(item)

    def test_completion_scope_covers_unchanged_related_entries(self):
        item = delta()
        item['label'] = '完成任务'
        with self.assertRaises(ValidationError):
            validate_change_record(item)
        item['afterTaskEntries'] = {'task': {'past-block': 'b' * 64}}
        validate_change_record(item)
        for scope in ({}, {'other-task': {}}, {'task': {'entry': 'not-a-hash'}}, {'task': []}):
            invalid = copy.deepcopy(item)
            invalid['afterTaskEntries'] = scope
            with self.subTest(scope=scope), self.assertRaises(ValidationError):
                validate_change_record(invalid)

    def test_history_limit_remains_thirty(self):
        value = migrate_workspace(empty_workspace())
        value['history'] = [{**delta(), 'id': f'change-{i}'} for i in range(30)]
        validate_workspace(value)
        value['history'].append({**delta(), 'id': 'change-30'})
        with self.assertRaises(ValidationError):
            validate_workspace(value)

    def fixture(self):
        identity = AuthStore(self.path).register({'username': 'history-test',
            'email': 'history@example.test', 'password': 'SyntheticHistory123'})
        uid = identity['user']['id']
        self.store.save(migrate_workspace(empty_workspace()), 0, uid)
        sync = SyncStore(self.path)
        operations = [
            {'id': 'create-task', 'entityType': 'tasks', 'entityId': 'task', 'expectedVersion': 0,
             'action': 'upsert', 'value': {'id': 'task', 'title': 'Task'}},
            {'id': 'create-history', 'entityType': 'history', 'entityId': 'change', 'expectedVersion': 0,
             'action': 'upsert', 'value': delta()},
        ]
        return uid, sync, operations

    def test_sync_replays_same_delta_body_and_preserves_metadata_when_marked_undone(self):
        uid, sync, operations = self.fixture()
        saved = sync.apply(uid, {'operations': operations})
        replayed = sync.apply(uid, {'operations': operations})
        self.assertEqual(saved['workspace'], replayed['workspace'])
        self.assertEqual(replayed['applied'], [])
        undone = {**delta(), 'undone': True}
        result = sync.apply(uid, {'operations': [{'id': 'mark-undone', 'entityType': 'history',
            'entityId': 'change', 'expectedVersion': saved['entityVersions']['history/change'],
            'action': 'upsert', 'value': undone}]})
        self.assertEqual(result['workspace']['history'], [undone])
        self.assertEqual(len(result['workspace']['tasks']), 1)

    def test_stale_history_version_and_invalid_delta_roll_back_the_whole_batch(self):
        uid, sync, operations = self.fixture()
        initial = sync.apply(uid, {'operations': operations})['workspace']
        new_task = {'id': 'another-write', 'entityType': 'tasks', 'entityId': 'other',
                    'expectedVersion': 0, 'action': 'upsert', 'value': {'id': 'other', 'title': 'Other'}}
        stale = {**operations[1], 'id': 'stale-history'}
        with self.assertRaises(SyncConflict):
            sync.apply(uid, {'operations': [new_task, stale]})
        self.assertEqual(sync.load(uid), initial)
        invalid = {**stale, 'expectedVersion': 1,
                   'value': {**delta(), 'format': 'unknown-format'}}
        with self.assertRaises(ValidationError):
            sync.apply(uid, {'operations': [new_task, invalid]})
        self.assertEqual(sync.load(uid), initial)

    def test_legacy_workspace_rewrite_preserves_metadata_and_history_version(self):
        uid, sync, operations = self.fixture()
        operations[1]['value'].update(label='完成任务', afterTaskEntries={'task': {'past': 'b' * 64}})
        original = sync.apply(uid, {'operations': operations})['workspace']
        incoming = copy.deepcopy(original)
        incoming['history'] = [old_client_record(original['history'][0])]
        original_body = copy.deepcopy(incoming)
        saved = self.store.save(incoming, incoming['revision'], uid)
        self.assertEqual(saved['history'], original['history'])
        self.assertEqual(saved['entityVersions']['history/change'], original['entityVersions']['history/change'])
        self.assertEqual(incoming, original_body)
        self.assertEqual(self.store.load(uid), saved)

    def test_changed_legacy_workspace_downgrade_is_rejected_without_writing(self):
        uid, sync, operations = self.fixture()
        original = sync.apply(uid, {'operations': operations})['workspace']
        for mutate in (
            lambda item: item.update(label='Changed'),
            lambda item: item.update(at='2026-11-02T01:00:00Z'),
            lambda item: item.update(undone=True),
            lambda item: item['before']['tasks'].append({'id': 'another'}),
            lambda item: item['after']['tasks'][0].update(title='Changed'),
        ):
            incoming = copy.deepcopy(original)
            incoming['history'] = [old_client_record(original['history'][0])]
            mutate(incoming['history'][0])
            incoming['tasks'][0]['title'] = 'Uncommitted edit'
            with self.subTest(record=incoming['history'][0]), self.assertRaises(ValidationError):
                self.store.save(incoming, incoming['revision'], uid)
            self.assertEqual(self.store.load(uid), original)

    def test_legacy_sync_rewrite_keeps_original_pending_body_and_idempotency_digest(self):
        uid, sync, operations = self.fixture()
        original = sync.apply(uid, {'operations': operations})['workspace']
        batch = {'operations': [{'id': 'old-client-rewrite', 'entityType': 'history',
            'entityId': 'change', 'expectedVersion': original['entityVersions']['history/change'],
            'action': 'upsert', 'value': old_client_record(original['history'][0])}]}
        pending_body = json.dumps(batch, sort_keys=True, separators=(',', ':'))
        saved = sync.apply(uid, batch)
        self.assertEqual(saved['workspace']['history'], original['history'])
        self.assertEqual(json.dumps(batch, sort_keys=True, separators=(',', ':')), pending_body)
        replayed = sync.apply(uid, json.loads(pending_body))
        self.assertEqual(replayed['workspace'], saved['workspace'])
        self.assertEqual(replayed['applied'], [])
        self.assertEqual(replayed['replayed'], ['old-client-rewrite'])
        rewritten = copy.deepcopy(batch)
        rewritten['operations'][0]['value'] = copy.deepcopy(original['history'][0])
        with self.assertRaises(SyncConflict) as reused:
            sync.apply(uid, rewritten)
        self.assertEqual(reused.exception.conflicts[0]['reason'], 'idempotency_key_reused')

    def test_changed_legacy_sync_downgrade_rolls_back_every_operation_and_receipt(self):
        uid, sync, operations = self.fixture()
        original = sync.apply(uid, {'operations': operations})['workspace']
        incoming = old_client_record(original['history'][0])
        incoming['undone'] = True
        batch = {'operations': [
            {'id': 'uncommitted-task', 'entityType': 'tasks', 'entityId': 'other',
             'expectedVersion': 0, 'action': 'upsert', 'value': {'id': 'other', 'title': 'Other'}},
            {'id': 'legacy-downgrade', 'entityType': 'history', 'entityId': 'change',
             'expectedVersion': original['entityVersions']['history/change'],
             'action': 'upsert', 'value': incoming},
        ]}
        with self.assertRaises(ValidationError):
            sync.apply(uid, batch)
        self.assertEqual(sync.load(uid), original)
        with sync.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM sync_operations WHERE user_id=? AND operation_id IN (?,?)',
                (uid, 'uncommitted-task', 'legacy-downgrade')).fetchone()[0], 0)

    def test_preservation_does_not_cross_accounts_or_record_ids(self):
        uid, sync, operations = self.fixture()
        original = sync.apply(uid, {'operations': operations})['workspace']
        other_uid = AuthStore(self.path).register({'username': 'other-history',
            'email': 'other-history@example.test', 'password': 'SyntheticHistory123'})['user']['id']
        other = migrate_workspace(empty_workspace())
        other['history'] = [old_client_record(original['history'][0])]
        saved = self.store.save(other, 0, other_uid)
        self.assertNotIn('format', saved['history'][0])
        result = sync.apply(other_uid, {'operations': [{'id': 'old-client-other-account',
            'entityType': 'history', 'entityId': 'change',
            'expectedVersion': saved['entityVersions']['history/change'], 'action': 'upsert',
            'value': old_client_record(original['history'][0])}]})
        self.assertNotIn('format', result['workspace']['history'][0])
        incoming = copy.deepcopy(original)
        incoming['history'].append({**old_client_record(original['history'][0]), 'id': 'different-id'})
        saved = self.store.save(incoming, incoming['revision'], uid)
        self.assertEqual(saved['history'][0], original['history'][0])
        self.assertNotIn('format', saved['history'][1])
        self.assertEqual(self.store.load(other_uid), result['workspace'])

    def test_legacy_rewrite_does_not_bypass_workspace_or_entity_cas(self):
        uid, sync, operations = self.fixture()
        original = sync.apply(uid, {'operations': operations})['workspace']
        incoming = copy.deepcopy(original)
        incoming['history'] = [old_client_record(original['history'][0])]
        incoming['revision'] -= 1
        with self.assertRaises(ConflictError):
            self.store.save(incoming, incoming['revision'], uid)
        with self.assertRaises(SyncConflict):
            sync.apply(uid, {'operations': [{'id': 'stale-legacy-write', 'entityType': 'history',
                'entityId': 'change', 'expectedVersion': original['entityVersions']['history/change'] - 1,
                'action': 'upsert', 'value': incoming['history'][0]}]})
        self.assertEqual(sync.load(uid), original)

    def test_only_exact_old_record_shape_can_restore_metadata(self):
        uid, sync, operations = self.fixture()
        original = sync.apply(uid, {'operations': operations})['workspace']
        for extra in ({'format': None}, {'afterDigest': 'a' * 64}, {'unexpected': True}):
            record = {**old_client_record(original['history'][0]), **extra}
            incoming = {**original, 'history': [record]}
            with self.subTest(extra=extra, path='put'), self.assertRaises(ValidationError):
                self.store.save(incoming, incoming['revision'], uid)
            with self.subTest(extra=extra, path='sync'), self.assertRaises(ValidationError):
                sync.apply(uid, {'operations': [{'id': 'invalid-legacy-write', 'entityType': 'history',
                    'entityId': 'change', 'expectedVersion': original['entityVersions']['history/change'],
                    'action': 'upsert', 'value': record}]})
        self.assertEqual(sync.load(uid), original)

    def test_openapi_exposes_optional_format_on_schema2_history(self):
        app = FastAPI()
        async def compatibility(request):
            return {}
        install_contract(app, compatibility)
        schemas = app.openapi()['components']['schemas']
        record = schemas['ChangeRecord']
        self.assertNotIn('format', record['required'])
        self.assertEqual(record['properties']['format']['enum'], ['entity-delta-v1'])
        self.assertEqual(schemas['Workspace']['properties']['schemaVersion']['maximum'], 2)
        self.assertEqual(schemas['Workspace']['properties']['history']['maxItems'], 30)


if __name__ == '__main__':
    unittest.main()
