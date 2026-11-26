"""Device checks around 3x-ui, TrustTunnel and AmneziaWG upgrades."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
import component_upgrade as cu
from component_upgrade import ComponentUpgradeError, ComponentUpgradeJob
import connectivity_probe as probes
import upgrade_checks as checks
from runner import Store

KEY = 'k' * 40
NETWORK = 'e' * 64


class Base(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = Store(self.root)
        self.addCleanup(self.store.close)
        self.job_id = 'a' * 32
        self.timers = []
        self.owned = {}
        self.rows = [dict(id=1, enable=True, protocol='vless')]
        self.panel = 'b' * 32
        self.changed = set()
        for target, name, value in [
                (checks, '_start_deadman_timer', lambda job_id, seconds: self.timers.append((job_id, seconds))),
                (cu, '_start_deadman_timer', lambda job_id, seconds: self.timers.append((job_id, seconds))),
                (cu, '_stop_deadman_timer', lambda job_id: self.timers.append((job_id, 'stop'))),
                (probes, 'fingerprint', lambda store, info: 'changed' if info['id'] in self.changed else info['afterHash']),
                (checks, 'panel_rows', lambda store, panel_id: list(self.rows)),
                (checks, 'panel_known', lambda store: bool(self.rows))]:
            p = patch.object(target, name, value)
            p.start()
            self.addCleanup(p.stop)
        for module in ('tt', 'awg'):
            p = patch(module + '.owned', lambda store: self.owned)
            p.start()
            self.addCleanup(p.stop)

    def lease(self, key, protocol='tt', resource='r1', expires=900, status='active', row=1):
        info = dict(id=key, status=status, protocol=protocol, expires=time.time() + expires, afterHash='h',
                    saved=dict(spec=dict(id=resource), panelId=self.panel), rowId=row)
        probes.save(self.store, info)
        return key

    def resource(self, rid='r1', enabled=True):
        self.owned[rid] = dict(spec=dict(id=rid, enabled=enabled, deleted=False))

    def device_check(self, leases, component='trusttunnel', baseline=None, **extra):
        value = dict(leases=leases, network=NETWORK, keyHash=hashlib.sha256(KEY.encode()).hexdigest(),
                     baseline=baseline if baseline is not None else [dict(lease=k, tcp=True, udp=True) for k in leases])
        if component == 'panel':
            value['panelId'] = self.panel
        value.update(extra)
        return value

    def request(self, component='trusttunnel', device_check=None, job_id=None):
        payload = dict(component=component, version='1.3.1')
        if device_check is not None:
            payload['deviceCheck'] = device_check
        return {'version': 1, 'action': 'submit', 'id': job_id or self.job_id, 'kind': 'component_upgrade_apply',
                'count': 6, 'interval': 1, 'payload': json.dumps(payload), 'fingerprint': 'f' * 64}

    def code(self, call, *args):
        with self.assertRaises(ComponentUpgradeError) as ctx:
            call(*args)
        return ctx.exception.code

    def insert(self, request, status='succeeded', checkpoint=6):
        self.store.db.execute('INSERT INTO jobs VALUES (?,?,?,?,0,0,?)',
                              (request['id'], json.dumps(request), status, checkpoint, time.time()))
        self.store.db.commit()


class AdmissionTests(Base):
    def test_resources_need_checks_and_nothing_to_check_needs_none(self):
        checks.admit(self.store, self.request())
        self.resource()
        self.assertEqual(self.code(checks.admit, self.store, self.request()), 'upgrade_checks_required')
        self.resource('r2', enabled=False)
        checks.admit(self.store, self.request(device_check=self.device_check([self.lease('1' * 32)])))

    def test_every_enabled_resource_is_covered_by_its_own_lease(self):
        self.resource(); self.resource('r2')
        one = self.lease('1' * 32)
        self.assertEqual(self.code(checks.admit, self.store, self.request(device_check=self.device_check([one]))),
                         'upgrade_checks_coverage')
        twice = self.lease('2' * 32)  # The same resource again.
        self.assertEqual(self.code(checks.admit, self.store, self.request(device_check=self.device_check([one, twice]))),
                         'upgrade_checks_coverage')
        other = self.lease('3' * 32, protocol='awg', resource='r2')
        self.assertEqual(self.code(checks.admit, self.store, self.request(device_check=self.device_check([one, other]))),
                         'upgrade_checks_coverage')
        checks.admit(self.store, self.request(device_check=self.device_check([one, self.lease('4' * 32, resource='r2')])))

    def test_lease_state_time_and_baseline(self):
        self.resource()
        key = self.lease('1' * 32, expires=checks.MIN_LEASE - 30)
        self.assertEqual(self.code(checks.admit, self.store, self.request(device_check=self.device_check([key]))),
                         'upgrade_checks_timeout')
        key = self.lease('1' * 32)
        self.changed.add(key)
        self.assertEqual(self.code(checks.admit, self.store, self.request(device_check=self.device_check([key]))),
                         'upgrade_checks_changed')
        self.changed.clear()
        failed = [dict(lease=key, tcp=False, udp=False)]
        self.assertEqual(self.code(checks.admit, self.store, self.request(device_check=self.device_check([key], baseline=failed))),
                         'upgrade_checks_coverage')
        self.lease(key, status='closed')
        self.assertEqual(self.code(checks.admit, self.store, self.request(device_check=self.device_check([key]))),
                         'upgrade_checks_changed')

    def test_panel_needs_every_enabled_inbound_and_only_vless(self):
        self.assertEqual(self.code(checks.admit, self.store, self.request('panel')), 'upgrade_checks_required')
        key = self.lease('1' * 32, protocol='vless')
        checks.admit(self.store, self.request('panel', self.device_check([key], 'panel')))
        self.rows.append(dict(id=2, enable=True, protocol='trojan'))
        self.assertEqual(self.code(checks.admit, self.store, self.request('panel', self.device_check([key], 'panel'))),
                         'upgrade_checks_coverage')
        self.rows[-1] = dict(id=2, enable=True, protocol='vless')
        self.assertEqual(self.code(checks.admit, self.store, self.request('panel', self.device_check([key], 'panel'))),
                         'upgrade_checks_coverage')
        foreign = self.lease('2' * 32, protocol='vless', row=2)
        probes.save(self.store, {**probes.load(self.store, foreign), 'saved': dict(spec=dict(id='x'), panelId='c' * 32)})
        self.assertEqual(self.code(checks.admit, self.store, self.request('panel', self.device_check([key, foreign], 'panel'))),
                         'upgrade_checks_coverage')

    def test_other_components_carry_no_device_checks(self):
        checks.admit(self.store, self.request('xray'))
        self.assertEqual(self.code(checks.admit, self.store, self.request('xray', self.device_check([]))), 'upgrade_checks_coverage')

    def test_a_submission_runs_beside_exactly_its_own_live_leases(self):
        one = self.lease('1' * 32)
        mine = self.request(device_check=self.device_check([one]))
        self.assertTrue(checks.claims(self.store, mine))
        self.lease('2' * 32, resource='r2')
        self.assertFalse(checks.claims(self.store, mine))
        self.assertFalse(checks.claims(self.store, {**mine, 'kind': 'vless_apply'}))
        self.lease('2' * 32, resource='r2', expires=-5)  # Expired: not live, as for probes.active.
        self.assertTrue(checks.claims(self.store, mine))

    def test_leases_stay_while_their_upgrade_is_unsettled(self):
        one = self.lease('1' * 32)
        request = self.request(device_check=self.device_check([one]))
        self.insert(request, status='running', checkpoint=3)
        self.assertTrue(checks.held(self.store, one))
        self.assertFalse(checks.held(self.store, '2' * 32))
        self.store.db.execute("UPDATE jobs SET status='succeeded'"); self.store.db.commit()
        self.assertFalse(checks.held(self.store, one))  # No window: finished.
        cu.arm_deadman(self.store, request, 120, checked=True)
        self.assertTrue(checks.held(self.store, one))
        self.assertEqual(self.code(checks.admit, self.store, self.request(device_check=self.device_check([one]), job_id='c' * 32)),
                         'upgrade_checks_changed')


class WindowTests(Base):
    def setUp(self):
        super().setUp()
        self.resource()
        self.key = self.lease('1' * 32)
        self.req = self.request(device_check=self.device_check([self.key], baseline=[dict(lease=self.key, tcp=True, udp=False)]))
        self.insert(self.req)
        cu.arm_deadman(self.store, self.req, 200, checked=True)
        self.window = cu._deadman_path(self.root, self.job_id)
        self.timers.clear()

    def commit(self, key=KEY, network=NETWORK, tcp=True, udp=False):
        body = dict(key=key, network=network, checks=[dict(lease=self.key, tcp=tcp, udp=udp)])
        return checks.commit(self.store, dict(id=self.job_id, payload=json.dumps(body)))

    def info(self):
        return json.loads(self.window.read_text())

    def test_only_the_device_checks_confirm_a_checked_window(self):
        self.assertEqual(self.code(cu.confirm_upgrade, self.store, self.job_id), 'upgrade_checks_required')
        self.assertFalse(self.info()['confirmed'])
        self.commit(udp=True)  # Better than before is fine.
        self.assertTrue(self.info()['confirmed'])
        self.assertIn((self.job_id, 'stop'), self.timers)
        self.assertFalse(checks.held(self.store, self.key))

    def test_worse_results_or_another_network_roll_back_now(self):
        self.assertEqual(self.code(self.commit, KEY, NETWORK, False, True), 'upgrade_checks_failed')
        self.assertEqual(self.timers, [(self.job_id, 1)])
        self.assertLessEqual(self.info()['deadline'], time.time())
        self.assertFalse(self.info()['confirmed'])
        self.assertEqual(self.code(self.commit), 'upgrade_checks_timeout')  # Too late now.

    def test_changed_network_lease_or_panel(self):
        self.assertEqual(self.code(self.commit, KEY, 'd' * 64), 'upgrade_checks_changed')
        self.assertEqual(self.timers, [(self.job_id, 1)])

    def test_closed_lease_rolls_back(self):
        self.lease(self.key, status='closed')
        self.assertEqual(self.code(self.commit), 'upgrade_checks_changed')
        self.assertEqual(self.timers, [(self.job_id, 1)])

    def test_another_shape_of_the_same_lease_after_the_upgrade_is_fine(self):
        self.changed.add(self.key)
        self.commit()
        self.assertTrue(self.info()['confirmed'])

    def test_wrong_key_changes_nothing(self):
        self.assertEqual(self.code(self.commit, 'x' * 40), 'upgrade_conflict')
        self.assertEqual(self.timers, [])
        self.assertTrue(cu.window_open(self.root, self.job_id))

    def test_abort_rolls_back_now_and_never_after_a_commit(self):
        abort = dict(id=self.job_id, payload=json.dumps(dict(key=KEY)))
        self.assertEqual(self.code(checks.abort, self.store, dict(abort, payload=json.dumps(dict(key='y' * 40)))), 'upgrade_conflict')
        checks.abort(self.store, abort)
        self.assertEqual(self.timers, [(self.job_id, 1)])
        self.assertLessEqual(self.info()['deadline'], time.time())
        info = self.info(); info['deadline'] = time.time() + 100
        self.window.write_text(json.dumps(info))
        self.commit()
        self.assertEqual(self.code(checks.abort, self.store, abort), 'upgrade_conflict')

    def test_plain_jobs_have_no_commit(self):
        other = self.request(job_id='c' * 32)
        self.insert(other)
        body = dict(id=other['id'], payload=json.dumps(dict(key=KEY, network=NETWORK, checks=[])))
        self.assertEqual(self.code(checks.commit, self.store, body), 'upgrade_conflict')


class JobTests(Base):
    def job(self, component='trusttunnel', leases=None):
        request = self.request(component, self.device_check(leases if leases is not None else [], component))
        self.insert(request, status='running', checkpoint=5)
        job = ComponentUpgradeJob(self.store, request)
        upgrader = job.upgrader
        upgrader._ensure_detection_and_metadata = MagicMock()
        upgrader.verify_health = MagicMock()
        upgrader.verify_connectivity = MagicMock()
        job._sync_panel_access_versions = MagicMock()
        return job

    def events(self):
        return [json.loads(r[0])['code'] for r in self.store.db.execute('SELECT event FROM events WHERE id=? ORDER BY sequence', (self.job_id,))]

    def test_checked_window_waits_for_checks_within_the_lease_time(self):
        self.resource()
        key = self.lease('1' * 32, expires=checks.MIN_WINDOW + checks.MARGIN + 50)
        self.job(leases=[key]).step(5)
        info = json.loads(cu._deadman_path(self.root, self.job_id).read_text())
        self.assertTrue(info['checked'])
        self.assertLessEqual(info['deadline'], time.time() + 50 + checks.MIN_WINDOW + 1)
        self.assertEqual(self.events()[-1], 'upgrade_awaiting_checks')

    def test_no_window_the_leases_cannot_outlive(self):
        self.resource()
        key = self.lease('1' * 32, expires=checks.MIN_WINDOW + checks.MARGIN - 5)
        self.assertEqual(self.code(self.job(leases=[key]).step, 5), 'upgrade_checks_timeout')
        self.assertFalse(cu._deadman_path(self.root, self.job_id).exists())

    def test_without_leases_the_plain_confirmation_stays(self):
        self.job(leases=[]).step(5)
        self.assertFalse(json.loads(cu._deadman_path(self.root, self.job_id).read_text()).get('checked'))
        self.assertEqual(self.events()[-1], 'upgrade_awaiting_confirmation')

    def test_panel_api_after_the_switch(self):
        key = self.lease('1' * 32, protocol='vless')
        job = self.job('panel', [key])
        checks.panel_inbounds(self.root, self.job_id).parent.mkdir(parents=True, exist_ok=True)
        checks.panel_inbounds(self.root, self.job_id).write_text('[1, 2]')
        self.assertEqual(self.code(job.step, 5), 'upgrade_checks_panel_api')
        checks.panel_inbounds(self.root, self.job_id).write_text('[1]')
        job.step(5)
        self.assertEqual(self.events()[-1], 'upgrade_awaiting_checks')

    def test_a_new_upgrade_never_confirms_a_checked_window(self):
        other = self.request(device_check=self.device_check([self.lease('1' * 32)]), job_id='c' * 32)
        self.insert(other)
        cu.arm_deadman(self.store, other, 200, checked=True)
        request = self.request('xray')
        self.insert(request, status='running', checkpoint=0)
        job = ComponentUpgradeJob(self.store, request)
        job.upgrader.pre_check = MagicMock()
        with patch.object(cu, 'plan', return_value=dict(fingerprint='f' * 64)):
            self.assertEqual(self.code(job.step, 0), 'upgrade_conflict')
        self.assertTrue(cu.window_open(self.root, other['id']))

    def test_no_switch_without_time_for_checks(self):
        self.resource()
        key = self.lease('1' * 32, expires=checks.SWITCH_RESERVE - 10)
        payload = json.loads(self.request(device_check=self.device_check([key]))['payload'])
        self.assertEqual(self.code(checks.before_switch, self.store, payload), 'upgrade_checks_timeout')


class RpcTests(Base):
    def test_submit_beside_its_leases_and_the_new_actions(self):
        self.resource()
        self.assertEqual(self.store.request(self.request())['code'], 'upgrade_checks_required')
        key = self.lease('1' * 32)
        self.assertEqual(self.store.request(self.request(job_id='c' * 32))['code'], 'probe_busy')
        self.assertEqual(self.store.request({**self.request(device_check=self.device_check([key]))})['code'], 'ok')
        self.assertEqual(self.store.request(dict(version=1, action='probe_end', id=key))['code'], 'probe_busy')
        body = json.dumps(dict(key=KEY, network=NETWORK, checks=[dict(lease=key, tcp=True, udp=True)]))
        self.assertEqual(self.store.request(dict(version=1, action='component_upgrade_commit', id=self.job_id, payload=body))['code'],
                         'upgrade_conflict')  # Its window is not open yet.
        self.assertEqual(self.store.request(dict(version=1, action='component_upgrade_abort', id=self.job_id,
                                                 payload=json.dumps(dict(key=KEY))))['code'], 'upgrade_conflict')


if __name__ == '__main__':
    unittest.main()
