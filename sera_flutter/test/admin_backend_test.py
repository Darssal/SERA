"""Admin API integration: temporary data and inert external providers only."""
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))

from fastapi.testclient import TestClient

from app import create_app
from auth_store import AuthError, AuthStore
from community_store import CommunityStore


PASSWORD = 'IsolatedAdminPassword123'
ADMIN = '/api/v1/admin'
COMMUNITY = '/api/v1/community'


def permissions(**enabled):
    return {'publishOfficial': False, 'publishActivity': False,
            'moderatePosts': False, 'moderateComments': False, **enabled}


class AdminBackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'isolated.sqlite3'
        self.accounts = AuthStore(self.path)
        self.owner, self.reader, self.moderator = [self.accounts.register({
            'username': name, 'email': name + '@example.test', 'password': PASSWORD,
        }) for name in ('official-owner', 'regular-reader', 'community-moderator')]
        environment = patch.dict(os.environ, {
            'SERA_COMMUNITY_OFFICIAL_USER_IDS': self.owner['user']['id'],
            'SERA_MAIL_MODE': 'local', 'SERA_PUBLIC_ORIGIN': 'https://sera.example.test',
        })
        environment.start()
        self.addCleanup(environment.stop)
        inert = SimpleNamespace(configured=False, model='isolated-provider')
        self.app = create_app(db_path=self.path, ai_service=inert, transcriber=inert,
                              sms_service=SimpleNamespace(capabilities=lambda: {'enabled': False}))
        self.client = TestClient(self.app)
        self.client.__enter__()
        self.addCleanup(lambda: self.client.__exit__(None, None, None))
        self.store = self.app.state.admin
        self.community = self.app.state.community
        self.sequence = 0

    def headers(self, session=None):
        return {'Authorization': 'Bearer ' + (session or self.owner)['token']}

    def request_id(self):
        self.sequence += 1
        return 'admin-isolated-' + str(self.sequence)

    def grant(self, **enabled):
        response = self.client.post(COMMUNITY + '/admins', headers=self.headers(), json={
            'identifier': self.moderator['user']['username'], 'permissions': permissions(**enabled)})
        self.assertEqual(response.status_code, 200, response.text)

    def publish(self, session=None, **changes):
        response = self.client.post(COMMUNITY + '/posts', headers=self.headers(session or self.reader), json={
            'requestId': self.request_id(), 'title': '日常记录', 'content': '记录今天的一点进展。',
            'kind': 'post', 'official': False, **changes})
        self.assertEqual(response.status_code, 201, response.text)
        return response.json()['post']

    def comment(self, post, content='评论进展'): 
        response = self.client.post(COMMUNITY + '/posts/' + post['id'] + '/comments',
            headers=self.headers(self.reader), json={'requestId': self.request_id(), 'content': content})
        self.assertEqual(response.status_code, 201, response.text)
        return response.json()['comment']

    def get(self, path, session=None, **params):
        return self.client.get(ADMIN + path, headers=self.headers(session), params=params)

    def set_status(self, disabled, *, target=None, request_id=None, reason='处理确认的违规行为'):
        return self.client.put(ADMIN + '/users/' + (target or self.reader['user']['id']) + '/status',
            headers=self.headers(), json={'requestId': request_id or self.request_id(), 'reason': reason, 'disabled': disabled})

    def delete_post(self, post, *, session=None, request_id=None, reason='清理测试内容'):
        return self.client.request('DELETE', ADMIN + '/posts/' + post['id'], headers=self.headers(session),
            json={'requestId': request_id or self.request_id(), 'reason': reason})

    def test_every_admin_read_requires_a_real_session_and_management_identity(self):
        for path in ('/bootstrap', '/posts', '/comments', '/users', '/audit', '/status'):
            self.assertEqual(self.client.get(ADMIN + path).status_code, 401)
            response = self.get(path, self.reader)
            self.assertEqual(response.status_code, 403, (path, response.text))
            self.assertEqual(response.headers['cache-control'], 'no-store')

    def test_bootstrap_uses_real_counts_and_hides_owner_counts_from_delegated_admin(self):
        post = self.publish(category='feedback')
        self.comment(post)
        self.grant(publishOfficial=True)
        result = self.get('/bootstrap').json()
        self.assertEqual(result['counts'], {'posts': 3, 'comments': 1, 'feedback': 1, 'activities': 1,
                                          'pendingApplications': 0, 'users': 3, 'admins': 1})
        delegated = self.get('/bootstrap', self.moderator).json()
        self.assertFalse(delegated['viewer']['isOfficial'])
        self.assertEqual(delegated['counts']['posts'], 3)
        for name in ('users', 'admins', 'pendingApplications'):
            self.assertIsNone(delegated['counts'][name])

    def test_zero_permission_admin_can_read_public_posts_but_no_private_admin_sections(self):
        self.grant()
        self.assertEqual(self.get('/posts', self.moderator).status_code, 200)
        for path in ('/comments', '/users', '/audit', '/status'):
            self.assertEqual(self.get(path, self.moderator).status_code, 403, path)

    def test_permissions_are_rechecked_immediately_without_refreshing_session(self):
        self.grant(moderateComments=True, moderatePosts=True)
        self.assertEqual(self.get('/comments', self.moderator).status_code, 200)
        response = self.client.put(COMMUNITY + '/admins/' + self.moderator['user']['id'],
            headers=self.headers(), json={'permissions': permissions(publishOfficial=True)})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.get('/comments', self.moderator).status_code, 403)
        self.client.delete(COMMUNITY + '/admins/' + self.moderator['user']['id'], headers=self.headers())
        self.assertEqual(self.get('/bootstrap', self.moderator).status_code, 403)

    def test_post_filters_search_literal_wildcards_and_existing_dto(self):
        daily = self.publish(title='100%_进展', content='这是一条精确匹配记录')
        self.publish(title='100xxxxx进展', content='不应被百分号通配')
        feedback = self.publish(title='提醒体验', category='feedback')
        found = self.get('/posts', q='%_').json()
        self.assertEqual([row['id'] for row in found['posts']], [daily['id']])
        self.assertEqual(self.get('/posts', category='feedback').json()['posts'][0]['id'], feedback['id'])
        official = self.get('/posts', official='yes').json()['posts']
        self.assertEqual(len(official), 2)
        self.assertTrue(all(row['isOfficial'] for row in official))
        self.assertEqual(len(self.get('/posts', kind='activity').json()['posts']), 1)
        dto = self.get('/posts', q=daily['id']).json()['posts'][0]
        self.assertEqual(dto['media'], [])
        self.assertTrue(dto['canDelete'])
        self.assertEqual(dto['authorId'], self.reader['user']['id'])

    def test_cursor_is_stable_for_inserts_and_scoped_to_filters(self):
        for index in range(4):
            self.publish(title='分页' + str(index))
        first = self.get('/posts', limit=2).json()
        self.assertEqual(len(first['posts']), 2)
        self.publish(title='刷新后新增')
        second = self.get('/posts', limit=2, cursor=first['nextCursor']).json()
        self.assertTrue(set(row['id'] for row in first['posts']).isdisjoint(row['id'] for row in second['posts']))
        self.assertEqual(self.get('/posts', cursor=first['nextCursor'], q='其他条件').status_code, 400)
        self.assertEqual(self.get('/comments', cursor=first['nextCursor']).status_code, 400)

    def test_query_bounds_and_malformed_cursor_fail_without_querying_arbitrary_sql(self):
        for params in ({'limit': 0}, {'limit': 101}, {'limit': '2x'}, {'q': 'x' * 201},
                       {'category': 'secret'}, {'kind': 'workspaces'}, {'official': 'owner'},
                       {'cursor': 'x' * 513}, {'cursor': 'not+base64'}, {'q': '\x00'}):
            response = self.get('/posts', **params)
            self.assertEqual(response.status_code, 400, (params, response.text))
        self.assertEqual(self.get('/posts', q="' OR 1=1 --").json()['posts'], [])

    def test_comments_are_global_paginated_and_include_exact_post_context(self):
        post = self.publish(title='评论所属帖子')
        comments = [self.comment(post, '评论' + str(index)) for index in range(3)]
        self.grant(moderateComments=True)
        first = self.get('/comments', self.moderator, postId=post['id'], limit=2).json()
        self.assertEqual(first['total'], 3)
        self.assertEqual([row['id'] for row in first['comments']], [comments[2]['id'], comments[1]['id']])
        self.assertEqual(first['comments'][0]['postTitle'], post['title'])
        next_page = self.get('/comments', self.moderator, postId=post['id'], cursor=first['nextCursor'], limit=2).json()
        self.assertEqual(next_page['comments'][0]['id'], comments[0]['id'])
        self.assertIsNone(next_page['nextCursor'])
        self.assertEqual(self.get('/comments', self.moderator, q='评论1').json()['total'], 1)

    def test_author_search_matches_public_names_without_disclosing_hidden_login_identifiers(self):
        post = self.publish()
        self.comment(post)
        self.assertEqual(self.get('/posts', q='regular-reader').json()['posts'][0]['id'], post['id'])
        self.assertEqual(self.get('/comments', q='regular-reader').json()['total'], 1)
        self.assertEqual(self.get('/posts', q='SERA 官方').json()['total'], 2)
        with self.accounts.connection() as db:
            db.execute('UPDATE users SET username=? WHERE id=?', ('hidden-login@example.test', self.reader['user']['id']))
        self.assertEqual(self.get('/posts', q='hidden-login@example.test').json()['total'], 0)
        self.assertEqual(self.get('/comments', q='hidden-login@example.test').json()['total'], 0)
        self.assertEqual(self.get('/posts', q='社区用户').json()['posts'][0]['id'], post['id'])

    def test_user_list_masks_identity_and_never_reads_private_workspaces(self):
        uid = self.reader['user']['id']
        with self.accounts.connection() as db:
            db.execute('UPDATE users SET phone=? WHERE id=?', ('+8613800000001', uid))
            db.execute('INSERT INTO account_workspaces VALUES(?,?,?)', (uid, 7, 'private-workspace-must-not-leak'))
        result = self.get('/users', q='regular-reader').json()
        self.assertEqual(result['total'], 1)
        user = result['users'][0]
        self.assertEqual(user['emailMasked'], 'r***@example.test')
        self.assertEqual(user['phoneMasked'], '+86138****0001')
        self.assertEqual(set(user), {'id', 'username', 'emailMasked', 'phoneMasked', 'emailVerified',
                                    'createdAt', 'disabled', 'postCount', 'commentCount'})
        self.assertNotIn('private-workspace', json.dumps(result))
        self.assertNotIn(self.reader['user']['email'], json.dumps(result))
        self.assertEqual(self.get('/users', q='+8613800000001').json()['users'][0]['id'], uid)

    def test_user_pagination_has_no_duplicates_with_equal_created_timestamps(self):
        with self.accounts.connection() as db:
            db.execute('UPDATE users SET created_at=100')
        found, cursor = [], None
        for _ in range(4):
            page = self.get('/users', cursor=cursor, limit=1).json()
            found.extend(row['id'] for row in page['users'])
            cursor = page['nextCursor']
            if not cursor:
                break
        self.assertEqual(len(found), 3)
        self.assertEqual(len(set(found)), 3)

    def test_disabled_account_revokes_all_sessions_push_tickets_jobs_and_preserves_workspace(self):
        uid = self.reader['user']['id']
        other = self.accounts.login({'identifier': 'regular-reader', 'password': PASSWORD})
        with self.accounts.connection() as db:
            db.execute('INSERT INTO account_workspaces VALUES(?,?,?)', (uid, 4, '{"preserved":true}'))
            db.execute('INSERT INTO push_subscriptions VALUES(?,?,?,?,?)', ('https://push.invalid/one', uid, '{}', 1, 'session'))
            db.execute('INSERT INTO asr_tickets VALUES(?,?,?,?,0)', ('nonce', uid, 'session', int(time.time()) + 60))
            db.execute('INSERT INTO jobs(id,user_id,kind,payload,status,created_at,updated_at) VALUES(?,?,?,?,?,?,?)',
                       ('job-1', uid, 'plan', '{}', 'running', 1, 1))
            db.execute('INSERT INTO push_deliveries(id,user_id,logical_key,payload,fire_at,status) VALUES(?,?,?,?,?,?)',
                       ('reminder-1', uid, 'one', '{}', 1, 'pending'))
        response = self.set_status(True, request_id='disable-exactly-once')
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.set_status(True, request_id='disable-exactly-once').status_code, 200)
        for session in (self.reader, other):
            self.assertEqual(self.client.get('/api/v1/auth/me', headers=self.headers(session)).status_code, 401)
        login = self.client.post('/api/v1/auth/login', json={'identifier': 'regular-reader', 'password': PASSWORD})
        self.assertEqual(login.status_code, 403, login.text)
        self.assertEqual(login.json()['code'], 'account_disabled')
        with self.accounts.connection() as db:
            for table in ('sessions', 'push_subscriptions', 'asr_tickets'):
                self.assertEqual(db.execute(f'SELECT count(*) FROM {table} WHERE user_id=?', (uid,)).fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT status FROM jobs WHERE id='job-1'").fetchone()[0], 'canceled')
            self.assertEqual(db.execute("SELECT status FROM push_deliveries WHERE id='reminder-1'").fetchone()[0], 'cancelled')
            self.assertEqual(db.execute('SELECT body FROM account_workspaces WHERE user_id=?', (uid,)).fetchone()[0], '{"preserved":true}')
            self.assertEqual(db.execute("SELECT count(*) FROM admin_audit WHERE action='disable_user'").fetchone()[0], 1)
        self.assertEqual(self.get('/users', status='disabled').json()['users'][0]['id'], uid)
        self.assertEqual(self.set_status(False).status_code, 200)
        self.assertEqual(self.client.get('/api/v1/auth/me', headers=self.headers(self.reader)).status_code, 401)
        login = self.client.post('/api/v1/auth/login', json={'identifier': 'regular-reader', 'password': PASSWORD})
        self.assertEqual(login.status_code, 200, login.text)
        self.assertEqual(self.get('/users', status='disabled').json()['total'], 0)

    def test_disabled_phone_login_and_direct_session_creation_cannot_bypass_restriction(self):
        uid = self.reader['user']['id']
        with self.accounts.connection() as db:
            db.execute('UPDATE users SET phone=? WHERE id=?', ('+8613800000001', uid))
            db.execute('CREATE TABLE isolated_proof(used INTEGER NOT NULL)')
            db.execute('INSERT INTO isolated_proof VALUES(0)')
        self.assertEqual(self.set_status(True).status_code, 200)
        def consume(db):
            db.execute('UPDATE isolated_proof SET used=1')
        with self.assertRaises(AuthError) as error:
            self.accounts.login_phone('+8613800000001', consume_proof=consume)
        self.assertEqual(error.exception.code, 'account_disabled')
        with self.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT used FROM isolated_proof').fetchone()[0], 0)
            user = db.execute('SELECT * FROM users WHERE id=?', (uid,)).fetchone()
            with self.assertRaises(AuthError):
                self.accounts._session(db, user)

    def test_disabled_session_is_rechecked_even_if_it_survived_a_separate_auth_check(self):
        uid = self.moderator['user']['id']
        self.grant(moderatePosts=True)
        with self.accounts.connection() as db:
            db.execute('INSERT INTO auth_account_status VALUES(?,?,?,?,?)', (uid, 1, 'isolated', 1, self.owner['user']['id']))
        with self.assertRaises(AuthError) as failure:
            self.community.create_post(uid, self.moderator['token'], {'requestId': 'late-write', 'content': '不得创建'})
        self.assertEqual(failure.exception.code, 'account_disabled')
        with self.assertRaises(AuthError):
            self.store.bootstrap(uid, self.moderator['token'])
        with self.accounts.connection() as db:
            with self.assertRaises(AuthError):
                self.accounts._session_user(db, self.moderator['token'])

    def test_owner_account_is_protected_and_regular_admin_cannot_change_status(self):
        self.assertEqual(self.set_status(True, target=self.owner['user']['id']).status_code, 403)
        self.grant(moderatePosts=True, moderateComments=True)
        response = self.client.put(ADMIN + '/users/' + self.reader['user']['id'] + '/status',
            headers=self.headers(self.moderator), json={'requestId': 'no-escalation', 'reason': '不可越权', 'disabled': True})
        self.assertEqual(response.status_code, 403)
        self.assertEqual(self.get('/users', status='disabled').json()['total'], 0)

    def test_mutations_validate_boolean_reason_unknown_fields_and_idempotency(self):
        self.assertEqual(self.set_status('true').status_code, 400)
        self.assertEqual(self.set_status(True, reason='').status_code, 400)
        self.assertEqual(self.set_status(True, reason='x' * 501).status_code, 400)
        self.assertEqual(self.set_status(True, target='not-present').status_code, 404)
        self.assertEqual(self.set_status(True, request_id='same-operation').status_code, 200)
        self.assertEqual(self.set_status(False, request_id='same-operation').status_code, 409)
        response = self.client.put(ADMIN + '/users/' + self.reader['user']['id'] + '/status', headers=self.headers(),
            json={'requestId': 'extra', 'reason': '原因', 'disabled': False, 'email': 'overwrite@example.test'})
        self.assertEqual(response.status_code, 400)

    def test_moderation_deletes_real_content_cascades_and_audits_once(self):
        post = self.publish()
        self.comment(post)
        self.client.put(COMMUNITY + '/posts/' + post['id'] + '/like', headers=self.headers(self.reader), json={'liked': True})
        self.grant(moderatePosts=True)
        response = self.delete_post(post, session=self.moderator, request_id='remove-once')
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.delete_post(post, session=self.moderator, request_id='remove-once').status_code, 200)
        self.assertEqual(self.client.get(COMMUNITY + '/posts/' + post['id']).status_code, 404)
        with self.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM community_comments WHERE post_id=?', (post['id'],)).fetchone()[0], 0)
            self.assertEqual(db.execute('SELECT count(*) FROM community_likes WHERE post_id=?', (post['id'],)).fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT count(*) FROM admin_audit WHERE action='delete_post'").fetchone()[0], 1)
            self.assertEqual(list(db.execute('PRAGMA foreign_key_check')), [])
        audit = self.get('/audit', q=post['id']).json()['entries'][0]
        self.assertEqual(audit['reason'], '清理测试内容')
        self.assertEqual(audit['actorName'], 'community-moderator')

    def test_post_and_comment_moderation_permissions_are_independent(self):
        post = self.publish()
        comment = self.comment(post)
        self.grant(moderateComments=True)
        self.assertEqual(self.delete_post(post, session=self.moderator).status_code, 403)
        response = self.client.request('DELETE', ADMIN + '/comments/' + comment['id'], headers=self.headers(self.moderator),
            json={'requestId': 'comment-remove', 'reason': '清理违规评论'})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.get('/comments', self.moderator, postId=post['id']).json()['comments'], [])
        self.assertEqual(self.client.get(COMMUNITY + '/posts/' + post['id']).json()['post']['commentCount'], 0)

    def test_delete_and_idempotency_claim_roll_back_if_audit_cannot_be_saved(self):
        post = self.publish()
        with patch.object(self.community, 'audit_handler', side_effect=sqlite3.OperationalError('isolated audit failure')):
            with self.assertRaises(sqlite3.OperationalError):
                self.delete_post(post, request_id='must-rollback')
        self.assertEqual(self.client.get(COMMUNITY + '/posts/' + post['id']).status_code, 200)
        with self.accounts.connection() as db:
            self.assertIsNone(db.execute("SELECT 1 FROM admin_operations WHERE request_id='must-rollback'").fetchone())
        self.assertEqual(self.delete_post(post, request_id='must-rollback').status_code, 200)

    def test_account_disable_rolls_back_revocation_when_audit_write_fails(self):
        with patch.object(self.store, 'record_audit', side_effect=sqlite3.OperationalError('isolated audit failure')):
            with self.assertRaises(sqlite3.OperationalError):
                self.set_status(True, request_id='status-rollback')
        self.assertEqual(self.client.get('/api/v1/auth/me', headers=self.headers(self.reader)).status_code, 200)
        self.assertEqual(self.get('/users', status='disabled').json()['total'], 0)
        self.assertEqual(self.set_status(True, request_id='status-rollback').status_code, 200)

    def test_official_publish_and_admin_management_are_audited_inside_existing_community_endpoints(self):
        official = self.publish(self.owner, title='官方说明', official=True)
        self.grant(publishOfficial=True)
        application = self.client.post(COMMUNITY + '/admin-applications', headers=self.headers(self.reader),
            json={'requestId': 'apply-reader', 'reason': '愿意协助社区'}).json()['application']
        reviewed = self.client.put(COMMUNITY + '/admin-applications/' + application['id'], headers=self.headers(),
            json={'status': 'approved', 'permissions': permissions(moderateComments=True)})
        self.assertEqual(reviewed.status_code, 200, reviewed.text)
        entries = self.get('/audit').json()['entries']
        self.assertEqual([entry['action'] for entry in entries], ['approve_application', 'grant_admin', 'publish_official'])
        self.assertEqual(entries[-1]['targetId'], official['id'])
        # Replaying the confirmed application does not log or grant again.
        self.client.put(COMMUNITY + '/admin-applications/' + application['id'], headers=self.headers(),
            json={'status': 'approved', 'permissions': permissions(moderateComments=True)})
        self.assertEqual(self.get('/audit').json()['total'], 3)

    def test_existing_mobile_delete_uses_the_same_transactional_audit(self):
        post = self.publish()
        self.assertEqual(self.client.delete(COMMUNITY + '/posts/' + post['id'], headers=self.headers()).status_code, 200)
        entry = self.get('/audit').json()['entries'][0]
        self.assertEqual(entry['action'], 'delete_post')
        self.assertEqual(entry['targetId'], post['id'])

    def test_cookie_admin_mutations_require_current_csrf_and_ignore_spoofed_role_headers(self):
        post = self.publish()
        login = self.client.post('/api/v1/auth/login', headers={'X-Sera-Client': 'web'},
            json={'identifier': 'official-owner', 'password': PASSWORD})
        self.assertEqual(login.status_code, 200, login.text)
        csrf = login.json()['csrfToken']
        payload = {'requestId': 'csrf-protected', 'reason': '确认删除测试记录'}
        for headers in ({}, {'X-CSRF-Token': 'stale'}, {'X-Admin-Role': 'official'}):
            denied = self.client.request('DELETE', ADMIN + '/posts/' + post['id'], json=payload, headers=headers)
            self.assertIn(denied.status_code, (401, 403))
        result = self.client.request('DELETE', ADMIN + '/posts/' + post['id'], json=payload,
            headers={'X-CSRF-Token': csrf})
        self.assertEqual(result.status_code, 200, result.text)
        self.assertEqual(self.client.get(ADMIN + '/bootstrap', headers={'X-CSRF-Token': 'old-account'}).status_code, 401)

    def test_status_is_owner_only_sanitised_configuration_and_does_not_call_providers(self):
        self.grant(moderatePosts=True)
        self.assertEqual(self.get('/status', self.moderator).status_code, 403)
        with self.accounts.connection() as db:
            db.execute('INSERT INTO service_heartbeats VALUES(?,?,?)', ('worker', int(time.time()), 'ok'))
        with patch('urllib.request.urlopen', side_effect=AssertionError('Must not connect to providers')):
            response = self.get('/status')
        self.assertEqual(response.status_code, 200, response.text)
        components = {component['id']: component for component in response.json()['components']}
        self.assertEqual(components['database']['status'], 'healthy')
        self.assertEqual(components['worker']['status'], 'healthy')
        self.assertEqual(components['ai']['status'], 'not_configured')
        self.assertIsNone(components['mail']['healthy'])
        self.assertNotIn(str(self.path), response.text)
        self.assertNotIn(self.owner['token'], response.text)

    def test_existing_database_reopen_keeps_user_schema_foreign_keys_and_data(self):
        post = self.publish()
        comment = self.comment(post)
        with self.accounts.connection() as db:
            before = [tuple(row) for row in db.execute('PRAGMA table_info(users)')]
            user = tuple(db.execute('SELECT * FROM users WHERE id=?', (self.reader['user']['id'],)).fetchone())
        reopened = AuthStore(self.path)
        from admin_store import AdminStore
        AdminStore(CommunityStore(reopened, official_user_ids=[self.owner['user']['id']]))
        with reopened.connection() as db:
            self.assertEqual([tuple(row) for row in db.execute('PRAGMA table_info(users)')], before)
            self.assertEqual(tuple(db.execute('SELECT * FROM users WHERE id=?', (self.reader['user']['id'],)).fetchone()), user)
            self.assertIsNotNone(db.execute('SELECT 1 FROM community_comments WHERE id=?', (comment['id'],)).fetchone())
            self.assertEqual(list(db.execute('PRAGMA foreign_key_check')), [])
        self.assertEqual(reopened.authenticate(self.reader['token'])['user']['id'], self.reader['user']['id'])

    def test_legacy_email_identity_migration_preserves_admin_status_and_audit_foreign_keys(self):
        # Exercise the historical users rebuild as well as reopening a v2 DB.
        from test_phone_identity import IdentityMigrationTests
        from admin_store import AdminStore
        legacy_path = Path(self.temp.name) / 'legacy.sqlite3'
        IdentityMigrationTests().legacy(legacy_path)
        with closing(sqlite3.connect(legacy_path)) as db, db:
            db.executescript('''
                CREATE TABLE auth_account_status (
                    user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
                    disabled INTEGER NOT NULL CHECK(disabled IN (0,1)),
                    reason TEXT NOT NULL, updated_at INTEGER NOT NULL,
                    updated_by TEXT REFERENCES users(id) ON DELETE SET NULL);
                INSERT INTO auth_account_status VALUES('old-id',1,'preserved status',1234,'old-id');
                CREATE TABLE admin_audit (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,
                    actor_id TEXT REFERENCES users(id) ON DELETE SET NULL,
                    actor_name TEXT NOT NULL,action TEXT NOT NULL,target_type TEXT NOT NULL,
                    target_id TEXT NOT NULL,target_label TEXT NOT NULL,reason TEXT NOT NULL,created_at INTEGER NOT NULL);
                INSERT INTO admin_audit VALUES(1,'legacy-audit','old-id','OldUser','disable_user','user','old-id','OldUser','preserved',1234000000);
            ''')
        migrated = AuthStore(legacy_path)
        AdminStore(CommunityStore(migrated, official_user_ids=['old-id']))
        with migrated.connection() as db:
            self.assertEqual(db.execute('SELECT disabled,reason FROM auth_account_status').fetchone()['reason'], 'preserved status')
            self.assertEqual(db.execute('SELECT actor_id FROM admin_audit').fetchone()['actor_id'], 'old-id')
            self.assertIsNotNone(db.execute("SELECT 1 FROM account_workspaces WHERE user_id='old-id'").fetchone())
            self.assertEqual(list(db.execute('PRAGMA foreign_key_check')), [])
        with self.assertRaises(AuthError) as failure:
            migrated.authenticate('legacy-token')
        self.assertEqual(failure.exception.code, 'account_disabled')

    def test_openapi_admin_contract_has_actual_routes_security_and_matching_dto_fields(self):
        document = self.app.openapi()
        schemas = document['components']['schemas']
        expected = {('/bootstrap', 'get'): 'AdminBootstrap', ('/posts', 'get'): 'AdminPosts',
            ('/comments', 'get'): 'AdminComments', ('/users', 'get'): 'AdminUsers',
            ('/users/{user_id}/status', 'put'): 'CommunityUpdated',
            ('/posts/{post_id}', 'delete'): 'CommunityDeleted',
            ('/comments/{comment_id}', 'delete'): 'CommunityDeleted',
            ('/audit', 'get'): 'AdminAudit', ('/status', 'get'): 'AdminStatus',
            ('/analytics', 'get'): 'AdminAnalytics'}
        actual = {(route.path[len(ADMIN):], method.lower()) for route in self.app.routes
                  if route.path.startswith(ADMIN) for method in getattr(route, 'methods', [])}
        self.assertEqual(actual, set(expected))
        for (path, method), result_schema in expected.items():
            operation = document['paths'][ADMIN + path][method]
            self.assertEqual(operation['security'], [{'BearerAuth': []}, {'CookieAuth': []}])
            self.assertEqual(operation['responses']['200']['content']['application/json']['schema']['$ref'],
                             '#/components/schemas/' + result_schema)
            self.assertEqual(operation['responses']['200']['headers']['Cache-Control']['schema']['const'], 'no-store')
        post = self.publish()
        self.comment(post)
        for suffix, result_schema, item_field, item_schema in (
            ('/posts', 'AdminPosts', 'posts', 'CommunityPost'),
            ('/comments', 'AdminComments', 'comments', 'AdminComment'),
            ('/users', 'AdminUsers', 'users', 'AdminUser')):
            result = self.get(suffix).json()
            self.assertEqual(set(result), set(schemas[result_schema]['properties']))
            self.assertEqual(set(result[item_field][0]), set(schemas[item_schema]['properties']))
        self.assertEqual(set(self.get('/bootstrap').json()), set(schemas['AdminBootstrap']['properties']))
        request_schema = schemas['AdminAccountStatus']
        self.assertEqual(set(request_schema['required']), {'disabled', 'requestId', 'reason'})
        self.assertFalse(request_schema['additionalProperties'])


if __name__ == '__main__':
    unittest.main()
