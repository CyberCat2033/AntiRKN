import hashlib
import json
import os
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
import awg
import awg_external


def payload():
    options = {k: v['default'] for k, v in awg.OPTIONS.items()}
    return dict(version=1, protocol='awg', workspaceId='a'*32, panelId='a'*32,
        users=[], resources=[dict(id='b'*32, name='AWG', enabled=True, deleted=False,
        endpoint='203.0.113.1', port=51820, externalPort=51820, pool='10.10.0.0/20',
        pool6='', mtu=1280, keepalive=25, options=options)])


class AwgTests(unittest.TestCase):
    def test_invalid_networks_and_obfuscation_rejected(self):
        awg.parse_payload(json.dumps(payload()))
        for changes in ({'pool': '127.0.0.0/24'}, {'pool': '10.10.0.1/20'},
                        {'pool6': '2001:db8::/64'}, {'endpoint': '::'}):
            p = payload(); p['resources'][0].update(changes)
            with self.subTest(changes=changes), self.assertRaises(awg.AwgError):
                awg.parse_payload(json.dumps(p))
        for key, value in [('s1', 13), ('jmin', 100), ('rekey-timeout', '7-3'), ('rekey-after-time', '180')]:
            p = payload(); p['resources'][0]['options'][key] = value
            with self.subTest(key=key), self.assertRaises(awg.AwgError):
                awg.parse_payload(json.dumps(p))

    def test_existing_edit_preserves_peers_hooks_unknown_fields(self):
        raw = b'[Interface]\n# existing comment\nPrivateKey = synthetic\nListenPort = 51820\nJc = 4\nUnknown = preserve\nPostUp = preserve-hook\n\n[Peer]\nPublicKey = synthetic-peer\nPresharedKey = synthetic-psk\nAllowedIPs = 10.0.0.2/32\n'
        edited = awg_external.patched(raw, {'Jc': '5'}, {'source': 'native'})
        self.assertEqual(edited, raw.replace(b'Jc = 4', b'Jc = 5'))
        for changes in ({'PrivateKey': 'replace'}, {'Jc': '5\nPostUp = command'}, {'S3': '12'}):
            with self.assertRaises(awg.AwgError):
                awg_external.patched(raw, changes, {'source': 'native'})
        with self.assertRaises(awg.AwgError) as error:
            awg_external.patched(raw, {'ListenPort': '51821'}, {'source': 'docker', 'portBindings': {'51820/udp': []}})
        self.assertEqual(error.exception.code, 'awg_port_mapping')

    def test_changed_master_key_never_silently_rotates_existing_identity(self):
        p = payload()
        with patch.object(awg, 'keys', return_value=('private', 'new-public')), patch.object(awg, 'derive', return_value=bytes(32)):
            with self.assertRaises(awg.AwgError) as error:
                awg.desired(p, p['resources'][0], {'publicKey': 'old-public', 'headerProtectionKey': 'old-header'})
        self.assertEqual(error.exception.code, 'awg_conflict')

    def test_defaults_do_not_mutate_and_avoid_reserved_ports(self):
        with patch.object(awg, 'prerequisites'), patch.object(awg, 'routes', return_value=[]), patch.object(awg, 'owned', return_value={}), patch.object(awg, 'free_port', side_effect=[False, True]) as port:
            result = awg.defaults(None)
        self.assertEqual(port.call_count, 2)
        self.assertTrue(49152 <= result['port'] <= 65535)
        self.assertEqual(result['endpoint'], '')
        self.assertEqual(result['port'], result['externalPort'])
        self.assertEqual(result['keepalive'], 0)
        result['endpoint'] = '203.0.113.1'
        p = payload(); p['resources'] = [result]
        awg.parse_payload(json.dumps(p))

    def test_in_process_x25519_key_derivation_without_subprocess(self):
        # Audit #17: X25519 key derivation runs in-process without spawning awg pubkey
        raw_key = b'12345678901234567890123456789012'
        pure_pub = awg._x25519_pure(raw_key)
        self.assertEqual(len(pure_pub), 32)
        curve_pub = awg._curve25519_pubkey(raw_key)
        import base64
        self.assertEqual(curve_pub, base64.b64encode(pure_pub).decode())
        with patch.object(awg, 'command') as mock_cmd:
            priv_b64, pub_b64 = awg.keys('test-label', preview=True)
            self.assertTrue(priv_b64)
            self.assertTrue(pub_b64)
            # Confirms subprocess command was NOT invoked
            mock_cmd.assert_not_called()


class NativeHost:
    """A fake systemd/AWG host for one native interface."""

    def __init__(self):
        self.active = False
        self.calls = []
        self.fail = {}

    def command(self, argv, timeout=30, input_data=None):
        self.calls.append(argv)
        for needle, error in list(self.fail.items()):
            if needle in ' '.join(argv):
                del self.fail[needle]
                raise error
        if argv[:2] == ['/usr/bin/systemctl', 'stop']:
            self.active = False
        elif argv[:3] == ['/usr/bin/systemctl', 'enable', '--now']:
            self.active = True
        return b''

    def ran(self, *words):
        return [c for c in self.calls if all(w in c for w in words)]


class NativeApplyTests(unittest.TestCase):
    """Precondition order, peer-only updates and undo of a failed step."""

    def setUp(self):
        from contextlib import ExitStack
        from runner import Store
        import tempfile
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        root = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        (root / 'awg').mkdir()
        self.store = Store(root)
        self.addCleanup(self.store.close)
        self.host = NativeHost()
        self.free = True
        def confirmed(saved, cache=None):
            r = saved['spec']
            expected = (None, None) if r['deleted'] else (saved['configHash'], saved['networkHash'])
            return awg.current_hashes(r['id']) == expected and self.host.active == (r['enabled'] and not r['deleted'])
        for name, value in dict(ROOT=root / 'awg', KEY=root / 'awg/master.key', prerequisites=lambda: 'release',
                                routes=lambda: [], active=lambda rid: self.host.active, command=self.host.command,
                                network_configure=lambda action, name: self.host.calls.append(['network', action]),
                                confirmed=confirmed, free_port=lambda port: self.free).items():
            self.stack.enter_context(patch.object(awg, name, value))

    def submit(self, p, number):
        preview = awg.plan(self.store, dict(id=p['workspaceId'], payload=json.dumps(p)))
        req = dict(version=1, action='submit', kind='awg_apply', id=f'{number:032x}', count=len(p['resources']) + 2,
                   interval=1, payload=json.dumps(p), fingerprint=preview['fingerprint'])
        self.assertEqual(self.store.request(req)['code'], 'ok')
        for _ in range(8):
            self.store.tick()
            row = self.store.request(dict(version=1, action='status', id=req['id'], cursor=0))['jobs'][0]
            if row['status'] not in ('planned', 'running'):
                return row['status']
        self.fail('job did not finish')

    def installed(self):
        p = payload()
        p['users'] = [dict(id='c' * 32, enabled=True)]
        self.assertEqual(self.submit(p, 1), 'succeeded')
        self.host.calls.clear()
        return p, awg.paths(p['resources'][0]['id'])[0].read_bytes()

    def test_busy_new_port_never_stops_the_working_interface(self):
        p, config = self.installed()
        p['resources'][0].update(port=51821, externalPort=51821)
        self.free = True
        preview = awg.plan(self.store, dict(id=p['workspaceId'], payload=json.dumps(p)))
        self.free = False  # Taken between plan and apply.
        req = dict(version=1, action='submit', kind='awg_apply', id='2' * 32, count=3, interval=1,
                   payload=json.dumps(p), fingerprint=preview['fingerprint'])
        self.store.request(req)
        with patch.object(awg, 'preflight', return_value=dict(fingerprint=preview['fingerprint'])):
            for _ in range(4):
                self.store.tick()
        self.assertEqual(self.store.db.execute('SELECT status FROM jobs WHERE id=?', (req['id'],)).fetchone()[0], 'failed')
        self.assertFalse(self.host.ran('stop'))
        self.assertTrue(self.host.active)
        self.assertEqual(awg.paths(p['resources'][0]['id'])[0].read_bytes(), config)

    def test_failed_restart_restores_the_previous_interface(self):
        p, config = self.installed()
        p['resources'][0]['mtu'] = 1300  # An interface change: full restart path.
        self.host.fail['enable --now'] = awg.PanelError('panel_api_failed')
        self.assertEqual(self.submit(p, 2), 'failed')
        self.assertEqual(awg.paths(p['resources'][0]['id'])[0].read_bytes(), config)
        self.assertTrue(self.host.active)
        self.assertEqual(len(self.host.ran('enable', '--now')), 2)  # Failed apply, then restore.
        self.assertFalse(list(self.store.directory.glob('awg-intent-*')))
        record = awg.owned(self.store)[p['resources'][0]['id']]
        self.assertEqual(record['configHash'], hashlib.sha256(config).hexdigest())
        self.assertEqual(self.submit(p, 3), 'succeeded')  # A new job still applies.

    def test_failed_undo_needs_attention(self):
        p, _ = self.installed()
        p['resources'][0]['mtu'] = 1300
        self.host.fail['enable --now'] = awg.PanelError('panel_api_failed')
        with patch.object(awg.AwgApply, 'recover', side_effect=awg.AwgError('awg_failed')):
            self.assertEqual(self.submit(p, 2), 'needs_attention')

    def test_peer_change_updates_live_interface_without_restart(self):
        p, _ = self.installed()
        p['users'].append(dict(id='d' * 32, enabled=True))
        self.assertEqual(self.submit(p, 2), 'succeeded')
        self.assertTrue(self.host.ran('syncconf'))
        self.assertFalse(self.host.ran('stop') or self.host.ran('enable'))
        stripped = self.host.ran('syncconf')
        self.assertTrue(stripped)

    def test_master_key_is_created_atomically_and_truncated_key_recovers_only_unused(self):
        key = awg.KEY
        key.write_bytes(b'')  # A power loss after the old non-atomic create.
        p, _ = self.installed()
        self.assertEqual(len(key.read_bytes()), 32)
        self.assertFalse([x for x in key.parent.iterdir() if x.name.endswith('.antirkn-tmp')])
        key.write_bytes(b'\x00' * 7)
        with self.assertRaises(ValueError):
            awg.create_key(key, in_use=True)  # Records exist: fail closed.
        self.assertEqual(key.read_bytes(), b'\x00' * 7)


class SharedHelperTests(unittest.TestCase):
    def test_create_key_never_replaces_and_rejects_links(self):
        import tempfile
        from awg_network import create_key
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'master.key'
            first = create_key(path, in_use=False)
            self.assertEqual(create_key(path, in_use=True), first)
            with self.assertRaises(ValueError):
                create_key(Path(d) / 'missing.key', in_use=True)
            link = Path(d) / 'link.key'
            link.symlink_to(path)
            with self.assertRaises(ValueError):
                create_key(link, in_use=False)

    def test_lock_files_fail_closed_on_links_fifos_and_hard_links(self):
        import tempfile
        from awg_network import open_lock
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            os.close(open_lock(root / 'ok.lock'))
            (root / 'target').write_text('root file')
            (root / 'link.lock').symlink_to(root / 'target')
            os.mkfifo(str(root / 'fifo.lock'))
            os.link(str(root / 'target'), str(root / 'hard.lock'))
            for name in ('link.lock', 'fifo.lock', 'hard.lock'):
                with self.subTest(name=name), self.assertRaises(OSError):
                    open_lock(root / name)

    def test_replace_preserving_keeps_mode(self):
        import tempfile
        from awg_network import replace_preserving
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'awg0.conf'
            path.write_text('old')
            path.chmod(0o640)
            replace_preserving(path, b'new')
            self.assertEqual((path.read_text(), path.stat().st_mode & 0o777), ('new', 0o640))
            self.assertEqual([p.name for p in Path(d).iterdir()], ['awg0.conf'])

    def test_native_external_write_rejects_writable_parent(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'awg0.conf'
            path.write_text('[Interface]\n')
            Path(d).chmod(0o777)
            with self.assertRaises(awg.AwgError):
                awg_external.write_file(dict(path=str(path)), b'changed')
            self.assertEqual(path.read_text(), '[Interface]\n')

    def test_firewall_listing_matches_reordered_rules_and_falls_back_to_check(self):
        listing = ('-P INPUT ACCEPT\n'
                   '-A INPUT -p udp -m udp --dport 51820 -m comment --comment antirkn-arbbbbbbbbbbbb -j ACCEPT\n'
                   '-A POSTROUTING -s 10.10.0.0/20 ! -o arbbbbbbbbbbbb -m comment --comment antirkn-arbbbbbbbbbbbb -j MASQUERADE\n')
        calls = []
        def run(argv, **kwargs):
            calls.append(argv)
            return types.SimpleNamespace(returncode=0 if '-S' in argv else 1, stdout=listing.encode())
        cache = {}
        with patch.object(awg.subprocess, 'run', side_effect=run):
            self.assertTrue(awg.rule_present('/usr/sbin/iptables', 'filter', 'INPUT', ['-p', 'udp', '--dport', '51820', '-m', 'comment', '--comment', 'antirkn-arbbbbbbbbbbbb', '-j', 'ACCEPT'], cache))
            self.assertTrue(awg.rule_present('/usr/sbin/iptables', 'filter', 'POSTROUTING', ['-s', '10.10.0.0/20', '!', '-o', 'arbbbbbbbbbbbb', '-m', 'comment', '--comment', 'antirkn-arbbbbbbbbbbbb', '-j', 'MASQUERADE'], cache))
            self.assertFalse(awg.rule_present('/usr/sbin/iptables', 'filter', 'INPUT', ['-p', 'udp', '--dport', '51821', '-m', 'comment', '--comment', 'antirkn-arbbbbbbbbbbbb', '-j', 'ACCEPT'], cache))
        self.assertEqual([c for c in calls if '-S' in c], [['/usr/sbin/iptables', '-w', '10', '-t', 'filter', '-S']])
        self.assertEqual(len([c for c in calls if '-C' in c]), 1)


class ExternalDiscoveryTests(unittest.TestCase):
    RAW = b'[Interface]\nPrivateKey = synthetic\nListenPort = 51820\nJc = 4\n'

    def test_discovery_scans_once_and_inspects_all_containers_in_one_call(self):
        ids = ['a' * 64, 'b' * 64]
        calls = []
        def run(argv, data=None, check=True):
            calls.append(argv)
            if argv[1] == 'ps':
                return types.SimpleNamespace(returncode=0, stdout='\n'.join(ids).encode())
            if argv[1] == 'inspect':
                return types.SimpleNamespace(returncode=0, stdout=json.dumps([
                    dict(Id=cid, Name='/amnezia-awg' + cid[0], Config=dict(Image='amneziavpn/amnezia-awg'),
                         HostConfig=dict(NetworkMode='bridge', PortBindings={})) for cid in ids]).encode())
            if 'showconf' in argv:
                return types.SimpleNamespace(returncode=0, stdout=self.RAW)
            if argv[-1] == '/opt/amnezia/awg/awg0.conf' or 'public-key' in argv:
                return types.SimpleNamespace(returncode=0, stdout=self.RAW)
            return types.SimpleNamespace(returncode=1, stdout=b'')
        with patch.object(awg_external.shutil, 'which', side_effect=lambda name: '/usr/bin/docker' if name == 'docker' else None), \
                patch.object(awg_external, 'run', side_effect=run):
            result = awg_external.discovery()
        self.assertEqual(len(result['resources']), 2)
        self.assertEqual(len([c for c in calls if c[1] == 'ps']), 1)
        self.assertEqual([c for c in calls if c[1] == 'inspect'], [['/usr/bin/docker', 'inspect', *ids]])

    def test_only_a_positively_gone_source_counts_as_absent(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'awg0.conf'
            path.write_text('x')
            self.assertFalse(awg_external.absent(dict(path=str(path), container=None, name='awgfixture0')))
            path.unlink()
            self.assertTrue(awg_external.absent(dict(path=str(path), container=None, name='awgfixture0')))
        listed = types.SimpleNamespace(returncode=0, stdout=('c' * 64 + '\n').encode())
        with patch.object(awg_external.shutil, 'which', return_value='/usr/bin/docker'), patch.object(awg_external, 'run', return_value=listed):
            # A stopped container is still listed by "ps -a": not absent.
            self.assertFalse(awg_external.absent(dict(path='/opt/amnezia/awg/awg0.conf', container='c' * 64, name='awg0')))
            self.assertTrue(awg_external.absent(dict(path='/opt/amnezia/awg/awg0.conf', container='d' * 64, name='awg0')))
        with patch.object(awg_external.shutil, 'which', return_value='/usr/bin/docker'), \
                patch.object(awg_external, 'run', return_value=types.SimpleNamespace(returncode=1, stdout=b'')):
            self.assertFalse(awg_external.absent(dict(path='/x', container='d' * 64, name='awg0')))
        self.assertFalse(awg_external.absent(None))

    def test_failed_external_edit_restores_config_and_live_peers(self):
        from runner import Store
        import tempfile
        state = dict(raw=self.RAW, runtime=self.RAW, writes=0)
        resource = dict(id='e' * 32, name='awg0', path='/fixture/awg0.conf', binary='awg', source='native', active=True)
        def read_resource(rid, resources=None):
            values, peers = awg_external.parse(state['raw'])
            return dict(resource), state['raw'], values, peers, awg_external.digest(dict(file=state['raw'].decode(), runtime=state['runtime'].decode()))
        def write(r, data):
            state['raw'] = data; state['writes'] += 1
        def execute(r, args, data=None, check=True):
            if 'syncconf' in args:
                if data and b'Jc = 5' in data:
                    raise awg.AwgError('awg_failed')  # The live update fails.
                state['runtime'] = data
            return types.SimpleNamespace(stdout=state['runtime'], returncode=0)
        with tempfile.TemporaryDirectory() as d, patch.object(awg_external, 'read_resource', side_effect=read_resource), \
                patch.object(awg_external, 'write_file', side_effect=write), patch.object(awg_external, 'read_file', side_effect=lambda r: state['raw']), \
                patch.object(awg_external, 'exec_resource', side_effect=execute):
            store = Store(Path(d))
            try:
                observed = read_resource('e' * 32)[4]
                payload = json.dumps(dict(resourceId='e' * 32, observedHash=observed, changes={'Jc': '5'}))
                fingerprint = awg_external.plan(dict(payload=payload))['fingerprint']
                req = dict(version=1, action='submit', kind='awg_external_edit', id='1' * 32, count=3, interval=1,
                           payload=payload, fingerprint=fingerprint)
                self.assertEqual(store.request(req)['code'], 'ok')
                for _ in range(4):
                    store.tick()
                status = store.db.execute('SELECT status FROM jobs').fetchone()[0]
            finally:
                store.close()
        self.assertEqual(status, 'failed')
        self.assertEqual(state['raw'], self.RAW)
        self.assertEqual(state['writes'], 2)
