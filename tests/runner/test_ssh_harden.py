"""SSH access transaction regression tests; all system paths are isolated."""
import concurrent.futures
from contextlib import ExitStack
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
import ssh_harden as h
from runner import Store

JOB = 'a' * 32


class HardeningTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.root = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        values = dict(RUNNER_DIR=self.root, BACKUP_DIR=self.root / 'backups',
                      SSH_DIRECTORY=self.root / 'ssh', SSH_CONFIG=self.root / 'ssh/sshd_config',
                      SUDO_DIRECTORY=self.root / 'sudoers', UNIT_DIRECTORY=self.root / 'systemd',
                      SOCKET_CONFIG=self.root / 'systemd/ssh.socket.d/99-antirkn-harden.conf',
                      BOOT_ID=self.root / 'boot_id', HOME_DIRECTORY=self.root / 'home',
                      ROOT_AUTH=self.root / 'root_keys', UFW_FILES=(self.root / 'ufw4', self.root / 'ufw6'))
        for key, value in values.items():
            self.stack.enter_context(patch.object(h, key, value))
        h.SSH_DIRECTORY.mkdir()
        h.SUDO_DIRECTORY.mkdir()
        h.BOOT_ID.write_text('fixture-boot')
        h.SSH_CONFIG.write_text('Port 22\nPermitRootLogin yes\n')
        self.store = Store(self.root)
        self.addCleanup(self.store.close)
        self.req = dict(version=1, action='submit', id=JOB, kind='ssh_harden', count=7, interval=1,
                        fingerprint='f' * 64, payload=json.dumps(dict(username='fixture', port=2222,
                        sudoPassword='fixture-password', disableRootLogin=True)))
        self.store.request(self.req)
        self.store.db.execute("UPDATE jobs SET status='running',checkpoint=6 WHERE id=?", (JOB,))
        self.store.db.commit()
        files = [h.snapshot(h.SSH_CONFIG), h.snapshot(h.SOCKET_CONFIG),
                 h.snapshot(h.SUDO_DIRECTORY / '99-antirkn-fixture')]
        for entry in files:
            entry['allowed'] = [h.digest(h.content(entry))]
        self.info = dict(version=2, job_id=JOB, username='fixture', port=2222,
                         old_ports=[22], socket_activation=False, listeners=['0.0.0.0:22'],
                         disable_root=True, deadline_at=time.time()+300,
                         deadline_monotonic=time.monotonic()+300, boot_id='fixture-boot',
                         phase='testing', files=files, config_paths=[str(h.SSH_CONFIG)],
                         user_marker='AntiRKN SSH ' + JOB)
        h.save_info(JOB, self.info)
        self.run = self.stack.enter_context(patch.object(h, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')))
        self.reload = self.stack.enter_context(patch.object(h, 'reload_ssh_service'))
        self.policy = self.stack.enter_context(patch.object(h, 'verify_policy'))
        self.listeners = self.stack.enter_context(patch.object(h, 'verify_listeners'))
        self.user = SimpleNamespace(pw_uid=1001, pw_gid=1001, pw_gecos=self.info['user_marker'],
                                    pw_dir=str(h.HOME_DIRECTORY / 'fixture'))
        self.users = self.stack.enter_context(patch.object(h, 'user_exists', return_value=self.user))
        self.stack.enter_context(patch.dict(os.environ, {'SUDO_USER': 'fixture', 'SUDO_UID': '1001'}))

    def rpc(self, action):
        return self.store.request(dict(version=1, action='ssh_harden_' + action, id=JOB))

    def set_info(self, **values):
        self.info.update(values)
        h.save_info(JOB, self.info)

    def test_confirm_is_provisional_and_commit_finishes(self):
        reply = self.rpc('confirm')
        self.assertEqual(reply['code'], 'ok')
        self.assertTrue(reply['sshHardenResult']['finalized'])
        self.assertFalse(reply['sshHardenResult']['confirmed'])
        self.assertEqual(h.load_info(JOB)['phase'], 'finalizing')
        self.assertEqual(self.store.db.execute('SELECT status FROM jobs').fetchone()[0], 'running')
        self.assertTrue(self.rpc('commit')['sshHardenResult']['confirmed'])
        self.assertEqual(self.store.db.execute('SELECT status FROM jobs').fetchone()[0], 'succeeded')
        self.assertTrue(self.rpc('commit')['sshHardenResult']['confirmed'])
        self.assertEqual(self.rpc('abort')['code'], 'ssh_harden_conflict')

    def test_cancelled_job_cannot_disable_root(self):
        original = h.SSH_CONFIG.read_bytes()
        self.assertTrue(self.rpc('abort')['sshHardenResult']['aborted'])
        self.assertEqual(self.rpc('confirm')['code'], 'ssh_harden_conflict')
        self.assertEqual(self.rpc('commit')['code'], 'ssh_harden_conflict')
        self.assertEqual(h.SSH_CONFIG.read_bytes(), original)

    def test_early_confirmation_and_wrong_job_kind_are_rejected(self):
        self.store.db.execute('UPDATE jobs SET checkpoint=2')
        self.store.db.commit()
        self.assertEqual(self.rpc('confirm')['code'], 'ssh_harden_conflict')
        self.store.db.execute('UPDATE jobs SET request=?', (json.dumps(dict(kind='diagnostic')),))
        self.store.db.commit()
        self.assertEqual(self.rpc('abort')['code'], 'ssh_harden_conflict')

    def test_deadline_or_boot_change_rejects_confirm_and_rolls_back(self):
        for change in (dict(deadline_at=0), dict(boot_id='old-boot')):
            with self.subTest(change=change):
                self.set_info(**change)
                self.assertEqual(self.rpc('confirm')['code'], 'ssh_harden_conflict')
                self.assertEqual(h.load_info(JOB)['phase'], 'rolled_back')
                self.store.db.execute("UPDATE jobs SET status='running'")
                self.store.db.commit()
                self.info.update(deadline_at=time.time()+300, boot_id='fixture-boot', phase='testing')

    def test_reload_failure_restores_original_configuration(self):
        original = h.SSH_CONFIG.read_bytes()
        self.reload.side_effect = [OSError('fixture failure'), None]
        self.assertEqual(self.rpc('confirm')['code'], 'ssh_harden_failed')
        self.assertEqual(h.SSH_CONFIG.read_bytes(), original)
        self.assertEqual(h.load_info(JOB)['phase'], 'rolled_back')

    def test_failed_rollback_never_reports_success_or_deletes_user(self):
        self.reload.side_effect = OSError('fixture recovery failure')
        self.assertEqual(self.rpc('abort')['code'], 'ssh_harden_failed')
        self.assertEqual(h.load_info(JOB)['phase'], 'rollback_failed')
        self.assertEqual(self.store.db.execute('SELECT status FROM jobs').fetchone()[0], 'needs_attention')
        self.assertFalse(any(c.args[0][0].endswith('userdel') for c in self.run.call_args_list))
        self.reload.side_effect = None
        self.assertTrue(self.rpc('abort')['sshHardenResult']['aborted'])

    def test_watchdog_recovers_without_stopping_its_own_service(self):
        self.set_info(deadline_at=0)
        h.watchdog_loop(JOB)
        self.assertEqual(h.load_info(JOB)['phase'], 'rolled_back')
        self.assertFalse(any('stop' in c.args[0] for c in self.run.call_args_list))

    def test_watchdog_is_persistent_and_armed_before_user_creation(self):
        h.arm_watchdog(JOB)
        unit = (h.UNIT_DIRECTORY / h.unit_name(JOB)).read_text()
        self.assertIn('WantedBy=multi-user.target', unit)
        self.assertIn('Restart=on-failure', unit)
        self.assertNotIn('Before=ssh', unit)  # No sockets.target/basic.target boot cycle.
        self.assertIn(JOB, unit)
        self.assertTrue(any('enable' in c.args[0] for c in self.run.call_args_list))

    def test_pending_user_cleanup_never_restarts_restored_ssh(self):
        def admin(command, **kwargs):
            if command[0].endswith('/userdel'):
                raise subprocess.CalledProcessError(8, command)
            return subprocess.CompletedProcess(command, 0, '', '')
        self.run.side_effect = admin
        for _ in range(3):
            reply = self.rpc('abort')
            self.assertEqual(reply['code'], 'ok')
            self.assertEqual(reply['sshHardenResult']['phase'], 'rolling_back')
            self.assertFalse(reply['sshHardenResult']['aborted'])
        self.assertEqual(self.reload.call_count, 1)
        self.assertTrue(h.load_info(JOB)['access_restored'])
        self.run.side_effect = None
        self.assertTrue(self.rpc('abort')['sshHardenResult']['aborted'])
        self.assertEqual(self.reload.call_count, 1)

    def test_completed_legacy_journal_does_not_block_upgrade(self):
        self.set_info(phase='rolled_back')
        legacy_id = 'b' * 32
        legacy = h.backup_path(legacy_id)
        legacy.mkdir()
        (legacy / 'info.json').write_text(json.dumps(dict(username='legacy')))
        self.store.db.execute("UPDATE jobs SET status='failed' WHERE id=?", (JOB,))
        self.store.db.commit()
        self.store.request({**self.req, 'id': legacy_id})
        self.store.db.execute("UPDATE jobs SET status='succeeded' WHERE id=?", (legacy_id,))
        self.store.db.commit()
        token = h.RUNNER_DIR / 'ssh_confirmed' / ('confirmed_' + legacy_id)
        token.parent.mkdir(); token.touch()
        state = dict(files=[h.snapshot(h.SSH_CONFIG)], ports=[22], socket_activation=False,
                     listeners=['0.0.0.0:22'], root='yes')
        with patch.object(h, 'host_state', return_value=state), patch.object(h, 'compute_fingerprint', return_value='f'*64), patch.object(h, 'free_port', return_value=True):
            self.users.return_value = None
            self.assertEqual(h.SshHardenJob(self.store, self.req).prepare()['phase'], 'staging')
            self.set_info(phase='rolled_back')
            token.unlink()
            with self.assertRaises(h.SshHardenError):
                h.SshHardenJob(self.store, self.req).prepare()

    def test_root_channel_cannot_commit_new_access(self):
        self.rpc('confirm')
        with patch.dict(os.environ, {'SUDO_USER': 'root', 'SUDO_UID': '0'}):
            self.assertEqual(self.rpc('commit')['code'], 'ssh_harden_conflict')
        self.assertEqual(h.load_info(JOB)['phase'], 'finalizing')

    def test_deadline_before_commit_preserves_rollback(self):
        self.rpc('confirm')
        info = h.load_info(JOB)
        info['deadline_at'] = 0
        h.save_info(JOB, info)
        self.assertEqual(self.rpc('commit')['code'], 'ssh_harden_conflict')
        h.watchdog_loop(JOB)
        self.assertEqual(h.load_info(JOB)['phase'], 'rolled_back')

    def test_external_configuration_change_is_not_overwritten(self):
        h.SSH_CONFIG.write_text('Port 2225\n')
        self.assertEqual(self.rpc('confirm')['code'], 'ssh_harden_failed')
        self.assertEqual(h.SSH_CONFIG.read_text(), 'Port 2225\n')
        self.assertEqual(h.load_info(JOB)['phase'], 'rollback_failed')

    def test_duplicate_confirm_keeps_same_deadline(self):
        first = self.rpc('confirm')['sshHardenResult']
        second = self.rpc('confirm')['sshHardenResult']
        self.assertEqual(first, second)
        self.assertEqual(self.reload.call_count, 1)

    def test_commit_and_abort_are_serialized(self):
        self.rpc('confirm')
        def request(action):
            store = Store(self.root)
            try:
                return store.request(dict(version=1, action='ssh_harden_' + action, id=JOB))['code']
            finally:
                store.close()
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            codes = list(pool.map(request, ['commit', 'abort']))
        self.assertEqual(sorted(codes), ['ok', 'ssh_harden_conflict'])
        self.assertIn(h.load_info(JOB)['phase'], h.TERMINAL)

    def test_payload_rejects_password_line_injection_and_empty_password(self):
        for password in ('', 'one\nroot:two', 'bad\rline', 'bad\x00value'):
            payload = json.loads(self.req['payload'])
            payload['sudoPassword'] = password
            with self.subTest(password=repr(password)), self.assertRaises(h.SshHardenError):
                h.parse_payload({**self.req, 'payload': json.dumps(payload)}, True)

    def test_sudoers_is_validated_with_full_configuration(self):
        h.SshHardenJob(self.store, self.req).sudoers(self.info)
        text = (h.SUDO_DIRECTORY / '99-antirkn-fixture').read_text()
        self.assertIn('PASSWD: ALL', text)
        self.run.assert_called_with(['/usr/sbin/visudo', '-c'])

    def test_existing_user_home_or_sudoers_cannot_be_claimed(self):
        state = dict(files=[h.snapshot(h.SSH_CONFIG)], ports=[22], socket_activation=False,
                     listeners=['0.0.0.0:22'], root='yes')
        # Exercise preflight directly without a pre-existing journal for this ID.
        (h.backup_path(JOB) / 'info.json').unlink()
        with patch.object(h, 'host_state', return_value=state), patch.object(h, 'compute_fingerprint', return_value='f'*64):
            with self.assertRaises(h.SshHardenError):
                h.SshHardenJob(self.store, self.req).prepare()

    def test_render_removes_all_ports_and_disables_root_in_match(self):
        h.SSH_CONFIG.write_text('Port=22\nPort 2200\nPermitRootLogin yes\nMatch Address 127.0.0.1\n PermitRootLogin yes\n')
        rendered = h.render_config(h.snapshot(h.SSH_CONFIG), [2222], True).decode()
        self.assertNotIn('Port=22', rendered)
        self.assertNotIn('Port 2200', rendered)
        self.assertNotIn('PermitRootLogin yes', rendered)
        self.assertTrue(rendered.startswith('# AntiRKN SSH access policy\nPort 2222\nPermitRootLogin no'))

    def test_config_walk_follows_include_and_rejects_cycles_and_symlinks(self):
        child = h.SSH_DIRECTORY / 'child.conf'
        child.write_text('PermitRootLogin yes\n')
        h.SSH_CONFIG.write_text(f'Include {child}\nPort 22\n')
        self.assertEqual(len(h.config_files()), 2)
        child.write_text(f'Include {h.SSH_CONFIG}\n')
        with self.assertRaises(h.SshHardenError):
            h.config_files()
        child.unlink()
        child.symlink_to(h.SSH_CONFIG)
        with self.assertRaises(h.SshHardenError):
            h.config_files()

    def test_rollback_preserves_preexisting_socket_dropin_and_modes(self):
        h.SOCKET_CONFIG.parent.mkdir(parents=True)
        h.SOCKET_CONFIG.write_text('[Socket]\nListenStream=127.0.0.1:22\n')
        h.SOCKET_CONFIG.chmod(0o640)
        entry = h.snapshot(h.SOCKET_CONFIG)
        entry['allowed'] = [h.digest(h.content(entry)), h.digest(b'fixture-staged')]
        self.info['files'][1] = entry
        self.set_info()
        h.SOCKET_CONFIG.write_bytes(b'fixture-staged')
        self.assertTrue(self.rpc('abort')['sshHardenResult']['aborted'])
        self.assertEqual(h.SOCKET_CONFIG.read_bytes(), h.content(entry))
        self.assertEqual(h.SOCKET_CONFIG.stat().st_mode & 0o777, 0o640)

    def test_unowned_account_is_never_deleted(self):
        self.user.pw_gecos = 'someone else'
        self.assertEqual(self.rpc('abort')['code'], 'ssh_harden_failed')
        self.assertFalse(any(c.args[0][0].endswith('userdel') for c in self.run.call_args_list))


if __name__ == '__main__':
    unittest.main()
