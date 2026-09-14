import json
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
    def request(self, kind='apt_update', number=1):
        r = dict(version=1, action='submit', id=f'{number:032x}', kind=kind, count=2, interval=1)
        if kind == 'apt_upgrade': r['fingerprint'] = 'a' * 64
        return r
    def result(self, r):
        return self.store.request(dict(version=1, action='status', id=r['id'], cursor=0))['jobs'][0]
    def test_parse_rejects_removals_new_dependencies_and_unsafe_names(self):
        self.assertEqual(parse_packages(OUTPUT), [dict(name='fixture', installed='1.0', version='2.0')])
        for output in ['Remv fixture [1.0]', 'Inst new-package (1.0 local [amd64])', 'Inst bad;id [1] (2 local)']:
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
    def test_interrupted_command_is_not_replayed_after_worker_recovery(self):
        r = self.request(); self.store.request(r)
        (Path(self.temp.name) / ('apt-' + r['id'] + '.started')).write_text('started')
        self.store.recover()
        with patch('apt.run') as run:
            self.store.tick(); run.assert_not_called()
        self.assertEqual(self.result(r)['status'], 'partially_applied')
        self.assertEqual(self.result(r)['events'][-1]['code'], 'apt_interrupted')
