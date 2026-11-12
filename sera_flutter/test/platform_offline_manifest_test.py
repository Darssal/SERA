"""Build-output manifest tests; no Flutter process or device access."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('offline_manifest', Path(__file__).resolve().parents[1] / 'web/generate_offline_manifest.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ManifestTest(unittest.TestCase):
    def fixture(self, root, local=True):
        files = ['index.html', 'main.dart.js', 'sera-platform.js', 'sera-sw.js',
                 'assets/FontManifest.json', 'assets/AssetManifest.bin',
                 'canvaskit/canvaskit.js', 'canvaskit/canvaskit.wasm',
                 'assets/assets/icons/icon-refresh.svg', 'assets/assets/fonts/chinese.ttf',
                 'canvaskit/skwasm.wasm', 'canvaskit/canvaskit.js.symbols', '.local/private.txt']
        for name in files:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name, encoding='utf-8')
        (root / 'flutter_bootstrap.js').write_text('_flutter.buildConfig = ' + json.dumps({'useLocalCanvasKit': local, 'builds': [{'renderer': 'canvaskit'}]}) + ';', encoding='utf-8')

    def test_all_runtime_and_assets_hashed_and_changes_create_new_version(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            first = module.generate(root)
            self.assertEqual(first['version'], module.generate(root)['version'])
            names = {item['path'] for item in first['resources']}
            self.assertIn('assets/assets/fonts/chinese.ttf', names)
            self.assertIn('assets/assets/icons/icon-refresh.svg', names)
            self.assertNotIn('canvaskit/skwasm.wasm', names)
            self.assertNotIn('canvaskit/canvaskit.js.symbols', names)
            self.assertNotIn('.local/private.txt', names)
            (root / 'main.dart.js').write_text('new release', encoding='utf-8')
            self.assertNotEqual(first['version'], module.generate(root)['version'])

    def test_remote_canvas_runtime_and_incomplete_build_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root, local=False)
            with self.assertRaisesRegex(ValueError, 'no-web-resources-cdn'):
                module.generate(root)
            self.fixture(root)
            (root / 'main.dart.js').unlink()
            with self.assertRaisesRegex(ValueError, 'missing required'):
                module.generate(root)

    def test_host_python_files_are_removed_from_completed_output_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            first = module.generate(root)
            copied = root / 'generate_offline_manifest.py'
            bytecode = root / '__pycache__/generate_offline_manifest.cpython-311.pyc'
            copied.write_text('host-only tool', encoding='utf-8')
            bytecode.parent.mkdir()
            bytecode.write_bytes(b'host-only bytecode')
            second = module.generate(root)
            self.assertFalse(copied.exists())
            self.assertFalse(bytecode.parent.exists())
            self.assertTrue(Path(module.__file__).is_file())
            self.assertEqual(first['version'], second['version'])
            with self.assertRaisesRegex(ValueError, 'not the web source'):
                module.generate(Path(module.__file__).parent)


if __name__ == '__main__':
    unittest.main()
