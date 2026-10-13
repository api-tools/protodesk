import tempfile
from pathlib import Path
import unittest
import zipfile
from audit_release import audit


class CleanReleaseTest(unittest.TestCase):
    def test_standard_definitions_are_allowed(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'google/protobuf/empty.proto'
            path.parent.mkdir(parents=True)
            path.write_text('message Empty {}')
            self.assertEqual(audit(root), 1)

    def test_archive_rejects_database_or_local_credentials(self):
        for name, data in [('protodesk.sqlite', b'data'), ('certs/test.pem', b'cert'),
                           ('assets/profile.json', b'Local Lab Reflection'),
                           ('assets/note.txt', b'/Users/hops/Projects/sample'),
                           ('assets/server.txt', b'protodesk-example-server')]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as root:
                archive = Path(root) / 'app.zip'
                with zipfile.ZipFile(archive, 'w') as out:
                    out.writestr(name, data)
                with self.assertRaises(ValueError):
                    audit(archive)

    def test_empty_bundle_is_not_a_pass(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(ValueError):
                audit(root)

class RegistrantConfigTest(unittest.TestCase):
    def test_build_only_alias_is_relative_idempotent_and_does_not_change_app_imports(self):
        from build_desktop import registrant_config
        source = {'packages': [{'name': 'protodesk', 'rootUri': '../',
                              'packageUri': 'lib/', 'languageVersion': '3.13'}]}
        result = registrant_config(source)
        self.assertEqual(result['packages'][0], source['packages'][0])
        self.assertEqual(result, registrant_config(result))
        self.assertEqual(result['packages'][1]['rootUri'], 'flutter_build/')
        self.assertEqual(len(source['packages']), 1)
