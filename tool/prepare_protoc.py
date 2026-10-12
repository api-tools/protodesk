#!/usr/bin/env python3
"""Install official, checksum-verified protoc assets for the build host."""
import hashlib
import io
import pathlib
import platform
import urllib.request
import zipfile

BUNDLES = {
    'Darwin': ('osx-universal_binary', '83d0dc80672f53486f54299bca6177159f9cad1fd54d4d3143eeea53c4423e1b'),
    'Linux': ('linux-x86_64', '121f6c7afe1d4d0e3ea6aab9432038599250134cbf4474cb1167d2c7decd4278'),
    'Windows': ('win64', 'f0c128dc0d8492eceece83bb459a4c0e316764b929ffbf1aa416357fd644edd3'),
}
name, expected = BUNDLES[platform.system()]
if platform.system() != 'Darwin' and platform.machine().lower() not in ('x86_64', 'amd64'):
    raise SystemExit('This release configuration targets x64 Windows/Linux; macOS is universal.')
url = f'https://github.com/protocolbuffers/protobuf/releases/download/v36.2/protoc-36.2-{name}.zip'
with urllib.request.urlopen(url, timeout=60) as response:
    payload = response.read(64 * 1024 * 1024)
if hashlib.sha256(payload).hexdigest() != expected:
    raise SystemExit('Official protoc archive checksum mismatch')
root = pathlib.Path(__file__).resolve().parent.parent / 'assets' / 'protoc'
for old in (root / 'bin').glob('protoc*'):
    old.unlink()
with zipfile.ZipFile(io.BytesIO(payload)) as archive:
    for info in archive.infolist():
        if info.is_dir():
            continue
        relative = pathlib.PurePosixPath(info.filename)
        if relative.is_absolute() or '..' in relative.parts:
            raise SystemExit('Unsafe compiler archive member')
        destination = root.joinpath(*relative.parts)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(archive.read(info))
compiler = root / 'bin' / ('protoc.exe' if platform.system() == 'Windows' else 'protoc')
compiler.chmod(0o755)
print(f'Prepared official protoc 36.2 for {name}')
