"""Regression tests: component upgrade rollback, confirmation window, probes, installer."""
import io
import json
import os
from pathlib import Path
import sqlite3
import sys
import tarfile
import tempfile
import time
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))

import component_upgrade as cu
from component_upgrade import ComponentUpgradeError, ComponentUpgradeJob, ComponentUpgrader
import connectivity_probe as probes
import install
from panel import PanelError
import upgrade_probe
from runner import Store


def calls(recorder):
    return [c.args[0] for c in recorder.call_args_list]


class Base(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = Store(self.root)
        self.addCleanup(self.store.close)
        self.job_id = 'a' * 32

    def request(self, job_id=None, component='xray', **payload):
        payload = dict(component=component, version='26.11.9', **payload)
        return {'version': 1, 'action': 'submit', 'id': job_id or self.job_id, 'kind': 'component_upgrade_apply',
                'count': 6, 'interval': 1, 'payload': json.dumps(payload), 'fingerprint': 'f' * 64}

    def insert(self, request, status='running', checkpoint=0):
        self.store.db.execute('INSERT INTO jobs VALUES (?,?,?,?,0,0,?)',
                              (request['id'], json.dumps(request), status, checkpoint, time.time()))
        self.store.db.commit()

    def upgrader(self, binary, component='xray', job_id=None, **detection):
        request = self.request(job_id, component)
        upgrader = ComponentUpgrader(self.store, request, json.loads(request['payload']))
        upgrader.detection = dict(installed=True, binaryPath=str(binary), units=['x.service'], arch='x86_64', **detection)
        return upgrader

    def backup(self, upgrader):
        with patch('component_upgrade.probe_component', return_value={}):
            upgrader.backup()


class PanelLayoutTests(Base):
    """The panel switch writes only into an existing layout, and a rollback
    removes what it added (an adopted /usr/bin/x-ui got /usr/local/x-ui/*
    and /usr/bin/bin/xray-* written with no backup)."""

    def stage(self, upgrader):
        staging = upgrader.staging_dir / 'x-ui'
        (staging / 'bin').mkdir(parents=True)
        (staging / 'x-ui').write_bytes(b'new-panel')
        (staging / 'x-ui.sh').write_bytes(b'new-script')
        (staging / 'bin' / 'xray-linux-amd64').write_bytes(b'new-core')
        return staging / 'x-ui'

    def test_adopted_binary_outside_the_layout_gets_no_companions(self):
        usr_bin = self.root / 'usr/bin'; usr_bin.mkdir(parents=True)
        binary = usr_bin / 'x-ui'; binary.write_bytes(b'old-panel'); binary.chmod(0o755)
        base = self.root / 'usr/local/x-ui'  # Absent on this server.
        with patch('component_upgrade.PANEL_BASE', base):
            upgrader = self.upgrader(binary, component='panel')
            self.backup(upgrader)
            staged = self.stage(upgrader)
            with patch('component_upgrade.subprocess.run'):
                upgrader.apply_switch(staged)
        self.assertEqual(binary.read_bytes(), b'new-panel')
        self.assertFalse(base.exists())
        self.assertEqual(sorted(p.name for p in usr_bin.iterdir()), ['x-ui'])

    def test_rollback_removes_files_the_switch_added(self):
        base = self.root / 'usr/local/x-ui'; (base / 'bin').mkdir(parents=True)
        binary = base / 'x-ui'; binary.write_bytes(b'old-panel'); binary.chmod(0o755)
        script = base / 'x-ui.sh'; script.write_bytes(b'old-script'); script.chmod(0o700)
        with patch('component_upgrade.PANEL_BASE', base):
            upgrader = self.upgrader(binary, component='panel')
            self.backup(upgrader)
            self.assertEqual(upgrader.backup_metadata['createdFiles'],
                             [str(base / 'bin/xray-linux-amd64'), str(base / 'bin/xray-linux-arm64')])
            staged = self.stage(upgrader)
            with patch('component_upgrade.subprocess.run'):
                upgrader.apply_switch(staged)
                self.assertEqual((base / 'bin/xray-linux-amd64').read_bytes(), b'new-core')
                self.assertEqual(script.read_bytes(), b'new-script')
                upgrader.rollback()
        self.assertEqual(binary.read_bytes(), b'old-panel')
        self.assertEqual(script.read_bytes(), b'old-script')
        self.assertEqual(script.stat().st_mode & 0o777, 0o700)
        self.assertEqual(list((base / 'bin').iterdir()), [])


class RollbackSourceTests(Base):
    """Findings 1, 7, 8: the step-2 backup is the only source, restored once, with owners kept."""

    def test_repeated_switch_still_rolls_back_to_the_old_binary(self):
        bin_dir = self.root / 'bin'; bin_dir.mkdir()
        binary = bin_dir / 'xray'; binary.write_bytes(b'old'); binary.chmod(0o751)
        upgrader = self.upgrader(binary)
        self.backup(upgrader)
        staged = self.root / 'staged'; staged.write_bytes(b'new')
        with patch('component_upgrade.subprocess.run'):
            upgrader.apply_switch(staged)
            upgrader.apply_switch(staged)  # Crash after the replace, before the checkpoint commit.
            upgrader.rollback()
        self.assertEqual(binary.read_bytes(), b'old')
        self.assertEqual(binary.stat().st_mode & 0o777, 0o751)
        self.assertEqual(sorted(p.name for p in bin_dir.iterdir()), ['xray'])  # No copy next to it.

    def test_repeated_switch_restores_the_old_setup_wizard(self):
        bin_dir = self.root / 'bin'; bin_dir.mkdir()
        binary = bin_dir / 'trusttunnel_endpoint'; binary.write_bytes(b'old-endpoint')
        (bin_dir / 'setup_wizard').write_bytes(b'old-wizard')
        upgrader = self.upgrader(binary, component='trusttunnel')
        self.backup(upgrader)
        upgrader.staging_dir.mkdir(parents=True, exist_ok=True)
        (upgrader.staging_dir / 'setup_wizard').write_bytes(b'new-wizard')
        staged = self.root / 'staged'; staged.write_bytes(b'new-endpoint')
        with patch('component_upgrade.subprocess.run'):
            upgrader.apply_switch(staged)
            upgrader.apply_switch(staged)
            upgrader.rollback()
        self.assertEqual((bin_dir / 'setup_wizard').read_bytes(), b'old-wizard')
        self.assertEqual(binary.read_bytes(), b'old-endpoint')

    def test_rollback_runs_once(self):
        binary = self.root / 'xray'; binary.write_bytes(b'old')
        upgrader = self.upgrader(binary)
        self.backup(upgrader)
        staged = self.root / 'staged'; staged.write_bytes(b'new')
        with patch('component_upgrade.subprocess.run') as run:
            upgrader.apply_switch(staged)
            upgrader.rollback()
            run.reset_mock()
            self.assertTrue(upgrader.rollback())
        self.assertEqual(run.call_count, 0)  # No second stop/restart.
        self.assertEqual(binary.read_bytes(), b'old')

    def test_nothing_switched_restores_no_data(self):
        """A crash in step 4 before any file was replaced: units come back, data stays."""
        binary = self.root / 'xray'; binary.write_bytes(b'old')
        config = self.root / 'config.json'; config.write_text('{"v": 1}')
        upgrader = self.upgrader(binary, configPath=str(config))
        self.backup(upgrader)
        config.write_text('{"v": 2}')
        with patch('component_upgrade.subprocess.run') as run:
            upgrader.rollback()
        self.assertEqual(config.read_text(), '{"v": 2}')
        self.assertEqual([c[1] for c in calls(run)], ['start'])

    def test_data_keeps_its_owner_and_mode(self):
        binary = self.root / 'xray'; binary.write_bytes(b'old')
        config = self.root / 'config.json'; config.write_text('{"v": 1}'); config.chmod(0o640)
        db = self.root / 'x-ui.db'
        con = sqlite3.connect(str(db)); con.execute('CREATE TABLE t (v INT)'); con.execute('INSERT INTO t VALUES (1)'); con.commit(); con.close()
        db.chmod(0o644)
        upgrader = self.upgrader(binary, configPath=str(config), dbPath=str(db))
        self.backup(upgrader)
        staged = self.root / 'staged'; staged.write_bytes(b'new')
        with patch('component_upgrade.subprocess.run'):
            upgrader.apply_switch(staged)
            config.write_text('{"v": 2}')
            Path(str(db) + '-wal').write_bytes(b'journal of the new version')
            upgrader.rollback()
        self.assertEqual(config.read_text(), '{"v": 1}')
        self.assertEqual(config.stat().st_mode & 0o777, 0o640)
        self.assertEqual(db.stat().st_mode & 0o777, 0o644)
        self.assertEqual(db.stat().st_uid, os.getuid())
        self.assertFalse(Path(str(db) + '-wal').exists())
        con = sqlite3.connect(str(db)); self.assertEqual(con.execute('SELECT v FROM t').fetchone()[0], 1); con.close()

    def test_symlinked_binary_keeps_its_link(self):
        real_dir = self.root / 'opt'; real_dir.mkdir()
        real = real_dir / 'xray-1.0'; real.write_bytes(b'old'); real.chmod(0o750)
        link = self.root / 'xray'; link.symlink_to(real)
        upgrader = self.upgrader(link)
        self.backup(upgrader)
        staged = self.root / 'staged'; staged.write_bytes(b'new')
        with patch('component_upgrade.subprocess.run'):
            upgrader.apply_switch(staged)
            self.assertTrue(link.is_symlink())
            self.assertEqual(real.read_bytes(), b'new')
            self.assertEqual(real.stat().st_mode & 0o777, 0o750)
            upgrader.rollback()
        self.assertTrue(link.is_symlink())
        self.assertEqual(real.read_bytes(), b'old')

    def test_restored_binary_is_verified(self):
        binary = self.root / 'xray'; binary.write_bytes(b'old')
        upgrader = self.upgrader(binary)
        self.backup(upgrader)
        (upgrader.backup_dir / 'xray').write_bytes(b'damaged')
        binary.write_bytes(b'new')
        with patch('component_upgrade.subprocess.run'), self.assertRaises(ComponentUpgradeError) as ctx:
            upgrader.rollback()
        self.assertEqual(ctx.exception.code, 'upgrade_rollback_failed')


class JobRollbackTests(Base):
    """Findings 2 and 7 through the runner loop."""

    def test_missing_backup_needs_attention_and_keeps_the_work_dir(self):
        request = self.request()
        self.insert(request, checkpoint=5)
        work = self.root / ('upgrade-' + self.job_id)
        (work / 'staging').mkdir(parents=True)
        with patch.object(ComponentUpgradeJob, 'step', side_effect=ComponentUpgradeError('upgrade_healthcheck_failed')):
            self.store.tick()
        row = self.store.db.execute('SELECT status FROM jobs WHERE id=?', (self.job_id,)).fetchone()
        self.assertEqual(row[0], 'needs_attention')
        events = [json.loads(r[0])['code'] for r in self.store.db.execute('SELECT event FROM events WHERE id=? ORDER BY sequence', (self.job_id,))]
        self.assertEqual(events[-1], 'upgrade_rollback_failed')
        self.assertTrue(work.exists())

    def test_failure_before_the_switch_touches_no_service_or_data(self):
        binary = self.root / 'xray'; binary.write_bytes(b'old')
        db = self.root / 'x-ui.db'
        con = sqlite3.connect(str(db)); con.execute('CREATE TABLE t (v INT)'); con.execute('INSERT INTO t VALUES (1)'); con.commit(); con.close()
        upgrader = self.upgrader(binary, dbPath=str(db))
        self.backup(upgrader)
        con = sqlite3.connect(str(db)); con.execute('UPDATE t SET v=2'); con.commit(); con.close()
        self.insert(self.request(), checkpoint=3)
        with patch.object(ComponentUpgradeJob, 'step', side_effect=ComponentUpgradeError('upgrade_syntax_failed')), \
             patch('component_upgrade.subprocess.run') as run:
            self.store.tick()
        self.assertEqual(calls(run), [])
        con = sqlite3.connect(str(db)); self.assertEqual(con.execute('SELECT v FROM t').fetchone()[0], 2); con.close()
        row = self.store.db.execute('SELECT status FROM jobs WHERE id=?', (self.job_id,)).fetchone()
        self.assertEqual(row[0], 'failed')

    def test_cancel_before_the_switch_stops_nothing(self):
        request = self.request()
        self.insert(request, checkpoint=2)
        self.store.db.execute('UPDATE jobs SET cancel=1 WHERE id=?', (self.job_id,)); self.store.db.commit()
        with patch('component_upgrade.subprocess.run') as run:
            self.store.tick()
        self.assertEqual(calls(run), [])
        self.assertEqual(self.store.db.execute('SELECT status FROM jobs WHERE id=?', (self.job_id,)).fetchone()[0], 'cancelled')

    def test_job_rollback_closes_a_window_armed_before_a_crash(self):
        binary = self.root / 'xray'; binary.write_bytes(b'old')
        upgrader = self.upgrader(binary)
        self.backup(upgrader)
        request = self.request()
        self.insert(request, checkpoint=5)
        with patch('component_upgrade.subprocess.run'):
            cu.arm_deadman(self.store, request)
            binary.write_bytes(b'new')
            self.assertTrue(ComponentUpgradeJob(self.store, request).rollback(5))
        self.assertEqual(binary.read_bytes(), b'old')
        self.assertFalse(cu.window_open(self.root, self.job_id))


class ConfirmationRaceTests(Base):
    """Finding 3."""

    def setUp(self):
        super().setUp()
        self.req = self.request()
        self.insert(self.req, status='succeeded', checkpoint=6)
        with patch('component_upgrade.subprocess.run'):
            cu.arm_deadman(self.store, self.req)
        self.window = cu._deadman_path(self.root, self.job_id)

    def test_window_being_rolled_back_is_never_confirmed(self):
        info = json.loads(self.window.read_text()); info['rollingBack'] = True
        self.window.write_text(json.dumps(info))
        with patch('component_upgrade.subprocess.run'), self.assertRaises(ComponentUpgradeError) as ctx:
            cu.confirm_upgrade(self.store, self.job_id)
        self.assertEqual(ctx.exception.code, 'upgrade_conflict')
        self.assertFalse(json.loads(self.window.read_text()).get('confirmed'))

    def test_confirmation_waits_for_the_lock_and_then_conflicts(self):
        with cu.upgrade_lock(self.root):
            with patch('component_upgrade.subprocess.run'), self.assertRaises(ComponentUpgradeError) as ctx:
                cu.confirm_upgrade(self.store, self.job_id, timeout=0.2)
        self.assertEqual(ctx.exception.code, 'upgrade_conflict')

    def test_confirmation_during_the_wait_wins(self):
        def confirmed_meanwhile(store, job_id, limit=120):
            with patch('component_upgrade.subprocess.run'):
                cu.confirm_upgrade(store, job_id)
            return True
        with patch('component_upgrade._wait_for_idle', side_effect=confirmed_meanwhile), \
             patch('component_upgrade._late_rollback') as late:
            self.assertFalse(cu.fire_deadman(self.store, self.job_id))
        late.assert_not_called()
        info = json.loads(self.window.read_text())
        self.assertTrue(info['confirmed']); self.assertFalse(info.get('rolledBack'))

    def test_expiry_defers_while_another_job_runs(self):
        with patch('component_upgrade._wait_for_idle', return_value=False), \
             patch.object(cu, 'DEFER_LIMIT', 0), \
             patch('component_upgrade._late_rollback') as late:
            self.assertFalse(cu.fire_deadman(self.store, self.job_id))
        late.assert_not_called()
        self.assertTrue(cu.window_open(self.root, self.job_id))

    def test_idle_without_a_live_worker(self):
        other = self.request('d' * 32)
        self.insert(other)  # 'running', but no worker heartbeat.
        with patch('component_upgrade.time.sleep') as sleep:
            self.assertTrue(cu._wait_for_idle(self.store, self.job_id))
        sleep.assert_not_called()

    def test_failed_late_rollback_keeps_backup_and_needs_attention(self):
        backup = self.root / ('upgrade-' + self.job_id) / 'backup'
        backup.mkdir(parents=True); (backup / 'meta.json').write_text('{}')
        with patch('component_upgrade._late_rollback', side_effect=ComponentUpgradeError('upgrade_rollback_failed')), \
             self.assertRaises(ComponentUpgradeError):
            cu.fire_deadman(self.store, self.job_id, wait=False)
        self.assertTrue((backup / 'meta.json').exists())
        self.assertEqual(self.store.db.execute('SELECT status FROM jobs WHERE id=?', (self.job_id,)).fetchone()[0], 'needs_attention')
        self.assertFalse(cu.window_open(self.root, self.job_id))
        with patch('component_upgrade._late_rollback') as late:
            self.assertFalse(cu.fire_deadman(self.store, self.job_id, wait=False))  # No automatic retry.
        late.assert_not_called()
        with patch('component_upgrade.subprocess.run'), self.assertRaises(ComponentUpgradeError):
            cu.confirm_upgrade(self.store, self.job_id)


class PreflightOrderTests(Base):
    """Finding 6: the plan is checked before another window is confirmed."""

    def setUp(self):
        super().setUp()
        self.other = self.request('4' * 32)
        self.insert(self.other, status='succeeded', checkpoint=6)
        with patch('component_upgrade.subprocess.run'):
            cu.arm_deadman(self.store, self.other)
        self.req = self.request('5' * 32)
        self.insert(self.req)

    def step0(self, fingerprint):
        with patch('component_upgrade.subprocess.run'), patch.object(ComponentUpgrader, 'pre_check'), \
             patch('component_upgrade.plan', return_value={'fingerprint': fingerprint}):
            ComponentUpgradeJob(self.store, self.req).step(0)

    def test_mismatch_leaves_the_other_window_open(self):
        with self.assertRaises(ComponentUpgradeError) as ctx:
            self.step0('0' * 64)
        self.assertEqual(ctx.exception.code, 'upgrade_conflict')
        self.assertTrue(cu.window_open(self.root, '4' * 32))

    def test_repeated_step_after_the_confirmation_passes(self):
        self.step0('f' * 64)
        self.assertFalse(cu.window_open(self.root, '4' * 32))
        self.step0('0' * 64)  # The confirmation changed the snapshot in the plan.


class ArchiveAndDownloadTests(Base):
    """Finding 12."""

    def tar(self, member, data=b''):
        path = self.root / 'release.tar.gz'
        with tarfile.open(path, 'w:gz') as tar:
            tar.addfile(member, io.BytesIO(data) if data else None)
        return path

    def test_link_and_device_members_are_refused(self):
        outside = self.root / 'outside'
        for kind, linkname in ((tarfile.SYMTYPE, str(outside)), (tarfile.SYMTYPE, 'inside'), (tarfile.LNKTYPE, 'inside'), (tarfile.CHRTYPE, '')):
            with self.subTest(kind=kind, linkname=linkname):
                member = tarfile.TarInfo('xray'); member.type = kind; member.linkname = linkname
                with self.assertRaises(ComponentUpgradeError) as ctx:
                    cu.extract_archive_safe(self.tar(member), self.root / 'staging')
                self.assertEqual(ctx.exception.detail, 'archive_unsafe_member')
        self.assertFalse(outside.exists())

    def test_fallback_without_filters_validates_too(self):
        member = tarfile.TarInfo('evil'); member.type = tarfile.SYMTYPE; member.linkname = '/etc'
        archive = self.tar(member)
        original = tarfile.TarFile.extractall
        def old_python(self, path='.', members=None, *, numeric_owner=False, **kwargs):
            if 'filter' in kwargs:
                raise TypeError('filter')
            return original(self, path, members, numeric_owner=numeric_owner, filter='fully_trusted')
        with patch.object(tarfile.TarFile, 'extractall', old_python), self.assertRaises(ComponentUpgradeError):
            cu.extract_archive_safe(archive, self.root / 'staging')
        self.assertFalse((self.root / 'staging' / 'evil').is_symlink())

    def download_step(self, url, sha256=''):
        req = self.request(url=url, sha256=sha256)
        self.insert(req)
        job = ComponentUpgradeJob(self.store, req)
        def fetch(url, path, expected, **kwargs):
            Path(path).write_bytes(b'archive')
            fetch.kwargs = kwargs
            return cu.digest(Path(path))
        with patch('component_upgrade.download_verified_artifact', side_effect=fetch) as download:
            job.step(1)
        return download, fetch

    def test_plain_http_without_digest_is_refused(self):
        with self.assertRaises(ComponentUpgradeError) as ctx:
            self.download_step('http://github.com/XTLS/Xray-core/releases/download/v26.11.9/Xray-linux-64.zip')
        self.assertEqual(ctx.exception.code, 'upgrade_checksum_failed')

    def test_https_without_digest_only_from_the_pinned_repository(self):
        with self.assertRaises(ComponentUpgradeError):
            self.download_step('https://example.invalid/Xray-linux-64.zip')
        self.job_id = 'b' * 32
        download, fetch = self.download_step('https://github.com/XTLS/Xray-core/releases/download/v26.11.9/Xray-linux-64.zip')
        download.assert_called_once()
        self.assertEqual(fetch.kwargs, {'require_https': True})

    def test_http_with_digest_is_verified(self):
        import hashlib
        with self.assertRaises(ComponentUpgradeError) as ctx:
            self.download_step('http://mirror.invalid/x.zip', sha256=hashlib.sha256(b'other').hexdigest())
        self.assertEqual(ctx.exception.code, 'upgrade_checksum_failed')


class CheckTimeoutTests(Base):
    """Finding 10 and the mihomo config test."""

    def test_unit_state_check_has_a_timeout(self):
        upgrader = self.upgrader(self.root / 'xray')
        upgrader.backup_metadata = dict(binaryPath=str(self.root / 'xray'), units=['x.service'])
        with patch('component_upgrade.subprocess.run', return_value=MagicMock(returncode=0)) as run:
            upgrader.verify_health(timeout=1)
        active = [c for c in run.call_args_list if 'is-active' in c.args[0]]
        self.assertTrue(active and all('timeout' in c.kwargs for c in active))

    def test_probe_after_the_deadline_starts_nothing(self):
        target = dict(port=443, user={'id': 'u'}, stream={})
        with patch.object(upgrade_probe, 'vless_targets', return_value={'vless:443': target}), \
             patch.object(upgrade_probe.subprocess, 'Popen', side_effect=AssertionError('no client')):
            self.assertEqual(upgrade_probe.probe_vless(deadline=time.monotonic() - 1), {'vless:443': False})

    def test_mihomo_config_is_tested(self):
        config = self.root / 'config.yaml'; config.write_text('mixed-port: 7890\n')
        staged = self.root / 'mihomo'; staged.write_bytes(b'binary')
        upgrader = self.upgrader(self.root / 'live-mihomo', component='mihomo', configPath=str(config))
        def run(cmd, **kwargs):
            return MagicMock(returncode=1 if '-t' in cmd else 0, stdout='Mihomo Meta v1.19.0', stderr='')
        with patch('component_upgrade.subprocess.run', side_effect=run) as mock, self.assertRaises(ComponentUpgradeError) as ctx:
            upgrader.syntax_pre_check(staged)
        self.assertEqual(ctx.exception.code, 'upgrade_syntax_failed')
        self.assertTrue(any('-t' in c.args[0] for c in mock.call_args_list))

    def test_check_error_codes_stay_in_the_contract(self):
        with patch('component_upgrade.plan', side_effect=ComponentUpgradeError('upgrade_unsafe_path')):
            response = self.store.request({'version': 1, 'action': 'component_upgrade_check', 'component': 'xray', 'payload': '{}'})
        self.assertEqual(response['code'], 'upgrade_failed')


class ProbeRecordTests(Base):
    """Findings 9 and 11."""

    def test_retire_is_idempotent(self):
        units = self.root / 'units'; (units / 'multi-user.target.wants').mkdir(parents=True)
        key = 'c' * 32
        name = 'antirkn-probe-' + key + '.service'
        (units / name).write_text('unit')
        (units / 'multi-user.target.wants' / name).symlink_to(units / name)
        def command(argv, **kwargs):
            if argv[1] == 'disable':
                raise PanelError('panel_api_failed')  # Not loaded any more.
            return b''
        with patch.object(probes, 'UNITS', units), patch.object(probes, 'command', side_effect=command) as run:
            probes.retire(key)
            self.assertFalse((units / name).exists())
            self.assertFalse((units / 'multi-user.target.wants' / name).is_symlink())
            run.reset_mock()
            probes.retire(key)
            run.assert_not_called()
            probes.save(self.store, dict(id=key, status='closed', stable=True, requestHash='h', closedAt=time.time()))
            self.assertEqual(probes.end(self.store, key), dict(closed=True, stable=True))

    def test_closed_records_are_retired(self):
        now = time.time()
        old, recent, open_ = 'd' * 32, 'e' * 32, 'f' * 32
        probes.save(self.store, dict(id=old, status='closed', closedAt=now - probes.CLOSED_RETENTION - 1))
        probes.save(self.store, dict(id=recent, status='closed', closedAt=now))
        probes.save(self.store, dict(id=open_, status='active', expires=now - 10 * probes.CLOSED_RETENTION))
        probes.prune(self.store, now)
        self.assertEqual(sorted(p.stem for p in probes.directory(self.store).glob('*.json')), sorted([recent, open_]))


class InstallerBusyTests(unittest.TestCase):
    """Finding 13."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name)
        (self.state / 'xray-upgrades' / ('a' * 32)).mkdir(parents=True)
        (self.state / 'connectivity-probes').mkdir()

    def xray(self, **data):
        (self.state / 'xray-upgrades' / ('a' * 32) / 'state.json').write_text(json.dumps(data))

    def test_transaction_or_probe_in_progress_is_busy(self):
        now = time.time()
        self.assertFalse(install.transactions_busy(self.state, now))
        self.xray(phase='awaiting_checks', deadline=now + 100)
        self.assertTrue(install.transactions_busy(self.state, now))
        for phase in ('committed', 'rolled_back', 'not_changed', 'recovery_required'):
            self.xray(phase=phase, deadline=now + 100)
            self.assertFalse(install.transactions_busy(self.state, now), phase)
        (self.state / 'connectivity-probes' / ('b' * 32 + '.json')).write_text(json.dumps(dict(status='active', expires=now + 60)))
        self.assertTrue(install.transactions_busy(self.state, now))
        (self.state / 'connectivity-probes' / ('b' * 32 + '.json')).write_text('not json')
        self.assertFalse(install.transactions_busy(self.state, now))

    def test_install_refuses_while_busy(self):
        import hashlib
        self.xray(phase='replacing', deadline=time.time() + 100)
        (self.state / 'jobs.sqlite').write_bytes(b'')

        class Db:
            def execute(self, sql, *_):
                self.sql = sql
                return self
            def fetchone(self):
                return (time.time(),) if 'health' in self.sql else None
            def fetchall(self):
                return []
            def close(self):
                pass
            def __enter__(self):
                return self
            def __exit__(self, *_):
                return False

        state, real_path = self.state, install.Path
        def path(value, *rest):
            value = str(value)
            if value.startswith('/var/lib/antirkn-runner'):
                return real_path(str(state) + value[len('/var/lib/antirkn-runner'):], *rest)
            return real_path(value, *rest)
        unit = hashlib.sha256(b'').hexdigest()
        hashes = {'antirkn-runner.service': unit}
        bundle = dict(files={'antirkn-runner.service': ''}, hashes=hashes,
                      release=hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest())
        before = dict(supported=True, fingerprint='f', state='installed', release='old', upgradable=True, active=True)
        with patch.object(install.os, 'geteuid', return_value=0), \
             patch.object(install, 'install_lock', MagicMock()), \
             patch.object(install, 'inspect_runner', return_value=before, create=True), \
             patch.object(install, 'PROGRAMS', (), create=True), \
             patch.object(install, 'Path', side_effect=path), \
             patch.object(install.sqlite3, 'connect', return_value=Db()), \
             patch.object(install.subprocess, 'run') as run:
            with self.assertRaises(ValueError) as ctx:
                install.install_runner(dict(fingerprint='f', bundle=bundle))
        self.assertEqual(str(ctx.exception), 'busy')
        run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
