import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
import signal
from unittest.mock import patch, Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
import components
from components import ComponentInstaller, ComponentError, extract
from contract import validate_request
from runner import Store


def request():
    return dict(version=1, action='submit', kind='component_install', component='trusttunnel',
        id='e'*32, count=6, interval=1, fingerprint='a'*64)


class ComponentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = Store(self.root)
    def tearDown(self):
        components.BUILD_PROCESSES.clear()
        self.store.close()
        self.temp.cleanup()
    def status(self):
        return self.store.request(dict(version=1,action='status',id=request()['id'],cursor=0))['jobs'][0]
    def test_only_named_pinned_components_can_be_requested(self):
        for delta in ({'component':'../../etc'}, {'url':'https://example.org/script'},
                {'count':5}, {'interval':2}, {'fingerprint':'x'*64}):
            with self.subTest(delta=delta), self.assertRaises(ValueError):
                validate_request({**request(),**delta})
    def test_preflight_drift_has_no_effect(self):
        self.store.request(request())
        with patch('components.component_plan', return_value={'fingerprint':'b'*64}):
            self.store.tick()
        self.assertEqual(self.status()['status'], 'failed')
        self.assertFalse((self.root/('component-'+request()['id'])).exists())
    def test_failed_download_resumes_same_job(self):
        self.store.request(request())
        with patch.object(ComponentInstaller,'step',side_effect=ComponentError('component_download_failed')):
            self.store.tick()
        self.assertEqual(self.status()['status'],'failed')
        result=self.store.request(dict(version=1,action='resume',id=request()['id']))
        self.assertEqual(result['code'],'ok')
        self.assertEqual(result['jobs'][0]['checkpoint'],0)
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],1)
    def test_cancel_after_possible_effect_is_partial(self):
        self.store.request(request())
        directory=self.root/('component-'+request()['id'])
        directory.mkdir()
        (directory/'target.json').write_text('{}')
        self.store.request(dict(version=1,action='cancel',id=request()['id']))
        self.store.tick()
        self.assertEqual(self.status()['status'],'partially_applied')
    def test_recovery_keeps_checkpoint_and_monotonic_events(self):
        self.store.request(request())
        with self.store.db:
            self.store.db.execute("UPDATE jobs SET status='running',checkpoint=4")
        self.store.recover()
        job=self.status()
        self.assertEqual(job['checkpoint'],4)
        self.assertEqual([e['sequence'] for e in job['events']],[1,2])
        self.assertEqual(json.loads(self.store.db.execute('SELECT request FROM jobs').fetchone()[0]),request())
    def test_archive_links_traversal_duplicates_and_expansion_are_refused(self):
        for mode in ('traversal','link','duplicate','size'):
            with self.subTest(mode=mode):
                archive=self.root/(mode+'.tar.gz')
                with tarfile.open(archive,'w:gz') as tar:
                    info=tarfile.TarInfo('../outside' if mode=='traversal' else 'file')
                    info.size=1
                    if mode=='link':
                        info.type=tarfile.SYMTYPE
                        info.linkname='/etc/passwd'
                        info.size=0
                    tar.addfile(info,io.BytesIO(b'x'))
                    if mode=='duplicate': tar.addfile(info,io.BytesIO(b'x'))
                with self.assertRaises(ComponentError):
                    extract(archive,self.root/mode,'tar',maximum=0 if mode=='size' else 100)
        self.assertFalse((self.root/'outside').exists())

    def test_build_step_non_blocking_yields_when_compiling(self):
        req = dict(version=1, action='submit', kind='component_install', component='amneziawg',
                   id='f'*32, count=6, interval=1, fingerprint='b'*64)
        self.store.request(req)
        directory = self.root / ('component-' + req['id'])
        directory.mkdir()
        (directory / 'plan.json').write_text(json.dumps(dict(fingerprint='b'*64)))
        (directory / '.build_prepared').write_bytes(b'ok')
        (directory / 'output').mkdir()
        source = directory / 'source' / ('amneziawg-go-0000000000000000000000000000000000000000')
        source.mkdir(parents=True)
        (source / 'version.go').write_text('')
        with self.store.db:
            self.store.db.execute("UPDATE jobs SET status='running', checkpoint=2 WHERE id=?", (req['id'],))

        mock_proc = Mock()
        mock_proc.pid = 99999
        mock_proc.poll.return_value = None

        with patch('subprocess.Popen', return_value=mock_proc), \
             patch('components.safe_file'), patch('components.safe_directory'):
            delay = self.store.tick()

        self.assertEqual(delay, 0.5)
        job = self.store.request(dict(version=1, action='status', id=req['id'], cursor=0))['jobs'][0]
        self.assertEqual(job['checkpoint'], 2)
        self.assertEqual(job['status'], 'running')
        self.assertIn(req['id'], components.BUILD_PROCESSES)
        self.assertTrue((directory / 'build_pid.json').exists())

        # When process finishes on next tick, it advances to checkpoint 3 and yields 0.1
        mock_proc.poll.return_value = 0
        with patch.object(ComponentInstaller, 'verify'), patch('components.names', return_value=[]), \
             patch('components.safe_file'), patch('components.safe_directory'):
            delay2 = self.store.tick()

        self.assertEqual(delay2, 0.1)
        job2 = self.store.request(dict(version=1, action='status', id=req['id'], cursor=0))['jobs'][0]
        self.assertEqual(job2['checkpoint'], 3)
        self.assertEqual(job2['status'], 'running')
        self.assertIn('component_built', [e['code'] for e in job2['events']])
        self.assertNotIn(req['id'], components.BUILD_PROCESSES)
        self.assertFalse((directory / 'build_pid.json').exists())

    def test_build_step_fails_when_process_fails(self):
        req = dict(version=1, action='submit', kind='component_install', component='amneziawg',
                   id='f'*32, count=6, interval=1, fingerprint='b'*64)
        self.store.request(req)
        directory = self.root / ('component-' + req['id'])
        directory.mkdir()
        (directory / 'plan.json').write_text(json.dumps(dict(fingerprint='b'*64)))
        (directory / '.build_prepared').write_bytes(b'ok')
        (directory / 'output').mkdir()
        with self.store.db:
            self.store.db.execute("UPDATE jobs SET status='running', checkpoint=2 WHERE id=?", (req['id'],))

        mock_proc = Mock()
        mock_proc.pid = 88888
        mock_proc.poll.return_value = 1
        components.BUILD_PROCESSES[req['id']] = (mock_proc, 9999999999)

        with patch('components.safe_file'), patch('components.safe_directory'):
            delay = self.store.tick()
        self.assertEqual(delay, 0.1)
        job = self.store.request(dict(version=1, action='status', id=req['id'], cursor=0))['jobs'][0]
        self.assertEqual(job['status'], 'failed')
        self.assertIn('component_build_failed', [e['code'] for e in job['events']])
        self.assertNotIn(req['id'], components.BUILD_PROCESSES)

    def test_cancel_during_compilation_terminates_process(self):
        req = dict(version=1, action='submit', kind='component_install', component='amneziawg',
                   id='f'*32, count=6, interval=1, fingerprint='b'*64)
        self.store.request(req)
        directory = self.root / ('component-' + req['id'])
        directory.mkdir()
        (directory / 'plan.json').write_text(json.dumps(dict(fingerprint='b'*64)))
        (directory / '.build_prepared').write_bytes(b'ok')
        (directory / 'output').mkdir()
        (directory / 'build_pid.json').write_text(json.dumps(dict(pid=77777, deadline=9999999999)))
        with self.store.db:
            self.store.db.execute("UPDATE jobs SET status='running', checkpoint=2 WHERE id=?", (req['id'],))

        mock_proc = Mock()
        mock_proc.pid = 77777
        mock_proc.poll.return_value = None
        components.BUILD_PROCESSES[req['id']] = (mock_proc, 9999999999)

        self.store.request(dict(version=1, action='cancel', id=req['id']))

        with patch('os.killpg') as mock_killpg, \
             patch('components.safe_file'), patch('components.safe_directory'):
            delay = self.store.tick()

        mock_killpg.assert_called_with(77777, signal.SIGTERM)
        job = self.store.request(dict(version=1, action='status', id=req['id'], cursor=0))['jobs'][0]
        self.assertEqual(job['status'], 'cancelled')
        self.assertIn('cancelled', [e['code'] for e in job['events']])
        self.assertNotIn(req['id'], components.BUILD_PROCESSES)
        self.assertFalse((directory / 'build_pid.json').exists())


if __name__=='__main__': unittest.main()
