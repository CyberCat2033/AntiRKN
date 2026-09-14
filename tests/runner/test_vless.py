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
    def __init__(self):self.rows=[];self.effects=0;self.crash=False
    def call(self,path,data=None):
        if path.endswith('/list'):return copy.deepcopy(self.rows)
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
    def test_two_inbounds_have_distinct_stable_personal_credentials(self):
        req=self.submit();self.assertEqual(self.finish(req)['status'],'succeeded')
        observed=state(self.store,'b'*32);ids=[u['uuid'] for r in observed for u in r['clients']]
        self.assertEqual(len(set(ids)),4);self.assertTrue(all(r['confirmed'] for r in observed))
        self.assertNotIn(ids[0],self.store.db.execute('SELECT request FROM jobs').fetchone()[0])
        p=payload();p['resources'][0]['name']='Переименован';p['users'][0]['enabled']=False
        second=self.submit(p,2);self.assertEqual(self.finish(second)['status'],'succeeded')
        self.assertEqual(ids,[u['uuid'] for r in state(self.store,'b'*32) for u in r['clients']])
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
    def test_tls_hostname_mismatch_blocks_before_any_mutation(self):
        p=payload();p['resources'][0].update(transport='xhttp',security='tls',certificate='/fixture.crt',certificateKey='/fixture.key')
        with patch('vless.command',return_value=b'Hostname example.com does NOT match certificate\n'):
            with self.assertRaises(VlessError):self.submit(p)
        self.assertEqual(self.api.effects,0)
if __name__=='__main__':unittest.main()
