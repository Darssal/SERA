import copy
from datetime import datetime, timezone
import json
import unittest

from auth_store import AuthError
from server import validate_workspace, ValidationError
from sync_store import migrate_workspace
from test_server import empty_workspace
from workflows import preview_ics


class V2ValidationTests(unittest.TestCase):
    def workspace(self):
        value = migrate_workspace(empty_workspace())
        value['tasks'] = [{'id': 'task', 'title': 'Independent task', 'goalId': None}]
        return value

    def test_cross_day_events_task_block_limit_and_refinement_synthetic_goal(self):
        value = self.workspace()
        event = {'id': 'event', 'title': 'Multi-day event', 'start': '2026-11-02T00:00:00Z',
            'end': '2026-11-05T00:00:00Z', 'allDay': True}
        value['entries'], value['externalBusyEntries'] = [event], [{**event, 'id': 'external'}]
        value['drafts'] = [{'id': 'refine', 'goal': {'id': 'display-only', 'title': 'Display',
            'deadline': '2026-11-06T00:00:00Z'}, 'status': 'draft', 'targetTaskId': 'task',
            'items': [{'task': value['tasks'][0]}]}]
        validate_workspace(value)
        self.assertEqual(value['goals'], [])
        invalid = copy.deepcopy(value)
        invalid['entries'][0]['taskId'] = 'task'
        with self.assertRaises(ValidationError): validate_workspace(invalid)
        invalid = copy.deepcopy(value)
        invalid['drafts'][0]['targetTaskId'] = 'missing'
        with self.assertRaises(ValidationError): validate_workspace(invalid)
        invalid = copy.deepcopy(value)
        invalid['drafts'][0]['items'][0]['task'] = {**value['tasks'][0], 'goalId': 'display-only'}
        with self.assertRaises(ValidationError): validate_workspace(invalid)
        # A saved stale draft must not prevent editing the real task later.
        stale = copy.deepcopy(value)
        stale['drafts'][0]['items'][0]['task'] = dict(value['tasks'][0])
        stale['drafts'][0]['baseTaskVersions'] = {'task': 1}
        stale['tasks'][0].update(goalId='real-goal', revision=2)
        stale['goals'] = [{'id': 'real-goal', 'title': 'Actual goal', 'deadline': '2026-11-06T00:00:00Z', 'taskIds': ['task']}]
        validate_workspace(stale)

    def test_v2_fields_reject_malformed_values_before_persistence(self):
        for change in (
            lambda w: w['preferences'].update(restStart=-1),
            lambda w: w['preferences'].update(useAiContext='true'),
            lambda w: w['tasks'][0].update(dueDate='2026-11-02T00:00:00Z'),
            lambda w: w['tasks'][0].update(blockedReason={'secret': True}),
            lambda w: w.update(reviews=[{'id': 'r', 'day': '2026-11-02', 'kind': 'invalid'}]),
            lambda w: w.update(focusSession={'id': 'f', 'taskId': 'task', 'startedAt': '2026-11-02T10:00:00Z',
                'lastResumedAt': '2026-11-02T09:00:00Z'}),
        ):
            value = self.workspace()
            change(value)
            with self.subTest(value=value), self.assertRaises(ValidationError): validate_workspace(value)

    def test_ics_override_exdate_and_multi_day_all_day(self):
        source = '''BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:series
DTSTART:20261102T100000Z
DTEND:20261102T110000Z
RRULE:FREQ=DAILY;COUNT=4
EXDATE:20261104T100000Z
SUMMARY:Original
END:VEVENT
BEGIN:VEVENT
UID:series
RECURRENCE-ID:20261103T100000Z
DTSTART:20261103T120000Z
DTEND:20261103T130000Z
SUMMARY:Moved
END:VEVENT
BEGIN:VEVENT
UID:series
RECURRENCE-ID:20261105T100000Z
STATUS:CANCELLED
DTSTART:20261105T100000Z
END:VEVENT
BEGIN:VEVENT
UID:all-day
DTSTART;VALUE=DATE:20261106
DTEND;VALUE=DATE:20261109
SUMMARY:Three days
END:VEVENT
END:VCALENDAR
'''.replace('\n', '\r\n').encode()
        result = preview_ics(source, datetime(2026, 11, 1, tzinfo=timezone.utc), datetime(2026, 11, 12, tzinfo=timezone.utc))
        self.assertEqual(len(result['entries']), 3)
        self.assertEqual({e['title'] for e in result['entries']}, {'Original', 'Moved', 'Three days'})
        moved = next(e for e in result['entries'] if e['title'] == 'Moved')
        self.assertTrue(moved['start'].startswith('2026-11-03T12:00:00'))
        self.assertTrue(next(e for e in result['entries'] if e['title'] == 'Three days')['allDay'])


if __name__ == '__main__': unittest.main()
