"""Factory boundaries and actual operation payloads, with offline transport."""
from copy import deepcopy
import json
import unittest
from unittest.mock import Mock, patch

from ai_service import AiServiceError, DEFAULT_MODEL, GLM_FLASH_MODEL, SiliconFlowPlanner
from experimental_action_protocol import JsonActionUnderstandingPlanner
from experimental_plan_schema import StrictLongTermPlanner
from model_runtime import GlmRuntimePlanner, create_planner
from test_experimental_action_protocol import action
from test_long_term_planner import GOAL, plan, envelope
from test_understanding_tools import INPUT, VALID, KEY, response


class ModelRuntimeFactoryTests(unittest.TestCase):
    def test_exact_adopted_model_selects_both_operations(self):
        for planner in (create_planner(KEY), create_planner(KEY, GLM_FLASH_MODEL)):
            self.assertIsInstance(planner, GlmRuntimePlanner)
            self.assertEqual(planner.model, DEFAULT_MODEL)
            self.assertTrue(planner.configured)
            self.assertIs(planner.understand.__func__, JsonActionUnderstandingPlanner.understand)
            self.assertIs(planner.generate.__func__, StrictLongTermPlanner.generate)

    def test_other_explicit_models_retain_the_base_class(self):
        for model in ('explicit/model', 'Qwen/Qwen3-8B', 'zai-org/GLM-5.3-Flash-extra'):
            planner = create_planner(KEY, model)
            self.assertIs(type(planner), SiliconFlowPlanner)
            self.assertEqual(planner.model, model)
        self.assertIsNot(SiliconFlowPlanner.understand, JsonActionUnderstandingPlanner.understand)
        self.assertIsNot(SiliconFlowPlanner.generate, StrictLongTermPlanner.generate)

    @patch('ai_service.urlopen')
    def test_construction_is_lazy_and_missing_key_never_reaches_http(self, http):
        factory = Mock(side_effect=AssertionError('construction must not make web session'))
        planner = create_planner(public_web_factory=factory)
        self.assertFalse(planner.configured)
        http.assert_not_called()
        factory.assert_not_called()
        with self.assertRaises(AiServiceError) as caught:
            planner.understand(INPUT)
        self.assertEqual(caught.exception.code, 'ai_not_configured')
        http.assert_not_called()
        factory.assert_not_called()

    @patch('ai_service.urlopen')
    def test_factory_preserves_timeout_and_public_web_dependency(self, http):
        factory = Mock(side_effect=AssertionError('ordinary finish must not use web'))
        planner = create_planner(KEY, timeout=12, public_web_factory=factory)
        self.assertIs(planner._public_web_factory, factory)
        http.return_value = response(action())
        planner.understand(INPUT)
        self.assertEqual(http.call_args.kwargs['timeout'], 12)
        self.assertEqual(planner.timeout, 12)
        factory.assert_not_called()

    @patch('ai_service.urlopen')
    def test_one_runtime_keeps_action_and_plan_schemas_separate_without_extra_calls(self, http):
        ordinary = {**deepcopy(VALID), 'intent': 'event', 'title': '课程',
                    'start': '2026-11-01T15:00:00+08:00', 'end': None, 'questions': []}
        http.side_effect = [response(action(result=ordinary)), envelope(plan()), response(action(result=ordinary))]
        planner = create_planner(KEY)
        first = planner.understand(INPUT)
        generated = planner.generate(GOAL)
        last = planner.understand(INPUT)
        self.assertEqual(http.call_count, 3)
        requests = [json.loads(call.args[0].data) for call in http.call_args_list]
        self.assertNotIn('response_format', requests[0])
        self.assertEqual(requests[1]['response_format']['json_schema']['name'], 'sera_phased_plan')
        self.assertNotIn('response_format', requests[2])
        self.assertEqual([p['max_tokens'] for p in requests], [1800, 6000, 1800])
        self.assertEqual([call.kwargs['timeout'] for call in http.call_args_list], [45, 75, 45])
        self.assertTrue(all('tools' not in p for p in requests))
        self.assertEqual(first, last)
        self.assertEqual(first['start'], ordinary['start'])
        self.assertIsNone(first['end'])
        self.assertEqual(first['questions'], [])
        self.assertEqual(len(generated['tasks']), 48)

    @patch('ai_service.urlopen')
    def test_prompt_clarifies_partial_times_and_source_identity_without_changing_output(self, http):
        http.return_value = response(action())
        create_planner(KEY).understand(INPUT)
        system = json.loads(http.call_args.args[0].data)['messages'][0]['content']
        self.assertIn('不能复制已知端点填另一端', system)
        self.assertIn('不为填齐字段机械追问', system)
        self.assertIn('发文机构原文或官方高校转发', system)
        self.assertIn('不能把它们称为官方来源', system)


if __name__ == '__main__':
    unittest.main(verbosity=2)
