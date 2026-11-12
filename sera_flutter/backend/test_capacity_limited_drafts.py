"""Capacity consent preserves complete plans without bypassing real placement.

All requests use an in-process authenticated client and a temporary SQLite DB.
No AI, SMS, mail, production service, or production workspace is accessed.
"""
from copy import deepcopy
from datetime import datetime
from pathlib import Path
import tempfile
import unittest

from fastapi.testclient import TestClient

from ai_service import SiliconFlowPlanner
from app import create_app
from server import ValidationError, WorkspaceStore, validate_workspace
from sync_store import migrate_workspace
from test_server import empty_workspace
from test_soft_budget_placement import operations


def pending_workspace(*, all_unplanned=False):
    value = migrate_workspace(empty_workspace())
    value['preferences'].update(dailyBudget=180, startMinute=9 * 60,
        endMinute=11 * 60, weekdays=[1, 2, 3, 4, 5, 6, 7], bufferMinutes=15,
        restStart=12 * 60, restEnd=13 * 60)
    items = []
    # Two complete phases, each 825 minutes, matching the reported total of
    # 1,650 minutes. Only the first complete task has actual calendar blocks.
    for index, minutes in enumerate([210, 210, 210, 195] * 2):
        first_phase = index < 4
        task = {'id': f'task-capacity-{index}', 'goalId': 'goal-capacity',
            'title': f'执行步骤 {index + 1}', 'estimatedMinutes': minutes,
            'phase': '第一周' if first_phase else '第二周',
            'notBefore': '2099-11-02T00:00:00+08:00' if first_phase else '2099-11-09T00:00:00+08:00',
            'dueAt': '2099-11-06T23:59:00+08:00' if first_phase else '2099-11-15T23:59:00+08:00',
            'splittable': True, 'minBlockMinutes': 15, 'status': 'todo',
            'checklist': [f'检查步骤 {index + 1}'], 'completedChecks': []}
        item = {'task': task, 'entry': None, 'additionalEntries': []}
        if index == 0 and not all_unplanned:
            blocks = [{'id': f'entry-capacity-{day}', 'taskId': task['id'],
                'title': task['title'], 'start': f'2099-11-{day:02}T09:00:00+08:00',
                'end': f'2099-11-{day:02}T10:45:00+08:00'} for day in (2, 3)]
            item.update(entry=blocks[0], additionalEntries=blocks[1:])
        items.append(item)
    goal = {'id': 'goal-capacity', 'title': '15 天完整计划',
        'deadline': '2099-11-15T23:59:00+08:00',
        'taskIds': [item['task']['id'] for item in items]}
    value['drafts'] = [{'id': 'draft-capacity', 'goal': goal, 'status': 'draft',
        'items': items, 'capacityLimited': True, 'capacityConfirmed': False}]
    return value


def committed_workspace(previous, *, confirmed=True):
    value = deepcopy(previous)
    draft = value['drafts'][0]
    draft.update(status='committed', capacityConfirmed=confirmed)
    value['goals'] = [deepcopy(draft['goal'])]
    value['tasks'] = [deepcopy(item['task']) for item in draft['items']]
    value['entries'] = [deepcopy(block) for item in draft['items']
        for block in ([item['entry']] if item.get('entry') else []) + item.get('additionalEntries', [])]
    return value


class CapacityDraftValidationTests(unittest.TestCase):
    def test_pending_and_confirmed_flags_survive_storage_without_creating_tasks(self):
        with tempfile.TemporaryDirectory() as directory:
            store = WorkspaceStore(Path(directory) / 'capacity.db')
            value = pending_workspace()
            saved = store.save(value, 0)
            self.assertEqual(store.load()['drafts'], value['drafts'])
            saved['drafts'][0]['capacityConfirmed'] = True
            result = store.save(saved, saved['revision'])
            self.assertTrue(result['drafts'][0]['capacityConfirmed'])
            self.assertEqual(result['tasks'], [])
            self.assertEqual(result['entries'], [])
            self.assertEqual(result['preferences'], value['preferences'])

    def test_missing_flags_remain_compatible_with_legacy_committed_unscheduled_tasks(self):
        value = committed_workspace(pending_workspace(all_unplanned=True))
        draft = value['drafts'][0]
        draft.pop('capacityLimited')
        draft.pop('capacityConfirmed')
        validate_workspace(value)
        draft.update(capacityLimited=False, capacityConfirmed=False)
        validate_workspace(value)

    def test_invalid_flag_types_and_confirmation_without_warning_are_validation_errors(self):
        changes = [{'capacityLimited': wrong} for wrong in (None, 0, 1, 'true', [], {})]
        changes += [{'capacityConfirmed': wrong} for wrong in (None, 0, 1, 'true', [], {})]
        changes += [{'capacityLimited': False, 'capacityConfirmed': True}]
        for change in changes:
            with self.subTest(change=change):
                value = pending_workspace()
                value['drafts'][0].update(change)
                with self.assertRaises(ValidationError):
                    validate_workspace(value)

    def test_active_status_matches_flutter_including_legacy_done_and_status_precedence(self):
        for status, legacy_done, requires_confirmation in (
                ('todo', False, True), ('in_progress', False, True),
                ('blocked', False, True), ('done', False, False),
                ('canceled', False, False), (None, True, False),
                (None, False, True), ('todo', True, True)):
            with self.subTest(status=status, legacy_done=legacy_done):
                value = committed_workspace(pending_workspace(all_unplanned=True), confirmed=False)
                # Test a single unscheduled task, since terminal siblings must
                # not independently cause a pending-confirmation rejection.
                draft = value['drafts'][0]
                draft['items'] = draft['items'][:1]
                value['tasks'] = value['tasks'][:1]
                for task in (draft['items'][0]['task'], value['tasks'][0]):
                    task['done'] = legacy_done
                    if status is None:
                        task.pop('status', None)
                    else:
                        task['status'] = status
                value['goals'][0]['taskIds'] = draft['goal']['taskIds'] = [value['tasks'][0]['id']]
                if requires_confirmation:
                    with self.assertRaisesRegex(ValidationError, 'capacity-limited plan must be confirmed'):
                        validate_workspace(value)
                else:
                    validate_workspace(value)

    def test_additional_only_block_is_scheduled_and_empty_draft_does_not_require_capacity_consent(self):
        value = committed_workspace(pending_workspace(), confirmed=False)
        draft = value['drafts'][0]
        draft['items'] = draft['items'][:1]
        first = draft['items'][0]
        first['additionalEntries'].insert(0, first.pop('entry'))
        first['entry'] = None
        value['tasks'] = value['tasks'][:1]
        value['goals'][0]['taskIds'] = draft['goal']['taskIds'] = [value['tasks'][0]['id']]
        validate_workspace(value)
        draft['items'] = []
        validate_workspace(value)


class CapacityPlacementTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.app = create_app(db_path=Path(self.temp.name) / 'capacity-placement.db',
            ai_service=SiliconFlowPlanner(), transcriber=object())
        identity = self.app.state.accounts.register({'username': 'capacity-placement',
            'email': 'capacity@example.test', 'password': 'CorrectPassword123'})
        self.client = TestClient(self.app)
        self.client.headers.update({'Authorization': 'Bearer ' + identity['token']})
        self.saved = self.put(pending_workspace())

    def tearDown(self):
        self.client.close()
        self.temp.cleanup()

    def put(self, value):
        response = self.client.put('/api/v1/workspace', json={
            'workspace': value, 'expectedRevision': value['revision']})
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()['workspace']

    def assert_preserved_plan(self, result, *, entry_count=2):
        self.assertEqual(len(result['tasks']), 8)
        self.assertEqual(sum(task['estimatedMinutes'] for task in result['tasks']), 1650)
        self.assertEqual(len(result['entries']), entry_count)
        self.assertEqual(result['preferences'], self.saved['preferences'])
        self.assertTrue(result['drafts'][0]['capacityConfirmed'])
        self.assertEqual(result['drafts'][0]['items'], self.saved['drafts'][0]['items'])
        scheduled = {entry['taskId'] for entry in result['entries']}
        self.assertEqual(scheduled, {'task-capacity-0'} if entry_count else set())
        self.assertEqual(len([task for task in result['tasks'] if task['id'] not in scheduled]),
            7 if entry_count else 8)

    def assert_saved_unchanged(self):
        response = self.client.get('/api/v1/workspace')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()['workspace'], self.saved)
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM sync_operations').fetchone()[0], 0)

    def reject_both_transports(self, value, *, expected_error=None):
        response = self.client.put('/api/v1/workspace', json={
            'workspace': value, 'expectedRevision': self.saved['revision']})
        self.assertEqual(response.status_code, 400, response.text)
        self.assertIsInstance(response.json().get('error'), str)
        if expected_error:
            self.assertIn(expected_error, response.json()['error'])
        self.assert_saved_unchanged()
        response = self.client.post('/api/v1/sync/operations', json=operations(self.saved, value))
        self.assertEqual(response.status_code, 400, response.text)
        if expected_error:
            self.assertIn(expected_error, response.json()['error'])
        self.assert_saved_unchanged()

    def test_put_confirmed_plan_preserves_all_tasks_and_only_actual_prefix_blocks(self):
        approved = deepcopy(self.saved)
        approved['drafts'][0]['capacityConfirmed'] = True
        self.saved = self.put(approved)
        self.assertEqual(self.saved['tasks'], [])
        result = self.put(committed_workspace(self.saved))
        self.assert_preserved_plan(result)
        # Repeat save with the current revision is harmless and never creates
        # additional objects even though workspace replacement advances revision.
        repeated = self.put(result)
        for key in ('tasks', 'entries', 'goals', 'drafts'):
            self.assertEqual(repeated[key], result[key])

    def test_sync_commit_is_atomic_and_exact_replay_does_not_duplicate(self):
        batch = operations(self.saved, committed_workspace(self.saved))
        first = self.client.post('/api/v1/sync/operations', json=batch)
        self.assertEqual(first.status_code, 200, first.text)
        result = first.json()['workspace']
        self.assert_preserved_plan(result)
        replay = self.client.post('/api/v1/sync/operations', json=batch)
        self.assertEqual(replay.status_code, 200, replay.text)
        self.assertEqual(replay.json()['workspace'], result)
        self.assertEqual(len(replay.json()['replayed']), 12)

    def test_all_unscheduled_confirmed_plan_can_be_saved_without_any_calendar_blocks(self):
        self.saved = self.put(pending_workspace(all_unplanned=True) | {'revision': self.saved['revision']})
        result = self.put(committed_workspace(self.saved))
        self.assert_preserved_plan(result, entry_count=0)

    def test_unconfirmed_commit_and_malformed_flags_reject_atomically_as_validation_errors(self):
        self.reject_both_transports(committed_workspace(self.saved, confirmed=False),
            expected_error='capacity-limited plan must be confirmed')
        for change in ({'capacityLimited': False, 'capacityConfirmed': True},
                       {'capacityConfirmed': 'true'}, {'capacityLimited': 1}):
            with self.subTest(change=change):
                value = committed_workspace(self.saved)
                value['drafts'][0].update(change)
                self.reject_both_transports(value, expected_error='draft capacity')

    def test_capacity_confirmation_does_not_grant_budget_override_or_placement_bypass(self):
        for condition in ('overlap', 'workday', 'work-window', 'rest', 'deadline',
                          'phase', 'buffer', 'daily-budget', 'dependency'):
            with self.subTest(condition=condition):
                value = committed_workspace(self.saved)
                first = value['drafts'][0]['items'][0]
                entry, task = value['entries'][0], value['tasks'][0]
                if condition == 'overlap':
                    value['entries'].append({**entry, 'id': 'busy', 'taskId': None})
                elif condition == 'workday':
                    weekday = datetime.fromisoformat(entry['start']).isoweekday()
                    value['preferences']['weekdays'] = [day for day in range(1, 8) if day != weekday]
                elif condition == 'work-window':
                    entry.update(start='2099-11-02T08:00:00+08:00', end='2099-11-02T09:45:00+08:00')
                elif condition == 'rest':
                    value['preferences'].update(restStart=9 * 60 + 30, restEnd=10 * 60)
                elif condition == 'deadline':
                    task['dueAt'] = '2099-11-02T10:00:00+08:00'
                elif condition == 'phase':
                    task['notBefore'] = '2099-11-02T09:30:00+08:00'
                elif condition == 'buffer':
                    value['entries'].append({**entry, 'id': 'busy', 'taskId': None,
                        'start': '2099-11-02T10:50:00+08:00', 'end': '2099-11-02T11:00:00+08:00'})
                elif condition == 'daily-budget':
                    value['preferences']['dailyBudget'] = 90
                elif condition == 'dependency':
                    task['dependencyIds'] = ['task-capacity-1']
                first.update(task=deepcopy(task), entry=deepcopy(entry))
                self.reject_both_transports(value)

    def test_unscheduled_tasks_still_require_valid_phase_and_dependency_graph(self):
        for condition in ('phase', 'missing-dependency', 'dependency-cycle'):
            with self.subTest(condition=condition):
                value = committed_workspace(self.saved)
                task = value['tasks'][-1]
                if condition == 'phase':
                    task['notBefore'] = task['dueAt']
                elif condition == 'missing-dependency':
                    task['dependencyIds'] = ['missing']
                else:
                    task['dependencyIds'] = [task['id']]
                value['drafts'][0]['items'][-1]['task'] = deepcopy(task)
                self.reject_both_transports(value)

    def test_openapi_documents_optional_capacity_confirmation_without_schema_upgrade(self):
        schema = self.client.get('/openapi.json').json()['components']['schemas']
        draft = schema['PlanDraft']
        for field in ('capacityLimited', 'capacityConfirmed'):
            self.assertEqual(draft['properties'][field]['type'], 'boolean')
            self.assertFalse(draft['properties'][field]['default'])
            self.assertNotIn(field, draft['required'])
        self.assertEqual(schema['Workspace']['properties']['schemaVersion']['maximum'], 2)


if __name__ == '__main__':
    unittest.main()
