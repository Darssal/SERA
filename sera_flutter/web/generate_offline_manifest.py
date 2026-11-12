"""Hash a completed local Flutter Web build for atomic SERA offline caching.

Run after flutter build web --release --no-web-resources-cdn:
  python web/generate_offline_manifest.py build/web
No source credentials, API data or private deployment files are included.
"""
import hashlib
import json
from pathlib import Path
import re
import sys


def generate(directory):
    root = Path(directory).resolve()
    if root == Path(__file__).resolve().parent:
        raise ValueError('Expected a completed build output, not the web source directory')
    bootstrap = root / 'flutter_bootstrap.js'
    if not bootstrap.is_file():
        raise ValueError('Completed Flutter Web build is missing flutter_bootstrap.js')
    source = bootstrap.read_text(encoding='utf-8')
    match = re.search(r'_flutter\.buildConfig\s*=\s*', source)
    if not match:
        raise ValueError('Flutter bootstrap build configuration was not found')
    config, _ = json.JSONDecoder().raw_decode(source[match.end():])
    if not config.get('useLocalCanvasKit'):
        raise ValueError('Build with --no-web-resources-cdn; offline runtime must be local')
    renderers = {build.get('renderer') for build in config.get('builds', []) if build}
    # Flutter copies the web source directory into the build. This host-side
    # generator and Python import caches must never become public Web assets.
    # Delete individual files only after validating the completed output, and
    # reject symlinks escaping the explicitly supplied absolute output root.
    for file in list(root.rglob('*')):
        if file.is_file() and (file.suffix in ('.py', '.pyc') or '__pycache__' in file.relative_to(root).parts):
            if root not in file.resolve().parents:
                raise ValueError('Build cleanup path escapes the output directory')
            file.unlink()
    for folder in sorted(root.rglob('__pycache__'), key=lambda path: len(path.parts), reverse=True):
        if folder.is_dir() and not any(folder.iterdir()):
            if root not in folder.resolve().parents:
                raise ValueError('Build cleanup directory escapes the output directory')
            folder.rmdir()
    resources = []
    for file in sorted(root.rglob('*')):
        if not file.is_file():
            continue
        relative = file.relative_to(root).as_posix()
        if (any(part.startswith('.') for part in file.relative_to(root).parts) or file.suffix in ('.py', '.pyc', '.symbols', '.tmp')
                or '__pycache__' in file.parts
                or relative in ('sera-cache-manifest.json', 'flutter_service_worker.js')):
            continue
        if root not in file.resolve().parents:
            raise ValueError('Build resource symlink escapes the output directory')
        # dart2js/CanvasKit never loads the unused skwasm/wimp engines. Keep
        # full/chromium/webparagraph CanvasKit variants and every app asset.
        if renderers == {'canvaskit'} and relative.startswith('canvaskit/') and file.name.startswith(('skwasm', 'wimp')):
            continue
        data = file.read_bytes()
        resources.append({'path': relative, 'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)})
    required = {'index.html', 'flutter_bootstrap.js', 'main.dart.js', 'sera-platform.js',
                'sera-sw.js', 'assets/FontManifest.json', 'assets/AssetManifest.bin',
                'canvaskit/canvaskit.js', 'canvaskit/canvaskit.wasm'}
    missing = required - {resource['path'] for resource in resources}
    if missing:
        raise ValueError('Offline build is missing required resources: ' + ', '.join(sorted(missing)))
    version = hashlib.sha256(json.dumps(resources, ensure_ascii=False, sort_keys=True,
                                       separators=(',', ':')).encode()).hexdigest()
    manifest = {'schemaVersion': 1, 'version': version, 'resources': resources,
                'totalBytes': sum(item['bytes'] for item in resources)}
    output = root / 'sera-cache-manifest.json'
    temporary = output.with_suffix('.json.tmp')
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')
    temporary.replace(output)
    print('SERA offline manifest: ' + str(len(resources)) + ' files, '
          + str(round(manifest['totalBytes'] / 1024 / 1024, 2)) + ' MiB, version ' + version[:12])
    return manifest


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: python web/generate_offline_manifest.py build/web')
    generate(sys.argv[1])
