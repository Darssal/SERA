"""Real authenticated PUT/sync placement with a nonempty confirmed budget plan."""
from copy import deepcopy
from datetime import datetime
from pathlib import Path
import tempfile
import unittest

from fastapi.testclient import TestClient

from ai_service import SiliconFlowPlanner
from app import create_app
from sync_store import migrate_workspace
from test_server import empty_workspace


def pending_workspace():
    value = migrate_workspace(empty_workspace())
    value['preferences'].update(dailyBudget=15, startMinute=9 * 60,
        endMinute=17 * 60, weekdays=[1, 2, 3, 4, 5, 6, 7], bufferMinutes=15,
        restStart=12 * 60, restEnd=13 * 60)
    task = {'id': 'task-budget', 'goalId': 'goal-budget', 'title': '复习清单',
        'estimatedMinutes': 60, 'dueAt': '2099-11-02T17:00:00+08:00'}
    entry = {'id': 'entry-budget', 'taskId': task['id'], 'title': task['title'],
        'start': '2099-11-02T14:00:00+08:00', 'end': '2099-11-02T15:00:00+08:00'}
    goal = {'id': 'goal-budget', 'title': '复习目标',
        'deadline': '2099-11-02T17:00:00+08:00', 'taskIds': [task['id']]}
    value['drafts'] = [{'id': 'draft-budget', 'goal': goal, 'status': 'draft',
        'items': [{'task': task, 'entry': entry}], 'originalDailyBudget': 15,
        'suggestedDailyBudget': 60, 'budgetOverrideConfirmed': False}]
    return value


def committed_workspace(previous, *, confirmed=True):
    value = deepcopy(previous)
    draft = value['drafts'][0]
    draft.update(status='committed', budgetOverrideConfirmed=confirmed)
    value['goals'] = [deepcopy(draft['goal'])]
    value['tasks'] = [deepcopy(draft['items'][0]['task'])]
    value['entries'] = [deepcopy(draft['items'][0]['entry'])]
    return value


def operations(previous, candidate):
    batch = [{'id': f'commit-{kind}-{item["id"]}',
        'entityType': kind, 'entityId': item['id'], 'action': 'upsert',
        'expectedVersion': previous['entityVersions'].get(f'{kind}/{item["id"]}', 0),
        'value': item} for kind in ('goals', 'tasks', 'entries', 'drafts')
        for item in candidate[kind]]
    if candidate['preferences'] != previous['preferences']:
        batch.append({'id': 'commit-preferences', 'entityType': 'preferences',
            'entityId': 'singleton', 'action': 'upsert',
            'expectedVersion': previous['entityVersions'].get('preferences/singleton', 0),
            'value': candidate['preferences']})
    return {'operations': batch}


class SoftBudgetPlacementTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.app = create_app(db_path=Path(self.temp.name) / 'budget-placement.db',
            ai_service=SiliconFlowPlanner(), transcriber=object())
        identity = self.app.state.accounts.register({'username': 'budget-placement',
            'email': 'budget@example.test', 'password': 'CorrectPassword123'})
        self.uid = identity['user']['id']
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

    def assert_saved_unchanged(self):
        response = self.client.get('/api/v1/workspace')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()['workspace'], self.saved)
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM sync_operations').fetchone()[0], 0)

    def reject_both_transports(self, value):
        response = self.client.put('/api/v1/workspace', json={
            'workspace': value, 'expectedRevision': self.saved['revision']})
        self.assertEqual(response.status_code, 400, response.text)
        self.assert_saved_unchanged()
        response = self.client.post('/api/v1/sync/operations', json=operations(self.saved, value))
        self.assertEqual(response.status_code, 400, response.text)
        self.assert_saved_unchanged()

    def test_put_confirmed_60_minute_plan_saves_under_15_minute_preference(self):
        approved = deepcopy(self.saved)
        approved['drafts'][0]['budgetOverrideConfirmed'] = True
        self.saved = self.put(approved)
        self.assertEqual(self.saved['tasks'], [])
        result = self.put(committed_workspace(self.saved))
        self.assertEqual(len(result['tasks']), 1)
        self.assertEqual(len(result['entries']), 1)
        self.assertEqual(result['preferences']['dailyBudget'], 15)
        self.assertEqual(result['drafts'][0]['suggestedDailyBudget'], 60)
        self.assertTrue(result['drafts'][0]['budgetOverrideConfirmed'])

    def test_sync_confirmed_60_minute_plan_is_atomic_and_replay_does_not_duplicate(self):
        batch = operations(self.saved, committed_workspace(self.saved))
        first = self.client.post('/api/v1/sync/operations', json=batch)
        self.assertEqual(first.status_code, 200, first.text)
        result = first.json()['workspace']
        self.assertEqual(len(result['tasks']), 1)
        self.assertEqual(len(result['entries']), 1)
        self.assertEqual(result['preferences']['dailyBudget'], 15)
        replay = self.client.post('/api/v1/sync/operations', json=batch)
        self.assertEqual(replay.status_code, 200, replay.text)
        self.assertEqual(replay.json()['workspace'], result)
        self.assertEqual(len(replay.json()['replayed']), 4)

    def test_old_committed_snapshot_remains_editable_and_new_goal_edit_inherits_approval(self):
        self.saved = self.put(committed_workspace(self.saved))
        renamed = deepcopy(self.saved)
        renamed['tasks'][0]['title'] = '用户后来修改的任务名'
        renamed['entries'][0]['title'] = '用户后来修改的任务名'
        renamed['entries'][0].update(start='2099-11-02T15:00:00+08:00',
            end='2099-11-02T16:00:00+08:00')
        self.saved = self.put(renamed)
        self.assertEqual(self.saved['drafts'][0]['items'][0]['entry']['start'],
            '2099-11-02T14:00:00+08:00')
        edit = deepcopy(self.saved['drafts'][0])
        edit.update(id='edit-goal-draft', targetGoalId='goal-budget', status='draft')
        edit['items'][0].update(task=deepcopy(self.saved['tasks'][0]),
            entry=deepcopy(self.saved['entries'][0]))
        pending = deepcopy(self.saved)
        pending['drafts'].append(edit)
        self.saved = self.put(pending)
        committed = deepcopy(self.saved)
        committed['drafts'][-1]['status'] = 'committed'
        result = self.put(committed)
        self.assertEqual(len(result['tasks']), 1)
        self.assertEqual(result['drafts'][-1]['suggestedDailyBudget'], 60)
        self.assertEqual(result['preferences']['dailyBudget'], 15)

    def test_unconfirmed_and_finite_cap_overflow_both_roll_back(self):
        self.reject_both_transports(committed_workspace(self.saved, confirmed=False))
        value = committed_workspace(self.saved)
        value['entries'][0]['end'] = '2099-11-02T15:05:00+08:00'
        value['tasks'][0]['estimatedMinutes'] = 65
        value['drafts'][0]['items'][0].update(task=deepcopy(value['tasks'][0]),
            entry=deepcopy(value['entries'][0]))
        self.reject_both_transports(value)

    def test_approved_budget_does_not_allow_overlap_availability_rest_or_deadlines(self):
        for condition in ('overlap', 'workday', 'work-window', 'rest', 'deadline', 'plan-deadline', 'phase', 'buffer'):
            with self.subTest(condition=condition):
                value = committed_workspace(self.saved)
                entry, task = value['entries'][0], value['tasks'][0]
                if condition == 'overlap':
                    value['entries'].append({**entry, 'id': 'busy', 'taskId': None})
                elif condition == 'workday':
                    day = datetime.fromisoformat(entry['start']).isoweekday()
                    value['preferences']['weekdays'] = [number for number in range(1, 8) if number != day]
                elif condition == 'work-window':
                    entry.update(start='2099-11-02T08:00:00+08:00', end='2099-11-02T09:00:00+08:00')
                elif condition == 'rest':
                    entry.update(start='2099-11-02T12:00:00+08:00', end='2099-11-02T13:00:00+08:00')
                elif condition == 'deadline':
                    task['dueAt'] = '2099-11-02T14:30:00+08:00'
                elif condition == 'plan-deadline':
                    value['drafts'][0]['goal']['deadline'] = '2099-11-02T14:30:00+08:00'
                    value['goals'][0]['deadline'] = '2099-11-02T14:30:00+08:00'
                elif condition == 'phase':
                    task['notBefore'] = '2099-11-02T14:30:00+08:00'
                elif condition == 'buffer':
                    value['entries'].append({**entry, 'id': 'busy', 'taskId': None,
                        'start': '2099-11-02T15:05:00+08:00', 'end': '2099-11-02T15:30:00+08:00'})
                value['drafts'][0]['items'][0].update(task=deepcopy(task), entry=deepcopy(entry))
                self.reject_both_transports(value)

    def test_confirmation_cannot_be_reused_for_unrelated_blocks_or_changed_snapshot(self):
        for condition in ('unrelated-task', 'changed-time', 'different-goal', 'other-plan'):
            with self.subTest(condition=condition):
                value = committed_workspace(self.saved)
                draft = value['drafts'][0]
                if condition == 'unrelated-task':
                    value['tasks'].append({**value['tasks'][0], 'id': 'other-task'})
                    value['goals'][0]['taskIds'].append('other-task')
                    value['entries'][0]['taskId'] = 'other-task'
                elif condition == 'changed-time':
                    value['entries'][0].update(start='2099-11-02T15:00:00+08:00', end='2099-11-02T16:00:00+08:00')
                elif condition == 'different-goal':
                    value['goals'].append({**value['goals'][0], 'id': 'other-goal', 'taskIds': ['task-budget']})
                    value['goals'][0]['taskIds'] = []
                    value['tasks'][0]['goalId'] = 'other-goal'
                elif condition == 'other-plan':
                    # This approved plan cannot lend its cap to another newly
                    # committed automatic plan on a different calendar day.
                    other = deepcopy(draft)
                    other.update(id='other-draft', originalDailyBudget=None,
                        suggestedDailyBudget=None, budgetOverrideConfirmed=False)
                    other['goal'].update(id='other-goal', taskIds=['other-task'])
                    other['items'][0]['task'].update(id='other-task', goalId='other-goal')
                    other['items'][0]['entry'].update(id='other-entry', taskId='other-task',
                        start='2099-11-01T14:00:00+08:00', end='2099-11-01T15:00:00+08:00')
                    value['drafts'].append(other)
                    value['goals'].append(deepcopy(other['goal']))
                    value['tasks'].append(deepcopy(other['items'][0]['task']))
                    value['entries'].append(deepcopy(other['items'][0]['entry']))
                self.reject_both_transports(value)


if __name__ == '__main__':
    unittest.main()
