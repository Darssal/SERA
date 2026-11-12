"""Planning result references and atomic source completion, using temporary SQLite only."""
import copy
import tempfile
from pathlib import Path
import unittest

from fastapi import FastAPI
from api_contract import install_contract
from auth_store import AuthStore
from server import (ValidationError, WorkspaceStore, planning_result_id,
                    validate_workspace)
from sync_store import SyncStore, migrate_workspace
from test_server import empty_workspace


def pending():
    value = migrate_workspace(empty_workspace())
    value['planningSessions'] = [{'id': 'source-input', 'prompt': 'Synthetic input',
        'notes': 'Keep these notes', 'stage': 'understood', 'dailyBudget': 90,
        'updatedAt': '2026-10-31T12:00:00+08:00'}]
    return value


def completed(value, kind='task'):
    result = {'kind': kind, 'id': planning_result_id('source-input', kind)}
    value = copy.deepcopy(value)
    value['planningSessions'][0].update(stage='confirmed', resultEntity=result)
    if kind == 'task':
        value['tasks'] = [{'id': result['id'], 'title': 'Saved synthetic task'}]
    else:
        value['entries'] = [{'id': result['id'], 'title': 'Saved synthetic event',
            'start': '2026-11-01T15:00:00+08:00', 'end': '2026-11-01T15:30:00+08:00'}]
    return value


class PlanningResultContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / 'planning-results.db'
        self.store = WorkspaceStore(self.path)
        self.initial = self.store.save(pending(), 0)

    def tearDown(self):
        self.temp.cleanup()

    def test_old_sessions_missing_or_null_result_keep_the_existing_schema(self):
        value = pending()
        validate_workspace(value)
        value['planningSessions'][0]['resultEntity'] = None
        validate_workspace(value)
        self.assertEqual(value['planningSessions'][0]['stage'], 'understood')

    def test_malformed_result_kind_id_stage_and_unstable_id_are_rejected(self):
        valid = completed(pending())
        mutations = [None, 'task', [], {}, {'kind': 'goal', 'id': 'x'},
            {'kind': 'task', 'id': ''}, {'kind': 'task', 'id': 42},
            {'kind': 'task', 'id': 'different'},
            {**valid['planningSessions'][0]['resultEntity'], 'extra': True}]
        for result in mutations:
            value = copy.deepcopy(valid)
            value['planningSessions'][0]['resultEntity'] = result
            if result is None:
                value['planningSessions'][0]['stage'] = 'understood'
                validate_workspace(value)  # Null is explicitly legacy-compatible.
                continue
            with self.subTest(result=result), self.assertRaises(ValidationError):
                validate_workspace(value)
        valid['planningSessions'][0]['stage'] = 'understood'
        with self.assertRaises(ValidationError):
            validate_workspace(valid)

    def test_task_and_completion_are_saved_in_the_same_workspace(self):
        saved = self.store.save(completed(self.initial), self.initial['revision'])
        loaded = WorkspaceStore(self.path).load()
        self.assertEqual(loaded, saved)
        self.assertEqual(loaded['planningSessions'][0]['resultEntity']['id'], loaded['tasks'][0]['id'])
        self.assertEqual(loaded['planningSessions'][0]['stage'], 'confirmed')

    def test_event_and_completion_are_saved_in_the_same_workspace(self):
        saved = self.store.save(completed(self.initial, 'event'), self.initial['revision'])
        self.assertEqual(saved['planningSessions'][0]['resultEntity']['id'], saved['entries'][0]['id'])
        self.assertEqual(saved['tasks'], [])

    def test_missing_result_entity_rolls_back_without_marking_session_completed(self):
        value = completed(self.initial)
        value['tasks'] = []
        with self.assertRaises(ValidationError):
            self.store.save(value, self.initial['revision'])
        self.assertEqual(self.store.load(), self.initial)

    def test_confirmed_reference_cannot_be_downgraded_or_rebound(self):
        saved = self.store.save(completed(self.initial), self.initial['revision'])
        for key, replacement in [('resultEntity', None), ('stage', 'input')]:
            value = copy.deepcopy(saved)
            value['planningSessions'][0][key] = replacement
            with self.subTest(key=key), self.assertRaises(ValidationError):
                self.store.save(value, saved['revision'])
            self.assertEqual(self.store.load(), saved)
        value = completed(saved, 'event')
        with self.assertRaises(ValidationError):
            self.store.save(value, saved['revision'])

    def test_later_delete_retains_confirmed_reference_and_history_can_be_cleared(self):
        saved = self.store.save(completed(self.initial), self.initial['revision'])
        deleted = copy.deepcopy(saved)
        deleted['tasks'] = []
        deleted = self.store.save(deleted, saved['revision'])
        self.assertEqual(deleted['planningSessions'][0]['stage'], 'confirmed')
        self.assertIsNotNone(deleted['planningSessions'][0]['resultEntity'])
        deleted['planningSessions'] = []
        cleared = self.store.save(deleted, deleted['revision'])
        self.assertEqual(cleared['planningSessions'], [])

    def sync_fixture(self):
        accounts = AuthStore(self.path)
        identity = accounts.register({'username': 'result-account', 'email': 'result@example.test',
                                      'password': 'SyntheticPassword123'})
        uid = identity['user']['id']
        sync = SyncStore(self.path)
        initial = WorkspaceStore(self.path).save(pending(), 0, uid)
        target = completed(initial)
        task, session = target['tasks'][0], target['planningSessions'][0]
        operations = [
            {'id': 'result-task-op', 'entityType': 'tasks', 'entityId': task['id'],
             'expectedVersion': 0, 'action': 'upsert', 'value': task},
            {'id': 'result-session-op', 'entityType': 'planningSessions', 'entityId': session['id'],
             'expectedVersion': initial['entityVersions']['planningSessions/source-input'],
             'action': 'upsert', 'value': session}]
        return uid, sync, initial, operations

    def test_sync_batch_is_atomic_and_replays_the_original_operation_ids(self):
        uid, sync, _, operations = self.sync_fixture()
        saved = sync.apply(uid, {'operations': operations})
        replay = sync.apply(uid, {'operations': operations})
        self.assertEqual(saved['workspace'], replay['workspace'])
        self.assertEqual(replay['applied'], [])
        self.assertEqual(replay['replayed'], ['result-task-op', 'result-session-op'])
        self.assertEqual(len(replay['workspace']['tasks']), 1)

    def test_invalid_partial_sync_does_not_consume_receipts_or_complete_session(self):
        uid, sync, initial, operations = self.sync_fixture()
        with self.assertRaises(ValidationError):
            sync.apply(uid, {'operations': operations[1:]})
        self.assertEqual(sync.load(uid), initial)
        saved = sync.apply(uid, {'operations': operations})
        self.assertEqual(len(saved['workspace']['tasks']), 1)
        stale = copy.deepcopy(initial['planningSessions'][0])
        with self.assertRaises(ValidationError):
            sync.apply(uid, {'operations': [{'id': 'stale-autosave', 'entityType': 'planningSessions',
                'entityId': stale['id'], 'expectedVersion': saved['entityVersions']['planningSessions/source-input'],
                'action': 'upsert', 'value': stale}]})
        self.assertEqual(sync.load(uid), saved['workspace'])

    def test_event_result_cannot_claim_a_task_time_block(self):
        value = completed(self.initial, 'event')
        value['tasks'] = [{'id': 'linked-task', 'title': 'Linked task'}]
        value['entries'][0]['taskId'] = 'linked-task'
        with self.assertRaises(ValidationError):
            self.store.save(value, self.initial['revision'])
        self.assertEqual(self.store.load(), self.initial)

    def exported_mixed_workspace(self):
        value = pending()
        legacy = value['planningSessions'][0]
        legacy['id'] = 'old-without-ref'
        legacy['stage'] = 'confirmed'
        for kind in ('task', 'event'):
            for state in ('live', 'deleted'):
                session_id = f'{kind}-{state}-source'
                result = {'kind': kind, 'id': planning_result_id(session_id, kind)}
                value['planningSessions'].append({**legacy, 'id': session_id, 'resultEntity': result})
                if kind == 'task':
                    value['tasks'].append({'id': result['id'], 'title': f'Synthetic {state} task'})
                else:
                    value['entries'].append({'id': result['id'], 'title': f'Synthetic {state} event',
                        'start': '2026-11-01T15:00:00+08:00', 'end': '2026-11-01T15:30:00+08:00'})
        value['revision'] = self.initial['revision']
        saved = self.store.save(value, value['revision'])
        deleted_ids = {item['resultEntity']['id'] for item in saved['planningSessions']
                       if item['id'].endswith('-deleted-source')}
        saved['tasks'] = [item for item in saved['tasks'] if item['id'] not in deleted_ids]
        saved['entries'] = [item for item in saved['entries'] if item['id'] not in deleted_ids]
        return self.store.save(saved, saved['revision'])

    def import_target(self, *, existing=False):
        accounts = AuthStore(self.path)
        identity = accounts.register({'username': 'import-account', 'email': 'import@example.test',
                                      'password': 'SyntheticPassword123'})
        uid = identity['user']['id']
        if existing:
            saved = self.store.save(pending(), 0, uid)
            return uid, saved['revision']
        return uid, 0

    def assert_mixed_import(self, *, existing):
        exported = self.exported_mixed_workspace()
        uid, expected = self.import_target(existing=existing)
        exported['revision'] = expected
        saved = self.store.save(exported, expected, uid, legacy_import=True)
        self.assertEqual(saved['schemaVersion'], 2)
        self.assertEqual(len(saved['planningSessions']), 5)
        self.assertEqual(len(saved['tasks']), 1)
        self.assertEqual(len(saved['entries']), 1)
        self.assertEqual(saved['planningSessions'], exported['planningSessions'])
        self.assertEqual(saved['tasks'], exported['tasks'])
        self.assertEqual(saved['entries'], exported['entries'])
        self.assertEqual(WorkspaceStore(self.path).load(uid), saved)
        self.assertEqual(SyncStore(self.path).load(uid)['planningSessions'], exported['planningSessions'])

    def test_whole_workspace_import_into_empty_account_preserves_live_results_tombstones_and_legacy(self):
        self.assert_mixed_import(existing=False)

    def test_whole_workspace_import_into_existing_account_preserves_results_without_resurrection(self):
        self.assert_mixed_import(existing=True)

    def test_import_flag_still_rejects_rebound_or_downgraded_existing_results(self):
        exported = self.exported_mixed_workspace()
        uid, expected = self.import_target()
        exported['revision'] = expected
        saved = self.store.save(exported, expected, uid, legacy_import=True)
        for key, replacement in [('resultEntity', None), ('stage', 'input')]:
            value = copy.deepcopy(saved)
            value['planningSessions'][1][key] = replacement
            with self.subTest(key=key), self.assertRaises(ValidationError):
                self.store.save(value, saved['revision'], uid, legacy_import=True)
            self.assertEqual(self.store.load(uid), saved)
        value = copy.deepcopy(saved)
        session = value['planningSessions'][1]
        session['resultEntity'] = {'kind': 'event', 'id': planning_result_id(session['id'], 'event')}
        with self.assertRaises(ValidationError):
            self.store.save(value, saved['revision'], uid, legacy_import=True)
        self.assertEqual(self.store.load(uid), saved)

    def test_import_flag_does_not_bypass_result_shape_stable_id_or_confirmed_stage_validation(self):
        uid, expected = self.import_target()
        for result, stage in [({'kind': 'task', 'id': 'unstable'}, 'confirmed'),
                              ({'kind': 'goal', 'id': 'bad'}, 'confirmed'),
                              ({'kind': 'task', 'id': planning_result_id('source-input', 'task'), 'extra': True}, 'confirmed'),
                              ({'kind': 'task', 'id': planning_result_id('source-input', 'task')}, 'input')]:
            value = pending()
            value['revision'] = expected
            value['planningSessions'][0].update(resultEntity=result, stage=stage)
            with self.subTest(result=result, stage=stage), self.assertRaises(ValidationError):
                self.store.save(value, expected, uid, legacy_import=True)
            self.assertIsNone(self.store.load(uid))

    def test_imported_event_reference_still_cannot_claim_an_existing_task_block(self):
        uid, expected = self.import_target()
        value = completed(pending(), 'event')
        value['revision'] = expected
        value['tasks'] = [{'id': 'linked-task', 'title': 'Synthetic linked task'}]
        value['entries'][0]['taskId'] = 'linked-task'
        with self.assertRaises(ValidationError):
            self.store.save(value, expected, uid, legacy_import=True)
        self.assertIsNone(self.store.load(uid))

    def test_normal_sync_rejects_first_dangling_result_even_after_an_import(self):
        uid, expected = self.import_target()
        value = pending()
        value['revision'] = expected
        initial = self.store.save(value, expected, uid, legacy_import=True)
        session = completed(initial)['planningSessions'][0]
        sync = SyncStore(self.path)
        with self.assertRaises(ValidationError):
            sync.apply(uid, {'operations': [{'id': 'dangling-after-import', 'entityType': 'planningSessions',
                'entityId': session['id'], 'expectedVersion': initial['entityVersions']['planningSessions/source-input'],
                'action': 'upsert', 'value': session}]})
        self.assertEqual(sync.load(uid), initial)

    def test_openapi_exposes_optional_typed_result_without_changing_workspace_version(self):
        app = FastAPI()
        async def compatibility(request):
            return {}
        install_contract(app, compatibility)
        schemas = app.openapi()['components']['schemas']
        self.assertEqual(schemas['PlanningResultRef']['properties']['kind']['enum'], ['task', 'event'])
        self.assertNotIn('resultEntity', schemas['PlanningSession']['required'])
        self.assertEqual(schemas['Workspace']['properties']['schemaVersion']['maximum'], 2)


if __name__ == '__main__':
    unittest.main()
