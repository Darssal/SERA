"""Isolated HTTP tests: fake provider only; no network, real users or SMS sends."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import secrets
from types import SimpleNamespace
import tempfile
import time
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from fastapi.testclient import TestClient

from app import create_app
from auth_store import AuthStore, AuthError
from test_app import StubAi
from test_server import empty_workspace


class IsolatedSms:
    """Deliberately test-local provider with SQL once-only claim consumption."""
    def __init__(self, path):
        self.path, self.challenges, self.sends, self.checks = path, {}, 0, 0
        self.store = self

    def capabilities(self):
        return {'enabled': True, 'message': 'isolated test only', 'codeLength': 6, 'cooldownSeconds': 60}

    def send(self, phone, *, purpose='login', source_ip=None, owner_uid=None, session_token=None):
        phone = AuthStore.phone(phone)
        self.sends += 1
        cid = secrets.token_urlsafe(24)
        claim = SimpleNamespace(id=cid, phone=phone, purpose=purpose, uid=owner_uid, session=session_token)
        self.challenges[cid] = claim
        with AuthStore(self.path).connection() as db:
            db.execute('CREATE TABLE IF NOT EXISTS isolated_sms_claims(id TEXT PRIMARY KEY,used INTEGER DEFAULT 0)')
            db.execute('INSERT INTO isolated_sms_claims(id) VALUES(?)', (cid,))
        now = datetime.now(timezone.utc).isoformat()
        return {'challengeId': cid, 'maskedPhone': '+86 138****0000', 'expiresAt': now,
                'resendAt': now, 'message': 'test fake', 'deliveryStatus': 'submitted'}

    def _claim(self, cid, purpose, owner_uid, session_token):
        claim = self.challenges.get(cid)
        if not claim or (claim.purpose, claim.uid, claim.session) != (purpose, owner_uid, session_token):
            raise AuthError('挑战无效。', 400, 'sms_challenge_invalid')
        return claim

    def challenge_phone(self, cid, *, purpose='login', owner_uid=None, session_token=None):
        return self._claim(cid, purpose, owner_uid, session_token).phone

    def verify(self, cid, code, *, purpose='login', owner_uid=None, session_token=None):
        self.checks += 1
        claim = self._claim(cid, purpose, owner_uid, session_token)
        if code != '123456':
            raise AuthError('验证码不正确。', 400, 'sms_code_invalid')
        return claim

    def consume_claim(self, db, claim):
        if db.execute('UPDATE isolated_sms_claims SET used=1 WHERE id=? AND used=0', (claim.id,)).rowcount != 1:
            raise AuthError('挑战已使用。', 400, 'sms_challenge_used')


class PhoneRoutesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {'SERA_MAIL_MODE': 'local', 'SERA_PUBLIC_ORIGIN': 'https://sera.example.test'})
        self.env.start()
        self.path = Path(self.temp.name) / 'phone.db'
        self.sms = IsolatedSms(self.path)
        self.app = create_app(db_path=self.path, ai_service=StubAi(), sms_service=self.sms)
        self.client = TestClient(self.app)
        self.client.__enter__()

    def tearDown(self):
        self.client.__exit__(None, None, None)
        self.env.stop()
        self.temp.cleanup()

    def register_email(self, name='email-user'):
        r = self.client.post('/api/v1/auth/register', json={'username': name,
            'email': name + '@example.test', 'password': 'CorrectPassword123'})
        self.assertEqual(r.status_code, 201, r.text)
        return r.json()

    @staticmethod
    def headers(session):
        return {'Authorization': 'Bearer ' + session['token']}

    def send(self, phone='13800000000', purpose='login', session=None, **extra):
        r = self.client.post('/api/v1/auth/phone/challenge', headers=self.headers(session) if session else {},
                             json={'phone': phone, 'purpose': purpose, **extra})
        self.assertEqual(r.status_code, 200, r.text)
        return r.json()['challengeId']

    def login_phone(self, phone='13800000000', **headers):
        cid = self.send(phone)
        r = self.client.post('/api/v1/auth/phone/login', headers=headers, json={
            'challengeId': cid, 'code': '123456', 'acceptRegistration': True})
        self.assertEqual(r.status_code, 200, r.text)
        return r.json()

    def proof(self, session):
        cid = self.send(session['user']['phone'], 'sensitive', session)
        r = self.client.post('/api/v1/auth/phone/verify-sensitive', headers=self.headers(session),
                             json={'challengeId': cid, 'code': '123456'})
        self.assertEqual(r.status_code, 200, r.text)
        return r.json()['phoneProof']

    def test_consent_before_provider_check_and_real_identity_without_fake_email(self):
        cid = self.send()
        r = self.client.post('/api/v1/auth/phone/login', json={'challengeId': cid,
            'code': '123456', 'acceptRegistration': False})
        self.assertEqual(r.status_code, 409)
        self.assertEqual(self.sms.checks, 0)
        r = self.client.post('/api/v1/auth/phone/login', json={'challengeId': cid,
            'code': '123456', 'acceptRegistration': True})
        self.assertEqual(r.status_code, 200, r.text)
        session = r.json()
        self.assertIsNone(session['user']['email'])
        self.assertFalse(session['user']['hasPassword'])
        self.assertEqual(session['user']['phone'], '+8613800000000')
        self.assertTrue(session['created'])
        replay = self.client.post('/api/v1/auth/phone/login', json={'challengeId': cid,
            'code': '123456', 'acceptRegistration': True})
        self.assertEqual(replay.status_code, 400)
        with self.app.state.accounts.connection() as db:
            user = db.execute('SELECT * FROM users').fetchone()
            self.assertIsNone(user['salt'])
            self.assertIsNone(user['password_hash'])

    def test_cookie_session_csrf_stale_cookie_login_and_origin_checks(self):
        a = self.login_phone(**{'X-Sera-Client': 'web'})
        self.assertEqual(a['token'], '')
        self.assertTrue(a['cookieSession'])
        csrf = a['csrfToken']
        self.assertEqual(self.client.post('/api/v1/auth/phone/challenge', json={
            'phone': a['user']['phone'], 'purpose': 'sensitive'}).status_code, 403)
        blocked = self.client.post('/api/v1/auth/phone/challenge', headers={'Origin': 'https://evil.example'},
                                  json={'phone': '13900000000'})
        self.assertEqual(blocked.status_code, 403)
        self.assertEqual(self.sms.sends, 1)
        self.assertEqual(self.client.post('/api/v1/auth/logout', headers={'X-CSRF-Token': csrf}, json={}).status_code, 200)
        # Browser keeps revoked cookie by design; an anonymous SMS login works.
        cid = self.send('13900000000')
        r = self.client.post('/api/v1/auth/phone/login', headers={'X-Sera-Client': 'web'},
                             json={'challengeId': cid, 'code': '123456', 'acceptRegistration': True})
        self.assertEqual(r.status_code, 200, r.text)
        self.assertIn('HttpOnly', r.headers['set-cookie'])
        self.assertNotIn('123456', r.text)

    def test_email_account_phone_binding_identity_and_unique_no_merge(self):
        email = self.register_email()
        password_wrong = self.client.post('/api/v1/auth/phone/challenge', headers=self.headers(email),
            json={'phone': '13800000000', 'purpose': 'bind_phone', 'currentPassword': 'wrong'})
        self.assertEqual(password_wrong.status_code, 401)
        self.assertEqual(self.sms.sends, 0)
        cid = self.send('13800000000', 'bind_phone', email, currentPassword='CorrectPassword123')
        r = self.client.post('/api/v1/auth/phone/bind', headers=self.headers(email), json={
            'challengeId': cid, 'code': '123456', 'currentPassword': 'CorrectPassword123'})
        self.assertEqual(r.status_code, 200, r.text)
        phone = self.login_phone()
        self.assertEqual(phone['user']['id'], email['user']['id'])
        self.assertFalse(phone['created'])
        other = self.register_email('other-email')
        conflict = self.client.post('/api/v1/auth/phone/challenge', headers=self.headers(other), json={
            'phone': '13800000000', 'purpose': 'bind_phone', 'currentPassword': 'CorrectPassword123'})
        self.assertEqual(conflict.status_code, 409)
        self.assertEqual(self.client.get('/api/v1/auth/me', headers=self.headers(other)).json()['user']['phone'], None)

    def test_proofs_bound_to_session_account_phone_and_one_use_for_password_setting(self):
        a = self.login_phone()
        b = self.login_phone('13900000000')
        proof = self.proof(a)
        r = self.client.post('/api/v1/auth/password/set', headers=self.headers(b),
            json={'password': 'NewPassword123', 'phoneProof': proof})
        self.assertEqual(r.status_code, 401)
        second_session = self.login_phone()
        self.assertEqual(second_session['user']['id'], a['user']['id'])
        r = self.client.post('/api/v1/auth/password/set', headers=self.headers(second_session),
            json={'password': 'NewPassword123', 'phoneProof': proof})
        self.assertEqual(r.status_code, 401)
        r = self.client.post('/api/v1/auth/password/set', headers=self.headers(a),
            json={'password': 'NewPassword123', 'phoneProof': proof})
        self.assertEqual(r.status_code, 200, r.text)
        self.assertTrue(self.client.get('/api/v1/auth/me', headers=self.headers(a)).json()['user']['hasPassword'])
        self.assertEqual(self.client.get('/api/v1/auth/me', headers=self.headers(second_session)).status_code, 401)
        replay = self.client.post('/api/v1/auth/password/set', headers=self.headers(a),
            json={'password': 'OtherPassword123', 'phoneProof': proof})
        self.assertEqual(replay.status_code, 401)

    def test_email_binding_requires_target_link_same_session_and_preserves_workspace(self):
        a = self.login_phone()
        workspace = self.client.put('/api/v1/workspace', headers=self.headers(a),
            json={'workspace': empty_workspace(), 'expectedRevision': 0}).json()['workspace']
        r = self.client.post('/api/v1/auth/email/bind/request', headers=self.headers(a),
            json={'email': 'new-binding@example.test', 'phoneProof': self.proof(a)})
        self.assertEqual(r.status_code, 200, r.text)
        self.assertIsNone(self.client.get('/api/v1/auth/me', headers=self.headers(a)).json()['user']['email'])
        mail = json.loads(next((Path(self.temp.name) / 'mail').glob('*.json')).read_text(encoding='utf-8'))
        self.assertEqual(mail['kind'], 'bind')
        self.assertIn('/#/phone-email?', mail['link'])
        action_token = parse_qs(urlsplit(mail['link']).fragment.partition('?')[2])['token'][0]
        other_session = self.login_phone()
        wrong = self.client.post('/api/v1/auth/email/bind/confirm', headers=self.headers(other_session), json={'token': action_token})
        self.assertEqual(wrong.status_code, 403)
        r = self.client.post('/api/v1/auth/email/bind/confirm', headers=self.headers(a), json={'token': action_token})
        self.assertEqual(r.status_code, 200, r.text)
        user = self.client.get('/api/v1/auth/me', headers=self.headers(a)).json()['user']
        self.assertEqual(user['email'], 'new-binding@example.test')
        self.assertTrue(user['emailVerified'])
        self.assertEqual(self.client.get('/api/v1/workspace', headers=self.headers(a)).json()['workspace'], workspace)
        self.assertEqual(self.client.post('/api/v1/auth/email/bind/confirm', headers=self.headers(a), json={'token': action_token}).status_code, 400)

    def test_passwordless_delete_requires_recent_proof_and_account_export_is_scoped(self):
        a, b = self.login_phone(), self.login_phone('13900000000')
        r = self.client.request('DELETE', '/api/v1/account', headers=self.headers(a), json={})
        self.assertEqual(r.status_code, 401)
        export = self.client.get('/api/v1/account/export', headers=self.headers(a))
        self.assertEqual(export.status_code, 200, export.text)
        self.assertEqual(export.json()['user']['id'], a['user']['id'])
        self.assertNotIn('password_hash', export.text)
        proof = self.proof(a)
        r = self.client.request('DELETE', '/api/v1/account', headers=self.headers(a), json={'phoneProof': proof})
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(self.client.get('/api/v1/auth/me', headers=self.headers(a)).status_code, 401)
        self.assertEqual(self.client.get('/api/v1/auth/me', headers=self.headers(b)).status_code, 200)
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM phone_identity_proofs WHERE user_id=?', (a['user']['id'],)).fetchone()[0], 0)

    def test_sensitive_proof_concurrent_consumption_exactly_once(self):
        a = self.login_phone()
        proof = self.proof(a)
        def consume():
            try:
                with self.app.state.accounts.connection() as db:
                    db.execute('BEGIN IMMEDIATE')
                    self.app.state.phone_proofs.consumer(proof, uid=a['user']['id'], token=a['token'])(db)
                return 'used'
            except AuthError as error:
                return error.code
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: consume(), range(2)))
        self.assertCountEqual(results, ['used', 'phone_proof_invalid'])


class ActualSmsCoreRoutesTests(unittest.TestCase):
    """Exercise the production service/store with only its cloud edge mocked."""
    def setUp(self):
        from sms_auth_service import SmsAuthService
        from sms_auth_store import SmsAuthStore
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / 'core-routes.db'
        self.clock = [time.time()]
        self.sent = {}
        outer = self
        class IsolatedProvider:
            configured = True
            def send(self, *, phone, purpose, out_id, **kwargs):
                outer.sent[out_id] = phone
            def verify(self, *, phone, out_id, code):
                return outer.sent.get(out_id) == phone and code == '654321'
        self.service = SmsAuthService(SmsAuthStore(self.path, clock=lambda: self.clock[0]), IsolatedProvider())
        self.app = create_app(db_path=self.path, ai_service=StubAi(), sms_service=self.service)
        self.client = TestClient(self.app)
        self.client.__enter__()

    def tearDown(self):
        self.client.__exit__(None, None, None)
        self.temp.cleanup()

    def send(self, phone='13800000000', **headers):
        r = self.client.post('/api/v1/auth/phone/challenge', headers=headers, json={'phone': phone, 'purpose': 'login'})
        self.assertEqual(r.status_code, 200, r.text)
        return r.json()['challengeId']

    def test_real_core_login_wrong_code_and_replay_no_second_session(self):
        cid = self.send()
        bad = self.client.post('/api/v1/auth/phone/login', json={
            'challengeId': cid, 'code': '000000', 'acceptRegistration': True})
        self.assertEqual(bad.status_code, 400)
        r = self.client.post('/api/v1/auth/phone/login', json={
            'challengeId': cid, 'code': '654321', 'acceptRegistration': True})
        self.assertEqual(r.status_code, 200, r.text)
        self.assertTrue(r.json()['created'])
        replay = self.client.post('/api/v1/auth/phone/login', json={
            'challengeId': cid, 'code': '654321', 'acceptRegistration': True})
        self.assertEqual(replay.status_code, 400)
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM sessions').fetchone()[0], 1)
            self.assertEqual(db.execute('SELECT attempts FROM sms_auth_challenges').fetchone()[0], 2)

    def test_resend_invalidates_old_challenge_and_source_forwarding_is_not_trusted(self):
        old = self.send(**{'X-Forwarded-For': '1.2.3.4'})
        self.clock[0] += 61
        current = self.send(**{'X-Forwarded-For': '8.8.8.8'})
        failed = self.client.post('/api/v1/auth/phone/login', json={
            'challengeId': old, 'code': '654321', 'acceptRegistration': True})
        self.assertEqual(failed.status_code, 400)
        r = self.client.post('/api/v1/auth/phone/login', json={
            'challengeId': current, 'code': '654321', 'acceptRegistration': True})
        self.assertEqual(r.status_code, 200, r.text)
        with self.app.state.accounts.connection() as db:
            sources = [row[0] for row in db.execute('SELECT source_hash FROM sms_auth_challenges')]
        self.assertEqual(set(sources), {hashlib.sha256(b'testclient').hexdigest()})

    def test_disabled_is_honest_and_email_login_still_operates(self):
        self.service.provider = None
        cap = self.client.get('/api/v1/auth/phone/capabilities')
        self.assertFalse(cap.json()['enabled'])
        send = self.client.post('/api/v1/auth/phone/challenge', json={'phone': '13800000000'})
        self.assertEqual(send.status_code, 503)
        self.assertEqual(send.json()['code'], 'sms_auth_disabled')
        email = self.client.post('/api/v1/auth/register', json={'username': 'fallback-email',
            'email': 'fallback@example.test', 'password': 'CorrectPassword123'})
        self.assertEqual(email.status_code, 201)
        login = self.client.post('/api/v1/auth/login', json={'identifier': 'fallback@example.test', 'password': 'CorrectPassword123'})
        self.assertEqual(login.status_code, 200)
        with self.app.state.accounts.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM sms_auth_challenges').fetchone()[0], 0)

    def test_real_core_phone_bound_to_email_and_deletion_cleans_scoped_challenges(self):
        cid = self.send()
        session = self.client.post('/api/v1/auth/phone/login', json={
            'challengeId': cid, 'code': '654321', 'acceptRegistration': True}).json()
        self.clock[0] += 61
        headers = {'Authorization': 'Bearer ' + session['token']}
        cid = self.client.post('/api/v1/auth/phone/challenge', headers=headers, json={
            'phone': '13800000000', 'purpose': 'sensitive'}).json()['challengeId']
        r = self.client.post('/api/v1/auth/phone/verify-sensitive', headers=headers,
            json={'challengeId': cid, 'code': '654321'})
        self.assertEqual(r.status_code, 200, r.text)
        ticket = r.json()['phoneProof']
        delete = self.client.request('DELETE', '/api/v1/account', headers=headers, json={'phoneProof': ticket})
        self.assertEqual(delete.status_code, 200, delete.text)
        with self.app.state.accounts.connection() as db:
            row = db.execute('SELECT * FROM sms_auth_challenges WHERE id=?', (cid,)).fetchone()
            self.assertIsNone(row['owner_uid'])
            self.assertIsNone(row['session_hash'])
            self.assertIsNone(row['claim_hash'])
            self.assertEqual(row['status'], 'consumed')
            self.assertEqual(db.execute('SELECT count(*) FROM sms_auth_challenges').fetchone()[0], 2)


if __name__ == '__main__':
    unittest.main(verbosity=2)
