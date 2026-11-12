"""Inspect a source/build archive without printing any credential contents."""
import argparse
import io
import json
from pathlib import Path
import re
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def private_name(name):
    parts = Path(name).parts
    file = parts[-1] if parts else ''
    return (any(p in ('.local', '.venv', '__pycache__', 'mail') for p in parts)
        or file in ('local.properties', 'key.properties', '.flutter-plugins-dependencies')
        or file.lower() == 'accesskey.txt'
        or file.startswith('.env') and file != '.env.example'
        or '.sqlite3' in file
        or file.endswith(('.env', '.session-secret', '.pem', '.jks', '.keystore', '.eml', 'api.txt')))


def inspect(archive, *, secret=None, additional_secrets=(), prefix='', depth=0):
    errors = []
    total = 0
    for info in archive.infolist():
        name = prefix + info.filename
        if info.is_dir():
            continue
        if private_name(info.filename):
            errors.append({'file': name, 'reason': 'private runtime/configuration file'})
        if info.file_size > 512 * 1024 * 1024:
            errors.append({'file': name, 'reason': 'unexpected oversized entry'})
            continue
        total += info.file_size
        if total > 2 * 1024 * 1024 * 1024:
            raise ValueError('Archive uncompressed size exceeds inspection limit')
        data = archive.read(info)
        if secret and secret in data:
            errors.append({'file': name, 'reason': 'configured API credential present'})
        if any(value in data for value in additional_secrets):
            errors.append({'file': name, 'reason': 'configured private credential present'})
        if re.search(rb'-----BEGIN (?:RSA |EC )?PRIVATE KEY-----', data):
            # Application source may name PEM delimiters in a parser. Only
            # material shaped like a complete PEM block is a credential.
            if re.search(rb'-----BEGIN (?:RSA |EC )?PRIVATE KEY-----\s+[A-Za-z0-9+/=\r\n]{80,}-----END', data):
                errors.append({'file': name, 'reason': 'private key material'})
        if depth < 2 and info.filename.endswith(('.apk', '.aab')):
            with zipfile.ZipFile(io.BytesIO(data)) as nested:
                errors.extend(inspect(nested, secret=secret, additional_secrets=additional_secrets,
                                      prefix=name + '!/', depth=depth + 1))
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, default=ROOT.parent / 'SERA-Flutter-Fullstack-v2.zip')
    parser.add_argument('--secret-file', type=Path)
    parser.add_argument('--private-env-file', type=Path, action='append', default=[],
                        help='Inspect exact private credential bytes; repeat for SMTP/SMS files. Values are never printed.')
    parser.add_argument('--report', type=Path, default=ROOT / 'docs/qa/delivery-scan.json')
    args = parser.parse_args()
    secret = None
    additional_secrets = ()
    smtp_checked = False
    sms_checked = False
    if args.secret_file:
        sys.path.insert(0, str(ROOT / 'backend'))
        from server import load_api_key
        secret = load_api_key(str(args.secret_file)).encode('utf-8')
        if not secret:
            raise ValueError('Configured credential could not be read; inspection stopped')
    if args.private_env_file:
        from serve import load_private_environments
        private_config = load_private_environments(args.private_env_file)
        smtp_password = private_config.get('SMTP_PASSWORD', '')
        sms_values = [private_config.get(key, '') for key in (
            'SERA_SMS_ACCESS_KEY_ID', 'SERA_SMS_ACCESS_KEY_SECRET',
            'SERA_SMS_SECURITY_TOKEN',
        )]
        configured_values = [smtp_password, *sms_values]
        # Authorized test phone numbers are private configuration too.
        configured_values.extend(private_config.get(
            'SERA_SMS_ALLOWED_TEST_PHONES', '').split(','))
        additional_secrets = tuple({value.strip().encode('utf-8')
                                    for value in configured_values if value.strip()})
        if not additional_secrets:
            raise ValueError('No configured private credential could be read; inspection stopped')
        smtp_checked = bool(smtp_password)
        sms_checked = any(sms_values)
    with zipfile.ZipFile(args.archive) as archive:
        errors = inspect(archive, secret=secret, additional_secrets=additional_secrets)
        entries = len(archive.infolist())
    report = {'archive': args.archive.name, 'entries': entries,
        'credentialExactMatchChecked': bool(secret), 'nestedApkAndAabInspected': True,
        'smtpCredentialExactMatchChecked': smtp_checked,
        'smsCredentialExactMatchChecked': sms_checked,
        'status': 'failed' if errors else 'passed', 'findings': errors}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'status': report['status'], 'entries': entries, 'findingCount': len(errors)}))
    if errors:
        for error in errors:
            print(error['file'] + ': ' + error['reason'])
        raise SystemExit(1)


if __name__ == '__main__':
    main()
