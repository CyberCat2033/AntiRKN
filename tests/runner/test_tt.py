import copy
import json
from pathlib import Path
import sys
import socket
import tempfile
import time
import types
import unittest
from unittest.mock import call, patch

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
        with patch.object(tt,'check_revocations'),patch.object(tt,'prerequisites',return_value='fixture'),patch.object(tt,'owned',return_value={r['id']:old}),patch.object(tt,'intact',return_value=True),patch.object(tt,'desired'),patch.object(cert,'record',return_value=dict(id=r['certificateId'],pairHash='fixture')),patch.object(tt,'active',return_value=True),patch.object(tt,'available',return_value=True) as port:
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

    def test_automatic_dns_uses_assigned_addresses_and_ssh_nat_hint(self):
        p=dict(domain='vpn.example.com',listen='0.0.0.0',expectedIps=[],autoDetectIps=True)
        def result(value):return types.SimpleNamespace(returncode=0,stdout=json.dumps(value).encode())
        local=[{'addr_info':[{'local':'203.0.113.1'},{'local':'2001:db8::1'},{'local':'127.0.0.1'},{'local':'fe80::1'}]}]
        for records in (['203.0.113.1'],['203.0.113.1','2001:db8::1']):
            with patch.object(cert,'run',side_effect=[result(records),result(local)]):
                self.assertEqual(cert.dns_check(p)['addresses'],sorted(records))
        for records in ([],['203.0.113.99'],['203.0.113.1','2001:db8::99'],['127.0.0.1']):
            with patch.object(cert,'run',side_effect=[result(records),result(local)]),self.assertRaises(cert.TtError) as error:
                cert.dns_check(p)
            self.assertEqual(error.exception.code,'tt_dns_mismatch')
        p['expectedIps']=['198.51.100.8']
        with patch.object(cert,'run',side_effect=[result(['198.51.100.8']),result([{'addr_info':[{'local':'10.0.0.5'}]}])]):
            self.assertEqual(cert.dns_check(p)['addresses'],['198.51.100.8'])

    def test_email_free_registration_and_existing_email_renewal(self):
        p=dict(id='a'*32,domain='vpn.example.com',mode='acme',listen='0.0.0.0',expectedIps=[],autoDetectIps=True,
            email='',certificate='',privateKey='',certificatePem='',privateKeyPem='')
        self.assertEqual(cert.decode(json.dumps(p)),p)
        with patch.object(cert,'dns_check'),patch.object(cert,'available',return_value=True),patch.object(cert,'run',return_value=types.SimpleNamespace(returncode=0)) as run:
            cert.issue(p)
            args=run.call_args.args[0]
            self.assertIn('--register-unsafely-without-email',args)
            self.assertNotIn('--email',args)
            old=dict(p,email='owner@example.com',expectedIps=['203.0.113.1'])
            del old['autoDetectIps']
            self.assertEqual(cert.decode(json.dumps(old)),old)
            cert.issue(old)
            self.assertIn('--email',run.call_args.args[0])
            cert.issue(p,renew=True)
            self.assertIn('renew',run.call_args.args[0])
            self.assertNotIn('--email',run.call_args.args[0])
        for value in ('bad-email','inject\n@example.com'):
            with self.assertRaises(cert.TtError):cert.decode(json.dumps(dict(p,email=value)))
        with self.assertRaises(cert.TtError):cert.decode(json.dumps(dict(p,autoDetectIps='true')))

    def test_issue_captures_certbot_stderr_and_classifies_errors(self):
        with tempfile.TemporaryDirectory() as d:
            cert_dir = Path(d)
            p = dict(id='b'*32, domain='vpn.example.com', mode='acme', listen='0.0.0.0', expectedIps=[], autoDetectIps=True,
                email='', certificate='', privateKey='', certificatePem='', privateKeyPem='')
            (cert_dir / ('b'*32)).mkdir(parents=True, exist_ok=True)
            with patch.object(cert, 'CERT_ROOT', cert_dir), patch.object(cert, 'dns_check'), patch.object(cert, 'available', return_value=True):
                # 1. Rate limited
                fail_res = types.SimpleNamespace(returncode=1, stdout=b'', stderr=b'An error occurred: rateLimited: too many certificates already issued for example.com')
                with patch.object(cert, 'run', return_value=fail_res):
                    with self.assertRaises(cert.TtError) as ctx:
                        cert.issue(p)
                    self.assertEqual(ctx.exception.code, 'tt_acme_rate_limited')
                err_file = cert_dir / ('b'*32) / 'last_error.log'
                self.assertTrue(err_file.exists())
                self.assertIn('rateLimited', err_file.read_text())

                # Verify public() surfaces errorDetail
                rec = dict(id='b'*32, domain='vpn.example.com', mode='acme', error='tt_acme_rate_limited', spec=p)
                pub = cert.public(rec)
                self.assertIn('rateLimited', pub.get('errorDetail', ''))

                # 2. DNS NXDOMAIN
                fail_dns = types.SimpleNamespace(returncode=1, stdout=b'', stderr=b'DNS problem: NXDOMAIN looking up A for vpn.example.com')
                with patch.object(cert, 'run', return_value=fail_dns):
                    with self.assertRaises(cert.TtError) as ctx:
                        cert.issue(p)
                    self.assertEqual(ctx.exception.code, 'tt_acme_dns_failed')
                self.assertIn('NXDOMAIN', err_file.read_text())

                # 3. Success clears last_error.log
                succ_res = types.SimpleNamespace(returncode=0, stdout=b'Congratulations!', stderr=b'')
                with patch.object(cert, 'run', return_value=succ_res):
                    cert.issue(p)
                self.assertFalse(err_file.exists())

    def test_certbot_install_uses_hardened_apt_job_and_verifies_binary(self):
        package = {'installed': False, 'version': None}
        installed = {'installed': True, 'version': 'certbot 2.9.0'}
        with patch.object(cert.Path, 'exists', return_value=False), \
                patch.object(cert, 'certbot_candidate', return_value='2.9.0-1'), \
                patch.object(cert, 'package_plan', return_value=installed), \
                patch.object(cert, 'apt_run') as apt_run:
            cert.install_certbot(package, 'a' * 32)
        self.assertEqual(apt_run.call_args_list, [
            call(
                ['-o', 'APT::Update::Error-Mode=any', 'update'],
                unit='antirkn-tt-certbot-' + 'a' * 32 + '-update',
            ),
            call(
                ['--assume-yes', '--no-install-recommends', 'install',
                 'certbot=2.9.0-1'],
                unit='antirkn-tt-certbot-' + 'a' * 32,
            ),
        ])

    def test_certbot_install_failure_is_reported_without_unsafe_retry(self):
        package = {'installed': False, 'version': '2.9.0-1'}
        with patch.object(cert.Path, 'exists', return_value=False), \
                patch.object(cert, 'apt_run', side_effect=cert.AptError()):
            with self.assertRaises(cert.TtError) as error:
                cert.install_certbot(package, 'a' * 32)
        self.assertEqual(error.exception.code, 'tt_certbot_required')

    def test_missing_certbot_is_planned_for_refresh_without_read_only_candidate(self):
        with patch.object(cert.Path, 'exists', return_value=False), \
                patch.object(cert, 'run') as run:
            self.assertEqual(cert.package_plan(),
                             {'installed': False, 'version': None})
        run.assert_not_called()

    def test_certbot_candidate_must_exist_after_index_refresh(self):
        result = types.SimpleNamespace(
            stdout=b'certbot:\n  Installed: (none)\n  Candidate: (none)\n')
        with patch.object(cert, 'run', return_value=result), \
                self.assertRaises(cert.TtError) as error:
            cert.certbot_candidate()
        self.assertEqual(error.exception.code, 'tt_certbot_required')

    def test_certbot_install_refreshes_an_old_planned_candidate(self):
        package = {'installed': False, 'version': '2.8.0-1'}
        installed = {'installed': True, 'version': 'certbot 2.9.0'}
        with patch.object(cert.Path, 'exists', return_value=False), \
                patch.object(cert, 'certbot_candidate', return_value='2.9.0-1'), \
                patch.object(cert, 'package_plan', return_value=installed), \
                patch.object(cert, 'apt_run') as apt_run:
            cert.install_certbot(package, 'a' * 32)
        self.assertEqual(apt_run.call_args_list, [
            call(
                ['-o', 'APT::Update::Error-Mode=any', 'update'],
                unit='antirkn-tt-certbot-' + 'a' * 32 + '-update',
            ),
            call(
                ['--assume-yes', '--no-install-recommends', 'install',
                 'certbot=2.9.0-1'],
                unit='antirkn-tt-certbot-' + 'a' * 32,
            ),
        ])

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


class NativeTtHost:
    def __init__(self):
        self.active = False
        self.calls = []
        self.fail = {}

    def run(self, argv, data=None, timeout=30, check=True):
        self.calls.append(argv)
        for needle, error in list(self.fail.items()):
            if needle in ' '.join(argv):
                del self.fail[needle]
                raise error
        if argv[1:2] == ['stop']:
            self.active = False
        elif argv[1:2] == ['restart']:
            self.active = True
        return types.SimpleNamespace(returncode=0, stdout=b'')

    def ran(self, verb):
        return [c for c in self.calls if c[1:2] == [verb]]


class NativeTtApplyTests(unittest.TestCase):
    """Restart only after a change, never a busy-port stop, undo on failure."""

    def setUp(self):
        from contextlib import ExitStack
        import hashlib
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        root = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        (root / 'tt').mkdir()
        (root / 'units').mkdir()
        self.store = Store(root)
        self.addCleanup(self.store.close)
        self.host = NativeTtHost()
        self.free = True
        def confirmed(saved, probe=True):
            r = saved['spec']
            return tt.intact(saved) and self.host.active == (r['enabled'] and not r['deleted'])
        info = dict(id='e' * 32, domain='vpn.example.com', fingerprint='f' * 64, pairHash='p')
        values = dict(ROOT=root / 'tt', KEY=root / 'tt/master.key', UNITS=root / 'units',
                      prerequisites=lambda: 'release', active=lambda unit: self.host.active, run=self.host.run,
                      available=lambda *a, **k: self.free, confirmed=confirmed, read=lambda p: Path(p).read_bytes(),
                      hash_file=lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest() if Path(p).exists() else None,
                      safe_path=lambda p, **k: Path(p))
        for name, value in values.items():
            self.stack.enter_context(patch.object(tt, name, value))
        for name, value in dict(certificate_paths=lambda cid: ('/cert', '/key', info), inspect_pair=lambda *a: info,
                                record=lambda cid: info, bind=lambda *a: None, unbind=lambda *a: None,
                                public=lambda r: {}).items():
            self.stack.enter_context(patch.object(cert, name, value))
        self.stack.enter_context(patch.object(common, 'STATE', root))

    def submit(self, p, number):
        preview = tt.plan(self.store, dict(id=p['workspaceId'], payload=json.dumps(p)))
        req = dict(version=1, action='submit', kind='tt_apply', id=f'{number:032x}', count=len(p['resources']) + 2,
                   interval=1, payload=json.dumps(p), fingerprint=preview['fingerprint'])
        self.assertEqual(self.store.request(req)['code'], 'ok')
        for _ in range(8):
            self.store.tick()
            row = self.store.request(dict(version=1, action='status', id=req['id'], cursor=0))['jobs'][0]
            if row['status'] not in ('planned', 'running'):
                return row['status'], req
        self.fail('job did not finish')

    def installed(self):
        p = payload()
        p['users'] = p['users'][:1]
        self.assertEqual(self.submit(p, 1)[0], 'succeeded')
        self.host.calls.clear()
        return p, [f.read_bytes() for f in tt.paths(p['resources'][0]['id'])[:3]]

    def test_credentials_change_restarts_once_without_stop_and_not_on_replay(self):
        p, _ = self.installed()
        p['users'] = payload()['users']
        status, req = self.submit(p, 2)
        self.assertEqual(status, 'succeeded')
        self.assertEqual((len(self.host.ran('restart')), self.host.ran('stop')), (1, []))
        # A worker crash after the restart, before the checkpoint: no restart.
        with self.store.db:
            self.store.db.execute("UPDATE jobs SET status='running', checkpoint=1 WHERE id=?", (req['id'],))
        self.host.calls.clear()
        tt.TtApply(self.store, req).step(1)
        self.assertEqual(self.host.ran('restart'), [])

    def test_busy_new_port_never_stops_the_working_endpoint(self):
        p, files = self.installed()
        p['resources'][0].update(port=8443, externalPort=8443)
        preview = tt.plan(self.store, dict(id=p['workspaceId'], payload=json.dumps(p)))
        self.free = False
        req = dict(version=1, action='submit', kind='tt_apply', id='2' * 32, count=3, interval=1,
                   payload=json.dumps(p), fingerprint=preview['fingerprint'])
        self.store.request(req)
        with patch.object(tt, 'preflight', return_value=dict(fingerprint=preview['fingerprint'])):
            for _ in range(4):
                self.store.tick()
        self.assertEqual(self.store.db.execute('SELECT status FROM jobs WHERE id=?', (req['id'],)).fetchone()[0], 'failed')
        self.assertEqual((self.host.ran('stop'), self.host.active), ([], True))
        self.assertEqual([f.read_bytes() for f in tt.paths(p['resources'][0]['id'])[:3]], files)

    def test_failed_restart_restores_files_and_old_service(self):
        p, files = self.installed()
        p['users'] = payload()['users']
        self.host.fail['restart'] = tt.TtError('tt_failed')
        self.assertEqual(self.submit(p, 2)[0], 'failed')
        self.assertEqual([f.read_bytes() for f in tt.paths(p['resources'][0]['id'])[:3]], files)
        self.assertEqual((len(self.host.ran('restart')), self.host.active), (2, True))
        self.assertFalse(list(self.store.directory.glob('tt-intent-*')))

    def test_watcher_lock_during_undo_finishes_the_undo_later_without_repeating_the_step(self):
        p, files = self.installed()
        p['users'] = payload()['users']
        self.host.fail['restart'] = tt.TtError('tt_failed')
        busy = [tt.TtError('tt_busy')]
        original = tt.TtApply.recover
        def recover(task, checkpoint):
            if busy:
                raise busy.pop()
            return original(task, checkpoint)
        steps = []
        original_step = tt.TtApply.step
        def step(task, checkpoint):
            steps.append(checkpoint)
            return original_step(task, checkpoint)
        with patch.object(tt.TtApply, 'recover', recover), patch.object(tt.TtApply, 'step', step):
            self.assertEqual(self.submit(p, 2)[0], 'failed')
        self.assertEqual(steps, [0, 1])  # Prepare and the failed step only.
        self.assertEqual([f.read_bytes() for f in tt.paths(p['resources'][0]['id'])[:3]], files)
        self.assertFalse(list(self.store.directory.glob('recover-*')))


class TtLockTests(unittest.TestCase):
    def test_locks_fail_closed_instead_of_running_unlocked(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            with patch.object(common, 'STATE', root / 'missing'):
                with self.assertRaises(common.TtError):
                    with common.lock():
                        pass
            target = root / 'credentials.toml'
            target.write_text('x')
            (root / 'elsewhere').write_text('root file')
            (root / 'credentials.toml.lock').symlink_to(root / 'elsewhere')
            with self.assertRaises(common.TtError):
                with common.file_lock(target):
                    pass
            with patch.object(common, 'STATE', root):
                with common.lock():
                    with common.lock():
                        pass


class TtVersionTests(unittest.TestCase):
    def test_external_service_accepts_supported_newer_releases(self):
        for output, ok in (('trusttunnel_endpoint 1.1.0', True), ('trusttunnel_endpoint 1.4.2\n', True),
                           ('trusttunnel_endpoint v1.10.0', True), ('trusttunnel_endpoint 1.0.9', False),
                           ('trusttunnel_endpoint 2.0.0', False), ('unknown', False)):
            with self.subTest(output=output):
                self.assertEqual(external.supported_version(output), ok)

    def test_discovery_walks_services_once_and_runs_version_once_per_binary(self):
        calls = []
        unit = 'trusttunnel.service'
        def run(argv, data=None, timeout=30, check=True):
            calls.append(argv)
            if argv[1] == 'show':
                return types.SimpleNamespace(returncode=0, stdout=('ExecStart={ path=/opt/tt/trusttunnel_endpoint ; argv[]=/opt/tt/trusttunnel_endpoint vpn.toml hosts.toml ; }\n'
                                                                   'WorkingDirectory=/opt/tt\nFragmentPath=/etc/systemd/system/' + unit + '\nActiveState=active\n').encode())
            return types.SimpleNamespace(returncode=0, stdout=b'trusttunnel_endpoint 1.2.0')
        files = {'/opt/tt/vpn.toml': b'listen_address="127.0.0.1:8443"\n', '/opt/tt/hosts.toml':
                 b'[[main_hosts]]\nhostname="vpn.example.com"\ncert_chain_path="/c"\nprivate_key_path="/k"\n',
                 '/etc/systemd/system/' + unit: b'[Service]\n'}
        stat = types.SimpleNamespace(st_uid=0, st_dev=1, st_ino=2, st_mtime_ns=3, st_size=4)
        with patch.object(external, 'run', side_effect=run), patch.object(external, 'candidates', return_value=[unit, 'other-trusttunnel.service']), \
                patch.object(external, 'safe_path', side_effect=lambda p, **k: Path(p)), patch.object(external.os, 'stat', return_value=stat), \
                patch.object(external.Path, 'stat', return_value=stat), patch.object(external.Path, 'resolve', lambda self, strict=False: self), \
                patch.object(external, 'read', side_effect=lambda p, owner=0: files[str(p)]):
            result = external.discovery()
        self.assertEqual(len(result['resources']), 2)
        self.assertEqual(len([c for c in calls if c[-1] == '--version']), 1)
        self.assertEqual(len([c for c in calls if c[1] == 'show']), 2)

    def test_absent_requires_missing_configs_and_unknown_unit(self):
        with tempfile.TemporaryDirectory() as d:
            source = dict(unit='trusttunnel.service', settings=str(Path(d) / 'vpn.toml'), hosts=str(Path(d) / 'hosts.toml'))
            gone = types.SimpleNamespace(returncode=0, stdout=b'not-found\n')
            loaded = types.SimpleNamespace(returncode=0, stdout=b'loaded\n')
            with patch.object(external, 'run', return_value=gone):
                self.assertTrue(external.absent(source))
                Path(source['hosts']).write_text('kept')
                self.assertFalse(external.absent(source))
                Path(source['hosts']).unlink()
            with patch.object(external, 'run', return_value=loaded):
                self.assertFalse(external.absent(source))
            self.assertFalse(external.absent(None))


class CertificateWatchTests(unittest.TestCase):
    def setUp(self):
        from contextlib import ExitStack
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.root = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        for name, value in dict(CERT_ROOT=self.root, mkdir=lambda p: p.mkdir(parents=True, exist_ok=True),
                                read=lambda p: Path(p).read_bytes(), source_path=lambda p: Path(p)).items():
            self.stack.enter_context(patch.object(cert, name, value))
        self.cid = 'e' * 32
        (self.root / self.cid).mkdir()
        self.source = self.root / 'source'
        self.source.mkdir()
        (self.source / 'fullchain.pem').write_text('chain')
        (self.source / 'privkey.pem').write_text('key')
        self.spec = dict(id=self.cid, mode='files', domain='vpn.example.com', listen='0.0.0.0', expectedIps=[], email='',
                         certificate=str(self.source / 'fullchain.pem'), privateKey=str(self.source / 'privkey.pem'))
        self.info = dict(domain='vpn.example.com', expiresAt=time.time() + 86400 * 30, notBefore=1, fingerprint='f' * 64, pairHash='hash')

    def test_unchanged_pair_skips_openssl_and_record_writes(self):
        with patch.object(cert, 'inspect_pair', return_value=self.info) as inspect, patch.object(cert, 'links', return_value=[]):
            saved = cert.activate(self.spec)
            self.assertTrue(inspect.called)
            self.assertEqual(saved['sourceStat'], cert.source_signature(self.source / 'fullchain.pem', self.source / 'privkey.pem'))
            inspect.reset_mock()
            before = cert.record_path(self.cid).stat().st_mtime_ns
            for _ in range(3):
                cert.check(cert.record(self.cid))
            inspect.assert_not_called()
            self.assertEqual(cert.record_path(self.cid).stat().st_mtime_ns, before)
            # A replaced source file is validated again.
            (self.source / 'fullchain.pem').write_text('renewed chain')
            cert.check(cert.record(self.cid))
            self.assertTrue(inspect.called)

    def test_successful_renewal_is_recorded_even_without_a_new_pair(self):
        spec = dict(self.spec, mode='acme')
        live = self.root / self.cid / 'acme/live/endpoint'
        live.mkdir(parents=True)
        (live / 'fullchain.pem').write_text('chain')
        (live / 'privkey.pem').write_text('key')
        with patch.object(cert, 'inspect_pair', return_value=self.info), patch.object(cert, 'links', return_value=[]):
            cert.activate(spec)
        now = time.time()
        with patch.object(cert, 'issue') as issue, patch.object(cert, 'inspect_pair') as inspect:
            cert.check(cert.record(self.cid), now)
            cert.check(cert.record(self.cid), now + 60)
        self.assertEqual(issue.call_count, 1)  # certbot runs twice a day, not each minute.
        inspect.assert_not_called()
        self.assertEqual(cert.record(self.cid)['lastRenewal'], now)

    def test_acme_failure_backs_off_instead_of_retrying_each_minute(self):
        spec = dict(self.spec, mode='acme')
        record = dict(id=self.cid, mode='acme', spec=spec, domain='vpn.example.com')
        now = 1000000.0
        with patch.object(cert, 'issue', side_effect=cert.TtError('tt_acme_failed')) as issue, \
                patch.object(cert, 'activate', side_effect=cert.TtError('tt_certificate_invalid')):
            cert.check(record, now)
            self.assertEqual(issue.call_count, 1)
            self.assertEqual(record['renewRetryAt'], now + 3600)
            self.assertEqual(record['error'], 'tt_certificate_invalid')
            for minute in range(1, 60):
                cert.check(record, now + 60 * minute)
            self.assertEqual(issue.call_count, 1)
            cert.check(record, now + 3600)
            self.assertEqual((issue.call_count, record['renewRetryAt']), (2, now + 3600 + 7200))
            record['renewFailures'] = 12
            cert.check(record, record['renewRetryAt'])
            self.assertEqual(record['renewRetryAt'] - record['lastCheck'], 86400)


class ExternalEditRecoveryTests(unittest.TestCase):
    def test_failed_external_edit_restores_files_links_and_service(self):
        changes = dict(listen='127.0.0.1', port=8443, quic=False, ipv6=False, allowPrivate=False, outbound='direct',
                       socksAddress='127.0.0.1:1080', hostIndex=0, domain='vpn.example.com', certificateId='')
        req = dict(id='1' * 32, payload=json.dumps(dict(resourceId='b' * 32, observedHash='a' * 64, changes=changes)))
        resource = dict(id='b' * 32, unit='trusttunnel.service', settings='/fixture/vpn.toml', hosts='/fixture/hosts.toml',
                        base='/fixture', ownerUid=0, active=True)
        before, after = ['listen_address="127.0.0.1:443"\n', 'h=1\n'], ['listen_address="127.0.0.1:8443"\n', 'h=2\n']
        links = [dict(cid='e' * 32, name='f' * 32 + '.json', data=dict(unit='trusttunnel.service', host='127.0.0.1', port=443))]
        for current, expected in ((after, 'failed'), (['foreign="edit"\n', 'h=2\n'], None)):
            with self.subTest(current=current), tempfile.TemporaryDirectory() as d:
                files = dict(zip((resource['settings'], resource['hosts']), current))
                calls = []
                def snapshot(rid, found=None):
                    return dict(resource, active=False), files[resource['settings']].encode(), files[resource['hosts']].encode(), {}, {}, 'x'
                def write(path, data, owner):
                    files[str(path)] = data.decode(); calls.append(('write', str(path)))
                store = Store(Path(d))
                try:
                    task = external.ExternalTtEdit(store, req)
                    task.backup.write_text(json.dumps(dict(resource=resource, before=before, after=after, certificate={},
                                                           source=None, links=links)))
                    with patch.object(common, 'STATE', Path(d)), patch.object(external, 'snapshot', side_effect=snapshot), \
                            patch.object(external, 'write_existing', side_effect=write), \
                            patch.object(external, 'read', side_effect=lambda p, owner=0: files[str(p)].encode() if str(p) in files else Path(p).read_bytes()), \
                            patch.object(external, 'run', side_effect=lambda argv, **k: calls.append(tuple(argv))), \
                            patch.object(external, 'active', return_value=True), \
                            patch.object(cert, 'restore_links', side_effect=lambda *a: calls.append(('links',) + a[:2])):
                        self.assertEqual(task.recover(1), expected)
                finally:
                    store.close()
                if expected:
                    self.assertEqual([files[resource['settings']], files[resource['hosts']]], before)
                    self.assertIn(('/usr/bin/systemctl', 'restart', 'trusttunnel.service'), calls)
                    self.assertIn(('links', 'trusttunnel.service', external.link_for(resource, changes)), calls)
                else:
                    self.assertEqual(calls, [])  # A foreign edit is never overwritten.


if __name__=='__main__':unittest.main()
