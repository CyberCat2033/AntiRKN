import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
from runner import Store
from observed_inbounds import wanted, snapshot, plan
from vless import VlessError, normal, digest

class Api:
    def __init__(self):
        self.effects = 0; self.lose = False; self.list_calls = 0
        self.row = dict(id=42, remark='Existing', enable=True, listen='127.0.0.1', port=45678, protocol='vless', up=45, down=50, total=12345,
            settings=json.dumps(dict(clients=[dict(id='private-existing-uuid', email='existing', enable=True)], decryption='none', custom='keep')),
            streamSettings=json.dumps(dict(network='xhttp', security='reality', xhttpSettings=dict(path='/', extraUnknown='keep'), realitySettings=dict(privateKey='private-existing-key', shortIds=['1234']))),
            sniffing='{"enabled":false}', customPanelField='keep')
    def call(self, path, data=None):
        if path.endswith('/list'):
            self.list_calls += 1
            return [copy.deepcopy(self.row)]
        if '/update/' in path:
            self.row = copy.deepcopy(data); self.effects += 1
            if self.lose: self.lose = False; raise OSError('response lost')
        elif path.endswith('/status'): return dict(xray=dict(state='running'))
        elif path.endswith('/restartXrayService'): return None
        else: raise AssertionError(path)

class ObservedTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.store = Store(self.temp.name); self.api = Api()
        self.addCleanup(self.temp.cleanup); self.addCleanup(self.store.close)
        for p in [patch('observed_inbounds.panel_for', return_value=self.api), patch('observed_inbounds.command'), patch('observed_inbounds.safe_file')]:
            p.start(); self.addCleanup(p.stop)
    def submit(self):
        p = dict(inboundId=42, panelId='b'*32, observedHash=digest(normal(self.api.row)), patch=dict(remark='Edited', streamSettings=dict(xhttpSettings=dict(path='/new', headers={'X-Token': 'sensitive-token'}))))
        preview = plan(self.store, dict(id='b'*32, payload=json.dumps(p)))
        r = dict(version=1, action='submit', id='a'*32, kind='inbound_update', count=3, interval=1, fingerprint=preview['fingerprint'], payload=json.dumps(p))
        self.store.request(r); return r
    def job(self): return self.store.request(dict(version=1, action='status', id='a'*32, cursor=0))['jobs'][0]
    def test_view_and_plan_do_not_mutate_or_adopt_and_keep_unknown_fields(self):
        original = copy.deepcopy(self.api.row)
        s = snapshot(self.store, dict(id='b'*32, payload=json.dumps(dict(inboundId=42))))
        self.assertEqual(s['row']['settings'], original['settings'])
        self.submit(); self.assertEqual(self.api.effects, 0)
        for _ in range(3): self.store.tick()
        self.assertEqual(self.job()['status'], 'succeeded')
        self.assertEqual(self.api.row['settings'], original['settings'])
        self.assertEqual(self.api.row['total'], original['total'])
        self.assertEqual(self.api.row['customPanelField'], 'keep')
        stream = json.loads(self.api.row['streamSettings'])
        self.assertEqual(stream['realitySettings']['privateKey'], 'private-existing-key')
        self.assertEqual(stream['realitySettings']['minClientVer'], '0.0.0')
        self.assertEqual(stream['xhttpSettings']['extraUnknown'], 'keep')
        self.assertEqual(stream['xhttpSettings']['path'], '/new')
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM vless_resources').fetchone()[0], 0)
        self.assertNotIn('sensitive-token', self.store.db.execute('SELECT request FROM jobs').fetchone()[0])
        self.assertNotIn('private-existing', json.dumps(self.job()))
    def test_api_object_fields_are_supported_as_well_as_json_strings(self):
        self.api.row['streamSettings'] = json.loads(self.api.row['streamSettings'])
        self.api.row['settings'] = json.loads(self.api.row['settings'])
        self.api.row['sniffing'] = json.loads(self.api.row['sniffing'])
        s = snapshot(self.store, dict(id='b'*32, payload=json.dumps(dict(inboundId=42))))
        self.assertIsInstance(s['row']['streamSettings'], str)
        self.submit()
        for _ in range(3): self.store.tick()
        self.assertEqual(self.job()['status'], 'succeeded')
    def test_manual_drift_between_preview_and_execution_blocks_before_effect(self):
        self.submit(); self.api.row['remark'] = 'Manual change'; self.store.tick()
        self.assertEqual(self.api.effects, 0); self.assertEqual(self.job()['status'], 'failed')
    def test_lost_api_response_resumes_without_duplicate_or_lost_clients(self):
        self.submit(); self.store.tick(); self.api.lose = True; self.store.tick()
        self.assertEqual(self.job()['status'], 'partially_applied')
        self.store.request(dict(version=1, action='resume', id='a'*32))
        self.store.tick(); self.store.tick()
        self.assertEqual(self.job()['status'], 'succeeded'); self.assertEqual(self.api.effects, 1)
    def test_managed_rows_and_client_replacement_are_not_silently_accepted(self):
        with self.assertRaises(VlessError): wanted(self.api.row, dict(settings='{}'))
        self.api.row['remark'] = 'AntiRKN:some-resource'
        with self.assertRaises(VlessError): wanted(self.api.row, dict(remark='new'))
    def test_preflight_and_step_batch_inbounds_list_calls(self):
        from observed_inbounds import read
        p = dict(inboundId=42, panelId='b'*32, observedHash=digest(normal(self.api.row)), patch=dict(remark='Edited'))
        self.api.list_calls = 0
        preview = plan(self.store, dict(id='b'*32, payload=json.dumps(p)))
        # Preflight should only call /list once
        self.assertEqual(self.api.list_calls, 1)
        r = dict(version=1, action='submit', id='a'*32, kind='inbound_update', count=3, interval=1, fingerprint=preview['fingerprint'], payload=json.dumps(p))
        self.store.request(r)
        self.api.list_calls = 0
        self.store.tick()  # checkpoint 0
        # Checkpoint 0 should only call /list once
        self.assertEqual(self.api.list_calls, 1)
    def test_read_with_prefetched_rows_makes_zero_api_calls(self):
        from observed_inbounds import read
        self.api.list_calls = 0
        _, row = read(self.store, 'b'*32, 42, rows=[self.api.row])
        self.assertEqual(row['id'], 42)
        self.assertEqual(self.api.list_calls, 0)
