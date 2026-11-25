"""Update jobs after a crash between a step and its terminal status, deadman
windows whose job update was lost, rollbacks that must not report success
they did not reach, and the raw-binary staging name."""
import json
import os
import sqlite3
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))

import component_upgrade as cu
import components
from component_upgrade import ComponentUpgradeError, ComponentUpgradeJob, ComponentUpgrader
from components import ComponentError, ComponentInstaller
from panel import PanelInstaller
from panel_update import PanelUpdate
from runner import Store

OK = MagicMock(returncode=0)


def upgrade_request(job_id):
    return {'version': 1, 'action': 'submit', 'id': job_id, 'kind': 'component_upgrade_apply', 'count': 6,
            'interval': 1, 'payload': json.dumps({'component': 'xray', 'version': '26.11.9'}), 'fingerprint': 'b' * 64}


class Base(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = Store(self.root)
        self.addCleanup(self.store.close)

    def insert(self, request, status='running', checkpoint=6):
        self.store.db.execute('INSERT INTO jobs VALUES (?,?,?,?,0,0,?)',
                              (request['id'], json.dumps(request), status, checkpoint, time.time()))
        self.store.db.commit()

    def job(self, job_id):
        return self.store.request(dict(version=1, action='status', id=job_id, cursor=0))['jobs'][0]

    def codes(self, job_id):
        return [e['code'] for e in self.job(job_id)['events']]


class AllStepsDoneTests(Base):
    """Checkpoint == count but still running: finish, never call step(count)."""

    def test_component_upgrade_keeps_the_window_and_drops_staging(self):
        request = upgrade_request('1' * 32)
        self.insert(request)
        work = self.root / ('upgrade-' + request['id'])
        (work / 'backup').mkdir(parents=True)
        (work / 'staging').mkdir()
        (work / 'release_archive').write_bytes(b'x')
        with patch('component_upgrade.subprocess.run'):
            cu.arm_deadman(self.store, request)
        with patch.object(ComponentUpgradeJob, 'step', side_effect=AssertionError('step past the end')):
            self.store.tick()
        self.assertEqual(self.job(request['id'])['status'], 'succeeded')
        self.assertTrue((work / 'backup').exists())
        self.assertFalse((work / 'staging').exists())
        self.assertFalse((work / 'release_archive').exists())

    def test_real_component_upgrade_step_past_the_end_is_not_reached(self):
        request = upgrade_request('2' * 32)
        self.insert(request)
        self.store.tick()  # Used to raise IndexError in step(6) and crash the worker.
        self.assertEqual(self.job(request['id'])['status'], 'succeeded')

    def test_panel_update_finishes_and_drops_its_backups(self):
        request = dict(version=1, action='submit', kind='panel_update', id='3' * 32,
                       panelId='a' * 32, count=6, interval=1, fingerprint='b' * 64)
        self.insert(request)
        update = PanelUpdate(self.store, request)
        update.directory.mkdir()
        (update.directory / 'backup').mkdir()
        self.store.tick()
        self.assertEqual(self.job(request['id'])['status'], 'succeeded')
        self.assertEqual(self.codes(request['id'])[-1], 'succeeded')
        self.assertFalse(update.directory.exists())

    def test_panel_install_finishes(self):
        request = dict(version=1, action='submit', kind='panel_install', id='4' * 32,
                       count=6, interval=1, port=2053, fingerprint='a' * 64)
        self.insert(request)
        with patch.object(PanelInstaller, 'step', side_effect=AssertionError('step past the end')):
            self.store.tick()
        self.assertEqual(self.job(request['id'])['status'], 'succeeded')

    def test_component_install_finishes_and_slims(self):
        request = dict(version=1, action='submit', kind='component_install', component='trusttunnel', payload='',
                       id='5' * 32, count=6, interval=1, fingerprint='a' * 64)
        self.insert(request)
        with patch.object(ComponentInstaller, 'step', side_effect=AssertionError('step past the end')), \
             patch('runner.slim_finished_job') as slim:
            self.store.tick()
        self.assertEqual(self.job(request['id'])['status'], 'succeeded')
        slim.assert_called_once_with(self.root, request['id'])

    def test_unfinished_job_still_runs_its_last_step(self):
        request = upgrade_request('6' * 32)
        self.insert(request, checkpoint=5)
        with patch.object(ComponentUpgradeJob, 'step') as step:
            self.store.tick()
        step.assert_called_once_with(5)
        self.assertEqual(self.job(request['id'])['status'], 'succeeded')


class DeadmanOutcomeTests(Base):
    def window(self, job_id, **state):
        request = upgrade_request(job_id)
        self.insert(request, status='succeeded')
        work = self.root / ('upgrade-' + job_id)
        (work / 'backup').mkdir(parents=True)
        (work / 'deadman.json').write_text(json.dumps(dict(id=job_id, deadline=0, confirmed=False, **state)))
        return work

    def test_rolled_back_window_settles_a_job_left_succeeded(self):
        job_id = '7' * 32
        work = self.window(job_id, rolledBack=True)
        with patch('component_upgrade._late_rollback') as late:
            cu.recover_deadmen(self.store)
            cu.recover_deadmen(self.store)  # Settled once.
        late.assert_not_called()
        self.assertEqual(self.job(job_id)['status'], 'failed')
        self.assertEqual(self.codes(job_id).count('upgrade_rolled_back'), 1)
        self.assertFalse((work / 'backup').exists())
        self.assertTrue((work / 'deadman.json').exists())

    def test_failed_window_rollback_needs_attention_and_keeps_the_backup(self):
        job_id = '8' * 32
        work = self.window(job_id, rollbackFailed=True)
        cu.recover_deadmen(self.store)
        self.assertEqual(self.job(job_id)['status'], 'needs_attention')
        self.assertEqual(self.codes(job_id)[-1], 'upgrade_rollback_failed')
        self.assertTrue((work / 'backup').exists())

    def test_crash_after_the_window_write_is_recovered(self):
        job_id = '9' * 32
        self.window(job_id)
        settle = cu._settle_window_job
        with patch('component_upgrade._late_rollback'), \
             patch('component_upgrade._settle_window_job', side_effect=SystemExit('crash')):
            with self.assertRaises(SystemExit):
                cu.fire_deadman(self.store, job_id, wait=False)
        self.assertEqual(self.job(job_id)['status'], 'succeeded')
        with patch('component_upgrade._late_rollback') as late, \
             patch('component_upgrade._settle_window_job', side_effect=settle):
            cu.recover_deadmen(self.store)
        late.assert_not_called()
        self.assertEqual(self.job(job_id)['status'], 'failed')

    def test_a_job_that_moved_on_is_not_changed(self):
        job_id = 'a' * 32
        self.window(job_id, rolledBack=True)
        with self.store.db:
            self.store.db.execute("UPDATE jobs SET status='cancelled' WHERE id=?", (job_id,))
        cu.recover_deadmen(self.store)
        self.assertEqual(self.job(job_id)['status'], 'cancelled')


class UpgradeRollbackTruthTests(Base):
    def switched(self):
        binary = self.root / 'xray'
        binary.write_bytes(b'old')
        db = self.root / 'x-ui.db'
        self.set_db(db, 1)
        request = upgrade_request('b' * 32)
        upgrader = ComponentUpgrader(self.store, request, json.loads(request['payload']))
        upgrader.detection = dict(installed=True, binaryPath=str(binary), units=['x.service'], arch='x86_64', dbPath=str(db))
        with patch('component_upgrade.probe_component', return_value={}):
            upgrader.backup()
        staged = self.root / 'staged'
        staged.write_bytes(b'new')
        with patch('component_upgrade.subprocess.run', return_value=OK):
            upgrader.apply_switch(staged)
        self.set_db(db, 2)
        return upgrader, binary, db

    @staticmethod
    def set_db(path, value):
        con = sqlite3.connect(str(path))
        con.execute('CREATE TABLE IF NOT EXISTS t (v INT)')
        con.execute('DELETE FROM t')
        con.execute('INSERT INTO t VALUES (?)', (value,))
        con.commit()
        con.close()

    @staticmethod
    def db_value(path):
        con = sqlite3.connect(str(path))
        try:
            return con.execute('SELECT v FROM t').fetchone()[0]
        finally:
            con.close()

    def test_unit_that_does_not_stop_replaces_nothing(self):
        upgrader, binary, db = self.switched()
        failing = lambda cmd, **kw: MagicMock(returncode=1 if 'stop' in cmd else 0)
        with patch('component_upgrade.subprocess.run', side_effect=failing), \
             self.assertRaises(ComponentUpgradeError) as ctx:
            upgrader.rollback()
        self.assertEqual(ctx.exception.code, 'upgrade_rollback_failed')
        self.assertEqual(binary.read_bytes(), b'new')
        self.assertEqual(self.db_value(db), 2)
        self.assertTrue((upgrader.backup_dir / 'db_backup.sqlite').exists())
        self.assertFalse(json.loads((upgrader.work_dir / 'rollback.json').read_text())['done'])

    def test_unit_that_does_not_come_back_is_not_a_rollback(self):
        upgrader, binary, _db = self.switched()
        inactive = lambda cmd, **kw: MagicMock(returncode=3 if 'is-active' in cmd else 0)
        with patch('component_upgrade.subprocess.run', side_effect=inactive), \
             patch('component_upgrade.time.sleep'), \
             self.assertRaises(ComponentUpgradeError) as ctx:
            cu_monotonic = iter(range(0, 100, 5))
            with patch('component_upgrade.time.monotonic', side_effect=lambda: next(cu_monotonic)):
                upgrader.rollback()
        self.assertEqual(ctx.exception.code, 'upgrade_rollback_failed')
        self.assertEqual(binary.read_bytes(), b'old')  # Restored, but not reported as done.
        self.assertFalse(json.loads((upgrader.work_dir / 'rollback.json').read_text())['done'])

    def test_clean_rollback_restores_and_is_done(self):
        upgrader, binary, db = self.switched()
        with patch('component_upgrade.subprocess.run', return_value=OK):
            self.assertTrue(upgrader.rollback())
        self.assertEqual(binary.read_bytes(), b'old')
        self.assertEqual(self.db_value(db), 1)
        self.assertTrue(json.loads((upgrader.work_dir / 'rollback.json').read_text())['done'])


class ComponentSwitchBackTests(Base):
    PREVIOUS, TARGET = 'a' * 64, 'b' * 64

    def installer(self, checkpoint, previous=True):
        base = self.root / 'lib'
        root = base / 'amneziawg'
        for release in (self.PREVIOUS, self.TARGET):
            (root / 'versions' / release).mkdir(parents=True)
            (root / 'versions' / release / 'manifest.json').write_text('{}')
        os.symlink('versions/' + self.TARGET, root / 'current')
        request = dict(version=1, action='submit', kind='component_install', component='amneziawg', payload='',
                       id='c' * 32, count=6, interval=1, fingerprint='a' * 64)
        self.insert(request, checkpoint=checkpoint)
        patcher = patch.object(components, 'BASE', base)
        patcher.start()
        self.addCleanup(patcher.stop)
        installer = ComponentInstaller(self.store, request)
        installer.directory.mkdir(parents=True)
        plan = dict(previous={'release': self.PREVIOUS} if previous else None, activeUnits=['antirkn-awg@awg0.service'])
        (installer.directory / 'plan.json').write_text(json.dumps(plan))
        (installer.directory / 'target.json').write_text(json.dumps({'release': self.TARGET}))
        return installer, root

    def test_failure_after_the_pointer_switch_points_back(self):
        installer, root = self.installer(checkpoint=4)
        with patch('components.subprocess.run') as run:
            self.assertEqual(installer.abort(), 'cancelled')
            self.assertEqual(installer.abort(), 'cancelled')  # Repeated: no change.
        self.assertEqual(os.readlink(root / 'current'), 'versions/' + self.PREVIOUS)
        self.assertEqual(run.call_count, 0)  # Step 4 restarted nothing.

    def test_from_step_five_the_units_restart_on_the_previous_version(self):
        installer, root = self.installer(checkpoint=5)
        with patch('components.subprocess.run', return_value=OK) as run:
            self.assertEqual(installer.abort(), 'cancelled')
        self.assertEqual(os.readlink(root / 'current'), 'versions/' + self.PREVIOUS)
        self.assertEqual([c.args[0][1] for c in run.call_args_list], ['restart', 'is-active'])

    def test_without_a_previous_version_it_stays_partial(self):
        installer, root = self.installer(checkpoint=4, previous=False)
        self.assertEqual(installer.abort(), 'partially_applied')
        self.assertEqual(os.readlink(root / 'current'), 'versions/' + self.TARGET)

    def test_previous_version_that_does_not_start_is_not_rolled_back(self):
        installer, root = self.installer(checkpoint=5)
        plan = json.loads((installer.directory / 'plan.json').read_text())
        failing = MagicMock(side_effect=subprocess.CalledProcessError(1, 'systemctl'))
        with patch('components.subprocess.run', failing), self.assertRaises(ComponentError) as ctx:
            installer.restore_previous(plan)
        self.assertEqual(ctx.exception.code, 'upgrade_rollback_failed')
        self.assertTrue((installer.directory / 'target.json').exists())
        with patch('components.subprocess.run', failing):
            self.assertEqual(installer.abort(), 'partially_applied')


class RawBinaryNameTests(unittest.TestCase):
    def test_binary_name_must_be_a_plain_file_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = root / 'release_archive'
            archive.write_bytes(b'\x7fELF raw binary')
            for name in ('../escape', '/etc/passwd', 'a/b', '..', '.', '', 'x' * 65, 'nul\x00', 7):
                with self.subTest(name=name):
                    dest = root / 'staging'
                    with self.assertRaises(ComponentUpgradeError) as ctx:
                        cu.extract_archive_safe(archive, dest, binary_name=name)
                    self.assertEqual(ctx.exception.code, 'upgrade_syntax_failed')
                    self.assertFalse(dest.exists())
                    self.assertFalse((root / 'escape').exists())
            cu.extract_archive_safe(archive, root / 'staging', binary_name='xray-linux-amd64')
            self.assertEqual((root / 'staging' / 'xray-linux-amd64').read_bytes(), archive.read_bytes())



class ProbeBinaryTests(unittest.TestCase):
    def test_arm64_panel_gets_its_own_core_and_amd64_stays_first_on_x86(self):
        import upgrade_probe
        with tempfile.TemporaryDirectory() as tmp:
            amd, arm = Path(tmp) / 'xray-linux-amd64', Path(tmp) / 'xray-linux-arm64'
            with patch.object(upgrade_probe, 'XRAY_BINARIES', (amd, arm)):
                arm.write_bytes(b'core')
                for machine in ('aarch64', 'x86_64'):
                    with patch('upgrade_probe.platform.machine', return_value=machine):
                        self.assertEqual(upgrade_probe.xray_binary(), arm)
                amd.write_bytes(b'core')
                with patch('upgrade_probe.platform.machine', return_value='x86_64'):
                    self.assertEqual(upgrade_probe.xray_binary(), amd)
                with patch('upgrade_probe.platform.machine', return_value='aarch64'):
                    self.assertEqual(upgrade_probe.xray_binary(), arm)
                target = dict(port=1, user=dict(id='u'), stream={})
                with patch('upgrade_probe.platform.machine', return_value='aarch64'), \
                     patch.object(upgrade_probe, 'vless_targets', return_value={'vless:1': target}), \
                     patch.object(upgrade_probe, '_wait_port'), \
                     patch.object(upgrade_probe.subprocess, 'Popen', side_effect=OSError('stop')) as popen:
                    try:
                        upgrade_probe.probe_vless()
                    except OSError:
                        pass
                self.assertEqual(popen.call_args.args[0][0], str(arm))

    def test_awg_from_the_distribution_package_is_probed(self):
        import upgrade_probe
        with tempfile.TemporaryDirectory() as tmp:
            local, system = Path(tmp) / 'local-awg', Path(tmp) / 'usr-bin-awg'
            system.write_bytes(b'awg')
            outputs = {('show', 'interfaces'): 'awg0\n', ('show', 'awg0', 'listen-port'): '51820\n'}
            run = lambda argv, **kw: MagicMock(stdout=outputs[tuple(argv[1:])])
            with patch.object(upgrade_probe, 'AWG_BINARIES', (local, system)), \
                 patch('upgrade_probe.sysutil_run', side_effect=run) as calls:
                self.assertEqual(upgrade_probe.probe_awg(), {'awg:awg0': True})
            self.assertEqual({c.args[0][0] for c in calls.call_args_list}, {str(system)})

if __name__ == '__main__':
    unittest.main()
