import json
from pathlib import Path
import sys
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

