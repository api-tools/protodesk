#!/usr/bin/env python3
"""Reject user data and local example-server material in desktop bundles."""
import argparse
from pathlib import Path
import re
import tarfile
import zipfile

BAD_NAMES = re.compile(r'(?i)(?:protodesk-example-server|security-bookmarks\.plist|\.sqlite(?:3|-(?:wal|shm))?$|\.db$|\.pem$|\.p12$|\.p8$|\.pdb$|\.ilk$|\.dSYM/|\.key$|localhost\.crt$|processes\.json$|desktop-workspace\.json$)')
BAD_CONTENT = (
    b'protodesk-example-server', b'/Users/', b'file:///home/', b'file:///D:/a/', b'\\Users\\hops\\',
    b'Local Lab Reflection', b'Local Lab three-message',
    b'-----BEGIN PRIVATE KEY-----', b'-----BEGIN RSA PRIVATE KEY-----',
    b'-----BEGIN EC PRIVATE KEY-----', b'localhost:50051',
)


def inspect(name, data):
    if BAD_NAMES.search(name):
        raise ValueError(f'Unexpected user data / credential / example-server file: {name}')
    for marker in BAD_CONTENT:
        if marker in data:
            raise ValueError(f'Unexpected developer material {marker!r}: {name}')


def audit(target):
    target = Path(target)
    count = 0
    if target.is_dir():
        for path in sorted(target.rglob('*')):
            if path.is_file() and not path.is_symlink():
                inspect(str(path.relative_to(target)), path.read_bytes())
                count += 1
    elif zipfile.is_zipfile(target):
        with zipfile.ZipFile(target) as archive:
            for entry in archive.infolist():
                if not entry.is_dir():
                    inspect(entry.filename, archive.read(entry))
                    count += 1
    else:
        with tarfile.open(target) as archive:
            for entry in archive:
                if entry.isfile():
                    inspect(entry.name, archive.extractfile(entry).read())
                    count += 1
    if not count:
        raise ValueError('Release contains no files')
    return count


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('targets', nargs='+', type=Path)
    args = parser.parse_args()
    for target in args.targets:
        print(f'Release content audit: PASS ({audit(target)} files): {target}')
