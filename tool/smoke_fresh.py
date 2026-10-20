#!/usr/bin/env python3
"""Verify the compiled app twice against isolated, initially empty storage."""
import os
from contextlib import closing
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile

executable = Path(sys.argv[1]).resolve()
parent = None
if sys.platform == 'darwin':
    parent = Path.home() / 'Library/Application Support/ProtoDesk'
    parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='protodesk-fresh-release-', dir=parent) as directory:
    settings = os.environ.copy()
    settings.pop('PROTODESK_SMOKE_ENDPOINT', None)
    settings.pop('PROTODESK_SMOKE_PROTO', None)
    settings['PROTODESK_DATA_DIR'] = directory
    settings['PROTODESK_SMOKE_FRESH'] = '1'
    for _ in range(2):
        subprocess.run([str(executable)], env=settings, check=True, timeout=45)
        with closing(sqlite3.connect(str(Path(directory) / 'protodesk.sqlite'))) as db:
            for table in ('servers', 'collections', 'collection_requests', 'history_items', 'credentials'):
                assert db.execute(f'SELECT count(*) FROM {table}').fetchone()[0] == 0, table
    print('Packaged fresh startup/restart and persisted empty tables: PASS')
