import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
from contract import validate_request
from runner import Store
from panel import PanelInstaller, PanelError, access_for


def request():
    return dict(version=1, action='submit', kind='panel_install', id='1' * 32,
                count=6, interval=1, port=2053, fingerprint='a' * 64)


class PanelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = Store(self.root)
    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def status(self):
        return self.store.request(dict(version=1, action='status', id=request()['id'], cursor=0))['jobs'][0]

    def test_component_contract_rejects_arbitrary_code_url_and_wrong_steps(self):
        for delta in ({'kind':'shell'}, {'port':True}, {'port':22}, {'url':'http://invalid'},
                      {'count':7}, {'interval':2}, {'fingerprint':'../file'}):
            with self.subTest(delta=delta), self.assertRaises(ValueError):
                validate_request({**request(), **delta})

    def test_preflight_refusal_has_no_component_effect(self):
        self.store.request(request())
        with patch('panel.prerequisites', return_value=['disk_space']):
            self.store.tick()
        job = self.status()
        self.assertEqual(job['status'], 'failed')
        self.assertEqual(job['events'][-1]['code'], 'panel_prerequisites')
        self.assertFalse((self.root / ('panel-' + request()['id'])).exists())

    def test_download_failure_remains_retryable_with_same_identity(self):
        self.store.request(request())
        with patch.object(PanelInstaller, 'step', side_effect=PanelError('panel_download_failed')):
            self.store.tick()
        self.assertEqual(self.status()['status'], 'failed')
        result = self.store.request(dict(version=1, action='resume', id=request()['id']))
        self.assertEqual(result['code'], 'ok')
        self.assertEqual(self.status()['checkpoint'], 0)
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0], 1)

    def test_cancel_after_effect_is_partial_not_rollback(self):
        self.store.request(request())
        self.store.request(dict(version=1, action='cancel', id=request()['id']))
        with patch.object(PanelInstaller, 'abort', return_value='partially_applied'):
            self.store.tick()
        self.assertEqual(self.status()['status'], 'partially_applied')
        self.assertEqual(self.status()['events'][-1]['code'], 'panel_cancelled_partial')

    def test_crash_and_resume_preserve_checkpoint_and_request(self):
        self.store.request(request())
        with self.store.db:
            self.store.db.execute("UPDATE jobs SET checkpoint=3,status='running'")
        self.store.recover()
        def step(installer, checkpoint):
            self.assertEqual(checkpoint, 3)
            installer.checkpoint(4, 'panel_configure')
        with patch.object(PanelInstaller, 'step', step):
            self.store.tick()
        self.assertEqual(self.status()['checkpoint'], 4)
        self.assertEqual(self.status()['kind'], 'panel_install')
        self.assertEqual(self.store.request(request())['code'], 'ok')

    def test_archive_traversal_and_links_never_reach_destinations(self):
        for name, kind in [('x-ui/../../escape', tarfile.REGTYPE), ('x-ui/x-ui', tarfile.SYMTYPE)]:
            with self.subTest(name=name):
                installer = PanelInstaller(self.store, request())
                installer.directory.mkdir(exist_ok=True)
                archive = self.root / 'bad.tar.gz'
                with tarfile.open(archive, 'w:gz') as stream:
                    item = tarfile.TarInfo(name); item.type = kind
                    if kind == tarfile.SYMTYPE: item.linkname = '/etc/passwd'
                    stream.addfile(item, io.BytesIO(b''))
                with self.assertRaises(PanelError): installer.extract(archive)
                self.assertFalse(installer.ownership.exists())

    def test_generated_credentials_are_stable_and_absent_from_job_records(self):
        key = self.root / 'key'; key.write_bytes(bytes(range(32)))
        self.store.request(request())
        with patch('panel.KEY', key), patch('panel.safe_file'):
            access = access_for(request()['id'], 2053)
            again = access_for(request()['id'], 2053)
        self.assertEqual(access, again)
        self.assertEqual(len(access['password']), 43)
        row = self.store.db.execute('SELECT request FROM jobs').fetchone()[0]
        self.assertNotIn(access['password'], row + json.dumps(self.status()))

    def test_access_not_returned_before_verified_completion(self):
        self.store.request(request())
        result = self.store.request(dict(version=1, action='panel_access', id=request()['id']))
        self.assertEqual(result['code'], 'missing')
        self.assertNotIn('panelAccess', result)


if __name__ == '__main__': unittest.main()
