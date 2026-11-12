"""A focus target is a compatible bounded session field, independent of work."""
from copy import deepcopy
from pathlib import Path
import tempfile
import unittest

from fastapi import FastAPI
from fastapi.testclient import TestClient

from api_contract import install_contract
from app import create_app
from server import ValidationError, validate_workspace
from sync_store import migrate_workspace
from test_app import StubAi
from test_server import empty_workspace


def workspace():
    value = migrate_workspace(empty_workspace())
    value['tasks'] = [{'id': 'task-focus', 'title': '跨多天整理考试范围', 'estimatedMinutes': 75}]
    value['focusSession'] = {'id': 'focus-session', 'taskId': 'task-focus',
        'startedAt': '2026-11-02T09:00:00+08:00', 'isRunning': False,
        'accumulatedSeconds': 73, 'targetMinutes': 15}
    return value


class FocusTargetTests(unittest.TestCase):
    def test_legacy_missing_or_null_target_remains_valid_and_does_not_change_estimate(self):
        value = workspace()
        value['focusSession'].pop('targetMinutes')
        validate_workspace(value)
        value['focusSession']['targetMinutes'] = None
        validate_workspace(value)
        self.assertEqual(value['tasks'][0]['estimatedMinutes'], 75)

    def test_target_is_a_bounded_integer_and_never_a_boolean(self):
        for target in (0, -1, 1441, True, False, '15', 15.0, {}, []):
            with self.subTest(target=target):
                value = workspace()
                value['focusSession']['targetMinutes'] = target
                with self.assertRaisesRegex(ValidationError, 'focusSession.targetMinutes'):
                    validate_workspace(value)
        for target in (1, 15, 1440):
            value = workspace()
            value['focusSession']['targetMinutes'] = target
            validate_workspace(value)

    def test_openapi_documents_optional_target_without_schema_upgrade(self):
        app = FastAPI()
        async def compatibility(request): return {}
        install_contract(app, compatibility)
        schemas = app.openapi()['components']['schemas']
        session = schemas['FocusSession']
        self.assertNotIn('targetMinutes', session['required'])
        self.assertEqual(session['properties']['targetMinutes']['type'], ['integer', 'null'])
        self.assertEqual(session['properties']['targetMinutes']['minimum'], 1)
        self.assertEqual(session['properties']['targetMinutes']['maximum'], 1440)
        self.assertEqual(schemas['Workspace']['properties']['schemaVersion']['maximum'], 2)

    def test_real_put_sync_reload_and_replay_preserve_target_and_actual_time(self):
        with tempfile.TemporaryDirectory() as directory:
            app = create_app(db_path=Path(directory) / 'focus.db', ai_service=StubAi(), transcriber=object())
            with TestClient(app) as client:
                identity = app.state.accounts.register({'username': 'focus-target',
                    'email': 'focus@example.test', 'password': 'CorrectPassword123'})
                client.headers.update({'Authorization': 'Bearer ' + identity['token']})
                response = client.put('/api/v1/workspace', json={'workspace': workspace(), 'expectedRevision': 0})
                self.assertEqual(response.status_code, 200, response.text)
                saved = response.json()['workspace']
                self.assertEqual(saved['focusSession']['targetMinutes'], 15)
                continued = deepcopy(saved['focusSession'])
                continued.update(isRunning=True, lastResumedAt='2026-11-03T09:00:00+08:00')
                batch = {'operations': [{'id': 'continue-focus', 'entityType': 'focusSession',
                    'entityId': 'singleton', 'action': 'upsert', 'value': continued,
                    'expectedVersion': saved['entityVersions']['focusSession/singleton']}]}
                first = client.post('/api/v1/sync/operations', json=batch)
                self.assertEqual(first.status_code, 200, first.text)
                result = first.json()['workspace']
                self.assertEqual(result['focusSession']['targetMinutes'], 15)
                self.assertEqual(result['focusSession']['accumulatedSeconds'], 73)
                self.assertEqual(result['tasks'][0]['estimatedMinutes'], 75)
                replay = client.post('/api/v1/sync/operations', json=batch)
                self.assertEqual(replay.status_code, 200, replay.text)
                self.assertEqual(replay.json()['workspace'], result)
                self.assertEqual(replay.json()['replayed'], ['continue-focus'])
                self.assertEqual(client.get('/api/v1/workspace').json()['workspace'], result)
                invalid = deepcopy(result)
                invalid['focusSession']['targetMinutes'] = True
                rejected = client.put('/api/v1/workspace', json={
                    'workspace': invalid, 'expectedRevision': result['revision']})
                self.assertEqual(rejected.status_code, 400)
                self.assertEqual(client.get('/api/v1/workspace').json()['workspace'], result)


if __name__ == '__main__': unittest.main()
