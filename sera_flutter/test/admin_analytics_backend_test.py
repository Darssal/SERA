"""Existing-row analytics contracts with real SQL and isolated HTTP sessions."""
import calendar
from contextlib import closing
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import secrets
import sqlite3
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))

from fastapi.testclient import TestClient

import admin_analytics
from app import create_app
from auth_store import AuthStore


NOW = datetime.fromisoformat('2026-11-09T04:30:00.123456+00:00')
PASSWORD = 'IsolatedAnalyticsPassword123'
PATH = '/api/v1/admin/analytics'


def instant(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def micros(value):
    value = instant(value) if isinstance(value, str) else value
    value = value.astimezone(timezone.utc)
    return calendar.timegm(value.timetuple()) * 1_000_000 + value.microsecond


class AdminAnalyticsBackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'analytics.sqlite3'
        self.accounts = AuthStore(self.path)
        self.owner, self.reader, self.moderator = [self.accounts.register({
            'username': name, 'email': name + '@example.test', 'password': PASSWORD,
        }) for name in ('analytics-official', 'analytics-reader', 'analytics-moderator')]
        environment = patch.dict(os.environ, {
            'SERA_COMMUNITY_OFFICIAL_USER_IDS': self.owner['user']['id'],
            'SERA_MAIL_MODE': 'local', 'SERA_PUBLIC_ORIGIN': 'https://sera.example.test',
        })
        environment.start()
        self.addCleanup(environment.stop)
        inert = SimpleNamespace(configured=False, model='isolated-no-network')
        self.app = create_app(db_path=self.path, ai_service=inert, transcriber=inert,
                              sms_service=SimpleNamespace(capabilities=lambda: {'enabled': False}))
        self.accounts = self.app.state.accounts
        self.client = TestClient(self.app)
        self.client.__enter__()
        self.addCleanup(lambda: self.client.__exit__(None, None, None))
        clock = patch.object(admin_analytics, 'now_utc', return_value=NOW)
        clock.start()
        self.addCleanup(clock.stop)
        with self.accounts.connection() as db:
            db.execute('PRAGMA journal_mode=WAL')
            db.execute('DELETE FROM community_posts')
            db.execute('UPDATE users SET created_at=1')
            db.execute('''INSERT INTO community_admins VALUES(?,?,?,?,?,?)''',
                (self.moderator['user']['id'], 1, 1, 1, 1, 1))

    def headers(self, session=None):
        return {'Authorization': 'Bearer ' + (session or self.owner)['token']}

    def get(self, days=7, session=None):
        response = self.client.get(PATH, headers=self.headers(session), params={'days': days})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.headers['cache-control'], 'no-store')
        return response.json()

    def post(self, at='2026-11-08T08:00:00Z', *, author=None, kind='post', category='daily', system=False, title='真实测试记录'):
        pid = secrets.token_hex(16)
        author_id = None if system else (author or self.reader)['user']['id']
        with self.accounts.connection() as db:
            db.execute('''INSERT INTO community_posts
                (id,author_id,is_official,kind,category,title,content,created_at,starts_at,place)
                VALUES(?,?,?,?,?,?,?,?,?,?)''',
                (pid, author_id, int(system or kind == 'activity'), kind, category, title, '仅隔离库中的测试正文',
                 micros(at), '2026-11-10T10:00:00Z' if kind == 'activity' else None, ''))
        return pid

    def comment(self, pid, at='2026-11-08T08:00:00Z', *, author=None):
        cid = secrets.token_hex(16)
        with self.accounts.connection() as db:
            db.execute('INSERT INTO community_comments(id,post_id,author_id,is_official,content,created_at) VALUES(?,?,?,?,?,?)',
                       (cid, pid, (author or self.reader)['user']['id'], 0, '实际评论', micros(at)))
        return cid

    def like(self, pid, session=None):
        with self.accounts.connection() as db:
            db.execute('INSERT INTO community_likes VALUES(?,?)', (pid, (session or self.reader)['user']['id']))

    def join(self, pid, session=None):
        with self.accounts.connection() as db:
            db.execute('INSERT INTO community_participants VALUES(?,?)', (pid, (session or self.reader)['user']['id']))

    def user_time(self, session, at):
        with self.accounts.connection() as db:
            db.execute('UPDATE users SET created_at=? WHERE id=?', (micros(at) // 1_000_000, session['user']['id']))

    def test_only_real_official_owner_can_read_even_fully_privileged_admin_is_denied(self):
        self.assertEqual(self.client.get(PATH).status_code, 401)
        for session in (self.reader, self.moderator):
            response = self.client.get(PATH, headers=self.headers(session))
            self.assertEqual(response.status_code, 403, response.text)
            self.assertEqual(response.json()['code'], 'admin_owner_required' if session is self.moderator else 'admin_required')
        self.assertEqual(self.get()['timeZone'], 'Asia/Hong_Kong')

    def test_days_defaults_and_exact_allowed_values_are_validated(self):
        default = self.client.get(PATH, headers=self.headers())
        self.assertEqual(default.status_code, 200)
        self.assertEqual(default.json()['days'], 30)
        for days in (7, 30, 90):
            result = self.get(days)
            self.assertEqual(result['days'], days)
            self.assertEqual(len(result['daily']), days)
        for value in ('', '0', '1', '6', '8', '31', '91', '-7', '7.0', '007', 'true', 'x' * 513):
            response = self.client.get(PATH, headers=self.headers(), params={'days': value})
            self.assertEqual(response.status_code, 400, (value, response.text))

    def test_periods_align_previous_end_to_same_instant_of_day(self):
        result = self.get(7)
        self.assertEqual(result['period'], {'startDate': '2026-11-03', 'endDate': '2026-11-09',
                                          'endAt': '2026-11-09T04:30:00.123456Z'})
        self.assertEqual(result['previousPeriod'], {'startDate': '2026-10-27', 'endDate': '2026-11-02',
                                                  'endAt': '2026-11-02T04:30:00.123456Z'})
        self.assertEqual(result['generatedAt'], result['period']['endAt'])
        # This noon record is later than the previous cut-off, so it must not
        # make the previous period appear to include a complete extra day.
        self.post('2026-11-02T05:00:00Z')
        self.post('2026-11-02T04:30:00.123456Z')
        self.assertEqual(self.get()['summary']['posts']['previous'], 1)

    def test_hong_kong_midnight_inclusion_microsecond_edges_and_future_filter(self):
        before = self.post('2026-11-02T15:59:59.999999Z')
        start = self.post('2026-11-02T16:00:00Z')
        end = self.post(NOW)
        future = self.post(NOW + timedelta(microseconds=1))
        self.like(start)
        self.like(end)
        self.like(before)
        self.like(future)
        result = self.get()
        self.assertEqual(result['summary']['posts']['value'], 2)
        self.assertEqual(result['daily'][0]['date'], '2026-11-03')
        self.assertEqual(result['daily'][0]['posts'], 1)
        self.assertEqual(result['daily'][-1]['posts'], 1)
        self.assertEqual({item['post']['id'] for item in result['topPosts']}, {start, end})
        # Existing likes remain sitewide current totals, including older posts.
        self.assertEqual(result['currentInteractions']['likes'], 4)

    def test_seconds_for_users_and_microseconds_for_content_share_same_local_day(self):
        self.user_time(self.owner, '2026-11-02T15:59:59Z')
        self.user_time(self.reader, '2026-11-02T16:00:00Z')
        self.user_time(self.moderator, '2026-11-09T04:30:01Z')
        self.post('2026-11-02T16:00:00Z')
        result = self.get()
        self.assertEqual(result['summary']['newUsers']['value'], 1)
        self.assertEqual(result['daily'][0]['newUsers'], 1)
        self.assertEqual(result['daily'][0]['posts'], 1)
        self.assertEqual(sum(row['newUsers'] for row in result['daily']), 1)

    def test_contributors_are_unique_across_posts_comments_and_days_not_daily_sum(self):
        first = self.post('2026-11-03T01:00:00Z', author=self.reader)
        self.post('2026-11-04T01:00:00Z', author=self.reader)
        self.comment(first, '2026-11-03T02:00:00Z', author=self.reader)
        self.comment(first, '2026-11-04T02:00:00Z', author=self.owner)
        self.post('2026-11-05T02:00:00Z', system=True)
        self.like(first, self.moderator)
        result = self.get()
        self.assertEqual(result['summary']['contributors']['value'], 2)
        self.assertEqual([row['contributors'] for row in result['daily']], [1, 2, 0, 0, 0, 0, 0])
        self.assertEqual(sum(row['contributors'] for row in result['daily']), 3)
        self.assertEqual(result['summary']['posts']['value'], 3)

    def test_comment_author_on_old_post_counts_in_period_without_counting_old_post(self):
        old = self.post('2026-10-01T01:00:00Z')
        self.comment(old, '2026-11-08T01:00:00Z', author=self.moderator)
        result = self.get()
        self.assertEqual(result['summary']['posts']['value'], 0)
        self.assertEqual(result['summary']['comments']['value'], 1)
        self.assertEqual(result['summary']['contributors']['value'], 1)
        self.assertEqual(result['topPosts'], [])

    def test_previous_distinct_counts_and_partial_last_day_are_independent(self):
        old = self.post('2026-10-27T00:00:00Z', author=self.reader)
        self.comment(old, '2026-11-02T04:30:00.123456Z', author=self.owner)
        self.comment(old, '2026-11-02T04:30:00.123457Z', author=self.moderator)
        self.post('2026-11-03T00:00:00Z', author=self.reader)
        result = self.get()
        self.assertEqual(result['summary']['posts'], {'value': 1, 'previous': 1})
        self.assertEqual(result['summary']['comments'], {'value': 0, 'previous': 1})
        self.assertEqual(result['summary']['contributors'], {'value': 1, 'previous': 2})

    def test_daily_zero_filling_and_all_count_reconciliations(self):
        daily = self.post('2026-11-03T04:00:00Z')
        self.post('2026-11-05T04:00:00Z', category='feedback')
        self.post('2026-11-06T04:00:00Z', kind='activity', author=self.owner)
        self.comment(daily, '2026-11-05T05:00:00Z')
        self.user_time(self.reader, '2026-11-05T06:00:00Z')
        result = self.get()
        self.assertEqual([row['date'] for row in result['daily']], [f'2026-11-{day:02}' for day in range(3, 10)])
        self.assertEqual(result['daily'][1], {'date': '2026-11-04', 'newUsers': 0, 'contributors': 0, 'posts': 0, 'comments': 0})
        for field in ('newUsers', 'posts', 'comments'):
            self.assertEqual(sum(day[field] for day in result['daily']), result['summary'][field]['value'])
        types = {entry['key']: entry['count'] for entry in result['contentTypes']}
        self.assertEqual(types, {'daily': 1, 'feedback': 1, 'activity': 1})
        self.assertEqual(sum(types.values()), result['summary']['posts']['value'])

    def test_empty_snapshot_has_zero_summaries_types_and_no_manufactured_ranking(self):
        result = self.get(30)
        self.assertTrue(all(value == {'value': 0, 'previous': 0} for value in result['summary'].values()))
        self.assertEqual(result['topPosts'], [])
        self.assertEqual(result['currentInteractions'], {'likes': 0, 'participants': 0})
        self.assertTrue(all(entry['count'] == 0 for entry in result['contentTypes']))
        self.assertEqual(len(result['daily']), 30)
        self.post()
        self.assertEqual(self.get()['topPosts'], [])

    def test_ranking_uses_current_counts_without_join_multiplication(self):
        pid = self.post(kind='activity', author=self.owner)
        for session in (self.owner, self.reader):
            self.like(pid, session)
            self.join(pid, session)
        for _ in range(3):
            self.comment(pid)
        old = self.post('2026-10-01T00:00:00Z', kind='activity')
        self.like(old)
        self.join(old)
        result = self.get()
        self.assertEqual(result['currentInteractions'], {'likes': 3, 'participants': 3})
        item = result['topPosts'][0]
        self.assertEqual(item['interactions'], 7)
        self.assertEqual(item['post']['likeCount'], 2)
        self.assertEqual(item['post']['commentCount'], 3)
        self.assertEqual(item['post']['participantCount'], 2)
        self.assertEqual(item['post']['id'], pid)
        self.assertEqual(len(result['topPosts']), 1)
        self.assertEqual(self.get(90)['currentInteractions'], result['currentInteractions'])

    def test_ranking_maximum_five_and_equal_scores_use_newest_sequence_first(self):
        ids = [self.post() for _ in range(7)]
        for pid in ids:
            self.like(pid)
        self.comment(ids[0])
        result = self.get()
        self.assertEqual([item['post']['id'] for item in result['topPosts']], [ids[0], *reversed(ids[-4:])])
        self.assertEqual([item['interactions'] for item in result['topPosts']], [2, 1, 1, 1, 1])

    def test_current_totals_reflect_deletion_unlike_and_cancel_instead_of_invented_history(self):
        pid = self.post(kind='activity')
        self.like(pid)
        self.join(pid)
        cid = self.comment(pid)
        before = self.get()
        self.assertEqual(before['topPosts'][0]['interactions'], 3)
        with self.accounts.connection() as db:
            db.execute('DELETE FROM community_participants WHERE post_id=?', (pid,))
            db.execute('DELETE FROM community_likes WHERE post_id=?', (pid,))
            db.execute('DELETE FROM community_comments WHERE id=?', (cid,))
        after = self.get()
        self.assertEqual(after['currentInteractions'], {'likes': 0, 'participants': 0})
        self.assertEqual(after['topPosts'], [])
        self.assertEqual(after['summary']['comments']['value'], 0)
        with self.accounts.connection() as db:
            db.execute('DELETE FROM community_posts WHERE id=?', (pid,))
        self.assertEqual(self.get()['summary']['posts']['value'], 0)

    def test_all_aggregates_and_top_dto_share_one_snapshot_during_concurrent_write(self):
        original = admin_analytics._contributors
        changed = False
        new_id = secrets.token_hex(16)
        def during_read(db, start, end):
            nonlocal changed
            value = original(db, start, end)
            if not changed:
                changed = True
                with closing(sqlite3.connect(self.path)) as writer, writer:
                    writer.execute('''INSERT INTO community_posts
                        (id,author_id,is_official,kind,category,title,content,created_at)
                        VALUES(?,?,0,'post','daily','并发写入','下一快照才出现',?)''',
                        (new_id, self.reader['user']['id'], micros(NOW)))
                    writer.execute('INSERT INTO community_likes VALUES(?,?)', (new_id, self.reader['user']['id']))
            return value
        with patch.object(admin_analytics, '_contributors', side_effect=during_read):
            result = self.get()
        self.assertTrue(changed)
        self.assertEqual(result['summary']['posts']['value'], 0)
        self.assertEqual(sum(entry['count'] for entry in result['contentTypes']), 0)
        self.assertEqual(result['currentInteractions']['likes'], 0)
        self.assertEqual(result['topPosts'], [])
        next_result = self.get()
        self.assertEqual(next_result['summary']['posts']['value'], 1)
        self.assertEqual(next_result['topPosts'][0]['post']['id'], new_id)

    def test_fixed_timezone_does_not_follow_server_local_date(self):
        with patch.object(admin_analytics, 'now_utc', return_value=instant('2026-11-08T16:01:00Z')):
            self.post('2026-11-08T16:00:00Z')
            result = self.get()
        self.assertEqual(result['period']['endDate'], '2026-11-09')
        self.assertEqual(result['daily'][-1]['date'], '2026-11-09')
        self.assertEqual(result['daily'][-1]['posts'], 1)

    def test_cookie_reads_reject_stale_account_csrf_and_expired_sessions(self):
        login = self.client.post('/api/v1/auth/login', headers={'X-Sera-Client': 'web'},
            json={'identifier': self.owner['user']['username'], 'password': PASSWORD})
        self.assertEqual(login.status_code, 200, login.text)
        csrf = login.json()['csrfToken']
        self.assertEqual(self.client.get(PATH, headers={'X-CSRF-Token': csrf}).status_code, 200)
        self.assertEqual(self.client.get(PATH, headers={'X-CSRF-Token': 'old-account'}).status_code, 401)
        self.accounts.logout(self.owner['token'])
        self.assertEqual(self.client.get(PATH, headers=self.headers()).status_code, 401)

    def test_read_does_not_change_schema_or_private_records_or_expose_identity(self):
        private_marker = 'private-workspace-secret-no-analytics'
        with self.accounts.connection() as db:
            db.execute('INSERT INTO account_workspaces VALUES(?,?,?)', (self.reader['user']['id'], 8, private_marker))
            schema = [tuple(row) for row in db.execute('SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name')]
            private_row = tuple(db.execute('SELECT * FROM account_workspaces').fetchone())
        queries = []
        connection = self.accounts.connection
        from contextlib import contextmanager
        @contextmanager
        def traced():
            with connection() as db:
                db.set_trace_callback(queries.append)
                yield db
        with patch.object(self.accounts, 'connection', side_effect=traced):
            result = self.app.state.admin.analytics(self.owner['user']['id'], self.owner['token'], days=7)
        encoded = json.dumps(result)
        for secret in (private_marker, self.reader['user']['email'], self.owner['token'], str(self.path)):
            self.assertNotIn(secret, encoded)
        self.assertTrue(queries)
        self.assertFalse(any('account_workspaces' in query.lower() for query in queries))
        with self.accounts.connection() as db:
            self.assertEqual([tuple(row) for row in db.execute('SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name')], schema)
            self.assertEqual(tuple(db.execute('SELECT * FROM account_workspaces').fetchone()), private_row)
            self.assertEqual(list(db.execute('PRAGMA foreign_key_check')), [])

    def test_openapi_documents_actual_dto_security_and_bounded_days(self):
        document = self.app.openapi()
        operation = document['paths'][PATH]['get']
        self.assertEqual(operation['security'], [{'BearerAuth': []}, {'CookieAuth': []}])
        self.assertEqual(operation['responses']['200']['content']['application/json']['schema']['$ref'], '#/components/schemas/AdminAnalytics')
        days = next(parameter for parameter in operation['parameters'] if parameter['name'] == 'days')
        self.assertEqual(days['schema']['enum'], [7, 30, 90])
        self.assertEqual(days['schema']['default'], 30)
        result = self.get()
        schemas = document['components']['schemas']
        self.assertEqual(set(result), set(schemas['AdminAnalytics']['properties']))
        self.assertEqual(set(result['daily'][0]), set(schemas['AdminAnalyticsDay']['properties']))
        self.assertEqual(set(result['period']), set(schemas['AdminAnalyticsPeriod']['properties']))
        self.assertEqual(set(result['summary']['posts']), set(schemas['AdminAnalyticsMetric']['properties']))
        self.assertNotIn('requestBody', operation)


if __name__ == '__main__':
    unittest.main()
