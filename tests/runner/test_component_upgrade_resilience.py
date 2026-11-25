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
        """A dpkg lock held by another process (POSIX lock) ends in a bounded backoff and a clean error."""
        lock = Path(self.temp_dir.name) / 'lock'
        lock.write_bytes(b'')
        holder = subprocess.Popen([sys.executable, '-c', 'import fcntl,sys,time\n'
            'f=open(sys.argv[1],"r+"); fcntl.lockf(f, fcntl.LOCK_EX); print("held", flush=True); time.sleep(30)',
            str(lock)], stdout=subprocess.PIPE)
        try:
            self.assertEqual(holder.stdout.readline().strip(), b'held')
            sleeps = []
            with patch('apt.is_unit_active', return_value=False):
                started = time.monotonic()
                with self.assertRaises(AptError) as ctx:
                    acquire_dpkg_locks(timeout=0.2, paths=[lock], sleep=sleeps.append)
            self.assertEqual(ctx.exception.code, 'apt_lock_busy')
            self.assertLess(time.monotonic() - started, 5)
        finally:
            holder.kill(); holder.wait(timeout=10); holder.stdout.close()

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

    def test_trusttunnel_archive_extraction(self):
        """Archive with root ./ entry and sha256:... prefix passes verify_sha256 and extract_archive_safe."""
        from component_upgrade import verify_sha256, extract_archive_safe
        import io
        archive_dir = Path(self.temp_dir.name) / 'tt_test'
        archive_dir.mkdir()
        tar_path = archive_dir / 'trusttunnel-v1.3.0-beta.2-linux-x86_64.tar.gz'

        with tarfile.open(tar_path, 'w:gz') as t:
            root_ti = tarfile.TarInfo('./')
            root_ti.type = tarfile.DIRTYPE
            t.addfile(root_ti)

            sub_ti = tarfile.TarInfo('trusttunnel-v1.3.0-beta.2-linux-x86_64/')
            sub_ti.type = tarfile.DIRTYPE
            t.addfile(sub_ti)

            payload = b"trusttunnel_endpoint_binary_content"
            bin_ti = tarfile.TarInfo('trusttunnel-v1.3.0-beta.2-linux-x86_64/trusttunnel_endpoint')
            bin_ti.size = len(payload)
            bin_ti.mode = 0o755
            t.addfile(bin_ti, io.BytesIO(payload))

        expected_hash = hashlib.sha256(tar_path.read_bytes()).hexdigest()
        raw_digest = f"sha256:{expected_hash}"

        verify_sha256(tar_path, raw_digest)

        extract_dest = archive_dir / 'extracted'
        extract_archive_safe(tar_path, extract_dest)

        extracted_bin = extract_dest / 'trusttunnel-v1.3.0-beta.2-linux-x86_64' / 'trusttunnel_endpoint'
        self.assertTrue(extracted_bin.exists())
        self.assertEqual(extracted_bin.read_bytes(), payload)

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
            # The check only reports; the job rolls back exactly once.
            self.assertEqual(active_bin.read_bytes(), b'crashed_new_version')
            upgrader.rollback()

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

    def test_semver_preserves_prerelease(self):
        """Parsing component version output with prerelease tags preserves full semver."""
        from component_upgrade import extract_semver
        self.assertEqual(extract_semver("trusttunnel_endpoint 1.3.0-beta.2\n"), "1.3.0-beta.2")
        self.assertEqual(extract_semver("1.1.0"), "1.1.0")
        self.assertEqual(extract_semver("v3.11.0"), "3.11.0")
        self.assertEqual(extract_semver("Xray 26.11.9 (Xray, Penetrates Everything.)"), "26.11.9")
        self.assertEqual(extract_semver("amneziawg-go v3.1.20260828"), "3.1.20260828")

    def test_precheck_aborts_on_wrong_arch_elf(self):
        """Providing an ARM64 ELF binary on x86_64 aborts in syntax_pre_check before switch."""
        from component_upgrade import ComponentUpgrader, ComponentUpgradeError
        target_dir = Path(self.temp_dir.name) / 'arch_test'
        target_dir.mkdir()
        active_bin = target_dir / 'trusttunnel_endpoint'
        active_bin.write_bytes(b'old_tt_binary')

        # Craft mock ARM64 ELF header (e_machine = 0xb7 at offset 18-19)
        arm64_elf = bytearray(b'\x7fELF\x02\x01\x01\x00' + b'\x00' * 10)
        arm64_elf += (0xb7).to_bytes(2, byteorder='little')
        arm64_elf += b'\x00' * 50

        staged_bin = target_dir / 'staged_arm64'
        staged_bin.write_bytes(bytes(arm64_elf))

        manifest = {
            'component': 'trusttunnel',
            'version': '1.3.0-beta.2',
            'architecture': 'x86_64',
            'sha256': '',
        }
        upgrader = ComponentUpgrader(self.store, {'id': 'a' * 32}, manifest)
        upgrader.detection = {
            'component': 'trusttunnel',
            'installed': True,
            'binaryPath': str(active_bin),
            'source': 'native',
            'units': [],
            'configPath': None,
            'ports': [],
            'arch': 'x86_64',
        }
        upgrader.backup()

        with patch('component_upgrade.normalize_arch', return_value='x86_64'):
            with self.assertRaises(ComponentUpgradeError) as ctx:
                upgrader.syntax_pre_check(staged_bin)
            self.assertEqual(ctx.exception.code, 'upgrade_architecture_mismatch')

        # Active binary was NOT touched
        self.assertEqual(active_bin.read_bytes(), b'old_tt_binary')

    def test_canary_rollback_on_port_bind_failure(self):
        """If updated binary starts but expected socket is not bound, canary triggers rollback."""
        from component_upgrade import ComponentUpgrader, ComponentUpgradeError
        target_dir = Path(self.temp_dir.name) / 'canary_test'
        target_dir.mkdir()
        active_bin = target_dir / 'trusttunnel_endpoint'
        active_bin.write_bytes(b'healthy_old_binary')

        new_bin = target_dir / 'new_binary'
        new_bin.write_bytes(b'broken_new_binary')

        manifest = {
            'component': 'trusttunnel',
            'version': '1.3.0-beta.2',
            'architecture': 'x86_64',
            'sha256': '',
        }
        upgrader = ComponentUpgrader(self.store, {'id': 'b' * 32}, manifest)
        upgrader.detection = {
            'component': 'trusttunnel',
            'installed': True,
            'binaryPath': str(active_bin),
            'source': 'native',
            'units': ['antirkn-tt@test.service'],
            'configPath': None,
            'ports': [8443],
            'healthTargets': [
                {
                    'unit_name': 'antirkn-tt@test.service',
                    'initial_state': 'active',
                    'initial_restarts': 0,
                    'config_path': None,
                    'expected_bindings': [{'host': '0.0.0.0', 'port': 8443, 'protocol': 'tcp'}],
                }
            ],
            'arch': 'x86_64',
        }
        upgrader.backup()
        with patch('subprocess.run', return_value=MagicMock(returncode=0, stdout='ActiveState=active\nNRestarts=0\n')):
            upgrader.apply_switch(new_bin)
        self.assertEqual(active_bin.read_bytes(), b'broken_new_binary')

        # Mock: service is active, but socket probe fails (port 8443 not listening)
        with patch('subprocess.run', return_value=MagicMock(returncode=0, stdout='ActiveState=active\nNRestarts=0\n')), \
             patch('component_upgrade.verify_socket_bindings', return_value=(False, 'Missing port 8443')):
            with self.assertRaises(ComponentUpgradeError) as ctx:
                upgrader.verify_health(timeout=0.1)
            self.assertEqual(ctx.exception.code, 'upgrade_healthcheck_failed')
            self.assertEqual(active_bin.read_bytes(), b'broken_new_binary')
            upgrader.rollback()

        # Rollback restored the original binary!
        self.assertEqual(active_bin.read_bytes(), b'healthy_old_binary')

    def test_trusttunnel_syntax_check_help_fallback(self):
        """trusttunnel_endpoint succeeds on --version and setup_wizard succeeds on --help."""
        from component_upgrade import ComponentUpgrader
        staging_dir = Path(self.temp_dir.name) / 'stage_tt'
        staging_dir.mkdir()
        tt_bin = staging_dir / 'trusttunnel_endpoint'
        tt_bin.write_bytes(b'\x7fELF\x02\x01\x01\x00' + b'\x00' * 10 + (0x3e).to_bytes(2, 'little') + b'\x00' * 50)
        sw_bin = staging_dir / 'setup_wizard'
        sw_bin.write_bytes(b'\x7fELF\x02\x01\x01\x00' + b'\x00' * 10 + (0x3e).to_bytes(2, 'little') + b'\x00' * 50)

        upgrader = ComponentUpgrader(self.store, {'id': 'c' * 32}, {'component': 'trusttunnel', 'version': '1.3.0-beta.2', 'sha256': ''})
        upgrader.staging_dir = staging_dir
        upgrader.detection = {'component': 'trusttunnel', 'installed': True, 'binaryPath': '/usr/local/bin/trusttunnel_endpoint', 'arch': 'x86_64'}

        def mock_run(cmd, *args, **kwargs):
            if 'trusttunnel_endpoint' in str(cmd[0]):
                return MagicMock(returncode=0, stdout='1.3.0-beta.2\n', stderr='')
            elif 'setup_wizard' in str(cmd[0]) and '--help' in cmd:
                return MagicMock(returncode=0, stdout='Usage: setup_wizard [OPTIONS]\n', stderr='')
            elif 'setup_wizard' in str(cmd[0]) and '--version' in cmd:
                return MagicMock(returncode=2, stdout='', stderr='unexpected argument')
            return MagicMock(returncode=0, stdout='ok', stderr='')

        with patch('subprocess.run', side_effect=mock_run):
            upgrader.syntax_pre_check(tt_bin)

    def test_trusttunnel_syntax_check_missing_wizard(self):
        """Archive missing setup_wizard raises upgrade_syntax_failed."""
        from component_upgrade import ComponentUpgrader, ComponentUpgradeError
        staging_dir = Path(self.temp_dir.name) / 'stage_no_wizard'
        staging_dir.mkdir()
        tt_bin = staging_dir / 'trusttunnel_endpoint'
        tt_bin.write_bytes(b'\x7fELF\x02\x01\x01\x00' + b'\x00' * 10 + (0x3e).to_bytes(2, 'little') + b'\x00' * 50)

        upgrader = ComponentUpgrader(self.store, {'id': 'd' * 32}, {'component': 'trusttunnel', 'version': '1.3.0-beta.2', 'sha256': ''})
        upgrader.staging_dir = staging_dir
        upgrader.detection = {'component': 'trusttunnel', 'installed': True, 'binaryPath': '/usr/local/bin/trusttunnel_endpoint', 'arch': 'x86_64'}

        with patch('subprocess.run', return_value=MagicMock(returncode=0, stdout='1.3.0-beta.2\n')):
            with self.assertRaises(ComponentUpgradeError) as ctx:
                upgrader.syntax_pre_check(tt_bin)
            self.assertEqual(ctx.exception.code, 'upgrade_syntax_failed')
            self.assertIn('setup_wizard binary missing', ctx.exception.detail)

    def test_trusttunnel_syntax_check_rejects_symlink(self):
        """A symlinked setup_wizard is rejected as upgrade_syntax_failed without chmod or exec."""
        from component_upgrade import ComponentUpgrader, ComponentUpgradeError
        staging_dir = Path(self.temp_dir.name) / 'stage_symlink'
        staging_dir.mkdir()
        tt_bin = staging_dir / 'trusttunnel_endpoint'
        tt_bin.write_bytes(b'\x7fELF\x02\x01\x01\x00' + b'\x00' * 10 + (0x3e).to_bytes(2, 'little') + b'\x00' * 50)

        fake_target = staging_dir / 'real_file'
        fake_target.write_bytes(b'echo')
        symlink_wizard = staging_dir / 'setup_wizard'
        symlink_wizard.symlink_to(fake_target)

        upgrader = ComponentUpgrader(self.store, {'id': 'e' * 32}, {'component': 'trusttunnel', 'version': '1.3.0-beta.2', 'sha256': ''})
        upgrader.staging_dir = staging_dir
        upgrader.detection = {'component': 'trusttunnel', 'installed': True, 'binaryPath': '/usr/local/bin/trusttunnel_endpoint', 'arch': 'x86_64'}

        with patch('subprocess.run', return_value=MagicMock(returncode=0, stdout='1.3.0-beta.2\n')):
            with self.assertRaises(ComponentUpgradeError) as ctx:
                upgrader.syntax_pre_check(tt_bin)
            self.assertEqual(ctx.exception.code, 'upgrade_syntax_failed')

    def test_plan_fingerprint_unit_order_invariant(self):
        """canonical_plan_fingerprint produces identical hash regardless of unit order."""
        from component_upgrade import canonical_plan_fingerprint
        plan1 = {
            'component': 'trusttunnel',
            'installed': True,
            'units': ['antirkn-tt@b.service', 'antirkn-tt@a.service'],
            'currentVersion': '1.1.0',
        }
        plan2 = {
            'component': 'trusttunnel',
            'installed': True,
            'units': ['antirkn-tt@a.service', 'antirkn-tt@b.service'],
            'currentVersion': '1.1.0',
        }
        self.assertEqual(canonical_plan_fingerprint(plan1), canonical_plan_fingerprint(plan2))

    def test_probe_staged_binary_stderr_output(self):
        """probe_staged_binary succeeds if binary outputs version on stderr."""
        from component_upgrade import probe_staged_binary
        fake_bin = Path(self.temp_dir.name) / 'fake_probe_bin'
        fake_bin.write_bytes(b'fake')
        with patch('subprocess.run', return_value=MagicMock(returncode=0, stdout='', stderr='x-ui v3.8.0\n')):
            out = probe_staged_binary(fake_bin, ['-v'])
            self.assertEqual(out, 'x-ui v3.8.0')

    def test_sync_panel_access_versions_creates_missing_version_file(self):
        """After a switch the installed panel+Xray versions are recorded for the owner.

        The job has no `manifest` attribute; the versions come from the binaries,
        because a 3x-ui archive also replaces its bundled Xray.
        """
        job = ComponentUpgradeJob(self.store, {'id': 'f' * 32, 'payload': json.dumps({'component': 'panel', 'version': '3.11.0'})})
        job.upgrader.component = 'panel'
        self.assertFalse(hasattr(job, 'manifest'))
        fake_db_dir = Path(self.temp_dir.name) / 'etc_x_ui'
        fake_db_dir.mkdir(parents=True, exist_ok=True)
        owner_file = fake_db_dir / '.antirkn-owner'
        owner_file.write_text('test_owner_123')

        with patch('panel.DATABASE', fake_db_dir), \
             patch('panel_discovery.EXTERNAL_ACCESS', fake_db_dir / '.external-access'), \
             patch('component_upgrade.installed_panel_versions', return_value={'panelVersion': '3.11.0', 'xrayVersion': '26.10.21'}):
            job._sync_panel_access_versions()
            version_file = fake_db_dir / '.antirkn-versions'
            self.assertTrue(version_file.exists())
            data = json.loads(version_file.read_text())
            self.assertEqual(data.get('id'), 'test_owner_123')
            self.assertEqual(data.get('panelVersion'), '3.11.0')
            self.assertEqual(data.get('xrayVersion'), '26.10.21')

    def test_sync_panel_access_versions_keeps_other_owner_record(self):
        """A version record of another panel id is never rewritten."""
        from component_upgrade import sync_installed_versions
        fake_db_dir = Path(self.temp_dir.name) / 'etc_x_ui_other'
        fake_db_dir.mkdir(parents=True, exist_ok=True)
        (fake_db_dir / '.antirkn-owner').write_text('owner_a')
        (fake_db_dir / '.antirkn-versions').write_text(json.dumps({'id': 'owner_b', 'panelVersion': '3.7.0', 'xrayVersion': '26.7.28'}))
        with patch('panel.DATABASE', fake_db_dir), \
             patch('panel_discovery.EXTERNAL_ACCESS', fake_db_dir / '.external-access'), \
             patch('component_upgrade.installed_panel_versions', return_value={'panelVersion': '3.11.0', 'xrayVersion': '26.10.21'}):
            sync_installed_versions()
        data = json.loads((fake_db_dir / '.antirkn-versions').read_text())
        self.assertEqual(data, {'id': 'owner_b', 'panelVersion': '3.7.0', 'xrayVersion': '26.7.28'})

    def test_normalize_sha256_canonical_and_error_cases(self):
        """normalize_sha256 strips sha256: prefix, validates 64-hex and rejects garbage."""
        from component_upgrade import normalize_sha256
        sample_hex = '496a27ff72014b883438efab55ffd237183b5ff95d9c341cc0de9d18342a9b11'
        self.assertEqual(normalize_sha256(''), '')
        self.assertEqual(normalize_sha256(None), '')
        self.assertEqual(normalize_sha256('   '), '')
        self.assertEqual(normalize_sha256(sample_hex), sample_hex)
        self.assertEqual(normalize_sha256(f'sha256:{sample_hex}'), sample_hex)
        self.assertEqual(normalize_sha256(f'SHA256:{sample_hex.upper()}'), sample_hex)
        self.assertEqual(normalize_sha256(f'  sha256:{sample_hex}  '), sample_hex)

        with self.assertRaises(ComponentUpgradeError) as ctx:
            normalize_sha256('short')
        self.assertEqual(ctx.exception.code, 'upgrade_checksum_failed')

        with self.assertRaises(ComponentUpgradeError) as ctx:
            normalize_sha256(sample_hex + 'extra')
        self.assertEqual(ctx.exception.code, 'upgrade_checksum_failed')

        with self.assertRaises(ComponentUpgradeError) as ctx:
            normalize_sha256('z' * 64)
        self.assertEqual(ctx.exception.code, 'upgrade_checksum_failed')

    def test_verify_sha256_rejects_empty_digest(self):
        """verify_sha256 rejects None, empty strings, and invalid hashes."""
        from component_upgrade import verify_sha256
        dummy_file = Path(self.temp_dir.name) / 'dummy.bin'
        dummy_file.write_bytes(b'test_payload')
        for bad_digest in (None, '', '   ', 'not_a_hex', 'a' * 63):
            with self.assertRaises(ComponentUpgradeError) as ctx:
                verify_sha256(dummy_file, bad_digest)
            self.assertEqual(ctx.exception.code, 'upgrade_checksum_failed')


if __name__ == '__main__':
    unittest.main()


class UpgradeConnectivityAndConfirmationTests(unittest.TestCase):
    """Real-connection verification and the confirmation window ("commit confirmed")."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.store = Store(self.temp_dir.name)
        self.addCleanup(self.temp_dir.cleanup)
        self.addCleanup(self.store.close)
        self.job_id = 'a' * 32
        self.request = {'version': 1, 'action': 'submit', 'id': self.job_id, 'kind': 'component_upgrade_apply',
                        'count': 6, 'interval': 1, 'payload': json.dumps({'component': 'xray', 'version': '26.11.9'}),
                        'fingerprint': 'b' * 64}
        self.store.db.execute('INSERT INTO jobs VALUES (?,?,?,6,0,0,?)', (self.job_id, json.dumps(self.request), 'succeeded', time.time()))
        self.store.db.commit()

    def _upgrader(self, before):
        upgrader = ComponentUpgrader(self.store, self.request, json.loads(self.request['payload']))
        upgrader.backup_metadata = {'binaryPath': '/nonexistent/xray', 'probeBefore': before}
        upgrader.detection = {'installed': True, 'binaryPath': '/nonexistent/xray'}
        return upgrader

    def test_inbound_that_stops_working_fails_the_check(self):
        upgrader = self._upgrader({'vless:443': True, 'vless:8443': False})
        clock = iter([0, 0, 100])
        with patch('component_upgrade.probe_component', return_value={'vless:443': False, 'vless:8443': False}) as probe, \
             patch('component_upgrade.time.sleep'), \
             patch('component_upgrade.time.monotonic', side_effect=lambda: next(clock)), \
             patch.object(ComponentUpgrader, 'rollback') as rollback:
            with self.assertRaises(ComponentUpgradeError) as ctx:
                upgrader.verify_connectivity()
        self.assertEqual(ctx.exception.code, 'upgrade_connectivity_failed')
        # The job rolls back on the error; the check itself never does.
        rollback.assert_not_called()
        # Every probe gets the one overall deadline.
        self.assertEqual({c.kwargs['deadline'] for c in probe.call_args_list}, {54})

    def test_previous_core_cut_off_rolls_back(self):
        """Double hop: an entry on the previous core must still reach this server."""
        with tempfile.TemporaryDirectory() as tmp:
            upgrader = self._upgrader({'vless:443': True})
            upgrader.backup_dir = Path(tmp)
            upgrader.backup_metadata['binaryPath'] = '/usr/local/x-ui/bin/xray-linux-amd64'
            core = Path(tmp) / 'xray-linux-amd64'
            core.write_text('#!/bin/sh\n')
            core.chmod(0o755)
            with patch('component_upgrade.probe_component', return_value={'vless:443': True}), \
                 patch('upgrade_probe.probe_vless', return_value={'vless:443': False}) as old_client, \
                 patch('component_upgrade.time.sleep'), \
                 patch('component_upgrade.time.monotonic', side_effect=[0, 0, 100]), \
                 patch.object(ComponentUpgrader, 'rollback') as rollback:
                with self.assertRaises(ComponentUpgradeError) as ctx:
                    upgrader.verify_connectivity()
            self.assertEqual(ctx.exception.code, 'upgrade_connectivity_failed')
            self.assertIn('previous:vless:443', ctx.exception.detail)
            self.assertEqual(old_client.call_args.kwargs['binary'], core)
            rollback.assert_not_called()

    def test_inbound_broken_before_does_not_block_upgrade(self):
        upgrader = self._upgrader({'vless:443': True, 'vless:8443': False})
        with patch('component_upgrade.probe_component', return_value={'vless:443': True, 'vless:8443': False}), \
             patch.object(ComponentUpgrader, 'rollback') as rollback:
            self.assertEqual(upgrader.verify_connectivity(), [])
        rollback.assert_not_called()

    def test_unconfirmed_upgrade_rolls_back_and_confirmed_does_not(self):
        from component_upgrade import arm_deadman, confirm_upgrade, fire_deadman
        with patch('component_upgrade.subprocess.run') as run:
            arm_deadman(self.store, self.request)
        self.assertTrue(any('systemd-run' in call.args[0][0] for call in run.call_args_list))
        with patch.object(ComponentUpgrader, 'rollback') as rollback, \
             patch('component_upgrade.sync_installed_versions'):
            self.assertTrue(fire_deadman(self.store, self.job_id))
            rollback.assert_called_once()
        status = self.store.db.execute('SELECT status FROM jobs WHERE id=?', (self.job_id,)).fetchone()[0]
        self.assertEqual(status, 'failed')
        with self.assertRaises(ComponentUpgradeError) as ctx, patch('component_upgrade.subprocess.run'):
            confirm_upgrade(self.store, self.job_id)
        self.assertEqual(ctx.exception.code, 'upgrade_rolled_back')

    def test_confirmed_upgrade_stops_the_timer(self):
        from component_upgrade import arm_deadman, confirm_upgrade, fire_deadman
        with patch('component_upgrade.subprocess.run') as run:
            arm_deadman(self.store, self.request)
            confirm_upgrade(self.store, self.job_id)
        self.assertTrue(any(call.args[0][:2] == ['/usr/bin/systemctl', 'stop'] for call in run.call_args_list))
        with patch.object(ComponentUpgrader, 'rollback') as rollback:
            self.assertFalse(fire_deadman(self.store, self.job_id))
            rollback.assert_not_called()
        events = [json.loads(r[0])['code'] for r in self.store.db.execute('SELECT event FROM events WHERE id=?', (self.job_id,))]
        self.assertIn('upgrade_confirmed', events)


class ConfirmationWindowLifecycleTests(unittest.TestCase):
    """The backup has to outlive the finished job until the window closes."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.store = Store(self.temp_dir.name)
        self.addCleanup(self.temp_dir.cleanup)
        self.addCleanup(self.store.close)
        self.job_id = 'c' * 32
        self.request = {'version': 1, 'action': 'submit', 'id': self.job_id, 'kind': 'component_upgrade_apply',
                        'count': 6, 'interval': 1, 'payload': json.dumps({'component': 'xray', 'version': '26.11.9'}),
                        'fingerprint': 'b' * 64}
        self.store.db.execute('INSERT INTO jobs VALUES (?,?,?,6,5,0,?)', (self.job_id, json.dumps(self.request), 'running', time.time()))
        self.store.db.commit()
        self.work = Path(self.temp_dir.name) / ('upgrade-' + self.job_id)

    def _finish_last_checkpoint(self):
        from component_upgrade import arm_deadman

        def step(job, checkpoint):
            (self.work / 'backup').mkdir(parents=True, exist_ok=True)
            (self.work / 'backup' / 'meta.json').write_text('{}')
            (self.work / 'staging').mkdir(exist_ok=True)
            (self.work / 'release_archive').write_bytes(b'x')
            with patch('component_upgrade.subprocess.run'):
                arm_deadman(self.store, self.request)
        with patch('component_upgrade.ComponentUpgradeJob.step', step):
            self.store.tick()

    def test_backup_survives_success_until_confirmation(self):
        from component_upgrade import confirm_upgrade
        self._finish_last_checkpoint()
        status = self.store.db.execute('SELECT status FROM jobs WHERE id=?', (self.job_id,)).fetchone()[0]
        self.assertEqual(status, 'succeeded')
        self.assertTrue((self.work / 'backup' / 'meta.json').exists())
        self.assertFalse((self.work / 'staging').exists())
        self.assertFalse((self.work / 'release_archive').exists())
        with patch('component_upgrade.subprocess.run'):
            confirm_upgrade(self.store, self.job_id)
            confirm_upgrade(self.store, self.job_id)  # a repeated confirmation is harmless
        self.assertFalse((self.work / 'backup').exists())
        self.assertTrue((self.work / 'deadman.json').exists())

    def test_expired_window_still_finds_the_backup(self):
        from component_upgrade import fire_deadman
        self._finish_last_checkpoint()
        with patch('component_upgrade._late_rollback') as late, \
             patch('component_upgrade.sync_installed_versions'):
            self.assertTrue(fire_deadman(self.store, self.job_id))
        upgrader = late.call_args.args[0]
        self.assertEqual(upgrader.backup_dir, self.work / 'backup')
        events = [json.loads(r[0])['code'] for r in self.store.db.execute('SELECT event FROM events WHERE id=? ORDER BY sequence', (self.job_id,))]
        self.assertEqual(events[-1], 'upgrade_rolled_back')
        self.assertFalse((self.work / 'backup').exists())

    def test_late_rollback_keeps_live_data_when_old_version_runs(self):
        from component_upgrade import _late_rollback
        upgrader = ComponentUpgrader(self.store, self.request, json.loads(self.request['payload']))
        upgrader.backup_metadata = {'binaryPath': '/x', 'units': ['x-ui.service'], 'dbPath': '/db',
                                    'probeBefore': {'vless:443': True}}
        with patch.object(ComponentUpgrader, 'rollback') as rollback, \
             patch('component_upgrade._units_settled', return_value=True), \
             patch('component_upgrade.probe_component', return_value={'vless:443': True}):
            _late_rollback(upgrader)
        self.assertEqual([c.kwargs for c in rollback.call_args_list], [{'restore_data': False}])

    def test_late_rollback_restores_data_when_old_version_does_not_come_up(self):
        from component_upgrade import _late_rollback
        upgrader = ComponentUpgrader(self.store, self.request, json.loads(self.request['payload']))
        upgrader.backup_metadata = {'binaryPath': '/x', 'units': ['x-ui.service'], 'dbPath': '/db',
                                    'probeBefore': {'vless:443': True}}
        with patch.object(ComponentUpgrader, 'rollback') as rollback, \
             patch('component_upgrade._units_settled', return_value=True), \
             patch('component_upgrade.probe_component', return_value={'vless:443': False}):
            _late_rollback(upgrader)
        self.assertEqual([c.kwargs for c in rollback.call_args_list], [{'restore_data': False}, {'restore_data': True, 'force': True}])

    def test_expiry_waits_for_a_running_job(self):
        from component_upgrade import _wait_for_idle
        other = 'd' * 32
        self.store.db.execute('INSERT INTO jobs VALUES (?,?,?,6,0,0,?)', (other, json.dumps({**self.request, 'id': other}), 'running', time.time()))
        self.store.db.commit()
        self.store.heartbeat()  # A live worker runs the other job.
        clock = iter([0, 0, 10, 200])
        with patch('component_upgrade.time.monotonic', side_effect=lambda: next(clock)), \
             patch('component_upgrade.time.sleep') as sleep:
            self.assertFalse(_wait_for_idle(self.store, self.job_id))
        self.assertTrue(sleep.called)


class InstallerChosenReleaseTests(unittest.TestCase):
    """Newer TrustTunnel/AmneziaWG releases through the AntiRKN installer."""

    COMMIT = 'c' * 40

    def awg(self, **change):
        choice = {'version': '3.1.20261116', 'commit': self.COMMIT,
                  'archive': {'url': 'https://codeload.github.com/amnezia-vpn/amneziawg-go/tar.gz/' + self.COMMIT,
                              'bytes': 133000, 'sha256': 'd' * 64}}
        choice.update(change)
        return json.dumps(choice)

    def test_chosen_awg_release_replaces_only_version_and_source(self):
        from components import release_for, release_hash, RELEASES
        release = release_for('amneziawg', self.awg())
        pinned = RELEASES['amneziawg']
        self.assertEqual(release['version'], '3.1.20261116')
        self.assertEqual(release['commit'], self.COMMIT)
        self.assertEqual(release['archives']['source']['sha256'], 'd' * 64)
        self.assertEqual(release['archives']['tools'], pinned['archives']['tools'])
        self.assertEqual(release['archives']['go'], pinned['archives']['go'])
        self.assertEqual(release['toolsVersion'], pinned['toolsVersion'])
        self.assertNotEqual(release_hash('amneziawg', release), release_hash('amneziawg'))
        self.assertIs(release_for('amneziawg', ''), pinned)

    def test_chosen_release_from_elsewhere_is_refused(self):
        from components import release_for, ComponentError
        bad = [
            self.awg(archive={'url': 'https://evil.example/x.tar.gz', 'bytes': 1, 'sha256': 'd' * 64}),
            self.awg(commit='e' * 40),  # URL commit differs from the declared one
            self.awg(version='3.1.0-rc1'),
            self.awg(archive={'url': 'https://codeload.github.com/amnezia-vpn/amneziawg-go/tar.gz/' + self.COMMIT,
                              'bytes': 1, 'sha256': 'not-a-hash'}),
            json.dumps({'version': '1.2.0', 'archive': {'url': 'http://github.com/TrustTunnel/TrustTunnel/releases/download/v1.2.0/trusttunnel-v1.2.0-linux-x86_64.tar.gz', 'bytes': 1, 'sha256': 'd' * 64}}),
        ]
        for i, payload in enumerate(bad):
            component = 'trusttunnel' if i == len(bad) - 1 else 'amneziawg'
            with self.assertRaises(ComponentError, msg=payload):
                release_for(component, payload)
        tt = release_for('trusttunnel', json.dumps({'version': '1.2.0', 'archive': {
            'url': 'https://github.com/TrustTunnel/TrustTunnel/releases/download/v1.2.0/trusttunnel-v1.2.0-linux-x86_64.tar.gz',
            'bytes': 10, 'sha256': 'd' * 64}}))
        self.assertTrue(tt['chosen'])
        self.assertNotIn('files', tt['archives']['endpoint'])

    def test_configuration_accepts_the_pinned_or_a_newer_same_generation_version(self):
        from components import usable, RELEASES
        awg, tt = RELEASES['amneziawg'], RELEASES['trusttunnel']
        self.assertTrue(usable('amneziawg', {'version': awg['version'], 'toolsVersion': awg['toolsVersion']}))
        self.assertTrue(usable('amneziawg', {'version': '3.1.20261116', 'toolsVersion': awg['toolsVersion']}))
        self.assertFalse(usable('amneziawg', {'version': '3.1.20200101', 'toolsVersion': awg['toolsVersion']}))
        self.assertFalse(usable('amneziawg', {'version': '4.0.0', 'toolsVersion': awg['toolsVersion']}))
        self.assertTrue(usable('trusttunnel', {'version': tt['version']}))
        self.assertTrue(usable('trusttunnel', {'version': '1.2.0'}))
        self.assertFalse(usable('trusttunnel', {'version': '1.0.9'}))
        self.assertFalse(usable('trusttunnel', None))

    def test_failed_start_points_back_to_the_previous_version(self):
        import components
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            root = base / 'amneziawg'
            for release in ('a' * 64, 'b' * 64):
                (root / 'versions' / release).mkdir(parents=True)
                (root / 'versions' / release / 'manifest.json').write_text('{}')
            os.symlink('versions/' + 'b' * 64, root / 'current')
            (Path(tmp) / 'state').mkdir()
            store = Store(Path(tmp) / 'state')
            self.addCleanup(store.close)
            request = {'id': 'f' * 32, 'component': 'amneziawg', 'payload': ''}
            with patch.object(components, 'BASE', base):
                installer = components.ComponentInstaller(store, request)
            installer.directory.mkdir(parents=True)
            (installer.directory / 'target.json').write_text('{}')
            plan = {'previous': {'release': 'a' * 64}, 'activeUnits': ['antirkn-awg@awg0.service']}
            with patch('components.subprocess.run') as run:
                self.assertTrue(installer.restore_previous(plan))
            self.assertEqual(os.readlink(root / 'current'), 'versions/' + 'a' * 64)
            self.assertFalse((installer.directory / 'target.json').exists())
            self.assertEqual(run.call_args.args[0], ['/usr/bin/systemctl', 'restart', 'antirkn-awg@awg0.service'])


class PanelClientRouteTests(unittest.TestCase):
    """Temporary probe clients use the routes the panel actually serves."""

    def test_new_route_first_then_legacy_on_404(self):
        import urllib.error
        from connectivity_probe import client_api
        calls = []

        class Api:
            def __init__(self, missing):
                self.missing = missing

            def call(self, path, body=None):
                calls.append(path)
                if path in self.missing:
                    raise urllib.error.HTTPError(path, 404, 'Not Found', {}, None)
                return {'ok': path}

        self.assertEqual(client_api(Api(set()), '/panel/api/clients/add', {}, '/panel/api/inbounds/addClient', {}),
                         {'ok': '/panel/api/clients/add'})
        self.assertEqual(calls, ['/panel/api/clients/add'])  # 3.7+ incl. 3.11: legacy route never touched
        calls.clear()
        self.assertEqual(client_api(Api({'/panel/api/clients/add'}), '/panel/api/clients/add', {},
                                    '/panel/api/inbounds/addClient', {}), {'ok': '/panel/api/inbounds/addClient'})
        self.assertEqual(calls, ['/panel/api/clients/add', '/panel/api/inbounds/addClient'])


class RequestContractTests(unittest.TestCase):
    def test_every_declared_action_is_accepted(self):
        """An action listed with its fields but missing from the enum is rejected as invalid."""
        from contract import SCHEMA, validate_request
        spec = SCHEMA['request']
        self.assertEqual([a for a in spec['actions'] if a not in spec['properties']['action']['enum']], [])
        validate_request({'version': 1, 'action': 'component_upgrade_confirm', 'id': 'a' * 32})


class PreviousVersionSnapshotTests(unittest.TestCase):
    """Going back is only possible to the version that ran before, from its snapshot."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.store = Store(self.temp_dir.name)
        self.addCleanup(self.temp_dir.cleanup)
        self.addCleanup(self.store.close)
        self.root = Path(self.temp_dir.name)

    def _job(self, job_id, component, meta, files):
        request = {'version': 1, 'action': 'submit', 'id': job_id, 'kind': 'component_upgrade_apply', 'count': 6,
                   'interval': 1, 'payload': json.dumps({'component': component, 'version': 'new'}), 'fingerprint': 'b' * 64}
        self.store.db.execute('INSERT INTO jobs VALUES (?,?,?,6,6,0,?)', (job_id, json.dumps(request), 'succeeded', time.time()))
        self.store.db.commit()
        backup = self.root / ('upgrade-' + job_id) / 'backup'
        for name, data in files.items():
            (backup / name).parent.mkdir(parents=True, exist_ok=True)
            (backup / name).write_bytes(data)
        (backup / 'meta.json').write_text(json.dumps(meta))
        from component_upgrade import arm_deadman
        with patch('component_upgrade.subprocess.run'):
            arm_deadman(self.store, request)
        return request

    def test_confirmed_panel_upgrade_keeps_programs_not_data(self):
        from component_upgrade import confirm_upgrade, snapshot_info, snapshot_archive
        meta = {'binaryPath': '/usr/local/x-ui/x-ui', 'version': '3.7.0', 'xrayVersion': '26.7.28',
                'extraFiles': [{'path': '/usr/local/x-ui/bin/xray-linux-amd64', 'mode': 493},
                               {'path': '/usr/local/x-ui/x-ui.sh', 'mode': 493}]}
        self._job('e' * 32, 'panel', meta, {'x-ui': b'old-panel', 'extra/xray-linux-amd64': b'old-xray',
                                             'extra/x-ui.sh': b'#!/bin/sh', 'db_backup.sqlite': b'db', 'config_backup': b'cfg'})
        with patch('component_upgrade.subprocess.run'):
            confirm_upgrade(self.store, 'e' * 32)
        self.assertEqual(snapshot_info(self.root, 'panel'), {'version': '3.7.0', 'xrayVersion': '26.7.28'})
        snap = self.root / 'snapshots' / 'panel'
        self.assertFalse((snap / 'db_backup.sqlite').exists())
        self.assertFalse((snap / 'config_backup').exists())
        archive = self.root / 'restore.tar.gz'
        snapshot_archive(self.root, 'panel', '3.7.0', archive)
        with tarfile.open(archive) as tar:
            self.assertEqual(sorted(tar.getnames()), ['bin/xray-linux-amd64', 'x-ui', 'x-ui.sh'])
            self.assertEqual(tar.extractfile('x-ui').read(), b'old-panel')
        with self.assertRaises(ComponentUpgradeError):
            snapshot_archive(self.root, 'panel', '3.8.0', archive)

    def test_newer_snapshot_replaces_older(self):
        from component_upgrade import confirm_upgrade, snapshot_info
        for job_id, version in (('1' * 32, '26.7.28'), ('2' * 32, '26.10.21')):
            self._job(job_id, 'xray', {'binaryPath': '/usr/local/x-ui/bin/xray-linux-amd64', 'version': version},
                      {'xray-linux-amd64': version.encode()})
            with patch('component_upgrade.subprocess.run'):
                confirm_upgrade(self.store, job_id)
        self.assertEqual(snapshot_info(self.root, 'xray'), {'version': '26.10.21'})
        self.assertEqual(sorted(p.name for p in (self.root / 'snapshots').iterdir()), ['xray'])

    def test_rolled_back_upgrade_leaves_no_snapshot(self):
        from component_upgrade import fire_deadman, snapshot_info
        self._job('3' * 32, 'xray', {'binaryPath': '/x/xray-linux-amd64', 'version': '26.10.21'}, {'xray-linux-amd64': b'x'})
        with patch('component_upgrade._late_rollback'), patch('component_upgrade.sync_installed_versions'):
            fire_deadman(self.store, '3' * 32, wait=False)
        self.assertIsNone(snapshot_info(self.root, 'xray'))

    def test_startup_sweeps_leftovers_of_finished_upgrades_only(self):
        from component_upgrade import sweep_finished_upgrades
        for job_id, status in (('6' * 32, 'succeeded'), ('7' * 32, 'needs_attention')):
            self.store.db.execute('INSERT INTO jobs VALUES (?,?,?,6,6,0,?)', (job_id, '{}', status, time.time()))
            for name in ('backup/meta.json', 'staging/x', 'release_archive'):
                (self.root / ('upgrade-' + job_id) / name).parent.mkdir(parents=True, exist_ok=True)
                (self.root / ('upgrade-' + job_id) / name).write_text('{}')
        self.store.db.commit()
        sweep_finished_upgrades(self.store)
        self.assertEqual(list((self.root / ('upgrade-' + '6' * 32)).iterdir()), [])
        self.assertTrue((self.root / ('upgrade-' + '7' * 32) / 'backup' / 'meta.json').exists())

    def test_finished_installs_keep_records_and_drop_build_trees(self):
        from runner import slim_finished_jobs
        done, running = '8' * 32, '9' * 32
        for job_id, status in ((done, 'succeeded'), (running, 'running')):
            self.store.db.execute('INSERT INTO jobs VALUES (?,?,?,6,3,0,?)', (job_id, '{}', status, time.time()))
            for name in ('plan.json', 'go/bin/go', 'go-cache/x', 'source.archive'):
                (self.root / ('component-' + job_id) / name).parent.mkdir(parents=True, exist_ok=True)
                (self.root / ('component-' + job_id) / name).write_text('x')
        (self.root / ('panel-' + done)).mkdir()
        (self.root / ('panel-' + done) / 'ownership.json').write_text('{}')
        (self.root / ('panel-' + done) / 'release.tar.gz').write_text('x')
        self.store.db.commit()
        slim_finished_jobs(self.store)
        self.assertEqual(sorted(p.name for p in (self.root / ('component-' + done)).iterdir()), ['plan.json'])
        self.assertEqual(sorted(p.name for p in (self.root / ('panel-' + done)).iterdir()), ['ownership.json'])
        self.assertTrue((self.root / ('component-' + running) / 'go' / 'bin' / 'go').exists())

    def test_backup_of_an_older_runner_becomes_the_previous_version(self):
        """A server broken by an update made with the old runner keeps its way back."""
        from component_upgrade import sweep_finished_upgrades, snapshot_info
        for job_id, created, version in (('a1' * 16, 100.0, '3.6.0'), ('b2' * 16, 200.0, '3.7.0')):
            request = {'kind': 'component_upgrade_apply', 'payload': json.dumps({'component': 'panel', 'version': '3.11.0'})}
            self.store.db.execute('INSERT INTO jobs VALUES (?,?,?,6,6,0,?)', (job_id, json.dumps(request), 'succeeded', created))
            backup = self.root / ('upgrade-' + job_id) / 'backup'
            (backup / 'extra').mkdir(parents=True)
            (backup / 'meta.json').write_text(json.dumps({'binaryPath': '/usr/local/x-ui/x-ui'}))  # no version: old runner
            for path, text in ((backup / 'x-ui', version), (backup / 'extra' / 'xray-linux-amd64', 'Xray 26.7.28 (Xray, Penetrates Everything.)')):
                path.write_text('#!/bin/sh\necho "%s"\n' % text)
                path.chmod(0o755)
            (self.root / ('upgrade-' + job_id) / 'release_archive').write_text('x')
        self.store.db.commit()
        sweep_finished_upgrades(self.store)
        self.assertEqual(snapshot_info(self.root, 'panel'), {'version': '3.7.0', 'xrayVersion': '26.7.28'})
        for job_id in ('a1' * 16, 'b2' * 16):
            self.assertEqual(list((self.root / ('upgrade-' + job_id)).iterdir()), [])

    def test_a_new_upgrade_confirms_an_open_window(self):
        from component_upgrade import ComponentUpgradeJob, window_open
        self._job('4' * 32, 'xray', {'binaryPath': '/x/xray-linux-amd64', 'version': '26.10.21'}, {'xray-linux-amd64': b'x'})
        request = {'version': 1, 'action': 'submit', 'id': '5' * 32, 'kind': 'component_upgrade_apply', 'count': 6,
                   'interval': 1, 'payload': json.dumps({'component': 'xray', 'version': '26.11.9'}), 'fingerprint': 'f' * 64}
        self.store.db.execute('INSERT INTO jobs VALUES (?,?,?,6,0,0,?)', ('5' * 32, json.dumps(request), 'running', time.time()))
        self.store.db.commit()
        with patch('component_upgrade.subprocess.run'), \
             patch.object(ComponentUpgrader, 'pre_check'), \
             patch('component_upgrade.plan', return_value={'fingerprint': 'f' * 64}):
            ComponentUpgradeJob(self.store, request).step(0)
        self.assertFalse(window_open(self.root, '4' * 32))


class OwnedPanelVersionSelfHealTests(unittest.TestCase):
    def test_panel_access_records_installed_versions_after_an_upgrade(self):
        import runner as runner_module
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        store = Store(temp.name); self.addCleanup(store.close)
        panel_id = 'c' * 32
        install = {'version': 1, 'action': 'submit', 'id': panel_id, 'kind': 'panel_install', 'count': 6, 'interval': 1, 'port': 20530, 'fingerprint': 'd' * 64}
        store.db.execute('INSERT INTO jobs VALUES (?,?,?,6,0,0,?)', (panel_id, json.dumps(install), 'succeeded', time.time())); store.db.commit()
        db_dir = Path(temp.name) / 'etc_x_ui'; db_dir.mkdir()
        (db_dir / '.antirkn-owner').write_text(panel_id)
        (db_dir / '.antirkn-versions').write_text(json.dumps({'id': panel_id, 'panelVersion': '3.7.0', 'xrayVersion': '26.7.28'}))
        key = Path(temp.name) / 'panel.key'; key.write_bytes(b'k' * 32)
        with patch('panel.DATABASE', db_dir), patch('panel.KEY', key), patch('panel.safe_file'), \
             patch('component_upgrade.safe_file'), \
             patch('panel_discovery.external_access', return_value=None), \
             patch('runner.external_access', return_value=None), \
             patch.object(runner_module.PanelInstaller, 'owns', return_value=True), \
             patch.object(runner_module.PanelInstaller, 'assert_owned'), \
             patch('component_upgrade.installed_panel_versions', return_value={'panelVersion': '3.11.0', 'xrayVersion': '26.10.21'}):
            response = store.request({'version': 1, 'action': 'panel_access', 'id': panel_id})
        self.assertEqual(response['code'], 'ok')
        self.assertEqual(response['panelAccess']['panelVersion'], '3.11.0')
        self.assertEqual(response['panelAccess']['xrayVersion'], '26.10.21')
