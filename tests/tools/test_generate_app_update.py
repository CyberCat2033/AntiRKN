"""The app update contract is generated from its schema and checked for drift."""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TARGET = 'packages/domain/lib/src/app_update_contract.g.dart'


class GenerateAppUpdateTests(unittest.TestCase):
    def run_check(self, root):
        return subprocess.run([sys.executable, str(root / 'tool/generate_app_update.py'), '--check'],
                              capture_output=True, text=True, timeout=120)

    def test_committed_contract_matches_schema(self):
        result = self.run_check(ROOT)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_schema_change_without_regeneration_is_detected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ['tool/generate_app_update.py', 'schemas/app-update-v1.json', TARGET]:
                (root / name).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(ROOT / name, root / name)
            self.assertEqual(self.run_check(root).returncode, 0)
            schema = json.loads((root / 'schemas/app-update-v1.json').read_text())
            schema['artifact']['size']['maximum'] += 1
            (root / 'schemas/app-update-v1.json').write_text(json.dumps(schema))
            result = self.run_check(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Generated file differs', result.stderr)

    def test_signed_limits_are_exported(self):
        source = (ROOT / TARGET).read_text()
        self.assertIn("const appUpdateSignaturePrefix = 'antirkn-app-update-v1';", source)
        self.assertIn("'release-assets.githubusercontent.com'", source)


if __name__ == '__main__':
    unittest.main()
