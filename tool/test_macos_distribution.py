"""Credential-free regressions: ordering, fail-closed policy and PR isolation."""
import json
import base64
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import package_macos as package
import macos_ci_credentials as credentials


class DistributionTests(unittest.TestCase):
    def fixture(self, root):
        app = Path(root) / 'ProtoDesk.app'
        binaries = ['Contents/MacOS/ProtoDesk', 'Contents/Helpers/protoc', 'Contents/Frameworks/Plugin.framework/Versions/A/Plugin', 'Contents/Frameworks/nested.dylib', str(package.ASSET_PROTOC)]
        for name in binaries:
            path = app / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(bytes.fromhex('cffaedfe') + b'code')
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'ProtoDesk'}))
        framework = app / 'Contents/Frameworks/Plugin.framework'
        try:
            (framework / 'Plugin').symlink_to('Versions/A/Plugin')
        except OSError:
            if os.name != 'nt':
                raise
        return app

    def test_inventory_signs_all_native_code_inside_out_without_deep(self):
        with tempfile.TemporaryDirectory() as root:
            app = self.fixture(root)
            commands = []
            def run(args, **kwargs):
                commands.append([str(a).replace('\\', '/') for a in args])
                return subprocess.CompletedProcess(args, 0, stdout='shared library', stderr='')
            with patch.object(package, 'run', side_effect=run):
                items, leaves = package.sign(app, 'CERT', distribution=True)
            self.assertEqual(len(leaves), 5)
            self.assertEqual(items[-1], app)
            strips = [i for i, c in enumerate(commands) if c[0] == '/usr/bin/strip']
            self.assertEqual(len(strips), len(leaves))
            self.assertLess(max(strips), next(i for i, c in enumerate(commands) if '--sign' in c))
            signs = [c for c in commands if '--sign' in c]
            self.assertEqual(len(signs), 7)
            self.assertTrue(all('--deep' not in c and '--timestamp' in c and '--options' in c for c in signs))
            self.assertLess(next(i for i,c in enumerate(signs) if c[-1].endswith('/Versions/A/Plugin')), next(i for i,c in enumerate(signs) if c[-1].endswith('/Plugin.framework')))
            entitled = [c for c in signs if '--entitlements' in c]
            self.assertEqual(len(entitled), 3)
            self.assertTrue(all(c[-1].endswith(('protoc', '.app')) for c in entitled))

    def test_missing_distribution_credentials_fail_before_sign_or_archive(self):
        with patch.object(package, 'sign') as sign, patch.object(package, 'archive') as archive:
            with self.assertRaisesRegex(RuntimeError, 'TEAM_ID'):
                package.package(Path('unused.app'), environ={})
            sign.assert_not_called()
            archive.assert_not_called()

    def test_apple_development_identity_cannot_substitute(self):
        response = subprocess.CompletedProcess([], 0, stdout='1) '+ 'A'*40 + ' "Apple Development: Owner (ZGPYL87DRA)"', stderr='')
        with patch.object(package, 'run', return_value=response):
            with self.assertRaisesRegex(RuntimeError, 'Developer ID Application'):
                package.identity_and_profile({'PROTODESK_TEAM_ID':'ZGPYL87DRA'})

    def test_public_pipeline_staples_before_final_archive_and_smokes_extracted_app(self):
        with tempfile.TemporaryDirectory() as root:
            app = self.fixture(root)
            commands = []
            def run(args, **kwargs):
                commands.append([str(a).replace('\\', '/') for a in args])
                if args[:3] == ['xcrun','notarytool','submit']:
                    return subprocess.CompletedProcess(args, 0, stdout=json.dumps({'id':'submission-id','status':'Accepted'}), stderr='')
                if args[:3] == ['xcrun','notarytool','log']:
                    Path(args[-1]).write_text('{"issues":null}')
                if args[:4] == ['/usr/bin/ditto','-c','-k','--sequesterRsrc']:
                    Path(args[-1]).write_bytes(b'archive')
                return subprocess.CompletedProcess(args, 0, stdout='', stderr='')
            with patch.object(package, 'ROOT', Path(root)), patch.object(package, 'run', side_effect=run), patch.object(package, 'identity_and_profile', return_value=('CERT','ZGPYL87DRA','',[])), patch.object(package, 'sign', return_value=([app],[app])), patch.object(package, 'verify_distribution'):
                destination = package.package(app, environ={})
            self.assertTrue(destination.exists())
            staple = next(i for i,c in enumerate(commands) if c[:3] == ['xcrun','stapler','staple'])
            archives = [i for i,c in enumerate(commands) if c[:2] == ['/usr/bin/ditto','-c']]
            self.assertLess(archives[0], staple)
            self.assertLess(staple, archives[1])
            self.assertTrue(any('smoke_release.py' in ' '.join(c) and '/extracted/' in ' '.join(c) for c in commands))
            evidence = json.loads((destination.parent/'macos-notarization.json').read_text())
            self.assertEqual(evidence['status'], 'Accepted')

    def test_rejected_notarization_never_staples_or_publishes(self):
        with tempfile.TemporaryDirectory() as root:
            app = self.fixture(root)
            commands = []
            def run(args, **kwargs):
                commands.append([str(a).replace('\\', '/') for a in args])
                if args[:3] == ['xcrun','notarytool','submit']:
                    return subprocess.CompletedProcess(args, 0, stdout=json.dumps({'id':'rejected','status':'Invalid'}), stderr='')
                if args[:3] == ['xcrun','notarytool','log']:
                    Path(args[-1]).write_text('{"issues":[{"severity":"error"}]}')
                return subprocess.CompletedProcess(args, 0, stdout='', stderr='')
            with patch.object(package, 'ROOT', Path(root)), patch.object(package, 'run', side_effect=run), patch.object(package, 'identity_and_profile', return_value=('CERT','TEAM','',[])), patch.object(package, 'sign', return_value=([app],[app])), patch.object(package, 'verify_distribution'):
                with self.assertRaisesRegex(RuntimeError, 'Notary log'):
                    package.package(app, environ={})
            self.assertFalse(any(c[:3] == ['xcrun','stapler','staple'] for c in commands))
            self.assertFalse((Path(root)/'dist/release/ProtoDesk-macos-universal.zip').exists())

    def test_pr_or_missing_environment_cannot_use_signing_secrets(self):
        with self.assertRaisesRegex(RuntimeError, 'never pull requests'):
            credentials.guard({'GITHUB_EVENT_NAME':'pull_request'})
        with self.assertRaisesRegex(RuntimeError, 'Missing protected'):
            credentials.guard({'GITHUB_EVENT_NAME':'push','GITHUB_REF':'refs/tags/v1.0.4','GITHUB_REPOSITORY':'api-tools/protodesk','RUNNER_OS':'macOS'})

    def test_wrapped_certificate_secret_is_imported_privately_and_cleanup_restores_state(self):
        with tempfile.TemporaryDirectory() as root:
            encoded = base64.b64encode(b'test-only certificate bytes').decode()
            environ = {'RUNNER_TEMP':root,'GITHUB_ENV':str(Path(root)/'job-env'),'GITHUB_EVENT_NAME':'push','GITHUB_REF':'refs/tags/v1.0.4','GITHUB_REPOSITORY':'api-tools/protodesk','RUNNER_OS':'macOS',
                'APPLE_DEVELOPER_ID_P12_BASE64':encoded[:8]+'\n'+encoded[8:]+'\n','APPLE_DEVELOPER_ID_P12_PASSWORD':'test-only-export-password','APPLE_TEAM_ID':'ZGPYL87DRA','APPLE_NOTARY_APPLE_ID':'fixture@example.invalid','APPLE_NOTARY_APP_PASSWORD':'test-only-notary-password'}
            with patch.object(credentials, 'sensitive', return_value='"/tmp/original.keychain-db"\n'), patch.object(credentials.subprocess, 'run', return_value=subprocess.CompletedProcess([],0)):
                credentials.setup(environ)
                self.assertFalse((Path(root)/'protodesk-signing.p12').exists())
                exported = Path(environ['GITHUB_ENV']).read_text()
                self.assertNotIn(environ['APPLE_NOTARY_APP_PASSWORD'], exported)
                self.assertNotIn(environ['APPLE_DEVELOPER_ID_P12_PASSWORD'], credentials.state_path(environ).read_text())
                credentials.cleanup(environ)
                self.assertFalse(credentials.state_path(environ).exists())

    def test_cleanup_rejects_arbitrary_keychain(self):
        with tempfile.TemporaryDirectory() as root:
            environ = {'RUNNER_TEMP':root}
            credentials.state_path(environ).write_text('{"keychain":"/Users/owner/login.keychain-db","previous":[]}')
            with self.assertRaisesRegex(RuntimeError, 'unrecognized'):
                credentials.cleanup(environ)


if __name__ == '__main__':
    unittest.main()
