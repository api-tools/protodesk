#!/usr/bin/env python3
"""Build a desktop release without embedding machine-specific registrant URIs."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def registrant_config(config):
    config = dict(config)
    packages = [dict(p) for p in config['packages'] if p['name'] != 'protodesk_generated']
    version = next(p['languageVersion'] for p in packages if p['name'] == 'protodesk')
    # Flutter resolves this generated entry point to a package URI instead of
    # retaining its absolute file URI in the AOT plugin registry constant.
    packages.append({'name': 'protodesk_generated', 'rootUri': 'flutter_build/',
                     'packageUri': '', 'languageVersion': version})
    config['packages'] = packages
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', choices=['macos', 'windows', 'linux'])
    args = parser.parse_args()
    flutter = shutil.which('flutter')
    if flutter is None:
        parser.error('Flutter SDK is not on PATH')
    subprocess.run([flutter, 'pub', 'get'], cwd=ROOT, check=True)
    path = ROOT / '.dart_tool/package_config.json'
    original = path.read_bytes()
    (ROOT / '.dart_tool/flutter_build').mkdir(parents=True, exist_ok=True)
    try:
        path.write_text(json.dumps(registrant_config(json.loads(original)), indent=2) + '\n')
        subprocess.run([flutter, 'build', args.target, '--release', '--no-pub',
                        '--split-debug-info=build/symbols'], cwd=ROOT, check=True)
    finally:
        path.write_bytes(original)


if __name__ == '__main__':
    main()
