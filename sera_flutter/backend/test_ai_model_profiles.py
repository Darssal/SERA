"""Offline checks of adopted model/operation-specific production settings."""
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch

from ai_service import AiServiceError, DEFAULT_MODEL, GLM_FLASH_MODEL, SiliconFlowPlanner
from understanding_contract import UNDERSTANDING_OUTPUT_SCHEMA, UNDERSTANDING_SYSTEM_PROMPT

KEY = 'sk-model-profile-test-not-a-real-secret'
INPUT = {'prompt': '明天下午三点有课', 'referenceNow': '2026-10-31T16:00:00+08:00',
         'timeZone': 'Asia/Hong_Kong', 'dailyBudget': 90}
GOAL = {'title': '课程展示准备', 'notes': '五页幻灯片和八分钟讲解', 'prompt': '分步准备',
        'deadline': '2026-11-20T23:59:00+08:00', 'dailyBudget': 40,
        'referenceNow': '2026-10-31T16:00:00+08:00', 'timeZone': 'Asia/Hong_Kong'}
UNDERSTANDING = {'intent': 'event', 'title': '课程', 'summary': '明天下午三点有课',
    'outcome': '', 'deadline': None, 'deadlineIsDateOnly': False, 'dailyBudget': None,
    'estimatedMinutes': None, 'start': '2026-11-01T15:00:00+08:00', 'end': None, 'questions': []}
PLAN = {'tasks': [{'title': '整理五页大纲', 'notes': '逐页列出要点与讲解顺序',
                  'estimatedMinutes': 30, 'checklist': ['列出五页标题', '匹配讲解顺序']}]}


def envelope(value, model=GLM_FLASH_MODEL):
    return io.BytesIO(json.dumps({'model': model, 'choices': [{'finish_reason': 'stop',
        'message': {'content': json.dumps(value, ensure_ascii=False)}}]}, ensure_ascii=False).encode('utf-8'))


class ModelProfileTests(unittest.TestCase):
    def test_default_uses_adopted_glm_without_replacing_explicit_model(self):
        self.assertEqual(DEFAULT_MODEL, 'zai-org/GLM-5.3-Flash')
        self.assertEqual(SiliconFlowPlanner().model, DEFAULT_MODEL)
        self.assertEqual(SiliconFlowPlanner(model='explicit/model').model, 'explicit/model')

    @patch('ai_service.urlopen')
    def test_glm_understanding_uses_tested_long_low_strict_eleven_field_request(self, mocked):
        mocked.return_value = envelope(UNDERSTANDING)
        result = SiliconFlowPlanner(KEY).understand(INPUT)
        sent = json.loads(mocked.call_args.args[0].data.decode('utf-8'))
        self.assertEqual({k: v for k, v in sent.items() if k not in ('messages', 'tools', 'tool_choice')}, {
            'model': GLM_FLASH_MODEL, 'stream': False, 'temperature': .1, 'max_tokens': 1800,
            'reasoning_effort': 'low', 'response_format': {'type': 'json_schema', 'json_schema': {
                'name': 'sera_understanding', 'strict': True, 'schema': UNDERSTANDING_OUTPUT_SCHEMA}}})
        self.assertEqual(len(sent['response_format']['json_schema']['schema']['required']), 11)
        self.assertEqual(sent['response_format']['json_schema']['schema']['properties']['questions']['maxItems'], 2)
        marker = '\ncalendarContext（由已验证的 referenceNow/timeZone 计算，仅供理解，不是输出字段）：\n'
        prompt, calendar = sent['messages'][0]['content'].split(marker)
        self.assertEqual(prompt, UNDERSTANDING_SYSTEM_PROMPT)
        self.assertEqual(json.loads(calendar)['relativeCalendarDates']['明天'], '2026-11-01')
        self.assertEqual(json.loads(sent['messages'][1]['content'])['prompt'], INPUT['prompt'])
        self.assertEqual(result['start'], UNDERSTANDING['start'])
        self.assertIsNone(result['end'])
        self.assertNotIn(KEY, json.dumps(result))
        self.assertEqual(mocked.call_count, 1)
        self.assertEqual(sent['tool_choice'], 'auto')
        self.assertEqual([tool['function']['name'] for tool in sent['tools']],
                         ['search_public_web', 'read_public_page'])

    @patch('ai_service.urlopen')
    def test_glm_plan_uses_tested_low_existing_plan_format_not_understanding_schema(self, mocked):
        mocked.return_value = envelope(PLAN)
        result = SiliconFlowPlanner(KEY).generate(GOAL)
        sent = json.loads(mocked.call_args.args[0].data.decode('utf-8'))
        self.assertEqual({k: v for k, v in sent.items() if k != 'messages'}, {
            'model': GLM_FLASH_MODEL, 'stream': False, 'temperature': .2, 'max_tokens': 6000,
            'reasoning_effort': 'low', 'response_format': {'type': 'json_object'}})
        self.assertEqual(result['tasks'], PLAN['tasks'])
        self.assertIn('独立约束排期引擎', sent['messages'][0]['content'])
        self.assertNotIn('sera_understanding', json.dumps(sent))
        self.assertEqual(mocked.call_args.kwargs['timeout'], 75)
        self.assertNotIn('tools', sent)

    @patch('ai_service.urlopen')
    def test_operation_profiles_do_not_leak_across_calls_on_same_planner(self, mocked):
        mocked.side_effect = [envelope(UNDERSTANDING), envelope(PLAN), envelope(UNDERSTANDING)]
        planner = SiliconFlowPlanner(KEY)
        planner.understand(INPUT)
        planner.generate(GOAL)
        planner.understand(INPUT)
        sent = [json.loads(call.args[0].data.decode('utf-8')) for call in mocked.call_args_list]
        self.assertEqual([p['response_format']['type'] for p in sent],
                         ['json_schema', 'json_object', 'json_schema'])
        self.assertEqual([p['max_tokens'] for p in sent], [1800, 6000, 1800])

    @patch('ai_service.urlopen')
    def test_other_explicit_models_keep_legacy_parameters_without_glm_only_options(self, mocked):
        for model in ('Qwen/Qwen2.5-7B-Instruct', 'Qwen/Qwen3-8B', 'custom/explicit-model'):
            with self.subTest(model=model):
                mocked.reset_mock()
                mocked.side_effect = [envelope(UNDERSTANDING, model), envelope(PLAN, model)]
                planner = SiliconFlowPlanner(KEY, model=model)
                planner.understand(INPUT)
                planner.generate(GOAL)
                for index, call in enumerate(mocked.call_args_list):
                    sent = json.loads(call.args[0].data.decode('utf-8'))
                    self.assertEqual(sent['model'], model)
                    self.assertEqual(sent['response_format'], {'type': 'json_object'})
                    self.assertNotIn('reasoning_effort', sent)
                    self.assertEqual(sent['temperature'], .1 if index == 0 else .2)
                    self.assertEqual(sent['max_tokens'], 1800 if index == 0 else 2400)

    def test_outgoing_schema_mutation_cannot_change_contract_or_later_request(self):
        original = deepcopy(UNDERSTANDING_OUTPUT_SCHEMA)
        captured = []
        planner = SiliconFlowPlanner(KEY)
        def complete(payload):
            captured.append(deepcopy(payload))
            schema = payload['response_format']['json_schema']['schema']
            schema['required'].clear()
            schema['properties']['questions']['maxItems'] = 99
            return deepcopy(UNDERSTANDING), GLM_FLASH_MODEL
        with patch.object(planner, '_complete', side_effect=complete):
            planner.understand(INPUT)
            planner.understand(INPUT)
        self.assertEqual(UNDERSTANDING_OUTPUT_SCHEMA, original)
        self.assertEqual(captured[0]['response_format'], captured[1]['response_format'])

    @patch('ai_service.urlopen')
    def test_schema_mode_still_rejects_invalid_provider_output_without_fallback(self, mocked):
        for value in ({**UNDERSTANDING, 'unexpected': True}, {**UNDERSTANDING, 'estimatedMinutes': True}):
            with self.subTest(value=value):
                mocked.reset_mock()
                mocked.return_value = envelope(value)
                with self.assertRaises(AiServiceError) as caught:
                    SiliconFlowPlanner(KEY).understand(INPUT)
                self.assertEqual(caught.exception.code, 'invalid_ai_output')
                self.assertEqual(mocked.call_count, 1)

    @patch('ai_service.urlopen')
    def test_known_end_unknown_start_is_preserved_without_provider_repair(self, mocked):
        value = {**UNDERSTANDING, 'summary': '电话到明晚九点，开始未定',
                 'start': None, 'end': '2026-11-01T21:00:00+08:00'}
        mocked.return_value = envelope(value)
        result = SiliconFlowPlanner(KEY).understand(INPUT)
        self.assertIsNone(result['start'])
        self.assertEqual(result['end'], value['end'])
        self.assertIsNone(result['estimatedMinutes'])


if __name__ == '__main__':
    unittest.main()
