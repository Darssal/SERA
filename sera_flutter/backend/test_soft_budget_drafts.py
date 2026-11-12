"""Budget approval belongs to a recoverable draft, never global preferences."""
import copy
from pathlib import Path
import tempfile
import unittest

from server import ValidationError, WorkspaceStore, validate_workspace
from sync_store import migrate_workspace
from test_server import empty_workspace


def workspace():
    value = migrate_workspace(empty_workspace())
    value['drafts'] = [{'id': 'draft-budget', 'goal': {'id': 'goal-budget',
        'title': '复习目标', 'deadline': '2026-11-02T12:00:00+08:00', 'taskIds': []},
        'items': [], 'status': 'draft', 'originalDailyBudget': 15,
        'suggestedDailyBudget': 60, 'budgetOverrideConfirmed': False}]
    return value


class SoftBudgetDraftTests(unittest.TestCase):
    def test_pending_and_approved_draft_survive_storage_without_preference_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            store = WorkspaceStore(Path(directory) / 'budget.db')
            value = workspace()
            saved = store.save(value, 0)
            self.assertEqual(store.load()['drafts'], value['drafts'])
            saved['drafts'][0]['budgetOverrideConfirmed'] = True
            approved = store.save(saved, saved['revision'])
            self.assertTrue(approved['drafts'][0]['budgetOverrideConfirmed'])
            self.assertEqual(approved['preferences']['dailyBudget'], 90)
            self.assertEqual(approved['tasks'], [])
            self.assertEqual(approved['entries'], [])

    def test_legacy_missing_or_null_budget_fields_remain_valid(self):
        value = workspace()
        draft = value['drafts'][0]
        for key in ('originalDailyBudget', 'suggestedDailyBudget', 'budgetOverrideConfirmed'):
            draft.pop(key)
        validate_workspace(value)
        draft.update(originalDailyBudget=None, suggestedDailyBudget=None, budgetOverrideConfirmed=False)
        validate_workspace(value)

    def test_invalid_and_unapproved_committed_overrides_are_rejected(self):
        for change in ({'originalDailyBudget': 0}, {'originalDailyBudget': True},
                       {'suggestedDailyBudget': 15}, {'suggestedDailyBudget': 1441},
                       {'suggestedDailyBudget': None}, {'budgetOverrideConfirmed': 1},
                       {'status': 'committed'},
                       {'originalDailyBudget': None, 'suggestedDailyBudget': None,
                        'budgetOverrideConfirmed': True}):
            with self.subTest(change=change):
                value = copy.deepcopy(workspace())
                value['drafts'][0].update(change)
                with self.assertRaises(ValidationError):
                    validate_workspace(value)


if __name__ == '__main__':
    unittest.main()
