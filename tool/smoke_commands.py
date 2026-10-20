#!/usr/bin/env python3
"""Exercise compiled command interchange with isolated storage and no server."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

executable = Path(sys.argv[1]).resolve()
parent = None
if sys.platform == 'darwin':
    parent = Path.home() / 'Library/Application Support/ProtoDesk'
    parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='protodesk-command-smoke-', dir=parent) as directory:
    settings = os.environ.copy()
    for name in tuple(settings):
        if name.startswith('PROTODESK_SMOKE_'):
            settings.pop(name)
    settings['PROTODESK_DATA_DIR'] = directory
    settings['PROTODESK_SMOKE_COMMANDS'] = '1'
    result = subprocess.run([str(executable)], env=settings,
                            timeout=60, capture_output=True, text=True)
    if result.returncode:
        print(result.stdout[-4000:], file=sys.stderr)
        print(result.stderr[-4000:], file=sys.stderr)
        raise RuntimeError('Compiled command verification failed')
    if 'COMMAND_SMOKE: PASS' not in result.stdout:
        raise RuntimeError('Compiled command verification did not report success')
    print(result.stdout.strip())
