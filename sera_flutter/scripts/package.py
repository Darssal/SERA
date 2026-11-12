"""Create a source + optional tested builds delivery without local secrets/data."""
import argparse
from pathlib import Path
import hashlib
import zipfile

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = {'.git', '.dart_tool', '.gradle', 'build', '__pycache__', '.idea', '.pub-cache', '.venv', '.local', 'models', 'mail'}


def source_files():
    for path in ROOT.rglob('*'):
        relative = path.relative_to(ROOT)
        if any(part in EXCLUDED for part in relative.parts) or not path.is_file():
            continue
        if (path.name in ('local.properties', 'key.properties', '.flutter-plugins-dependencies', 'GeneratedPluginRegistrant.java') or path.name.lower() == 'accesskey.txt' or path.name.startswith('.env') and path.name != '.env.example'
                or '.sqlite3' in path.name or path.name.endswith(('.env', '.pyc', '.key', '.keystore', '.jks', '.zip', 'api.txt', '.log', '.pem', '.session-secret', '.db', '.eml'))):
            continue
        yield path, 'sera_flutter/' + relative.as_posix()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT.parent / 'SERA-Flutter-Fullstack-v2.zip')
    parser.add_argument('--include-builds', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve()
    files = list(source_files())
    instructions = ROOT.parent / 'AGENTS.md'
    if instructions.is_file():
        files.append((instructions, 'AGENTS.md'))
    if args.include_builds:
        web = ROOT / 'build' / 'web'
        if not (web / 'index.html').is_file():
            parser.error('Web build missing')
        files.extend((p, 'sera_flutter/build/web/' + p.relative_to(web).as_posix())
                     for p in web.rglob('*') if p.is_file()
                     and '__pycache__' not in p.relative_to(web).parts
                     and p.suffix not in ('.py', '.pyc'))
        for relative in ('app/outputs/flutter-apk/app-release.apk', 'app/outputs/bundle/release/app-release.aab'):
            artifact = ROOT / 'build' / relative
            if not artifact.is_file():
                parser.error(f'Release build missing: {relative}')
            files.append((artifact, 'sera_flutter/build/' + relative))
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path, name in sorted(files, key=lambda entry: entry[1]):
            if path.resolve() != output:
                archive.write(path, name)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(output.suffix + '.sha256').write_text(digest + '  ' + output.name + '\n', encoding='ascii')
    print(f'Packaged {len(files)} files; {output.stat().st_size:,} bytes; SHA256 {digest}')


if __name__ == '__main__':
    main()
