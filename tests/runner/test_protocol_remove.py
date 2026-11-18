import errno
import hashlib
from pathlib import Path
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
import protocol_remove as removal


def content_digest(path):
    values = []
    for p in [path, *sorted(path.rglob('*'))] if path.is_dir() else [path]:
        values.append((str(p.relative_to(path)), os.readlink(p) if p.is_symlink() else p.read_bytes().hex() if p.is_file() else None))
    return hashlib.sha256(repr(values).encode()).hexdigest()


class RemovalTests(unittest.TestCase):
    def test_template_fragment_does_not_call_systemctl_show(self):
        with patch.object(removal, 'exists', side_effect=lambda p: str(p) == '/etc/systemd/system/antirkn-awg@.service'), patch.object(removal, 'run') as run:
            self.assertEqual(removal.unit_fragment('antirkn-awg@.service'), Path('/etc/systemd/system/antirkn-awg@.service'))
            run.assert_not_called()

    def test_cross_mount_copy_preserves_bytes_and_links_and_can_resume(self):
        for interrupt in (False, True):
            with self.subTest(interrupt=interrupt), tempfile.TemporaryDirectory() as root:
                root = Path(root)
                source, backup = root / 'source', root / 'backup'
                source.mkdir()
                (source / 'config').write_text('public-fixture')
                (source / 'link').symlink_to('config')
                rename = os.rename
                def cross_mount(a, b):
                    if a == source:
                        raise OSError(errno.EXDEV, 'fixture bind mount')
                    return rename(a, b)
                with patch.object(removal, 'path_state', side_effect=content_digest), patch.object(removal.os, 'rename', side_effect=cross_mount):
                    if interrupt:
                        with patch.object(removal.shutil, 'rmtree', side_effect=OSError('crash before source removal')):
                            with self.assertRaises(OSError):
                                removal.quarantine(source, backup)
                        self.assertTrue(source.exists())
                        self.assertTrue(backup.exists())
                    removal.quarantine(source, backup)
                    removal.quarantine(source, backup)
                self.assertFalse(source.exists())
                self.assertEqual((backup / 'config').read_text(), 'public-fixture')
                self.assertTrue((backup / 'link').is_symlink())

    def test_unrelated_recreation_after_rename_is_not_deleted(self):
        with tempfile.TemporaryDirectory() as root:
            source, backup = Path(root) / 'source', Path(root) / 'backup'
            source.write_text('owned')
            with patch.object(removal, 'path_state', side_effect=content_digest):
                removal.quarantine(source, backup)
                source.write_text('new resource')
                with self.assertRaises(removal.RemovalError):
                    removal.quarantine(source, backup)
            self.assertEqual(source.read_text(), 'new resource')

    def test_changed_source_after_cross_mount_copy_blocks_resume(self):
        with tempfile.TemporaryDirectory() as root:
            source, backup = Path(root) / 'source', Path(root) / 'backup'
            source.write_text('changed')
            backup.write_text('original')
            backup.with_name('backup.copied').write_text(content_digest(backup))
            with patch.object(removal, 'path_state', side_effect=content_digest):
                with self.assertRaises(removal.RemovalError):
                    removal.quarantine(source, backup)
            self.assertEqual(source.read_text(), 'changed')

    def test_plan_fingerprint_survives_live_panel_writes(self):
        # 3x-ui rewrites its database, WAL and metrics every few seconds; a
        # removal approved a moment ago must still match. New files do not.
        from types import SimpleNamespace
        trusted_parent = lambda self, **kw: SimpleNamespace(st_uid=0, st_mode=0o40755)
        with tempfile.TemporaryDirectory() as root, patch.object(removal.Path, 'stat', trusted_parent):
            data = Path(root) / 'x-ui'
            data.mkdir()
            (data / 'x-ui.db').write_bytes(b'one')
            (data / 'system_metrics.gob').write_bytes(b'a')
            planned = removal.path_state(data, content=False)
            exact = removal.path_state(data)
            (data / 'x-ui.db').write_bytes(b'two')
            (data / 'system_metrics.gob').write_bytes(b'bb')
            self.assertEqual(removal.path_state(data, content=False), planned)
            self.assertNotEqual(removal.path_state(data), exact)
            (data / 'foreign.conf').write_text('other software')
            self.assertNotEqual(removal.path_state(data, content=False), planned)

    def test_prune_quarantines_retains_bounded_recent_directories(self):
        # Audit #24: Quarantine directories are pruned to prevent uncontrolled disk growth
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            dirs = []
            for i in range(5):
                d = root / f'remove-job{i}'
                d.mkdir()
                (d / 'data').write_text(f'data-{i}')
                # Set distinct mtimes
                os.utime(d, (1000 + i * 10, 1000 + i * 10))
                dirs.append(d)
            # Unrelated directory should not be touched
            other = root / 'other-dir'
            other.mkdir()

            removal.prune_quarantines(root, keep=2)
            # Oldest 3 remove-* directories should be removed
            self.assertFalse(dirs[0].exists())
            self.assertFalse(dirs[1].exists())
            self.assertFalse(dirs[2].exists())
            # Newest 2 should be preserved
            self.assertTrue(dirs[3].exists())
            self.assertTrue(dirs[4].exists())
            # Non-remove dir must be preserved
            self.assertTrue(other.exists())

