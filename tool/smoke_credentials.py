#!/usr/bin/env python3
"""Explicit native OS-store check using only a new synthetic credential/catalog."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    executable = Path(sys.argv[1]).resolve()
    parent = None
    if sys.platform == 'darwin':
        parent = Path.home() / 'Library/Application Support/ProtoDesk'
        parent.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix='protodesk-credential-smoke-', dir=parent))
    settings = os.environ.copy()
    for name in ('PROTODESK_SMOKE_ENDPOINT', 'PROTODESK_SMOKE_SOURCES',
                 'PROTODESK_SMOKE_FRESH', 'PROTODESK_SMOKE_SOURCES_OFFLINE'):
        settings.pop(name, None)
    settings['PROTODESK_DATA_DIR'] = str(directory)
    settings['PROTODESK_SMOKE_CREDENTIALS'] = '1'
    try:
        completed = subprocess.run([str(executable)], env=settings, check=True,
                                   timeout=45, capture_output=True, text=True)
        if 'CREDENTIAL_SMOKE: PASS' not in completed.stdout:
            raise RuntimeError('Native credential smoke did not report success')
    except Exception:
        # Retain the journal if an interrupted OS write needs later cleanup.
        print(f'Credential smoke failed; isolated recovery catalog retained at {directory}',
              file=sys.stderr)
        raise
    else:
        shutil.rmtree(directory)
        print('Native OS credential write/read/verified delete: PASS')


if __name__ == '__main__':
    main()
