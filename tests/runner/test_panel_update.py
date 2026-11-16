import copy
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch, Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
from panel import PanelError
from panel_update import PanelUpdate, plan, UPDATE_RELEASE, object_digest_bytes
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
        self.update.started.write_text('1')
        self.assertEqual(self.update.abort(),'partially_applied')

    def test_corrupt_download_never_unpacks(self):
        archive=self.directory/'bad.tar.gz';archive.write_bytes(b'corrupted')
        with self.assertRaises(PanelError): self.update.unpack(archive)
        self.assertFalse((self.update.directory/'extracted').exists())

    def test_traversal_in_hash_verified_archive_is_rejected(self):
        archive=self.directory/'bad.tar.gz'
        with tarfile.open(archive,'w:gz') as t:
            item=tarfile.TarInfo('x-ui/../../escape');item.size=1;t.addfile(item,io.BytesIO(b'x'))
        self.update.release=dict(UPDATE_RELEASE,sha256=object_digest_bytes(archive.read_bytes()))
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
        self.update.record.write_text(json.dumps(dict(configuration=dict(settings={},inbounds=[{'id':7,'settings':{'clients':[{'id':'secret-client'}]}}]))))
        with patch('panel_update.safe_file'),patch('panel_update.access_for_panel',return_value={}),patch('panel_update.client',return_value=Mock()),patch('panel_update.versions',return_value={k:UPDATE_RELEASE[k] for k in ('panelVersion','xrayVersion')}),patch('panel_update.configuration',return_value=dict(settings={},inbounds=[])),patch('panel_update.atomic_file') as write:
            with self.assertRaises(PanelError):self.update.verify()
        write.assert_not_called()

    def test_semver_parsing_and_prefixes(self):
        from panel_update import semver, version
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
            self.assertEqual(version(v), expected)
        for bad in ('', 'v', 'xyz', '3.x.0', 123, None):
            with self.assertRaises(PanelError):
                semver(bad)

    def test_plan_supported_panel_range_and_current_version_clean(self):
        # Range >= 3.7.0 and <= 3.11.99
        for panel, core, expected in [
            ('3.7.0', '26.7.28', 'update'),
            ('3.8.0', '26.7.28', 'current'),
            ('v3.8.0', 'v26.7.28', 'current'),
            ('3.9.0', '26.7.28', 'update'),
            ('3.11.0', '26.7.28', 'update'),
            ('v3.11.0', '26.7.28', 'update'),
            ('3.11.1', '26.7.28', 'update'),
            ('3.11.99', '26.7.28', 'update'),
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

if __name__=='__main__':unittest.main()
