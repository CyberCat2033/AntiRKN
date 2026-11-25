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


if __name__ == '__main__':
    unittest.main()
