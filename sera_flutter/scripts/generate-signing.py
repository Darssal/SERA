"""Generate a private course signing key without printing passwords."""
from pathlib import Path
import argparse
import os
import secrets
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--keytool', default=shutil.which('keytool'))
    args = parser.parse_args()
    keytool = args.keytool
    if not keytool:
        candidates = [Path(os.environ.get('JAVA_HOME', '')) / 'bin/keytool.exe', Path('D:/development/jdk-21/bin/keytool.exe')]
        keytool = next((str(p) for p in candidates if p.is_file()), None)
    if not keytool:
        parser.error('Install Java 21 or pass --keytool')
    directory = ROOT / '.local/signing'
    directory.mkdir(parents=True, exist_ok=True)
    properties = directory / 'key.properties'
    if properties.exists():
        print('Existing signing configuration retained.')
        return
    keystore = directory / 'sera-release.jks'
    if keystore.exists():
        parser.error('Keystore exists without properties. Restore private configuration; do not replace identity.')
    password_file = directory / 'password.private'
    password = secrets.token_urlsafe(32)
    password_file.write_text(password, encoding='ascii')
    try:
        subprocess.run([keytool, '-genkeypair', '-alias', 'sera-release', '-keyalg', 'RSA', '-keysize', '3072',
            '-validity', '3650', '-storetype', 'JKS', '-keystore', str(keystore),
            '-storepass:file', str(password_file), '-keypass:file', str(password_file),
            '-dname', 'CN=SERA Course Build, OU=Course, O=SERA, C=CN'], check=True, capture_output=True)
        properties.write_text(f'storeFile={keystore.as_posix()}\nstorePassword={password}\nkeyAlias=sera-release\nkeyPassword={password}\n', encoding='ascii')
    finally:
        password_file.unlink(missing_ok=True)
    print('Course release signing key created in .local/signing. Back it up separately from source delivery.')

if __name__ == '__main__':
    main()
