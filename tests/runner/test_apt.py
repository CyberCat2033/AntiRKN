import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
from apt import AptError, parse_packages
from runner import Store

OUTPUT = 'Inst fixture [1.0] (2.0 local [amd64])\nConf fixture (2.0 local [amd64])\n'
class AptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.store = Store(self.temp.name)
        self.addCleanup(self.temp.cleanup); self.addCleanup(self.store.close)
        self.prereq = patch('apt.prerequisites'); self.prereq.start(); self.addCleanup(self.prereq.stop)
        self.dpkg = patch('apt.dpkg_interrupted', return_value=False); self.dpkg.start(); self.addCleanup(self.dpkg.stop)
    def request(self, kind='apt_update', number=1):
        r = dict(version=1, action='submit', id=f'{number:032x}', kind=kind, count=2, interval=1)
        if kind == 'apt_upgrade': r['fingerprint'] = 'a' * 64
        return r
    def result(self, r):
        return self.store.request(dict(version=1, action='status', id=r['id'], cursor=0))['jobs'][0]
    def test_parse_rejects_removals_and_unsafe_names_and_supports_new_packages(self):
        self.assertEqual(parse_packages(OUTPUT), [dict(name='fixture', installed='1.0', version='2.0')])
        self.assertEqual(parse_packages('Inst new-package (1.0 local [amd64])\n'),
                         [dict(name='new-package', installed='new', version='1.0')])
        for output in ['Remv fixture [1.0]', 'Inst bad;id [1] (2 local)', 'Inst bad;id (2 local)']:
            with self.assertRaises(AptError): parse_packages(output)
    def test_preview_never_refreshes_indexes_and_changed_plan_blocks_upgrade(self):
        with patch('apt.run', return_value=OUTPUT) as run:
            preview = self.store.request(dict(version=1, action='apt_plan'))['aptPlan']
            self.assertEqual(preview['packages'][0]['version'], '2.0')
            self.assertEqual(run.call_args.args[0], ['--simulate', 'upgrade'])
            r = self.request('apt_upgrade'); self.store.request(r); self.store.tick()
            self.assertEqual(self.result(r)['status'], 'failed')
            self.assertEqual(self.result(r)['events'][-1]['code'], 'apt_conflict')
            self.assertTrue(all(c.kwargs.get('capture') for c in run.call_args_list))
    def test_cancel_before_execution_has_no_apt_effect(self):
        r = self.request(); self.store.request(r)
        self.store.request(dict(version=1, action='cancel', id=r['id']))
        with patch('apt.run') as run:
            self.store.tick(); run.assert_not_called()
        self.assertEqual(self.result(r)['status'], 'cancelled')
    def test_upgrade_freezes_versions_and_uses_dedicated_system_unit(self):
        r = self.request('apt_upgrade'); self.store.request(r)
        with patch('apt.plan', return_value=dict(fingerprint='a'*64, packages=parse_packages(OUTPUT))), patch('apt.run', return_value=OUTPUT) as run:
            self.store.tick(); self.store.tick()
        self.assertEqual(self.result(r)['status'], 'succeeded')
        actual = [c for c in run.call_args_list if c.kwargs.get('unit')]
        self.assertIn('fixture=2.0', actual[0].args[0])
        self.assertIn('--only-upgrade', actual[0].args[0])
        self.assertEqual(len(actual), 2)
        self.assertEqual(self.store.request(r)['jobs'][0]['status'], 'succeeded')
    def test_running_apply_unit_is_awaited_not_replayed_after_worker_recovery(self):
        r = self.request(); self.store.request(r)
        marker = Path(self.temp.name) / ('apt-' + r['id'] + '.started')
        marker.write_text('running')
        self.store.recover()
        with patch('apt.is_unit_active', return_value=True), patch('apt.run') as run:
            self.assertEqual(self.store.tick(), 1)
            run.assert_not_called()
        self.assertEqual(self.result(r)['status'], 'running')
        self.assertEqual(self.result(r)['checkpoint'], 0)

    def test_finished_apply_after_worker_crash_is_not_reported_failed(self):
        # The worker died while apt ran; the run recorded its exit status.
        r = self.request(); self.store.request(r)
        marker = Path(self.temp.name) / ('apt-' + r['id'] + '.started')
        marker.write_text('exit 0')
        self.store.recover()
        with patch('apt.is_unit_active', return_value=False), patch('apt.unit_properties', return_value={}), \
                patch('apt.run') as run:
            self.store.tick()
            self.assertEqual(self.result(r)['checkpoint'], 1)
            self.store.tick()
        self.assertEqual(self.result(r)['status'], 'succeeded')
        # Only the read-only check ran; the apply was never repeated.
        self.assertEqual([c.kwargs.get('unit') for c in run.call_args_list], ['antirkn-apt-' + r['id'] + '-check'])

    def test_unit_result_is_read_when_the_marker_has_none(self):
        r = self.request(); self.store.request(r)
        (Path(self.temp.name) / ('apt-' + r['id'] + '.started')).write_text('started')
        failed = dict(LoadState='loaded', ActiveState='failed', Result='exit-code', ExecMainStatus='100')
        with patch('apt.is_unit_active', return_value=False), patch('apt.unit_properties', return_value=failed), \
                patch('apt.run') as run:
            self.store.tick(); run.assert_not_called()
        # A failed list refresh changed no package.
        self.assertEqual(self.result(r)['status'], 'failed')
        self.assertEqual(self.result(r)['events'][-1]['code'], 'apt_failed')

    def test_interrupted_command_is_not_replayed_after_worker_recovery(self):
        # apt-get started, then the server rebooted: its end is unknown.
        for kind, status in (('apt_upgrade', 'partially_applied'), ('apt_update', 'failed')):
            with self.subTest(kind=kind):
                r = self.request(kind, number=2 if kind == 'apt_update' else 3); self.store.request(r)
                marker = Path(self.temp.name) / ('apt-' + r['id'] + '.started')
                marker.write_text('running')
                self.store.recover()
                with patch('apt.is_unit_active', return_value=False), patch('apt.unit_properties', return_value={}), \
                        patch('apt.run') as run:
                    self.store.tick(); run.assert_not_called()
                self.assertEqual(self.result(r)['status'], status)
                self.assertEqual(self.result(r)['events'][-1]['code'], 'apt_interrupted')
                # A list refresh changed no package: a resume starts afresh.
                self.assertEqual(marker.exists(), kind == 'apt_upgrade')

    def test_failure_before_apt_get_started_is_not_partial(self):
        # systemd-run could not start the unit: the marker never left 'started'.
        for kind in ('apt_update', 'apt_upgrade'):
            with self.subTest(kind=kind):
                r = self.request(kind, number=4 if kind == 'apt_update' else 5); self.store.request(r)
                marker = Path(self.temp.name) / ('apt-' + r['id'] + '.started')

                def unit_run(args, unit=None, **kwargs):
                    if unit is None:
                        return OUTPUT
                    self.assertEqual(marker.read_text(), 'started')
                    raise AptError()
                with patch('apt.plan', return_value=dict(fingerprint='a'*64, packages=parse_packages(OUTPUT))), \
                        patch('apt.run', side_effect=unit_run), patch('apt.is_unit_active', return_value=False), \
                        patch('apt.unit_properties', return_value={}):
                    self.store.tick()
                self.assertEqual(self.result(r)['status'], 'failed')
                self.assertEqual(self.result(r)['events'][-1]['code'], 'apt_failed')
                self.assertFalse(marker.exists())

    def test_failed_upgrade_after_apt_get_started_is_partial(self):
        r = self.request('apt_upgrade', number=6); self.store.request(r)
        marker = Path(self.temp.name) / ('apt-' + r['id'] + '.started')

        def unit_run(args, unit=None, **kwargs):
            if unit is None:
                return OUTPUT
            marker.write_text('exit 100')
            raise AptError()
        with patch('apt.plan', return_value=dict(fingerprint='a'*64, packages=parse_packages(OUTPUT))), \
                patch('apt.run', side_effect=unit_run), patch('apt.is_unit_active', return_value=False):
            self.store.tick()
        self.assertEqual(self.result(r)['status'], 'partially_applied')
        self.assertTrue(marker.exists())

    def test_interrupted_dpkg_is_reported_and_never_repaired(self):
        self.dpkg.stop()
        with patch('apt.dpkg_interrupted', return_value=True), patch('apt.run') as run:
            reply = self.store.request(dict(version=1, action='apt_plan'))
            self.assertEqual(reply['code'], 'apt_dpkg_interrupted')
            self.assertNotIn('aptPlan', reply)
            r = self.request(); self.store.request(r); self.store.tick()
            run.assert_not_called()
        self.assertEqual(self.result(r)['status'], 'failed')
        self.assertEqual(self.result(r)['events'][-1]['code'], 'apt_dpkg_interrupted')
        self.dpkg.start()

    def test_interrupted_dpkg_detection_is_read_only(self):
        import apt
        from unittest.mock import MagicMock
        self.dpkg.stop()
        updates = Path(self.temp.name) / 'updates'; updates.mkdir()
        query = lambda states: MagicMock(returncode=0, stdout=''.join('install ok %s\n' % s for s in states).encode())
        with patch('apt.DPKG_UPDATES', updates), patch('apt.LOCKS', ()), patch('apt.run_command') as run:
            run.return_value = query(['installed', 'config-files'])
            self.assertFalse(apt.dpkg_interrupted())
            self.assertEqual(run.call_args.args[0][0], '/usr/bin/dpkg-query')
            for state in ('half-configured', 'unpacked', 'triggers-pending'):
                run.return_value = query(['installed', state])
                self.assertTrue(apt.dpkg_interrupted())
            run.return_value = query(['installed'])
            (updates / 'tmp.i').write_text('')
            self.assertFalse(apt.dpkg_interrupted())
            (updates / '0003').write_text('journal')
            self.assertTrue(apt.dpkg_interrupted())
            self.assertFalse(any('--configure' in c.args[0] for c in run.call_args_list))
        with patch('apt.DPKG_UPDATES', updates), patch('apt.lock_busy', return_value=True):
            self.assertFalse(apt.dpkg_interrupted())  # A dpkg run in progress is not judged.
        self.dpkg.start()

    def test_plan_errors_are_codes_not_a_crashed_rpc(self):
        for error, code in ((AptError('apt_lock_busy'), 'apt_lock_busy'), (AptError('unknown_code'), 'apt_failed'),
                            (OSError('missing'), 'apt_failed'), (__import__('subprocess').TimeoutExpired('apt', 60), 'apt_failed')):
            with self.subTest(code=code), patch('apt.plan', side_effect=error):
                reply = self.store.request(dict(version=1, action='apt_plan'))
                self.assertEqual(reply['code'], code)

    def test_preflight_codes_reach_the_job_events(self):
        r = self.request(number=7); self.store.request(r)
        with patch('apt.check_disk_and_memory', side_effect=AptError('apt_disk_full')):
            self.store.tick()
        self.assertEqual(self.result(r)['events'][-1]['code'], 'apt_disk_full')

    def test_stopped_worker_with_a_started_apt_unit_is_not_reported_failed(self):
        import runner
        r = self.request('apt_upgrade', number=8); self.store.request(r)
        (Path(self.temp.name) / ('apt-' + r['id'] + '.started')).write_text('running')
        with self.store.db:
            self.store.db.execute('UPDATE jobs SET created=created-?', (runner.STALE_AFTER + 5,))
            self.store.reap_stale_jobs()
        self.assertEqual(self.result(r)['status'], 'partially_applied')
        self.assertEqual(self.result(r)['events'][-1]['code'], 'apt_interrupted')
        other = self.request(number=9); self.store.request(other)  # Never started apt.
        with self.store.db:
            self.store.db.execute('UPDATE jobs SET created=created-?', (runner.STALE_AFTER + 5,))
            self.store.reap_stale_jobs()
        self.assertEqual(self.result(other)['status'], 'failed')

    def test_stale_marker_cleaned_up_if_unit_inactive(self):
        r = self.request(); self.store.request(r)
        marker = Path(self.temp.name) / ('apt-' + r['id'] + '.started')
        marker.write_text('started')
        with patch('apt.is_unit_active', return_value=False), patch('apt.unit_properties', return_value={}), \
                patch('apt.run') as run:
            self.store.tick()
            run.assert_called()
        self.assertTrue(marker.exists())
    def test_checkpoint_1_removes_marker(self):
        r = self.request(); self.store.request(r)
        marker = Path(self.temp.name) / ('apt-' + r['id'] + '.started')
        with patch('apt.run'):
            self.store.tick()
            self.assertTrue(marker.exists())
            self.store.tick()
            self.assertFalse(marker.exists())
        self.assertEqual(self.result(r)['status'], 'succeeded')
    def test_abort_cleans_marker_when_unit_inactive(self):
        r = self.request()
        marker = Path(self.temp.name) / ('apt-' + r['id'] + '.started')
        marker.write_text('started')
        from apt import AptJob
        job = AptJob(self.store, r)
        with patch('apt.is_unit_active', return_value=False), patch('apt.unit_properties', return_value={}):
            self.assertEqual(job.abort(), 'cancelled')
            self.assertFalse(marker.exists())
        marker.write_text('exit 0')
        with patch('apt.is_unit_active', return_value=False), patch('apt.unit_properties', return_value={}):
            self.assertEqual(job.abort(), 'partially_applied')
            self.assertTrue(marker.exists())
    def test_abort_retains_marker_when_unit_active(self):
        r = self.request()
        marker = Path(self.temp.name) / ('apt-' + r['id'] + '.started')
        marker.write_text('started')
        from apt import AptJob
        job = AptJob(self.store, r)
        with patch('apt.is_unit_active', return_value=True):
            self.assertEqual(job.abort(), 'partially_applied')
            self.assertTrue(marker.exists())
    def test_upgrade_simulation_allows_co_dependencies_and_ordering(self):
        r = self.request('apt_upgrade'); self.store.request(r)
        sim_output = 'Inst new-dep (1.0 local [amd64])\nInst fixture [1.0] (2.0 local [amd64])\nConf fixture (2.0 local [amd64])\n'
        with patch('apt.plan', return_value=dict(fingerprint='a'*64, packages=parse_packages(OUTPUT))), patch('apt.run', return_value=sim_output):
            self.store.tick()
        self.assertEqual(self.result(r)['events'][-1]['code'], 'apt_checked')
    def test_dpkg_locks_see_posix_locks_of_other_processes(self):
        import fcntl, os, subprocess
        from apt import acquire_dpkg_locks, lock_busy
        lock = Path(self.temp.name) / 'lock-frontend'
        lock.write_bytes(b'')
        self.assertFalse(lock_busy(lock))
        self.assertFalse(lock_busy(Path(self.temp.name) / 'missing'))
        # dpkg and apt hold fcntl (POSIX) locks; flock() alone never saw them.
        holder = subprocess.Popen([sys.executable, '-c', 'import fcntl,sys,time\n'
            'f=open(sys.argv[1],"r+"); fcntl.lockf(f, fcntl.LOCK_EX); print("held", flush=True); time.sleep(30)',
            str(lock)], stdout=subprocess.PIPE)
        try:
            self.assertEqual(holder.stdout.readline().strip(), b'held')
            fd = os.open(str(lock), os.O_RDWR)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)  # The old check: no exclusion.
            finally:
                os.close(fd)
            self.assertTrue(lock_busy(lock))
            sleeps = []
            with patch('apt.is_unit_active', return_value=False):
                with self.assertRaises(AptError) as ctx:
                    acquire_dpkg_locks(timeout=2, paths=[lock], sleep=sleeps.append)
            self.assertEqual(ctx.exception.code, 'apt_lock_busy')
            self.assertTrue(sleeps)
            # A scheduled apt run in progress is reported at once, without waiting.
            sleeps.clear()
            with patch('apt.is_unit_active', side_effect=lambda unit: unit == 'apt-daily-upgrade.service'):
                with self.assertRaises(AptError):
                    acquire_dpkg_locks(timeout=60, paths=[lock], sleep=sleeps.append)
            self.assertEqual(sleeps, [])
        finally:
            holder.kill(); holder.wait(timeout=10); holder.stdout.close()
        acquire_dpkg_locks(timeout=1, paths=[lock], sleep=sleeps.append)

    def test_unit_runs_are_bounded_and_record_their_exit_status(self):
        from apt import run as apt_run, RUNTIME_MAX
        marker = Path(self.temp.name) / 'marker'
        with patch('subprocess.run') as mock_run:
            mock_run.return_value.returncode = 0
            mock_run.return_value.stdout = b''
            apt_run(['update'], unit='test-unit', record=marker)
        argv = mock_run.call_args.args[0]
        self.assertIn('--property=RuntimeMaxSec=%d' % RUNTIME_MAX, argv)
        self.assertGreater(mock_run.call_args.kwargs['timeout'], RUNTIME_MAX)
        self.assertEqual(argv[argv.index('record') + 1], str(marker))
        self.assertEqual(argv.count('Dpkg::Options::=--force-confold'), 1)

    def test_recorded_exit_status_survives_the_worker(self):
        from apt import record_exit, recorded, INTERRUPTED
        marker = Path(self.temp.name) / 'marker'
        self.assertIsNone(recorded(marker))
        marker.write_text('started')
        self.assertIsNone(recorded(marker))
        marker.write_text('running')
        self.assertEqual(recorded(marker), INTERRUPTED)
        self.assertEqual(record_exit(marker, [sys.executable, '-c', 'raise SystemExit(3)']), 3)
        self.assertEqual(recorded(marker), 3)

    def test_stopped_unit_leaves_the_end_unknown(self):
        # A reboot or RuntimeMaxSec sends SIGTERM to the unit while dpkg runs.
        import signal
        import subprocess
        from apt import recorded, INTERRUPTED
        marker = Path(self.temp.name) / 'marker'
        source = Path(__file__).resolve().parents[2] / 'server/runner/apt.py'
        process = subprocess.Popen([sys.executable, '-I', '-c',
            'import sys; sys.path.insert(0, %r); from pathlib import Path; import apt; '
            'apt.record_exit(Path(%r), [sys.executable, "-c", "import time; time.sleep(30)"])'
            % (str(source.parent), str(marker))], start_new_session=True)
        for _ in range(200):
            if recorded(marker) == INTERRUPTED:
                break
            __import__('time').sleep(0.05)
        os.killpg(process.pid, signal.SIGTERM)  # systemd stops the whole unit.
        self.assertEqual(process.wait(timeout=30), 128 + signal.SIGTERM)
        self.assertEqual(recorded(marker), INTERRUPTED)

    def test_run_guarantees_noninteractive_and_force_confold(self):
        from apt import run as apt_run
        with patch('subprocess.run') as mock_run:
            mock_run.return_value.returncode = 0
            mock_run.return_value.stdout = b''
            apt_run(['install', 'pkg'], unit='test-unit')
            call_args = mock_run.call_args
            argv = call_args.args[0]
            env = call_args.kwargs['env']
            self.assertEqual(env.get('DEBIAN_FRONTEND'), 'noninteractive')
            self.assertIn('--setenv=DEBIAN_FRONTEND=noninteractive', argv)
            self.assertIn('-o', argv)
            self.assertIn('Dpkg::Options::=--force-confold', argv)


class StandaloneEntryTests(unittest.TestCase):
    def test_record_wrapper_starts_under_isolated_python(self):
        # systemd-run starts `python3 -I apt.py record ...`: no script dir on
        # sys.path. Wrong arguments must reach the usage check (exit 2), not
        # die on an import (exit 1), which would fail every apt job.
        import subprocess
        source = Path(__file__).resolve().parents[2] / 'server/runner/apt.py'
        result = subprocess.run([sys.executable, '-I', str(source), 'record'], capture_output=True, timeout=60,
                                cwd=tempfile.gettempdir())
        self.assertEqual(result.returncode, 2, result.stderr)
