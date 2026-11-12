"""Strict current-provider output contract; no network calls or user database.

Legacy/history adaptation belongs to validate_understanding. These tests call
the actual SiliconFlowPlanner.understand provider entry point so an invalid new
model response cannot be silently repaired into a successful current result.
"""
from copy import deepcopy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from ai_service import AiServiceError, SiliconFlowPlanner
from fastapi.testclient import TestClient
from app import create_app
from understanding_contract import (
    UNDERSTANDING_OUTPUT_SCHEMA,
    UNDERSTANDING_SYSTEM_PROMPT,
    parse_provider_json,
    validate_provider_shape,
)


FIELDS = {
    "intent", "title", "summary", "outcome", "deadline", "deadlineIsDateOnly",
    "dailyBudget", "estimatedMinutes", "start", "end", "questions",
}
INPUT = {
    "prompt": "我明天下午三点有个课程，只知道开始时间，先给我核对。",
    "referenceNow": "2026-10-31T16:00:00+08:00",
    "timeZone": "Asia/Hong_Kong",
    "dailyBudget": 90,
}
VALID = {
    "intent": "event", "title": "课程", "summary": "明天下午三点有课程，结束时间未定。",
    "outcome": "", "deadline": None, "deadlineIsDateOnly": False,
    "dailyBudget": 90, "estimatedMinutes": None,
    "start": "2026-11-01T15:00:00+08:00", "end": None, "questions": [],
}


def provider_response(value=None, *, content=None):
    if content is None:
        content = json.dumps(VALID if value is None else value, ensure_ascii=False)
    envelope = {"model": "strict-contract-offline-fixture", "choices": [
        {"finish_reason": "stop", "message": {"content": content}},
    ]}
    return io.BytesIO(json.dumps(envelope, ensure_ascii=False).encode("utf-8"))


class UnderstandingOutputContractTests(unittest.TestCase):
    def setUp(self):
        self.urlopen = patch("ai_service.urlopen").start()
        self.addCleanup(patch.stopall)
        self.planner = SiliconFlowPlanner("sk-offline-fixture-not-a-real-secret")

    def reject(self, value=None, *, content=None):
        self.urlopen.return_value = provider_response(value, content=content)
        with self.assertRaises(AiServiceError) as caught:
            self.planner.understand(INPUT)
        self.assertEqual(caught.exception.code, "invalid_ai_output")
        self.assertEqual(caught.exception.status, 502)

    def test_each_of_eleven_fields_is_required_at_the_actual_provider_boundary(self):
        self.assertEqual(set(VALID), FIELDS)
        for field in sorted(FIELDS):
            with self.subTest(missing=field):
                value = deepcopy(VALID)
                del value[field]
                self.reject(value)

    def test_extra_top_level_fields_are_rejected_instead_of_being_removed(self):
        for field, value in (("source", "siliconflow"), ("model", "pretend-model"),
                             ("规划时间", "明天下午三点"), ("tasks", []), ("debug", "extra")):
            with self.subTest(field=field):
                self.reject({**VALID, field: value})

    def test_new_provider_questions_must_use_the_exact_id_question_shape(self):
        invalid = [
            "请问几点结束？", None, {}, ["请问几点结束？"],
            [{"id": "q1", "text": "请问几点结束？"}],
            [{"text": "请问几点结束？"}], [{"question": "请问几点结束？"}],
            [{"id": "q1", "question": "请问几点结束？", "text": "额外字段"}],
            [{"id": "课程时间", "question": "请问几点结束？"}],
            [{"id": "q1", "question": "   "}],
            [{"id": "q1", "question": "问" * 301}],
        ]
        for questions in invalid:
            with self.subTest(questions=questions):
                self.reject({**VALID, "questions": questions})

    def test_three_questions_and_duplicate_ids_are_invalid_current_output(self):
        self.reject({**VALID, "questions": [
            {"id": "q1", "question": "先处理哪件事？"},
            {"id": "q2", "question": "完成标准是什么？"},
            {"id": "q3", "question": "什么时候完成？"},
        ]})
        self.reject({**VALID, "questions": [
            {"id": "same", "question": "先处理哪件事？"},
            {"id": "same", "question": "完成标准是什么？"},
        ]})

    def test_timestamps_without_offsets_or_real_calendar_dates_are_rejected(self):
        for field in ("start", "end", "deadline"):
            for value in ("2026-11-01T15:00:00", "2026-11-01", "tomorrow", "2026-02-30T15:00:00+08:00"):
                with self.subTest(field=field, value=value):
                    self.reject({**VALID, field: value})

    def test_boolean_is_never_an_integer_budget_or_duration(self):
        for field in ("dailyBudget", "estimatedMinutes"):
            for value in (True, False):
                with self.subTest(field=field, value=value):
                    self.reject({**VALID, field: value})
        for value in (0, 1, None, "false"):
            with self.subTest(deadlineIsDateOnly=value):
                self.reject({**VALID, "deadlineIsDateOnly": value})

    def test_duplicate_json_keys_even_with_valid_final_values_are_rejected(self):
        original = json.dumps(VALID, ensure_ascii=False)
        duplicate_intent = '{"intent":"other",' + original[1:]
        duplicate_start = '{"start":null,' + original[1:]
        duplicate_question_key = json.dumps({**VALID, "questions": [{"id": "q1", "question": "先处理哪个？"}]}, ensure_ascii=False).replace('"id": "q1"', '"id":"old","id":"q1"')
        for content in (duplicate_intent, duplicate_start, duplicate_question_key):
            with self.subTest(content=content):
                self.reject(content=content)

    def test_nan_infinity_and_markdown_are_invalid_not_repaired(self):
        raw = json.dumps(VALID, ensure_ascii=False)
        for content in (
            raw.replace('"dailyBudget": 90', '"dailyBudget": NaN'),
            raw.replace('"estimatedMinutes": null', '"estimatedMinutes": Infinity'),
            raw.replace('"estimatedMinutes": null', '"estimatedMinutes": -Infinity'),
            "```json\n" + raw + "\n```",
            "这是理解结果：\n" + raw,
            raw + "\n请确认",
        ):
            with self.subTest(content=content):
                self.reject(content=content)

    def test_strict_json_helper_rejects_constants_and_duplicates_before_shape_validation(self):
        for content in ('{"x":NaN}', '{"x":Infinity}', '{"x":-Infinity}', '{"x":1,"x":2}',
                        '{"nested":{"x":1,"x":2}}', '```json\n{}\n```'):
            with self.subTest(content=content), self.assertRaises(ValueError):
                parse_provider_json(content)

    def test_single_start_keeps_unknown_end_and_accepts_zero_or_one_model_judged_question(self):
        for questions in ([], [{'id': 'duration', 'question': '预计持续多久？'}]):
            with self.subTest(questions=questions):
                value = {**VALID, 'summary': '明天下午三点有课程。', 'questions': questions}
                self.urlopen.return_value = provider_response(value)
                result = self.planner.understand({**INPUT, 'prompt': '我明天下午三点有个课程。'})
                self.assertEqual({field: result[field] for field in FIELDS}, value)
                self.assertEqual(result['start'], '2026-11-01T15:00:00+08:00')
                self.assertIsNone(result['end'])
                self.assertIsNone(result['deadline'])
                self.assertIsNone(result['estimatedMinutes'])
                self.assertEqual(result['questions'], questions)
                self.assertEqual(result['source'], 'siliconflow')
                self.assertEqual(result['model'], 'strict-contract-offline-fixture')

    def test_question_history_and_explicit_deferral_do_not_generate_followups_in_python(self):
        previous = {**VALID, 'questions': [{'id': 'duration', 'question': '预计持续多久？'}],
                    'clarificationAnswers': {'duration': '还没定，之后在表单补'}}
        notes = '结束时间还没定，之后在表单补，先不设截止。'
        self.urlopen.return_value = provider_response(VALID)
        result = self.planner.understand({**INPUT, 'previous': previous, 'notes': notes})
        payload = json.loads(self.urlopen.call_args.args[0].data.decode('utf-8'))
        supplied = json.loads(payload['messages'][1]['content'])
        self.assertEqual(supplied['previous'], previous)
        self.assertEqual(supplied['notes'], notes)
        self.assertEqual(result['questions'], [])
        self.assertEqual(result['start'], VALID['start'])
        self.assertIsNone(result['end'])
        self.assertIsNone(result['deadline'])
        self.assertIn('null本身不触发追问', payload['messages'][0]['content'])
        self.assertIn('同一事项的可选补问只进行一次', payload['messages'][0]['content'])

    def test_two_question_schema_compatibility_is_separate_from_one_question_prompt_policy(self):
        value = {**VALID, "intent": "goal", "start": None,
                 "deadline": "2026-11-20T23:59:00+08:00", "deadlineIsDateOnly": True,
                 "questions": [{"id": "q1", "question": "具体准备哪类展示？"},
                               {"id": "q2", "question": "需要达到什么完成标准？"}]}
        self.urlopen.return_value = provider_response(value)
        result = self.planner.understand(INPUT)
        self.assertEqual({field: result[field] for field in FIELDS}, value)
        # The standalone strict validator also accepts the canonical provider
        # shape without adding source/model metadata or inventing unknowns.
        checked = deepcopy(value)
        validate_provider_shape(checked)
        self.assertEqual(checked, value)
        self.assertEqual(UNDERSTANDING_OUTPUT_SCHEMA['properties']['questions']['maxItems'], 2)
        self.assertIn('本轮最多1项', UNDERSTANDING_SYSTEM_PROMPT)

    def test_real_request_prompt_and_schema_agree_on_the_same_eleven_fields(self):
        self.urlopen.return_value = provider_response()
        self.planner.understand(INPUT)
        payload = json.loads(self.urlopen.call_args.args[0].data.decode("utf-8"))
        self.assertEqual([message["role"] for message in payload["messages"]], ["system", "user"])
        instructions = payload["messages"][0]["content"]
        self.assertIn(UNDERSTANDING_SYSTEM_PROMPT, instructions)
        self.assertEqual(set(UNDERSTANDING_OUTPUT_SCHEMA["properties"]), FIELDS)
        self.assertEqual(set(UNDERSTANDING_OUTPUT_SCHEMA["required"]), FIELDS)
        self.assertFalse(UNDERSTANDING_OUTPUT_SCHEMA["additionalProperties"])
        for field in FIELDS:
            with self.subTest(field=field):
                self.assertIn('"' + field + '"', instructions)
        questions = UNDERSTANDING_OUTPUT_SCHEMA["properties"]["questions"]
        self.assertEqual(questions["type"], "array")
        self.assertEqual(questions["maxItems"], 2)
        self.assertEqual(set(questions["items"]["required"]), {"id", "question"})
        self.assertEqual(set(questions["items"]["properties"]), {"id", "question"})
        self.assertFalse(questions["items"]["additionalProperties"])
        supplied = json.loads(payload["messages"][1]["content"])
        for field, expected in INPUT.items():
            self.assertEqual(supplied[field], expected)

    def test_actual_openapi_uses_deep_copied_provider_schema_plus_server_metadata(self):
        class NoTranscriber:
            configured = False

        original = deepcopy(UNDERSTANDING_OUTPUT_SCHEMA)
        with tempfile.TemporaryDirectory() as directory:
            application = create_app(db_path=Path(directory) / 'contract.sqlite3',
                                     ai_service=self.planner, transcriber=NoTranscriber())
            with TestClient(application) as client:
                response = client.get('/openapi.json')
                self.assertEqual(response.status_code, 200)
                actual = response.json()['components']['schemas']['AiUnderstanding']
                internal = application.openapi()['components']['schemas']['AiUnderstanding']
                internal['properties']['questions']['maxItems'] = 99
                self.assertEqual(UNDERSTANDING_OUTPUT_SCHEMA, original)
                internal['properties']['questions']['maxItems'] = 2
        self.assertEqual(set(actual['properties']), FIELDS | {'source', 'model', 'references', 'research'})
        self.assertEqual(set(actual['required']), FIELDS | {'source', 'model'})
        self.assertEqual(len(actual['required']), 13)
        self.assertFalse(actual['additionalProperties'])
        self.assertEqual(actual['properties']['source'], {'type': 'string', 'enum': ['siliconflow']})
        self.assertEqual(actual['properties']['model']['type'], 'string')
        for field in FIELDS:
            self.assertEqual(actual['properties'][field], UNDERSTANDING_OUTPUT_SCHEMA['properties'][field])
        self.assertEqual(actual['properties']['questions']['maxItems'], 2)
        actual['properties']['questions']['maxItems'] = 99
        self.assertEqual(UNDERSTANDING_OUTPUT_SCHEMA, original)
        self.assertNotIn('source', UNDERSTANDING_OUTPUT_SCHEMA['properties'])
        self.urlopen.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
