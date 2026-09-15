import copy
import json
from pathlib import Path
import sys
import socket
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'server/runner'))
import tt
import tt_certificates as cert
import tt_common as common
import tt_external as external
from contract import validate_request
from runner import Store


def payload():
    return dict(version=1,protocol='tt',workspaceId='a'*32,panelId='a'*32,
        users=[dict(id='c'*32,login='alice',enabled=True),dict(id='d'*32,login='bob',enabled=True)],
        resources=[dict(id='b'*32,name='TT',enabled=True,deleted=False,listen='0.0.0.0',port=443,
            endpoint='203.0.113.1',externalPort=443,domain='vpn.example.com',certificateId='e'*32,
            quic=False,ipv6=False,allowPrivate=False,outbound='direct',socksAddress='127.0.0.1:1080',rotation=0)])


class TrustTunnelTests(unittest.TestCase):
    def test_defaults_use_https_ports_and_do_not_require_udp(self):
        for free, expected, probes in (([True],443,[443]),([False,True],8443,[443,8443]),([False,False],443,[443,8443])):
            with self.subTest(free=free),patch.object(tt,'prerequisites'),patch.object(tt,'available',side_effect=free) as probe:
                value=tt.defaults(None)
                self.assertEqual(value['port'],expected)
                self.assertEqual(value['externalPort'],expected)
                self.assertFalse(value['quic'])
                self.assertEqual([c.args for c in probe.call_args_list],[('0.0.0.0',p) for p in probes])

    def test_certificate_watcher_lock_queues_job_and_remains_cancellable(self):
        with tempfile.TemporaryDirectory() as d:
            s=Store(d)
            try:
                req=dict(version=1,action='submit',id='f'*32,kind='tt_apply',count=3,interval=1,payload=json.dumps(payload()),fingerprint='a'*64)
                self.assertEqual(s.request(req)['code'],'ok')
                with patch.object(tt.TtApply,'step',side_effect=tt.TtError('tt_busy')):
                    s.tick()
                row=s.db.execute('SELECT * FROM jobs').fetchone()
                self.assertEqual(row['status'],'running');self.assertEqual(row['checkpoint'],0)
                s.request(dict(version=1,action='cancel',id=req['id']));s.tick()
                self.assertEqual(s.db.execute('SELECT status FROM jobs').fetchone()[0],'cancelled')
            finally:s.close()

    def test_port_probe_rejects_listener_but_allows_tcp_time_wait(self):
        with socket.socket() as listener:
            listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
            listener.bind(('127.0.0.1',0));port=listener.getsockname()[1];listener.listen()
            self.assertFalse(common.available('127.0.0.1',port))
            with socket.create_connection(('127.0.0.1',port)) as client:
                connection,_=listener.accept();connection.close()
                self.assertEqual(client.recv(1),b'')
        self.assertTrue(common.available('127.0.0.1',port))

    def test_contract_and_invalid_endpoints(self):
        p=payload();tt.parse_payload(json.dumps(p))
        validate_request(dict(version=1,action='tt_plan',id='a'*32,payload=json.dumps(p)))
        for changes in ({'listen':'$(id)'},{'port':0},{'domain':'bad domain'},{'endpoint':'::'},
                        {'outbound':'socks5','socksAddress':'127.0.0.1:1;id'},{'deleted':True}):
            candidate=payload();candidate['resources'][0].update(changes)
            with self.subTest(changes=changes),self.assertRaises((tt.TtError,ValueError)):
                tt.parse_payload(json.dumps(candidate))

    def test_stable_distinct_passwords_revocation_and_explicit_rotation(self):
        p=payload();info=dict(domain='vpn.example.com',error=None)
        with tempfile.TemporaryDirectory() as d:
            key=Path(d)/'key';key.write_bytes(bytes(range(32)))
            with patch.object(tt,'KEY',key),patch.object(tt,'read',lambda p:Path(p).read_bytes()),patch.object(cert,'certificate_paths',return_value=('/cert','/key',info)),patch.object(cert,'inspect_pair'):
                before,data=tt.desired(p,p['resources'][0],None)
                self.assertNotEqual(before['clients'][0]['password'],before['clients'][1]['password'])
                p['resources'][0]['name']='Renamed';p['users'][0]['enabled']=False
                after,data=tt.desired(p,p['resources'][0],before)
                self.assertEqual([c['password'] for c in before['clients']],[c['password'] for c in after['clients']])
                self.assertNotIn(b'alice',data[2]);self.assertIn(b'bob',data[2])
                p['users'][1]['enabled']=False
                empty,data=tt.desired(p,p['resources'][0],after)
                sentinel=common.toml_loads(data[2].decode())['client']
                self.assertEqual(len(sentinel),1)
                self.assertEqual(sentinel[0]['username'],'_antirkn_no_clients')
                self.assertTrue(all(c['password']!=sentinel[0]['password'] for c in empty['clients']))
                self.assertTrue(data[2].startswith(b'[["client"]]'))
                p['resources'][0]['rotation']=1
                rotated,_=tt.desired(p,p['resources'][0],after)
                self.assertNotEqual(rotated['clients'][0]['password'],after['clients'][0]['password'])
                key.write_bytes(bytes(32))
                with self.assertRaises(tt.TtError): tt.desired(p,p['resources'][0],after)

    def test_toml_unknown_fields_roundtrip(self):
        value=common.toml_loads('title="unknown"\n[custom]\nwhen=1979-05-27T07:32:00Z\nvalues=[1,2]\n[[client]]\nusername="external"\npassword="fixture"\n[client.limits]\nbytes=42\n')
        self.assertEqual(common.toml_loads(common.toml_bytes(value).decode()),value)

    def test_existing_editor_preserves_unselected_hosts_unknown_fields(self):
        vpn=dict(listen_address='127.0.0.1:8443',credentials_file='custom-users.toml',rules_file='rules.toml',
            listen_protocols={'http2':{'max_concurrent_streams':42}},forward_protocol={'direct':{'unknown':9}},custom={'nested':[1,2]})
        hosts={'main_hosts':[dict(hostname='vpn.example.com',cert_chain_path='/cert',private_key_path='/key',extra='keep'),dict(hostname='other.example.com',cert_chain_path='/other',private_key_path='/other-key')],'ping_hosts':[{'custom':'keep'}]}
        changes=dict(listen='127.0.0.1',port=8443,quic=True,ipv6=False,allowPrivate=False,outbound='socks5',socksAddress='127.0.0.1:1080',hostIndex=0,domain='vpn.example.com',certificateId='')
        with patch.object(cert,'inspect_pair',return_value={'fingerprint':'f'*64}),patch.object(external,'check_socks'),patch.object(external,'available',return_value=True):
            a,b,_=external.patched({'changes':changes},{'active':False,'base':'/opt/trusttunnel','id':'b'*32},vpn,hosts)
        v,h=common.toml_loads(a.decode()),common.toml_loads(b.decode())
        self.assertEqual(v['custom'],vpn['custom']);self.assertEqual(v['credentials_file'],vpn['credentials_file'])
        self.assertEqual(v['listen_protocols']['http2'],vpn['listen_protocols']['http2'])
        self.assertEqual(h['main_hosts'][1],hosts['main_hosts'][1])
        self.assertEqual(h['main_hosts'][0]['extra'],'keep')
        self.assertEqual(h['ping_hosts'],hosts['ping_hosts'])

    def test_disable_expired_endpoint_keeps_credentials_revocable(self):
        p=payload();p['resources'][0]['enabled']=False
        with tempfile.TemporaryDirectory() as d:
            key=Path(d)/'key';key.write_bytes(bytes(32))
            with patch.object(tt,'KEY',key),patch.object(tt,'read',lambda p:Path(p).read_bytes()),patch.object(cert,'certificate_paths',return_value=('/cert','/key',dict(domain='vpn.example.com',error='tt_certificate_invalid'))),patch.object(cert,'inspect_pair') as inspect:
                tt.desired(p,p['resources'][0],None)
                inspect.assert_not_called()

    def test_enabling_quic_checks_only_new_udp_socket(self):
        p=payload();r=p['resources'][0];r['quic']=True
        old=dict(workspaceId=p['workspaceId'],spec=dict(r,quic=False))
        with patch.object(tt,'prerequisites',return_value='fixture'),patch.object(tt,'owned',return_value={r['id']:old}),patch.object(tt,'intact',return_value=True),patch.object(tt,'desired'),patch.object(cert,'record',return_value=dict(id=r['certificateId'],pairHash='fixture')),patch.object(tt,'active',return_value=True),patch.object(tt,'available',return_value=True) as port:
            tt.preflight(None,p)
            port.assert_called_once_with(r['listen'],r['port'],udp_only=True)

    def test_renewal_warning_does_not_invalidate_valid_served_certificate(self):
        saved={'spec':payload()['resources'][0]}
        with patch.object(tt,'intact',return_value=True),patch.object(tt,'active',return_value=True),patch.object(cert,'certificate_paths',return_value=('/cert','/key',dict(error='tt_acme_failed',fingerprint='f'*64))),patch.object(cert,'verify_service') as verify:
            self.assertTrue(tt.confirmed(saved))
            verify.assert_called_once()

    def test_dns_rejects_wrong_or_additional_aaaa_before_acme(self):
        p={'domain':'vpn.example.com','listen':'203.0.113.1','expectedIps':['203.0.113.1']}
        def result(value):return types.SimpleNamespace(returncode=0,stdout=json.dumps(value).encode())
        with patch.object(cert,'run',side_effect=[result(['203.0.113.1']),result([{'addr_info':[{'local':'203.0.113.1'}]}])]):
            self.assertEqual(cert.dns_check(p)['addresses'],['203.0.113.1'])
        for records in (['203.0.113.2'],['203.0.113.1','2001:db8::1']):
            with patch.object(cert,'run',return_value=result(records)),self.assertRaises(cert.TtError) as e:
                cert.dns_check(p)
            self.assertEqual(e.exception.code,'tt_dns_mismatch')

    def test_wildcard_dns_uses_selected_external_ips(self):
        p={'domain':'vpn.example.com','listen':'0.0.0.0','expectedIps':['203.0.113.1']}
        results=[types.SimpleNamespace(returncode=0,stdout=b'["203.0.113.1"]'),types.SimpleNamespace(returncode=0,stdout=b'[]')]
        with patch.object(cert,'run',side_effect=results):self.assertEqual(cert.dns_check(p)['expected'],p['expectedIps'])

    def test_stale_external_plan_rejected_without_writes(self):
        c=dict(listen='127.0.0.1',port=8443,quic=False,ipv6=False,allowPrivate=False,outbound='direct',socksAddress='127.0.0.1:1080',hostIndex=0,domain='vpn.example.com',certificateId='')
        req={'payload':json.dumps(dict(resourceId='b'*32,observedHash='a'*64,changes=c))}
        with patch.object(external,'snapshot',return_value=({},b'',b'',{},{},'b'*64)),patch.object(external,'patched') as edit,self.assertRaises(tt.TtError): external.plan(req)
        edit.assert_not_called()

    def test_activation_intent_resumes_restart_after_pointer_switch(self):
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory)/('e'*32);base.mkdir()
            (base/'pair-hash').mkdir();(base/'pair-hash/fullchain.pem').write_text('fixture');(base/'pair-hash/privkey.pem').write_text('fixture')
            (base/'current').symlink_to('pair-hash')
            service=dict(unit='trusttunnel.service',host='127.0.0.1',port=8443)
            (base/'activation.json').write_text(json.dumps(dict(before='old-pair',after='pair-hash',services=[service])))
            info=dict(domain='vpn.example.com',expiresAt=9999999999,notBefore=1,fingerprint='f'*64,pairHash='hash')
            p=dict(id='e'*32,mode='files',domain='vpn.example.com',certificate='/cert',privateKey='/key')
            with patch.object(cert,'CERT_ROOT',Path(directory)),patch.object(cert,'mkdir',lambda p:p.mkdir(parents=True,exist_ok=True)),patch.object(cert,'read',lambda p:Path(p).read_bytes()),patch.object(cert,'inspect_pair',return_value=info),patch.object(cert,'links',return_value=[]),patch.object(cert,'run') as run,patch.object(cert,'verify_service') as verify:
                cert.activate(p)
                run.assert_called_once_with(['/usr/bin/systemctl','restart','trusttunnel.service'],timeout=60)
                verify.assert_called_once()
                self.assertFalse((base/'activation.json').exists())
                run.reset_mock();cert.activate(p);run.assert_not_called()


if __name__=='__main__':unittest.main()
