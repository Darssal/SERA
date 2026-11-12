"""Bounded, backward-compatible conversation storage; temporary databases only."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

from fastapi import FastAPI
from api_contract import install_contract
from ai_service import validate_understanding
from auth_store import AuthStore
from server import ValidationError, WorkspaceStore, validate_workspace
from sync_store import SyncStore, migrate_workspace
from test_server import empty_workspace


def messages():
    return [
        {'id': 'user-1', 'role': 'user', 'text': '明晚八点到九点开会'},
        {'id': 'assistant-1', 'role': 'assistant', 'text': '请核对这次安排',
         'understanding': {'intent': 'event', 'title': '开会',
                           'start': '2026-11-01T20:00:00+08:00',
                           'questions': []}},
        {'id': 'user-2', 'role': 'user', 'text': '地点在会议室。\n请带上材料。'},
    ]


def workspace():
    value = migrate_workspace(empty_workspace())
    value['planningSessions'] = [{'id': 'conversation', 'prompt': '明晚八点到九点开会',
        'notes': '地点在会议室。\n请带上材料。', 'stage': 'understood',
        'updatedAt': '2026-10-31T16:00:00+08:00', 'messages': messages(),
        'composerDraft': '还没有发出的下一句话\n保留换行'}]
    return value


class PlanningMessageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / 'conversation.db'
        self.store = WorkspaceStore(self.path)

    def tearDown(self):
        self.temp.cleanup()

    def test_legacy_missing_null_and_empty_messages_need_no_schema_upgrade(self):
        for state in ('missing', None, []):
            value = workspace()
            session = value['planningSessions'][0]
            if state == 'missing':
                session.pop('messages')
            else:
                session['messages'] = state
            with self.subTest(state=state):
                validate_workspace(value)
                self.assertEqual(value['schemaVersion'], 2)

    def test_ordered_messages_and_structured_snapshots_survive_sqlite_reload(self):
        value = workspace()
        saved = self.store.save(value, 0)
        loaded = WorkspaceStore(self.path).load()
        self.assertEqual(loaded, saved)
        self.assertEqual(loaded['planningSessions'][0]['messages'], messages())
        self.assertEqual(loaded['planningSessions'][0]['composerDraft'], '还没有发出的下一句话\n保留换行')
        self.assertEqual(loaded['tasks'], [])
        self.assertEqual(loaded['entries'], [])

    def test_operation_sync_replays_the_same_conversation_without_extra_turns(self):
        accounts = AuthStore(self.path)
        account = accounts.register({'username': 'chat-fixture', 'email': 'chat@example.test',
                                     'password': 'SyntheticPassword123'})
        uid = account['user']['id']
        sync = SyncStore(self.path)
        self.store.save(migrate_workspace(empty_workspace()), 0, uid)
        session = workspace()['planningSessions'][0]
        operations = {'operations': [{'id': 'conversation-op', 'entityType': 'planningSessions',
            'entityId': session['id'], 'expectedVersion': 0, 'action': 'upsert', 'value': session}]}
        saved = sync.apply(uid, operations)
        replay = sync.apply(uid, operations)
        self.assertEqual(saved['workspace'], replay['workspace'])
        self.assertEqual(replay['replayed'], ['conversation-op'])
        self.assertEqual(replay['workspace']['planningSessions'][0]['messages'], messages())

    def test_maximum_count_text_id_and_structured_bytes_are_accepted(self):
        value = workspace()
        value['planningSessions'][0]['messages'] = [
            {'id': str(index), 'role': 'user', 'text': 'a' * 10000 if index == 0 else '继续'}
            for index in range(100)]
        validate_workspace(value)
        reply = {'x': 'a' * 63992}
        self.assertEqual(len(json.dumps(reply, ensure_ascii=False, separators=(',', ':')).encode('utf-8')), 64000)
        value['planningSessions'][0]['messages'] = [
            {'id': 'a' * 128, 'role': 'assistant', 'text': '', 'understanding': reply}]
        validate_workspace(value)

    def test_malformed_roles_ids_text_snapshots_and_duplicates_are_rejected(self):
        user = messages()[0]
        invalid = ['', {}, [None], ['message'],
            [{**user, 'role': 'system'}], [{**user, 'role': 1}],
            [{**user, 'id': ''}], [{**user, 'id': '  '}], [{**user, 'id': 'a' * 129}],
            [{**user, 'text': 1}], [{**user, 'text': ' \n '}], [{**user, 'text': 'a' * 10001}],
            [{**user, 'understanding': {'intent': 'event'}}],
            [{'id': 'x', 'role': 'assistant', 'text': '回复', 'understanding': []}],
            [{'id': 'x', 'role': 'assistant', 'text': '回复', 'understanding': {'x': '中' * 21331}}],
            [{'id': 'x', 'role': 'assistant', 'text': '回复', 'understanding': {'x': float('nan')}}],
            [{**user, 'requestId': 'unexpected-field'}],
            [user, user], [{**user, 'id': str(index)} for index in range(101)]]
        for invalid_messages in invalid:
            value = workspace()
            value['planningSessions'][0]['messages'] = invalid_messages
            with self.subTest(messages=str(invalid_messages)[:100]), self.assertRaises(ValidationError):
                validate_workspace(value)

    def test_invalid_conversation_rolls_back_without_replacing_prior_history(self):
        saved = self.store.save(workspace(), 0)
        invalid = copy.deepcopy(saved)
        invalid['planningSessions'][0]['messages'].append(messages()[0])
        with self.assertRaises(ValidationError):
            self.store.save(invalid, saved['revision'])
        self.assertEqual(self.store.load(), saved)

    def test_maximum_cjk_and_escaped_valid_reply_can_be_saved(self):
        reply = {'source': 'siliconflow', 'model': '中' * 200,
            'intent': 'goal', 'title': '中' * 200, 'summary': '中' * 1000,
            'outcome': '\u0000' * 1998 + '中文', 'deadline': None,
            'deadlineIsDateOnly': False, 'dailyBudget': 480, 'estimatedMinutes': 480,
            'start': None, 'end': None,
            'questions': [{'id': f'question-{index}', 'question': '中' * 300} for index in range(2)]}
        validate_understanding(reply)
        encoded = json.dumps(reply, ensure_ascii=False, separators=(',', ':'))
        self.assertLessEqual(len(encoded), 16000)
        self.assertGreater(len(encoded.encode('utf-8')), 16000)
        value = workspace()
        value['planningSessions'][0]['messages'] = [
            {'id': 'large-valid-reply', 'role': 'assistant', 'text': reply['summary'], 'understanding': reply}]
        saved = self.store.save(value, 0)
        self.assertEqual(saved['planningSessions'][0]['messages'][0]['understanding'], reply)
        self.assertEqual(self.store.load(), saved)

    def test_unsent_draft_is_optional_bounded_text_and_does_not_create_turns(self):
        for draft in ('missing', None, '', 'a' * 10000):
            value = workspace()
            session = value['planningSessions'][0]
            if draft == 'missing':
                session.pop('composerDraft')
            else:
                session['composerDraft'] = draft
            validate_workspace(value)
            self.assertEqual(session['messages'], messages())
        for draft in (1, [], {}, 'a' * 10001):
            value = workspace()
            value['planningSessions'][0]['composerDraft'] = draft
            with self.subTest(draft=str(draft)[:30]), self.assertRaises(ValidationError):
                validate_workspace(value)

    def test_openapi_exposes_optional_typed_bounded_messages_in_schema_2(self):
        app = FastAPI()
        async def compatibility(request):
            return {}
        install_contract(app, compatibility)
        schemas = app.openapi()['components']['schemas']
        self.assertEqual(schemas['PlanningMessage']['properties']['role']['enum'], ['user', 'assistant'])
        self.assertEqual(schemas['PlanningMessage']['required'], ['id', 'role', 'text'])
        self.assertEqual(schemas['PlanningSession']['properties']['messages']['anyOf'][0]['maxItems'], 100)
        self.assertNotIn('messages', schemas['PlanningSession']['required'])
        self.assertNotIn('composerDraft', schemas['PlanningSession']['required'])
        self.assertEqual(schemas['PlanningSession']['properties']['composerDraft']['maxLength'], 10000)
        self.assertEqual(schemas['Workspace']['properties']['schemaVersion']['maximum'], 2)


if __name__ == '__main__':
    unittest.main()
