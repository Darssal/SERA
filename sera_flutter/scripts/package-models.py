"""Package the verified official mixed-precision CPU ASR runtime separately."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'backend'))
from download_asr_model import NAME, SHA256, URL, RUNTIME_FILES, RUNTIME_SHA256, CONFIGURATION


def verified_runtime_files(model):
    manifest = json.loads((model / 'manifest.json').read_text(encoding='utf-8'))
    if manifest.get('archiveSha256') != SHA256:
        raise ValueError('Model source is not the pinned official release')
    files = [model / name for name in RUNTIME_FILES]
    verified = {}
    for path in files:
        if not path.is_file():
            raise ValueError('Required official runtime file missing: ' + path.name)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != RUNTIME_SHA256[path.name] or digest != manifest['files'].get(path.name):
            raise ValueError(f'Model checksum mismatch: {path.name}')
        verified[path.name] = digest
    return files, verified


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT.parent / 'SERA-ASR-CPU-Models-v2.zip')
    args = parser.parse_args()
    model = ROOT / 'backend/models' / NAME
    files, verified = verified_runtime_files(model)
    licenses = ROOT / 'docs/licenses'
    if not (licenses / 'asr-provenance.json').is_file() or not any(licenses.glob('*LICENSE*')):
        raise ValueError('Model attribution and licensing evidence missing')
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in files:
            archive.write(path, f'models/{NAME}/{path.name}')
        archive.writestr(f'models/{NAME}/manifest.json', json.dumps({
            'source': URL, 'archiveSha256': SHA256, 'configuration': CONFIGURATION,
            'runtimeFiles': list(RUNTIME_FILES), 'files': verified,
        }, indent=2))
        for path in licenses.rglob('*'):
            if path.is_file():
                archive.write(path, 'licenses/' + path.relative_to(licenses).as_posix())
        archive.writestr('README.txt', 'SERA CPU streaming ASR model package\n\n'
            'Extract this ZIP inside sera_flutter/backend; it creates models/<model-name>.\n'
            'Official runtime: encoder.int8 + decoder.float + joiner.int8; all hashes pinned.\n'
            'See licenses/ for separate model and runtime attribution.\n'
            'Unused int8 decoder, float encoder/joiner and test recordings are excluded.\n')
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(output.suffix + '.sha256').write_text(digest + '  ' + output.name + '\n', encoding='ascii')
    print(f'{output.name}: {output.stat().st_size:,} bytes; SHA256 {digest}')


if __name__ == '__main__':
    main()
