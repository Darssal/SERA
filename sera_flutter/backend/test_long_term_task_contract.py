import unittest

from server import ValidationError, validate_task
from api_contract import understanding_response_schema


class LongTermTaskContractTests(unittest.TestCase):
    def test_phase_window_valid_and_legacy_compatible(self):
        validate_task({'id': 'legacy', 'title': 'Legacy'})
        validate_task({'id': 'long', 'title': 'Trees', 'phase': 'Practice',
                       'notBefore': '2026-11-09T00:00:00+08:00',
                       'dueAt': '2026-11-16T00:00:00+08:00'})

    def test_bad_phase_window_is_rejected(self):
        for fields in ({'phase': ['invalid']}, {'phase': 'x' * 101},
                       {'notBefore': 'next week'},
                       {'notBefore': '2026-11-16T00:00:00+08:00',
                        'dueAt': '2026-11-09T00:00:00+08:00'}):
            with self.subTest(fields=fields), self.assertRaises(ValidationError):
                validate_task({'id': 't', 'title': 'Task', **fields})

    def test_research_metadata_optional_outside_model_fields(self):
        schema = understanding_response_schema()
        self.assertIn('references', schema['properties'])
        self.assertIn('research', schema['properties'])
        self.assertNotIn('research', schema['required'])
        self.assertEqual(len(schema['required']), 13)


if __name__ == '__main__':
    unittest.main()
