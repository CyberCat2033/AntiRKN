import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'server/runner'))
from runner import Store
from vless import VlessApply, VlessError, parse_payload, plan, state, normal, digest, client_id


def spec(number=1,transport='raw'):
    return dict(id=f'{number:032x}',name='Managed VLESS',enabled=True,deleted=False,listen='127.0.0.1',port=23400+number,endpoint='203.0.113.10',externalPort=23400+number,transport=transport,security='reality',sni='example.com',target='example.com:443',path='/',host='',mode='auto',certificate='',certificateKey='',region='')
def payload():return dict(version=1,workspaceId='a'*32,panelId='b'*32,resources=[spec(),spec(2,'xhttp')],users=[dict(id='c'*32,enabled=True),dict(id='d'*32,enabled=True)])
class Api:
    def __init__(self):self.rows=[];self.effects=0;self.crash=False;self.list_calls=0;self.get_calls=0;self.annotate_list=False;self.extra_list_field=False
    def call(self,path,data=None):
        if path.endswith('/list'):
            self.list_calls+=1
            rows=copy.deepcopy(self.rows)
            if self.annotate_list:
                for row in rows:
                    row['originNodeGuid']='panel-guid'
                    row['fallbackParent']={'masterId':42}
            if self.extra_list_field:
                for row in rows:
                    row['listOnlyDiagnostic'] = 'computed-by-panel'
            return rows
        if '/get/' in path:
            self.get_calls+=1
            return copy.deepcopy(next((r for r in self.rows if r['id']==int(path.split('/')[-1])),None))
        if path.endswith('/status'):return dict(xray=dict(state='running'))
        if path.endswith('/restartXrayService'):return None
        if '/del/' in path:self.rows=[r for r in self.rows if r['id']!=int(path.split('/')[-1])]
        elif path.endswith('/add'):
            row=copy.deepcopy(data);row['id']=max([r['id'] for r in self.rows],default=0)+1;row['tag']='inbound-'+str(row['port'])
            row=normal(row)
            self.rows.append(row)
        elif '/update/' in path:
            row=normal(data);self.rows=[copy.deepcopy(row) if r['id']==row['id'] else r for r in self.rows]
        else:raise AssertionError(path)
        self.effects+=1
        if self.crash:self.crash=False;raise OSError('response lost')
        return None

class VlessTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.store=Store(Path(self.temp.name));self.api=Api()
        self.patches=[patch('vless.panel_for',return_value=self.api),patch('vless.material',return_value=dict(privateKey='A'*43,publicKey='B'*43,shortId='0123456789abcdef')),patch('vless.secret',side_effect=lambda label:hashlib.sha256(label.encode()).digest()),patch('vless.command',return_value=b'')]
        for p in self.patches:p.start()
    def tearDown(self):
        for p in self.patches:p.stop()
        self.store.close();self.temp.cleanup()
    def submit(self,p=None,number=1):
        p=p or payload();preview=plan(self.store,dict(id=p['panelId'],payload=json.dumps(p)))
        req=dict(version=1,action='submit',id=f'{number:032x}',kind='vless_apply',count=len(p['resources'])+2,interval=1,payload=json.dumps(p),fingerprint=preview['fingerprint'])
        self.store.request(req);return req
    def job(self,req):return self.store.request(dict(version=1,action='status',id=req['id'],cursor=0))['jobs'][0]
    def finish(self,req):
        for _ in range(8):
            self.store.tick()
            if self.job(req)['status'] in ('succeeded','failed','partially_applied','cancelled'):break
        return self.job(req)
    def test_competing_prepared_revision_cannot_overwrite_first_devices_apply(self):
        first_payload = payload()
        other_payload = payload()
        other_payload['users'][0]['enabled'] = False
        other_preview = plan(self.store, dict(id=other_payload['panelId'], payload=json.dumps(other_payload)))
        first = self.submit(first_payload)
        self.assertEqual(self.finish(first)['status'], 'succeeded')
        before = copy.deepcopy(self.api.rows)
        effects = self.api.effects
        stale = dict(version=1, action='submit', id='9'*32, kind='vless_apply',
            count=len(other_payload['resources'])+2, interval=1,
            payload=json.dumps(other_payload), fingerprint=other_preview['fingerprint'])
        self.store.request(stale)
        self.assertEqual(self.finish(stale)['status'], 'failed')
        self.assertEqual(self.api.effects, effects)
        self.assertEqual(self.api.rows, before)
        self.assertIn('vless_conflict', [e['code'] for e in self.job(stale)['events']])

    def test_reality_client_version_is_zero_without_form_input(self):
        from vless import wanted_inbound
        p = payload()
        wanted = wanted_inbound(p, p['resources'][0])
        self.assertEqual(json.loads(wanted['streamSettings'])['realitySettings']['minClientVer'], '0.0.0')

    def test_deleted_id_cannot_resume_but_new_id_gets_new_credentials(self):
        original = self.submit()
        self.assertEqual(self.finish(original)['status'], 'succeeded')
        old_uuid = state(self.store, 'b'*32)[0]['clients'][0]['uuid']
        revoked = payload()
        revoked['users'][0]['enabled'] = False
        revoked['revokedUsers'] = ['c'*32]
        self.assertEqual(self.finish(self.submit(revoked, 2))['status'], 'succeeded')
        self.assertTrue(all(not r['clients'][0]['enabled'] and r['clients'][1]['enabled'] for r in state(self.store, 'b'*32)))
        effects = self.api.effects
        self.store.close()
        self.store = Store(Path(self.temp.name))
        with self.assertRaisesRegex(ValueError, 'revoked_client'):
            self.submit(payload(), 3)
        with self.assertRaisesRegex(ValueError, 'revoked_client'):
            VlessApply(self.store, original).step(1)
        self.assertEqual(self.api.effects, effects)
        recreated = payload()
        recreated['users'][0]['id'] = 'e'*32
        self.assertEqual(self.finish(self.submit(recreated, 4))['status'], 'succeeded')
        clients = state(self.store, 'b'*32)[0]['clients']
        self.assertEqual(clients[0]['id'], 'e'*32)
        self.assertTrue(clients[0]['enabled'])
        self.assertNotEqual(clients[0]['uuid'], old_uuid)

    def test_two_inbounds_have_distinct_stable_personal_credentials(self):
        req=self.submit();self.assertEqual(self.finish(req)['status'],'succeeded')
        self.assertTrue(all(r['sniffing']['enabled'] for r in self.api.rows))
        self.assertEqual(self.api.rows[0]['sniffing']['destOverride'], ['http','tls','quic','fakedns'])
        observed=state(self.store,'b'*32);ids=[u['uuid'] for r in observed for u in r['clients']]
        self.assertEqual(len(set(ids)),4);self.assertTrue(all(r['confirmed'] for r in observed))
        self.assertNotIn(ids[0],self.store.db.execute('SELECT request FROM jobs').fetchone()[0])
        p=payload();p['resources'][0]['name']='Переименован';p['users'][0]['enabled']=False
        second=self.submit(p,2);self.assertEqual(self.finish(second)['status'],'succeeded')
        self.assertEqual(ids,[u['uuid'] for r in state(self.store,'b'*32) for u in r['clients']])
        self.assertGreater(self.api.get_calls, 0)

    def test_prepare_reuses_list_snapshot_and_update_reads_only_target(self):
        req = self.submit()
        before = self.api.list_calls
        self.store.tick()
        self.assertEqual(self.api.list_calls - before, 1)
        self.assertEqual(self.finish(req)['status'], 'succeeded')
        changed = payload()
        changed['users'][0]['enabled'] = False
        req = self.submit(changed, 2)
        self.store.tick()  # Preflight and backup share one snapshot.
        before_list, before_get = self.api.list_calls, self.api.get_calls
        self.store.tick()  # Update the first existing inbound.
        self.assertEqual(self.api.list_calls - before_list, 1)
        self.assertEqual(self.api.get_calls - before_get, 1)
        self.assertEqual(self.finish(req)['status'], 'succeeded')

    def test_point_readback_and_list_annotations_have_same_fingerprint(self):
        self.api.annotate_list=True
        req=self.submit()
        self.assertEqual(self.finish(req)['status'], 'succeeded')
        changed=payload();changed['users'][0]['enabled']=False
        req=self.submit(changed,2)
        self.assertEqual(self.finish(req)['status'], 'succeeded')
        self.assertTrue(all(r['confirmed'] for r in state(self.store,'b'*32)))

    def test_list_only_metadata_falls_back_to_detail_without_hiding_drift(self):
        self.api.extra_list_field = True
        first = self.submit()
        self.assertEqual(self.finish(first)['status'], 'succeeded')
        self.assertTrue(all(row['confirmed'] for row in state(self.store, 'b'*32)))
        changed = payload()
        changed['users'][0]['enabled'] = False
        second = self.submit(changed, 2)
        self.assertEqual(self.finish(second)['status'], 'succeeded')
        # A real edit to the stored row remains a conflict even though the
        # list contains fields that are absent from the detail endpoint.
        self.api.rows[0]['streamSettings']['security'] = 'tls'
        self.assertFalse(state(self.store, 'b'*32)[0]['confirmed'])
        with self.assertRaises(VlessError):
            self.submit(changed, 3)

    def test_resume_saved_final_checkpoint_with_list_metadata(self):
        first = self.submit()
        self.store.tick()  # preflight
        self.store.tick()  # first resource
        self.store.tick()  # second resource
        self.assertEqual(self.job(first)['checkpoint'], 3)
        effects = self.api.effects
        # Emulate a terminal job saved by an older runner just before its
        # final readback. Resuming must verify the existing rows, not reapply.
        self.store.db.execute(
            "UPDATE jobs SET status='partially_applied' WHERE id=?",
            (first['id'],),
        )
        self.store.db.commit()
        self.api.extra_list_field = True
        self.store.request(dict(version=1, action='resume', id=first['id']))
        self.assertEqual(self.finish(first)['status'], 'succeeded')
        self.assertEqual(self.api.effects, effects)

    def test_legacy_list_fingerprint_can_be_verified_after_upgrade(self):
        self.api.annotate_list = True
        first = self.submit()
        self.assertEqual(self.finish(first)['status'], 'succeeded')
        resource = payload()['resources'][0]['id']
        saved = json.loads(self.store.db.execute(
            'SELECT data FROM vless_resources WHERE id=?', (resource,),
        ).fetchone()[0])
        legacy_row = normal(self.api.rows[0])
        legacy_row['originNodeGuid'] = 'panel-guid'
        legacy_row['fallbackParent'] = {'masterId': 42}
        saved['observedHash'] = digest(legacy_row)
        self.store.db.execute(
            'UPDATE vless_resources SET data=? WHERE id=?',
            (json.dumps(saved), resource),
        )
        self.store.db.commit()
        self.assertTrue(state(self.store, 'b'*32)[0]['confirmed'])
        changed = payload()
        changed['users'][0]['enabled'] = False
        self.assertEqual(self.finish(self.submit(changed, 2))['status'], 'succeeded')

    def test_panel_session_reused_but_pinned_version_checked_each_step(self):
        self.patches[0].stop()
        from vless import panel_for
        access = dict(port=12345, username='user', password='secret',
            panelVersion='3.8.0', xrayVersion='26.9.9')
        class Session:
            logins = 0
            version = '26.9.9'
            def login(self, *_):self.logins += 1
            def call(self, path):
                self.assert_path = path
                return dict(panelVersion='3.8.0', xray=dict(version=self.version))
        session = Session()
        try:
            with patch('vless.access_for_panel', return_value=access), patch('vless.PanelApi', return_value=session):
                self.assertIs(panel_for(self.store, 'b'*32), session)
                self.assertIs(panel_for(self.store, 'b'*32), session)
                self.assertEqual(session.logins, 1)
                session.version = 'other'
                with self.assertRaises(VlessError):panel_for(self.store, 'b'*32)
        finally:
            self.patches[0].start()
    def test_internal_inbound_revokes_our_clients_and_reopens_with_same_credentials(self):
        self.finish(self.submit())
        before=[c['uuid'] for c in state(self.store,'b'*32)[0]['clients']]
        p=payload();p['resources'][0]['internal']=True
        self.assertEqual(self.finish(self.submit(p,2))['status'],'succeeded')
        self.assertTrue(self.api.rows[0]['enable'])
        self.assertEqual(self.api.rows[0]['settings']['clients'],[])
        self.assertEqual(state(self.store,'b'*32)[0]['clients'],[])
        p['resources'][0]['internal']=False
        self.assertEqual(self.finish(self.submit(p,3))['status'],'succeeded')
        self.assertEqual(before,[c['uuid'] for c in state(self.store,'b'*32)[0]['clients']])
    def test_xhttp_options_reach_api_and_conflicts_are_rejected(self):
        p=payload();p['resources'][1]['xhttp']={'xmux':{'maxConnections':'2-3','hKeepAlivePeriod':30},'xPaddingBytes':'200-400','headers':{'X-Fixture':'yes'},'noSSEHeader':True}
        self.assertEqual(self.finish(self.submit(p))['status'],'succeeded')
        observed=self.api.rows[1]['streamSettings']['xhttpSettings']
        self.assertEqual(observed['xmux']['maxConnections'],'2-3')
        self.assertEqual(observed['xPaddingBytes'],'200-400')
        for extra in [{'xmux':{'maxConnections':'2','maxConcurrency':'4'}},{'xPaddingBytes':'400-200'},{'headers':{'Host':'bad'}},{'headers':{'X-Test':'bad\r\nInjected:yes'}},{'uplinkDataPlacement':'cookie'}]:
            p['resources'][1]['xhttp']=extra
            with self.subTest(extra=extra),self.assertRaises((ValueError,VlessError)): parse_payload(json.dumps(p))
    def test_crash_after_panel_effect_resumes_without_duplicate(self):
        req=self.submit();self.store.tick();self.api.crash=True;self.store.tick()
        self.assertEqual(self.job(req)['status'],'partially_applied');self.assertEqual(len(self.api.rows),1)
        self.store.request(dict(version=1,action='resume',id=req['id']));self.assertEqual(self.finish(req)['status'],'succeeded')
        self.assertEqual(len(self.api.rows),2);self.assertEqual(self.api.effects,2)
    def test_drift_and_foreign_inbounds_are_never_overwritten(self):
        req=self.submit();self.finish(req);effects=self.api.effects
        self.api.rows[0]['streamSettings']['externalOption']='foreign'
        with self.assertRaises(VlessError):self.submit(payload(),2)
        self.assertEqual(self.api.effects,effects)
        self.assertFalse(state(self.store,'b'*32)[0]['confirmed'])
    def test_precondition_change_after_preview_causes_no_effect(self):
        req=self.submit();self.api.rows.append(dict(id=44,protocol='vless',port=24500,listen='127.0.0.1',enable=True,remark='Unmanaged',settings={},streamSettings={}))
        job=self.finish(req);self.assertEqual(job['status'],'failed');self.assertEqual(self.api.effects,0)
    def test_cancel_at_safe_checkpoint_preserves_applied_resource(self):
        req=self.submit();self.store.tick();self.store.tick();self.store.request(dict(version=1,action='cancel',id=req['id']))
        job=self.finish(req);self.assertEqual(job['status'],'partially_applied');self.assertEqual(len(self.api.rows),1)
        self.assertTrue((Path(self.temp.name)/('vless-backup-'+req['id']+'.json')).exists())
    def test_delete_only_owned_resource(self):
        req=self.submit();self.finish(req);p=payload();p['resources'][0].update(enabled=False,deleted=True)
        second=self.submit(p,2);self.assertEqual(self.finish(second)['status'],'succeeded');self.assertEqual(len(self.api.rows),1)
        self.assertTrue(state(self.store,'b'*32)[0]['confirmed'])
    def test_contract_rejects_unknown_fields_injection_invalid_combinations_and_duplicates(self):
        for change in [dict(listen='$(id)'),dict(port=True),dict(endpoint='0.0.0.0'),dict(transport='ws'),dict(transport='raw',security='tls'),dict(transport='xhttp',mode='packet-up'),dict(certificate='/etc/../key')]:
            p=payload();p['resources'][0].update(change)
            with self.subTest(change=change),self.assertRaises((ValueError,VlessError)):parse_payload(json.dumps(p))
        p=payload();p['users'].append(p['users'][0])
        with self.assertRaises(VlessError):parse_payload(json.dumps(p))
    def test_checkpoint_registry_event_atomic_on_storage_error(self):
        req=self.submit();self.store.tick()
        self.store.db.execute("CREATE TRIGGER fail_resource BEFORE INSERT ON vless_resources BEGIN SELECT RAISE(ABORT,'fixture'); END")
        import sqlite3
        with self.assertRaises(sqlite3.Error):self.store.tick()
        self.assertEqual(self.job(req)['checkpoint'],1);self.assertEqual(len(self.api.rows),1)
        self.store.db.execute('DROP TRIGGER fail_resource');self.store.recover();self.assertEqual(self.finish(req)['status'],'succeeded')
        self.assertEqual(len(self.api.rows),2)
    def test_plan_allows_coexisting_inbounds_on_different_listen_ips(self):
        self.api.rows.append(dict(id=99, protocol='vless', port=23401, listen='127.0.0.2', enable=True, remark='other', settings={}, streamSettings={}))
        preview = plan(self.store, dict(id='b'*32, payload=json.dumps(payload())))
        self.assertIn('fingerprint', preview)
    def test_plan_rejects_colliding_port_on_wildcard_or_same_ip(self):
        self.api.rows.append(dict(id=99, protocol='vless', port=23401, listen='0.0.0.0', enable=True, remark='wildcard', settings={}, streamSettings={}))
        with self.assertRaises(VlessError) as ctx:
            plan(self.store, dict(id='b'*32, payload=json.dumps(payload())))
        self.assertEqual(str(ctx.exception), 'vless_port_busy')
    def test_tls_hostname_mismatch_blocks_before_any_mutation(self):
        p=payload();p['resources'][0].update(transport='xhttp',security='tls',certificate='/fixture.crt',certificateKey='/fixture.key')
        with patch('vless.command',return_value=b'Hostname example.com does NOT match certificate\n'):
            with self.assertRaises(VlessError):self.submit(p)
        self.assertEqual(self.api.effects,0)

    def test_state_reconciles_manually_deleted_panel_inbound(self):
        req = self.submit()
        self.assertEqual(self.finish(req)['status'], 'succeeded')
        self.assertEqual(len(self.api.rows), 2)
        deleted_id = self.api.rows[0]['id']
        self.api.rows = [r for r in self.api.rows if r['id'] != deleted_id]
        st = state(self.store, 'b' * 32)
        self.assertEqual(len(st), 2)
        deleted_obs = [s for s in st if not s['exists']][0]
        self.assertTrue(deleted_obs['deleted'])
        self.assertTrue(deleted_obs['confirmed'])
        self.assertFalse(deleted_obs['exists'])

    def test_preflight_allows_deleting_manually_removed_panel_inbound(self):
        p = payload()
        req = self.submit(p)
        self.assertEqual(self.finish(req)['status'], 'succeeded')
        self.api.rows = self.api.rows[1:]
        p_del = copy.deepcopy(p)
        p_del['resources'][0]['deleted'] = True
        p_del['resources'][0]['enabled'] = False
        preview = plan(self.store, dict(id=p_del['panelId'], payload=json.dumps(p_del)))
        self.assertIn('fingerprint', preview)
        second = self.submit(p_del, 2)
        self.assertEqual(self.finish(second)['status'], 'succeeded')

    def test_preflight_allows_adding_inbound_when_old_was_manually_deleted_from_panel(self):
        p = payload()
        req = self.submit(p)
        self.assertEqual(self.finish(req)['status'], 'succeeded')
        self.api.rows = self.api.rows[1:]
        p_new = copy.deepcopy(p)
        p_new['resources'] = [p['resources'][1], spec(3, 'raw')]
        preview = plan(self.store, dict(id=p_new['panelId'], payload=json.dumps(p_new)))
        self.assertIn('fingerprint', preview)
        second = self.submit(p_new, 2)
        self.assertEqual(self.finish(second)['status'], 'succeeded')

class RealityMaterialTests(unittest.TestCase):
    def test_regenerate_changes_only_reality_material_and_is_stable_on_retry(self):
        from vless import material
        with tempfile.TemporaryDirectory() as directory:
            key=Path(directory)/'key';key.write_bytes(bytes(range(32)))
            with patch('vless.KEY',key),patch('vless.safe_file'):
                original=material('a'*32,'b'*32)
                regenerated=material('a'*32,'b'*32,'c'*32)
                self.assertEqual(regenerated,material('a'*32,'b'*32,'c'*32))
                self.assertNotEqual(original['publicKey'],regenerated['publicKey'])
                self.assertNotEqual(original['shortId'],regenerated['shortId'])
                self.assertEqual([len(x) for x in regenerated['shortIds']],list(range(2,17,2)))
                before=client_id('a'*32,'b'*32,'d'*32)
                material('a'*32,'b'*32,'e'*32)
                self.assertEqual(before,client_id('a'*32,'b'*32,'d'*32))

if __name__=='__main__':unittest.main()
