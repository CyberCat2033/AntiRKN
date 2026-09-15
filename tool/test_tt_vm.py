#!/usr/bin/env python3
"""Focused TrustTunnel acceptance on artifacts/tt-test only. No secret output."""
import copy
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time
import urllib.request

ROOT=Path(__file__).resolve().parent.parent
DIRECTORY=ROOT/'artifacts/tt-test'
os.environ['ANTIRKN_VM_DIRECTORY']=str(DIRECTORY)
from test_panel_vm import remote,python,bundle_strings
from test_vless_vm import socks,free_port

results={}
def check(value,name):
    if not value:raise AssertionError(name)
    results[name]=True;print('PASS',name,flush=True)


def rpc(req):
    return json.loads(remote('/usr/bin/python3 -I /usr/local/lib/antirkn-runner/v12/runner.py rpc',json.dumps(req).encode(),check=False).stdout)


def wait(req):
    response=rpc(req)
    if response['code']!='ok':raise AssertionError(response['code'])
    for _ in range(900):
        response=rpc(dict(version=1,action='status',id=req['id'],cursor=0))
        if response['code']=='busy':time.sleep(.25);continue
        job=response['jobs'][0]
        if job['status'] not in ('planned','running'):return job
        time.sleep(.25)
    raise AssertionError('TT fixture timeout')


def apply(action,kind,p,count,id=None):
    preview=rpc(dict(version=1,action=action,payload=json.dumps(p),**({'id':p['workspaceId']} if action=='tt_plan' else {})))
    check(preview['code']=='ok','plan_'+kind+'_'+preview['code'])
    req=dict(version=1,action='submit',kind=kind,id=id or secrets.token_hex(16),count=count,interval=1,payload=json.dumps(p),fingerprint=preview['tt']['fingerprint'])
    job=wait(req)
    check(job['status']=='succeeded','apply_'+kind+'_'+job['events'][-1]['code'])
    check(rpc(req)['jobs'][0]['sequence']==job['sequence'],'repeat_'+kind)
    return job


def download(url,sha,path):
    if not path.exists():
        data=urllib.request.urlopen(url,timeout=60).read();path.write_bytes(data);path.chmod(0o600)
    data=path.read_bytes()
    assert hashlib.sha256(data).hexdigest()==sha
    return data


def bootstrap():
    check(python("from pathlib import Path;assert Path('/etc/hostname').read_text().strip()=='antirkn-runner-fixture'").returncode==0,'isolated_ubuntu')
    sources=bundle_strings()
    preview=json.loads(python(sources['runnerInspector']+'\nprint(json.dumps(inspect_runner()))').stdout)
    release=json.loads(sources['runnerBundle'])['release']
    upgrading=preview['upgradable']
    predecessor=preview['release']
    if preview['release']!=release:
        if preview['state']=='installed' and not preview['upgradable']:
            # Only this named development fixture may replace an in-progress
            # v12 bundle. The application upgrader remains immutable.
            python("""import pathlib,sqlite3,subprocess,shutil
assert pathlib.Path('/etc/hostname').read_text().strip()=='antirkn-runner-fixture'
db=sqlite3.connect('/var/lib/antirkn-runner/jobs.sqlite');assert not db.execute("SELECT 1 FROM jobs WHERE status IN ('planned','running')").fetchone();db.close()
subprocess.run(['systemctl','stop','antirkn-runner','antirkn-tt-certificates.timer'],check=False,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
shutil.rmtree('/usr/local/lib/antirkn-runner/v12')
base=pathlib.Path('/usr/local/lib/antirkn-runner')
if not any(base.iterdir()):base.rmdir()
pathlib.Path('/etc/systemd/system/antirkn-runner.service').unlink(missing_ok=True)
""")
            preview=json.loads(python(sources['runnerInspector']+'\nprint(json.dumps(inspect_runner()))').stdout)
        result=python(sources['runnerInstaller'],json.dumps(dict(fingerprint=preview['fingerprint'],bundle=json.loads(sources['runnerBundle']))).encode())
        check(json.loads(result.stdout)['active'],'runner_installed')
    if upgrading:
        (ROOT/'docs/evidence/tt-upgrade.json').write_text(json.dumps(dict(fromRelease=predecessor,toRelease=release,fromVersion=11,toVersion=12,result='PASS'),indent=2)+'\n')
    data=(ROOT/'packages/ssh_transport/lib/src/runner_bundle.g.dart').read_text()
    inspector=re.search(r"const runnerComponentInspector =\s*r'''(.*?)''';",data,re.S).group(1)
    component=json.loads(python(inspector,json.dumps(dict(component='trusttunnel')).encode()).stdout)['componentPlan']
    if component['state']!='current':
        req=dict(version=1,action='submit',id=secrets.token_hex(16),kind='component_install',component='trusttunnel',count=6,interval=1,fingerprint=component['fingerprint'])
        artifact=json.loads((ROOT/'schemas/component-releases.json').read_text())['trusttunnel']['archives']['endpoint']
        raw=download(artifact['url'],artifact['sha256'],DIRECTORY/'trusttunnel.tar.gz')
        directory='/var/lib/antirkn-runner/component-'+req['id'];remote('mkdir -m 700 -p '+directory);remote('cat > '+directory+'/endpoint.archive',raw)
        job=wait(req);check(job['status']=='succeeded','trusttunnel_install_'+job['events'][-1]['code'])
    mihomo=DIRECTORY/'mihomo-compatible'
    if not mihomo.exists():
        metadata=json.load(urllib.request.urlopen('https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/v1.19.30'))
        asset=next(a for a in metadata['assets'] if a['name']=='mihomo-linux-amd64-compatible-v1.19.30.gz')
        raw=download(asset['browser_download_url'],asset['digest'].split(':')[1],DIRECTORY/'mihomo-compatible.gz')
        mihomo.write_bytes(gzip.decompress(raw));mihomo.chmod(0o700)
        (DIRECTORY/'mihomo-release.json').write_text(json.dumps(dict(version='1.19.30',url=asset['browser_download_url'],archiveSha256=asset['digest'],binarySha256=hashlib.sha256(mihomo.read_bytes()).hexdigest())))
    return mihomo


def certificate_fixture():
    python("""from pathlib import Path
import subprocess
p=Path('/etc/tt-fixture');p.mkdir(mode=0o700,exist_ok=True)
def run(args):subprocess.run(args,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
if not (p/'ca.key').exists():
 run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','10','-subj','/CN=AntiRKN TT fixture CA','-keyout',str(p/'ca.key'),'-out',str(p/'ca.crt')])
 Path('/usr/local/share/ca-certificates/tt-fixture.crt').write_bytes((p/'ca.crt').read_bytes());run(['update-ca-certificates'])
if not (p/'certificate.pem').exists():
 run(['openssl','req','-new','-newkey','rsa:2048','-nodes','-subj','/CN=tt.fixture.test','-keyout',str(p/'private.pem'),'-out',str(p/'request.pem')])
 (p/'ext.cnf').write_text('subjectAltName=DNS:tt.fixture.test\\nextendedKeyUsage=serverAuth\\n')
 run(['openssl','x509','-req','-in',str(p/'request.pem'),'-CA',str(p/'ca.crt'),'-CAkey',str(p/'ca.key'),'-CAcreateserial','-days','5','-extfile',str(p/'ext.cnf'),'-out',str(p/'certificate.pem')])
for f in p.iterdir():
 if f.is_file() and f.name not in ('mihomo','pebble'):f.chmod(0o600)
root=Path('/root/cert/tt.fixture.test');root.mkdir(parents=True,mode=0o700,exist_ok=True)
for name,target in [('fullchain.pem','certificate.pem'),('privkey.pem','private.pem')]:
 if not (root/name).exists():(root/name).symlink_to(p/target)
""")
    (DIRECTORY/'ca.crt').write_bytes(remote('cat /etc/tt-fixture/ca.crt').stdout)
    spec=dict(id='e'*32,mode='files',domain='tt.fixture.test',listen='0.0.0.0',expectedIps=['127.0.0.1'],email='',certificate='/root/cert/tt.fixture.test/fullchain.pem',privateKey='/root/cert/tt.fixture.test/privkey.pem',certificatePem='',privateKeyPem='')
    apply('tt_certificate_plan','tt_certificate',spec,4)
    return spec


def desired():
    return dict(version=1,protocol='tt',workspaceId='a'*32,panelId='a'*32,
        users=[dict(id='c'*32,login='alice',enabled=True),dict(id='d'*32,login='bob',enabled=True)],
        resources=[dict(id='b'*32,name='TT fixture',enabled=True,deleted=False,listen='0.0.0.0',port=28443,
            endpoint='127.0.0.1',externalPort=28443,domain='tt.fixture.test',certificateId='e'*32,
            quic=False,ipv6=False,allowPrivate=True,outbound='direct',socksAddress='127.0.0.1:1080',rotation=0)])


def observed():
    result=rpc(dict(version=1,action='tt_state',id='a'*32));check(result['code']=='ok','state_readback');return result['tt']['resources']


def network(mihomo,p,state,user=0,expected=True):
    uid=p['users'][user]['id'];port=free_port();directory=DIRECTORY/('network-'+str(user));directory.mkdir(exist_ok=True)
    workspace=dict(version=3,id=p['workspaceId'],users=[dict(id=u['id'],enabled=True,login=u['login'],name=u['login']) for u in p['users']],inbounds=[],awgInterfaces=[],ttEndpoints=[dict(serverId='fixture',spec=r) for r in p['resources']],servers={'tt/fixture':dict(observed=state)},profiles={})
    template={'mixed-port':port,'allow-lan':False,'mode':'rule','log-level':'silent','ipv6':False,'dns':{'enable':False},'proxies':[],
        'proxy-groups':[{'name':'TEST','type':'select','include-all-proxies':True}],'rules':['MATCH,TEST']}
    input_file=directory/'input.json';input_file.write_text(json.dumps(dict(workspace=workspace,userId=uid,resourceId=p['resources'][0]['id'],template=template)));input_file.chmod(0o600)
    config=directory/'config.yaml'
    subprocess.run(['dart','run','tool/compile_vless_fixture.dart',str(input_file),str(config)],cwd=ROOT,check=True,stdout=subprocess.DEVNULL);config.chmod(0o600)
    env={**os.environ,'SSL_CERT_FILE':str(DIRECTORY/'ca.crt')}
    result=subprocess.run([str(mihomo),'-t','-d',str(directory),'-f',str(config)],capture_output=True,env=env)
    check(result.returncode==0,'mihomo_config')
    log=(directory/'mihomo.log').open('wb')
    process=subprocess.Popen([str(mihomo),'-d',str(directory),'-f',str(config)],stdout=log,stderr=log,env=env)
    try:
        for _ in range(40):
            try:
                with socket.create_connection(('127.0.0.1',port),timeout=.1):break
            except OSError:time.sleep(.1)
        ok=False
        try:
            s,_=socks(port,1,'10.0.2.2',29890)
            with s:s.settimeout(8);s.sendall(b'TT');ok=s.recv(16)==b'TT-OK'
        except (OSError,RuntimeError):pass
        check(ok==expected,'tcp_'+p['resources'][0]['outbound']+'_'+str(user) if expected else 'revoked_old_profile')
        if expected:
            control,(_,udpport)=socks(port,3,'0.0.0.0',0)
            with control,socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as udp:
                udp.settimeout(8);message=secrets.token_bytes(48)
                packet=b'\x00\x00\x00\x01'+socket.inet_aton('10.0.2.2')+struct.pack('!H',29891)+message
                udp.sendto(packet,('127.0.0.1',udpport));data,_=udp.recvfrom(65535)
                check(data.endswith(message),'udp_'+p['resources'][0]['outbound']+'_'+str(user))
    finally:process.terminate();process.wait(timeout=10);log.close()


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(10)
        if self.request.recv(16)==b'TT':self.request.sendall(b'TT-OK')


def socks_fixture(mihomo):
    remote('systemctl stop tt-socks-fixture.service',check=False)
    remote('cat > /etc/tt-fixture/mihomo',mihomo.read_bytes())
    remote('chmod 700 /etc/tt-fixture/mihomo')
    config={'mixed-port':1080,'bind-address':'127.0.0.1','allow-lan':False,'mode':'direct','log-level':'silent','dns':{'enable':False}}
    remote('cat > /etc/tt-fixture/socks.json',json.dumps(config).encode())
    unit=b'[Unit]\nDescription=TT fixture SOCKS5\n[Service]\nExecStart=/etc/tt-fixture/mihomo -d /etc/tt-fixture -f /etc/tt-fixture/socks.json\n'
    remote('cat > /etc/systemd/system/tt-socks-fixture.service',unit)
    remote('systemctl daemon-reload');remote('systemctl restart tt-socks-fixture')
    python("""import socket,time
for _ in range(100):
 try:
  with socket.create_connection(('127.0.0.1',1080),timeout=.5) as s:
   s.sendall(b'\\x05\\x01\\x00');assert s.recv(2)==b'\\x05\\x00'
  break
 except OSError:time.sleep(.2)
else:raise AssertionError('SOCKS fixture failed to listen')
""".replace('\n+','\n'))


def external_fixture():
    python(r"""from pathlib import Path
import sys,subprocess,shutil,os
sys.path.insert(0,'/usr/local/lib/antirkn-runner/v12')
from tt_common import toml_read,toml_bytes
p=Path('/opt/trusttunnel-fixture');p.mkdir(mode=0o700,exist_ok=True)
subprocess.run(['systemctl','stop','trusttunnel-fixture'],check=False,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
if not (p/'trusttunnel_endpoint').exists():shutil.copy2('/usr/local/bin/trusttunnel_endpoint',p/'trusttunnel_endpoint')
v=toml_read('/etc/antirkn-components/trusttunnel/'+'b'*32+'/vpn.toml')
v.update(listen_address='0.0.0.0:28444',credentials_file=str(p/'users.toml'),custom={'keep':['one','two']})
h={'main_hosts':[{'hostname':'tt.fixture.test','cert_chain_path':'/etc/tt-fixture/certificate.pem','private_key_path':'/etc/tt-fixture/private.pem','keep':'yes'}]}
(p/'vpn.toml').write_bytes(toml_bytes(v));(p/'hosts.toml').write_bytes(toml_bytes(h))
(p/'users.toml').write_text('[[client]]\nusername="external"\npassword="synthetic-external-password"\nmax_http2_conns=5\n')
for f in [p,*p.iterdir()]:os.chown(f,1000,0)
Path('/etc/systemd/system/trusttunnel-fixture.service').write_text('[Unit]\nDescription=External TT fixture\n[Service]\nWorkingDirectory=/opt/trusttunnel-fixture\nExecStart=/opt/trusttunnel-fixture/trusttunnel_endpoint vpn.toml hosts.toml\n')
subprocess.run(['systemctl','daemon-reload'],check=True);subprocess.run(['systemctl','restart','trusttunnel-fixture'],check=True)
""")
    found=rpc(dict(version=1,action='tt_discover'))
    check(found['code']=='ok' and len(found['tt']['resources'])==1,'existing_native_discovered')
    r=found['tt']['resources'][0];before=remote('sha256sum /opt/trusttunnel-fixture/users.toml').stdout
    metadata=remote('stat -c "%u:%g:%a" /opt/trusttunnel-fixture/vpn.toml /opt/trusttunnel-fixture/hosts.toml').stdout
    changes={**r['values'],'hostIndex':0,'domain':'tt.fixture.test','certificateId':''}
    changes['outbound']='socks5';changes['socksAddress']='127.0.0.1:1080'
    p=dict(resourceId=r['id'],observedHash=r['fingerprint'],changes=changes)
    apply('tt_external_plan','tt_external_edit',p,3)
    check(remote('sha256sum /opt/trusttunnel-fixture/users.toml').stdout==before,'external_credentials_preserved')
    check(remote('stat -c "%u:%g:%a" /opt/trusttunnel-fixture/vpn.toml /opt/trusttunnel-fixture/hosts.toml').stdout==metadata,'installation_owner_group_and_modes_preserved')
    check(python("import sys;sys.path.insert(0,'/usr/local/lib/antirkn-runner/v12');from tt_common import read,toml_loads;toml_read=lambda p:toml_loads(read(p,1000).decode());assert toml_read('/opt/trusttunnel-fixture/vpn.toml')['custom']=={'keep':['one','two']};assert toml_read('/opt/trusttunnel-fixture/hosts.toml')['main_hosts'][0]['keep']=='yes'").returncode==0,'external_unknown_fields_preserved')
    stale=rpc(dict(version=1,action='tt_external_plan',payload=json.dumps(p)))
    check(stale['code']=='tt_conflict','external_stale_plan_rejected')


def renew_fixture():
    unit='antirkn-tt@'+'b'*32+'.service'
    before=remote('systemctl show '+unit+' --property=MainPID --value').stdout
    old=observed()[0]['certificate']['fingerprint']
    python("""from pathlib import Path
import subprocess,sys
p=Path('/etc/tt-fixture')
subprocess.run(['openssl','x509','-req','-in',str(p/'request.pem'),'-CA',str(p/'ca.crt'),'-CAkey',str(p/'ca.key'),'-CAcreateserial','-days','6','-extfile',str(p/'ext.cnf'),'-out',str(p/'certificate.pem')],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
sys.path.insert(0,'/usr/local/lib/antirkn-runner/v12')
from tt_certificates import watch
watch()
""")
    new=observed()[0]
    check(new['confirmed'] and new['certificate']['fingerprint']!=old,'renewed_certificate_served')
    check(remote('systemctl show '+unit+' --property=MainPID --value').stdout!=before,'certificate_change_restarts_service')
    before=remote('systemctl show '+unit+' --property=MainPID --value').stdout
    python("""from pathlib import Path
import sys
sys.path.insert(0,'/usr/local/lib/antirkn-runner/v12')
from tt_certificates import watch,record
p=Path('/etc/tt-fixture/private.pem');old=p.read_bytes()
try:
 p.write_text('incomplete-key');watch();assert record('e'*32)['error']=='tt_certificate_invalid'
finally:p.write_bytes(old)
watch()
""")
    check(remote('systemctl show '+unit+' --property=MainPID --value').stdout==before,'incomplete_pair_keeps_running_certificate')

def main():
    if '--diagnose-existing' in sys.argv:
        print(python("""import sys,traceback
sys.path.insert(0,'/usr/local/lib/antirkn-runner/v12')
import tt_external as ext
print('Candidates',ext.candidates())
for unit in ext.candidates():
 try:
  r=ext.definition(unit);print('Definition',r)
  r['id']=ext.digest({k:r[k] for k in ('unit','settings','hosts')})[:32]
  ext.public_snapshot(r['id']);print('Snapshot OK')
 except Exception as e:
  print(type(e).__name__,getattr(e,'code','redacted'))
  for f in traceback.extract_tb(e.__traceback__):print(f.filename,f.lineno,f.name)
""").stdout.decode());return
    if '--diagnose-socks' in sys.argv:
        print(remote('journalctl -u tt-socks-fixture -n 15 --no-pager').stdout.decode());return
    if '--diagnose' in sys.argv:
        r=python("""import sys,sqlite3,json,traceback,subprocess
sys.path.insert(0,'/usr/local/lib/antirkn-runner/v12')
import tt,tt_external
from runner import Store
s=Store('/var/lib/antirkn-runner');row=s.db.execute("SELECT * FROM jobs WHERE request LIKE '%tt_%' ORDER BY created DESC LIMIT 1").fetchone()
req=json.loads(row['request'])
print('Checkpoint',row['checkpoint'],'Status',row['status'])
try:
 factory=tt_external.ExternalTtEdit if req['kind']=='tt_external_edit' else tt.TtApply
 factory(s,req).step(row['checkpoint'])
except Exception as e:
 print(type(e).__name__,getattr(e,'code','redacted'))
 for f in traceback.extract_tb(e.__traceback__):print(f.filename,f.lineno,f.name)
log=subprocess.check_output(['journalctl','-u',tt.unit_for('b'*32),'-n','15','--no-pager'],text=True)
from tt_common import toml_read
try:
 for c in toml_read(tt.paths('b'*32)[2]).get('client',[]):
  for value in c.values():
   if isinstance(value,str):log=log.replace(value,'<redacted>')
except Exception:pass
print(log)
""".replace('\n+','\n'))
        print(r.stdout.decode());return
    mihomo=bootstrap()
    if '--external-only' in sys.argv:
        external_fixture()
        (ROOT/'docs/evidence/tt-existing.json').write_text(json.dumps(dict(ownerUid=1000,runnerVersion=12,results=results),indent=2)+'\n')
        return
    if '--existing-only' in sys.argv:
        external_fixture();renew_fixture();return
    if '--reset-managed' in sys.argv:
        python("""import pathlib,subprocess,shutil,sqlite3
assert pathlib.Path('/etc/hostname').read_text().strip()=='antirkn-runner-fixture'
unit='antirkn-tt@'+'b'*32+'.service'
subprocess.run(['systemctl','disable','--now',unit],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
shutil.rmtree('/etc/antirkn-components/trusttunnel/'+'b'*32,ignore_errors=True)
pathlib.Path('/etc/systemd/system',unit).unlink(missing_ok=True)
db=sqlite3.connect('/var/lib/antirkn-runner/jobs.sqlite');db.execute('DELETE FROM tt_resources WHERE id=?',('b'*32,));db.commit();db.close()
""".replace('\n+','\n'))
    if '--deploy-only' in sys.argv:return
    certificate_fixture();p=desired();apply('tt_plan','tt_apply',p,3);before=observed()
    class Server(socketserver.ThreadingTCPServer):allow_reuse_address=True;daemon_threads=True
    tcp=Server(('127.0.0.1',29890),Echo);threading.Thread(target=tcp.serve_forever,daemon=True).start()
    udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);udp.bind(('127.0.0.1',29891));udp.settimeout(.5);stop=threading.Event()
    def echo():
        while not stop.is_set():
            try:data,peer=udp.recvfrom(65535);udp.sendto(data,peer)
            except socket.timeout:pass
            except OSError:break
    threading.Thread(target=echo,daemon=True).start()
    try:
        if '--outbound-only' not in sys.argv:
            check(before[0]['confirmed'],'server_confirmed');network(mihomo,p,before)
            changed=copy.deepcopy(p);changed['users'][0]['enabled']=False;changed['resources'][0]['name']='Edited TT'
            apply('tt_plan','tt_apply',changed,3);after=observed()
            check([c['password'] for c in before[0]['clients']]==[c['password'] for c in after[0]['clients']],'stable_passwords')
            network(mihomo,p,before,expected=False);network(mihomo,changed,after,1)
            apply('tt_plan','tt_apply',p,3)
        socks_fixture(mihomo)
        changed=copy.deepcopy(p);changed['resources'][0]['outbound']='socks5'
        apply('tt_plan','tt_apply',changed,3);network(mihomo,changed,observed(),0)
        changed['resources'][0]['quic']=True
        apply('tt_plan','tt_apply',changed,3);network(mihomo,changed,observed(),1)
        external_fixture();renew_fixture()
        (DIRECTORY/'payload.json').write_text(json.dumps(changed))
    finally:stop.set();tcp.shutdown();tcp.server_close();udp.close()
    (ROOT/'docs/evidence/tt-network.json').write_text(json.dumps(dict(os='Ubuntu 24.04 x86_64',trusttunnel='1.1.0',mihomo=json.loads((DIRECTORY/'mihomo-release.json').read_text()),results=results),indent=2)+'\n')


if __name__=='__main__':main()
