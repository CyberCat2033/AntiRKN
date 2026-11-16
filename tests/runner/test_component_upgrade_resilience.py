"""Comprehensive stress- and chaos-testing suite for the dynamic update subsystem.

Covers:
1. Low-end VPS APT safety (disk exhaustion, boot partition safety, RAM starvation, lock contention).
2. Binary checksum tampering and architecture mismatch chaos injection.
3. Syntax regression pre-flight abort (zero downtime).
4. Self-healing canary watchdog and unconditional automatic rollback.
5. Adopted / pre-existing components update with custom path and permission preservation.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch, MagicMock

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))

import apt
from apt import AptError, check_disk_and_memory, acquire_dpkg_locks
from component_upgrade import (
    ComponentUpgrader,
    ComponentUpgradeJob,
    ComponentUpgradeError,
    detect_component,
    plan as component_upgrade_plan,
)
from runner import Store


class ComponentUpgradeResilienceTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.store = Store(self.temp_dir.name)
        self.addCleanup(self.temp_dir.cleanup)
        self.addCleanup(self.store.close)

    # ------------------------------------------------------------------------
    # 1. APT Safety & Low-End VPS Stress Tests
    # ------------------------------------------------------------------------

    def test_apt_preflight_archives_disk_exhaustion(self):
        """Modeling disk exhaustion in /var/cache/apt/archives prevents bricking VPS."""
        with patch('shutil.disk_usage') as mock_du, patch('pathlib.Path.exists', return_value=True):
            # Simulate only 50 MB free in archives
            mock_du.return_value = MagicMock(free=50 * 1024 * 1024)
            with self.assertRaises(AptError) as ctx:
                check_disk_and_memory()
            self.assertEqual(ctx.exception.code, 'apt_disk_full')

    def test_apt_preflight_boot_partition_exhaustion(self):
        """Modeling low disk space on /boot prevents incomplete kernel upgrades."""
        def fake_disk_usage(path):
            if str(path) == '/boot':
                return MagicMock(free=20 * 1024 * 1024)  # 20 MB free (< 50 MB threshold)
            return MagicMock(free=5 * 1024 * 1024 * 1024)

        with patch('shutil.disk_usage', side_effect=fake_disk_usage), \
             patch('pathlib.Path.exists', return_value=True):
            with self.assertRaises(AptError) as ctx:
                check_disk_and_memory()
            self.assertEqual(ctx.exception.code, 'apt_disk_full')

    def test_apt_preflight_ram_starvation(self):
        """Modeling memory exhaustion on 512MB RAM VPS prevents OOM-kill of SSH."""
        meminfo_content = "MemTotal:         500000 kB\nMemFree:           10000 kB\nMemAvailable:      20000 kB\n"
        with patch('pathlib.Path.exists', return_value=True), \
             patch('pathlib.Path.read_text', return_value=meminfo_content), \
             patch('shutil.disk_usage', return_value=MagicMock(free=5 * 1024 * 1024 * 1024)):
            with self.assertRaises(AptError) as ctx:
                check_disk_and_memory()
            self.assertEqual(ctx.exception.code, 'apt_memory_low')

    def test_apt_dpkg_lock_contention_nonblocking_backoff(self):
        """Modeling dpkg lock held by unattended-upgrades results in clean backoff and error."""
        with patch('pathlib.Path.exists', return_value=True), \
             patch('os.open', return_value=999), \
             patch('fcntl.flock', side_effect=BlockingIOError), \
             patch('os.close'):
            with self.assertRaises(AptError) as ctx:
                acquire_dpkg_locks(timeout=0.2)
            self.assertEqual(ctx.exception.code, 'apt_lock_busy')

    # ------------------------------------------------------------------------
    # 2. Architecture & Checksum Chaos Tests
    # ------------------------------------------------------------------------

    def test_component_upgrade_architecture_mismatch_rejected(self):
        """Cross-architecture artifact download (e.g. aarch64 on x86_64) is strictly rejected."""
        manifest = {
            'component': 'xray',
            'version': '26.9.9',
            'architecture': 'aarch64',  # Incompatible with x86_64 host
            'sha256': '0' * 64,
        }
        req = {'id': '0' * 32, 'payload': manifest}
        upgrader = ComponentUpgrader(self.store, req, manifest)

        with patch('component_upgrade.detect_component') as mock_detect, \
             patch('component_upgrade.normalize_arch', side_effect=lambda a=None: a if a else 'x86_64'):
            mock_detect.return_value = {
                'installed': True,
                'binaryPath': '/usr/local/bin/xray',
                'arch': 'x86_64',
            }
            with self.assertRaises(ComponentUpgradeError) as ctx:
                upgrader.pre_check()
            self.assertEqual(ctx.exception.code, 'upgrade_architecture_mismatch')

    def test_component_upgrade_checksum_tampering_aborts_cleanly(self):
        """Tampered or corrupted binary archive fails validation before extraction."""
        fake_bin_dir = Path(self.temp_dir.name) / 'fake_bin'
        fake_bin_dir.mkdir()
        fake_bin = fake_bin_dir / 'xray'
        fake_bin.write_bytes(b'old_working_binary')

        manifest = {
            'component': 'xray',
            'version': '26.9.9',
            'architecture': 'x86_64',
            'sha256': hashlib.sha256(b'expected_valid_archive').hexdigest(),
            'binaryName': 'xray',
        }
        req = {'id': '0' * 32, 'payload': manifest}
        upgrader = ComponentUpgrader(self.store, req, manifest)
        upgrader.detection = {
            'installed': True,
            'binaryPath': str(fake_bin),
            'arch': 'x86_64',
        }

        # Corrupted archive with wrong bytes
        corrupted_archive = fake_bin_dir / 'release.zip'
        corrupted_archive.write_bytes(b'corrupted_tampered_payload')

        with self.assertRaises(ComponentUpgradeError) as ctx:
            upgrader.validate_and_stage(corrupted_archive)
        self.assertEqual(ctx.exception.code, 'upgrade_checksum_failed')

        # Verify active binary is intact and not modified
        self.assertEqual(fake_bin.read_bytes(), b'old_working_binary')

    # ------------------------------------------------------------------------
    # 3. Syntax Pre-Flight Check Failure (Zero Downtime)
    # ------------------------------------------------------------------------

    def test_component_upgrade_syntax_pre_check_failure_zero_downtime(self):
        """When new binary rejects existing config, pre-flight aborts without touching service."""
        fake_bin_dir = Path(self.temp_dir.name) / 'xray_app'
        fake_bin_dir.mkdir()
        active_bin = fake_bin_dir / 'xray'
        active_bin.write_bytes(b'xray_v26.7')
        config_path = fake_bin_dir / 'config.json'
        config_path.write_bytes(b'{"inbounds": []}')

        manifest = {
            'component': 'xray',
            'version': '26.9.9',
            'architecture': 'x86_64',
            'sha256': hashlib.sha256(b'valid').hexdigest(),
            'binaryName': 'xray',
        }
        req = {'id': '1' * 32, 'payload': manifest}
        upgrader = ComponentUpgrader(self.store, req, manifest)
        upgrader.detection = {
            'installed': True,
            'binaryPath': str(active_bin),
            'configPath': str(config_path),
            'arch': 'x86_64',
            'units': ['xray.service'],
        }

        staged_bin = fake_bin_dir / 'staged_xray'
        staged_bin.write_bytes(b'xray_v26.9_with_breaking_syntax')

        # Simulate subprocess run of `xray run -test -config ...` exiting with code 1 (syntax error)
        with patch('subprocess.run') as mock_run:
            mock_run.return_value = MagicMock(returncode=1, stderr=b'Failed to parse config')
            with self.assertRaises(ComponentUpgradeError) as ctx:
                upgrader.syntax_pre_check(staged_bin)
            self.assertEqual(ctx.exception.code, 'upgrade_syntax_failed')

        # Live binary must NEVER have been touched
        self.assertEqual(active_bin.read_bytes(), b'xray_v26.7')

    # ------------------------------------------------------------------------
    # 4. Canary Validation Failure & Unconditional Auto-Rollback
    # ------------------------------------------------------------------------

    def test_component_upgrade_healthcheck_failure_triggers_auto_rollback(self):
        """Canary failure (service crash / listening port failure) triggers immediate self-healing rollback."""
        fake_dir = Path(self.temp_dir.name) / 'service_test'
        fake_dir.mkdir()
        active_bin = fake_dir / 'x-ui'
        active_bin.write_bytes(b'working_v3.7_binary')
        active_bin.chmod(0o755)

        db_file = fake_dir / 'x-ui.db'
        import sqlite3
        con = sqlite3.connect(str(db_file))
        con.execute('CREATE TABLE users (id INT, name TEXT)')
        con.execute('INSERT INTO users VALUES (1, "alice")')
        con.commit()
        con.close()

        manifest = {
            'component': 'panel',
            'version': '3.8.0',
            'architecture': 'x86_64',
            'sha256': 'dummy',
            'binaryName': 'x-ui',
        }
        req = {'id': '2' * 32, 'payload': manifest}
        upgrader = ComponentUpgrader(self.store, req, manifest)
        upgrader.detection = {
            'installed': True,
            'binaryPath': str(active_bin),
            'dbPath': str(db_file),
            'units': ['x-ui.service'],
            'ports': [54321],
            'arch': 'x86_64',
        }

        # 1. Take backup
        upgrader.backup()
        self.assertTrue((upgrader.backup_dir / 'x-ui').exists())

        # 2. Simulate applying broken new binary
        broken_staged = fake_dir / 'broken_new_bin'
        broken_staged.write_bytes(b'crashed_new_version')
        with patch('subprocess.run'):
            upgrader.apply_switch(broken_staged)
        self.assertEqual(active_bin.read_bytes(), b'crashed_new_version')

        # 3. Canary healthcheck fails (systemctl is-active returns 3 / failed)
        def fake_systemctl(cmd, **kwargs):
            if 'is-active' in cmd:
                return MagicMock(returncode=3)  # Inactive / failed
            return MagicMock(returncode=0)

        with patch('subprocess.run', side_effect=fake_systemctl):
            with self.assertRaises(ComponentUpgradeError) as ctx:
                upgrader.verify_health(timeout=1)
            self.assertEqual(ctx.exception.code, 'upgrade_healthcheck_failed')

        # 4. Verify SELF-HEALING ROLLBACK has succeeded!
        # Active binary must be reverted to the original working version
        self.assertEqual(active_bin.read_bytes(), b'working_v3.7_binary')

        # Verify DB is intact
        con = sqlite3.connect(str(db_file))
        row = con.execute('SELECT name FROM users WHERE id=1').fetchone()
        con.close()
        self.assertEqual(row[0], 'alice')

    # ------------------------------------------------------------------------
    # 5. Adopted / Pre-Existing Component Upgrade with Custom Paths
    # ------------------------------------------------------------------------

    def test_adopted_component_preserves_custom_path_and_permissions(self):
        """User-adopted component in custom path retains exact ownership, permissions and data."""
        custom_dir = Path(self.temp_dir.name) / 'opt' / 'custom-x-ui'
        custom_dir.mkdir(parents=True)
        adopted_bin = custom_dir / 'x-ui'
        adopted_bin.write_bytes(b'adopted_v3.6')
        adopted_bin.chmod(0o750)  # Custom restricted permissions

        manifest = {
            'component': 'panel',
            'version': '3.8.0',
            'architecture': 'x86_64',
            'sha256': 'dummy',
            'binaryName': 'x-ui',
        }
        req = {'id': '3' * 32, 'payload': manifest}
        upgrader = ComponentUpgrader(self.store, req, manifest)
        upgrader.detection = {
            'installed': True,
            'binaryPath': str(adopted_bin),
            'source': 'adopted_binary',
            'units': ['x-ui.service'],
            'ports': [],
            'arch': 'x86_64',
        }

        # Backup
        upgrader.backup()
        self.assertEqual(upgrader.backup_metadata['mode'] & 0o777, 0o750)

        # Apply upgrade with new binary
        new_staged = custom_dir / 'staged_bin'
        new_staged.write_bytes(b'upgraded_v3.8')
        with patch('subprocess.run'):
            upgrader.apply_switch(new_staged)

        # Confirm path is unchanged
        self.assertTrue(adopted_bin.exists())
        self.assertEqual(adopted_bin.read_bytes(), b'upgraded_v3.8')
        # Confirm custom permissions were preserved exactly
        self.assertEqual(adopted_bin.stat().st_mode & 0o777, 0o750)

    # ------------------------------------------------------------------------
    # 6. Runner Daemon RPC Job Execution with Auto-Rollback
    # ------------------------------------------------------------------------

    def test_runner_job_flow_and_rollback_recovery(self):
        """End-to-end execution of `component_upgrade_apply` in Runner daemon loop with rollback."""
        fake_dir = Path(self.temp_dir.name) / 'runner_flow'
        fake_dir.mkdir()
        fake_bin = fake_dir / 'xray'
        fake_bin.write_bytes(b'xray_v26.7')

        valid_archive = fake_dir / 'archive.tar.gz'
        with tarfile.open(valid_archive, 'w:gz') as t:
            data = b'xray_v26.9_new'
            ti = tarfile.TarInfo('xray')
            ti.size = len(data)
            ti.mode = 0o755
            import io
            t.addfile(ti, io.BytesIO(data))

        archive_sha = hashlib.sha256(valid_archive.read_bytes()).hexdigest()
        manifest = {
            'component': 'xray',
            'version': '26.9.9',
            'architecture': 'x86_64',
            'sha256': archive_sha,
            'url': f'file://{valid_archive}',
            'binaryName': 'xray',
        }

        with patch('component_upgrade.detect_component') as mock_detect, \
             patch('component_upgrade.check_system_resources'):
            mock_detect.return_value = {
                'installed': True,
                'source': 'native',
                'binaryPath': str(fake_bin),
                'arch': 'x86_64',
                'units': ['xray.service'],
                'ports': [],
            }
            # Plan request
            plan = component_upgrade_plan(self.store, 'xray', manifest)
            self.assertTrue(plan['ready'])
            self.assertTrue(plan['upgradable'])

            job_req = {
                'version': 1,
                'action': 'submit',
                'id': '4' * 32,
                'kind': 'component_upgrade_apply',
                'count': 6,
                'interval': 1,
                'payload': json.dumps(manifest),
                'fingerprint': plan['fingerprint'],
            }

            self.store.request(job_req)

            # Step 0: upgrade_prepared
            self.store.tick()
            job = self.store.request({'version': 1, 'action': 'status', 'id': '4' * 32, 'cursor': 0})['jobs'][0]
            self.assertEqual(job['checkpoint'], 1)
            self.assertEqual(job['events'][-1]['code'], 'upgrade_prepared')

            # Step 1: upgrade_downloaded
            self.store.tick()
            job = self.store.request({'version': 1, 'action': 'status', 'id': '4' * 32, 'cursor': 0})['jobs'][0]
            self.assertEqual(job['checkpoint'], 2)
            self.assertEqual(job['events'][-1]['code'], 'upgrade_downloaded')

            # Step 2: upgrade_backing_up
            self.store.tick()
            job = self.store.request({'version': 1, 'action': 'status', 'id': '4' * 32, 'cursor': 0})['jobs'][0]
            self.assertEqual(job['checkpoint'], 3)
            self.assertEqual(job['events'][-1]['code'], 'upgrade_backed_up')

            # Step 3: upgrade_syntax_checked
            with patch('subprocess.run', return_value=MagicMock(returncode=0)):
                self.store.tick()
            job = self.store.request({'version': 1, 'action': 'status', 'id': '4' * 32, 'cursor': 0})['jobs'][0]
            self.assertEqual(job['checkpoint'], 4)
            self.assertEqual(job['events'][-1]['code'], 'upgrade_syntax_checked')

            # Step 4: upgrade_switched
            with patch('subprocess.run', return_value=MagicMock(returncode=0)):
                self.store.tick()
            job = self.store.request({'version': 1, 'action': 'status', 'id': '4' * 32, 'cursor': 0})['jobs'][0]
            self.assertEqual(job['checkpoint'], 5)
            self.assertEqual(job['events'][-1]['code'], 'upgrade_switched')

            # Step 5: canary failure in step 5 -> automatic rollback and report
            with patch('subprocess.run', side_effect=lambda cmd, **kw: MagicMock(returncode=3 if 'is-active' in cmd else 0)), \
                 patch('time.sleep'), \
                 patch('time.monotonic', side_effect=[0, 20, 21, 22]):
                self.store.tick()

            final_job = self.store.request({'version': 1, 'action': 'status', 'id': '4' * 32, 'cursor': 0})['jobs'][0]
            self.assertEqual(final_job['status'], 'failed')
            self.assertEqual(final_job['events'][-1]['code'], 'upgrade_rolled_back')

            # Confirm original binary is restored after rollback
            self.assertEqual(fake_bin.read_bytes(), b'xray_v26.7')

    def test_component_upgrade_missing_or_empty_sha256_computed_and_assigned(self):
        """When manifest sha256 is missing or empty, digest(archive) is computed and assigned."""
        import io
        test_dir = Path(self.temp_dir.name) / 'sha_test'
        test_dir.mkdir()
        bin_file = test_dir / 'binary'
        bin_file.write_bytes(b'installed_bin')

        # Create valid tarball archive
        archive_path = test_dir / 'archive.tar.gz'
        with tarfile.open(archive_path, 'w:gz') as t:
            data = b'new_bin_bytes'
            info = tarfile.TarInfo('binary')
            info.size = len(data)
            t.addfile(info, io.BytesIO(data))

        expected_hash = hashlib.sha256(archive_path.read_bytes()).hexdigest()

        # 1. validate_and_stage with empty sha256
        manifest = {
            'component': 'xray',
            'version': '26.9.9',
            'architecture': 'x86_64',
            'sha256': '',
            'binaryName': 'binary',
        }
        req = {'id': '5' * 32, 'payload': manifest}
        upgrader = ComponentUpgrader(self.store, req, manifest)
        upgrader.detection = {
            'installed': True,
            'binaryPath': str(bin_file),
            'arch': 'x86_64',
        }

        upgrader.validate_and_stage(archive_path)
        self.assertEqual(manifest['sha256'], expected_hash)

        # 2. ComponentUpgradeJob.step(1) with missing sha256
        payload = {
            'component': 'xray',
            'version': '26.9.9',
            'architecture': 'x86_64',
            'binaryName': 'binary',
            'url': f'file://{archive_path}',
        }
        job_req = {
            'version': 1,
            'action': 'submit',
            'id': '6' * 32,
            'kind': 'component_upgrade_apply',
            'count': 6,
            'interval': 1,
            'payload': json.dumps(payload),
            'fingerprint': 'f' * 64,
        }
        self.store.request(job_req)
        job = ComponentUpgradeJob(self.store, job_req)
        job.step(1)
        self.assertEqual(job.payload['sha256'], expected_hash)
        self.assertEqual(job.upgrader.manifest['sha256'], expected_hash)

    def test_composite_3xui_distribution_atomic_switch_and_db_preservation(self):
        """Composite 3x-ui distributions update x-ui, x-ui.sh, xray and NEVER touch x-ui.db."""
        import io
        import sqlite3
        test_panel_dir = Path(self.temp_dir.name) / 'usr_local_x_ui'
        test_panel_dir.mkdir(parents=True)
        active_xui = test_panel_dir / 'x-ui'
        active_xui.write_bytes(b'old_xui_v2.4')
        active_xui.chmod(0o755)

        active_sh = test_panel_dir / 'x-ui.sh'
        active_sh.write_bytes(b'#!/bin/bash\necho old')
        active_sh.chmod(0o755)

        bin_subdir = test_panel_dir / 'bin'
        bin_subdir.mkdir(parents=True)
        active_xray = bin_subdir / 'xray-linux-amd64'
        active_xray.write_bytes(b'old_xray_core')
        active_xray.chmod(0o755)

        # Protected database (valid SQLite database)
        test_etc_dir = Path(self.temp_dir.name) / 'etc_x_ui'
        test_etc_dir.mkdir(parents=True)
        protected_db = test_etc_dir / 'x-ui.db'
        con = sqlite3.connect(str(protected_db))
        con.execute('CREATE TABLE users (id INT, name TEXT)')
        con.execute('INSERT INTO users VALUES (1, "alice")')
        con.commit()
        con.close()
        db_before_bytes = protected_db.read_bytes()

        # Create composite tarball
        archive_path = Path(self.temp_dir.name) / 'x-ui-linux-amd64.tar.gz'
        with tarfile.open(archive_path, 'w:gz') as t:
            # 1. x-ui binary
            info1 = tarfile.TarInfo('x-ui/x-ui')
            info1.size = len(b'new_composite_xui_v2.5')
            t.addfile(info1, io.BytesIO(b'new_composite_xui_v2.5'))

            # 2. x-ui.sh
            info2 = tarfile.TarInfo('x-ui/x-ui.sh')
            info2.size = len(b'#!/bin/bash\necho new_sh')
            t.addfile(info2, io.BytesIO(b'#!/bin/bash\necho new_sh'))

            # 3. bin/xray-linux-amd64
            info3 = tarfile.TarInfo('x-ui/bin/xray-linux-amd64')
            info3.size = len(b'new_xray_core_v26.9')
            t.addfile(info3, io.BytesIO(b'new_xray_core_v26.9'))

            # Even if archive contains a dummy x-ui.db, it must be ignored
            info4 = tarfile.TarInfo('x-ui/x-ui.db')
            info4.size = len(b'MALICIOUS_OVERWRITE_DB')
            t.addfile(info4, io.BytesIO(b'MALICIOUS_OVERWRITE_DB'))

        archive_sha = hashlib.sha256(archive_path.read_bytes()).hexdigest()

        manifest = {
            'component': 'panel',
            'version': '2.5.0',
            'architecture': 'x86_64',
            'sha256': archive_sha,
            'binaryName': 'x-ui',
        }
        req = {'id': '7' * 32, 'payload': manifest}
        upgrader = ComponentUpgrader(self.store, req, manifest)
        upgrader.detection = {
            'installed': True,
            'binaryPath': str(active_xui),
            'source': 'native',
            'units': ['x-ui.service'],
            'dbPath': str(protected_db),
            'ports': [],
            'arch': 'x86_64',
        }

        # Backup
        upgrader.backup()
        self.assertEqual(protected_db.read_bytes(), db_before_bytes)

        # Validate and stage composite files
        staged_binary = upgrader.validate_and_stage(archive_path)
        self.assertIsNotNone(staged_binary)
        self.assertEqual(staged_binary.stat().st_mode & 0o777, 0o755)

        # Apply switch
        with patch('subprocess.run'):
            upgrader.apply_switch(staged_binary)

        # Verify all composite components are upgraded with 0o755
        self.assertEqual(active_xui.read_bytes(), b'new_composite_xui_v2.5')
        self.assertEqual(active_xui.stat().st_mode & 0o777, 0o755)

        self.assertEqual(active_sh.read_bytes(), b'#!/bin/bash\necho new_sh')
        self.assertEqual(active_sh.stat().st_mode & 0o777, 0o755)

        self.assertEqual(active_xray.read_bytes(), b'new_xray_core_v26.9')
        self.assertEqual(active_xray.stat().st_mode & 0o777, 0o755)

        # CRITICAL: Verify database is untouched and NOT overwritten or deleted
        self.assertTrue(protected_db.exists())
        self.assertEqual(protected_db.read_bytes(), db_before_bytes)
        con = sqlite3.connect(str(protected_db))
        row = con.execute('SELECT name FROM users WHERE id=1').fetchone()
        con.close()
        self.assertEqual(row[0], 'alice')

    def test_xray_zip_with_generic_name_upgrades_amd64_target_binary(self):
        """Official XTLS/Xray-core releases name binary 'xray' inside zip, while 3x-ui names it 'xray-linux-amd64'."""
        import zipfile
        fake_fs = Path(self.temp_dir.name) / 'fake_xui_fs'
        bin_dir = fake_fs / 'usr/local/x-ui/bin'
        bin_dir.mkdir(parents=True, exist_ok=True)
        active_xray = bin_dir / 'xray-linux-amd64'
        active_xray.write_bytes(b'old_xray_core_26.10.21')
        active_geoip = bin_dir / 'geoip.dat'
        active_geoip.write_bytes(b'old_geoip')

        # Create upstream Xray zip archive containing 'xray', 'geoip.dat', 'geosite.dat', 'LICENSE'
        zip_path = fake_fs / 'Xray-linux-64.zip'
        with zipfile.ZipFile(str(zip_path), 'w') as zf:
            zf.writestr('xray', b'new_xray_core_26.11.9')
            zf.writestr('geoip.dat', b'new_geoip_data')
            zf.writestr('geosite.dat', b'new_geosite_data')
            zf.writestr('LICENSE', b'Mozilla Public License')
            zf.writestr('README.md', b'# Xray')

        request = {
            'id': 'd' * 32,
            'kind': 'component_upgrade_apply',
            'count': 6,
            'interval': 1,
            'fingerprint': 'e' * 64,
            'payload': json.dumps({'component': 'xray', 'version': '26.11.9'}),
        }
        upgrader = ComponentUpgrader(self.store, request, {'component': 'xray', 'version': '26.11.9'})
        upgrader.detection = {
            'component': 'xray',
            'installed': True,
            'binaryPath': str(active_xray),
            'source': 'native',
            'units': ['x-ui.service'],
            'configPath': None,
            'ports': [],
            'arch': 'x86_64',
        }

        upgrader.backup()
        staged_binary = upgrader.validate_and_stage(zip_path)
        self.assertIsNotNone(staged_binary)
        self.assertEqual(staged_binary.name, 'xray')

        with patch('subprocess.run') as mock_run:
            mock_run.return_value = MagicMock(returncode=0)
            upgrader.syntax_pre_check(staged_binary)
            upgrader.apply_switch(staged_binary)

        # Verify active binary replaced
        self.assertEqual(active_xray.read_bytes(), b'new_xray_core_26.11.9')
        # Verify geoip.dat and geosite.dat updated
        self.assertEqual(active_geoip.read_bytes(), b'new_geoip_data')
        self.assertEqual((bin_dir / 'geosite.dat').read_bytes(), b'new_geosite_data')

    def test_store_event_code_safe_fallback(self):
        """Store.event must never write an invalid event code that violates RunnerEvent schema."""
        job_id = 'c' * 32
        req = {'version': 1, 'action': 'submit', 'id': job_id, 'kind': 'component_upgrade_apply', 'count': 6, 'interval': 1, 'payload': '{}', 'fingerprint': 'a' * 64}
        with self.store.db:
            self.store.db.execute("INSERT INTO jobs VALUES (?,?,?,0,0,0,?)", (job_id, json.dumps(req), 'running', time.time()))

        # Emitting unknown code should fallback to 'failed' rather than crashing or storing illegal event
        self.store.event(job_id, 'non_existent_crazy_event_code', 1, 6)
        row = self.store.db.execute("SELECT event FROM events WHERE id=?", (job_id,)).fetchone()
        self.assertIsNotNone(row)
        event = json.loads(row[0])
        self.assertEqual(event['code'], 'failed')


if __name__ == '__main__':
    unittest.main()
