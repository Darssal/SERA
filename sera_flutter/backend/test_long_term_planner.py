"""Offline phased-plan validation and real provider request wiring."""
from copy import deepcopy
from datetime import datetime, timezone
import io
import json
import unittest
from unittest.mock import patch

from ai_service import AiServiceError, GLM_FLASH_MODEL, SiliconFlowPlanner, validate_ai_tasks, validate_goal_request
from long_term_planner import build_payload, normalize_plan, planning_context

KEY = 'sk-long-plan-offline-not-a-real-key'
GOAL = {'title': '完成多月项目', 'prompt': '逐步完成需求、实施、验证与交付', 'notes': '需要可核对成果',
        'deadline': '2027-04-30T23:59:00+08:00', 'dailyBudget': 90,
        'referenceNow': '2026-10-31T16:00:00+08:00', 'timeZone': 'Asia/Hong_Kong'}


def plan(count=48):
    phases = [
        {'id': 'p1', 'title': '需求与方案', 'start': '2026-11-01T09:00:00+08:00', 'end': '2026-12-31T18:00:00+08:00', 'outcome': '形成可核对方案'},
        {'id': 'p2', 'title': '分批实施', 'start': '2027-01-01T09:00:00+08:00', 'end': '2027-02-28T18:00:00+08:00', 'outcome': '各批次可验收'},
        {'id': 'p3', 'title': '验证与交付', 'start': '2027-03-01T09:00:00+08:00', 'end': '2027-04-30T18:00:00+08:00', 'outcome': '完成验证和交付材料'},
    ]
    tasks = [{'title': f'执行与核对第{i + 1}项产出', 'notes': f'产出{i + 1}通过明确检查',
              'estimatedMinutes': 45, 'checklist': ['核对该项具体产出'],
              'phaseId': phases[min(2, i * 3 // count)]['id']} for i in range(count)]
    return {'phases': phases, 'tasks': tasks}


def envelope(value, finish='stop'):
    return io.BytesIO(json.dumps({'model': GLM_FLASH_MODEL, 'choices': [{'finish_reason': finish,
        'message': {'content': json.dumps(value, ensure_ascii=False)}}]}, ensure_ascii=False).encode('utf-8'))


class LongTermPlanTests(unittest.TestCase):
    def setUp(self):
        self.context = planning_context(GOAL)

    @patch('ai_service.urlopen')
    def test_default_glm_generates_48_phased_tasks_in_one_75_second_request(self, http):
        value = plan()
        http.return_value = envelope(value)
        result = SiliconFlowPlanner(KEY).generate(GOAL)
        self.assertEqual(http.call_count, 1)
        self.assertEqual(http.call_args.kwargs['timeout'], 75)
        payload = json.loads(http.call_args.args[0].data)
        self.assertEqual(payload['max_tokens'], 6000)
        self.assertEqual(payload['temperature'], .2)
        self.assertEqual(payload['reasoning_effort'], 'low')
        self.assertEqual(payload['response_format'], {'type': 'json_object'})
        self.assertNotIn('tools', payload)
        self.assertNotIn('request_timeout', payload)
        self.assertEqual(len(result['tasks']), 48)
        self.assertGreater(sum(task['estimatedMinutes'] for task in result['tasks']), 1440)
        self.assertEqual(result['tasks'][0]['notBefore'], value['phases'][0]['start'])
        self.assertEqual(result['tasks'][-1]['notBefore'], value['phases'][-1]['start'])
        self.assertEqual(result['tasks'][-1]['deadline'], value['phases'][-1]['end'])
        self.assertEqual(result['tasks'][-1]['phase'], value['phases'][-1]['title'])
        self.assertEqual(result['tasks'][17]['title'], value['tasks'][17]['title'])
        self.assertEqual(result['phases'], value['phases'])
        self.assertNotIn(KEY, json.dumps(result))

    def test_96_tasks_are_valid_and_97_are_rejected_without_truncation(self):
        self.assertEqual(len(normalize_plan(plan(96), self.context, validate_ai_tasks)['tasks']), 96)
        with self.assertRaises(ValueError):
            normalize_plan(plan(97), self.context, validate_ai_tasks)

    def test_phases_cannot_overlap_reorder_escape_goal_or_use_invalid_calendar_values(self):
        changes = [('start', '2026-10-30T09:00:00+08:00'), ('end', '2027-05-01T00:00:00+08:00'),
                   ('start', '2026-11-01T09:00:00'), ('start', '2026-11-31T09:00:00+08:00'),
                   ('end', '2026-11-01T09:00:00+08:00')]
        for field, value in changes:
            with self.subTest(field=field, value=value):
                candidate = plan()
                candidate['phases'][0][field] = value
                with self.assertRaises(ValueError):
                    normalize_plan(candidate, self.context, validate_ai_tasks)
        candidate = plan()
        candidate['phases'][1]['start'] = '2026-12-01T09:00:00+08:00'
        with self.assertRaises(ValueError):
            normalize_plan(candidate, self.context, validate_ai_tasks)
        candidate = plan()
        candidate['phases'].reverse()
        with self.assertRaises(ValueError):
            normalize_plan(candidate, self.context, validate_ai_tasks)

    def test_phase_ids_references_shape_and_empty_stages_are_rejected(self):
        candidates = []
        value = plan(); value['phases'][1]['id'] = 'p1'; candidates.append(value)
        value = plan(); value['tasks'][0]['phaseId'] = 'missing'; candidates.append(value)
        value = plan(); value['phases'][0]['outcome'] = ''; candidates.append(value)
        value = plan(); value['phases'][0]['startAfter'] = value['phases'][0]['start']; candidates.append(value)
        value = plan(); value['tasks'][0].pop('phaseId'); candidates.append(value)
        value = plan(); value['tasks'] = value['tasks'][:3]; candidates.append(value)
        for candidate in candidates:
            with self.subTest(candidate=candidate):
                with self.assertRaises(ValueError):
                    normalize_plan(candidate, self.context, validate_ai_tasks)

    def test_task_duration_structure_limits_remain(self):
        for duration in (True, 47, 245):
            candidate = plan()
            candidate['tasks'][0]['estimatedMinutes'] = duration
            with self.subTest(duration=duration):
                with self.assertRaises((ValueError, AiServiceError)):
                    normalize_plan(candidate, self.context, validate_ai_tasks)

    def test_daily_budget_is_a_target_and_valid_excess_reaches_client_confirmation(self):
        candidate = plan()
        candidate['tasks'][0]['estimatedMinutes'] = 95
        result = normalize_plan(candidate, self.context, validate_ai_tasks)
        self.assertEqual(result['tasks'][0]['estimatedMinutes'], 95)
        self.assertEqual(result['tasks'][0]['notBefore'], candidate['phases'][0]['start'])
        self.assertEqual(result['tasks'][0]['deadline'], candidate['phases'][0]['end'])
        legacy = {'tasks': [{key: candidate['tasks'][0][key] for key in
                            ('title', 'notes', 'estimatedMinutes', 'checklist')}]}
        self.assertEqual(normalize_plan(legacy, self.context, validate_ai_tasks), legacy)

    def test_phase_title_matches_100_character_api_and_client_limit(self):
        candidate = plan()
        candidate['phases'][0]['title'] = '阶' * 100
        result = normalize_plan(candidate, self.context, validate_ai_tasks)
        self.assertEqual(result['tasks'][0]['phase'], '阶' * 100)
        candidate['phases'][0]['title'] += '段'
        with self.assertRaises(ValueError):
            normalize_plan(candidate, self.context, validate_ai_tasks)

    def test_interleaved_tasks_are_stably_grouped_by_validated_phase_order(self):
        candidate = plan(6)
        candidate['tasks'] = [candidate['tasks'][0], candidate['tasks'][2],
                              candidate['tasks'][1], candidate['tasks'][4],
                              candidate['tasks'][3], candidate['tasks'][5]]
        result = normalize_plan(candidate, self.context, validate_ai_tasks)
        self.assertEqual([task['title'] for task in result['tasks']],
                         [task['title'] for task in plan(6)['tasks']])
        self.assertEqual(result['phases'], candidate['phases'])
        for task in result['tasks']:
            phase = next(p for p in candidate['phases'] if p['title'] == task['phase'])
            self.assertEqual((task['notBefore'], task['deadline']), (phase['start'], phase['end']))

    def test_old_four_field_outline_is_preserved_without_fake_phase_dates(self):
        tasks = [{key: task[key] for key in ('title', 'notes', 'estimatedMinutes', 'checklist')} for task in plan()['tasks']]
        result = normalize_plan({'tasks': tasks}, self.context, validate_ai_tasks)
        self.assertEqual(result, {'tasks': tasks})
        self.assertNotIn('phases', result)
        self.assertNotIn('notBefore', result['tasks'][0])

    def test_enqueue_normalization_is_stable_and_never_injects_current_time(self):
        old = {key: value for key, value in GOAL.items() if key not in ('referenceNow', 'timeZone')}
        first, second = validate_goal_request(old), validate_goal_request(old)
        self.assertEqual(first, second)
        self.assertNotIn('referenceNow', first)
        self.assertNotIn('timeZone', first)
        self.assertEqual(validate_goal_request(GOAL)['referenceNow'], GOAL['referenceNow'])

    def test_runtime_default_now_and_zone_are_explicit_and_legacy_naive_deadline_uses_zone(self):
        goal = {key: value for key, value in GOAL.items() if key not in ('referenceNow', 'timeZone')}
        goal['deadline'] = '2027-04-30T23:59:00'
        context = planning_context(goal, now=datetime(2026, 10, 31, 8, 0, tzinfo=timezone.utc))
        self.assertEqual(context['timeZone'], 'Asia/Hong_Kong')
        self.assertEqual(context['referenceLocalNow'], '2026-10-31T16:00:00+08:00')
        self.assertEqual(context['deadline'], '2027-04-30T23:59:00+08:00')
        self.assertNotIn('referenceNow', goal)

    @patch('ai_service.urlopen')
    def test_invalid_optional_context_or_past_deadline_fails_before_paid_request(self, http):
        for changed in ({'timeZone': 'Unknown/Zone'}, {'referenceNow': '2026-10-31T16:00:00'},
                        {'deadline': '2026-10-30T12:00:00+08:00'}):
            with self.subTest(changed=changed):
                with self.assertRaises(AiServiceError) as caught:
                    SiliconFlowPlanner(KEY).generate({**GOAL, **changed})
                self.assertEqual(caught.exception.code, 'invalid_ai_request')
        http.assert_not_called()

    def test_time_zone_and_dst_use_instants_without_rewriting_model_phase_dates(self):
        context = planning_context({**GOAL, 'referenceNow': '2026-10-31T16:00:00Z',
            'timeZone': 'America/New_York', 'deadline': '2026-11-02T12:00:00-05:00'})
        self.assertEqual(context['referenceLocalNow'], '2026-10-31T12:00:00-04:00')
        value = {'phases': [{'id': 'p', 'title': '跨夏令时阶段', 'start': '2026-10-31T12:00:00-04:00',
                            'end': '2026-11-02T12:00:00-05:00', 'outcome': '完成阶段产出'}],
                 'tasks': [{**plan(1)['tasks'][0], 'phaseId': 'p'}]}
        result = normalize_plan(value, context, validate_ai_tasks)
        self.assertEqual(result['tasks'][0]['notBefore'], value['phases'][0]['start'])
        self.assertEqual(result['tasks'][0]['deadline'], value['phases'][0]['end'])

    @patch('ai_service.urlopen')
    def test_truncated_large_plan_is_not_a_partial_success_or_automatic_retry(self, http):
        http.return_value = envelope(plan(), finish='length')
        with self.assertRaises(AiServiceError) as caught:
            SiliconFlowPlanner(KEY).generate(GOAL)
        self.assertEqual(caught.exception.code, 'invalid_ai_output')
        self.assertEqual(http.call_count, 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
