import copy
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
import connectivity_probe as probe
import managed_existing
import awg
import tt
import vless
import test_managed_existing as adoption_fixture
import test_vless as vless_fixture


def probe_api(api):
    original = api.call
    def call(path, data=None):
        if path == '/panel/api/clients/add' or path.startswith('/panel/api/clients/del/'):
            # This fixture is a panel without the 3.7+ client routes.
            import urllib.error
            raise urllib.error.HTTPError(path, 404, 'Not Found', {}, None)
        if path.endswith('/addClient'):
            row = next(r for r in api.rows if r['id'] == data['id'])
            row['settings']['clients'].extend(json.loads(data['settings'])['clients'])
            api.effects += 1
        elif '/delClient/' in path:
            rid, key = path.split('/')[-3], path.split('/')[-1]
            row = next(r for r in api.rows if r['id'] == int(rid))
            row['settings']['clients'] = [c for c in row['settings']['clients'] if c['id'] != key]
            api.effects += 1
        else:
            return original(path, data)
    api.call = call


class AdoptedProbeTests(unittest.TestCase):
    def setUp(self):
        adoption_fixture.AdoptionTests.setUp(self)
        patcher=patch.object(probe,'safe_file');patcher.start();self.patches.append(patcher)
    tearDown = adoption_fixture.AdoptionTests.tearDown
    awg_snapshot = adoption_fixture.AdoptionTests.awg_snapshot
    awg_write = adoption_fixture.AdoptionTests.awg_write
    tt_snapshot = adoption_fixture.AdoptionTests.tt_snapshot
    tt_write = adoption_fixture.AdoptionTests.tt_write
    payload = adoption_fixture.AdoptionTests.payload
    submit = adoption_fixture.AdoptionTests.submit
    finish = adoption_fixture.AdoptionTests.finish
    def awg_exec(self, resource, args, data=None, check=True):
        if 'remove' in args:
            self.runtime = probe.remove_peer(self.runtime, args[-2])
        return adoption_fixture.AdoptionTests.awg_exec(self, resource, args, data, check)

    def begin(self, protocol, number=1):
        p = self.payload(protocol)
        self.assertEqual(self.finish(self.submit(p, protocol, number))['status'], 'succeeded')
        request = dict(version=1, action='probe_begin', id=f'{number+100:032x}', payload=json.dumps(dict(
            protocol=protocol, resource='b'*32, workspace='a'*32, spec=p['resources'][0])))
        return request

    def test_all_protocols_temporary_access_does_not_enter_managed_clients(self):
        probe_api(self.api)
        for i, protocol in enumerate(('vless','awg','tt'),1):
            with self.subTest(protocol=protocol), patch.object(probe,'arm'), patch.object(probe,'retire'):
                req=self.begin(protocol,i)
                before=copy.deepcopy(dict(vless=vless.owned_rows, awg=awg.owned, tt=tt.owned)[protocol](self.store))
                raw_before=self.raw; credentials_before=self.credentials; rows_before=copy.deepcopy(self.api.rows)
                result=self.store.request(req)
                self.assertEqual(result['code'],'ok', result)
                info=result['connectionProbe']; self.assertEqual(info['observation']['clients'][0]['id'],req['id'])
                self.assertEqual(dict(vless=vless.owned_rows, awg=awg.owned, tt=tt.owned)[protocol](self.store),before)
                self.assertEqual(self.store.request(req)['connectionProbe'],info)
                end=self.store.request(dict(version=1,action='probe_end',id=req['id']))
                self.assertEqual(end['connectionProbe'],dict(closed=True,stable=True),end)
                self.assertEqual(self.raw,raw_before);self.assertEqual(self.credentials,credentials_before)
                self.assertEqual(self.api.rows,rows_before)
                private=probe.load(self.store,req['id']);self.assertEqual(private['status'],'closed')
                self.assertNotIn('saved',private);self.assertNotIn('observation',private)

    def test_unmanaged_all_protocols_are_probed_without_adoption(self):
        probe_api(self.api)
        for i, protocol in enumerate(('vless','awg','tt')):
            with self.subTest(protocol=protocol), patch.object(probe,'arm'), patch.object(probe,'retire'):
                p=self.payload(protocol)
                req=dict(version=1,action='probe_begin',id=f'{i+200:032x}',payload=json.dumps(dict(protocol=protocol,resource='b'*32,workspace='a'*32,spec=p['resources'][0],external=True)))
                original=([vless.normal(r) for r in self.api.rows],self.raw,self.credentials)
                response=self.store.request(req);self.assertEqual(response['code'],'ok',response)
                self.assertEqual(managed_existing.records(self.store,protocol),{})
                self.assertEqual(probe.end(self.store,req['id']),dict(closed=True,stable=True))
                self.assertEqual(([vless.normal(r) for r in self.api.rows],self.raw,self.credentials),original)

    def test_cleanup_preserves_concurrent_file_and_runtime_peers(self):
        with patch.object(probe,'arm'), patch.object(probe,'retire'):
            req=self.begin('awg');self.assertEqual(self.store.request(req)['code'],'ok')
            foreign='\n[Peer]\nPublicKey = BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ=\nAllowedIPs = 10.9.0.20/32\n'
            self.raw+=foreign;self.runtime+=foreign
            runtime_only='\n[Peer]\nPublicKey = BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU=\nAllowedIPs = 10.9.0.21/32\n'
            self.runtime+=runtime_only
            end=self.store.request(dict(version=1,action='probe_end',id=req['id']))
            self.assertEqual(end['connectionProbe'],dict(closed=True,stable=False),end)
            self.assertIn(foreign,self.raw);self.assertIn(runtime_only,self.runtime)

    def test_external_vless_traffic_counters_do_not_invalidate_probe(self):
        probe_api(self.api)
        with patch.object(probe, 'arm'), patch.object(probe, 'retire'):
            p = self.payload('vless')
            req = dict(version=1, action='probe_begin', id='e'*32,
                       payload=json.dumps(dict(protocol='vless', resource='b'*32,
                           workspace='a'*32, spec=p['resources'][0], external=True)))
            response = self.store.request(req)
            self.assertEqual(response['code'], 'ok', response)
            before = copy.deepcopy(vless.normal(self.api.rows[0]))
            self.api.rows[0].update(up=1024, down=8192, allTime=9216,
                clientStats=[dict(id=1, up=1024, down=8192, lastOnline=123456)])
            # Panel JSON formatting, client order and timestamps are not settings.
            settings = self.api.rows[0]['settings']
            for client in settings['clients']:
                client['updated_at'] = 123456
            settings['clients'].reverse()
            self.api.rows[0]['settings'] = json.dumps(settings, indent=2)
            self.assertEqual(vless.normal(self.api.rows[0]), before)
            self.assertEqual(self.store.request(req)['connectionProbe'], response['connectionProbe'])
            self.api.rows[0]['settings'] = settings  # fixture API expects a map
            self.assertEqual(probe.end(self.store, req['id']), dict(closed=True, stable=True))
            self.assertEqual(len(self.api.rows[0]['settings']['clients']), 1)
            self.assertEqual(self.api.rows[0]['up'], 1024)

    def test_external_vless_actual_changes_invalidate_probe_and_survive_cleanup(self):
        probe_api(self.api)
        with patch.object(probe, 'arm'), patch.object(probe, 'retire'):
            p = self.payload('vless')
            req = dict(version=1, action='probe_begin', id='e'*32,
                       payload=json.dumps(dict(protocol='vless', resource='b'*32,
                           workspace='a'*32, spec=p['resources'][0], external=True)))
            self.assertEqual(self.store.request(req)['code'], 'ok')
            self.api.rows[0]['streamSettings']['sockopt']['tcpFastOpen'] = False
            foreign = dict(id='99999999-9999-4999-8999-999999999999', email='added', enable=True)
            self.api.rows[0]['settings']['clients'].append(foreign)
            self.assertEqual(probe.end(self.store, req['id']), dict(closed=True, stable=False))
            self.assertFalse(self.api.rows[0]['streamSettings']['sockopt']['tcpFastOpen'])
            self.assertIn(foreign, self.api.rows[0]['settings']['clients'])
            self.assertEqual(len(self.api.rows[0]['settings']['clients']), 2)

    def test_cleanup_preserves_concurrent_tt_user(self):
        with patch.object(probe,'arm'), patch.object(probe,'retire'):
            req=self.begin('tt');self.assertEqual(self.store.request(req)['code'],'ok')
            self.credentials+='\n[[client]]\nusername="added"\npassword="foreign-two"\n'
            end=self.store.request(dict(version=1,action='probe_end',id=req['id']))
            self.assertEqual(end['connectionProbe'],dict(closed=True,stable=False),end)
            self.assertIn('added',self.credentials);self.assertIn('foreign-two',self.credentials)

    def test_watchdog_must_be_armed_before_first_mutation(self):
        req=self.begin('tt');writes=self.writes;before=self.credentials
        with patch.object(probe,'arm',side_effect=OSError('systemd unavailable')):
            self.assertEqual(self.store.request(req)['code'],'probe_failed')
        self.assertEqual(self.writes,writes);self.assertEqual(self.credentials,before)
        self.assertEqual(probe.load(self.store,req['id'])['status'],'prepared')
        with patch.object(probe,'retire'):
            self.assertTrue(probe.end(self.store,req['id'])['closed'])

    def test_rpc_mutations_blocked_while_lease_active_and_replay_cannot_resurrect(self):
        with patch.object(probe,'arm'), patch.object(probe,'retire'):
            req=self.begin('tt');self.assertEqual(self.store.request(req)['code'],'ok')
            attempt=dict(version=1,action='submit',id='d'*32,kind='demo',count=1,interval=1)
            self.assertEqual(self.store.request(attempt)['code'],'probe_busy')
            probe.end(self.store,req['id'])
            self.assertEqual(self.store.request(req)['code'],'probe_changed')

    def test_cleanup_retries_unit_retirement_after_closed_record(self):
        with patch.object(probe,'arm'):
            req=self.begin('tt');self.assertEqual(self.store.request(req)['code'],'ok')
            with patch.object(probe,'retire',side_effect=OSError()):
                self.assertEqual(self.store.request(dict(version=1,action='probe_end',id=req['id']))['code'],'probe_failed')
            with patch.object(probe,'retire') as retired:
                self.assertTrue(probe.end(self.store,req['id'])['closed']);retired.assert_called_once()


class NativeVlessProbeTests(unittest.TestCase):
    def setUp(self):
        vless_fixture.VlessTests.setUp(self)
        patcher=patch.object(probe,'safe_file');patcher.start();self.patches.append(patcher)
    tearDown = vless_fixture.VlessTests.tearDown
    submit = vless_fixture.VlessTests.submit
    finish = vless_fixture.VlessTests.finish
    job = vless_fixture.VlessTests.job
    def test_native_vless_preserves_existing_and_concurrent_clients(self):
        probe_api(self.api)
        p=vless_fixture.payload();p['resources']=p['resources'][:1]
        self.assertEqual(self.finish(self.submit(p))['status'],'succeeded')
        req=dict(version=1,action='probe_begin',id='e'*32,payload=json.dumps(dict(protocol='vless',resource=p['resources'][0]['id'],workspace=p['workspaceId'],spec=p['resources'][0])))
        before=copy.deepcopy(self.api.rows)
        with patch.object(probe,'arm'),patch.object(probe,'retire'):
            response=self.store.request(req);self.assertEqual(response['code'],'ok',response)
            self.assertEqual(len(self.api.rows[0]['settings']['clients']),len(before[0]['settings']['clients'])+1)
            foreign=dict(id='99999999-9999-4999-8999-999999999999',email='foreign',enable=True)
            self.api.rows[0]['settings']['clients'].append(foreign)
            end=probe.end(self.store,req['id']);self.assertEqual(end,dict(closed=True,stable=False))
            self.assertEqual(self.api.rows[0]['settings']['clients'],before[0]['settings']['clients']+[foreign])
