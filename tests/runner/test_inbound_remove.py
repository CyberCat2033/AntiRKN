import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
from runner import Store
from inbound_remove import decode, plan
from vless import VlessError, digest, normal


class Api:
    def __init__(self):
        self.rows = [dict(id=i, remark='External %d' % i, port=10000 + i,
            protocol='vless', enable=True, listen='', settings='{"clients":[]}',
            streamSettings='{}', sniffing='{}') for i in (1, 2, 3)]
        self.effects = []
        self.lose = False

    def call(self, path, data=None):
        if path.endswith('/list'): return copy.deepcopy(self.rows)
        if '/del/' in path:
            ident = int(path.rsplit('/', 1)[1])
            self.rows = [r for r in self.rows if r['id'] != ident]
            self.effects.append(ident)
            if self.lose:
                self.lose = False
                raise OSError('lost response')
        elif path.endswith('/status'): return dict(xray=dict(state='running'))
        elif path.endswith('/restartXrayService'): pass
        else: raise AssertionError(path)


class RemoveTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.store = Store(temp.name)
        self.addCleanup(self.store.close)
        self.api = Api()
        for mock in (patch('inbound_remove.panel_for', return_value=self.api), patch('inbound_remove.safe_file')):
            mock.start(); self.addCleanup(mock.stop)

    def submit(self):
        payload = dict(panelId='b' * 32, removals=[dict(inboundId=r['id'],
            observedHash=digest(normal(r))) for r in self.api.rows[:2]])
        preview = plan(self.store, dict(id='b' * 32, payload=json.dumps(payload)))
        req = dict(version=1, action='submit', id='a' * 32, kind='inbound_remove',
            count=3, interval=1, fingerprint=preview['fingerprint'], payload=json.dumps(payload))
        self.assertEqual(self.store.request(req)['code'], 'ok')
        return req

    def status(self):
        return self.store.request(dict(version=1, action='status', id='a' * 32, cursor=0))['jobs'][0]['status']

    def test_only_selected_rows_removed_and_duplicate_submission_has_no_effect(self):
        req = self.submit()
        self.assertEqual(self.api.effects, [])
        for _ in range(3): self.store.tick()
        self.assertEqual(self.status(), 'succeeded')
        self.assertEqual([r['id'] for r in self.api.rows], [3])
        self.store.request(req); self.store.tick()
        self.assertEqual(self.api.effects, [1, 2])

    def test_lost_reply_resumes_without_deleting_twice(self):
        self.submit(); self.store.tick(); self.api.lose = True; self.store.tick()
        self.assertEqual(self.status(), 'partially_applied')
        self.store.request(dict(version=1, action='resume', id='a' * 32))
        self.store.tick(); self.store.tick()
        self.assertEqual(self.status(), 'succeeded')
        self.assertEqual(self.api.effects, [1, 2])

    def test_reused_id_after_partial_failure_is_not_deleted(self):
        self.submit(); self.store.tick(); self.api.lose = True; self.store.tick()
        reused = copy.deepcopy(self.api.rows[0]); reused.update(id=1, remark='New unrelated inbound')
        self.api.rows.append(reused)
        self.store.request(dict(version=1, action='resume', id='a' * 32)); self.store.tick()
        self.assertEqual(self.status(), 'partially_applied')
        self.assertEqual(self.api.effects, [1])

    def test_drift_before_execution_is_rejected(self):
        self.submit(); self.api.rows[0]['remark'] = 'Changed'; self.store.tick()
        self.assertEqual(self.status(), 'failed')
        self.assertEqual(self.api.effects, [])

    def test_managed_inbound_requires_managed_deletion_path(self):
        self.api.rows[0]['remark'] = 'AntiRKN:owner:resource'
        with self.assertRaises(VlessError): self.submit()

    def test_payload_validation_and_duplicate_ids(self):
        for value in ({}, {'removals': []}, {'removals': [{'inboundId': True, 'observedHash': 'a' * 64}]},
                      {'removals': [{'inboundId': 1, 'observedHash': 'a' * 64}] * 2}):
            with self.assertRaises(VlessError): decode(json.dumps(value))
