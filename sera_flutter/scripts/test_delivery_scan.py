"""In-memory delivery scanner regressions; never read deployment credentials."""
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import unittest
import zipfile


SPEC = importlib.util.spec_from_file_location(
    'sera_delivery_scanner', Path(__file__).with_name('verify-delivery.py'))
scanner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scanner)

# Deliberately synthetic byte sequences, passed directly to inspect. No real
# environment, secret file, local database or service is consulted by this file.
AI = b'qa-synthetic-ai-credential-for-delivery-scan-only'
SMTP = b'qa-synthetic-smtp-password-for-delivery-scan-only'
RAM_ID = b'qa-synthetic-ram-access-id-for-delivery-scan-only'
RAM_SECRET = b'qa-synthetic-ram-access-secret-for-delivery-scan-only'
RAM_TOKEN = b'qa-synthetic-ram-session-token-for-delivery-scan-only'
PRIVATE = (SMTP, RAM_ID, RAM_SECRET, RAM_TOKEN)
ALL_SECRETS = (AI, *PRIVATE)


def archive_bytes(entries):
    """Construct an actual ZIP in memory, including nested APK/AAB ZIP data."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in entries.items():
            archive.writestr(name, data)
    return buffer.getvalue()


class DeliveryScanTest(unittest.TestCase):
    def inspect_memory(self, entries):
        stdout, stderr = io.StringIO(), io.StringIO()
        with zipfile.ZipFile(io.BytesIO(archive_bytes(entries))) as archive:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                findings = scanner.inspect(
                    archive, secret=AI, additional_secrets=PRIVATE)
        report = json.dumps(findings, ensure_ascii=False).encode('utf-8')
        emitted = (stdout.getvalue() + stderr.getvalue()).encode('utf-8')
        # Boolean assertions avoid echoing even the synthetic values if the
        # scanner accidentally leaks a credential in a future regression.
        self.assertFalse(any(secret in report for secret in ALL_SECRETS),
                         'Findings must never contain configured credential values.')
        self.assertFalse(any(secret in emitted for secret in ALL_SECRETS),
                         'Console output must never contain configured credential values.')
        self.assertTrue(not emitted, 'inspect must remain a silent inspection function.')
        return findings

    def test_exact_ai_credential_is_reported_without_its_value(self):
        findings = self.inspect_memory({
            'sera_flutter/build/web/main.dart.js': b'prefix:' + AI + b':suffix',
        })
        self.assertIn({
            'file': 'sera_flutter/build/web/main.dart.js',
            'reason': 'configured API credential present',
        }, findings)

    def test_each_exact_smtp_and_ram_credential_is_reported_without_its_value(self):
        for kind, secret in zip(('smtp', 'ram_id', 'ram_secret', 'ram_token'), PRIVATE):
            with self.subTest(credential_kind=kind):
                findings = self.inspect_memory({
                    'assets/runtime.bin': b'\x00before\x00' + secret + b'\x00after',
                })
                self.assertIn({
                    'file': 'assets/runtime.bin',
                    'reason': 'configured private credential present',
                }, findings)

    def test_multiple_credentials_in_one_entry_retain_safe_finding_reasons(self):
        findings = self.inspect_memory({
            'assets/runtime.json': b'\n'.join(ALL_SECRETS),
        })
        self.assertEqual({finding['reason'] for finding in findings}, {
            'configured API credential present',
            'configured private credential present',
        })

    def test_nested_apk_and_aab_are_recursively_inspected_in_both_orders(self):
        for outer_suffix, inner_suffix in (('apk', 'aab'), ('aab', 'apk')):
            with self.subTest(outer=outer_suffix, inner=inner_suffix):
                leaf = archive_bytes({'assets/runtime.bin': b'\n'.join(ALL_SECRETS)})
                package = archive_bytes({f'embedded.{inner_suffix}': leaf})
                findings = self.inspect_memory({f'release.{outer_suffix}': package})
                leaf_path = (f'release.{outer_suffix}!/embedded.{inner_suffix}'
                             '!/assets/runtime.bin')
                self.assertIn({'file': leaf_path,
                               'reason': 'configured API credential present'}, findings)
                self.assertIn({'file': leaf_path,
                               'reason': 'configured private credential present'}, findings)

    def test_nested_package_runtime_env_is_rejected(self):
        package = archive_bytes({'assets/sms-auth.env': b'SERA_SMS_AUTH_ENABLED=false\n'})
        findings = self.inspect_memory({'release.apk': package})
        self.assertIn({'file': 'release.apk!/assets/sms-auth.env',
                       'reason': 'private runtime/configuration file'}, findings)

    def test_all_private_env_suffixes_are_rejected_by_filename(self):
        for name in ('smtp.env', 'sms-auth.env', 'provider.env', '.env',
                     '.env.production', 'config/credentials.env',
                     'sera_flutter/backend/private-settings.env',
                     'accesskey.txt', 'backend/ACCESSKEY.txt'):
            with self.subTest(entry=name):
                findings = self.inspect_memory({name: b'PLACEHOLDER=non-secret\n'})
                self.assertIn({'file': name,
                               'reason': 'private runtime/configuration file'}, findings)

    def test_public_env_examples_are_preserved(self):
        entries = {name: b'SERA_SMS_AUTH_ENABLED=false\nSERA_SMS_ACCESS_KEY_SECRET=\n'
                   for name in ('.env.example', 'smtp.env.example',
                                'sms-auth.env.example',
                                'sera_flutter/backend/sms-auth.env.example')}
        self.assertEqual(self.inspect_memory(entries), [])

    def test_clean_source_and_nested_build_archive_succeeds(self):
        apk = archive_bytes({'AndroidManifest.xml': b'<manifest package="example.qa"/>',
                             'assets/flutter_assets/notice.txt': b'Public application assets.'})
        aab = archive_bytes({'base/manifest/AndroidManifest.xml': b'Public manifest.'})
        self.assertEqual(self.inspect_memory({
            'sera_flutter/lib/main.dart': b'void main() {}\n',
            'sera_flutter/backend/sms-auth.env.example': b'SERA_SMS_AUTH_ENABLED=false\n',
            'sera_flutter/README.md': b'Public setup documentation.\n',
            'sera_flutter/build/app-release.apk': apk,
            'sera_flutter/build/app-release.aab': aab,
        }), [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
