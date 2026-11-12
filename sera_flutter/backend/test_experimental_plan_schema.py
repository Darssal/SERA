"""Offline checks for the strict phased-plan schema used by the GLM runtime."""
from copy import deepcopy
import json
import unittest
from unittest.mock import patch

from ai_service import AiServiceError, MODEL_REQUEST_PROFILES, GLM_FLASH_MODEL
from experimental_plan_schema import StrictLongTermPlanner, STRICT_PLAN_SCHEMA, plan_schema
from test_long_term_planner import KEY, GOAL, plan, envelope


class StrictPlanExperimentTests(unittest.TestCase):
    @patch('ai_service.urlopen')
    def test_only_format_changes_from_actual_long_plan_profile(self, http):
        before = deepcopy(MODEL_REQUEST_PROFILES)
        http.return_value = envelope(plan())
        result = StrictLongTermPlanner(KEY).generate(GOAL)
        self.assertEqual(http.call_count, 1)
        self.assertEqual(http.call_args.kwargs['timeout'], 75)
        payload = json.loads(http.call_args.args[0].data)
        self.assertEqual(payload['reasoning_effort'], 'low')
        self.assertEqual((payload['temperature'], payload['max_tokens']), (.2, 6000))
        self.assertEqual(payload['response_format']['type'], 'json_schema')
        self.assertTrue(payload['response_format']['json_schema']['strict'])
        self.assertEqual(payload['response_format']['json_schema']['name'], 'sera_phased_plan')
        schema = payload['response_format']['json_schema']['schema']
        self.assertEqual(schema, plan_schema(90))
        self.assertEqual(schema['properties']['tasks']['items']['properties']['estimatedMinutes']['maximum'], 240)
        self.assertEqual(MODEL_REQUEST_PROFILES, before)
        self.assertEqual(MODEL_REQUEST_PROFILES[GLM_FLASH_MODEL]['plan']['response_format'], {'type': 'json_object'})
        self.assertEqual(len(result['tasks']), 48)
        self.assertNotIn('tools', payload)

    @patch('ai_service.urlopen')
    def test_extra_empty_phase_key_is_rejected_not_silently_removed_or_retried(self, http):
        candidate = {**plan(), 'phase_1': ''}
        http.return_value = envelope(candidate)
        with self.assertRaises(AiServiceError) as caught:
            StrictLongTermPlanner(KEY).generate(GOAL)
        self.assertEqual(caught.exception.code, 'invalid_ai_output')
        self.assertEqual(http.call_count, 1)

    @patch('ai_service.urlopen')
    def test_strict_experiment_requires_phases_and_preserves_window_validation(self, http):
        candidates = [{'tasks': []}, plan()]
        candidates[1]['phases'][1]['start'] = candidates[1]['phases'][0]['start']
        for candidate in candidates:
            with self.subTest(candidate=candidate):
                http.return_value = envelope(candidate)
                with self.assertRaises(AiServiceError):
                    StrictLongTermPlanner(KEY).generate(GOAL)

    def test_schema_exact_keys_counts_and_server_metadata_are_separate(self):
        self.assertFalse(STRICT_PLAN_SCHEMA['additionalProperties'])
        self.assertEqual(set(STRICT_PLAN_SCHEMA['required']), {'tasks', 'phases'})
        for name in ('phases', 'tasks'):
            item = STRICT_PLAN_SCHEMA['properties'][name]['items']
            self.assertFalse(item['additionalProperties'])
            self.assertEqual(set(item['required']), set(item['properties']))
        self.assertEqual(STRICT_PLAN_SCHEMA['properties']['tasks']['maxItems'], 96)
        self.assertEqual(STRICT_PLAN_SCHEMA['properties']['phases']['maxItems'], 12)
        self.assertNotIn('source', STRICT_PLAN_SCHEMA['properties'])
        self.assertEqual(STRICT_PLAN_SCHEMA['properties']['phases']['items']['properties']['title']['maxLength'], 100)

    def test_daily_target_does_not_reduce_hard_duration_bounds_or_mutate_global(self):
        first, second = plan_schema(15), plan_schema(300)
        for schema in (first, second):
            self.assertEqual(schema['properties']['tasks']['items']['properties']['estimatedMinutes'],
                             {'type': 'integer', 'minimum': 5, 'maximum': 240, 'multipleOf': 5})
        first['properties']['phases']['maxItems'] = 1
        self.assertEqual(second['properties']['tasks']['items']['properties']['estimatedMinutes']['maximum'], 240)
        self.assertEqual(STRICT_PLAN_SCHEMA['properties']['phases']['maxItems'], 12)


if __name__ == '__main__':
    unittest.main(verbosity=2)
