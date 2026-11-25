import copy
import json
from pathlib import Path
import socket
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
import client_egress as e
import egress_config as c
import egress_access as a
import egress_network as n
import vless
from runner import Store

LINK = 'vless://11111111-2222-4333-8444-555555555555@exit.example:443?type=tcp&security=reality&pbk=' + 'a' * 43 + '&sid=abcd&flow=xtls-rprx-vision#Exit'


class LinkTests(unittest.TestCase):
    def test_reality_tcp_and_ipv6_xhttp_tls(self):
        value = c.parse_link(LINK)
        self.assertEqual(value['outbound']['streamSettings']['network'], 'raw')
        self.assertEqual(value['name'], 'Exit')
        link = 'vless://11111111-2222-4333-8444-555555555555@[2001:db8::1]:8443?type=xhttp&security=tls&path=%2Fbridge&mode=packet-up&sni=exit.example'
        value = c.parse_link(link)
        self.assertEqual(value['host'], '2001:db8::1')
        self.assertEqual(value['outbound']['streamSettings']['xhttpSettings']['path'], '/bridge')

    def test_explicit_default_share_link_options(self):
        self.assertEqual(c.parse_link(LINK.replace('#Exit', '&headerType=none&allowInsecure=0#Exit')), c.parse_link(LINK))
        for value in ('http', ''):
            with self.assertRaises(c.EgressError): c.parse_link(LINK.replace('#Exit', '&headerType=' + value))

    def test_invalid_or_unimplemented_options_are_not_silently_dropped(self):
        for link in [LINK + '\n', LINK.replace('exit.example', '127.0.0.1'), LINK.replace('security=reality', 'security=none'),
                     LINK.replace('type=tcp', 'type=invalid'), LINK.replace('sid=abcd', 'sid=abc'),
                     LINK.replace('&sid=abcd', '&sid=abcd&sid=beef'), LINK.replace('type=tcp', 'type=xhttp'),
                     LINK.replace('#Exit', '&allowInsecure=1'), LINK.replace('#Exit', '&unknown=1'),
                     LINK.replace('#Exit', '&path=%2F'), LINK.replace('11111111-2222-4333-8444-555555555555', 'wrong')]:
            with self.subTest(link=link), self.assertRaises(c.EgressError): c.parse_link(link)

    def test_existing_routing_and_outbounds_survive_round_trip(self):
        before = dict(inbounds=[dict(tag='api', port=4000)], outbounds=[dict(tag='direct', protocol='freedom')],
                      routing=dict(domainStrategy='AsIs', rules=[dict(type='field', inboundTag=['api'], outboundTag='api')]),
                      dns=dict(servers=['1.1.1.1']))
        configured, owned = c.configure(before, c.parse_link(LINK), 1080, 1081)
        self.assertEqual(configured['routing']['rules'][:-1], before['routing']['rules'])
        self.assertEqual(configured['routing']['rules'][-1], dict(type='field', network='tcp,udp', outboundTag=c.TAG))
        self.assertEqual(configured['inbounds'][1]['listen'], '127.0.0.1')
        self.assertEqual(configured['inbounds'][1]['settings']['auth'], 'noauth')
        self.assertNotIn('clients', configured['inbounds'][1]['settings'])
        configured['dns']['servers'].append('9.9.9.9')
        restored, _ = c.configure(configured, None, 1080, 1081, owned)
        before['dns']['servers'].append('9.9.9.9')
        self.assertEqual(restored, before)

    def test_owned_entry_drift_never_deletes_foreign_configuration(self):
        template, owned = c.configure({}, c.parse_link(LINK), 1080, 1081)
        template['outbounds'][0]['settings']['changed'] = True
        with self.assertRaises(c.EgressError): c.remove_owned(template, owned)
        with self.assertRaises(c.EgressError): c.configure(dict(outbounds=[dict(tag=c.TAG)]), c.parse_link(LINK), 1080, 1081)


class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = Store(self.root)
        self.config = dict(inbounds=[], outbounds=[dict(tag='direct', protocol='freedom')], routing=dict(rules=[]))
        self.api = object()
        self.networks = []
        self.stack = []
        self.mock(e, 'STATE', self.root / 'state.json')
        self.mock(e, 'safe_file', lambda *args: None)
        self.mock(e, 'panel_for', lambda *args: self.api)
        self.mock(e, 'read_template', lambda api: (copy.deepcopy(self.config), 'https://test.example/'))
        self.mock(e, 'write_template', self.write)
        self.mock(e, 'inventory', lambda store: dict(interfaces=['awg0'], tt=[]))
        self.mock(e, 'configure_network', lambda info, previous=None: self.networks.append(info['enabled']))
        self.mock(e, 'choose_port', lambda preferred, occupied=(): 1080 if not occupied else 1081)
        self.mock(n, 'check_reservations', lambda *args: None)
        self.mock(n, 'intact', lambda *args: None)
        self.mock(n, 'run', lambda *args: type('Result', (), dict(stdout=b'[]'))())
        self.mock(socket, 'getaddrinfo', lambda *args, **kwargs: [(None, None, None, None, ('192.0.2.20', 443))])
        self.mock(e.probe, 'validate', lambda *args: None)
        self.mock(e.probe, 'outbound', lambda *args: dict(tcp=True, udp=True))
        self.mock(e.probe, 'check', lambda *args: dict(tcp=True, udp=True))

    def mock(self, module, name, value):
        obj = patch.object(module, name, value); obj.start(); self.stack.append(obj)

    def tearDown(self):
        for obj in reversed(self.stack): obj.stop()
        self.store.close(); self.temp.cleanup()

    def write(self, api, config, url): self.config = copy.deepcopy(config)

    def request(self, key, enabled=True):
        p = dict(panelId='a' * 32, enabled=enabled, uri=LINK if enabled else '', socksPort=0, observedHash=e.public()['observedHash'])
        req = dict(version=1, action='submit', id=key * 32, kind='egress_apply', count=3, interval=1, payload=json.dumps(p))
        req['fingerprint'] = e.plan(self.store, req)['fingerprint']
        self.assertEqual(self.store.request(req)['code'], 'ok')
        return req

    def finish(self, req):
        for _ in range(5): self.store.tick()
        return self.store.request(dict(version=1, action='status', id=req['id'], cursor=0))['jobs'][0]

    def test_success_disable_and_repeated_submission(self):
        before = copy.deepcopy(self.config)
        req = self.request('b')
        self.assertEqual(self.finish(req)['status'], 'succeeded')
        self.assertTrue(e.public()['enabled'])
        self.assertEqual(self.store.request(req)['jobs'][0]['status'], 'succeeded')
        self.assertEqual(self.finish(self.request('c', False))['status'], 'succeeded')
        self.assertFalse(e.public()['enabled'])
        self.assertEqual(before, self.config)
        self.assertEqual(self.networks, [True, False])

    def test_udp_failure_before_mutations_keeps_old_configuration(self):
        req = self.request('b')
        before = copy.deepcopy(self.config)
        with patch.object(e.probe, 'outbound', side_effect=c.EgressError('egress_probe_failed')):
            self.assertEqual(self.finish(req)['status'], 'failed')
        self.assertEqual(self.config, before)
        self.assertFalse(e.STATE.exists())
        self.assertFalse(self.networks)

    def test_failure_after_panel_switch_restores_previous_exit(self):
        req = self.request('b')
        before = copy.deepcopy(self.config)
        with patch.object(e.probe, 'check', side_effect=c.EgressError('egress_probe_failed')):
            self.assertEqual(self.finish(req)['status'], 'failed')
        self.assertEqual(self.config, before)
        self.assertFalse(e.public()['enabled'])

    def test_worker_replay_after_effect_before_checkpoint(self):
        req = self.request('b')
        task = e.EgressApply(self.store, req)
        task.step(0); task.step(1)
        with self.store.db: self.store.db.execute('UPDATE jobs SET checkpoint=1 WHERE id=?', (req['id'],))
        self.assertEqual(self.finish(req)['status'], 'succeeded')
        self.assertEqual(len(self.config['outbounds']), 2)
        self.assertEqual(len(self.config['inbounds']), 3)

    def test_changed_state_or_panel_between_plan_and_apply_is_rejected(self):
        req = self.request('b')
        self.config['routing']['rules'].append(dict(outboundTag='direct', network='tcp'))
        self.assertEqual(self.finish(req)['status'], 'failed')
        self.assertFalse(e.STATE.exists())

    def test_external_tt_added_after_activation_preserves_original_on_replay(self):
        self.finish(self.request('b'))
        original = dict(socks5=dict(address='127.0.0.1:9000', extended_auth=True))
        e.remember_tt_forward('/fixture/vpn.toml', original)
        e.remember_tt_forward('/fixture/vpn.toml', e.forward(1080))
        self.assertEqual(e.load()['ttOriginal']['/fixture/vpn.toml'], original)

    def test_new_tt_writer_inherits_common_exit_without_changing_clients(self):
        self.finish(self.request('b'))
        vpn = dict(forward_protocol={'direct': {}}, credentials_file='/private/credentials')
        e.effective_forward(vpn)
        self.assertEqual(vpn['forward_protocol'], e.forward(1080))
        self.assertEqual(vpn['credentials_file'], '/private/credentials')


class NetworkTests(unittest.TestCase):
    def test_network_rules_only_intercept_vpn_ingress_and_never_output(self):
        calls = []
        def run(args, check=True):
            calls.append(args)
            return type('Result', (), dict(returncode=1 if '-C' in args or '-S' in args else 0, stdout=b'[]'))()
        def restore(args, **kwargs):
            calls.append(args + [kwargs['input'].decode()])
            return type('Result', (), dict(returncode=0))()
        with patch.object(n, 'run', run), patch.object(n.subprocess, 'run', restore):
            n.configure(['awg0'], 1081)
        self.assertFalse(any('OUTPUT' in x for call in calls for x in call))
        hooks = [call for call in calls if 'PREROUTING' in call or 'FORWARD' in call or 'INPUT' in call]
        self.assertTrue(hooks)
        self.assertTrue(all('-i' in call and call[call.index('-i') + 1] == 'awg0' for call in hooks))
        self.assertTrue(any('TPROXY' in part for call in calls for part in call))
        with self.assertRaises(c.EgressError): n.validate_interfaces(['eth0; anything'])

    def test_server_addresses_and_private_ranges_bypass_tproxy(self):
        restores = []
        def run(args, check=True):
            return type('Result', (), dict(returncode=1 if '-C' in args or '-S' in args else 0, stdout=b'[]'))()
        def restore(args, **kwargs):
            restores.append((args[0], kwargs['input'].decode().splitlines()))
            return type('Result', (), dict(returncode=0))()
        with patch.object(n, 'run', run), patch.object(n.subprocess, 'run', restore):
            n.configure(['awg0'], 1081)
            n.configure(['awg0'], 1081)  # Idempotent: the chain is rebuilt.
        self.assertEqual(len(restores), 4)
        for binary, lines in restores:
            self.assertEqual(lines.count('-F ' + n.CHAIN), 1)
            body = [line for line in lines if line.startswith('-A ')]
            first = next(i for i, line in enumerate(body) if 'TPROXY' in line)
            bypass = body[:first]
            self.assertIn('-A %s -m addrtype --dst-type LOCAL -j RETURN' % n.CHAIN, bypass)
            ranges = ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '127.0.0.0/8', '169.254.0.0/16', '100.64.0.0/10') \
                if binary.endswith('/iptables-restore') else ('fc00::/7', 'fe80::/10', '::1/128')
            for network in ranges:
                self.assertIn('-A %s -d %s -j RETURN' % (n.CHAIN, network), bypass)
            self.assertEqual(body[-1], '-A %s -j DROP' % n.CHAIN)

    def test_intact_requires_the_bypass_rules(self):
        missing = '-A %s -m addrtype --dst-type LOCAL -j RETURN' % n.CHAIN
        def run(args, check=True):
            line = ' '.join(['-A', *args[args.index('-C') + 1:]]) if '-C' in args else ''
            if line == missing:
                return type('Result', (), dict(returncode=1, stdout=b''))()
            if 'rule' in args:
                return type('Result', (), dict(returncode=0, stdout=json.dumps([dict(priority=int(n.PRIORITY), table=n.TABLE, fwmark=n.MARK)]).encode()))()
            if 'route' in args:
                return type('Result', (), dict(returncode=0, stdout=json.dumps([dict(type='local', dst='default', dev='lo')]).encode()))()
            return type('Result', (), dict(returncode=0, stdout=b''))()
        with patch.object(n, 'run', run), self.assertRaises(c.EgressError):
            n.intact(dict(interfaces=['awg0'], transparentPort=1081))


class ServiceAccessTests(unittest.TestCase):
    def test_service_clients_require_both_registered_uuid_and_email(self):
        client = dict(id='fixture-uuid', email='ar_egress_fixture', enable=True)
        row = dict(id=3, settings=json.dumps(dict(clients=[client,
            dict(id='foreign', email='ar_egress_fixture'), dict(id='fixture-uuid', email='foreign')])) )
        with patch.object(a, 'records', return_value=[dict(inboundId=3, client=client)]):
            self.assertEqual(a.clients_for(row), [client])
            self.assertEqual(a.clients_for({**row, 'id': 4}), [])

    def test_removal_of_panel_is_blocked_while_client_exit_is_active(self):
        import protocol_remove
        with patch.object(e, 'load', return_value=dict(enabled=True)), patch.object(protocol_remove, 'discover') as discover:
            with self.assertRaises(protocol_remove.RemovalError) as error: protocol_remove.plan('vless')
            self.assertEqual(error.exception.code, 'egress_disable_first')
            discover.assert_not_called()

    def test_interrupted_service_access_can_remove_only_its_own_client(self):
        from observed_inbounds import object_field
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); store = Store(root)
            original = dict(id=1, protocol='vless', remark='fixture', settings=json.dumps(dict(clients=[dict(id='foreign', email='other')])) )
            client = dict(id='service', email='ar_egress_one', enable=True)
            current = {**original, 'settings': json.dumps(dict(clients=[dict(id='foreign', email='renamed'), client]))}
            class API:
                def call(self, path, value=None):
                    nonlocal current
                    if '/get/' in path: return copy.deepcopy(current)
                    if '/update/' in path: current = copy.deepcopy(value)
            req = dict(id='a' * 32, payload='{}')
            task = a.AccessApply(store, req)
            task.intent.write_text(json.dumps(dict(panelId='b' * 32, inboundId=1, key='c' * 64,
                client=client, previous=None, before=original)))
            with patch.object(a, 'ROOT', root), patch.object(a, 'safe_file', lambda *args: None), patch.object(vless, 'panel_for', return_value=API()):
                task.rollback()
            self.assertEqual(object_field(current['settings'])['clients'], [dict(id='foreign', email='renamed')])
            store.close()


if __name__ == '__main__': unittest.main()
