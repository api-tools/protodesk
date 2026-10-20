#!/usr/bin/env python3
"""Run new source compilation/cache flows inside the actual macOS sandbox.

Local fixture is always offline. --github additionally enables an opt-in public
HTTPS acquisition check; CI need not depend on a live GitHub service.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def run(executable, directory, config, *, offline=False):
    env = os.environ.copy()
    for name in tuple(env):
        if name.startswith('PROTODESK_SMOKE_'):
            env.pop(name)
    env['PROTODESK_DATA_DIR'] = str(directory)
    env['PROTODESK_SMOKE_SOURCES'] = json.dumps(config)
    env['PROTODESK_SMOKE_SOURCES_OFFLINE'] = '1' if offline else '0'
    result = subprocess.run([str(executable)], env=env, text=True, capture_output=True, timeout=120, check=True)
    for line in result.stdout.splitlines():
        if line.startswith('SOURCE_SMOKE_RESULT='):
            return json.loads(line.split('=', 1)[1])
    raise RuntimeError('Source smoke result missing: ' + result.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    parser.add_argument('--github', action='store_true')
    args = parser.parse_args()
    parent = Path.home() / 'Library/Application Support/ProtoDesk' if os.sys.platform == 'darwin' else None
    if parent:
        parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='source-package-smoke-', dir=parent) as temporary:
        directory = Path(temporary)
        root = directory / 'fixture'
        (root / 'services').mkdir(parents=True)
        (root / 'common').mkdir()
        (root / 'google/protobuf').mkdir(parents=True)
        standard = Path(__file__).resolve().parent.parent / 'assets/protoc/include/google/protobuf/empty.proto'
        (root / 'google/protobuf/empty.proto').write_bytes(standard.read_bytes())
        (root / 'common/types.proto').write_text('syntax="proto3"; import "google/protobuf/empty.proto"; package fixture; message Empty { google.protobuf.Empty value=1; }')
        (root / 'services/api.proto').write_text('syntax="proto3"; import public \'common/types.proto\'; package fixture; service Echo { rpc Call(Empty) returns (Empty); }')
        config = {'version': 1, 'sources': [{'type': 'directory', 'path': str(root), 'entries': ['services/api.proto']}], 'importRoots': [str(root)]}
        result = run(args.executable.resolve(), directory, config, offline=True)
        assert result['validation']['services'] == 1
        assert result['validation']['dependencies'] == 2
        print('Packaged sandbox local sources / independent roots / single-quoted public import / vendored WKT: PASS')
        if args.github:
            config = {'version': 1, 'sources': [{'type': 'git', 'url': 'https://github.com/grpc/grpc-proto', 'ref': 'master', 'directory': 'grpc/reflection/v1', 'roots': [''], 'entries': ['reflection.proto']}], 'importRoots': []}
            result = run(args.executable.resolve(), directory, config)
            assert len(result['configuration']['sources'][0]['commit']) == 40
            offline = run(args.executable.resolve(), directory, result['configuration'], offline=True)
            assert offline['validation']['services'] == result['validation']['services']
            print('Packaged sandbox GitHub acquisition / cached offline startup: PASS')
        assert not (directory / 'protodesk.sqlite').exists(), 'Smoke must not seed application data'


if __name__ == '__main__':
    main()
