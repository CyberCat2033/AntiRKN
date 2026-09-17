#!/usr/bin/env python3
"""Only the private disposable Mihomo VM; all exported credentials stay in /tmp."""
import hashlib,json,secrets,sys,time
from pathlib import Path
import test_mihomo_vm as m
import test_vless_vm as v
from test_panel_vm import python,remote

RESULTS={}
def record(name):RESULTS[name]=True;print('PASS '+name,flush=True)
def rpc(action,key,payload=None):
    req=dict(version=1,action=action,id=key)
    if payload is not None:req['payload']=json.dumps(payload)
    response=m.rpc(req)
    if response['code']!='ok':raise AssertionError(action+': '+response['code'])
    return response.get('xrayCheck') or response.get('connectionProbe')
def private(source,data=None):
    return python("import sys;sys.path.insert(0,'/usr/local/lib/antirkn-runner/"+m.VERSION+"');from runner import Store,STATE;import xray_transaction as x;import connectivity_probe as p;s=Store(STATE);\n"+source,data)
def reset():
    # Restore test fixture input between independent cases, never an owner host.
    archive=Path('/tmp/antirkn-mihomo-xray-old.zip')
    remote('cat > /tmp/mihomo-xray-old.zip',archive.read_bytes())
    private("import zipfile\nassert __import__('pathlib').Path('/etc/hostname').read_text().strip()=='antirkn-runner-fixture'\nassert not x.active(s)\nx.atomic_file(x.BINARY,zipfile.ZipFile('/tmp/mihomo-xray-old.zip').read('xray'),0o755)\nx.panel.client(x.vless.access_for_panel(s,"+repr(PANEL)+")).call('/panel/api/server/restartXrayService',{})")
    time.sleep(2)
    private("x.cache_versions(s,{'payload':{'panelId':"+repr(PANEL)+"}},dict(panelVersion='3.8.0',xrayVersion='26.7.28'))")
def check(fields,expected=True):
    result=m.native_check(fields,CA)
    if result['status']!='success':result=m.native_check(fields,CA)
    if expected:assert result['status']=='success',result['code']
    return result

def prepare():
    plan=rpc('xray_check_plan',PANEL)
    rows=m.rpc(dict(version=1,action='vless_state',id=PANEL))['vlessState']
    keys=[];fields=[]
    for row in rows:
        spec=row['spec']
        if not spec['enabled']:continue
        key=secrets.token_hex(16)
        access=rpc('probe_begin',key,dict(protocol='vless',resource=spec['id'],workspace=m.WORKSPACE,spec=spec))
        keys.append(key);fields.append(m.compile_proxy('vless',spec,access['observation'],access['user']))
        check(fields[-1])
    record('baseline_all_inbounds_https_udp')
    return plan,keys,fields

def begin(plan,keys):
    key=secrets.token_hex(16)
    # Supply only a checksum-verified official archive to avoid network variance
    # while keeping the production digest/extraction/config tests in force.
    remote('cat > /tmp/mihomo-xray-new.zip',Path('/tmp/antirkn-mihomo-xray-new.zip').read_bytes())
    private("path=x.location(s,"+repr(key)+");path.mkdir(mode=0o700);x.atomic_file(path/'candidate.zip',__import__('pathlib').Path('/tmp/mihomo-xray-new.zip').read_bytes())")
    data=dict(panelId=PANEL,fingerprint=plan['fingerprint'],leases=keys,network='vm-fixture-device',core='ac017cdd246ce8bd547653d927e7bf77d7ee73d5',baseline=[dict(lease=k,tcp=True,udp=True) for k in keys])
    result=rpc('xray_check_begin',key,data)
    for _ in range(90):
        status=rpc('xray_check_status',key)
        if status['phase'] in ('awaiting_checks','rolled_back','not_changed','recovery_required'):break
        time.sleep(1)
    assert status['phase']=='awaiting_checks',(status['phase'],status['code'])
    record('real_official_binary_replaced_before_device_commit')
    return key,dict(nonce=result['nonce'],manifest=result['manifest'])

def cleanup(keys):
    for key in keys:
        value=rpc('probe_end',key);assert value['closed'] and value['stable']

def actual_update():
    plan,keys,fields=prepare()
    try:
        key,commit=begin(plan,keys)
        results=[check(f,False) for f in fields]
        good=all(r['status']=='success' for r in results)
        if good:
            commit.update(network='vm-fixture-device',checks=[dict(lease=k,tcp=True,udp=True) for k in keys])
            assert rpc('xray_check_commit',key,commit)['phase']=='committed'
            record('real_update_full_network_comparison_and_commit')
        else:
            assert rpc('xray_check_abort',key,commit)['phase']=='rolled_back'
            for f in fields:check(f)
            record('real_update_regression_restored_binary_and_all_traffic')
        after=rpc('xray_check_plan',PANEL)
        assert after['inbounds']==plan['inbounds'];record('inbound_ids_ports_enabled_unchanged')
    finally:cleanup(keys)
    reset()

def expiry(reboot=False):
    plan,keys,fields=prepare()
    try:
        key,commit=begin(plan,keys)
        remote('systemctl stop antirkn-runner')
        if reboot:
            remote('systemctl reboot',check=False)
            time.sleep(5)
        else:
            private("with p.operation_lock(s):\n i=x.load(s,"+repr(key)+");i['deadline']=__import__('time').time()-1;x.save(s,i)")
        for _ in range(120):
            try:state=rpc('xray_check_status',key)
            except Exception:time.sleep(1);continue
            if state['phase']=='rolled_back':break
            time.sleep(1)
        assert state['phase']=='rolled_back',state['phase']
        late=m.rpc(dict(version=1,action='xray_check_commit',id=key,payload=json.dumps(commit)))
        assert late['code']=='xray_check_late'
        for f in fields:check(f)
        record('independent_rollback_'+('reboot' if reboot else 'deadline_runner_stopped')+'_and_traffic')
        record('late_commit_rejected')
    finally:
        remote('systemctl start antirkn-runner');cleanup(keys)

def udp_regression():
    plan,keys,fields=prepare()
    key,commit=begin(plan,keys)
    try:
        remote('iptables -I OUTPUT 1 -p udp --dport 53 -j DROP')
        result=check(fields[-1],False)
        assert result['tcp'] and not result['udp']
        # Device policy confirms controls on its own network, then aborts the
        # entire update even though only UDP on one inbound has failed.
        assert rpc('xray_check_abort',key,commit)['phase']=='rolled_back'
        record('one_inbound_udp_only_failure_rolls_back')
    finally:
        remote('iptables -D OUTPUT -p udp --dport 53 -j DROP',check=False)
        for f in fields:check(f)
        cleanup(keys)
    record('udp_failure_recovery_all_traffic')

def successful_tls_update():
    original=[r['spec'] for r in m.rpc(dict(version=1,action='vless_state',id=PANEL))['vlessState']]
    limited=[dict(spec,enabled=spec['security']=='tls') for spec in original]
    try:
        v.apply(v.payload(limited,users=[]),'only_tls_enabled')
        plan,keys,fields=prepare()
        try:
            key,commit=begin(plan,keys)
            for f in fields:check(f)
            commit.update(network='vm-fixture-device',checks=[dict(lease=k,tcp=True,udp=True) for k in keys])
            assert rpc('xray_check_commit',key,commit)['phase']=='committed'
            record('real_update_full_tls_baseline_comparison_commit')
        finally:cleanup(keys)
        reset()
    finally:
        v.apply(v.payload(original,users=[]),'restore_fixture_enabled_flags')

if __name__=='__main__':
    PANEL=json.loads((m.DIRECTORY/'panel-access.json').read_text())['id'];CA=m.DIRECTORY/'tls/ca.crt'
    v.PANEL_ID=PANEL;v.WORKSPACE=m.WORKSPACE;v.HOST_BASE=37443;v.FIXTURE=m.DIRECTORY/'tls';v.rpc=m.rpc
    v.python=lambda source,*a,**kw:python(source.replace('/v5','/'+m.VERSION).replace('10000000000000000000000000000001',PANEL).replace("'Origin':api.base","'Origin':api.origin"),*a,**kw)
    close=v.fixtures()
    try:
        if sys.argv[1:]==['success']:
            previous=Path('docs/evidence/xray-upgrade-vm.json')
            if previous.exists():RESULTS.update(json.loads(previous.read_text())['results'])
            successful_tls_update()
        else:
            actual_update();udp_regression();expiry();expiry(reboot=True)
        Path('docs/evidence/xray-upgrade-vm.json').write_text(json.dumps(dict(results=RESULTS,panel='3.8.0',before='26.7.28',candidate='26.9.9',deviceCore='Mihomo 1.19.30'),indent=2)+'\n')
    finally:close()
