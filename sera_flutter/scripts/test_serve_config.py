"""Private stack configuration parser tests; no service, Flutter or ADB runs."""
import importlib.util
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


SPEC = importlib.util.spec_from_file_location('sera_stack_serve', Path(__file__).with_name('serve.py'))
serve = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(serve)


class PrivateEnvironmentTest(unittest.TestCase):
    def parse(self, text):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'private.env'
            path.write_text(text, encoding='utf-8')
            return serve.load_private_environment(path)

    def assert_safe_failure(self, text):
        with self.assertRaises(serve.PrivateEnvironmentError) as raised:
            self.parse(text)
        self.assertNotIn('synthetic-secret', str(raised.exception))
        self.assertNotIn('SMTP_PASSWORD', str(raised.exception))
        return str(raised.exception)

    def test_allowlisted_configuration_with_comments_bom_and_quotes(self):
        result = self.parse('\ufeff# private sample\r\n\nSMTP_HOST = smtp.example.test\n'
                            'SMTP_PORT=465\nSMTP_TLS=ssl\nSMTP_USERNAME="sender@example.test"\n'
                            "SMTP_PASSWORD='synthetic-secret#with=equals'\n"
                            "SMTP_FROM='SERA <sender@example.test>'\n"
                            'SERA_MAIL_MODE=smtp\nSERA_PUBLIC_ORIGIN=http://127.0.0.1:8788\n')
        self.assertEqual(set(result), {
            'SMTP_HOST', 'SMTP_PORT', 'SMTP_TLS', 'SMTP_USERNAME',
            'SMTP_PASSWORD', 'SMTP_FROM', 'SERA_MAIL_MODE', 'SERA_PUBLIC_ORIGIN',
        })
        self.assertEqual(result['SMTP_PASSWORD'], 'synthetic-secret#with=equals')
        self.assertEqual(result['SMTP_FROM'], 'SERA <sender@example.test>')
        self.assertEqual(result['SMTP_PORT'], '465')

    def test_blank_file_is_valid_and_empty_values_are_preserved(self):
        self.assertEqual(self.parse('\n # comment\n'), {})
        self.assertEqual(self.parse('SMTP_USERNAME=\nSMTP_PASSWORD=""\n'),
                         {'SMTP_USERNAME': '', 'SMTP_PASSWORD': ''})

    def test_official_identity_is_explicit_private_configuration(self):
        self.assertEqual(self.parse('SERA_COMMUNITY_OFFICIAL_USER_IDS=owner-a,owner-b'),
                         {'SERA_COMMUNITY_OFFICIAL_USER_IDS': 'owner-a,owner-b'})

    def test_values_are_literal_and_do_not_change_process_environment(self):
        before = os.environ.copy()
        value = '${HOME} $(synthetic-secret) `literal` # still a value'
        self.assertEqual(self.parse('SMTP_PASSWORD=' + value)['SMTP_PASSWORD'], value)
        self.assertEqual(dict(os.environ), before)

    def test_unknown_keys_are_rejected_without_echoing_source(self):
        message = self.assert_safe_failure('SYNTHETIC_PRIVATE_KEY=synthetic-secret')
        self.assertNotIn('SYNTHETIC_PRIVATE_KEY', message)
        self.assertIn('line 1', message)

    def test_duplicate_keys_are_rejected_without_echoing_values(self):
        message = self.assert_safe_failure('SMTP_PASSWORD=first\nSMTP_PASSWORD=synthetic-secret')
        self.assertIn('line 2', message)

    def test_bad_assignment_formats_are_rejected(self):
        for source in ('export SMTP_PASSWORD=synthetic-secret', 'SMTP_PASSWORD synthetic-secret',
                       '=synthetic-secret', 'smtp_password=synthetic-secret'):
            with self.subTest(source_kind=source.split('=', 1)[0]):
                self.assert_safe_failure(source)

    def test_mismatched_or_unterminated_quotes_are_rejected(self):
        for value in ('"synthetic-secret', "'synthetic-secret\"", 'synthetic-secret"',
                      '"synthetic-secret"trailing"'):
            with self.subTest(quote=value[:1]):
                self.assert_safe_failure('SMTP_PASSWORD=' + value)

    def test_multiline_and_control_characters_are_rejected(self):
        for value in ('synthetic-secret\x00extra', 'synthetic-secret\rextra',
                      '"synthetic-secret\nsecond line"'):
            self.assert_safe_failure('SMTP_PASSWORD=' + value)

    def test_missing_file_has_safe_diagnostic(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(serve.PrivateEnvironmentError,
                                        '^Cannot read private environment file\\.$'):
                serve.load_private_environment(Path(directory) / 'synthetic-secret.env')

    def test_oversized_file_is_rejected_before_parsing(self):
        with self.assertRaisesRegex(serve.PrivateEnvironmentError, 'size limit'):
            self.parse('SMTP_PASSWORD=' + 'x' * serve.PRIVATE_ENV_MAX_BYTES)

    def test_invalid_utf8_has_safe_diagnostic(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'private.env'
            path.write_bytes(b'SMTP_PASSWORD=\xffsynthetic-secret')
            with self.assertRaisesRegex(serve.PrivateEnvironmentError, 'must use UTF-8'):
                serve.load_private_environment(path)


    def test_sms_example_is_explicitly_allowlisted_without_enabling_it(self):
        path = Path(__file__).resolve().parents[1] / 'backend/sms-auth.env.example'
        before = os.environ.copy()
        config = serve.load_private_environment(path)
        self.assertEqual(config['SERA_SMS_AUTH_ENABLED'], 'false')
        self.assertEqual(config['SERA_SMS_ACCESS_KEY_SECRET'], '')
        self.assertTrue(set(config).issubset(serve.PRIVATE_ENV_KEYS))
        self.assertEqual(dict(os.environ), before)

    def test_multiple_files_merge_in_explicit_order(self):
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / 'first.env'
            second = Path(directory) / 'second.env'
            first.write_text('SMTP_PASSWORD=synthetic-first\nSERA_SMS_AUTH_ENABLED=false')
            second.write_text('SERA_SMS_ACCESS_KEY_SECRET=synthetic-secret\nSERA_SMS_AUTH_ENABLED=true')
            config = serve.load_private_environments([first, second])
            self.assertEqual(config['SMTP_PASSWORD'], 'synthetic-first')
            self.assertEqual(config['SERA_SMS_ACCESS_KEY_SECRET'], 'synthetic-secret')
            self.assertEqual(config['SERA_SMS_AUTH_ENABLED'], 'true')
            self.assertEqual(serve.load_private_environments([second, first])[
                'SERA_SMS_AUTH_ENABLED'], 'false')

    def test_later_file_failure_never_mutates_the_process_environment(self):
        before = os.environ.copy()
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / 'first.env'
            second = Path(directory) / 'second.env'
            first.write_text('SMTP_PASSWORD=synthetic-secret')
            second.write_text('UNRECOGNIZED=synthetic-secret')
            with self.assertRaises(serve.PrivateEnvironmentError):
                serve.load_private_environments([first, second])
        self.assertEqual(dict(os.environ), before)


class StackModelConfigurationTest(unittest.TestCase):
    def test_explicit_model_reaches_warmup_api_and_worker_together(self):
        factory = Mock(return_value=object())
        child = Mock()
        child.poll.return_value = 0
        with tempfile.TemporaryDirectory() as directory:
            args = ['serve.py', '--no-asr', '--db', str(Path(directory) / 'test.sqlite3'),
                    '--ai-model', 'zai-org/GLM-5.3-Flash']
            with patch('sys.argv', args), patch.dict('sys.modules', {
                    'app': SimpleNamespace(create_app=factory)}), \
                    patch.object(serve.subprocess, 'Popen', return_value=child) as launch, \
                    patch.object(serve.signal, 'signal'), patch('builtins.print'):
                with self.assertRaisesRegex(RuntimeError, 'stack service exited'):
                    serve.main()
        self.assertEqual(factory.call_args.kwargs['ai_model'], 'zai-org/GLM-5.3-Flash')
        self.assertEqual(launch.call_count, 2)
        commands = [call.args[0][1] for call in launch.call_args_list]
        self.assertEqual(commands, ['backend/server.py', 'backend/worker.py'])
        for call in launch.call_args_list:
            self.assertEqual(call.kwargs['env']['SILICONFLOW_MODEL'], 'zai-org/GLM-5.3-Flash')


if __name__ == '__main__':
    unittest.main(verbosity=2)
