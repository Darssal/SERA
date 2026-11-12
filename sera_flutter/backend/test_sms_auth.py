"""Isolated SMS tests. No test in this module sends a real SMS or uses RAM keys."""
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
import hashlib
import json
from pathlib import Path
import tempfile
import threading
from types import SimpleNamespace
import unittest

from auth_store import AuthStore
from sms_auth_service import (AliyunPnvsProvider, PnvsConfig, SmsAuthService,
                              SmsProviderError)
from sms_auth_store import (SmsAuthError, SmsAuthStore, SmsPolicy, normalize_phone)


PHONE = '+8613800000000'
OTHER_PHONE = '+8613900000000'
TEST_CODE = '621937'


class FakeProvider:
    configured = True

    def __init__(self):
        self.send_calls, self.verify_calls = [], []
        self.send_error, self.verify_error = None, None
        self.entered, self.release = None, None

    def send(self, **kwargs):
        self.send_calls.append(kwargs)
        if self.send_error:
            raise self.send_error

    def verify(self, **kwargs):
        self.verify_calls.append({key: value for key, value in kwargs.items() if key != 'code'})
        if self.entered:
            self.entered.set()
            self.release.wait(3)
        if self.verify_error:
            raise self.verify_error
        return kwargs['code'] == TEST_CODE


class SmsAuthTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'isolated.sqlite3'
        self.now = 2000000000
        self.store = SmsAuthStore(self.path, clock=lambda: self.now)
        self.provider = FakeProvider()
        self.service = SmsAuthService(self.store, self.provider)

    def send(self, phone=PHONE, **kwargs):
        return self.service.send(phone, source_ip='192.0.2.1', **kwargs)

    def identity(self, phone=None):
        accounts = AuthStore(self.path)
        session = accounts.register({'username': 'sms_user', 'email': 'sms@example.test',
                                     'password': 'IsolatedPassword123'})
        with accounts.connection() as db:
            db.execute('UPDATE sessions SET expires_at=?', (self.now + 86400,))
            db.execute('UPDATE users SET phone=? WHERE id=?', (phone, session['user']['id']))
        return session['user']['id'], session['token']

    def read_challenge(self, challenge_id):
        with self.store.connection() as db:
            return dict(db.execute('SELECT * FROM sms_auth_challenges WHERE id=?', (challenge_id,)).fetchone())

    def test_unconfigured_fails_closed_and_reports_capability(self):
        disabled = SmsAuthService.from_env(self.path, {})
        self.assertFalse(disabled.capabilities()['enabled'])
        self.assertEqual(disabled.capabilities()['codeLength'], 6)
        with self.assertRaises(SmsAuthError) as caught:
            disabled.send(PHONE, source_ip='192.0.2.1')
        self.assertEqual(caught.exception.code, 'sms_auth_disabled')
        misconfigured = SmsAuthService.from_env(self.path, {'SERA_SMS_AUTH_ENABLED': 'true'})
        self.assertFalse(misconfigured.configured)
        bad_quota = SmsAuthService.from_env(self.path, {'SERA_SMS_GLOBAL_DAY_LIMIT': 'oops'})
        self.assertFalse(bad_quota.configured)

    def test_phone_normalization_scope_and_masked_response(self):
        self.assertEqual(normalize_phone('138 0000-0000'), PHONE)
        self.assertEqual(normalize_phone('+86 13800000000'), PHONE)
        for value in ('+85212345678', '12345', '1380000000x', ['13800000000'], None):
            with self.assertRaises(SmsAuthError):
                normalize_phone(value)
        challenge = self.send()
        self.assertEqual(challenge['maskedPhone'], '+86 138****0000')
        self.assertIn('resendAt', challenge)
        self.assertNotIn(PHONE, json.dumps(challenge))
        self.assertEqual(self.service.challenge_phone(challenge['challengeId']), PHONE)
        for purpose in ('bind_phone', 'sensitive'):
            with self.assertRaises(SmsAuthError):
                self.service.challenge_phone(challenge['challengeId'], purpose=purpose)

    def test_success_is_internal_proof_consumed_once_in_account_transaction(self):
        challenge = self.send()
        claim = self.service.verify(challenge['challengeId'], TEST_CODE)
        self.assertEqual(claim.phone, PHONE)
        self.assertNotIn(claim.secret, repr(claim))
        with self.assertRaises(ValueError):
            with self.store.connection() as db:
                self.store.consume_claim(db, claim)
        with self.store.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            self.assertEqual(self.store.consume_claim(db, claim), PHONE)
        with self.store.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            with self.assertRaises(SmsAuthError):
                self.store.consume_claim(db, claim)
        with self.assertRaises(SmsAuthError):
            self.service.verify(challenge['challengeId'], TEST_CODE)
        self.assertEqual(len(self.provider.verify_calls), 1)
        with self.store.connection() as db:
            self.assertNotIn(TEST_CODE, '\n'.join(db.iterdump()))

    def test_claim_consumption_rolls_back_with_failed_account_mutation(self):
        claim = self.service.verify(self.send()['challengeId'], TEST_CODE)
        with self.assertRaises(RuntimeError):
            with self.store.connection() as db:
                db.execute('BEGIN IMMEDIATE')
                self.store.consume_claim(db, claim)
                raise RuntimeError('account unique constraint or other mutation failed')
        with self.store.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            self.store.consume_claim(db, claim)
        self.assertEqual(self.read_challenge(claim.challenge_id)['status'], 'consumed')

    def test_bad_attempts_commit_across_auth_errors_and_restart(self):
        challenge_id = self.send()['challengeId']
        for attempt in range(1, 6):
            with self.assertRaises(SmsAuthError) as caught:
                self.service.verify(challenge_id, '000001')
            self.assertEqual(self.read_challenge(challenge_id)['attempts'], attempt)
            self.assertEqual(caught.exception.code, 'sms_attempts_exhausted' if attempt == 5 else 'invalid_sms_code')
            # A new worker/process sees the same durable attempt counter.
            self.service = SmsAuthService(SmsAuthStore(self.path, clock=lambda: self.now), self.provider)
        with self.assertRaises(SmsAuthError):
            self.service.verify(challenge_id, TEST_CODE)
        self.assertEqual(len(self.provider.verify_calls), 5)

    def test_expiry_claim_expiry_and_invalid_formats_do_not_call_provider(self):
        challenge_id = self.send()['challengeId']
        for value in ('12345', '1234567', '１２３４５６', 123456, None):
            with self.assertRaises(SmsAuthError):
                self.service.verify(challenge_id, value)
        self.assertEqual(len(self.provider.verify_calls), 0)
        self.now += 301
        with self.assertRaises(SmsAuthError):
            self.service.verify(challenge_id, TEST_CODE)
        claim = self.service.verify(self.send()['challengeId'], TEST_CODE)
        self.now += 61
        with self.store.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            with self.assertRaises(SmsAuthError):
                self.store.consume_claim(db, claim)

    def test_resend_invalidates_old_challenges_across_purposes_and_workers(self):
        uid, token = self.identity()
        first = self.send()['challengeId']
        with self.assertRaises(SmsAuthError) as caught:
            SmsAuthService(SmsAuthStore(self.path, clock=lambda: self.now), self.provider).send(
                PHONE, source_ip='198.51.100.2', purpose='bind_phone', owner_uid=uid, session_token=token)
        self.assertEqual(caught.exception.code, 'sms_cooldown')
        self.assertEqual(caught.exception.retry_after_seconds, 60)
        self.now += 60
        self.send(purpose='bind_phone', owner_uid=uid, session_token=token)
        self.assertEqual(self.read_challenge(first)['status'], 'superseded')
        with self.assertRaises(SmsAuthError):
            self.service.verify(first, TEST_CODE)

    def test_owner_and_session_binding_blocks_cross_account_and_cross_session(self):
        uid, token = self.identity()
        challenge_id = self.send(purpose='bind_phone', owner_uid=uid, session_token=token)['challengeId']
        for scope in ({'owner_uid': 'user-b', 'session_token': token},
                      {'owner_uid': uid, 'session_token': 'session-b'}):
            with self.assertRaises(SmsAuthError):
                self.service.verify(challenge_id, TEST_CODE, purpose='bind_phone', **scope)
        with self.assertRaises(SmsAuthError):
            self.service.verify(challenge_id, TEST_CODE)
        claim = self.service.verify(challenge_id, TEST_CODE, purpose='bind_phone', owner_uid=uid, session_token=token)
        self.assertEqual(claim.session_hash, hashlib.sha256(token.encode()).hexdigest())
        self.assertEqual(len(self.provider.verify_calls), 1)

    def test_send_timeout_retains_challenge_no_automatic_retry_and_persistent_cooldown(self):
        self.provider.send_error = SmsProviderError(uncertain=True)
        challenge = self.send()
        self.assertEqual(challenge['deliveryStatus'], 'unknown')
        self.assertEqual(self.read_challenge(challenge['challengeId'])['status'], 'unknown')
        with self.assertRaises(SmsAuthError):
            self.send()
        self.assertEqual(len(self.provider.send_calls), 1)
        # A delayed real SMS can still be checked, with no synthetic success.
        claim = self.service.verify(challenge['challengeId'], TEST_CODE)
        self.assertEqual(claim.phone, PHONE)

    def test_provider_rejection_still_counts_reservation_and_code_check_errors_count(self):
        self.provider.send_error = SmsProviderError('not activated')
        with self.assertRaises(SmsProviderError):
            self.send()
        with self.assertRaises(SmsAuthError) as caught:
            self.send()
        self.assertEqual(caught.exception.code, 'sms_cooldown')
        self.provider.send_error = None
        self.now += 60
        challenge_id = self.send()['challengeId']
        self.provider.verify_error = RuntimeError('provider request may contain a private code')
        with self.assertRaises(SmsProviderError) as caught:
            self.service.verify(challenge_id, TEST_CODE)
        self.assertNotIn('private code', str(caught.exception))
        self.assertEqual(self.read_challenge(challenge_id)['attempts'], 1)
        self.assertEqual(self.read_challenge(challenge_id)['status'], 'unknown')

    def test_phone_ip_and_global_quotas_survive_store_recreation(self):
        policy = replace(SmsPolicy(), phone_hour_limit=2, phone_day_limit=3,
                         ip_hour_limit=3, global_hour_limit=4, global_day_limit=5)
        self.store = SmsAuthStore(self.path, policy=policy, clock=lambda: self.now)
        self.service = SmsAuthService(self.store, self.provider)
        self.send()
        self.now += 60
        self.send()
        self.now += 60
        with self.assertRaises(SmsAuthError) as caught:
            self.send()
        self.assertEqual(caught.exception.code, 'sms_rate_limited')
        self.send(OTHER_PHONE)
        with self.assertRaises(SmsAuthError):
            self.send('+8613700000000')  # Same source IP, third previous reservation.
        self.service.send('+8613700000000', source_ip='198.51.100.2')
        with self.assertRaises(SmsAuthError):
            self.service.send('+8613600000000', source_ip='198.51.100.3')
        self.assertEqual(len(self.provider.send_calls), 4)

    def test_day_and_ip_minute_quotas_are_independent(self):
        policy = replace(SmsPolicy(), phone_day_limit=1, global_day_limit=2, ip_minute_limit=1)
        self.service = SmsAuthService(SmsAuthStore(self.path, policy=policy, clock=lambda: self.now), self.provider)
        self.send()
        with self.assertRaises(SmsAuthError):
            self.send(OTHER_PHONE)  # Minute source quota without a phone conflict.
        self.now += 3601
        self.service = SmsAuthService(SmsAuthStore(self.path, policy=policy, clock=lambda: self.now), self.provider)
        with self.assertRaises(SmsAuthError):
            self.send()  # Phone daily quota survives new store and hourly reset.
        self.send(OTHER_PHONE)
        self.now += 3601
        with self.assertRaises(SmsAuthError):
            self.service.send('+8613700000000', source_ip='198.51.100.1')
        self.assertEqual(len(self.provider.send_calls), 2)

    def test_delete_anonymizes_scoped_challenges_and_keeps_abuse_quotas(self):
        uid, token = self.identity()
        challenge_id = self.send(purpose='bind_phone', owner_uid=uid, session_token=token)['challengeId']
        with self.store.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            self.store.delete_account_data(db, uid)
        row = self.read_challenge(challenge_id)
        self.assertIsNone(row['owner_uid'])
        self.assertIsNone(row['session_hash'])
        self.assertEqual(row['status'], 'consumed')
        with self.assertRaises(SmsAuthError):
            self.send()

    def test_scoped_send_without_accounts_schema_fails_closed(self):
        with self.assertRaises(SmsAuthError) as caught:
            self.send(purpose='bind_phone', owner_uid='no-real-user', session_token='no-real-session')
        self.assertEqual(caught.exception.code, 'session_expired')
        self.assertEqual(self.provider.send_calls, [])
        with self.store.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM sms_auth_challenges').fetchone()[0], 0)

    def test_scoped_send_checks_live_session_and_current_phone(self):
        uid, token = self.identity(PHONE)
        for purpose, phone in (('sensitive', OTHER_PHONE), ('bind_phone', OTHER_PHONE)):
            with self.assertRaises(SmsAuthError):
                self.send(phone, purpose=purpose, owner_uid=uid, session_token=token)
        self.assertEqual(self.provider.send_calls, [])
        self.send(purpose='sensitive', owner_uid=uid, session_token=token)
        self.assertEqual(len(self.provider.send_calls), 1)
        self.now += 60
        with self.store.connection() as db:
            db.execute('UPDATE sessions SET expires_at=?', (self.now,))
        with self.assertRaises(SmsAuthError) as caught:
            self.send(purpose='sensitive', owner_uid=uid, session_token=token)
        self.assertEqual(caught.exception.code, 'session_expired')
        self.assertEqual(len(self.provider.send_calls), 1)

    def test_session_revoked_between_route_preflight_and_reservation_never_sends(self):
        uid, token = self.identity()
        accounts = AuthStore(self.path)
        # Cached route authentication/preflight succeeded before revocation.
        accounts.authenticate(token)
        started = threading.Event()
        def stale_send():
            started.set()
            try:
                return self.send(purpose='bind_phone', owner_uid=uid, session_token=token)
            except SmsAuthError as error:
                return error.code
        with ThreadPoolExecutor(max_workers=1) as pool:
            with self.store.connection() as db:
                db.execute('BEGIN IMMEDIATE')
                db.execute('DELETE FROM sessions WHERE user_id=?', (uid,))
                future = pool.submit(stale_send)
                self.assertTrue(started.wait(2))
                # The send cannot reserve until this revocation commits.
            self.assertEqual(future.result(3), 'session_expired')
        self.assertEqual(self.provider.send_calls, [])
        with self.store.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM sms_auth_challenges').fetchone()[0], 0)

    def test_deleted_account_cannot_reserve_with_cached_owner_and_session(self):
        uid, token = self.identity()
        accounts = AuthStore(self.path)
        accounts.authenticate(token)
        accounts.delete_account(token, 'IsolatedPassword123')
        with self.assertRaises(SmsAuthError) as caught:
            self.send(purpose='bind_phone', owner_uid=uid, session_token=token)
        self.assertEqual(caught.exception.code, 'session_expired')
        self.assertEqual(self.provider.send_calls, [])
        with self.store.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM sms_auth_challenges').fetchone()[0], 0)

    def test_concurrent_send_reserves_once(self):
        gate = threading.Barrier(8)
        def send_once(index):
            gate.wait(3)
            try:
                store = SmsAuthStore(self.path, clock=lambda: self.now)
                return SmsAuthService(store, self.provider).send(PHONE, source_ip=f'192.0.2.{index}')
            except SmsAuthError:
                return None
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(send_once, range(8)))
        self.assertEqual(sum(result is not None for result in results), 1)
        self.assertEqual(len(self.provider.send_calls), 1)

    def test_concurrent_verify_and_resend_fence_late_provider_success(self):
        challenge_id = self.send()['challengeId']
        self.provider.entered, self.provider.release = threading.Event(), threading.Event()
        def first_check():
            try:
                return self.service.verify(challenge_id, TEST_CODE)
            except SmsAuthError as error:
                return error.code
        with ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(first_check)
            self.assertTrue(self.provider.entered.wait(2))
            with self.assertRaises(SmsAuthError) as caught:
                self.service.verify(challenge_id, TEST_CODE)
            self.assertEqual(caught.exception.code, 'sms_verification_busy')
            self.now += 60
            self.send()
            self.provider.release.set()
            self.assertEqual(future.result(3), 'sms_challenge_expired')
        self.assertEqual(len(self.provider.verify_calls), 1)

    def test_crashed_verify_never_reopens_a_lease(self):
        challenge_id = self.send()['challengeId']
        self.store.begin_verification(challenge_id)
        self.now += 120
        with self.assertRaises(SmsAuthError) as caught:
            SmsAuthStore(self.path, clock=lambda: self.now).begin_verification(challenge_id)
        self.assertEqual(caught.exception.code, 'sms_verification_busy')
        self.assertEqual(len(self.provider.verify_calls), 0)

    def test_claim_concurrent_consumption_only_one_account_mutation(self):
        claim = self.service.verify(self.send()['challengeId'], TEST_CODE)
        with self.store.connection() as db:
            db.execute('CREATE TABLE account_mutations (value TEXT)')
        gate = threading.Barrier(6)
        def consume(index):
            gate.wait(3)
            try:
                with self.store.connection() as db:
                    db.execute('BEGIN IMMEDIATE')
                    self.store.consume_claim(db, claim)
                    db.execute('INSERT INTO account_mutations VALUES(?)', (str(index),))
                return True
            except SmsAuthError:
                return False
        with ThreadPoolExecutor(max_workers=6) as pool:
            self.assertEqual(sum(pool.map(consume, range(6))), 1)
        with self.store.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM account_mutations').fetchone()[0], 1)

class PnvsAdapterTests(unittest.TestCase):
    def setUp(self):
        self.client = SimpleNamespace()
        self.provider = AliyunPnvsProvider(PnvsConfig('isolated-key', 'isolated-secret', '系统赠送签名'), client=self.client)

    @staticmethod
    def response(out_id='out-123', result='PASS', code='OK', success=True):
        return SimpleNamespace(body=SimpleNamespace(code=code, success=success,
            model=SimpleNamespace(out_id=out_id, verify_result=result)))

    def test_official_sdk_send_parameters_and_no_retry_no_return_code(self):
        calls = []
        self.client.send_sms_verify_code_with_options = lambda request, runtime: calls.append((request, runtime)) or self.response()
        self.provider.send(phone=PHONE, purpose='login', out_id='out-123', valid_seconds=300, cooldown_seconds=60)
        request, runtime = calls[0]
        self.assertEqual(request.phone_number, PHONE[3:])
        self.assertEqual(request.country_code, '86')
        self.assertEqual(request.scheme_name, self.provider._scheme_name('out-123'))
        self.assertLessEqual(len(request.scheme_name), 20)
        self.assertEqual(request.template_code, '100001')
        self.assertEqual(json.loads(request.template_param), {'code': '##code##', 'min': '5'})
        self.assertEqual(request.code_length, 6)
        self.assertEqual(request.duplicate_policy, 1)
        self.assertEqual(request.auto_retry, 0)
        self.assertFalse(request.return_verify_code)
        self.assertFalse(runtime.autoretry)
        self.assertEqual(runtime.max_attempts, 1)
        self.assertFalse(runtime.ignore_ssl)

    def test_scheme_is_challenge_specific_and_identical_for_send_and_check(self):
        sends, checks = [], []
        self.client.send_sms_verify_code_with_options = lambda request, runtime: sends.append(request) or self.response(out_id=request.out_id)
        self.client.check_sms_verify_code_with_options = lambda request, runtime: checks.append(request) or self.response(out_id=request.out_id)
        for out_id in ('older-delayed-send', 'newest-send'):
            self.provider.send(phone=PHONE, purpose='login', out_id=out_id, valid_seconds=300, cooldown_seconds=60)
            self.assertTrue(self.provider.verify(phone=PHONE, out_id=out_id, code=TEST_CODE))
        self.assertEqual(sends[0].scheme_name, checks[0].scheme_name)
        self.assertEqual(sends[1].scheme_name, checks[1].scheme_name)
        self.assertNotEqual(sends[0].scheme_name, sends[1].scheme_name)
        self.assertEqual(len(sends[0].scheme_name), 20)
        self.assertEqual(self.provider._scheme_name('older-delayed-send'), sends[0].scheme_name)

    def test_check_requires_pass_and_exact_out_id_not_only_ok(self):
        calls = []
        def check(request, runtime):
            calls.append(request)
            return self.response(result='UNKNOWN')
        self.client.check_sms_verify_code_with_options = check
        self.assertFalse(self.provider.verify(phone=PHONE, out_id='out-123', code=TEST_CODE))
        self.assertEqual(calls[0].out_id, 'out-123')
        self.assertEqual(calls[0].verify_code, TEST_CODE)
        self.client.check_sms_verify_code_with_options = lambda request, runtime: self.response(out_id='another-challenge')
        with self.assertRaises(SmsProviderError):
            self.provider.verify(phone=PHONE, out_id='out-123', code=TEST_CODE)
        self.client.check_sms_verify_code_with_options = lambda request, runtime: self.response()
        self.assertTrue(self.provider.verify(phone=PHONE, out_id='out-123', code=TEST_CODE))

    def test_errors_do_not_expose_sdk_exception_contents_or_secret(self):
        calls = []
        def fail(request, runtime):
            calls.append(request)
            raise RuntimeError('isolated-secret ' + TEST_CODE)
        self.client.send_sms_verify_code_with_options = fail
        with self.assertRaises(SmsProviderError) as caught:
            self.provider.send(phone=PHONE, purpose='login', out_id='out-123', valid_seconds=300, cooldown_seconds=60)
        self.assertTrue(caught.exception.uncertain)
        self.assertNotIn(TEST_CODE, str(caught.exception))
        self.assertNotIn('isolated-secret', str(caught.exception))
        self.assertNotIn('isolated-secret', repr(self.provider.config))
        self.assertEqual(len(calls), 1)

    def test_test_allowlist_blocks_unapproved_numbers_before_sdk_call(self):
        provider = AliyunPnvsProvider(PnvsConfig('isolated-key', 'isolated-secret', '系统赠送签名',
                                    allowed_test_phones=(OTHER_PHONE,)), client=self.client)
        with self.assertRaises(SmsProviderError) as caught:
            provider.send(phone=PHONE, purpose='login', out_id='out-123', valid_seconds=300, cooldown_seconds=60)
        self.assertEqual(caught.exception.code, 'sms_phone_not_allowed')

    def test_explicit_sdk_rejection_is_not_reported_as_unknown_delivery(self):
        class SdkError(Exception):
            code = 'FUNCTION_NOT_OPENED'
        def fail(request, runtime):
            raise SdkError('private request diagnostics')
        self.client.send_sms_verify_code_with_options = fail
        with self.assertRaises(SmsProviderError) as caught:
            self.provider.send(phone=PHONE, purpose='login', out_id='out-123', valid_seconds=300, cooldown_seconds=60)
        self.assertFalse(caught.exception.uncertain)
        self.assertNotIn('private request', str(caught.exception))

    def test_real_order_status_rejection_has_actionable_message_and_never_unknown_delivery(self):
        calls = []
        def rejected(request, runtime):
            calls.append(request)
            return self.response(code='OFFER_NOT_ORDER_STATUS', success=False)
        self.client.send_sms_verify_code_with_options = rejected
        with self.assertRaises(SmsProviderError) as caught:
            self.provider.send(phone=PHONE, purpose='login', out_id='out-123', valid_seconds=300, cooldown_seconds=60)
        self.assertEqual(caught.exception.code, 'sms_service_order_unavailable')
        self.assertEqual(caught.exception.status, 503)
        self.assertFalse(caught.exception.uncertain)
        self.assertIn('开通或订单状态', str(caught.exception))
        self.assertEqual(len(calls), 1)
        class SdkOrderError(Exception):
            code = 'OFFER_NOT_ORDER_STATUS'
        def raised(request, runtime):
            raise SdkOrderError('private diagnostics isolated-secret')
        self.client.send_sms_verify_code_with_options = raised
        with self.assertRaises(SmsProviderError) as caught:
            self.provider.send(phone=PHONE, purpose='login', out_id='out-123', valid_seconds=300, cooldown_seconds=60)
        self.assertEqual(caught.exception.code, 'sms_service_order_unavailable')
        self.assertFalse(caught.exception.uncertain)
        self.assertNotIn('isolated-secret', str(caught.exception))


if __name__ == '__main__':
    unittest.main()
