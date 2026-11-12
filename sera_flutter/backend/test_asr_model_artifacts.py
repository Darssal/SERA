"""Runtime/download/package contract for the official mixed-precision model."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import download_asr_model as download
import local_asr

spec = importlib.util.spec_from_file_location('package_asr_models', Path(__file__).resolve().parents[1] / 'scripts/package-models.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class AsrModelArtifactTests(unittest.TestCase):
    def fixture(self, directory):
        root = Path(directory)
        checksums = {}
        for name in download.RUNTIME_FILES:
            data = ('fixture:' + name).encode()
            (root / name).write_bytes(data)
            checksums[name] = hashlib.sha256(data).hexdigest()
        (root / 'decoder-epoch-99-avg-1.int8.onnx').write_bytes(b'legacy decoder must never be selected')
        (root / 'manifest.json').write_text(json.dumps({'archiveSha256': download.SHA256, 'files': checksums}))
        return root, checksums

    def test_legacy_int8_decoder_cannot_silently_replace_missing_float_decoder(self):
        with tempfile.TemporaryDirectory() as directory:
            model, checksums = self.fixture(directory)
            (model / 'decoder-epoch-99-avg-1.onnx').unlink()
            factory = Mock()
            with patch.object(local_asr, 'RUNTIME_SHA256', checksums), patch.dict(sys.modules, {'sherpa_onnx': SimpleNamespace(OnlineRecognizer=SimpleNamespace(from_transducer=factory))}):
                with self.assertRaisesRegex(ValueError, 'decoder.float'):
                    local_asr.StreamingRecognizer(model)
            factory.assert_not_called()
            with patch.object(package, 'RUNTIME_SHA256', checksums):
                with self.assertRaisesRegex(ValueError, 'decoder-epoch-99-avg-1.onnx'):
                    package.verified_runtime_files(model)

    def test_verified_runtime_and_package_use_float_decoder_excluding_retained_legacy_file(self):
        with tempfile.TemporaryDirectory() as directory:
            model, checksums = self.fixture(directory)
            factory = Mock(return_value=object())
            with patch.object(local_asr, 'RUNTIME_SHA256', checksums), patch.dict(sys.modules, {'sherpa_onnx': SimpleNamespace(OnlineRecognizer=SimpleNamespace(from_transducer=factory))}):
                local_asr.StreamingRecognizer(model)
            self.assertEqual(Path(factory.call_args.kwargs['decoder']).name, 'decoder-epoch-99-avg-1.onnx')
            with patch.object(package, 'RUNTIME_SHA256', checksums):
                files, verified = package.verified_runtime_files(model)
            self.assertEqual(set(verified), set(download.RUNTIME_FILES))
            self.assertNotIn('decoder-epoch-99-avg-1.int8.onnx', [file.name for file in files])

    def test_tampered_float_decoder_rejected_by_runtime_and_packager(self):
        with tempfile.TemporaryDirectory() as directory:
            model, checksums = self.fixture(directory)
            (model / 'decoder-epoch-99-avg-1.onnx').write_bytes(b'changed')
            with patch.object(local_asr, 'RUNTIME_SHA256', checksums):
                with self.assertRaisesRegex(ValueError, 'integrity check failed'):
                    local_asr.StreamingRecognizer(model)
            with patch.object(package, 'RUNTIME_SHA256', checksums):
                with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                    package.verified_runtime_files(model)

    def test_checksum_verified_download_extracts_official_combination_and_excludes_old_decoder_from_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory)
            model = destination / download.NAME
            model.mkdir()
            (model / 'decoder-epoch-99-avg-1.int8.onnx').write_bytes(b'keep local legacy file')
            hashes = {}
            archive = destination / (download.NAME + '.tar.bz2')
            with tarfile.open(archive, 'w:bz2') as bundle:
                for name in (*download.RUNTIME_FILES, 'decoder-epoch-99-avg-1.int8.onnx'):
                    data = ('archive:' + name).encode()
                    hashes[name] = hashlib.sha256(data).hexdigest()
                    member = tarfile.TarInfo(download.NAME + '/' + name)
                    member.size = len(data)
                    bundle.addfile(member, io.BytesIO(data))
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            with patch.object(download, 'SHA256', digest), patch.object(download, 'RUNTIME_SHA256', hashes), patch.object(download, 'urlopen', side_effect=AssertionError('No network expected')):
                self.assertEqual(download.download(destination), model)
            manifest = json.loads((model / 'manifest.json').read_text())
            self.assertEqual(set(manifest['runtimeFiles']), set(download.RUNTIME_FILES))
            self.assertNotIn('decoder-epoch-99-avg-1.int8.onnx', manifest['files'])
            self.assertEqual((model / 'decoder-epoch-99-avg-1.int8.onnx').read_bytes(), b'keep local legacy file')
            self.assertEqual(manifest['files']['decoder-epoch-99-avg-1.onnx'], hashes['decoder-epoch-99-avg-1.onnx'])


if __name__ == '__main__':
    unittest.main()
