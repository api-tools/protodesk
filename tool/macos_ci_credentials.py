#!/usr/bin/env python3
"""Protected tag-only credentials; never print key material or command arguments."""
import base64
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys

REQUIRED = ('APPLE_DEVELOPER_ID_P12_BASE64', 'APPLE_DEVELOPER_ID_P12_PASSWORD', 'APPLE_TEAM_ID', 'APPLE_NOTARY_APPLE_ID', 'APPLE_NOTARY_APP_PASSWORD')


def sensitive(title, args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'{title} failed. Check the protected macos-release secrets and Apple account permissions.')
    return result.stdout


def guard(environ):
    if environ.get('GITHUB_EVENT_NAME') != 'push' or not environ.get('GITHUB_REF', '').startswith('refs/tags/v') or environ.get('GITHUB_REPOSITORY') != 'api-tools/protodesk' or environ.get('RUNNER_OS') != 'macOS':
        raise RuntimeError('Signing credentials are allowed only in the protected macOS release job for a repository version tag, never pull requests')
    missing = [name for name in REQUIRED if not environ.get(name)]
    if missing:
        raise RuntimeError('Missing protected macos-release secrets: ' + ', '.join(missing))


def state_path(environ):
    return Path(environ['RUNNER_TEMP']) / 'protodesk-signing-state.json'


def setup(environ):
    guard(environ)
    root = Path(environ['RUNNER_TEMP']).resolve()
    keychain = root / f'protodesk-signing-{secrets.token_hex(8)}.keychain-db'
    certificate = root / 'protodesk-signing.p12'
    password = secrets.token_urlsafe(32)
    existing = sensitive('Read keychain search list', ['security', 'list-keychains', '-d', 'user'])
    previous = [line.strip().strip('"') for line in existing.splitlines() if line.strip()]
    state = state_path(environ)
    state.write_text(json.dumps({'keychain':str(keychain),'previous':previous}))
    state.chmod(0o600)
    try:
        certificate.write_bytes(base64.b64decode(environ['APPLE_DEVELOPER_ID_P12_BASE64'], validate=True))
        certificate.chmod(0o600)
        sensitive('Create temporary keychain', ['security', 'create-keychain', '-p', password, str(keychain)])
        sensitive('Configure temporary keychain', ['security', 'set-keychain-settings', '-lut', '21600', str(keychain)])
        sensitive('Unlock temporary keychain', ['security', 'unlock-keychain', '-p', password, str(keychain)])
        sensitive('Import Developer ID key', ['security', 'import', str(certificate), '-k', str(keychain), '-P', environ['APPLE_DEVELOPER_ID_P12_PASSWORD'], '-T', '/usr/bin/codesign', '-T', '/usr/bin/security'])
        sensitive('Authorize Apple signing tools', ['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, str(keychain)])
        sensitive('Select temporary search list', ['security', 'list-keychains', '-d', 'user', '-s', str(keychain), *previous])
        sensitive('Validate/store notarization profile', ['xcrun', 'notarytool', 'store-credentials', 'protodesk-notary', '--keychain', str(keychain), '--apple-id', environ['APPLE_NOTARY_APPLE_ID'], '--team-id', environ['APPLE_TEAM_ID'], '--password', environ['APPLE_NOTARY_APP_PASSWORD'], '--validate'])
        with Path(environ['GITHUB_ENV']).open('a') as output:
            output.write(f'PROTODESK_SIGNING_KEYCHAIN={keychain}\nPROTODESK_TEAM_ID={environ["APPLE_TEAM_ID"]}\nPROTODESK_NOTARY_PROFILE=protodesk-notary\n')
    finally:
        certificate.unlink(missing_ok=True)


def cleanup(environ):
    state = state_path(environ)
    if not state.exists():
        return
    data = json.loads(state.read_text())
    root = Path(environ['RUNNER_TEMP']).resolve()
    keychain = Path(data['keychain']).resolve()
    if keychain.parent != root or not keychain.name.startswith('protodesk-signing-'):
        raise RuntimeError('Refusing to remove an unrecognized keychain')
    try:
        sensitive('Restore keychain search list', ['security', 'list-keychains', '-d', 'user', '-s', *data['previous']])
    finally:
        subprocess.run(['security', 'delete-keychain', str(keychain)], capture_output=True, check=False)
        (root / 'protodesk-signing.p12').unlink(missing_ok=True)
        state.unlink(missing_ok=True)


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2 or sys.argv[1] not in ('setup', 'cleanup'):
            raise RuntimeError('Usage: macos_ci_credentials.py setup|cleanup')
        (setup if sys.argv[1] == 'setup' else cleanup)(os.environ)
    except (RuntimeError, OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
