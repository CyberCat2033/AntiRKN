"""The one bounded subprocess call and the shared root-file primitives."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
import sysutil


class Failure(Exception):
    pass


class RunTests(unittest.TestCase):
    def test_exit_status_maps_to_the_module_error(self):
        with self.assertRaises(Failure):
            sysutil.run([sys.executable, '-c', 'raise SystemExit(3)'], check=True, error=Failure())
        with self.assertRaises(subprocess.CalledProcessError):
            sysutil.run([sys.executable, '-c', 'raise SystemExit(3)'], check=True)
        self.assertEqual(sysutil.run([sys.executable, '-c', 'raise SystemExit(3)']).returncode, 3)

    def test_error_carries_no_program_output(self):
        try:
            sysutil.run([sys.executable, '-c', 'print("secret-token"); raise SystemExit(1)'], check=True, error=Failure('code'))
        except Failure as error:
            self.assertNotIn('secret-token', repr(error))
            self.assertIsNone(error.__cause__)

    def test_output_limit(self):
        with self.assertRaises(Failure):
            sysutil.run([sys.executable, '-c', 'print("x" * 100)'], max_output=10, oversize=Failure())
        self.assertEqual(sysutil.run([sys.executable, '-c', 'print("ok")'], max_output=10).stdout, b'ok\n')

    def test_stdin_is_closed_without_input(self):
        result = sysutil.run([sys.executable, '-c', 'import sys; print(repr(sys.stdin.read()))'], text=True, timeout=10)
        self.assertEqual(result.stdout.strip(), "''")
        self.assertEqual(sysutil.run([sys.executable, '-c', 'import sys; print(sys.stdin.read())'], input=b'in').stdout, b'in\n')

    def test_timeout_is_enforced(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            sysutil.run([sys.executable, '-c', 'import time; time.sleep(5)'], timeout=0.2)

    def test_lock_refuses_a_link(self):
        with tempfile.TemporaryDirectory() as root:
            target = Path(root) / 'target'; target.write_text('x')
            link = Path(root) / 'lock'; link.symlink_to(target)
            with self.assertRaises(OSError):
                sysutil.open_lock(link)


if __name__ == '__main__':
    unittest.main()
