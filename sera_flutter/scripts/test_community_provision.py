import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('provision_community', Path(__file__).with_name('provision-community-official.py'))
provision = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(provision)


class ProvisionTest(unittest.TestCase):
    def test_new_official_is_unverified_and_private_credentials_are_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            db_path = root / 'test.sqlite3'
            sqlite3.connect(db_path).close()
            credentials, created = provision.provision(db_path, root / 'private', '序日官方', 'official@sera.example')
            self.assertTrue(created)
            original = credentials.read_bytes()
            saved = json.loads(original)
            auth = provision.AuthStore(db_path)
            session = auth.login({'identifier': saved['username'], 'password': saved['password']})
            self.assertFalse(session['user']['emailVerified'])
            auth.logout(session['token'])
            with auth.connection() as connection:
                self.assertEqual(connection.execute('SELECT count(*) FROM sessions').fetchone()[0], 0)
                self.assertEqual(connection.execute('SELECT count(*) FROM email_actions').fetchone()[0], 0)
            _, created_again = provision.provision(db_path, root / 'private', '序日官方', 'official@sera.example')
            self.assertFalse(created_again)
            self.assertEqual(credentials.read_bytes(), original)
            self.assertEqual((root / 'private/official.env').read_text().strip(),
                             'SERA_COMMUNITY_OFFICIAL_USER_IDS=' + saved['userId'])
            self.assertEqual(len(list((root / 'private').glob('before-official-*.sqlite3'))), 1)


if __name__ == '__main__':
    unittest.main()
