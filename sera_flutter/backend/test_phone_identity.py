"""Identity migration/lifecycle tests; all phone proofs use isolated test DBs."""
import hashlib
import json
from contextlib import closing
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
import unittest

from auth_store import AuthError, AuthStore


PASSWORD = 'CorrectPassword123'
PHONE_A = '+8613800000001'
PHONE_B = '+8613800000002'


class PhoneIdentityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'identity.sqlite3'
        self.store = AuthStore(self.path)
        with self.store.connection() as db:
            db.execute('CREATE TABLE test_proofs(id TEXT PRIMARY KEY, used INTEGER NOT NULL DEFAULT 0)')

    def proof(self, name):
        with self.store.connection() as db:
            db.execute('INSERT INTO test_proofs(id) VALUES(?)', (name,))

        def consume(db):
            changed = db.execute('UPDATE test_proofs SET used=1 WHERE id=? AND used=0', (name,)).rowcount
            if changed != 1:
                raise AuthError('Test proof expired', 401, 'sms_proof_expired')
        return consume

    def used(self, name):
        with self.store.connection() as db:
            return db.execute('SELECT used FROM test_proofs WHERE id=?', (name,)).fetchone()[0]

    def phone_user(self, phone=PHONE_A, proof='new'):
        return self.store.login_phone(phone, consent=True, consume_proof=self.proof(proof))

    def email_user(self, username='legacy'):
        return self.store.register({'username': username, 'email': username + '@example.test', 'password': PASSWORD})

    def assert_code(self, code, function, *args, **kwargs):
        with self.assertRaises(AuthError) as caught:
            function(*args, **kwargs)
        self.assertEqual(caught.exception.code, code)

    def concurrently(self, functions):
        barrier = threading.Barrier(len(functions))
        results = []

        def run(function):
            barrier.wait(timeout=5)
            try:
                results.append(('ok', function()))
            except AuthError as error:
                results.append(('error', error.code))
            except Exception as error:
                results.append(('unexpected', repr(error)))
        threads = [threading.Thread(target=run, args=(function,)) for function in functions]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=15)
            self.assertFalse(thread.is_alive())
        self.assertNotIn('unexpected', [kind for kind, _ in results], results)
        return results

    def test_registration_requires_explicit_consent_without_consuming_challenge(self):
        proof = self.proof('consent')
        for consent in (False, None, 'true', 1):
            self.assert_code('phone_registration_consent_required', self.store.login_phone,
                             PHONE_A, consent=consent, consume_proof=proof)
        self.assertEqual(self.used('consent'), 0)
        self.assertFalse(self.store.phone_registered(PHONE_A))
        session = self.store.login_phone(PHONE_A, consent=True, consume_proof=proof)
        user = session['user']
        self.assertEqual(user['phone'], PHONE_A)
        self.assertIsNone(user['email'])
        self.assertFalse(user['emailVerified'])
        self.assertFalse(user['hasPassword'])
        with self.store.connection() as db:
            row = db.execute('SELECT * FROM users').fetchone()
            self.assertIsNone(row['salt'])
            self.assertIsNone(row['password_hash'])
            self.assertNotIn('13800000001', row['username'])
        self.assert_code('invalid_credentials', self.store.login,
                         {'identifier': user['username'], 'password': PASSWORD})
        self.assertEqual(self.store.authenticate(session['token'])['user'], user)
        again = self.store.login_phone('13800000001', consume_proof=self.proof('again'))
        self.assertEqual(again['user']['id'], user['id'])

    def test_invalid_phone_and_missing_proof_create_no_account(self):
        for phone in (None, 13800000001, '+85291234567', '123', '+8612800000001', '1380000000x'):
            self.assert_code('invalid_phone', self.store.phone_registered, phone)
        self.assert_code('recent_phone_verification_required', self.store.login_phone,
                         PHONE_A, consent=True, consume_proof=None)
        with self.store.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM users').fetchone()[0], 0)

    def test_single_proof_concurrent_logins_cannot_replay_or_duplicate_accounts(self):
        proof = self.proof('once')
        results = self.concurrently([
            lambda: self.store.login_phone(PHONE_A, consent=True, consume_proof=proof),
            lambda: self.store.login_phone(PHONE_A, consent=True, consume_proof=proof),
        ])
        self.assertEqual([kind for kind, _ in results].count('ok'), 1, results)
        self.assertIn(('error', 'sms_proof_expired'), results)
        with self.store.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM users').fetchone()[0], 1)
            self.assertEqual(db.execute('SELECT count(*) FROM sessions').fetchone()[0], 1)

    def test_two_valid_concurrent_challenges_create_one_phone_identity(self):
        proofs = [self.proof('first'), self.proof('second')]
        results = self.concurrently([
            lambda proof=proof: self.store.login_phone(PHONE_A, consent=True, consume_proof=proof)
            for proof in proofs
        ])
        self.assertEqual([kind for kind, _ in results], ['ok', 'ok'])
        self.assertEqual(len({session['user']['id'] for _, session in results}), 1)

    def test_failed_session_creation_rolls_back_proof_consumption_and_user_creation(self):
        proof = self.proof('rollback')
        with self.store.connection() as db:
            db.execute("CREATE TRIGGER refuse_sessions BEFORE INSERT ON sessions BEGIN SELECT RAISE(ABORT,'isolated failure'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            self.store.login_phone(PHONE_A, consent=True, consume_proof=proof)
        self.assertEqual(self.used('rollback'), 0)
        self.assertFalse(self.store.phone_registered(PHONE_A))

    def test_bind_preserves_email_identity_requires_password_and_never_merges(self):
        account = self.email_user()
        foreign = self.phone_user()
        proof = self.proof('bind')
        self.assert_code('invalid_credentials', self.store.preflight_phone_binding,
                         account['token'], PHONE_B, 'wrong')
        self.assert_code('invalid_credentials', self.store.bind_phone,
                         account['token'], PHONE_B, password='wrong', consume_proof=proof)
        self.assertEqual(self.used('bind'), 0)
        self.assert_code('phone_in_use', self.store.bind_phone,
                         account['token'], PHONE_A, password=PASSWORD, consume_proof=proof)
        self.assertEqual(self.used('bind'), 0)
        self.assertEqual(self.store.preflight_phone_binding(account['token'], PHONE_B, PASSWORD)['id'], account['user']['id'])
        bound = self.store.bind_phone(account['token'], PHONE_B, password=PASSWORD, consume_proof=proof)
        self.assertEqual(bound['id'], account['user']['id'])
        self.assertEqual(bound['email'], account['user']['email'])
        self.assertTrue(bound['hasPassword'])
        self.assertEqual(self.store.login_phone(PHONE_B, consume_proof=self.proof('bound-login'))['user']['id'], bound['id'])
        self.assertEqual(self.store.login({'identifier': bound['email'], 'password': PASSWORD})['user']['id'], bound['id'])
        self.assertEqual(self.store.authenticate(foreign['token'])['user']['id'], foreign['user']['id'])
        self.assert_code('phone_already_bound', self.store.bind_phone,
                         account['token'], PHONE_A, password=PASSWORD, consume_proof=self.proof('replace'))
        self.assertEqual(self.used('replace'), 0)

    def test_concurrent_binding_phone_uniqueness_rejects_loser_without_consuming_proof(self):
        accounts = [self.email_user('first'), self.email_user('second')]
        proofs = [self.proof('bind-first'), self.proof('bind-second')]
        results = self.concurrently([
            lambda account=account, proof=proof: self.store.bind_phone(account['token'], PHONE_A,
                password=PASSWORD, consume_proof=proof)
            for account, proof in zip(accounts, proofs)
        ])
        self.assertEqual([kind for kind, _ in results].count('ok'), 1, results)
        self.assertIn(('error', 'phone_in_use'), results)
        self.assertEqual(self.used('bind-first') + self.used('bind-second'), 1)
        with self.store.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM users WHERE phone=?', (PHONE_A,)).fetchone()[0], 1)

    def test_email_binding_requires_current_identity_then_target_verification_same_session(self):
        account = self.phone_user()
        other = self.phone_user(PHONE_B, 'other-user')
        second_session = self.store.login_phone(PHONE_A, consume_proof=self.proof('second-session'))
        self.assert_code('email_not_bound', self.store.create_email_action, kind='verify', uid=account['user']['id'])
        self.assert_code('recent_phone_verification_required', self.store.start_email_binding,
                         account['token'], 'bound@example.test')
        action = self.store.start_email_binding(account['token'], 'BOUND@example.test', consume_proof=self.proof('email-start'))
        self.assertIsNone(self.store.authenticate(account['token'])['user']['email'])
        self.assert_code('action_account_mismatch', self.store.confirm_email_binding, other['token'], action['token'])
        self.assert_code('action_account_mismatch', self.store.confirm_email_binding, second_session['token'], action['token'])
        self.assert_code('action_expired', self.store.confirm_email_action, token=action['token'], kind='verify')
        user = self.store.confirm_email_binding(account['token'], action['token'])
        self.assertEqual(user['id'], account['user']['id'])
        self.assertEqual(user['email'], 'bound@example.test')
        self.assertTrue(user['emailVerified'])
        self.assertFalse(user['hasPassword'])
        self.assert_code('action_expired', self.store.confirm_email_binding, account['token'], action['token'])
        reset = self.store.create_email_action(kind='reset', email=user['email'])
        self.store.confirm_email_action(token=reset['token'], kind='reset', password=PASSWORD)
        self.assertEqual(self.store.login({'identifier': user['email'], 'password': PASSWORD})['user']['id'], user['id'])

    def test_email_binding_reservation_conflict_resend_expiry_and_no_account_merge(self):
        a, b = self.phone_user(), self.phone_user(PHONE_B, 'new-b')
        email_user = self.email_user()
        unused = self.proof('unused')
        self.assert_code('email_in_use', self.store.start_email_binding,
                         a['token'], email_user['user']['email'], consume_proof=unused)
        self.assertEqual(self.used('unused'), 0)
        first = self.store.start_email_binding(a['token'], 'shared@example.test', consume_proof=self.proof('reserve'))
        self.assert_code('email_reserved', self.store.start_email_binding,
                         b['token'], 'SHARED@example.test', consume_proof=unused)
        self.assertEqual(self.used('unused'), 0)
        second = self.store.start_email_binding(a['token'], 'shared@example.test', consume_proof=self.proof('resend'))
        self.assert_code('action_expired', self.store.confirm_email_binding, a['token'], first['token'])
        with self.store.connection() as db:
            db.execute('UPDATE email_bindings SET expires_at=0 WHERE used=0')
        self.assert_code('action_expired', self.store.confirm_email_binding, a['token'], second['token'])
        replacement = self.store.start_email_binding(b['token'], 'shared@example.test', consume_proof=unused)
        bound = self.store.confirm_email_binding(b['token'], replacement['token'])
        self.assertEqual(bound['id'], b['user']['id'])
        self.assertIsNone(self.store.authenticate(a['token'])['user']['email'])

    def test_email_binding_race_with_registration_rejects_conflict_and_preserves_owner(self):
        phone = self.phone_user()
        action = self.store.start_email_binding(phone['token'], 'racer@example.test', consume_proof=self.proof('race'))
        registered = self.store.register({'username': 'racer', 'email': 'racer@example.test', 'password': PASSWORD})
        self.assert_code('email_in_use', self.store.confirm_email_binding, phone['token'], action['token'])
        self.assertIsNone(self.store.authenticate(phone['token'])['user']['email'])
        self.assertEqual(self.store.authenticate(registered['token'])['user']['email'], 'racer@example.test')

    def test_email_reservation_and_confirmation_are_atomic_under_concurrency(self):
        accounts = [self.phone_user(), self.phone_user(PHONE_B, 'reservation-b')]
        proofs = [self.proof('reservation-first'), self.proof('reservation-second')]
        results = self.concurrently([
            lambda account=account, proof=proof: (account, self.store.start_email_binding(
                account['token'], 'unique@example.test', consume_proof=proof))
            for account, proof in zip(accounts, proofs)
        ])
        self.assertEqual([kind for kind, _ in results].count('ok'), 1, results)
        self.assertIn(('error', 'email_reserved'), results)
        account, action = next(value for kind, value in results if kind == 'ok')
        confirmed = self.concurrently([
            lambda: self.store.confirm_email_binding(account['token'], action['token']),
            lambda: self.store.confirm_email_binding(account['token'], action['token']),
        ])
        self.assertEqual([kind for kind, _ in confirmed].count('ok'), 1, confirmed)
        self.assertIn(('error', 'action_expired'), confirmed)
        self.assertEqual(self.used('reservation-first') + self.used('reservation-second'), 1)

    def test_failed_sensitive_proof_rolls_back_email_binding_and_password_change(self):
        account = self.phone_user()
        proof = self.proof('denied-sensitive')

        def reject_after_write(db):
            proof(db)
            return False
        self.assert_code('recent_phone_verification_required', self.store.start_email_binding,
                         account['token'], 'failed@example.test', consume_proof=reject_after_write)
        self.assertEqual(self.used('denied-sensitive'), 0)
        self.assert_code('recent_phone_verification_required', self.store.set_password,
                         account['token'], PASSWORD, consume_proof=reject_after_write)
        self.assertEqual(self.used('denied-sensitive'), 0)
        self.assertFalse(self.store.authenticate(account['token'])['user']['hasPassword'])

    def test_email_binding_rate_limit_logout_and_passwordless_delete_guard(self):
        account = self.phone_user()
        for index in range(5):
            self.store.start_email_binding(account['token'], f'bind{index}@example.test', consume_proof=self.proof(f'request-{index}'))
        unused = self.proof('limited')
        self.assert_code('mail_rate_limited', self.store.start_email_binding,
                         account['token'], 'six@example.test', consume_proof=unused)
        self.assertEqual(self.used('limited'), 0)
        self.assert_code('recent_phone_verification_required', self.store.delete_account, account['token'])
        self.assert_code('recent_phone_verification_required', self.store.delete_account, account['token'], PASSWORD)
        with self.store.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM email_bindings').fetchone()[0], 5)
        self.store.logout(account['token'])
        with self.store.connection() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM email_bindings').fetchone()[0], 0)

    def test_set_password_uses_recent_proof_revokes_other_sessions_and_keeps_current(self):
        account = self.phone_user()
        other_session = self.store.login_phone(PHONE_A, consume_proof=self.proof('old-session'))
        with self.store.connection() as db:
            db.execute('''CREATE TABLE push_subscriptions(endpoint TEXT PRIMARY KEY,
                user_id TEXT REFERENCES users(id) ON DELETE CASCADE, session_hash TEXT)''')
            for name, session in [('current', account), ('other', other_session)]:
                db.execute('INSERT INTO push_subscriptions VALUES(?,?,?)',
                           (name, account['user']['id'], hashlib.sha256(session['token'].encode()).hexdigest()))
        self.assert_code('recent_phone_verification_required', self.store.set_password,
                         account['token'], PASSWORD)
        proof = self.proof('password')
        user = self.store.set_password(account['token'], PASSWORD, consume_proof=proof)
        self.assertTrue(user['hasPassword'])
        self.assertTrue(self.store.authenticate(account['token'])['user']['hasPassword'])
        self.assert_code('session_expired', self.store.authenticate, other_session['token'])
        self.assertEqual(self.store.login({'identifier': user['username'], 'password': PASSWORD})['user']['id'], user['id'])
        self.assert_code('sms_proof_expired', self.store.set_password,
                         account['token'], 'ReplacementPassword123', consume_proof=proof)
        with self.store.connection() as db:
            self.assertEqual([row[0] for row in db.execute('SELECT endpoint FROM push_subscriptions')], ['current'])
        self.store.set_password(account['token'], 'ReplacementPassword123', password=PASSWORD)
        self.assert_code('invalid_credentials', self.store.login, {'identifier': user['username'], 'password': PASSWORD})

    def test_password_account_can_use_current_phone_proof_and_all_deletion_children_cascade(self):
        from sync_store import SyncStore
        from workflows import WorkflowStore
        from test_server import empty_workspace
        WorkflowStore(self.path)
        SyncStore(self.path)
        account = self.phone_user()
        other = self.email_user('survivor')
        uid = account['user']['id']
        with self.store.connection() as db:
            for current in (account, other):
                db.execute('INSERT INTO account_workspaces VALUES(?,?,?)',
                           (current['user']['id'], 1, json.dumps(empty_workspace())))
            db.execute('INSERT INTO sync_operations VALUES(?,?,?,?)', (uid, 'op', 'digest', 1))
        workflows = WorkflowStore(self.path)
        workflows.enqueue(uid, 'plan', {})
        email_action = self.store.start_email_binding(account['token'], 'delete@example.test', consume_proof=self.proof('delete-bind'))
        self.store.confirm_email_binding(account['token'], email_action['token'])
        self.store.create_email_action(kind='reset', email='delete@example.test')
        self.store.set_password(account['token'], PASSWORD, consume_proof=self.proof('set-before-delete'))
        proof = self.proof('delete')
        self.store.delete_account(account['token'], consume_proof=proof)
        self.assertEqual(self.used('delete'), 1)
        self.assert_code('session_expired', self.store.authenticate, account['token'])
        self.assertEqual(self.store.authenticate(other['token'])['user']['id'], other['user']['id'])
        with self.store.connection() as db:
            for table in ('sessions', 'account_workspaces', 'jobs', 'sync_operations', 'email_actions', 'email_bindings'):
                self.assertEqual(db.execute(f'SELECT count(*) FROM {table} WHERE user_id=?', (uid,)).fetchone()[0], 0, table)
            self.assertEqual(db.execute('SELECT count(*) FROM account_workspaces WHERE user_id=?', (other['user']['id'],)).fetchone()[0], 1)
            self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(), [])

    def test_deletion_anonymizes_owned_sms_but_retains_number_and_global_quota_records(self):
        from sms_auth_store import SmsAuthStore
        from sms_auth_routes import PhoneProofs
        sms = SmsAuthStore(self.path)
        PhoneProofs(self.store)
        account = self.phone_user()
        challenge = sms.reserve_send(PHONE_A, purpose='sensitive', source_ip='127.0.0.1',
                                    owner_uid=account['user']['id'], session_token=account['token'])
        with self.store.connection() as db:
            db.execute('INSERT INTO phone_identity_proofs VALUES(?,?,?,?,?,0)',
                       ('test-sensitive-proof', account['user']['id'],
                        hashlib.sha256(account['token'].encode()).hexdigest(), PHONE_A, int(time.time()) + 300))
        self.store.delete_account(account['token'], consume_proof=self.proof('delete-sms'))
        with self.store.connection() as db:
            row = db.execute('SELECT * FROM sms_auth_challenges WHERE id=?', (challenge['id'],)).fetchone()
            self.assertIsNone(row['owner_uid'])
            self.assertIsNone(row['session_hash'])
            self.assertIsNone(row['claim_hash'])
            self.assertEqual(row['status'], 'consumed')
            self.assertEqual(row['phone'], PHONE_A)
            self.assertIsNotNone(row['source_hash'])
            self.assertEqual(db.execute('SELECT count(*) FROM phone_identity_proofs').fetchone()[0], 0)


class IdentityMigrationTests(unittest.TestCase):
    def legacy(self, path, *, verified=True, unknown_column=False, orphan=False):
        salt, iterations = b'legacy-16-bytes!!', 6000
        hashed = hashlib.pbkdf2_hmac('sha256', PASSWORD.encode(), salt, iterations)
        token_hash = hashlib.sha256(b'legacy-token').hexdigest()
        with closing(sqlite3.connect(path)) as db, db:
            db.executescript('''
                CREATE TABLE users(id TEXT PRIMARY KEY,username TEXT NOT NULL COLLATE NOCASE UNIQUE,
                  email TEXT NOT NULL COLLATE NOCASE UNIQUE,salt BLOB NOT NULL,password_hash BLOB NOT NULL,
                  iterations INTEGER NOT NULL,created_at INTEGER NOT NULL);
                CREATE TABLE sessions(token_hash TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                  expires_at INTEGER NOT NULL);
                CREATE TABLE account_workspaces(user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
                  revision INTEGER NOT NULL,body TEXT NOT NULL);
                CREATE TABLE push_subscriptions(endpoint TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                  body TEXT NOT NULL,created_at INTEGER NOT NULL,session_hash TEXT);
                CREATE TABLE sync_operations(user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                  operation_id TEXT NOT NULL,digest TEXT NOT NULL,applied_at INTEGER NOT NULL,PRIMARY KEY(user_id,operation_id));
                CREATE TABLE email_actions(token_hash TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                  kind TEXT NOT NULL,expires_at INTEGER NOT NULL,used INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE jobs(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                  kind TEXT NOT NULL,payload TEXT NOT NULL,status TEXT NOT NULL);
                CREATE TABLE audit(message TEXT);
                CREATE INDEX users_original_time ON users(created_at);
                CREATE TRIGGER users_original_audit AFTER INSERT ON users BEGIN INSERT INTO audit VALUES(new.id); END;
            ''')
            db.execute('INSERT INTO users VALUES(?,?,?,?,?,?,?)', ('old-id', 'OldUser', 'old@example.test', salt, hashed, iterations, 1234))
            if verified:
                db.execute('ALTER TABLE users ADD COLUMN email_verified INTEGER NOT NULL DEFAULT 0')
                db.execute('UPDATE users SET email_verified=1')
            if unknown_column:
                db.execute('ALTER TABLE users ADD COLUMN unknown_future_column TEXT')
            uid = 'orphan' if orphan else 'old-id'
            db.execute('INSERT INTO sessions VALUES(?,?,?)', (token_hash, uid, int(time.time()) + 3600))
            db.execute('INSERT INTO account_workspaces VALUES(?,?,?)', ('old-id', 7, '{"tasks":[{"id":"keep"}]}'))
            db.execute('INSERT INTO push_subscriptions VALUES(?,?,?,?,?)', ('https://push.example.test', 'old-id', '{}', 1, token_hash))
            db.execute('INSERT INTO sync_operations VALUES(?,?,?,?)', ('old-id', 'op', 'digest', 1))
            db.execute('INSERT INTO email_actions VALUES(?,?,?,?,?)', ('mail-token-hash', 'old-id', 'verify', int(time.time()) + 1800, 0))
            db.execute('INSERT INTO jobs VALUES(?,?,?,?,?)', ('old-job', 'old-id', 'understand', '{"prompt":"keep"}', 'succeeded'))
        return salt, hashed, iterations

    def test_migration_preserves_identifiers_hashes_sessions_workspaces_push_and_fk_targets(self):
        for verified in (False, True):
            with self.subTest(email_verified_column=verified), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'legacy.db'
                salt, hashed, iterations = self.legacy(path, verified=verified)
                store = AuthStore(path)
                user = store.authenticate('legacy-token')['user']
                self.assertEqual(user['id'], 'old-id')
                self.assertEqual(user['emailVerified'], verified)
                self.assertTrue(user['hasPassword'])
                self.assertIsNone(user['phone'])
                self.assertEqual(store.login({'identifier': 'OLD@example.test', 'password': PASSWORD})['user']['id'], 'old-id')
                AuthStore(path)  # Idempotent restart must not rebuild/cascade again.
                with store.connection() as db:
                    row = db.execute('SELECT * FROM users').fetchone()
                    self.assertEqual((row['salt'], row['password_hash'], row['iterations']), (salt, hashed, iterations))
                    self.assertEqual(db.execute('SELECT revision,body FROM account_workspaces').fetchone()[0], 7)
                    for table in ('push_subscriptions', 'sync_operations', 'email_actions', 'jobs'):
                        self.assertEqual(db.execute(f'SELECT count(*) FROM {table}').fetchone()[0], 1)
                        self.assertIn('users', [row[2] for row in db.execute(f'PRAGMA foreign_key_list({table})')])
                    self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(), [])
                    columns = {row[1]: row[3] for row in db.execute('PRAGMA table_info(users)')}
                    for name in ('email', 'salt', 'password_hash'):
                        self.assertEqual(columns[name], 0)
                    self.assertEqual(db.execute('SELECT version FROM auth_schema_migrations').fetchone()[0], 2)
                    self.assertIsNotNone(db.execute("SELECT 1 FROM sqlite_master WHERE name='users_original_time'").fetchone())
                    self.assertIsNotNone(db.execute("SELECT 1 FROM sqlite_master WHERE name='users_original_audit'").fetchone())
                    self.assertEqual(db.execute('SELECT count(*) FROM audit').fetchone()[0], 1)

    def test_migration_refuses_unknown_schema_and_bad_foreign_keys_without_losing_old_data(self):
        for unknown_column, orphan in ((True, False), (False, True)):
            with self.subTest(unknown=unknown_column, orphan=orphan), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'refuse.db'
                self.legacy(path, unknown_column=unknown_column, orphan=orphan)
                with self.assertRaises(sqlite3.DatabaseError):
                    AuthStore(path)
                with closing(sqlite3.connect(path)) as db, db:
                    columns = {row[1]: row[3] for row in db.execute('PRAGMA table_info(users)')}
                    self.assertEqual(columns['email'], 1)
                    self.assertNotIn('phone', columns)
                    self.assertEqual(db.execute('SELECT id FROM users').fetchone()[0], 'old-id')
                    self.assertEqual(db.execute('SELECT count(*) FROM sessions').fetchone()[0], 1)
                    self.assertIsNone(db.execute("SELECT 1 FROM sqlite_master WHERE name='users_identity_v2'").fetchone())

    def test_concurrent_process_style_initialization_migrates_once(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'concurrent.db'
            self.legacy(path)
            barrier, errors = threading.Barrier(2), []

            def initialize():
                try:
                    barrier.wait(timeout=5)
                    AuthStore(path)
                except Exception as error:
                    errors.append(repr(error))
            threads = [threading.Thread(target=initialize) for _ in range(2)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=15)
                self.assertFalse(thread.is_alive())
            self.assertEqual(errors, [])
            self.assertEqual(AuthStore(path).authenticate('legacy-token')['user']['id'], 'old-id')


if __name__ == '__main__':
    unittest.main()
