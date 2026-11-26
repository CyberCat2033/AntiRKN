"""Inbound writes on 3x-ui 3.9+ (update keeps clients and enable) and 3.7/3.8."""
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from urllib.parse import unquote
from unittest.mock import patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
import egress_access
import managed_existing as existing
import panel_clients
from panel_clients import converge, in_transition
from runner import Store
import vless
from vless import VlessError, normal, digest
from test_vless import Api, payload

CLIENT_ROUTES = ('/panel/api/clients/add', '/panel/api/clients/update/', '/panel/api/clients/del/',
                 '/detach', '/attach', '/panel/api/inbounds/setEnable/')


class Panel38(Api):
    """3x-ui 3.7/3.8: inbounds/update applies clients and enable."""
    def __init__(self):
        super().__init__()
        self.routes = []

    def call(self, path, data=None):
        self.routes.append(path)
        return super().call(path, data)

    def client_routes(self):
        return [r for r in self.routes if any(part in r for part in CLIENT_ROUTES)]


class Panel311(Panel38):
    """3x-ui 3.9+: update keeps the stored clients and enable flag; clients
    are global records changed through /panel/api/clients/*."""
    def __init__(self):
        super().__init__()
        self.crash_on = None
        self.fail_on = None

    def row(self, rid):
        return next(r for r in self.rows if r['id'] == rid)

    def effect(self, path):
        self.effects += 1
        if self.crash or self.crash_on and self.crash_on in path:
            self.crash = False
            self.crash_on = None
            raise OSError('response lost')

    def call(self, path, data=None):
        if self.fail_on and self.fail_on in path:
            self.fail_on = None
            self.routes.append(path)
            raise ValueError('panel_api_failed')
        if path.startswith('/panel/api/inbounds/update/'):
            self.routes.append(path)
            stored = self.row(int(path.rsplit('/', 1)[1]))
            row = normal(data)
            row['settings']['clients'] = copy.deepcopy(stored['settings']['clients'])
            row['enable'] = stored['enable']
            self.rows = [row if r['id'] == row['id'] else r for r in self.rows]
            return self.effect(path)
        if path.startswith('/panel/api/inbounds/setEnable/'):
            self.routes.append(path)
            self.row(int(path.rsplit('/', 1)[1]))['enable'] = data['enable']
            return self.effect(path)
        if path == '/panel/api/clients/add':
            self.routes.append(path)
            self.clients()
            client = data['client']
            if client['email'] in self.client_records:
                raise ValueError('panel_api_failed')  # email already in use
            client = dict(client, subId=client.get('subId') or str(uuid.uuid4()))
            for rid in data['inboundIds']:
                self.row(rid)['settings']['clients'].append(copy.deepcopy(client))
            self.client_records[client['email']] = dict(id=len(self.client_records) + 1, email=client['email'], uuid=client.get('id', ''))
            return self.effect(path)
        if path.startswith('/panel/api/clients/update/'):
            self.routes.append(path)
            email = unquote(path.rsplit('/', 1)[1])
            for row in self.rows:
                clients = row['settings']['clients']
                for i, old in enumerate(clients):
                    if old.get('email') == email:
                        clients[i] = dict(data, subId=data.get('subId') or old.get('subId', ''))
            return self.effect(path)
        if path.startswith('/panel/api/clients/del/'):
            self.routes.append(path)
            email = unquote(path.rsplit('/', 1)[1])
            for row in self.rows:
                row['settings']['clients'] = [c for c in row['settings']['clients'] if c.get('email') != email]
            self.client_records.pop(email, None)
            return self.effect(path)
        if path.endswith('/detach') or path.endswith('/attach'):
            self.routes.append(path)
            email = unquote(path.split('/')[-2])
            record = self.client_records[email]
            for rid in data['inboundIds']:
                clients = self.row(rid)['settings']['clients']
                clients[:] = [c for c in clients if c.get('email') != email]
                if path.endswith('/attach'):
                    clients.append(dict(id=record['uuid'], email=email, enable=True, subId='kept-sub'))
            return self.effect(path)
        return super().call(path, data)


def inbound(rid=7, clients=(), enable=True, port=24443):
    return dict(id=rid, protocol='vless', remark='Original', enable=enable, listen='127.0.0.1', port=port,
                settings=dict(decryption='none', clients=[copy.deepcopy(c) for c in clients]),
                streamSettings=dict(network='tcp', security='none'), sniffing=dict(enabled=False), expiryTime=0)


FOREIGN = dict(id='11111111-1111-4111-8111-111111111111', email='foreign', enable=True, limitIp=4)
OURS = dict(id='22222222-2222-4222-8222-222222222222', email='ar_x_ours', enable=True, flow='',
            totalGB=0, expiryTime=0, limitIp=0, tgId=0, subId='', reset=0)


def wanted_from(row, clients=None, **changes):
    result = copy.deepcopy(row)
    if clients is not None:
        result['settings'] = dict(result['settings'], clients=copy.deepcopy(clients))
    result.update(changes)
    return result


def clients_by_email(row):
    return {c['email']: c for c in row['settings']['clients']}


class ConvergeTests(unittest.TestCase):
    def panels(self):
        return (('3.8', Panel38()), ('3.11', Panel311()))

    def test_own_inbound_follows_wanted_clients_and_switch_on_both_panels(self):
        other = dict(OURS, id='33333333-3333-4333-8333-333333333333', email='ar_x_other')
        for version, api in self.panels():
            with self.subTest(version=version):
                api.rows = [inbound(clients=[OURS, other])]
                # Add a user, drop one, disable one, and switch the inbound off.
                added = dict(OURS, id='44444444-4444-4444-8444-444444444444', email='ar_x_new')
                wanted = wanted_from(api.rows[0], [dict(OURS, enable=False), added], enable=False, remark='Renamed')
                observed = converge(api, 7, wanted)
                self.assertTrue(vless.subset(normal(wanted), normal(observed)))
                self.assertEqual(observed, api.rows[0])
                self.assertIs(api.rows[0]['enable'], False)
                self.assertEqual(api.rows[0]['remark'], 'Renamed')
                self.assertEqual(set(clients_by_email(api.rows[0])), {'ar_x_ours', 'ar_x_new'})
                self.assertIs(clients_by_email(api.rows[0])['ar_x_ours']['enable'], False)
                if version == '3.8':
                    self.assertEqual(api.client_routes(), [])
                else:
                    self.assertEqual(sorted(r.rsplit('/', 1)[-1] for r in api.client_routes()),
                                     ['7', 'add', 'ar_x_other', 'ar_x_ours'])
                    self.assertIn('/panel/api/clients/del/ar_x_other', api.routes)
                    self.assertIn('/panel/api/clients/update/ar_x_ours', api.routes)
                    self.assertNotIn('ar_x_other', api.client_records)
                # Repeating converges without another client or switch call.
                count = len(api.client_routes())
                converge(api, 7, wanted)
                self.assertEqual(len(api.client_routes()), count)

    def test_adopted_merge_keeps_foreign_clients_and_their_later_panel_edits(self):
        for version, api in self.panels():
            with self.subTest(version=version):
                before = inbound(clients=[FOREIGN])
                api.rows = [copy.deepcopy(before), inbound(8, clients=[FOREIGN], port=24444)]
                after = wanted_from(before, [FOREIGN, OURS])
                if version == '3.11':
                    # The panel renewed the foreign client after the plan.
                    api.rows[0]['settings']['clients'][0]['expiryTime'] = 999
                observed = converge(api, 7, after, before=before)
                foreign = clients_by_email(observed)['foreign']
                self.assertEqual(set(clients_by_email(observed)), {'foreign', 'ar_x_ours'})
                if version == '3.11':
                    self.assertEqual(foreign['expiryTime'], 999)
                    self.assertEqual(api.client_routes(), ['/panel/api/clients/add'])
                # Revoking ours removes only ours; the shared foreign record stays.
                revoked = converge(api, 7, before, before=after)
                self.assertEqual(set(clients_by_email(revoked)), {'foreign'})
                self.assertEqual(set(clients_by_email(api.rows[1])), {'foreign'})
                if version == '3.11':
                    self.assertEqual(api.client_routes()[-1], '/panel/api/clients/del/ar_x_ours')
                    self.assertIn('foreign', api.client_records)

    def test_dropping_a_shared_client_detaches_it_from_this_inbound_only(self):
        api = Panel311()
        api.rows = [inbound(clients=[FOREIGN, OURS]), inbound(8, clients=[FOREIGN], port=24444)]
        row = copy.deepcopy(api.rows[0])
        observed = converge(api, 7, wanted_from(row, [OURS]), before=row)
        self.assertEqual(set(clients_by_email(observed)), {'ar_x_ours'})
        self.assertEqual(set(clients_by_email(api.rows[1])), {'foreign'})
        self.assertEqual(api.client_routes(), ['/panel/api/clients/foreign/detach'])
        self.assertIn('foreign', api.client_records)

    def test_readding_an_email_with_a_kept_record_attaches_then_updates_it(self):
        api = Panel311()
        api.rows = [inbound(clients=[OURS]), inbound(8, port=24444)]
        converge(api, 8, wanted_from(api.rows[1], [dict(OURS, enable=False)]))
        # The client now sits on both inbounds; detach it from 8 again.
        converge(api, 8, wanted_from(api.rows[1], []))
        self.assertEqual(api.client_routes()[-1], '/panel/api/clients/ar_x_ours/detach')
        self.assertEqual(clients_by_email(api.rows[0])['ar_x_ours']['enable'], False)

    def test_foreign_credentials_under_our_email_are_a_conflict(self):
        api = Panel311()
        api.rows = [inbound(clients=[dict(OURS, id='55555555-5555-4555-8555-555555555555')], port=1), inbound(8, port=24444)]
        with self.assertRaises(VlessError) as raised:
            converge(api, 8, wanted_from(api.rows[1], [OURS]))
        self.assertEqual(raised.exception.code, 'vless_conflict')
        self.assertEqual(api.client_routes(), [])

    def test_switch_alone_uses_set_enable_and_keeps_clients(self):
        api = Panel311()
        api.rows = [inbound(clients=[FOREIGN])]
        row = copy.deepcopy(api.rows[0])
        observed = converge(api, 7, dict(row, enable=False), before=row)
        self.assertIs(observed['enable'], False)
        self.assertEqual(api.client_routes(), ['/panel/api/inbounds/setEnable/7'])
        self.assertEqual(observed['settings']['clients'], [FOREIGN])

    def test_crash_between_calls_resumes_by_readback(self):
        for crash_on in ('/panel/api/inbounds/update/', '/panel/api/clients/add', '/panel/api/clients/update/',
                         '/panel/api/inbounds/setEnable/'):
            with self.subTest(crash_on=crash_on):
                api = Panel311()
                old = dict(OURS, email='ar_x_old', id='66666666-6666-4666-8666-666666666666')
                kept = dict(OURS, email='ar_x_kept', id='99999999-9999-4999-8999-999999999999')
                before = inbound(clients=[FOREIGN, old, kept])
                api.rows = [copy.deepcopy(before)]
                after = wanted_from(before, [FOREIGN, OURS, dict(kept, enable=False)], enable=False, remark='Renamed')
                api.crash_on = crash_on
                with self.assertRaises(OSError):
                    converge(api, 7, after, before=before)
                current = api.rows[0]
                self.assertTrue(in_transition(before, after, current))
                effects = api.effects
                converge(api, 7, after, before=before)
                self.assertTrue(vless.subset(normal(after), normal(api.rows[0])))
                self.assertEqual(set(clients_by_email(api.rows[0])), {'foreign', 'ar_x_ours', 'ar_x_kept'})
                self.assertIs(clients_by_email(api.rows[0])['ar_x_kept']['enable'], False)
                self.assertNotIn('ar_x_old', api.client_records)
                self.assertGreater(api.effects, effects)

    def test_foreign_change_is_not_a_transition(self):
        before = inbound(clients=[FOREIGN])
        after = wanted_from(before, [FOREIGN, OURS])
        rogue = wanted_from(before, [FOREIGN, dict(OURS, id='77777777-7777-4777-8777-777777777777', email='rogue')])
        self.assertFalse(in_transition(before, after, rogue))
        self.assertFalse(in_transition(before, after, wanted_from(before, [OURS])))
        self.assertFalse(in_transition(before, after, wanted_from(after, port=1)))
        self.assertFalse(in_transition(before, after, wanted_from(before, [dict(FOREIGN, limitIp=9)])))
        self.assertTrue(in_transition(before, after, before))
        self.assertTrue(in_transition(before, after, after))


class OwnVlessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name))
        self.patches = [patch('vless.material', return_value=dict(privateKey='A'*43, publicKey='B'*43, shortId='0123456789abcdef')),
                        patch('vless.secret', side_effect=lambda label: hashlib.sha256(label.encode()).digest()),
                        patch('vless.command', return_value=b''), patch('vless.safe_file')]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.store.close()
        self.temp.cleanup()

    def use(self, api):
        self.api = api
        p = patch('vless.panel_for', return_value=api)
        p.start()
        self.addCleanup(p.stop)

    def submit(self, p, number):
        preview = vless.plan(self.store, dict(id=p['panelId'], payload=json.dumps(p)))
        req = dict(version=1, action='submit', id=f'{number:032x}', kind='vless_apply', count=len(p['resources']) + 2,
                   interval=1, payload=json.dumps(p), fingerprint=preview['fingerprint'])
        self.store.request(req)
        return req

    def job(self, req):
        return self.store.request(dict(version=1, action='status', id=req['id'], cursor=0))['jobs'][0]

    def finish(self, req):
        for _ in range(8):
            self.store.tick()
            if self.job(req)['status'] in ('succeeded', 'failed', 'partially_applied', 'cancelled'):
                break
        return self.job(req)

    def emails(self, index):
        return {c['email']: c['enable'] for c in self.api.rows[index]['settings']['clients']}

    def confirmed(self):
        return all(r['confirmed'] for r in vless.state(self.store, 'b'*32))

    def test_users_and_switch_reach_the_panel_on_both_versions(self):
        for version, api in (('3.8', Panel38()), ('3.11', Panel311())):
            with self.subTest(version=version):
                self.store.close()
                self.temp.cleanup()
                self.temp = tempfile.TemporaryDirectory()
                self.store = Store(Path(self.temp.name))
                self.use(api)
                p = payload()
                c, d = 'ar_' + p['resources'][0]['id'] + '_' + 'c'*32, 'ar_' + p['resources'][0]['id'] + '_' + 'd'*32
                self.assertEqual(self.finish(self.submit(p, 1))['status'], 'succeeded')
                self.assertEqual(self.emails(0), {c: True, d: True})
                p['users'][0]['enabled'] = False
                self.assertEqual(self.finish(self.submit(p, 2))['status'], 'succeeded')
                self.assertEqual(self.emails(0), {c: False, d: True})
                p['users'] = p['users'][:1]
                self.assertEqual(self.finish(self.submit(p, 3))['status'], 'succeeded')
                self.assertEqual(self.emails(0), {c: False})
                p['users'][0]['enabled'] = True
                p['users'].append(dict(id='e'*32, enabled=True))
                p['resources'][0]['enabled'] = False
                self.assertEqual(self.finish(self.submit(p, 4))['status'], 'succeeded')
                self.assertEqual(self.emails(0), {c: True, 'ar_' + p['resources'][0]['id'] + '_' + 'e'*32: True})
                self.assertIs(api.rows[0]['enable'], False)
                self.assertTrue(self.confirmed())
                if version == '3.8':
                    self.assertEqual(api.client_routes(), [])
                else:
                    self.assertIn('/panel/api/inbounds/setEnable/1', api.routes)
                    self.assertIn('/panel/api/clients/del/' + d, api.routes)

    def test_crash_inside_a_resource_resumes_on_3_11(self):
        for crash_on in ('/panel/api/clients/update/', '/panel/api/inbounds/setEnable/', '/panel/api/clients/add'):
            with self.subTest(crash_on=crash_on):
                self.store.close()
                self.temp.cleanup()
                self.temp = tempfile.TemporaryDirectory()
                self.store = Store(Path(self.temp.name))
                api = Panel311()
                self.use(api)
                p = payload()
                self.assertEqual(self.finish(self.submit(p, 1))['status'], 'succeeded')
                p['users'][0]['enabled'] = False
                p['users'].append(dict(id='e'*32, enabled=True))
                p['resources'][0]['enabled'] = False
                req = self.submit(p, 2)
                api.crash_on = crash_on
                self.assertIn(self.finish(req)['status'], ('failed', 'partially_applied'))
                self.store.request(dict(version=1, action='resume', id=req['id']))
                self.assertEqual(self.finish(req)['status'], 'succeeded')
                self.assertIs(api.rows[0]['enable'], False)
                self.assertEqual(sorted(self.emails(0).values()), [False, True, True])
                self.assertTrue(self.confirmed())

    def test_foreign_client_added_mid_job_is_still_a_conflict(self):
        api = Panel311()
        self.use(api)
        p = payload()
        self.assertEqual(self.finish(self.submit(p, 1))['status'], 'succeeded')
        p['users'][0]['enabled'] = False
        req = self.submit(p, 2)
        api.fail_on = '/panel/api/clients/update/'
        self.assertIn(self.finish(req)['status'], ('failed', 'partially_applied'))
        api.rows[0]['settings']['clients'].append(dict(id='88888888-8888-4888-8888-888888888888', email='intruder', enable=True))
        effects = api.effects
        self.store.request(dict(version=1, action='resume', id=req['id']))
        self.assertNotEqual(self.finish(req)['status'], 'succeeded')
        self.assertIn('vless_conflict', [e['code'] for e in self.job(req)['events']])
        self.assertEqual(api.effects, effects)


class AdoptedVlessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name))
        self.api = Panel311()
        self.api.rows = [dict(inbound(clients=[FOREIGN]), sniffing=dict(enabled=False), total=999),
                         inbound(8, clients=[FOREIGN], port=24444)]
        original = vless.command

        def command(args, **kw):
            return original(args, **kw) if args[0] == '/usr/bin/openssl' else b''
        self.patches = [patch('vless.panel_for', return_value=self.api), patch('vless.command', side_effect=command),
                        patch('managed_existing.safe_file')]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.store.close()
        self.temp.cleanup()

    def payload(self):
        r = dict(id='b'*32, name='Imported', enabled=True, deleted=False, endpoint='vpn.example.com', port=24443,
                 externalPort=443, transport='tcp', security='none',
                 adoption=dict(sourceId='7', observedHash='0'*64, panelId='a'*32, panelPort=2053))
        p = dict(version=1, workspaceId='a'*32, panelId='a'*32, resources=[r], users=[dict(id='c'*32, enabled=True)])
        r['adoption']['observedHash'] = existing.adapter('vless').snapshot(self.store, p, r)['fingerprint']
        return p

    def submit(self, p, number):
        preview = vless.plan(self.store, dict(id=p['panelId'], payload=json.dumps(p)))
        request = dict(version=1, action='submit', kind='vless_apply', id=f'{number:032x}', count=3, interval=1,
                       payload=json.dumps(p), fingerprint=preview['fingerprint'])
        self.assertEqual(self.store.request(request)['code'], 'ok')
        return request

    def finish(self, request):
        for _ in range(8):
            self.store.tick()
            row = self.store.request(dict(version=1, action='status', id=request['id'], cursor=0))['jobs'][0]
            if row['status'] in ('succeeded', 'failed', 'partially_applied', 'cancelled'):
                return row
        self.fail('job did not finish')

    def test_merge_and_revoke_touch_only_our_client(self):
        p = self.payload()
        self.assertEqual(self.finish(self.submit(p, 1))['status'], 'succeeded')
        self.assertEqual(set(clients_by_email(self.api.rows[0])), {'foreign', 'ar_' + 'b'*32 + '_' + 'c'*32})
        self.assertEqual(clients_by_email(self.api.rows[0])['foreign'], FOREIGN)
        self.assertTrue(vless.state(self.store, 'a'*32)[0]['confirmed'])
        p['users'][0]['enabled'] = False
        self.assertEqual(self.finish(self.submit(p, 2))['status'], 'succeeded')
        self.assertEqual(self.api.rows[0]['settings']['clients'], [FOREIGN])
        self.assertEqual(self.api.rows[1]['settings']['clients'], [FOREIGN])
        self.assertIn('foreign', self.api.client_records)
        self.assertFalse(any('/foreign' in r for r in self.api.client_routes()))

    def test_lost_reply_after_client_add_is_undone_and_resumes_once(self):
        p = self.payload()
        request = self.submit(p, 1)
        self.store.tick()
        self.api.crash_on = '/panel/api/clients/add'
        self.assertEqual(self.finish(request)['status'], 'failed')
        # The failed step is undone: our client is gone, the foreign one kept.
        self.assertEqual(self.api.rows[0]['settings']['clients'], [FOREIGN])
        self.store.request(dict(version=1, action='resume', id=request['id']))
        self.assertEqual(self.finish(request)['status'], 'succeeded')
        self.assertEqual(len(self.api.rows[0]['settings']['clients']), 2)


class EgressAccessTests(unittest.TestCase):
    def test_service_client_is_added_and_restored_through_client_routes(self):
        api = Panel311()
        api.rows = [inbound(clients=[FOREIGN]), inbound(8, clients=[FOREIGN], port=24444)]
        before = copy.deepcopy(api.rows[0])
        with patch.object(egress_access, 'records', return_value=[]):
            client, _, after = egress_access.issue(before, 'k'*64, 'ar_egress_')
            observed = egress_access.ensure_inbound(api, 7, before, after)
            self.assertEqual(set(clients_by_email(observed)), {'foreign', client['email']})
            self.assertEqual(api.client_routes(), ['/panel/api/clients/add'])
            # Repeating after a lost reply writes nothing new.
            effects = api.effects
            egress_access.ensure_inbound(api, 7, before, after)
            self.assertEqual(api.client_routes(), ['/panel/api/clients/add'])
            restored = egress_access.restore_client(api, 7, client, before)
        self.assertEqual(restored['settings']['clients'], [FOREIGN])
        self.assertEqual(api.rows[1]['settings']['clients'], [FOREIGN])
        self.assertEqual(api.client_routes()[-1], '/panel/api/clients/del/' + client['email'])
        self.assertGreaterEqual(api.effects, effects)


if __name__ == '__main__':
    unittest.main()
