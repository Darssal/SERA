import io
import json
import os
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

from ai_service import AiServiceError, SiliconFlowPlanner, load_api_key, validate_ai_tasks


GOAL = {'title': '准备数据库课程答辩', 'notes': '重点解释索引和事务', 'prompt': '请帮我安排准备过程',
        'deadline': '2026-11-20T18:00:00', 'dailyBudget': 90,
        'referenceNow': '2026-10-31T16:00:00+08:00', 'timeZone': 'Asia/Hong_Kong'}
TASKS = [{'title': '整理索引实验结果', 'notes': '比较执行计划并解释性能差异', 'estimatedMinutes': 45,
          'checklist': ['导出执行计划', '记录查询耗时']}]
FAKE_KEY = 'sk-unit-test-secret-not-a-real-key'


def completion(tasks=TASKS, finish='stop'):
    return {'model': 'test-model', 'choices': [{'finish_reason': finish,
            'message': {'content': json.dumps({'tasks': tasks}, ensure_ascii=False)}}]}


class AiTests(unittest.TestCase):
    @patch('ai_service.urlopen')
    def test_provider_request_has_json_contract_and_returns_validated_semantic_tasks(self, mocked):
        mocked.return_value = io.BytesIO(json.dumps(completion()).encode())
        result = SiliconFlowPlanner(FAKE_KEY, model='test-model').generate(GOAL)
        self.assertEqual(result, {'tasks': TASKS, 'model': 'test-model', 'source': 'siliconflow'})
        request = mocked.call_args.args[0]
        sent = json.loads(request.data)
        self.assertEqual(sent['response_format'], {'type': 'json_object'})
        self.assertEqual(sent['model'], 'test-model')
        self.assertEqual(json.loads(sent['messages'][1]['content'])['title'], GOAL['title'])
        self.assertEqual(request.headers['Authorization'], 'Bearer ' + FAKE_KEY)
        self.assertNotIn(FAKE_KEY, json.dumps(result))

    @patch('ai_service.urlopen')
    def test_valid_over_budget_output_is_returned_once_for_local_confirmation(self, mocked):
        mocked.return_value = io.BytesIO(json.dumps(completion()).encode())
        result = SiliconFlowPlanner(FAKE_KEY, model='test-model').generate({**GOAL, 'dailyBudget': 15})
        self.assertEqual(result['tasks'], TASKS)
        self.assertEqual(mocked.call_count, 1)

    @patch('ai_service.urlopen')
    def test_missing_configuration_does_not_call_provider_or_fallback(self, mocked):
        with self.assertRaises(AiServiceError) as caught:
            SiliconFlowPlanner().generate(GOAL)
        self.assertEqual(caught.exception.status, 503)
        self.assertEqual(caught.exception.code, 'ai_not_configured')
        mocked.assert_not_called()

    @patch('ai_service.urlopen')
    def test_invalid_input_is_rejected_before_any_billable_call(self, mocked):
        for changed in ({'title': ''}, {'deadline': 'not a date'}, {'dailyBudget': True}, {'notes': []}):
            with self.assertRaises(AiServiceError) as caught:
                SiliconFlowPlanner(FAKE_KEY).generate({**GOAL, **changed})
            self.assertEqual(caught.exception.status, 400)
        mocked.assert_not_called()

    @patch('ai_service.urlopen')
    def test_malformed_or_truncated_output_is_not_treated_as_success(self, mocked):
        for response in ({'choices': []}, completion(finish='length'), completion(tasks=[{**TASKS[0], 'estimatedMinutes': 32}])):
            mocked.return_value = io.BytesIO(json.dumps(response).encode())
            with self.assertRaises(AiServiceError) as caught:
                SiliconFlowPlanner(FAKE_KEY).generate(GOAL)
            self.assertEqual(caught.exception.code, 'invalid_ai_output')

    @patch('ai_service.urlopen')
    def test_rate_limit_credential_and_timeout_errors_are_safe_and_visible(self, mocked):
        for status in (401, 429, 503):
            mocked.side_effect = HTTPError('https://api.siliconflow.cn', status, 'upstream', {}, io.BytesIO(FAKE_KEY.encode()))
            with self.assertRaises(AiServiceError) as caught:
                SiliconFlowPlanner(FAKE_KEY).generate(GOAL)
            self.assertEqual(caught.exception.status, 429 if status == 429 else 502)
            self.assertNotIn(FAKE_KEY, str(caught.exception))
        mocked.side_effect = socket.timeout()
        with self.assertRaises(AiServiceError) as caught:
            SiliconFlowPlanner(FAKE_KEY).generate(GOAL)
        self.assertEqual(caught.exception.status, 504)

    def test_key_file_and_environment_are_server_only_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            key_path = Path(directory) / 'private.txt'
            key_path.write_text(FAKE_KEY)
            with patch.dict(os.environ, {'SILICONFLOW_API_KEY': ''}):
                self.assertEqual(load_api_key(key_path), FAKE_KEY)
            with patch.dict(os.environ, {'SILICONFLOW_API_KEY': 'sk-environment-override-key'}):
                self.assertEqual(load_api_key(key_path), 'sk-environment-override-key')
            with patch.dict(os.environ, {'SILICONFLOW_API_KEY': ''}):
                with self.assertRaises(AiServiceError):
                    load_api_key(Path(directory) / 'missing.txt')

    def test_task_limits_and_checklist_normalization(self):
        self.assertEqual(validate_ai_tasks({'tasks': [{**TASKS[0], 'checklist': ['检查', '检查']} ]})[0]['checklist'], ['检查'])
        for tasks in ([], TASKS * 97, [{**TASKS[0], 'estimatedMinutes': True}], [{**TASKS[0], 'estimatedMinutes': 250}]):
            with self.assertRaises(AiServiceError):
                validate_ai_tasks({'tasks': tasks})


if __name__ == '__main__':
    unittest.main(verbosity=2)
