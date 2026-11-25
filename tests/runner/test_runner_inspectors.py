"""The bundled inspectors run alone (`python3 -I -c <source>`) before the
runner is installed, so they must not need any sibling runner module."""

import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
BUNDLE = ROOT / 'packages/ssh_transport/lib/src/runner_bundle.g.dart'
INSPECTORS = ('runnerInspector', 'runnerInstaller', 'runnerComponentInspector', 'runnerPanelInspector')


def inspector(name):
    match = re.search(r"const %s =\s*r'''(.*?)''';" % name, BUNDLE.read_text(), re.S)
    return match.group(1)


def run_alone(source, stdin=b''):
    with tempfile.TemporaryDirectory() as directory:
        return subprocess.run([sys.executable, '-I', '-c', source], cwd=directory, input=stdin,
                              capture_output=True, timeout=120)


class StandaloneInspectorTests(unittest.TestCase):
    def test_every_inspector_starts_without_runner_modules(self):
        for name in INSPECTORS:
            with self.subTest(inspector=name):
                result = run_alone(inspector(name))
                stderr = result.stderr.decode(errors='replace')
                self.assertNotIn('ImportError', stderr)
                self.assertNotIn('ModuleNotFoundError', stderr)
                if name != 'runnerInspector':
                    # Reached the input prompt, then failed only on empty input.
                    self.assertIn('__ANTIRKN_RUNNER_INPUT__', stderr)

    def test_plan_inspectors_resolve_every_module_they_use(self):
        # Module-level and in-function imports (panel.run imports sysutil
        # lazily) resolve to the bundled sources, never to the working directory.
        for name, modules in (('runnerPanelInspector', ('panel', 'sysutil', 'panel_release')),
                              ('runnerComponentInspector', ('panel', 'sysutil', 'components', 'component_releases'))):
            with self.subTest(inspector=name):
                source = inspector(name)
                head = source.split("print('__ANTIRKN_RUNNER_INPUT__'", 1)[0]
                check = head + ''.join('import %s\n' % m for m in modules) + (
                    'import panel, sysutil\n'
                    "assert panel.run([sys.executable, '-c', 'pass'], timeout=30).returncode == 0\n"
                    "print('resolved')\n")
                result = run_alone(check)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace')[-2000:])
                self.assertEqual(result.stdout.strip(), b'resolved')

    def test_component_plan_reports_json(self):
        result = run_alone(inspector('runnerComponentInspector'), json.dumps({'component': 'trusttunnel'}).encode())
        stderr = result.stderr.decode(errors='replace')
        self.assertNotIn('ModuleNotFoundError', stderr)
        self.assertNotIn('NameError', stderr)
        if result.returncode == 0:
            reply = json.loads(result.stdout)
            self.assertEqual(reply['componentPlan']['component'], 'trusttunnel')


if __name__ == '__main__':
    unittest.main()
