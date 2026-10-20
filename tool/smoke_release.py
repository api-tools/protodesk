#!/usr/bin/env python3
"""Run dynamic reflection and proto-only calls in the actual desktop release."""
import base64
import os
import pathlib
import socket
import shutil
import subprocess
import sys
import time

root = pathlib.Path(__file__).resolve().parent.parent
compiler = root / 'assets/protoc/bin' / ('protoc.exe' if os.name == 'nt' else 'protoc')
settings = os.environ.copy()
for name in tuple(settings):
    if name.startswith('PROTODESK_SMOKE_'):
        settings.pop(name)
settings['PROTOC'] = str(compiler)
if sys.platform == 'darwin':
    settings['PROTODESK_EXPECT_DATA_PATH'] = str(pathlib.Path.home() / 'Library/Application Support/ProtoDesk/protodesk.sqlite')
dart = shutil.which('dart')
if dart is None:
    raise SystemExit('Dart SDK is not on PATH')
if os.name == 'nt' and pathlib.Path(dart).suffix.lower() == '.bat':
    dart = str(pathlib.Path(dart).parent / 'cache/dart-sdk/bin/dart.exe')
server = subprocess.Popen([dart, 'run', 'tool/fixture_server.dart'], cwd=root, env=settings)
try:
    deadline = time.monotonic() + 45
    while True:
        try:
            with socket.create_connection(('127.0.0.1', 50079), timeout=1):
                break
        except OSError:
            if server.poll() is not None or time.monotonic() > deadline:
                raise SystemExit('Dart fixture did not start')
            time.sleep(0.25)
    for mode in ('reflection', 'proto'):
        settings['PROTODESK_SMOKE_ENDPOINT'] = '127.0.0.1:50079'
        if mode == 'proto':
            settings['PROTODESK_SMOKE_PROTO'] = base64.b64encode((root / 'test/fixtures/runtime.proto').read_bytes()).decode()
        result = subprocess.run([str(pathlib.Path(sys.argv[1]).resolve())], env=settings, timeout=45)
        if result.returncode:
            raise SystemExit(f'Compiled {mode} smoke failed: {result.returncode}')
        print(f'Compiled desktop {mode} smoke passed')
finally:
    server.terminate()
    try:
        server.wait(timeout=10)
    except subprocess.TimeoutExpired:
        server.kill()
