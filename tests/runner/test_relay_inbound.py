import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
import client_egress
import egress_access as access
import egress_config
import egress_probe
import panel_api
import relay_inbound as relay
import vless
from observed_inbounds import object_field
from runner import Store

PANEL = 'a' * 32
EXIT = 'vless://11111111-2222-4333-8444-555555555555@exit.example:443?type=tcp&security=reality&pbk=' + 'a' * 43 + '&sid=abcd&flow=xtls-rprx-vision#Exit'
TEMPLATE = dict(
    inbounds=[dict(tag='api', listen='127.0.0.1', port=62789, protocol='dokodemo-door')],
    outbounds=[dict(tag='direct', protocol='freedom'), dict(tag='blocked', protocol='blackhole')],
    routing=dict(rules=[dict(type='field', inboundTag=['api'], outboundTag='api'),
                        dict(type='field', ip=['geoip:private'], outboundTag='blocked')]))


def inbound_row(inbound_id, port, security='tls', remark='servers'):
    stream = dict(network='tcp', security=security)
    if security == 'tls':
        stream['tlsSettings'] = dict(serverName='relay.example', alpn=['h2'])
    return dict(id=inbound_id, protocol='vless', enable=True, remark=remark, listen='', port=port,
                tag='inbound-%d' % port, expiryTime=0, sniffing='{}', streamSettings=json.dumps(stream),
                settings=json.dumps(dict(clients=[dict(id='foreign-uuid', email='someone', enable=True)],
                                         decryption='none', fallbacks=[])))


class Panel:
    def __init__(self, *rows):
        self.rows = {r['id']: copy.deepcopy(r) for r in rows}
        self.restarts = 0

    def call(self, path, value=None, form=False):
        if path == '/panel/api/inbounds/list': return [copy.deepcopy(r) for r in self.rows.values()]
        if path.startswith('/panel/api/inbounds/get/'):
            row = self.rows.get(int(path.rsplit('/', 1)[1]))
            if row is None: raise ValueError('panel_api_failed')
            return copy.deepcopy(row)
        if path.startswith('/panel/api/inbounds/update/'):
            self.rows[int(path.rsplit('/', 1)[1])] = copy.deepcopy(value); return None
        if path == '/panel/api/server/restartXrayService': self.restarts += 1; return None
        if path == '/panel/api/server/status': return dict(xray=dict(state='running'))
        raise AssertionError(path)

    def clients(self, inbound_id):
        return object_field(self.rows[inbound_id]['settings'])['clients']


class RelayTemplateTests(unittest.TestCase):
    def test_rule_goes_before_egress_and_outbound_is_shared(self):
        egressed, _ = egress_config.configure(TEMPLATE, egress_config.parse_link(EXIT), 1080, 1081)
        one = relay.configure(egressed, add='inbound-443')
        rules = one['routing']['rules']
        self.assertEqual(rules[:2], TEMPLATE['routing']['rules'])
        self.assertEqual(rules[2], relay.rule('inbound-443'))
        self.assertEqual(rules[3]['outboundTag'], egress_config.TAG)
        two = relay.configure(one, add='inbound-8443')
        self.assertEqual([r.get('outboundTag') for r in two['routing']['rules'][2:]],
                         [relay.TAG, relay.TAG, egress_config.TAG])
        self.assertEqual(two['outbounds'].count(relay.OUTBOUND), 1)
        self.assertEqual(two['outbounds'][0]['tag'], 'direct')  # The default outbound stays first.
        back = relay.configure(relay.configure(two, remove='inbound-8443'), remove='inbound-443', last=True)
        self.assertEqual(back, egressed)

    def test_without_egress_the_rule_is_appended(self):
        result = relay.configure(TEMPLATE, add='inbound-443')
        self.assertEqual(result['routing']['rules'][-1], relay.rule('inbound-443'))
        self.assertEqual(relay.configure(result, remove='inbound-443', last=True), TEMPLATE)

    def test_tag_change_moves_the_rule(self):
        one = relay.configure(TEMPLATE, add='inbound-443')
        moved = relay.configure(one, remove='inbound-443', add='inbound-444')
        self.assertNotIn(relay.rule('inbound-443'), moved['routing']['rules'])
        self.assertIn(relay.rule('inbound-444'), moved['routing']['rules'])

    def test_foreign_changes_of_our_objects_conflict(self):
        one = relay.configure(TEMPLATE, add='inbound-443')
        changed = copy.deepcopy(one)
        changed['outbounds'][-1]['settings'] = dict(domainStrategy='UseIP')
        with self.assertRaises(relay.RelayError) as error: relay.configure(changed, remove='inbound-443', last=True)
        self.assertEqual(error.exception.code, 'relay_conflict')
        changed = copy.deepcopy(one)
        changed['routing']['rules'][-1]['network'] = 'tcp'
        with self.assertRaises(relay.RelayError): relay.configure(changed, remove='inbound-443', last=True)
        foreign = copy.deepcopy(one)
        foreign['routing']['rules'].insert(0, dict(type='field', domain=['example.com'], outboundTag=relay.TAG))
        with self.assertRaises(relay.RelayError): relay.configure(foreign, remove='inbound-443', last=True)
        with self.assertRaises(relay.RelayError): relay.configure(one, add='inbound-443')

    def test_foreign_panel_edits_survive_removal(self):
        one = relay.configure(TEMPLATE, add='inbound-443')
        one['routing']['rules'].insert(0, dict(type='field', domain=['example.com'], outboundTag='blocked'))
        one['dns'] = dict(servers=['1.1.1.1'])
        back = relay.configure(one, remove='inbound-443', last=True)
        self.assertEqual(back['routing']['rules'][0]['domain'], ['example.com'])
        self.assertEqual(back['dns'], dict(servers=['1.1.1.1']))
        self.assertNotIn(relay.OUTBOUND, back['outbounds'])

    def test_egress_reconfigure_and_disable_keep_relay_rules(self):
        egressed, owned = egress_config.configure(TEMPLATE, egress_config.parse_link(EXIT), 1080, 1081)
        with_relay = relay.configure(egressed, add='inbound-443')
        # Egress changes its exit: its rule returns at the end, after ours.
        again, owned = egress_config.configure(with_relay, egress_config.parse_link(EXIT.replace('exit.example', 'exit2.example')),
                                               1080, 1081, owned)
        rules = again['routing']['rules']
        self.assertLess(rules.index(relay.rule('inbound-443')), next(i for i, r in enumerate(rules) if r.get('outboundTag') == egress_config.TAG))
        disabled, _ = egress_config.configure(again, None, 1080, 1081, owned)
        self.assertEqual(disabled, relay.configure(TEMPLATE, add='inbound-443'))


class RelayTransactionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = Store(self.root)
        self.api = Panel(inbound_row(3, 443), inbound_row(4, 8443), inbound_row(5, 9443, security='none'))
        self.template = copy.deepcopy(TEMPLATE)
        self.validated = []
        self.stack = []
        self.mock(relay, 'STATE', self.root / 'relay.json')
        self.mock(relay, 'safe_file', lambda *args: None)
        self.mock(relay, 'panel_for', lambda *args: self.api)
        self.mock(access, 'ROOT', self.root / 'egress-access')
        self.mock(access, 'safe_file', lambda *args: None)
        self.mock(client_egress, 'STATE', self.root / 'egress.json')
        self.mock(client_egress, 'safe_file', lambda *args: None)
        self.mock(client_egress, 'panel_for', lambda *args: self.api)
        self.mock(client_egress, 'read_template', lambda api: (copy.deepcopy(self.template), 'https://test.example/'))
        self.mock(client_egress, 'write_template', self.write)
        self.mock(egress_probe, 'validate', lambda config: self.validated.append(copy.deepcopy(config)))
        self.mock(panel_api, 'restart_xray', lambda api: api.call('/panel/api/server/restartXrayService', {}))

    def mock(self, module, name, value):
        obj = patch.object(module, name, value); obj.start(); self.stack.append(obj)

    def tearDown(self):
        for obj in reversed(self.stack): obj.stop()
        self.store.close(); self.temp.cleanup()

    def write(self, api, template, url):
        self.template = copy.deepcopy(template)
        api.call('/panel/api/server/restartXrayService', {})

    def payload(self, inbound_id=3, enabled=True):
        state = self.store.request(dict(version=1, action='relay_state'))
        self.assertEqual(state['code'], 'ok')
        return json.dumps(dict(panelId=PANEL, inboundId=inbound_id, enabled=enabled,
                               observedHash=state['relay']['observedHash']))

    def submit(self, key, inbound_id=3, enabled=True):
        payload = self.payload(inbound_id, enabled)
        plan = self.store.request(dict(version=1, action='relay_plan', payload=payload))
        self.assertEqual(plan['code'], 'ok', plan)
        req = dict(version=1, action='submit', id=key * 32, kind='relay_apply', count=3, interval=1,
                   payload=payload, fingerprint=plan['relay']['fingerprint'])
        self.assertEqual(self.store.request(req)['code'], 'ok')
        return req

    def finish(self, req):
        for _ in range(5): self.store.tick()
        return self.store.request(dict(version=1, action='status', id=req['id'], cursor=0))['jobs'][0]

    def service(self, inbound_id=3):
        return [c for c in self.api.clients(inbound_id) if c['email'].startswith(relay.PREFIX)]

    def test_enable_link_state_and_disable_revokes_the_client(self):
        job = self.finish(self.submit('b'))
        self.assertEqual(job['status'], 'succeeded')
        self.assertEqual([e['code'] for e in job['events']][-4:], ['relay_preparing', 'relay_applying', 'relay_checking', 'succeeded'])
        self.assertIn(relay.rule('inbound-443'), self.template['routing']['rules'])
        self.assertIn(relay.OUTBOUND, self.template['outbounds'])
        self.assertTrue(self.validated)
        self.assertEqual(len(self.service()), 1)
        self.assertEqual([c['id'] for c in self.api.clients(3)][0], 'foreign-uuid')
        self.assertFalse((self.root / ('relay-' + 'b' * 32 + '.json')).exists())
        state = self.store.request(dict(version=1, action='relay_state'))['relay']
        self.assertEqual(state['inbounds'], [dict(panelId=PANEL, inboundId=3, tag='inbound-443', stale=False)])
        link = self.store.request(dict(version=1, action='relay_link', payload=json.dumps(
            dict(panelId=PANEL, inboundId=3, endpoint='203.0.113.7', externalPort=443))))
        self.assertEqual(link['code'], 'ok')
        uri = link['relay']['uri']
        self.assertTrue(uri.startswith('vless://' + self.service()[0]['id'] + '@203.0.113.7:443?'))
        self.assertNotIn('#', uri)
        self.assertEqual(egress_config.parse_link(uri)['security'], 'tls')
        # The link never enters the job journal.
        journal = json.dumps([json.loads(r[0]) for r in self.store.db.execute('SELECT request FROM jobs')])
        self.assertNotIn(self.service()[0]['id'], journal)
        self.assertEqual(self.finish(self.submit('c', enabled=False))['status'], 'succeeded')
        self.assertEqual(self.template, TEMPLATE)
        self.assertEqual(self.service(), [])
        self.assertEqual(list((self.root / 'egress-access').glob('*.json')), [])
        self.assertFalse(relay.STATE.exists())
        self.assertEqual(self.store.request(dict(version=1, action='relay_link', payload=json.dumps(
            dict(panelId=PANEL, inboundId=3, endpoint='203.0.113.7', externalPort=443))))['code'], 'relay_missing')

    def test_reapply_keeps_the_uuid_and_follows_a_new_tag(self):
        self.finish(self.submit('b'))
        uid = self.service()[0]['id']
        self.api.rows[3]['tag'] = 'inbound-0.0.0.0:443'
        state = self.store.request(dict(version=1, action='relay_state'))['relay']
        self.assertTrue(state['inbounds'][0]['stale'])
        self.assertEqual(self.finish(self.submit('c'))['status'], 'succeeded')
        self.assertEqual([c['id'] for c in self.service()], [uid])
        rules = self.template['routing']['rules']
        self.assertIn(relay.rule('inbound-0.0.0.0:443'), rules)
        self.assertNotIn(relay.rule('inbound-443'), rules)
        self.assertFalse(self.store.request(dict(version=1, action='relay_state'))['relay']['inbounds'][0]['stale'])

    def panel_retags(self, inbound_id, tag):
        """What 3x-ui 3.7 does on an inbound edit: a new tag, and routing rules follow it."""
        old = self.api.rows[inbound_id]['tag']
        self.api.rows[inbound_id]['tag'] = tag
        for item in self.template['routing']['rules']:
            if old in item.get('inboundTag', []):
                item['inboundTag'] = [tag if t == old else t for t in item['inboundTag']]

    def test_panel_that_rewrites_routing_on_tag_change(self):
        self.finish(self.submit('b'))
        uid = self.service()[0]['id']
        self.panel_retags(3, 'inbound-0.0.0.0:443')
        # Routing still covers the inbound: not stale, the current tag is reported.
        state = self.store.request(dict(version=1, action='relay_state'))['relay']['inbounds']
        self.assertEqual(state, [dict(panelId=PANEL, inboundId=3, tag='inbound-0.0.0.0:443', stale=False)])
        # Applying again refreshes the record instead of reporting a conflict.
        self.assertEqual(self.finish(self.submit('c'))['status'], 'succeeded')
        rules = self.template['routing']['rules']
        self.assertEqual(rules.count(relay.rule('inbound-0.0.0.0:443')), 1)
        self.assertNotIn(relay.rule('inbound-443'), rules)
        self.assertEqual([c['id'] for c in self.service()], [uid])
        self.assertEqual(relay.load()['inbounds'][0]['tag'], 'inbound-0.0.0.0:443')
        self.panel_retags(3, 'inbound-444')
        self.assertEqual(self.finish(self.submit('d', enabled=False))['status'], 'succeeded')
        self.assertEqual(self.template, TEMPLATE)
        self.assertEqual(self.service(), [])

    def test_disable_after_panel_rewrote_the_rule(self):
        self.finish(self.submit('b', 3))
        self.finish(self.submit('c', 4))
        self.panel_retags(3, 'inbound-0.0.0.0:443')
        self.assertEqual(self.finish(self.submit('d', 3, False))['status'], 'succeeded')
        self.assertEqual([r for r in self.template['routing']['rules'] if r.get('outboundTag') == relay.TAG],
                         [relay.rule('inbound-8443')])
        self.assertIn(relay.OUTBOUND, self.template['outbounds'])
        self.assertEqual(self.finish(self.submit('e', 4, False))['status'], 'succeeded')
        self.assertEqual(self.template, TEMPLATE)

    def test_second_inbound_shares_the_outbound_until_the_last_is_disabled(self):
        self.finish(self.submit('b', 3))
        self.finish(self.submit('c', 4))
        self.assertEqual(self.template['outbounds'].count(relay.OUTBOUND), 1)
        self.finish(self.submit('d', 3, False))
        self.assertIn(relay.OUTBOUND, self.template['outbounds'])
        self.assertEqual(self.template['routing']['rules'][-1], relay.rule('inbound-8443'))
        self.finish(self.submit('e', 4, False))
        self.assertEqual(self.template, TEMPLATE)

    def test_relay_then_egress_and_egress_then_relay(self):
        self.finish(self.submit('b', 3))
        # Egress enabled later: its catch-all lands after the relay rule.
        egressed, owned = egress_config.configure(self.template, egress_config.parse_link(EXIT), 1080, 1081)
        self.template = egressed
        self.finish(self.submit('c', 4))
        tags = [r.get('outboundTag') for r in self.template['routing']['rules']]
        self.assertEqual(tags[-3:], [relay.TAG, relay.TAG, egress_config.TAG])
        # Disabling relay keeps the egress rule; disabling egress keeps relay.
        self.finish(self.submit('d', 3, False))
        self.assertEqual(self.template['routing']['rules'][-1]['outboundTag'], egress_config.TAG)
        disabled, _ = egress_config.configure(self.template, None, 1080, 1081, owned)
        self.assertEqual(disabled['routing']['rules'][-1], relay.rule('inbound-8443'))
        self.template = disabled
        self.finish(self.submit('e', 4, False))
        self.assertEqual(self.template, TEMPLATE)

    def test_client_inbound_and_unsupported_inbounds_are_rejected(self):
        saved = dict(workspaceId='w' * 32, panelId=PANEL, spec=dict(internal=False), observedHash='0' * 64)
        self.api.rows[3]['remark'] = vless.marker('w' * 32, 'r' * 32)
        with self.store.db:
            self.store.db.execute('INSERT INTO vless_resources VALUES (?,?)', ('r' * 32, vless.canonical(saved)))
        plan = lambda inbound_id: self.store.request(dict(version=1, action='relay_plan', payload=self.payload(inbound_id)))['code']
        self.assertEqual(plan(3), 'relay_client_inbound')
        saved['spec']['internal'] = True
        with self.store.db:
            self.store.db.execute('UPDATE vless_resources SET data=?', (vless.canonical(saved),))
        self.assertEqual(plan(3), 'ok')
        self.assertEqual(plan(5), 'relay_unsupported')
        self.api.rows[4]['enable'] = False
        self.assertEqual(plan(4), 'relay_unsupported')
        self.assertEqual(plan(9), 'relay_missing')
        self.assertEqual(self.store.request(dict(version=1, action='relay_plan', payload=self.payload(3, False)))['code'], 'relay_missing')
        stale = json.dumps(dict(panelId=PANEL, inboundId=3, enabled=True, observedHash='0' * 64))
        self.assertEqual(self.store.request(dict(version=1, action='relay_plan', payload=stale))['code'], 'relay_conflict')
        self.assertEqual(self.store.request(dict(version=1, action='relay_plan', payload='{}'))['code'], 'invalid')

    def test_internal_change_makes_managed_row_observation_follow(self):
        saved = dict(workspaceId='w' * 32, panelId=PANEL, spec=dict(internal=True), observedHash='0' * 64)
        self.api.rows[3]['remark'] = vless.marker('w' * 32, 'r' * 32)
        with self.store.db:
            self.store.db.execute('INSERT INTO vless_resources VALUES (?,?)', ('r' * 32, vless.canonical(saved)))
        self.finish(self.submit('b'))
        data = json.loads(self.store.db.execute('SELECT data FROM vless_resources').fetchone()[0])
        self.assertEqual(data['observedHash'], vless.digest(vless.normal(self.api.rows[3])))
        # Normal reconciliation keeps the service client.
        self.assertEqual(access.clients_for(self.api.rows[3]), self.service())

    def test_failure_after_effects_rolls_back(self):
        req = self.submit('b')
        before = copy.deepcopy(self.api.rows[3])
        calls = []
        def failing(api):
            calls.append(1)
            if len(calls) == 1: raise ValueError('panel_api_failed')
            api.call('/panel/api/server/restartXrayService', {})
        with patch.object(panel_api, 'restart_xray', failing):
            job = self.finish(req)
        self.assertEqual(job['status'], 'failed')
        self.assertEqual(job['events'][-1]['code'], 'relay_failed')
        self.assertEqual(self.template, TEMPLATE)
        self.assertEqual(vless.normal(self.api.rows[3]), vless.normal(before))
        self.assertFalse(relay.STATE.exists())
        self.assertEqual(list((self.root / 'egress-access').glob('*.json')), [])
        # Resumable: the kept intent replays once the panel recovers.
        self.assertEqual(self.store.request(dict(version=1, action='resume', id=req['id']))['code'], 'ok')
        self.assertEqual(self.finish(req)['status'], 'succeeded')
        self.assertIn(relay.rule('inbound-443'), self.template['routing']['rules'])
        self.assertEqual(len(self.service()), 1)

    def test_external_drift_during_rollback_needs_attention(self):
        req = self.submit('b')
        task = relay.RelayApply(self.store, req)
        task.step(0); task.step(1)
        self.template['routing']['rules'].append(dict(type='field', domain=['x.example'], outboundTag='blocked'))
        with self.store.db: self.store.db.execute('UPDATE jobs SET checkpoint=2 WHERE id=?', (req['id'],))
        job = self.finish(req)
        self.assertEqual(job['status'], 'needs_attention')
        self.assertEqual(job['events'][-1]['code'], 'relay_conflict')

    def test_worker_replay_after_effect_before_checkpoint(self):
        req = self.submit('b')
        task = relay.RelayApply(self.store, req)
        task.step(0); task.step(1)
        with self.store.db: self.store.db.execute('UPDATE jobs SET checkpoint=1 WHERE id=?', (req['id'],))
        self.assertEqual(self.finish(req)['status'], 'succeeded')
        self.assertEqual(self.template['routing']['rules'].count(relay.rule('inbound-443')), 1)
        self.assertEqual(self.template['outbounds'].count(relay.OUTBOUND), 1)
        self.assertEqual(len(self.service()), 1)

    def test_cancel_after_effects_restores_everything(self):
        req = self.submit('b')
        task = relay.RelayApply(self.store, req)
        task.step(0); task.step(1)
        with self.store.db: self.store.db.execute('UPDATE jobs SET checkpoint=2 WHERE id=?', (req['id'],))
        self.assertEqual(self.store.request(dict(version=1, action='cancel', id=req['id']))['code'], 'ok')
        self.assertEqual(self.finish(req)['status'], 'cancelled')
        self.assertEqual(self.template, TEMPLATE)
        self.assertEqual(self.service(), [])
        self.assertFalse(relay.STATE.exists())

    def test_changed_template_between_plan_and_apply_is_rejected(self):
        req = self.submit('b')
        self.template['routing']['rules'].append(dict(type='field', network='udp', outboundTag='blocked'))
        job = self.finish(req)
        self.assertEqual(job['status'], 'failed')
        self.assertEqual(job['events'][-1]['code'], 'relay_conflict')
        self.assertEqual(self.service(), [])

    def test_disable_after_inbound_was_deleted(self):
        self.finish(self.submit('b'))
        del self.api.rows[3]
        self.assertTrue(self.store.request(dict(version=1, action='relay_state'))['relay']['inbounds'][0]['stale'])
        self.assertEqual(self.finish(self.submit('c', enabled=False))['status'], 'succeeded')
        self.assertEqual(self.template, TEMPLATE)
        self.assertFalse(relay.STATE.exists())

    def test_relay_blocks_client_facing_switch_removal_and_panel_uninstall(self):
        import inbound_remove
        import protocol_remove
        self.finish(self.submit('b'))
        with self.assertRaises(vless.VlessError) as error:
            inbound_remove.preflight(self.store, PANEL, dict(removals=[dict(inboundId=3, observedHash=vless.digest(vless.normal(self.api.rows[3])))]), api=self.api)
        self.assertEqual(error.exception.code, 'relay_disable_first')
        with patch.object(protocol_remove, 'discover') as discover, self.assertRaises(protocol_remove.RemovalError) as error:
            protocol_remove.plan('vless')
        self.assertEqual(error.exception.code, 'relay_disable_first')
        discover.assert_not_called()
        workspace, rid = 'w' * 32, 'r' * 32
        self.api.rows[3]['remark'] = vless.marker(workspace, rid)
        payload = dict(workspaceId=workspace, panelId=PANEL, users=[],
                       resources=[dict(id=rid, deleted=False, internal=False)])
        for resource in (dict(id=rid, deleted=False, internal=False), dict(id=rid, deleted=True, internal=True),
                         dict(id='s' * 32, deleted=False, internal=False, adoption=dict(sourceId='3', panelId=PANEL))):
            payload['resources'] = [resource]
            with self.subTest(resource=resource), self.assertRaises(vless.VlessError) as error:
                vless.preflight(self.store, payload, self.api, rows=list(self.api.rows.values()))
            self.assertEqual(error.exception.code, 'relay_disable_first')


if __name__ == '__main__': unittest.main()
