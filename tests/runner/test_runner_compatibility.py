"""The released v44 variants must upgrade, while unknown variants stay blocked."""

import hashlib
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
MANIFESTS = json.loads((ROOT / 'schemas/runner-predecessor-v44.json').read_text())


class RunnerCompatibilityTests(unittest.TestCase):
    def _inspect(self, manifest, *, old_limit_files=frozenset(), version='v44'):
        generated = (ROOT / 'packages/ssh_transport/lib/src/runner_bundle.g.dart').read_text()
        source = generated.split("const runnerInspector = r'''", 1)[1].split("''';", 1)[0]
        scope = {}
        exec(source, scope)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base = root / 'runner'
            installed = base / version
            installed.mkdir(parents=True)
            unit = root / 'antirkn-runner.service'
            fixtures = {}
            for name, expected in manifest['hashes'].items():
                content = ('released-fixture:' + name).encode()
                fixtures[content] = expected
                path = unit if name == 'antirkn-runner.service' else installed / name
                path.write_bytes(content)
            # This exercises trust in registered manifests, independently of
            # future source edits. The release-lock gate verifies current bytes.
            actual_sha256 = hashlib.sha256
            scope['hashlib'] = SimpleNamespace(sha256=lambda data: (
                SimpleNamespace(hexdigest=lambda: fixtures[data]) if data in fixtures
                else actual_sha256(data)))
            (installed / 'manifest.json').write_text(json.dumps(manifest))
            scope['BASE'] = base
            scope['UNIT'] = unit
            original_lstat = Path.lstat

            def root_owned(path):
                meta = original_lstat(path)
                if path == root or root in path.parents:
                    return SimpleNamespace(st_uid=0, st_mode=meta.st_mode, st_size=meta.st_size)
                return meta

            with patch.object(Path, 'lstat', root_owned):
                return scope['inspect_runner']()

    def test_both_released_v44_variants_are_upgradeable(self):
        self.assertEqual(len(MANIFESTS), 2)
        for index, manifest in enumerate(MANIFESTS):
            with self.subTest(release=manifest['release']):
                old_files = {'vless.py', 'inbound_remove.py'} if index == 0 else set()
                actual = self._inspect(manifest, old_limit_files=old_files)
                self.assertEqual(actual['state'], 'installed')
                self.assertEqual(actual['release'], manifest['release'])
                self.assertTrue(actual['upgradable'])

    def test_released_v45_is_upgradeable(self):
        manifest = json.loads((ROOT / 'schemas/runner-predecessor-v45.json').read_text())
        actual = self._inspect(manifest, version='v45')
        self.assertEqual(actual['state'], 'installed')
        self.assertEqual(actual['release'], manifest['release'])
        self.assertTrue(actual['upgradable'])

    def test_released_v46_is_upgradeable(self):
        manifest = json.loads((ROOT / 'schemas/runner-predecessor-v46.json').read_text())
        actual = self._inspect(manifest, version='v46')
        self.assertEqual(actual['state'], 'installed')
        self.assertEqual(actual['release'], manifest['release'])
        self.assertTrue(actual['upgradable'])

    def test_released_v47_is_upgradeable(self):
        manifest = json.loads((ROOT / 'schemas/runner-predecessor-v47.json').read_text())
        actual = self._inspect(manifest, version='v47')
        self.assertEqual(actual['state'], 'installed')
        self.assertEqual(actual['release'], manifest['release'])
        self.assertTrue(actual['upgradable'])

    def test_released_v48_is_upgradeable(self):
        manifest = json.loads((ROOT / 'schemas/runner-predecessor-v48.json').read_text())
        actual = self._inspect(manifest, version='v48')
        self.assertEqual(actual['state'], 'installed')
        self.assertEqual(actual['release'], manifest['release'])
        self.assertTrue(actual['upgradable'])

    def test_released_v49_is_upgradeable(self):
        manifest = json.loads((ROOT / 'schemas/runner-predecessor-v49.json').read_text())
        actual = self._inspect(manifest, version='v49')
        self.assertEqual(actual['state'], 'installed')
        self.assertEqual(actual['release'], manifest['release'])
        self.assertTrue(actual['upgradable'])

    def test_released_v50_variants_are_upgradeable(self):
        manifests = json.loads((ROOT / 'schemas/runner-predecessor-v50.json').read_text())
        self.assertEqual(len(manifests), 2)
        for manifest in manifests:
            with self.subTest(release=manifest['release']):
                actual = self._inspect(manifest, version='v50')
                self.assertEqual(actual['state'], 'installed')
                self.assertEqual(actual['release'], manifest['release'])
                self.assertTrue(actual['upgradable'])

    def test_released_v51_variants_are_upgradeable(self):
        manifests = json.loads((ROOT / 'schemas/runner-predecessor-v51.json').read_text())
        self.assertEqual(len(manifests), 2)
        for manifest in manifests:
            with self.subTest(release=manifest['release']):
                actual = self._inspect(manifest, version='v51')
                self.assertEqual(actual['state'], 'installed')
                self.assertEqual(actual['release'], manifest['release'])
                self.assertTrue(actual['upgradable'])

    def test_released_v52_is_upgradeable(self):
        manifest = json.loads((ROOT / 'schemas/runner-predecessor-v52.json').read_text())
        actual = self._inspect(manifest, version='v52')
        self.assertEqual(actual['state'], 'installed')
        self.assertEqual(actual['release'], manifest['release'])
        self.assertTrue(actual['upgradable'])

    def test_released_v53_is_upgradeable(self):
        manifest = json.loads((ROOT / 'schemas/runner-predecessor-v53.json').read_text())
        actual = self._inspect(manifest, version='v53')
        self.assertEqual(actual['state'], 'installed')
        self.assertEqual(actual['release'], manifest['release'])
        self.assertTrue(actual['upgradable'])

    def test_released_v54_is_upgradeable(self):
        manifest = json.loads((ROOT / 'schemas/runner-predecessor-v54.json').read_text())
        actual = self._inspect(manifest, version='v54')
        self.assertEqual(actual['state'], 'installed')
        self.assertEqual(actual['release'], manifest['release'])
        self.assertTrue(actual['upgradable'])

    def test_released_v55_is_upgradeable(self):
        manifest = json.loads((ROOT / 'schemas/runner-predecessor-v55.json').read_text())
        actual = self._inspect(manifest, version='v55')
        self.assertEqual(actual['state'], 'installed')
        self.assertEqual(actual['release'], manifest['release'])
        self.assertTrue(actual['upgradable'])

    def test_released_v56_is_upgradeable(self):
        manifest = json.loads((ROOT / 'schemas/runner-predecessor-v56.json').read_text())
        actual = self._inspect(manifest, version='v56')
        self.assertEqual(actual['state'], 'installed')
        self.assertEqual(actual['release'], manifest['release'])
        self.assertTrue(actual['upgradable'])

    def test_released_v57_is_upgradeable(self):
        manifest = json.loads((ROOT / 'schemas/runner-predecessor-v57.json').read_text())
        actual = self._inspect(manifest, version='v57')
        self.assertEqual(actual['state'], 'installed')
        self.assertEqual(actual['release'], manifest['release'])
        self.assertTrue(actual['upgradable'])

    def test_released_v58_is_upgradeable(self):
        manifest = json.loads((ROOT / 'schemas/runner-predecessor-v58.json').read_text())
        actual = self._inspect(manifest, version='v58')
        self.assertEqual(actual['state'], 'installed')
        self.assertEqual(actual['release'], manifest['release'])
        self.assertTrue(actual['upgradable'])

    def test_released_v59_is_upgradeable(self):
        manifest = json.loads((ROOT / 'schemas/runner-predecessor-v59.json').read_text())
        actual = self._inspect(manifest, version='v59')
        self.assertEqual(actual['state'], 'installed')
        self.assertEqual(actual['release'], manifest['release'])
        self.assertTrue(actual['upgradable'])

    def test_unknown_v44_variant_remains_blocked(self):
        manifest = json.loads(json.dumps(MANIFESTS[1]))
        manifest['hashes']['vless.py'] = MANIFESTS[0]['hashes']['vless.py']
        manifest['release'] = hashlib.sha256(
            json.dumps(manifest['hashes'], sort_keys=True).encode()
        ).hexdigest()
        actual = self._inspect(manifest, old_limit_files={'vless.py'})
        self.assertEqual(actual['state'], 'conflict')
        self.assertFalse(actual['upgradable'])


if __name__ == '__main__':
    unittest.main()
