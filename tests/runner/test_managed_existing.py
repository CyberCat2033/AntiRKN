import copy
import contextlib
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
import awg
import managed_awg
import managed_existing as existing
import managed_tt
import managed_vless
import tt
import vless
from vless import VlessError
from runner import Store
from test_vless import Api


class AdoptionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name))
        self.api = Api()
        self.api.rows = [dict(id=7, protocol='vless', remark='Original', enable=True,
            listen='127.0.0.1', port=24443, settings=dict(decryption='none', fallbacks=[dict(dest=8080)],
            clients=[dict(id='11111111-1111-4111-8111-111111111111', email='foreign', enable=True, limitIp=4)]),
            streamSettings=dict(network='tcp', security='none', sockopt=dict(tcpFastOpen=True)),
            sniffing=dict(enabled=False), expiryTime=12345, total=999)]
        self.raw = ('[Interface]\nPrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n'
                    'Address = 10.9.0.1/24\nListenPort = 51820\nJc = 4\nJmin = 40\nJmax = 70\n'
                    'S1 = 0\nS2 = 0\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\n'
                    'PostUp = preserved-hook\n\n[Peer]\nPublicKey = AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=\n'
                    'PresharedKey = AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM=\nAllowedIPs = 10.9.0.2/32\n')
        self.runtime = self.raw
        self.resource = dict(id='e'*32, name='awg0', path='/fixture/awg0.conf', binary='awg', source='native', active=True)
        self.credentials = 'title="kept"\n[[client]]\nusername="foreign"\npassword="secret-fixture"\n[client.limits]\nbytes=42\n'
        self.settings = 'listen_address="127.0.0.1:8443"\ncredentials_file="/fixture/users.toml"\ncustom="kept"\n[listen_protocols.http2]\n'
        self.hosts = '[[main_hosts]]\nhostname="vpn.example.com"\ncert_chain_path="/fixture/cert"\nprivate_key_path="/fixture/key"\n'
        self.tt_active = True
        self.writes = 0
        self.lose_reply = False
        original_command = vless.command
        def command(args, **kw):
            if args[0] == '/usr/bin/openssl': return original_command(args, **kw)
            return b''
        self.patches = [patch('vless.panel_for', return_value=self.api), patch('vless.command', side_effect=command),
            patch('managed_existing.safe_file'), patch('awg.routes', return_value=[]),
            patch('awg.prerequisites', side_effect=AssertionError('must not install')),
            patch('tt.prerequisites', side_effect=AssertionError('must not install')),
            patch('tt.lock', side_effect=contextlib.nullcontext),
            patch('managed_awg.external.read_resource', side_effect=self.awg_snapshot),
            patch('managed_awg.external.write_file', side_effect=self.awg_write),
            patch('managed_awg.external.exec_resource', side_effect=self.awg_exec),
            patch('managed_tt.external.snapshot', side_effect=self.tt_snapshot),
            patch('managed_tt.read', side_effect=lambda *a: self.credentials.encode()),
            patch('managed_tt.external.write_existing', side_effect=self.tt_write),
            patch('managed_tt.run', return_value=types.SimpleNamespace(stdout=b'')),
            patch('managed_tt.certificates.inspect_pair', return_value=dict(fingerprint='1'*64)),
            patch('managed_tt.certificates.verify_service')]
        for patcher in self.patches: patcher.start()

    def tearDown(self):
        for patcher in reversed(self.patches): patcher.stop()
        self.store.close()
        self.temp.cleanup()

    def awg_snapshot(self, source):
        values, peers = managed_awg.external.parse(self.raw.encode())
        fp = vless.digest(dict(resource=self.resource, file=self.raw, runtime=awg.runtime_config(self.runtime.encode())))
        return copy.deepcopy(self.resource), self.raw.encode(), values, peers, fp

    def awg_write(self, resource, data):
        self.raw = data.decode(); self.writes += 1
        if self.lose_reply:
            self.lose_reply = False
            raise OSError('reply lost after file write')

    def awg_exec(self, resource, args, data=None, check=True):
        if 'syncconf' in args: self.runtime = data.decode()
        return types.SimpleNamespace(stdout=self.runtime.encode(), returncode=0)

    def tt_snapshot(self, source):
        resource = dict(id=source, unit='trusttunnel.service', settings='/fixture/vpn.toml', hosts='/fixture/hosts.toml',
            credentials='/fixture/users.toml', base='/fixture', ownerUid=0, active=self.tt_active,
            credentialsHash=vless.digest(self.credentials), rulesHash=vless.digest('rules'), unitHash='unit', execHash='exec')
        fingerprint = vless.digest(dict(resource=resource, settings=self.settings, hosts=self.hosts))
        return resource, self.settings.encode(), self.hosts.encode(), {}, {}, fingerprint

    def tt_write(self, path, data, owner):
        self.credentials = data.decode(); self.writes += 1
        if self.lose_reply:
            self.lose_reply = False
            raise OSError('reply lost after credentials write')

    def payload(self, protocol):
        r = dict(id='b'*32, name='Imported', enabled=True, deleted=False, endpoint='vpn.example.com',
                 port=24443 if protocol=='vless' else 51820 if protocol=='awg' else 8443, externalPort=443,
                 adoption=dict(sourceId='7' if protocol=='vless' else 'e'*32, observedHash='0'*64))
        if protocol == 'vless': r.update(transport='tcp',security='none');r['adoption'].update(panelId='a'*32,panelPort=2053)
        elif protocol == 'awg': r.update(pool='10.9.0.0/24',pool6='',mtu=1280,keepalive=25)
        else: r.update(domain='vpn.example.com',listen='127.0.0.1',quic=False,outbound='direct',socksAddress='127.0.0.1:1080')
        p = dict(version=1,workspaceId='a'*32,panelId='a'*32,resources=[r],users=[dict(id='c'*32,enabled=True)])
        if protocol != 'vless': p['protocol'] = protocol
        if protocol == 'tt': p['users'][0]['login'] = 'alice'
        r['adoption']['observedHash'] = existing.adapter(protocol).snapshot(self.store,p,r)['fingerprint']
        return p

    def submit(self, p, protocol, number=1):
        module = {'vless':vless,'awg':awg,'tt':tt}[protocol]
        module.parse_payload(json.dumps(p))
        preview = module.plan(self.store,dict(id=p['panelId'],payload=json.dumps(p)))
        request=dict(version=1,action='submit',kind=protocol+'_apply',id=f'{number:032x}',count=len(p['resources'])+2,interval=1,
                     payload=json.dumps(p),fingerprint=preview['fingerprint'])
        self.assertEqual(self.store.request(request)['code'],'ok')
        return request

    def finish(self, request):
        for _ in range(8):
            self.store.tick()
            row=self.store.request(dict(version=1,action='status',id=request['id'],cursor=0))['jobs'][0]
            if row['status'] in ('succeeded','failed','partially_applied','cancelled'): return row
        self.fail('job did not finish')

    def test_public_state_waits_for_successful_final_job_verification(self):
        for number, protocol in enumerate(('vless', 'awg', 'tt'), 1):
            with self.subTest(protocol=protocol):
                module = {'vless': vless, 'awg': awg, 'tt': tt}[protocol]
                request = self.submit(self.payload(protocol), protocol, number)
                self.store.tick()
                self.store.tick()
                self.assertFalse(module.state(self.store, 'a'*32)[0]['confirmed'])
                self.assertEqual(self.finish(request)['status'], 'succeeded')
                self.assertTrue(module.state(self.store, 'a'*32)[0]['confirmed'])

    def test_vless_preserves_foreign_keys_settings_and_clients_then_revokes_only_ours(self):
        original=copy.deepcopy(self.api.rows[0]);p=self.payload('vless')
        self.assertEqual(self.finish(self.submit(p,'vless'))['status'],'succeeded')
        row=self.api.rows[0]
        for key in ('id','remark','streamSettings','sniffing','expiryTime'): self.assertEqual(row[key],original[key])
        self.assertEqual(row['settings']['fallbacks'],original['settings']['fallbacks'])
        self.assertIn(original['settings']['clients'][0],row['settings']['clients'])
        observed=vless.state(self.store,'a'*32)[0]
        self.assertTrue(observed['confirmed']);self.assertFalse(observed['proxy']['tls'])
        self.assertEqual(len(row['settings']['clients']),2)
        uuid=observed['clients'][0]['uuid'];p['users'][0]['enabled']=False
        self.assertEqual(self.finish(self.submit(p,'vless',2))['status'],'succeeded')
        self.assertEqual(self.api.rows[0]['settings']['clients'],original['settings']['clients'])
        p['users'][0]['enabled']=True
        self.assertEqual(self.finish(self.submit(p,'vless',3))['status'],'succeeded')
        self.assertEqual(vless.state(self.store,'a'*32)[0]['clients'][0]['uuid'],uuid)

    def test_vless_crash_after_api_write_recovers_without_duplicate(self):
        p=self.payload('vless');request=self.submit(p,'vless');self.store.tick();self.api.crash=True
        self.assertEqual(self.finish(request)['status'],'partially_applied')
        self.store.request(dict(version=1,action='resume',id=request['id']))
        self.assertEqual(self.finish(request)['status'],'succeeded')
        self.assertEqual(self.api.effects,1);self.assertEqual(len(self.api.rows),1)
        self.assertEqual(len(self.api.rows[0]['settings']['clients']),2)

    def test_awg_preserves_server_keys_hooks_and_peers_and_allocates_free_address(self):
        original=self.raw;p=self.payload('awg')
        self.assertEqual(self.finish(self.submit(p,'awg'))['status'],'succeeded')
        self.assertTrue(self.raw.startswith(original))
        result=awg.state(self.store,'a'*32)[0]
        self.assertTrue(result['confirmed']);self.assertEqual(result['clients'][0]['address'],'10.9.0.3')
        private=result['clients'][0]['privateKey'];p['users'][0]['enabled']=False
        self.assertEqual(self.finish(self.submit(p,'awg',2))['status'],'succeeded')
        self.assertEqual(self.raw.strip(),original.strip())
        p['users'][0]['enabled']=True
        self.assertEqual(self.finish(self.submit(p,'awg',3))['status'],'succeeded')
        self.assertEqual(awg.state(self.store,'a'*32)[0]['clients'][0]['privateKey'],private)

    def test_awg_does_not_allocate_outside_a_small_ipv6_pool(self):
        self.raw = self.raw.replace('Address = 10.9.0.1/24', 'Address = 10.9.0.1/24, fd00:9::1/126')
        self.raw = self.raw.replace('AllowedIPs = 10.9.0.2/32', 'AllowedIPs = 10.9.0.2/32, fd00:9::2/127')
        self.runtime = self.raw
        p = self.payload('awg')
        p['resources'][0]['pool6'] = 'fd00:9::/126'
        with self.assertRaises(VlessError) as failure:
            self.submit(p, 'awg')
        self.assertEqual(failure.exception.code, 'awg_pool_full')
        self.assertEqual(self.writes, 0)

    def test_awg_partial_file_write_resumes_syncconf(self):
        request=self.submit(self.payload('awg'),'awg');self.store.tick();self.lose_reply=True
        self.assertEqual(self.finish(request)['status'],'partially_applied')
        self.store.request(dict(version=1,action='resume',id=request['id']))
        self.assertEqual(self.finish(request)['status'],'succeeded')
        self.assertEqual(self.writes,1);self.assertTrue(awg.state(self.store,'a'*32)[0]['confirmed'])

    def test_tt_preserves_foreign_credentials_hosts_and_unit_and_revokes_only_ours(self):
        original=managed_tt.toml_loads(self.credentials);settings=self.settings;hosts=self.hosts;p=self.payload('tt')
        self.assertEqual(self.finish(self.submit(p,'tt'))['status'],'succeeded')
        result=managed_tt.toml_loads(self.credentials)
        self.assertEqual(result['title'],original['title']);self.assertIn(original['client'][0],result['client'])
        self.assertEqual(self.settings,settings);self.assertEqual(self.hosts,hosts)
        result=tt.state(self.store,'a'*32)[0];self.assertTrue(result['confirmed'])
        password=result['clients'][0]['password'];p['users'][0]['enabled']=False
        self.assertEqual(self.finish(self.submit(p,'tt',2))['status'],'succeeded')
        self.assertEqual(managed_tt.toml_loads(self.credentials),original)
        p['users'][0]['enabled']=True
        self.assertEqual(self.finish(self.submit(p,'tt',3))['status'],'succeeded')
        self.assertEqual(tt.state(self.store,'a'*32)[0]['clients'][0]['password'],password)

    def test_tt_partial_write_resumes_with_original_identity(self):
        request=self.submit(self.payload('tt'),'tt');self.store.tick();self.lose_reply=True
        self.assertEqual(self.finish(request)['status'],'partially_applied')
        self.store.request(dict(version=1,action='resume',id=request['id']))
        self.assertEqual(self.finish(request)['status'],'succeeded')
        self.assertEqual(self.writes,1)

    def test_tt_login_collision_preserves_foreign_account_and_uses_stable_personal_name(self):
        p=self.payload('tt');p['users'][0]['login']='FOREIGN'
        before=managed_tt.toml_loads(self.credentials)['client'][0]
        self.assertEqual(self.finish(self.submit(p,'tt'))['status'],'succeeded')
        self.assertIn(before,managed_tt.toml_loads(self.credentials)['client'])
        username=tt.state(self.store,'a'*32)[0]['clients'][0]['username']
        self.assertNotEqual(username.lower(),'foreign')
        self.assertEqual(self.finish(self.submit(p,'tt',2))['status'],'succeeded')
        self.assertEqual(tt.state(self.store,'a'*32)[0]['clients'][0]['username'],username)

    def test_drift_and_second_claim_are_rejected_without_effects(self):
        for number, protocol in enumerate(('vless','awg','tt'), 1):
            with self.subTest(protocol=protocol):
                p=self.payload(protocol)
                request=self.submit(p,protocol,number * 10)
                self.assertEqual(self.finish(request)['status'],'succeeded')
                candidate=copy.deepcopy(p);candidate['resources'][0]['id']='d'*32
                with self.assertRaises(VlessError): self.submit(candidate,protocol,9)
                if protocol=='vless': self.api.rows[0]['remark']='outside edit'
                elif protocol=='awg': self.raw += '# outside edit\n'
                else: self.credentials += '# outside edit\n'
                with self.assertRaises(VlessError): self.submit(p,protocol,10)

    def test_cancel_before_effect_does_not_claim(self):
        request=self.submit(self.payload('vless'),'vless')
        self.store.request(dict(version=1,action='cancel',id=request['id']))
        self.assertEqual(self.finish(request)['status'],'cancelled')
        self.assertEqual(self.api.effects,0);self.assertFalse(existing.records(self.store,'vless'))

    def test_reality_private_key_short_ids_and_transport_are_preserved(self):
        source=dict(network='tcp',security='reality',realitySettings=dict(
            privateKey='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
            shortIds=['0123456789abcdef',''],serverNames=['example.com','other.example.com'],
            target='example.com:443',minClientVer='1.0.0',settings=dict(
                publicKey='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
                serverName='other.example.com',fingerprint='firefox')))
        self.api.rows[0]['streamSettings']=copy.deepcopy(source)
        p=self.payload('vless');p['resources'][0]['security']='reality'
        self.assertEqual(self.finish(self.submit(p,'vless'))['status'],'succeeded')
        self.assertEqual(self.api.rows[0]['streamSettings'],source)
        exported=vless.state(self.store,'a'*32)[0]['proxy']
        self.assertEqual(exported['reality-opts']['short-id'],'0123456789abcdef')
        self.assertEqual(exported['reality-opts']['public-key'],'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB')
        self.assertEqual(exported['servername'],'other.example.com')
        self.assertEqual(exported['client-fingerprint'],'firefox')
        self.assertEqual(exported['flow'],'xtls-rprx-vision')
        self.assertNotIn('privateKey',vless.canonical(exported))

    def test_disabled_vless_keeps_foreign_access_and_disabled_state(self):
        self.api.rows[0]['enable']=False
        before=copy.deepcopy(self.api.rows[0]);p=self.payload('vless');p['resources'][0]['enabled']=False
        self.assertEqual(self.finish(self.submit(p,'vless'))['status'],'succeeded')
        self.assertFalse(self.api.rows[0]['enable'])
        self.assertEqual(self.api.rows[0]['settings'],before['settings'])
        self.assertFalse(vless.state(self.store,'a'*32)[0]['clients'][0]['enabled'])

    def test_stopped_tt_is_not_started_by_adoption(self):
        self.tt_active=False;p=self.payload('tt');p['resources'][0]['enabled']=False
        with patch('managed_tt.run') as run:
            self.assertEqual(self.finish(self.submit(p,'tt'))['status'],'succeeded')
        run.assert_not_called();self.assertFalse(self.tt_active)

    def test_cancelled_job_cannot_claim_and_changed_consent_cannot_overwrite(self):
        request=self.submit(self.payload('vless'),'vless');self.store.tick()
        self.api.rows[0]['settings']['clients'].append(dict(id='new-foreign',email='foreign2',enable=True))
        self.assertEqual(self.finish(request)['status'],'partially_applied')
        self.assertEqual(self.api.effects,0);self.assertFalse(existing.records(self.store,'vless'))

    def test_secret_loss_or_replacement_blocks_subsequent_changes(self):
        p=self.payload('vless')
        self.assertEqual(self.finish(self.submit(p,'vless'))['status'],'succeeded')
        before=self.api.effects
        (self.store.directory/'adopted-resources.key').write_bytes(bytes(32))
        with self.assertRaises(VlessError):self.submit(p,'vless',2)
        self.assertEqual(self.api.effects,before)

    def test_storage_crash_preserves_intent_and_replays_without_duplicate_effect(self):
        p=self.payload('vless');request=self.submit(p,'vless');self.store.tick()
        self.store.db.execute("CREATE TRIGGER fail BEFORE INSERT ON vless_resources BEGIN SELECT RAISE(ABORT,'fixture'); END")
        import sqlite3
        with self.assertRaises(sqlite3.Error):self.store.tick()
        self.store.db.execute('DROP TRIGGER fail');self.store.recover()
        self.assertEqual(self.finish(request)['status'],'succeeded')
        self.assertEqual(self.api.effects,1)

    def test_duplicate_sources_in_one_payload_are_rejected_before_effects(self):
        for protocol in ('vless','awg','tt'):
            p=self.payload(protocol);p['resources'].append({**p['resources'][0],'id':'f'*32})
            with self.subTest(protocol=protocol),self.assertRaises(VlessError):
                {'vless':vless,'awg':awg,'tt':tt}[protocol].parse_payload(json.dumps(p))
        self.assertEqual(self.api.effects+self.writes,0)

    def test_vless_deletion_succeeds_when_already_deleted_from_panel(self):
        p = self.payload('vless')
        self.assertEqual(self.finish(self.submit(p, 'vless'))['status'], 'succeeded')
        # Simulate panel row deleted externally (e.g. via 3x-ui inbound_remove)
        self.api.rows = []
        p['resources'][0]['deleted'] = True
        p['resources'][0]['enabled'] = False
        res = self.finish(self.submit(p, 'vless', 2))
        self.assertEqual(res['status'], 'succeeded')
        record = existing.records(self.store, 'vless')[p['resources'][0]['id']]
        self.assertTrue(record.get('deleted'))

    def test_deleted_vless_resource_does_not_conflict_with_new_adoption_of_same_source(self):
        p = self.payload('vless')
        self.assertEqual(self.finish(self.submit(p, 'vless'))['status'], 'succeeded')
        # Delete first resource
        self.api.rows = []
        p['resources'][0]['deleted'] = True
        p['resources'][0]['enabled'] = False
        self.assertEqual(self.finish(self.submit(p, 'vless', 2))['status'], 'succeeded')
        # Re-create panel row with same sourceId
        self.api.rows = [dict(id=7, protocol='vless', remark='New', enable=True,
            listen='127.0.0.1', port=24443, settings=dict(decryption='none', fallbacks=[],
            clients=[dict(id='22222222-2222-4222-8222-222222222222', email='newforeign', enable=True)]),
            streamSettings=dict(network='tcp', security='none'),
            sniffing=dict(enabled=False), expiryTime=0, total=0)]
        p2 = self.payload('vless')
        new_r = copy.deepcopy(p2['resources'][0])
        new_r['id'] = 'd'*32
        p2['resources'] = [p['resources'][0], new_r]
        res = self.finish(self.submit(p2, 'vless', 3))
        self.assertEqual(res['status'], 'succeeded')

    def test_unadopted_deleted_resource_does_not_conflict_with_plan(self):
        p = self.payload('vless')
        # Resource marked deleted without ever having been adopted in store.db
        p['resources'][0]['deleted'] = True
        p['resources'][0]['enabled'] = False
        res = self.finish(self.submit(p, 'vless', 1))
        self.assertEqual(res['status'], 'succeeded')

    def test_deleted_vless_resource_succeeds_when_panel_row_was_modified(self):
        p = self.payload('vless')
        self.assertEqual(self.finish(self.submit(p, 'vless'))['status'], 'succeeded')
        # Row modified in panel (remark or traffic counter)
        self.api.rows[0]['remark'] = 'modified_externally'
        p['resources'][0]['deleted'] = True
        p['resources'][0]['enabled'] = False
        res = self.finish(self.submit(p, 'vless', 2))
        self.assertEqual(res['status'], 'succeeded')
        record = existing.records(self.store, 'vless')[p['resources'][0]['id']]
        self.assertTrue(record.get('deleted'))

    def test_state_reconciles_externally_removed_adopted_inbound(self):
        p = self.payload('vless')
        self.assertEqual(self.finish(self.submit(p, 'vless'))['status'], 'succeeded')
        # Delete panel row externally
        self.api.rows = []
        st = vless.state(self.store, p['panelId'])
        self.assertEqual(len(st), 1)
        self.assertTrue(st[0]['confirmed'])
        self.assertTrue(st[0]['deleted'])
        self.assertFalse(st[0]['exists'])
        record = existing.records(self.store, 'vless')[p['resources'][0]['id']]
        self.assertTrue(record.get('deleted'))

    def test_apply_new_inbound_succeeds_when_old_adopted_inbound_was_externally_removed(self):
        from test_vless import spec
        p = self.payload('vless')
        self.assertEqual(self.finish(self.submit(p, 'vless'))['status'], 'succeeded')
        # Delete panel row externally
        self.api.rows = []
        # Submit plan with new inbound
        new_p = copy.deepcopy(p)
        new_p['resources'] = [spec(3)]
        with patch('vless.material', return_value=dict(privateKey='A'*43,publicKey='B'*43,shortId='0123456789abcdef')), \
             patch('vless.secret', side_effect=lambda label: hashlib.sha256(label.encode()).digest()), \
             patch('vless.command', return_value=b''):
            res = self.finish(self.submit(new_p, 'vless', 2))
        self.assertEqual(res['status'], 'succeeded')

    def test_deleted_adopted_inbound_updates_revision_in_subsequent_plan(self):
        from test_vless import spec
        p = self.payload('vless')
        self.assertEqual(self.finish(self.submit(p, 'vless'))['status'], 'succeeded')
        # Delete adopted inbound
        p['resources'][0]['deleted'] = True
        p['resources'][0]['enabled'] = False
        res1 = self.finish(self.submit(p, 'vless', 2))
        self.assertEqual(res1['status'], 'succeeded')
        record1 = existing.records(self.store, 'vless')[p['resources'][0]['id']]
        self.assertEqual(record1['revision'], vless.digest(p))

        # Subsequent plan adds a new inbound while retaining the deleted adopted inbound
        new_p = copy.deepcopy(p)
        new_p['resources'].append(spec(3))
        with patch('vless.material', return_value=dict(privateKey='A'*43,publicKey='B'*43,shortId='0123456789abcdef')), \
             patch('vless.secret', side_effect=lambda label: hashlib.sha256(label.encode()).digest()), \
             patch('vless.command', return_value=b''):
            res2 = self.finish(self.submit(new_p, 'vless', 3))
        self.assertEqual(res2['status'], 'succeeded')
        record2 = existing.records(self.store, 'vless')[p['resources'][0]['id']]
        self.assertEqual(record2['revision'], vless.digest(new_p))
        st = vless.state(self.store, p['panelId'])
        obs = {r['id']: r for r in st}
        self.assertEqual(obs[p['resources'][0]['id']]['revision'], vless.digest(new_p))
        self.assertTrue(obs[p['resources'][0]['id']]['confirmed'])

    def test_vless_state_does_not_mark_deleted_on_transient_panel_network_error(self):
        p = self.payload('vless')
        self.assertEqual(self.finish(self.submit(p, 'vless'))['status'], 'succeeded')
        rid = p['resources'][0]['id']
        saved = existing.records(self.store, 'vless')[rid]
        self.assertFalse(saved.get('deleted'))

        # Simulate transient network error during panel API call
        with patch.object(self.api, 'call', side_effect=OSError('Connection refused')):
            with self.assertRaises(OSError):
                existing.state(self.store, saved, 'vless')

        # Verify that the resource in store.db was NOT marked as deleted
        record = existing.records(self.store, 'vless')[rid]
        self.assertFalse(record.get('deleted'))

        # Simulate panel API 500 error / ValueError
        with patch.object(self.api, 'call', side_effect=ValueError('panel_api_failed')):
            with self.assertRaises(ValueError):
                existing.state(self.store, saved, 'vless')

        record = existing.records(self.store, 'vless')[rid]
        self.assertFalse(record.get('deleted'))

    def test_awg_state_does_not_mark_deleted_on_transient_io_error(self):
        p = self.payload('awg')
        self.assertEqual(self.finish(self.submit(p, 'awg'))['status'], 'succeeded')
        rid = p['resources'][0]['id']
        saved = existing.records(self.store, 'awg')[rid]
        self.assertFalse(saved.get('deleted'))

        # Simulate transient I/O error reading resource
        with patch('managed_awg.external.read_resource', side_effect=OSError('Disk I/O error')):
            with self.assertRaises(OSError):
                existing.state(self.store, saved, 'awg')

        # Verify record in store.db was NOT marked deleted
        record = existing.records(self.store, 'awg')[rid]
        self.assertFalse(record.get('deleted'))

    def test_tt_state_does_not_mark_deleted_on_transient_io_error(self):
        p = self.payload('tt')
        self.assertEqual(self.finish(self.submit(p, 'tt'))['status'], 'succeeded')
        rid = p['resources'][0]['id']
        saved = existing.records(self.store, 'tt')[rid]
        self.assertFalse(saved.get('deleted'))

        # Simulate transient I/O error reading snapshot
        with patch('managed_tt.external.snapshot', side_effect=OSError('Disk I/O error')):
            with self.assertRaises(OSError):
                existing.state(self.store, saved, 'tt')

        # Verify record in store.db was NOT marked deleted
        record = existing.records(self.store, 'tt')[rid]
        self.assertFalse(record.get('deleted'))
