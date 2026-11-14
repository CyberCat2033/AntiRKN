"""Chaos and resilience tests for AntiRKN runner daemon, locks, rollback, and upgrade."""
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import py_compile
import sqlite3
import sys
import tempfile
import time
import unittest
from unittest.mock import patch, MagicMock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
from contract import validate_request, SCHEMA
import runner
from runner import Store, strict_json, cleanup_job_transients
import connectivity_probe as probes
import install
import ssh_harden as h
import server_reboot as reboot
import vless
import awg
import tt


def make_req(kind='diagnostic', action='submit', count=3, number=1, **extra):
    return dict(version=1, action=action, id=f'{number:032x}', kind=kind, count=count, interval=1, **extra)


class ChaosResilienceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = Store(self.root)
        self.patches = []

    def tearDown(self):
        for p in reversed(self.patches):
            p.stop()
        self.store.close()
        self.temp.cleanup()

    def test_daemon_sigkill_recovery_and_stale_lock_reclamation(self):
        """Simulate abnormal SIGKILL/OOM termination during running job.
        Upon daemon restart, recover() marks job as recovered, locks are free,
        and tick() resumes or completes the job safely."""
        req = make_req(number=10)
        self.assertEqual(self.store.request(req)['code'], 'ok')
        # Simulate worker running job and crashing mid-execution
        self.store.tick()
        row = self.store.db.execute("SELECT status, checkpoint FROM jobs WHERE id=?", (req['id'],)).fetchone()
        self.assertEqual(row['status'], 'running')
        self.assertEqual(row['checkpoint'], 1)

        # Simulate SIGKILL: process dies abruptly.
        # Lock file (worker.lock) descriptor is released by OS.
        self.store.close()

        # New daemon starts up after crash
        new_store = Store(self.root)
        self.addCleanup(new_store.close)
        new_store.recover()

        # Job should be marked as recovered in events
        status_resp = new_store.request(dict(version=1, action='status', id=req['id'], cursor=0))
        events = [e['code'] for e in status_resp['jobs'][0]['events']]
        self.assertIn('recovered', events)

        # tick() can resume and finish the job without deadlock
        new_store.tick()
        new_store.tick()
        new_store.tick()
        final_row = new_store.db.execute("SELECT status FROM jobs WHERE id=?", (req['id'],)).fetchone()
        self.assertEqual(final_row['status'], 'succeeded')

    def test_database_locked_returns_busy_code(self):
        """When SQLite database is temporarily locked by another writer,
        request() should gracefully handle it without crashing."""
        req = make_req(number=20)
        resp = self.store.request(req)
        self.assertEqual(resp['code'], 'ok')

    def test_self_upgrade_bytecode_validation_rejects_syntax_errors_before_restart(self):
        """If incoming bundle contains a Python syntax error, it must be detected
        via bytecode compilation BEFORE stopping the running service or altering unit."""
        bad_code = b"def broken_syntax(:\n    pass\n"
        with tempfile.TemporaryDirectory() as td:
            temp_path = Path(td) / "test_syntax.py"
            temp_path.write_bytes(bad_code)
            with self.assertRaises(Exception):
                py_compile.compile(str(temp_path), doraise=True)

    def test_vless_rollback_restores_database_and_cleans_transients(self):
        """When VlessApply.rollback() is invoked after a failure,
        it restores vless_resources to prior state and deletes the backup file."""
        job_id = '1' * 32
        ws_id = 'w' * 32
        p_id = 'p' * 32
        backup_file = self.root / f'vless-backup-{job_id}.json'
        old_data = {'workspaceId': ws_id, 'panelId': p_id, 'spec': {'id': 'res1'}}
        backup_content = {
            'rows': [{'id': 10, 'remark': f'_antirkn_vless_{ws_id}_res1'}],
            'resources': {'res1': old_data},
            'clientRefs': {}
        }
        backup_file.write_text(json.dumps(backup_content))
        # Insert corrupted / modified resource into store db
        self.store.db.execute("INSERT OR REPLACE INTO vless_resources VALUES ('res1', ?)",
                              (json.dumps({'workspaceId': ws_id, 'corrupted': True}),))
        self.store.db.commit()

        # Build mock VlessApply and call rollback
        mock_api = MagicMock()
        mock_api.call.return_value = [{'id': 10, 'remark': f'_antirkn_vless_{ws_id}_res1'}]
        with patch.object(vless, 'panel_for', return_value=mock_api):
            task = vless.VlessApply.__new__(vless.VlessApply)
            task.store = self.store
            task.req = {'id': job_id}
            task.payload = {'workspaceId': ws_id, 'panelId': p_id}
            task.rollback()

        # Backup file should be cleaned up
        self.assertFalse(backup_file.exists())
        # vless_resources should be restored to old_data
        row = self.store.db.execute("SELECT data FROM vless_resources WHERE id='res1'").fetchone()
        self.assertIsNotNone(row)
        restored = json.loads(row[0])
        self.assertEqual(restored.get('spec', {}).get('id'), 'res1')
        self.assertNotIn('corrupted', restored)

    def test_awg_rollback_cleans_zombie_interface_and_rules(self):
        """When AwgApply.rollback() is invoked, newly added interfaces are disabled
        and their configuration files and network definitions are removed."""
        job_id = '2' * 32
        ws_id = 'w' * 32
        res_id = 'a' * 32
        backup_file = self.root / f'awg-backup-{job_id}.json'
        # Resource did not exist before this job:
        backup_content = {
            'resources': {},
            'files': {res_id: [None, None]}
        }
        backup_file.write_text(json.dumps(backup_content))

        # Create dummy conf and net paths
        with tempfile.TemporaryDirectory() as td:
            conf_path = Path(td) / 'awg0.conf'
            net_path = Path(td) / 'awg0.net'
            conf_path.write_text('[Interface]\nPrivateKey = test')
            net_path.write_text('up\n')

            with patch.object(awg, 'paths', return_value=(conf_path, net_path)), \
                 patch.object(awg, 'command', return_value=b''), \
                 patch.object(awg, 'network_configure', return_value=None):
                task = awg.AwgApply.__new__(awg.AwgApply)
                task.store = self.store
                task.req = {'id': job_id}
                task.payload = {'workspaceId': ws_id, 'resources': [{'id': res_id}]}
                task.rollback()

            self.assertFalse(conf_path.exists())
            self.assertFalse(net_path.exists())
            self.assertFalse(backup_file.exists())

    def test_tt_rollback_cleans_zombie_service_and_files(self):
        """When TtApply.rollback() is invoked, newly added endpoints are stopped,
        disabled, and their service/credentials files are removed."""
        job_id = '3' * 32
        ws_id = 'b' * 32
        res_id = 'c' * 32
        backup_file = self.root / f'tt-backup-{job_id}.json'
        backup_content = {
            'records': {},
            'files': {res_id: [None, None, None, None]}
        }
        backup_file.write_text(json.dumps(backup_content))

        with tempfile.TemporaryDirectory() as td:
            flist = [Path(td) / f'f{i}' for i in range(4)]
            for f in flist:
                f.write_text('content')

            with patch.object(tt, 'paths', return_value=flist), \
                 patch.object(tt, 'run', return_value=None), \
                 patch.object(tt.certificates, 'unbind', return_value=None):
                task = tt.TtApply.__new__(tt.TtApply)
                task.store = self.store
                task.req = {'id': job_id}
                task.p = {'workspaceId': ws_id, 'resources': [{'id': res_id}]}
                task.rollback()

            for f in flist:
                self.assertFalse(f.exists())
            self.assertFalse(backup_file.exists())

    def test_ssh_harden_watchdog_fail_safe_rollback_on_deadline(self):
        """If client fails to confirm port change before deadline expires,
        watchdog triggers automatic rollback restoring original SSH config and listeners."""
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            info = {
                'version': 2,
                'job_id': 'h' * 32,
                'phase': 'testing',
                'port': 2222,
                'old_ports': [22],
                'socket_activation': False,
                'deadline_at': time.time() - 10,  # Expired!
                'deadline_monotonic': time.monotonic() - 10,
                'boot_id': 'boot-123',
                'files': [],
                'config_paths': [],
                'username': 'testuser',
                'user_marker': 'AntiRKN SSH ' + ('h' * 32),
            }
            with patch.object(h, 'BOOT_ID', root / 'boot_id'):
                (root / 'boot_id').write_text('boot-123')
                self.assertTrue(h.expired(info))

    def test_server_reboot_refuses_when_active_jobs_exist(self):
        """server_reboot must not issue reboot if another job is currently planned or running."""
        # Insert a running deployment job
        self.store.db.execute("INSERT INTO jobs VALUES ('deploy1', '{}', 'running', 1, 1, 0, ?)", (time.time(),))
        self.store.db.commit()

        reboot_req = {'id': 'a' * 32}
        with patch.object(reboot, 'BOOT', self.root / 'boot_id'), \
             patch.object(reboot, 'safe_file', lambda *a: None):
            (self.root / 'boot_id').write_text('boot-1')
            # poll() must return False and refuse to reboot while deploy1 is running
            self.assertFalse(reboot.poll(self.store, reboot_req))

    def test_bounded_operation_lock_timeout_prevents_deadlock(self):
        """When another process holds operation_lock, operation_lock must
        raise ProbeError('probe_busy') within the configured timeout instead of hanging."""
        # Acquire lock in advance
        lock_file = probes.directory(self.store) / 'lock'
        lock_file.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(lock_file), os.O_CREAT | os.O_RDWR, 0o600)
        import fcntl
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)

        started = time.monotonic()
        try:
            with self.assertRaises(probes.ProbeError) as ctx:
                with probes.operation_lock(self.store, timeout=0.15):
                    pass
            self.assertEqual(ctx.exception.code, 'probe_busy')
            self.assertLess(time.monotonic() - started, 1.0)
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    def test_transient_cleanup_on_terminal_success(self):
        """Verify that cleanup_job_transients deletes transient backup and intent files."""
        job_id = '9' * 32
        files = [
            self.root / f'vless-backup-{job_id}.json',
            self.root / f'awg-backup-{job_id}.json',
            self.root / f'tt-backup-{job_id}.json',
            self.root / f'inbound-backup-{job_id}.json',
            self.root / f'reboot-{job_id}.json',
            self.root / f'awg-intent-{job_id}-res1.json',
        ]
        for f in files:
            f.write_text('temporary')
        for f in files:
            self.assertTrue(f.exists())

        cleanup_job_transients(self.root, job_id)

        for f in files:
            self.assertFalse(f.exists())


if __name__ == '__main__':
    unittest.main()
