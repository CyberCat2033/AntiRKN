import copy
import hashlib
import io
import os
import sqlite3
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch, Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
from panel import PanelError
from panel_update import PanelUpdate, plan, UPDATE_RELEASE
from contract import validate_request
from runner import Store


def request():
    return dict(version=1, action='submit', kind='panel_update', id='d'*32,
                panelId='a'*32, count=6, interval=1, fingerprint='b'*64)


class PanelUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.store = Store(self.directory)
        self.update = PanelUpdate(self.store, request())
        self.update.directory.mkdir()
    def tearDown(self):
        self.store.close(); self.temp.cleanup()

    def test_contract_cannot_select_arbitrary_release_or_destination(self):
        for delta in ({'url':'https://invalid'}, {'panelId':'../escape'}, {'count':5}, {'kind':'update_shell'}, {'command':'id'}):
            with self.subTest(delta=delta), self.assertRaises(ValueError):
                validate_request(dict(request(), **delta))

    def test_preview_rejects_newer_core_and_unknown_panel(self):
        for panel, core, expected in [('3.7.0','26.7.28','update'),('3.8.0','26.7.28','current'),('3.8.0','27.1.1','incompatible'),('2.8.0','26.7.28','incompatible')]:
            with patch('panel_update.prerequisites',return_value=[]), patch('panel_update.snapshot',return_value=dict(panelVersion=panel,xrayVersion=core)):
                self.assertEqual(plan(self.store,'a'*32)['state'],expected)
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0],0)

    def test_stale_preview_fails_before_replacing_anything(self):
        self.store.request(request())
        with patch('panel_update.plan',return_value=dict(state='update',supported=True,fingerprint='f'*64)):
            self.store.tick()
        row=self.store.request(dict(version=1,action='status',id=request()['id'],cursor=0))['jobs'][0]
        self.assertEqual(row['status'],'failed')
        self.assertEqual(row['events'][-1]['code'],'panel_conflict')
        self.assertFalse(self.update.started.exists())

    def test_cancel_before_and_after_switch_reports_actual_effect(self):
        self.assertEqual(self.update.abort(),'cancelled')
        self.assertIsNone(self.update.rolled_back)
        self.update.started.write_text('1')
        # After the switch started the old panel is restored and checked.
        with patch.object(PanelUpdate,'restore') as restore:
            self.assertEqual(self.update.abort(),'cancelled')
        restore.assert_called_once_with()
        self.assertTrue(self.update.rolled_back)
        with patch.object(PanelUpdate,'restore',side_effect=PanelError('panel_api_failed')):
            self.assertEqual(self.update.abort(),'needs_attention')
        self.assertFalse(self.update.rolled_back)

    def test_corrupt_download_never_unpacks(self):
        archive=self.directory/'bad.tar.gz';archive.write_bytes(b'corrupted')
        with self.assertRaises(PanelError): self.update.unpack(archive)
        self.assertFalse((self.update.directory/'extracted').exists())

    def test_traversal_in_hash_verified_archive_is_rejected(self):
        archive=self.directory/'bad.tar.gz'
        with tarfile.open(archive,'w:gz') as t:
            item=tarfile.TarInfo('x-ui/../../escape');item.size=1;t.addfile(item,io.BytesIO(b'x'))
        self.update.release=dict(UPDATE_RELEASE,sha256=hashlib.sha256(archive.read_bytes()).hexdigest())
        with self.assertRaises(PanelError): self.update.unpack(archive)
        self.assertFalse((self.directory/'escape').exists())

    def test_resume_refuses_administrator_changes_before_stopping_service(self):
        modified=self.directory/'binary';modified.write_bytes(b'changed outside runner')
        self.update.record.write_text(json.dumps(dict(files={str(modified):'0'*64})))
        self.update.started.write_text('1')
        with patch('panel_update.safe_file'),patch('panel_update.CLI',modified),patch('panel_update.systemctl') as system:
            with self.assertRaises(PanelError):self.update.switch()
        system.assert_not_called()

    def test_verification_detects_lost_client_and_does_not_mark_versions(self):
        self.update.SETTLE_SECONDS = 0
        self.update.record.write_text(json.dumps(dict(configuration=dict(settings={},inbounds=[{'id':7,'settings':{'clients':[{'id':'secret-client'}]}}]))))
        with patch('panel_update.safe_file'),patch('panel_update.access_for_panel',return_value={}),patch('panel_update.client',return_value=Mock()),patch('panel_update.versions',return_value={k:UPDATE_RELEASE[k] for k in ('panelVersion','xrayVersion')}),patch('panel_update.configuration',return_value=dict(settings={},inbounds=[])),patch('panel_update.atomic_file') as write:
            with self.assertRaises(PanelError):self.update.verify()
        write.assert_not_called()

    def test_semver_parsing_and_prefixes(self):
        from panel_update import semver
        for v, expected in [
            ('3.8.0', (3, 8, 0)),
            ('v3.8.0', (3, 8, 0)),
            ('V3.8.0', (3, 8, 0)),
            ('3.11.0', (3, 11, 0)),
            ('v3.11.0', (3, 11, 0)),
            ('3.11.1', (3, 11, 1)),
            ('3.11.99', (3, 11, 99)),
            ('v26.7.28', (26, 7, 28)),
            ('3.8', (3, 8, 0)),
        ]:
            self.assertEqual(semver(v), expected)
        for bad in ('', 'v', 'xyz', '3.x.0', 123, None):
            with self.assertRaises(PanelError):
                semver(bad)

    def test_plan_supported_panel_range_and_current_version_clean(self):
        # Range >= 3.7.0 and <= the target
        for panel, core, expected in [
            ('3.7.0', '26.7.28', 'update'),
            ('3.8.0', '26.7.28', 'current'),
            ('v3.8.0', 'v26.7.28', 'current'),
            # Newer than the 3.8.0 target: never offered as an "update".
            ('3.9.0', '26.7.28', 'incompatible'),
            ('3.11.0', '26.7.28', 'incompatible'),
            ('v3.11.0', '26.7.28', 'incompatible'),
            ('3.11.1', '26.7.28', 'incompatible'),
            ('3.11.99', '26.7.28', 'incompatible'),
            ('3.7.0', '26.1.1', 'update'),
            ('3.6.9', '26.7.28', 'incompatible'),
            ('3.12.0', '26.7.28', 'incompatible'),
        ]:
            with patch('panel_update.prerequisites', return_value=[]), patch('panel_update.snapshot', return_value=dict(panelVersion=panel, xrayVersion=core)):
                p = plan(self.store, 'a'*32)
                self.assertEqual(p['state'], expected, f'panel {panel} core {core} expected {expected}')
                if expected == 'current':
                    self.assertEqual(p['panelId'], 'a'*32)
                    self.assertEqual(p['state'], 'current')
                    self.assertTrue(p['supported'])

    def test_no_downgrade_of_a_newer_panel_or_core(self):
        for panel, core in [('3.9.0', '26.7.28'), ('3.8.1', '26.1.1'), ('3.7.0', '26.7.29'), ('3.11.1', '26.10.21')]:
            with self.subTest(panel=panel, core=core), patch('panel_update.prerequisites', return_value=[]), \
                    patch('panel_update.snapshot', return_value=dict(panelVersion=panel, xrayVersion=core)):
                self.assertNotEqual(plan(self.store, 'a'*32)['state'], 'update')

    def test_verification_tolerates_columns_a_newer_panel_adds(self):
        from panel_update import same_inbounds
        from vless import normal
        before = [normal(dict(id=7, remark='r', enable=True, port=443, protocol='vless', settings={'clients': [{'id': 'x'}]}))]
        self.assertTrue(same_inbounds(before, [dict(before[0], excludeFromSub=False)]))
        self.assertFalse(same_inbounds(before, [dict(before[0], excludeFromSub=True)]))
        self.assertFalse(same_inbounds(before, [dict(before[0], port=8443)]))
        self.assertFalse(same_inbounds(before, []))

    def test_verify_keeps_one_session_and_retries_until_the_panel_is_ready(self):
        target = {k: UPDATE_RELEASE[k] for k in ('panelVersion', 'xrayVersion')}
        self.update.record.write_text(json.dumps(dict(configuration=dict(settings={'a': 1}, inbounds=[]))))
        answers = iter([dict(panelVersion='3.7.0', xrayVersion='26.1.1'), target])
        with patch('panel_update.safe_file'), patch('panel_update.access_for_panel', return_value=dict(port=1)), \
                patch('panel_update.client', return_value=Mock()) as client, \
                patch('panel_update.versions', side_effect=lambda api: next(answers)), \
                patch('panel_update.configuration', return_value=dict(settings={'a': 1, 'new': 2}, inbounds=[])), \
                patch('panel_update.digest', side_effect=lambda path: self.update.target_files[str(path).split('x-ui/', 1)[1]]), \
                patch('panel_update.systemctl'), patch('panel_update.time.sleep'), \
                patch('panel_discovery.external_access', return_value=None), patch('panel_update.atomic_file'):
            self.update.verify()
        self.assertEqual(client.call_count, 1)

    def test_failed_verification_after_switch_restores_and_ends_failed(self):
        self.store.request(request())
        with self.store.db:
            self.store.db.execute("UPDATE jobs SET status='running', checkpoint=5")
        self.update.started.write_text('1')
        with patch.object(PanelUpdate, 'step', side_effect=PanelError('panel_api_failed')), \
                patch.object(PanelUpdate, 'restore') as restore:
            self.store.tick()
        restore.assert_called_once_with()
        job = self.store.request(dict(version=1, action='status', id=request()['id'], cursor=0))['jobs'][0]
        self.assertEqual((job['status'], job['events'][-1]['code']), ('failed', 'upgrade_rolled_back'))

    def test_failed_restore_needs_attention(self):
        self.store.request(request())
        with self.store.db:
            self.store.db.execute("UPDATE jobs SET status='running', checkpoint=5")
        self.update.started.write_text('1')
        with patch.object(PanelUpdate, 'step', side_effect=PanelError('panel_api_failed')), \
                patch.object(PanelUpdate, 'restore', side_effect=OSError('disk')):
            self.store.tick()
        job = self.store.request(dict(version=1, action='status', id=request()['id'], cursor=0))['jobs'][0]
        self.assertEqual((job['status'], job['events'][-1]['code']), ('needs_attention', 'upgrade_rollback_failed'))
        self.assertTrue(self.update.directory.exists())

    def test_success_removes_backups_with_secrets(self):
        self.store.request(request())
        with self.store.db:
            self.store.db.execute("UPDATE jobs SET status='running', checkpoint=5")
        (self.update.directory / 'backup').mkdir()
        (self.update.directory / 'backup' / 'x-ui.db').write_bytes(b'full panel database')
        with patch.object(PanelUpdate, 'step', lambda self, number: self.checkpoint(6, 'panel_check')):
            self.store.tick()
        job = self.store.request(dict(version=1, action='status', id=request()['id'], cursor=0))['jobs'][0]
        self.assertEqual(job['status'], 'succeeded')
        self.assertFalse(self.update.directory.exists())

    def test_interrupted_restore_is_finished_not_the_update(self):
        self.update.rolling_back.write_text('1')
        with self.assertRaises(PanelError):
            self.update.step(5)


class PanelRestoreTests(unittest.TestCase):
    """switch() then restore() on real files and a real SQLite database."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        (root / 'state').mkdir()
        self.store = Store(root / 'state')
        self.panel, self.database, self.cli = root / 'x-ui', root / 'etc-x-ui', root / 'cli'
        (self.panel / 'bin').mkdir(parents=True); self.database.mkdir()
        self.old = {'x-ui': b'old panel', 'x-ui.sh': b'old menu', 'bin/xray-linux-amd64': b'old core'}
        self.new = {'x-ui': b'new panel', 'x-ui.sh': b'new menu', 'bin/xray-linux-amd64': b'new core'}
        for name, data in self.old.items():
            (self.panel / name).write_bytes(data); (self.panel / name).chmod(0o700)
        (self.panel / 'bin/config.json').write_bytes(b'{"old":true}')
        db = sqlite3.connect(str(self.database / 'x-ui.db'))
        db.execute('CREATE TABLE inbounds (id INTEGER, remark TEXT)'); db.execute("INSERT INTO inbounds VALUES (1, 'kept')")
        db.commit(); db.close()
        (self.database / 'x-ui.db').chmod(0o640)
        sha = lambda data: hashlib.sha256(data).hexdigest()
        self.update = PanelUpdate(self.store, request())
        self.update.release = dict(UPDATE_RELEASE, files={n: sha(d) for n, d in self.new.items()},
                                   coreArchive=dict(UPDATE_RELEASE['coreArchive'], files={'bin/xray-linux-amd64': sha(self.new['bin/xray-linux-amd64'])}))
        self.update.directory.mkdir()
        for name, data in self.new.items():
            target = self.update.directory / 'extracted' / name
            target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data)
        files = {str(self.panel / n): sha(d) for n, d in self.old.items()}
        files[str(self.cli)] = None
        self.versions = dict(panelVersion='3.7.0', xrayVersion='26.1.1')
        self.config = dict(settings={'webPort': 2053}, inbounds=[dict(id=1, remark='kept')])
        self.update.record.write_text(json.dumps(dict(files=files, configuration=self.config, **self.versions)))
        backup = self.update.directory / 'backup'; backup.mkdir()
        for index, name in enumerate(files):
            if files[name] is not None:
                (backup / str(index)).write_bytes(Path(name).read_bytes())
        self.patches = [patch('panel_update.PANEL', self.panel), patch('panel_update.DATABASE', self.database),
            patch('panel_update.CLI', self.cli), patch('panel_update.systemctl'), patch('panel_update.time.sleep'),
            patch('panel_update.access_for_panel', return_value={}), patch('panel_update.client', return_value=Mock()),
            patch('panel_update.versions', return_value=self.versions),
            # The old panel answers with a column the newer one had added.
            patch('panel_update.configuration', return_value=dict(settings={'webPort': 2053},
                inbounds=[dict(id=1, remark='kept', excludeFromSub=False)])),
            patch.object(PanelUpdate, 'same_snapshot')]
        for item in self.patches: item.start()

    def tearDown(self):
        for item in self.patches: item.stop()
        self.store.close(); self.temp.cleanup()

    def test_restore_returns_files_database_config_owner_and_mode(self):
        self.update.switch()
        self.assertTrue(self.update.started.exists())
        for name, data in self.new.items():
            self.assertEqual((self.panel / name).read_bytes(), data)
        self.assertEqual(self.cli.read_bytes(), self.new['x-ui.sh'])  # The official menu was installed.
        # The new panel migrates its DB and leaves a journal behind.
        db = sqlite3.connect(str(self.database / 'x-ui.db')); db.execute("UPDATE inbounds SET remark='migrated'"); db.commit(); db.close()
        (self.database / 'x-ui.db-wal').write_bytes(b'journal of the migrated db')
        (self.panel / 'bin/config.json').write_bytes(b'{"new":true}')
        self.update.restore()
        for name, data in self.old.items():
            self.assertEqual((self.panel / name).read_bytes(), data)
            self.assertEqual((self.panel / name).stat().st_mode & 0o777, 0o700)
        self.assertFalse(self.cli.exists())
        self.assertEqual((self.panel / 'bin/config.json').read_bytes(), b'{"old":true}')
        self.assertFalse((self.database / 'x-ui.db-wal').exists())
        self.assertEqual((self.database / 'x-ui.db').stat().st_mode & 0o777, 0o640)
        db = sqlite3.connect(str(self.database / 'x-ui.db'))
        self.assertEqual(db.execute('SELECT remark FROM inbounds').fetchall(), [('kept',)]); db.close()
        # A retry starts from fresh backups; nothing marks a pending switch.
        self.assertFalse(self.update.started.exists())
        self.assertFalse(self.update.rolling_back.exists())
        self.assertFalse((self.update.directory / 'backup' / 'x-ui.db').exists())
        self.assertEqual(self.update.abort(), 'cancelled')

    def test_restore_never_overwrites_an_administrators_change(self):
        self.update.switch()
        (self.panel / 'x-ui').write_bytes(b'administrator build')
        self.update.SETTLE_SECONDS = 0
        self.assertEqual(self.update.abort(), 'needs_attention')
        self.assertEqual((self.panel / 'x-ui').read_bytes(), b'administrator build')

    def test_restore_that_cannot_be_confirmed_needs_attention(self):
        self.update.switch()
        self.update.SETTLE_SECONDS = 0
        with patch('panel_update.versions', return_value=dict(panelVersion='3.8.0', xrayVersion='26.7.28')):
            self.assertEqual(self.update.abort(), 'needs_attention')
        self.assertTrue(self.update.rolling_back.exists())
        # The worker resumes the restore, never the update.
        with self.assertRaises(PanelError):
            self.update.step(5)


if __name__=='__main__':unittest.main()
