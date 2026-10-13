#!/usr/bin/env python3
"""Inside-out signing and fail-closed notarized macOS distribution."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / 'build/macos/Build/Products/Release/ProtoDesk.app'
ASSET_PROTOC = Path('Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/protoc/bin/protoc')
MACHO_MAGIC = {bytes.fromhex(x) for x in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


def run(args, *, check=True):
    result = subprocess.run([str(a) for a in args], text=True, capture_output=True)
    if check and result.returncode:
        raise RuntimeError(f'{args[0]} failed: {result.stderr.strip() or result.stdout.strip()}')
    return result


def code_inventory(app):
    """Find every real Mach-O leaf and code bundle, ignoring framework symlinks."""
    app = Path(app)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    leaves, bundles = [], []
    for directory, dirs, files in os.walk(app, followlinks=False):
        dirs[:] = [d for d in dirs if not (Path(directory) / d).is_symlink()]
        for name in dirs:
            path = Path(directory) / name
            if path.suffix in ('.framework', '.app', '.appex', '.xpc', '.bundle'):
                bundles.append(path)
        for name in files:
            path = Path(directory) / name
            if path.is_symlink():
                continue
            with path.open('rb') as file:
                if file.read(4) in MACHO_MAGIC:
                    leaves.append(path)
    if executable not in leaves or app / 'Contents/Helpers/protoc' not in leaves:
        raise RuntimeError('App executable or bundled protoc is missing from Mach-O inventory')
    # A new nested executable needs an explicit entitlement policy, not blind signing.
    allowed = {executable, app / 'Contents/Helpers/protoc', app / ASSET_PROTOC}
    for leaf in leaves:
        if leaf not in allowed and run(['/usr/bin/file', '-b', leaf]).stdout.strip().find('executable') >= 0:
            raise RuntimeError(f'Unconfigured nested executable: {leaf.relative_to(app)}')
    items = set(leaves + bundles)
    items.discard(executable)  # Signing the outer app applies its executable entitlements.
    return sorted(items, key=lambda p: (-len(p.parts), str(p))) + [app], leaves


def identity_and_profile(environ):
    team = environ.get('PROTODESK_TEAM_ID', '')
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise RuntimeError('Set PROTODESK_TEAM_ID to your 10-character Apple Developer Team ID')
    keychain = environ.get('PROTODESK_SIGNING_KEYCHAIN', '')
    args = ['security', 'find-identity', '-v', '-p', 'codesigning']
    if keychain:
        args.append(keychain)
    identities = re.findall(r'([0-9A-F]{40}) "(Developer ID Application:[^"]+)"', run(args).stdout)
    chosen = environ.get('PROTODESK_SIGNING_IDENTITY', '')
    candidates = [(sha, name) for sha, name in identities if not chosen or chosen in (sha, name)]
    candidates = [(sha, name) for sha, name in candidates if name.endswith(f'({team})')]
    if len(candidates) != 1:
        raise RuntimeError('Install/select exactly one valid Developer ID Application identity (certificate AND private key) for PROTODESK_TEAM_ID. Apple Development and ad-hoc identities are not distribution identities.')
    profile = environ.get('PROTODESK_NOTARY_PROFILE', 'protodesk-notary')
    auth = ['--keychain-profile', profile]
    if keychain:
        auth += ['--keychain', keychain]
    result = run(['xcrun', 'notarytool', 'history', *auth, '--output-format', 'json'], check=False)
    if result.returncode:
        raise RuntimeError(f'Notarization profile {profile!r} is unavailable or invalid. Run xcrun notarytool store-credentials {profile} --team-id {team} locally and enter credentials at the secure prompts.')
    return candidates[0][0], team, keychain, auth


def sign(app, identity, keychain='', distribution=False):
    items, leaves = code_inventory(app)
    # Remove developer object/source paths before producing any signed bundle.
    for leaf in leaves:
        run(['/usr/bin/strip', '-S', '-x', leaf])
    for item in items:
        args = ['/usr/bin/codesign', '--force', '--sign', identity]
        if keychain:
            args += ['--keychain', keychain]
        if distribution:
            args += ['--options', 'runtime', '--timestamp']
        if item == app:
            args += ['--entitlements', ROOT / 'macos/Runner/Release.entitlements']
        elif item in {app / 'Contents/Helpers/protoc', app / ASSET_PROTOC}:
            args += ['--entitlements', ROOT / 'macos/Runner/Protoc.entitlements']
        run([*args, item])
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--verbose=2', app])
    return items, leaves


def verify_distribution(app, items, leaves, team):
    for item in set(items + leaves):
        run(['/usr/bin/codesign', '--verify', '--strict', item])
        detail = run(['/usr/bin/codesign', '-d', '--verbose=4', item]).stderr
        if f'TeamIdentifier={team}' not in detail or 'Authority=Developer ID Application:' not in detail or 'Timestamp=' not in detail or 'runtime' not in detail:
            raise RuntimeError(f'Missing Developer ID / team / hardened runtime / secure timestamp: {item}')
    for item, required in [(app, 'Release'), (app / 'Contents/Helpers/protoc', 'Protoc'), *([(app / ASSET_PROTOC, 'Protoc')] if (app / ASSET_PROTOC).exists() else [])]:
        actual = run(['/usr/bin/codesign', '-d', '--entitlements', ':-', item]).stdout
        # codesign writes the XML payload to stdout and diagnostics to stderr.
        entitlements = plistlib.loads(actual.encode())
        expected = plistlib.loads((ROOT / f'macos/Runner/{required}.entitlements').read_bytes())
        if entitlements != expected or entitlements.get('com.apple.security.get-task-allow'):
            raise RuntimeError(f'Unexpected distribution entitlements: {item}')


def archive(app, destination):
    run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, destination])


def package(app, *, development=False, environ=None):
    app = Path(app).resolve()
    environ = os.environ if environ is None else environ
    if development:
        sign(app, '-')
        destination = ROOT / 'dist/ProtoDesk-macos-development.zip'
        destination.parent.mkdir(parents=True, exist_ok=True)
        archive(app, destination)
        return destination
    # Preflight runs before signing or producing any public distribution archive.
    identity, team, keychain, auth = identity_and_profile(environ)
    items, leaves = sign(app, identity, keychain, distribution=True)
    verify_distribution(app, items, leaves, team)
    output = ROOT / 'dist/release'
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='protodesk-notary-') as work:
        submitted = Path(work) / 'submission.zip'
        archive(app, submitted)
        submission = run(['xcrun', 'notarytool', 'submit', submitted, *auth, '--wait', '--timeout', '30m', '--output-format', 'json'], check=False)
        (output / 'notary-submission.json').write_text(submission.stdout)
        try:
            status = json.loads(submission.stdout)
        except json.JSONDecodeError:
            raise RuntimeError('Notary submission failed before returning JSON. Check the keychain profile/network and dist/release/notary-submission.json. ' + submission.stderr.strip()) from None
        identifier = status.get('id')
        if identifier:
            log = output / 'notary-log.json'
            run(['xcrun', 'notarytool', 'log', identifier, *auth, log])
            issues = json.loads(log.read_text()).get('issues') or []
            if issues:
                raise RuntimeError(f'Notary log contains issues; review {log} and repair before publishing (submission {identifier})')
        if submission.returncode or status.get('status') != 'Accepted' or not identifier:
            raise RuntimeError(f'Notarization was not accepted ({status.get("status", "unknown")}, submission {identifier}). Inspect notarytool info/log; a timed-out submission continues at Apple. No distribution archive was produced.')
        run(['xcrun', 'stapler', 'staple', app])
        run(['xcrun', 'stapler', 'validate', app])
        verify_distribution(app, items, leaves, team)
        run(['/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=2', app])
        # Archive only after the ticket is stapled. Verify and smoke the extracted artifact.
        packaged = Path(work) / 'ProtoDesk-macos-universal.zip'
        archive(app, packaged)
        extracted = Path(work) / 'extracted'
        run(['/usr/bin/ditto', '-x', '-k', packaged, extracted])
        distributed = extracted / app.name
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', distributed])
        run(['xcrun', 'stapler', 'validate', distributed])
        run(['/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=2', distributed])
        run([sys.executable, ROOT / 'tool/smoke_release.py', distributed / 'Contents/MacOS/ProtoDesk'])
        sha = hashlib.sha256(packaged.read_bytes()).hexdigest()
        destination = output / packaged.name
        pending = destination.with_suffix('.zip.pending')
        shutil.copyfile(packaged, pending)
        os.replace(pending, destination)
        (output / 'macos-notarization.json').write_text(json.dumps({'status':'Accepted','submissionId':identifier,'teamId':team,'archive':destination.name,'sha256':sha,'nestedMachOCount':len(leaves),'stapled':True,'gatekeeper':'accepted','extractedSmoke':'passed'}, indent=2) + '\n')
        return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['check', 'development', 'distribute'])
    parser.add_argument('--app', type=Path, default=APP)
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('macOS signing/notarization must run on macOS')
    try:
        if args.mode == 'check':
            _, team, _, _ = identity_and_profile(os.environ)
            print(f'Developer ID and notarization profile ready for team {team}')
        else:
            print(package(args.app, development=args.mode == 'development'))
    except (RuntimeError, OSError, ValueError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
