"""Download a pinned official model archive, verify and extract only safe files."""
import argparse
import hashlib
import json
from pathlib import Path
import tarfile
from urllib.request import urlopen

NAME = 'sherpa-onnx-streaming-zipformer-small-bilingual-zh-en-2023-02-16'
SHA256 = '2b7c63322b32e5e0f2526043a1103366119ca58dd615cd7105a37c01db9553d7'
URL = f'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/{NAME}.tar.bz2'
RUNTIME_FILES = ('encoder-epoch-99-avg-1.int8.onnx', 'decoder-epoch-99-avg-1.onnx',
                 'joiner-epoch-99-avg-1.int8.onnx', 'tokens.txt')
RUNTIME_SHA256 = {
    'encoder-epoch-99-avg-1.int8.onnx': 'db6f51551762e40e549166fe041ea3e45464370b595e9ad23f06478ec3794fbb',
    'decoder-epoch-99-avg-1.onnx': '89be509a83175261695bdef5fd1c7b9ab1129a663d1284e7ba9f8507b21e0906',
    'joiner-epoch-99-avg-1.int8.onnx': 'bdda356d6f9b8c2d7cee9ee0e26075fa537490f7fd06520be408d287073667b9',
    'tokens.txt': 'a8e0e4ec53810e433789b54a5c0134a7eaa2ffca595a6334d54c00da858841d3',
}
CONFIGURATION = 'encoder.int8 + decoder.float + joiner.int8'


def download(destination):
    destination = Path(destination).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / (NAME + '.tar.bz2')
    archive_valid = False
    if archive.exists():
        with archive.open('rb') as source:
            archive_valid = hashlib.file_digest(source, 'sha256').hexdigest() == SHA256
    if not archive_valid:
        partial = archive.with_suffix('.partial')
        with urlopen(URL, timeout=120) as response, partial.open('wb') as output:
            while chunk := response.read(1024 * 1024): output.write(chunk)
        with partial.open('rb') as source:
            if hashlib.file_digest(source, 'sha256').hexdigest() != SHA256: raise ValueError('Official model archive checksum does not match pinned release')
        partial.replace(archive)
    with tarfile.open(archive) as source:
        members = []
        for member in source.getmembers():
            target = (destination / member.name).resolve()
            if not target.is_relative_to(destination) or not (member.isfile() or member.isdir()): raise ValueError('Unsafe archive path/type')
            relative = Path(member.name).relative_to(NAME)
            if (len(relative.parts) == 1 and relative.name in (*RUNTIME_FILES, 'bpe.model')
                    or relative.parts and relative.parts[0] == 'test_wavs'):
                members.append(member)
        source.extractall(destination, members=members)
    model = destination / NAME
    checksums = {}
    for file in model.rglob('*'):
        relative = file.relative_to(model)
        if file.is_file() and (len(relative.parts) == 1 and file.name in (*RUNTIME_FILES, 'bpe.model')
                              or relative.parts[0] == 'test_wavs'):
            with file.open('rb') as data: checksums[str(file.relative_to(model)).replace('\\', '/')] = hashlib.file_digest(data, 'sha256').hexdigest()
    for name in RUNTIME_FILES:
        if checksums.get(name) != RUNTIME_SHA256[name]:
            raise ValueError('Official runtime file checksum mismatch: ' + name)
    (model / 'manifest.json').write_text(json.dumps({'source': URL, 'archiveSha256': SHA256,
        'configuration': CONFIGURATION, 'runtimeFiles': list(RUNTIME_FILES), 'files': checksums}, indent=2), encoding='utf-8')
    return model


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--destination', default=str(Path(__file__).with_name('models')))
    args = parser.parse_args()
    print(download(args.destination))
