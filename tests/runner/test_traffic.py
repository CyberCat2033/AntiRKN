import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
import traffic
from runner import Store

W, OTHER = 'a' * 32, 'f' * 32
NOV = time.mktime((2026, 11, 15, 12, 0, 0, 0, 0, 0)) - time.timezone
DEC = NOV + 30 * 86400


def save(store, table, rid, data):
    with store.db:
        store.db.execute('INSERT INTO %s VALUES (?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data' % table,
                         (rid, json.dumps(data)))


class FoldTests(unittest.TestCase):
    def test_first_reading_is_total_only_then_deltas_go_to_the_month(self):
        e = {}
        self.assertTrue(traffic.fold(e, ('1', 100, 10), NOV))
        self.assertEqual((e['t'], e['m']), ([100, 10], {}))
        traffic.fold(e, ('1', 150, 30), NOV + 60)
        self.assertEqual((e['t'], e['m']), ([150, 30], {'2026-11': [50, 20]}))
        traffic.fold(e, ('1', 160, 30), DEC)
        self.assertEqual(e['m'], {'2026-11': [50, 20], '2026-12': [10, 0]})

    def test_new_counter_of_a_known_resource_belongs_to_the_month(self):
        e = {}
        self.assertTrue(traffic.fold(e, ('1', 70, 7), NOV, known=True))
        self.assertEqual((e['t'], e['m']), ([70, 7], {'2026-11': [70, 7]}))

    def test_counter_restart_counts_the_whole_reading(self):
        e = {}
        traffic.fold(e, ('1', 1000, 1000), NOV)
        traffic.fold(e, ('1', 40, 2000), NOV + 60)  # Smaller download: restarted.
        self.assertEqual(e['m']['2026-11'], [40, 2000])
        traffic.fold(e, ('2', 5000, 5000), NOV + 120)  # New epoch, larger values.
        self.assertEqual(e['m']['2026-11'], [5040, 7000])
        self.assertEqual(e['t'], [6040, 8000])

    def test_unchanged_reading_does_not_rewrite(self):
        e = {}
        traffic.fold(e, (None, 5, 5), NOV)
        self.assertFalse(traffic.fold(e, (None, 5, 5), NOV + 60))
        self.assertTrue(traffic.fold(e, (None, 5, 5), NOV + 2 * 86400))  # Keeps "seen" fresh.

    def test_prune_keeps_twelve_months_and_forgets_long_unseen(self):
        ledger = {'a': {'s': DEC, 't': [9, 9], 'm': {'2025-12': [1, 1], '2025-11': [1, 1], '2026-12': [1, 1]}},
                  'b': {'s': DEC - 401 * 86400, 't': [1, 1], 'm': {}}}
        self.assertTrue(traffic.prune(ledger, DEC))
        self.assertEqual(list(ledger), ['a'])
        self.assertEqual(sorted(ledger['a']['m']), ['2026-12'])  # 2025-12 is 13 months back.
        self.assertEqual(ledger['a']['t'], [9, 9])


class ParseTests(unittest.TestCase):
    def test_metrics_per_user_directions_and_escapes(self):
        text = '\n'.join([
            '# HELP inbound_traffic_bytes_per_user bytes uploaded',
            'inbound_traffic_bytes_per_user{username="alice"} 100',
            'outbound_traffic_bytes_per_user{username="alice"} 900',
            'outbound_traffic_bytes_per_user{protocol_type="h2",username="b\\"o\\\\b"} 7 1700000000000',
            'inbound_traffic_bytes_per_user{username="b\\"o\\\\b"} 0',
            'outbound_traffic_bytes{protocol_type="h2"} 99999',
            'client_sessions_per_user{username="alice",protocol_type="h2"} 3'])
        self.assertEqual(traffic.parse_metrics(text), {'alice': [900, 100], 'b"o\\b': [7, 0]})

    def test_transfer_output(self):
        self.assertEqual(traffic.parse_transfer('K1=\t10\t20\nbad line\nK2=\t0\t5\n'),
                         {'K1=': (10, 20), 'K2=': (0, 5)})

    def test_metrics_address_is_loopback_and_per_endpoint(self):
        a, b = traffic.metrics_address('1' * 32), traffic.metrics_address('2' * 32)
        self.assertNotEqual(a, b)
        self.assertTrue(traffic.loopback(a[0]) and a[0].startswith('127.'))
        self.assertEqual(a, traffic.metrics_address('1' * 32))
        self.assertFalse(traffic.loopback('0.0.0.0') or traffic.loopback('10.0.0.1'))


class ReviewTests(unittest.TestCase):
    def test_one_direction_only_is_left_out(self):
        text = 'inbound_traffic_bytes_per_user{username="a"} 5\noutbound_traffic_bytes_per_user{username="b"} 1\ninbound_traffic_bytes_per_user{username="b"} 2\n'
        self.assertEqual(traffic.parse_metrics(text), {'b': [1, 2]})

    def test_damaged_entry_is_dropped_alone(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'traffic.json'
            good = dict(w=W, t=[1, 2], s=5, m={'2026-11': [1, 2]}, l=[1, 2])
            path.write_text(json.dumps(dict(version=1, entries={'vless/r/u': good, 'awg/r/u': None, 'tt/r/u': dict(t='x')},
                                            resources={'vless/r': 5, 'bad': 'x'})))
            path.chmod(0o600)
            entries, resources = traffic.load(path)
        self.assertEqual((list(entries), resources), (['vless/r/u'], {'vless/r': 5}))

    def test_live_resource_is_never_forgotten(self):
        old = DEC - 500 * 86400
        ledger = {'awg/r/u': dict(t=[9, 9], s=old, m={}), 'awg/gone/u': dict(t=[1, 1], s=old, m={})}
        seen = {'awg/r': old, 'awg/gone': old}
        traffic.prune(ledger, DEC, seen, {'awg/r'})
        self.assertEqual((list(ledger), list(seen)), (['awg/r/u'], ['awg/r']))

    def test_metrics_port_avoids_the_endpoint_port(self):
        self.assertEqual(traffic.metrics_address('1' * 32, 443)[1], 1987)
        self.assertEqual(traffic.metrics_address('1' * 32, 1987)[1], 1988)

    def test_redirect_and_error_status_are_not_followed(self):
        import http.server, threading

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(302); self.send_header('Location', 'http://192.0.2.1/metrics'); self.end_headers()

            def log_message(self, *args):
                pass
        server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            with self.assertRaises(traffic.Unavailable):
                traffic.fetch_metrics('127.0.0.1', server.server_address[1])
        finally:
            server.shutdown(); server.server_close()


class LedgerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = Store(self.root)
        self.panel = self.root / 'x-ui.db'
        db = sqlite3.connect(self.panel)
        db.execute('CREATE TABLE client_traffics (id INTEGER PRIMARY KEY, inbound_id INTEGER, email TEXT, up INTEGER, down INTEGER)')
        db.commit(); db.close()
        patcher = patch('panel_discovery.databases', lambda: [(self.panel, 'systemd')])
        patcher.start(); self.addCleanup(patcher.stop)
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(self.store.close)
        self.vless = 'b' * 32
        save(self.store, 'vless_resources', self.vless, dict(workspaceId=W, spec=dict(id=self.vless, enabled=True, deleted=False),
             clients=[dict(id='u1'), dict(id='u2')]))
        save(self.store, 'vless_resources', 'c' * 32, dict(workspaceId=W, spec=dict(id='c' * 32, enabled=True, deleted=False), clients=[]))

    def panel_rows(self, *rows):
        db = sqlite3.connect(self.panel)
        db.execute('DELETE FROM client_traffics')
        db.executemany('INSERT INTO client_traffics (id, inbound_id, email, up, down) VALUES (?,1,?,?,?)', rows)
        db.commit(); db.close()

    def user(self, result, protocol, rid, uid):
        r = next(r for r in result['resources'] if r['protocol'] == protocol and r['id'] == rid)
        return r, next((u for u in r['users'] if u['id'] == uid), None)

    def test_vless_from_panel_database_by_managed_email(self):
        email = 'ar_' + self.vless + '_'
        self.panel_rows((1, email + 'u1', 10, 100), (2, 'foreign@x', 5, 5), (3, 'ar_' + 'd' * 32 + '_u1', 7, 7))
        traffic.read(self.store, W, now=NOV)
        self.panel_rows((1, email + 'u1', 15, 300), (4, email + 'u2', 1, 2))
        result = traffic.read(self.store, W, now=NOV + 900)
        r, u1 = self.user(result, 'vless', self.vless, 'u1')
        self.assertEqual(r['state'], 'ok')
        self.assertEqual((u1['down'], u1['up'], u1['months']), (300, 15, [dict(month='2026-11', down=200, up=5)]))
        # u2 appeared after the resource was first read: its traffic is this month's.
        self.assertEqual(self.user(result, 'vless', self.vless, 'u2')[1]['months'], [dict(month='2026-11', down=2, up=1)])
        self.assertNotIn('c' * 32, [r['id'] for r in result['resources']])  # Internal inbound, no clients.
        # A deleted client row keeps the ledger; re-created it starts a new epoch.
        self.panel_rows((4, email + 'u2', 1, 2))
        traffic.read(self.store, W, now=NOV + 1800)
        self.panel_rows((5, email + 'u1', 1, 50), (4, email + 'u2', 1, 2))
        u1 = self.user(traffic.read(self.store, W, now=NOV + 2700), 'vless', self.vless, 'u1')[1]
        self.assertEqual(u1['months'], [dict(month='2026-11', down=250, up=6)])
        self.assertEqual(json.loads((self.root / 'traffic.json').read_text())['version'], 1)

    def test_workspace_filter_and_forgotten_resources(self):
        save(self.store, 'vless_resources', 'e' * 32, dict(workspaceId=OTHER, spec=dict(id='e' * 32, enabled=True, deleted=False),
             clients=[dict(id='u9')]))
        self.panel_rows((1, 'ar_' + self.vless + '_u1', 1, 1), (2, 'ar_' + 'e' * 32 + '_u9', 1, 1))
        traffic.read(self.store, W, now=NOV)
        ids = [r['id'] for r in traffic.read(self.store, W, now=NOV + 1)['resources']]
        self.assertEqual(ids, [self.vless])
        with self.store.db:
            self.store.db.execute('DELETE FROM vless_resources WHERE id=?', (self.vless,))
        result = traffic.read(self.store, W, now=NOV + 2)
        self.assertEqual([(r['id'], r['state']) for r in result['resources']], [(self.vless, 'gone')])
        self.assertEqual([r['id'] for r in traffic.read(self.store, OTHER, now=NOV + 3)['resources']], ['e' * 32])

    def test_unreadable_panel_disabled_and_tt_without_metrics(self):
        self.panel.unlink()
        save(self.store, 'awg_resources', '1' * 32, dict(workspaceId=W, spec=dict(id='1' * 32, enabled=False, deleted=False), clients=[]))
        tt_root = self.root / 'tt'
        (tt_root / ('2' * 32)).mkdir(parents=True)
        (tt_root / ('2' * 32) / 'vpn.toml').write_text('listen_address = "0.0.0.0:443"\n')
        save(self.store, 'tt_resources', '2' * 32, dict(workspaceId=W, spec=dict(id='2' * 32, enabled=True, deleted=False),
             clients=[dict(id='u1', username='alice')]))
        with patch('tt_common.ROOT', tt_root), patch('tt.ROOT', tt_root), patch('tt_common.read', lambda p, owner_uid=0: Path(p).read_bytes()):
            states = {r['protocol']: r['state'] for r in traffic.read(self.store, W, now=NOV)['resources']}
        self.assertEqual(states, {'vless': 'unavailable', 'awg': 'disabled', 'tt': 'off'})

    def test_tt_metrics_and_awg_transfer(self):
        tt_root = self.root / 'tt'
        (tt_root / ('2' * 32)).mkdir(parents=True)
        (tt_root / ('2' * 32) / 'vpn.toml').write_text('[metrics]\naddress = "127.0.0.1:1987"\nper_client_metrics = true\n')
        save(self.store, 'tt_resources', '2' * 32, dict(workspaceId=W, spec=dict(id='2' * 32, enabled=True, deleted=False),
             clients=[dict(id='u1', username='alice')]))
        save(self.store, 'awg_resources', '1' * 32, dict(workspaceId=W, spec=dict(id='1' * 32, enabled=True, deleted=False),
             clients=[dict(id='u1', publicKey='K1=')]))
        seen = []

        class Out:
            def __init__(self, data): self.stdout = data

        def run(argv, **kwargs):
            seen.append(argv)
            if argv[-1] == 'transfer':
                return Out(b'K1=\t500\t70\n')  # rx 500 from the client, tx 70 to it.
            return Out(b'inv-1\n')
        with patch('tt_common.ROOT', tt_root), patch('tt.ROOT', tt_root), patch('tt_common.read', lambda p, owner_uid=0: Path(p).read_bytes()), patch('sysutil.run', run), \
                patch.object(traffic, 'fetch_metrics', lambda host, port: {'alice': [900, 100]}) as _, \
                patch.object(traffic.Path, 'read_text', lambda self: '7\n'):
            result = traffic.read(self.store, W, now=NOV)
        tt_user = self.user(result, 'tt', '2' * 32, 'u1')[1]
        awg_user = self.user(result, 'awg', '1' * 32, 'u1')[1]
        self.assertEqual((tt_user['down'], tt_user['up']), (900, 100))
        self.assertEqual((awg_user['down'], awg_user['up']), (70, 500))
        self.assertTrue(any(a[-1] == 'transfer' for a in seen))

    def test_rpc_read_is_validated_and_answers(self):
        self.panel_rows((1, 'ar_' + self.vless + '_u1', 1, 2))
        response = self.store.request(dict(version=1, action='traffic_read', id=W))
        self.assertEqual(response['code'], 'ok')
        self.assertEqual(response['traffic']['resources'][0]['users'][0]['down'], 2)
        with self.assertRaises(ValueError):  # No workspace: rejected by the contract.
            self.store.request(dict(version=1, action='traffic_read'))

    def test_damaged_ledger_restarts_accounting(self):
        (self.root / 'traffic.json').write_text('{broken')
        (self.root / 'traffic.json').chmod(0o600)
        self.panel_rows((1, 'ar_' + self.vless + '_u1', 1, 2))
        self.assertEqual(traffic.read(self.store, W, now=NOV)['resources'][0]['users'][0]['down'], 2)


class TtConfigTests(unittest.TestCase):
    def test_managed_endpoint_enables_per_client_metrics_on_loopback(self):
        import tt
        import tt_certificates as cert
        from test_tt import payload
        p = payload()
        with tempfile.TemporaryDirectory() as d:
            key = Path(d) / 'key'; key.write_bytes(bytes(range(32)))
            info = dict(domain='vpn.example.com', error=None)
            with patch.object(tt, 'KEY', key), patch.object(tt, 'read', lambda p: Path(p).read_bytes()), \
                    patch.object(cert, 'certificate_paths', return_value=('/cert', '/key', info)), patch.object(cert, 'inspect_pair'):
                _, data = tt.desired(p, p['resources'][0], None)
        import tt_common
        metrics = tt_common.toml_loads(data[0].decode())['metrics']
        host, port = traffic.metrics_address(p['resources'][0]['id'], p['resources'][0]['port'])
        self.assertEqual(metrics, dict(address='%s:%d' % (host, port), request_timeout_secs=3, per_client_metrics=True))
        self.assertTrue(traffic.loopback(host))
        p['resources'][0]['allowPrivate'] = True
        with tempfile.TemporaryDirectory() as d:
            key = Path(d) / 'key'; key.write_bytes(bytes(range(32)))
            with patch.object(tt, 'KEY', key), patch.object(tt, 'read', lambda p: Path(p).read_bytes()), \
                    patch.object(cert, 'certificate_paths', return_value=('/cert', '/key', info)), patch.object(cert, 'inspect_pair'):
                _, data = tt.desired(p, p['resources'][0], None)
        self.assertNotIn('metrics', tt_common.toml_loads(data[0].decode()))


if __name__ == '__main__':
    unittest.main()
