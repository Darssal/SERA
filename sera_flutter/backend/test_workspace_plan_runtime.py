"""Durable legacy resumes and account-grounded one-call planning, offline."""
from copy import deepcopy
from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from fastapi.testclient import TestClient
from ai_service import AiServiceError, validate_goal_request
from app import create_app
from auth_store import AuthError
from long_term_planner import planning_context
from model_runtime import create_planner
from server import validate_workspace
from test_app import StubAi
from test_long_term_planner import GOAL, KEY, plan, envelope
from test_server import empty_workspace
from worker import process_job
from workflows import WorkflowStore


def workspace(budget=90, zone='Asia/Hong_Kong', weekdays=None):
    value = empty_workspace()
    value['preferences'].update(dailyBudget=budget, timeZone=zone,
                                weekdays=weekdays or [1, 2, 3, 4, 5])
    value['tasks'] = [{'id': 'private-task', 'title': 'PRIVATE_TASK_TITLE', 'notes': 'PRIVATE_TASK_NOTES'}]
    value['entries'] = [{'id': 'private-event', 'title': 'PRIVATE_EVENT_TITLE',
                         'start': '2026-11-02T14:00:00+08:00', 'end': '2026-11-02T15:00:00+08:00'}]
    validate_workspace(value)
    return value


def short_plan():
    value = plan(6)
    for task in value['tasks']:
        task['estimatedMinutes'] = 30
    return value


class WorkspacePlanContextTests(unittest.TestCase):
    @patch('ai_service.urlopen')
    def test_effective_budget_and_whitelisted_preferences_are_execution_only(self, http):
        body = {**GOAL, 'dailyBudget': 180, 'notes': '本次选择180分钟；保留原文，不可修改。'}
        saved = workspace()
        before_body, before_workspace = deepcopy(body), deepcopy(saved)
        http.return_value = envelope(short_plan())
        result = create_planner(KEY).generate_for_workspace(body, saved)
        payload = json.loads(http.call_args.args[0].data)
        context = json.loads(payload['messages'][1]['content'])
        self.assertEqual(context['dailyBudget'], 90)
        self.assertEqual(context['notes'], body['notes'])
        self.assertEqual(context['schedulingContext'], {
            'weekdays': [1, 2, 3, 4, 5], 'startMinute': 840, 'endMinute': 1020,
            'bufferMinutes': 15, 'restStart': 720, 'restEnd': 780})
        self.assertEqual(payload['response_format']['json_schema']['schema']['properties']['tasks']['items']
                         ['properties']['estimatedMinutes']['maximum'], 240)
        self.assertIn('逐阶段核算', payload['messages'][0]['content'])
        self.assertIn('已取本次目标选择与个人每日偏好的较小值', payload['messages'][0]['content'])
        self.assertNotIn('PRIVATE_', json.dumps(payload))
        self.assertEqual(body, before_body)
        self.assertEqual(saved, before_workspace)
        self.assertEqual(len(result['tasks']), 6)
        self.assertEqual(http.call_count, 1)

    @patch('ai_service.urlopen')
    def test_request_budget_below_preference_is_preserved(self, http):
        http.return_value = envelope(short_plan())
        create_planner(KEY).generate_for_workspace({**GOAL, 'dailyBudget': 40}, workspace())
        payload = json.loads(http.call_args.args[0].data)
        self.assertEqual(json.loads(payload['messages'][1]['content'])['dailyBudget'], 40)
        self.assertEqual(payload['response_format']['json_schema']['schema']['properties']['tasks']['items']
                         ['properties']['estimatedMinutes']['maximum'], 240)

    @patch('ai_service.urlopen')
    def test_production_factory_preserves_honest_estimates_and_requires_budget_approval(self, http):
        body = {**GOAL, 'dailyBudget': 15}
        saved = workspace(budget=180)
        original_body, original_workspace = deepcopy(body), deepcopy(saved)
        candidate = short_plan()
        candidate['tasks'][0]['estimatedMinutes'] = 60
        http.return_value = envelope(candidate)
        result = create_planner(KEY).generate_for_workspace(body, saved)
        self.assertEqual(http.call_count, 1)
        self.assertEqual(result['tasks'][0]['estimatedMinutes'], 60)
        self.assertEqual(saved, original_workspace)
        self.assertEqual(body, original_body)
        payload = json.loads(http.call_args.args[0].data)
        context = json.loads(payload['messages'][1]['content'])
        self.assertEqual(context['dailyBudget'], 15)
        duration = payload['response_format']['json_schema']['schema']['properties']['tasks']['items']['properties']['estimatedMinutes']
        self.assertEqual(duration, {'type': 'integer', 'minimum': 5, 'maximum': 240, 'multipleOf': 5})
        system = payload['messages'][0]['content']
        for requirement in ('每日投入目标', '必须由用户明确确认后才能执行',
                            '工作日、工作时窗、休息和缓冲是硬约束', '阶段截止', '不得越过目标截止',
                            '不要为迎合dailyBudget虚假缩短估时', '不能自行改变个人偏好'):
            self.assertIn(requirement, system)
        self.assertNotIn('不得越过目标截止、增加可用星期或放大预算', system)
        self.assertNotIn('各90分钟的阶段放入540分钟', system)

    @patch('ai_service.urlopen')
    def test_production_factory_still_rejects_invalid_duration_and_phase_windows_without_retry(self, http):
        candidates = []
        for invalid in (0, 245, 16):
            candidate = short_plan()
            candidate['tasks'][0]['estimatedMinutes'] = invalid
            candidates.append(candidate)
        candidate = short_plan()
        candidate['phases'][0]['end'] = '2027-05-01T00:00:00+08:00'
        candidates.append(candidate)
        for candidate in candidates:
            with self.subTest(candidate=candidate):
                http.reset_mock()
                http.return_value = envelope(candidate)
                with self.assertRaises(AiServiceError) as caught:
                    create_planner(KEY).generate_for_workspace({**GOAL, 'dailyBudget': 15}, workspace())
                self.assertEqual(caught.exception.code, 'invalid_ai_output')
                self.assertEqual(http.call_count, 1)

    @patch('ai_service.urlopen')
    def test_preference_zone_is_only_default_and_now_is_injected_only_during_execution(self, http):
        body = {k: v for k, v in GOAL.items() if k not in ('timeZone', 'referenceNow')}
        before = deepcopy(body)
        now = datetime(2026, 10, 31, 8, tzinfo=timezone.utc)
        for explicit, expected in ((None, 'America/New_York'), ('Asia/Hong_Kong', 'Asia/Hong_Kong')):
            with self.subTest(explicit=explicit):
                request = {**body, **({'timeZone': explicit} if explicit else {})}
                http.return_value = envelope(short_plan())
                with patch('model_runtime.planning_context', side_effect=lambda goal: planning_context(goal, now=now)):
                    create_planner(KEY).generate_for_workspace(request, workspace(zone='America/New_York'))
                context = json.loads(json.loads(http.call_args.args[0].data)['messages'][1]['content'])
                self.assertEqual(context['timeZone'], expected)
                self.assertEqual(context['referenceNow'], now.isoformat())
                self.assertNotIn('referenceNow', request)
        self.assertEqual(body, before)
        normalized = validate_goal_request(body)
        self.assertNotIn('referenceNow', normalized)
        self.assertNotIn('timeZone', normalized)

    @patch('ai_service.urlopen')
    def test_missing_workspace_or_preferences_preserves_existing_generate_behavior(self, http):
        for saved in (None, {}):
            with self.subTest(saved=saved):
                http.return_value = envelope(short_plan())
                create_planner(KEY).generate_for_workspace({**GOAL, 'dailyBudget': 180}, saved)
                context = json.loads(json.loads(http.call_args.args[0].data)['messages'][1]['content'])
                self.assertEqual(context['dailyBudget'], 180)
                self.assertNotIn('schedulingContext', context)

    @patch('ai_service.urlopen')
    def test_existing_invalid_preferences_fail_before_any_provider_request(self, http):
        for change in ({'dailyBudget': True}, {'dailyBudget': 0}, {'weekdays': [1, True]},
                       {'weekdays': [1, 1]}, {'timeZone': 'Unknown/Zone'}, {'endMinute': 10}):
            with self.subTest(change=change):
                saved = workspace()
                saved['preferences'].update(change)
                with self.assertRaises(AiServiceError) as caught:
                    create_planner(KEY).generate_for_workspace(GOAL, saved)
                self.assertEqual(caught.exception.code, 'invalid_ai_request')
        http.assert_not_called()


class DurableWorkspacePlanTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / 'jobs.sqlite3'
        self.store = WorkflowStore(self.path)
        self.identities = [self.store.accounts.register({'username': 'planner-' + suffix,
            'email': suffix + '@example.test', 'password': 'CorrectPassword123'}) for suffix in ('alpha', 'beta')]
        self.a, self.b = [identity['user']['id'] for identity in self.identities]

    def tearDown(self):
        self.temp.cleanup()

    def row(self, job_id):
        with self.store.accounts.connection() as db:
            return dict(db.execute('SELECT * FROM jobs WHERE id=?', (job_id,)).fetchone())

    def put_workspace(self, uid, value):
        validate_workspace(value)
        raw = json.dumps(value, ensure_ascii=False)
        with self.store.accounts.connection() as db:
            db.execute('INSERT INTO account_workspaces VALUES(?,?,?)', (uid, 0, raw))
        return raw

    def test_old_completed_job_resumes_with_explicit_hk_without_mutation_or_rerun(self):
        legacy = validate_goal_request({k: v for k, v in GOAL.items() if k not in ('timeZone', 'referenceNow')})
        job = self.store.enqueue(self.a, 'plan', legacy, 'old-plan')
        result = {'tasks': [{'title': 'saved-result'}]}
        with self.store.accounts.connection() as db:
            db.execute("UPDATE jobs SET status='succeeded',result=? WHERE id=?", (json.dumps(result), job['id']))
        before = self.row(job['id'])
        restarted = WorkflowStore(self.path)
        resumed = restarted.enqueue(self.a, 'plan', {**legacy, 'timeZone': 'Asia/Hong_Kong'}, 'old-plan')
        self.assertEqual(resumed['id'], job['id'])
        self.assertEqual(resumed['status'], 'succeeded')
        self.assertEqual(resumed['result'], result)
        self.assertEqual(self.row(job['id']), before)
        planner = Mock()
        self.assertFalse(process_job(restarted, planner))
        planner.generate.assert_not_called()
        planner.generate_for_workspace.assert_not_called()

    def test_only_plan_missing_hk_zone_is_equal_all_other_changes_still_conflict(self):
        legacy = validate_goal_request({k: v for k, v in GOAL.items() if k != 'timeZone'})
        job = self.store.enqueue(self.a, 'plan', legacy, 'same-key')
        for change in ({'timeZone': 'America/New_York'}, {'timeZone': 'UTC'}, {'title': 'changed'},
                       {'notes': 'changed'}, {'dailyBudget': 180}, {'referenceNow': '2026-10-31T17:00:00+08:00'}):
            with self.subTest(change=change), self.assertRaises(AuthError) as caught:
                self.store.enqueue(self.a, 'plan', {**legacy, **change}, 'same-key')
            self.assertEqual(caught.exception.status, 409)
        self.assertEqual(json.loads(self.row(job['id'])['payload']), legacy)
        # The comparison remains account-scoped and does not alias job kinds.
        other = self.store.enqueue(self.b, 'plan', {**legacy, 'timeZone': 'Asia/Hong_Kong'}, 'same-key')
        self.assertNotEqual(other['id'], job['id'])
        with self.assertRaises(AuthError):
            self.store.enqueue(self.a, 'understand', legacy, 'same-key')
        self.store.enqueue(self.a, 'understand', legacy, 'understand-key')
        with self.assertRaises(AuthError):
            self.store.enqueue(self.a, 'understand', {**legacy, 'timeZone': 'Asia/Hong_Kong'}, 'understand-key')

    def test_explicit_hk_can_resume_older_missing_form_without_rewriting_either_payload(self):
        payload = validate_goal_request(GOAL)
        job = self.store.enqueue(self.a, 'plan', payload, 'hk-first')
        before = self.row(job['id'])
        missing = {k: v for k, v in payload.items() if k != 'timeZone'}
        self.assertEqual(self.store.enqueue(self.a, 'plan', missing, 'hk-first')['id'], job['id'])
        self.assertEqual(self.row(job['id']), before)

    @patch('ai_service.urlopen')
    def test_worker_reads_only_job_owner_preferences_and_keeps_payload_and_workspaces_unchanged(self, http):
        stored = {self.a: self.put_workspace(self.a, workspace()),
                  self.b: self.put_workspace(self.b, workspace(35, 'America/New_York', [6, 7]))}
        payloads = [{**GOAL, 'title': title, 'dailyBudget': 180} for title in ('Account A goal', 'Account B goal')]
        for payload in payloads:
            payload.pop('timeZone')
        jobs = [self.store.enqueue(uid, 'plan', validate_goal_request(body), 'account-plan')
                for uid, body in zip((self.a, self.b), payloads)]
        before = [self.row(job['id'])['payload'] for job in jobs]
        http.side_effect = [envelope(short_plan()), envelope(short_plan())]
        planner = create_planner(KEY)
        self.assertTrue(process_job(self.store, planner))
        self.assertTrue(process_job(self.store, planner))
        self.assertFalse(process_job(self.store, planner))
        contexts = {c['title']: c for c in [json.loads(json.loads(call.args[0].data)['messages'][1]['content'])
                    for call in http.call_args_list]}
        self.assertEqual(contexts['Account A goal']['dailyBudget'], 90)
        self.assertEqual(contexts['Account A goal']['schedulingContext']['weekdays'], [1, 2, 3, 4, 5])
        self.assertEqual(contexts['Account B goal']['dailyBudget'], 35)
        self.assertEqual(contexts['Account B goal']['schedulingContext']['weekdays'], [6, 7])
        self.assertEqual(contexts['Account B goal']['timeZone'], 'America/New_York')
        self.assertNotIn('PRIVATE_', json.dumps(contexts))
        self.assertEqual([self.row(job['id'])['payload'] for job in jobs], before)
        self.assertTrue(all(self.row(job['id'])['status'] == 'succeeded' for job in jobs))
        with self.store.accounts.connection() as db:
            after = {r['user_id']: r['body'] for r in db.execute('SELECT user_id,body FROM account_workspaces')}
        self.assertEqual(after, stored)

    def test_worker_legacy_planner_still_receives_original_request_without_new_context(self):
        payload = validate_goal_request(GOAL)
        job = self.store.enqueue(self.a, 'plan', payload, 'legacy-class')
        planner = StubAi()
        self.assertTrue(process_job(self.store, planner))
        self.assertEqual(planner.calls, 1)
        self.assertEqual(json.loads(self.row(job['id'])['payload']), payload)
        self.assertEqual(self.row(job['id'])['status'], 'succeeded')

    @patch('ai_service.urlopen')
    def test_first_time_glm_worker_keeps_explicit_budget_and_runtime_defaults_without_mutating_job(self, http):
        body = {k: v for k, v in {**GOAL, 'dailyBudget': 180}.items() if k not in ('timeZone', 'referenceNow')}
        payload = validate_goal_request(body)
        job = self.store.enqueue(self.a, 'plan', payload, 'first-time')
        before = self.row(job['id'])['payload']
        http.return_value = envelope(short_plan())
        # This response fixture starts on Nov 1. Pin execution time while
        # still exercising the missing-referenceNow runtime default.
        with patch('experimental_plan_schema.planning_context', side_effect=lambda goal: planning_context(
                goal, now=datetime(2026, 10, 31, 8, tzinfo=timezone.utc))):
            self.assertTrue(process_job(self.store, create_planner(KEY)))
        self.assertEqual(self.row(job['id'])['status'], 'succeeded')
        context = json.loads(json.loads(http.call_args.args[0].data)['messages'][1]['content'])
        self.assertEqual(context['dailyBudget'], 180)
        self.assertEqual(context['timeZone'], 'Asia/Hong_Kong')
        self.assertIn('referenceNow', context)
        self.assertNotIn('schedulingContext', context)
        self.assertEqual(self.row(job['id'])['payload'], before)
        self.assertNotIn('referenceNow', json.loads(before))
        self.assertNotIn('timeZone', json.loads(before))
        resumed = self.store.enqueue(self.a, 'plan', {**payload, 'timeZone': 'Asia/Hong_Kong'}, 'first-time')
        self.assertEqual(resumed['id'], job['id'])
        self.assertEqual(resumed['status'], 'succeeded')
        self.assertFalse(process_job(self.store, create_planner(KEY)))
        self.assertEqual(http.call_count, 1)


class PlanResumeHttpTests(unittest.TestCase):
    def test_legacy_request_id_recovers_completed_result_via_real_routes(self):
        with tempfile.TemporaryDirectory() as temp:
            planner = StubAi()
            app = create_app(db_path=Path(temp) / 'app.db', ai_service=planner)
            with TestClient(app) as client:
                identity = client.post('/api/v1/auth/register', json={'username': 'resume-http',
                    'email': 'resume@example.test', 'password': 'CorrectPassword123'}).json()
                headers = {'Authorization': 'Bearer ' + identity['token']}
                body = {k: v for k, v in GOAL.items() if k not in ('timeZone', 'referenceNow')}
                first = client.post('/api/v1/jobs', headers=headers,
                    json={'kind': 'plan', 'input': body, 'requestId': 'resume-old'})
                self.assertEqual(first.status_code, 202)
                job_id = first.json()['job']['id']
                self.assertTrue(process_job(app.state.workflows, planner))
                resumed = client.post('/api/v1/jobs', headers=headers,
                    json={'kind': 'plan', 'input': {**body, 'timeZone': 'Asia/Hong_Kong'}, 'requestId': 'resume-old'})
                self.assertEqual(resumed.status_code, 202, resumed.text)
                self.assertEqual(resumed.json()['job']['id'], job_id)
                self.assertEqual(resumed.json()['job']['status'], 'succeeded')
                changed = client.post('/api/v1/jobs', headers=headers,
                    json={'kind': 'plan', 'input': {**body, 'timeZone': 'UTC'}, 'requestId': 'resume-old'})
                self.assertEqual(changed.status_code, 409)
                self.assertFalse(process_job(app.state.workflows, planner))
                self.assertEqual(planner.calls, 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
