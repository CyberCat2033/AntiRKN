import concurrent.futures
import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
from contract import validate_request, SCHEMA
from runner import Store, strict_json


def submit(number=1, count=3):
    return dict(version=1, action='submit', id=f'{number:032x}', kind='diagnostic', count=count, interval=1)


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.store = Store(self.directory)
    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def test_strict_request_contract(self):
        req = submit()
        for invalid in ({**req, 'id': '../../etc/passwd'}, {**req, 'count': True}, {**req, 'count': 61}, {**req, 'interval': 0}, {**req, 'shell': 'id'}, {**req, 'kind': 'shell'}, {**req, 'version': 2}):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                validate_request(invalid)
        with self.assertRaises(ValueError):
            strict_json('{"version":1,"version":2}')
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0], 0)

    def test_any_verified_predecessor_is_upgradeable(self):
        path = Path(__file__).resolve().parents[2] / 'server/runner/inspect.py'
        spec = importlib.util.spec_from_file_location('runner_inspector_fixture', path)
        inspector = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(inspector)
        predecessors = [
            {'release': 'a' * 64, 'hashes': {'antirkn-runner.service': 'unit-a'}},
            {'release': 'b' * 64, 'hashes': {'antirkn-runner.service': 'unit-b'}},
        ]
        self.assertEqual(inspector.predecessor_for_unit(predecessors, 'unit-a'), predecessors[0])
        self.assertIsNone(inspector.predecessor_for_unit(predecessors, 'unknown'))

    def test_v29_predecessor_manifests_valid(self):
        schema_path = Path(__file__).resolve().parents[2] / 'schemas/runner-predecessor-v29.json'
        manifests = json.loads(schema_path.read_text())
        self.assertIsInstance(manifests, list)
        self.assertEqual(len(manifests), 3)
        for m in manifests:
            self.assertIn('release', m)
            self.assertIn('hashes', m)
            self.assertEqual(len(m['release']), 64)
            expected = hashlib.sha256(json.dumps(m['hashes'], sort_keys=True).encode()).hexdigest()
            self.assertEqual(m['release'], expected)
            self.assertIn('antirkn-runner.service', m['hashes'])
            self.assertIn('runner.py', m['hashes'])

    def test_v30_predecessor_manifests_valid(self):
        schema_path = Path(__file__).resolve().parents[2] / 'schemas/runner-predecessor-v30.json'
        manifests = json.loads(schema_path.read_text())
        self.assertIsInstance(manifests, list)
        self.assertEqual(len(manifests), 1)
        for m in manifests:
            self.assertIn('release', m)
            self.assertIn('hashes', m)
            self.assertEqual(len(m['release']), 64)
            expected = hashlib.sha256(json.dumps(m['hashes'], sort_keys=True).encode()).hexdigest()
            self.assertEqual(m['release'], expected)
            self.assertIn('antirkn-runner.service', m['hashes'])
            self.assertIn('runner.py', m['hashes'])

    def test_v31_predecessor_manifests_valid(self):
        schema_path = Path(__file__).resolve().parents[2] / 'schemas/runner-predecessor-v31.json'
        manifests = json.loads(schema_path.read_text())
        self.assertIsInstance(manifests, list)
        self.assertEqual(len(manifests), 2)
        for m in manifests:
            self.assertIn('release', m)
            self.assertIn('hashes', m)
            self.assertEqual(len(m['release']), 64)
            expected = hashlib.sha256(json.dumps(m['hashes'], sort_keys=True).encode()).hexdigest()
            self.assertEqual(m['release'], expected)
            self.assertIn('antirkn-runner.service', m['hashes'])
            self.assertIn('runner.py', m['hashes'])

    def test_v32_predecessor_manifests_valid(self):
        schema_path = Path(__file__).resolve().parents[2] / 'schemas/runner-predecessor-v32.json'
        manifests = json.loads(schema_path.read_text())
        self.assertIsInstance(manifests, list)
        self.assertEqual(len(manifests), 1)
        for m in manifests:
            self.assertIn('release', m)
            self.assertIn('hashes', m)
            self.assertEqual(len(m['release']), 64)
            expected = hashlib.sha256(json.dumps(m['hashes'], sort_keys=True).encode()).hexdigest()
            self.assertEqual(m['release'], expected)
            self.assertIn('antirkn-runner.service', m['hashes'])
            self.assertIn('runner.py', m['hashes'])

    def test_v33_predecessor_manifests_valid(self):
        schema_path = Path(__file__).resolve().parents[2] / 'schemas/runner-predecessor-v33.json'
        manifests = json.loads(schema_path.read_text())
        self.assertIsInstance(manifests, list)
        self.assertEqual(len(manifests), 1)
        for m in manifests:
            self.assertIn('release', m)
            self.assertIn('hashes', m)
            self.assertEqual(len(m['release']), 64)
            expected = hashlib.sha256(json.dumps(m['hashes'], sort_keys=True).encode()).hexdigest()
            self.assertEqual(m['release'], expected)
            self.assertIn('antirkn-runner.service', m['hashes'])
            self.assertIn('runner.py', m['hashes'])

    def test_v34_predecessor_manifests_valid(self):
        schema_path = Path(__file__).resolve().parents[2] / 'schemas/runner-predecessor-v34.json'
        manifests = json.loads(schema_path.read_text())
        self.assertIsInstance(manifests, list)
        self.assertEqual(len(manifests), 1)
        for m in manifests:
            self.assertIn('release', m)
            self.assertIn('hashes', m)
            self.assertEqual(len(m['release']), 64)
            expected = hashlib.sha256(json.dumps(m['hashes'], sort_keys=True).encode()).hexdigest()
            self.assertEqual(m['release'], expected)
            self.assertIn('antirkn-runner.service', m['hashes'])
            self.assertIn('runner.py', m['hashes'])

    def test_v35_predecessor_manifests_valid(self):
        schema_path = Path(__file__).resolve().parents[2] / 'schemas/runner-predecessor-v35.json'
        manifests = json.loads(schema_path.read_text())
        self.assertIsInstance(manifests, list)
        self.assertEqual(len(manifests), 1)
        for m in manifests:
            self.assertIn('release', m)
            self.assertIn('hashes', m)
            self.assertEqual(len(m['release']), 64)
            expected = hashlib.sha256(json.dumps(m['hashes'], sort_keys=True).encode()).hexdigest()
            self.assertEqual(m['release'], expected)
            self.assertIn('antirkn-runner.service', m['hashes'])
            self.assertIn('runner.py', m['hashes'])

    def test_v36_predecessor_manifests_valid(self):
        schema_path = Path(__file__).resolve().parents[2] / 'schemas/runner-predecessor-v36.json'
        manifests = json.loads(schema_path.read_text())
        self.assertIsInstance(manifests, list)
        self.assertEqual(len(manifests), 1)
        for m in manifests:
            self.assertIn('release', m)
            self.assertIn('hashes', m)
            self.assertEqual(len(m['release']), 64)
            expected = hashlib.sha256(json.dumps(m['hashes'], sort_keys=True).encode()).hexdigest()
            self.assertEqual(m['release'], expected)
            self.assertIn('antirkn-runner.service', m['hashes'])
            self.assertIn('runner.py', m['hashes'])

    def test_v38_predecessor_manifests_valid(self):
        schema_path = Path(__file__).resolve().parents[2] / 'schemas/runner-predecessor-v38.json'
        manifests = json.loads(schema_path.read_text())
        self.assertEqual(len(manifests), 7)
        self.assertEqual(len({m['release'] for m in manifests}), len(manifests))
        for manifest in manifests:
            hashes = manifest['hashes']
            self.assertEqual(
                manifest['release'],
                hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest(),
            )
            self.assertIn('antirkn-runner.service', hashes)
            self.assertIn('runner.py', hashes)

    def test_protocol_remove_plan_action(self):
        with patch('runner.protocol_removal_plan', return_value={'test': 123}) as mock_plan:
            res = self.store.request(dict(version=1, action='protocol_remove_plan', protocol='vless'))
            self.assertEqual(res['code'], 'ok')
            self.assertEqual(res['removalPlan'], {'test': 123})
            mock_plan.assert_called_once_with('vless')



    def test_repeat_and_conflicting_request_identity(self):
        req = submit()
        first = self.store.request(req)
        self.store.tick()
        second = self.store.request(req)
        self.assertEqual(second['jobs'][0]['checkpoint'], 1)
        self.assertEqual(len(self.store.request(dict(version=1, action='list'))['jobs']), 1)
        self.assertEqual(self.store.request({**req, 'count': 4})['code'], 'conflict')
        self.assertGreater(second['jobs'][0]['sequence'], first['jobs'][0]['sequence'])

    def test_two_connections_admit_one_job(self):
        def request(number):
            store = Store(self.directory)
            try: return store.request(submit(number))['code']
            finally: store.close()
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            self.assertEqual(sorted(pool.map(request, [1,2])), ['busy', 'ok'])

    def test_two_devices_retry_same_id_create_one_job_and_one_event(self):
        def request(_):
            store = Store(self.directory)
            try:
                return store.request(submit())['code']
            finally:
                store.close()
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            self.assertEqual(list(pool.map(request, range(2))), ['ok', 'ok'])
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0], 1)
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM events').fetchone()[0], 1)
        self.store.tick()
        second = Store(self.directory)
        try:
            observed = second.request(dict(version=1, action='status', id=submit()['id'], cursor=0))
            repeated = second.request(submit())
            self.assertEqual(observed['jobs'], repeated['jobs'])
            self.assertEqual(observed['jobs'][0]['checkpoint'], 1)
        finally:
            second.close()

    def test_cancel_and_replay_terminal(self):
        req = submit()
        self.store.request(req)
        cancel = dict(version=1, action='cancel', id=req['id'])
        self.store.request(cancel)
        self.store.request(cancel)
        self.store.tick()
        result = self.store.request(req)['jobs'][0]
        self.assertEqual(result['status'], 'cancelled')
        self.assertEqual(result['checkpoint'], 0)
        self.assertEqual([e['code'] for e in result['events']].count('cancel_requested'), 1)
        self.assertEqual(self.store.request(cancel)['jobs'][0]['sequence'], result['sequence'])

    def test_restart_resumes_checkpoint_and_events(self):
        req = submit()
        self.store.request(req)
        self.store.tick()
        checkpoint = self.store.request(req)['jobs'][0]['checkpoint']
        self.store.close()
        self.store = Store(self.directory)
        self.store.recover()
        self.store.tick(); self.store.tick()
        result = self.store.request(req)['jobs'][0]
        self.assertEqual(result['status'], 'succeeded')
        self.assertEqual(result['checkpoint'], 3)
        self.assertIn('recovered', [e['code'] for e in result['events']])
        self.assertEqual(checkpoint, 1)
        sequences = [e['sequence'] for e in result['events']]
        self.assertEqual(sequences, list(range(1, result['sequence'] + 1)))

    def test_failed_event_write_rolls_back_submission(self):
        self.store.db.execute("CREATE TRIGGER fail_event BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'fixture disk failure'); END")
        with self.assertRaises(sqlite3.Error): self.store.request(submit())
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0], 0)
        self.store.db.execute('DROP TRIGGER fail_event')
        self.assertEqual(self.store.request(submit())['code'], 'ok')

    def test_checkpoint_and_event_are_atomic_on_disk_error(self):
        req = submit()
        self.store.request(req); self.store.tick()
        previous = self.store.request(req)['jobs'][0]
        self.store.db.execute("CREATE TRIGGER fail_event BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'fixture'); END")
        with self.assertRaises(sqlite3.Error): self.store.tick()
        self.store.db.execute('DROP TRIGGER fail_event')
        current = self.store.request(req)['jobs'][0]
        self.assertEqual(current, previous)

    def test_event_cursor_and_rotation(self):
        req = submit()
        self.store.request(req)
        with self.store.db:
            for _ in range(SCHEMA['maxEvents'] + 10): self.store.event(req['id'], 'recovered', 0, req['count'])
        job = self.store.request(dict(version=1, action='status', id=req['id'], cursor=0))['jobs'][0]
        self.assertEqual(len(job['events']), SCHEMA['maxEvents'])
        self.assertGreater(job['events'][0]['sequence'], 1)
        self.assertEqual(self.store.request(dict(version=1, action='status', id=req['id'], cursor=job['sequence']))['jobs'][0]['events'], [])

    def test_missing_requests_do_not_create_jobs(self):
        for action in ['status', 'cancel']:
            req = dict(version=1, action=action, id=submit()['id'])
            if action == 'status': req['cursor'] = 0
            self.assertEqual(self.store.request(req)['code'], 'missing')
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0], 0)

    def test_probe_failure_is_terminal_with_saved_result(self):
        req = submit()
        self.store.request(req)
        with patch('runner.os.statvfs', side_effect=OSError()): self.store.tick()
        self.assertEqual(self.store.request(req)['jobs'][0]['status'], 'failed')

    def test_future_database_schema_is_not_downgraded(self):
        self.store.db.execute('PRAGMA user_version=2')
        with self.assertRaises(ValueError): Store(self.directory)
        self.assertEqual(self.store.db.execute('PRAGMA user_version').fetchone()[0], 2)

    def test_clear_managed_clients(self):
        res = self.store.request(dict(version=1, action='clear_managed_clients'))
        self.assertEqual(res['code'], 'ok')
        self.assertEqual(res['clearedClients'], {'cleared': 0})
        # Add sample resources and revoked clients
        with self.store.db:
            self.store.db.execute('INSERT INTO revoked_clients VALUES (?, ?)', ('ws1', 'u1'))
            self.store.db.execute('INSERT INTO tt_resources VALUES (?, ?)', ('res1', json.dumps({
                'workspaceId': 'ws1', 'spec': {'id': 'res1'}, 'clients': [{'id': 'u1', 'username': 'user1'}]
            })))
            self.store.db.execute('INSERT INTO awg_resources VALUES (?, ?)', ('res2', json.dumps({
                'workspaceId': 'ws1', 'spec': {'id': 'res2'}, 'clients': [{'id': 'u1', 'publicKey': 'our_key_b64'}]
            })))
        res = self.store.request(dict(version=1, action='clear_managed_clients'))
        self.assertEqual(res['code'], 'ok')
        self.assertEqual(res['clearedClients'], {'cleared': 0})
        # Verify AntiRKN revoked clients are NOT wiped
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM revoked_clients').fetchone()[0], 1)
        # Verify AntiRKN clients in resources are preserved
        row = self.store.db.execute('SELECT data FROM tt_resources WHERE id=?', ('res1',)).fetchone()[0]
        self.assertEqual(json.loads(row)['clients'], [{'id': 'u1', 'username': 'user1'}])


if __name__ == '__main__':
    unittest.main()
