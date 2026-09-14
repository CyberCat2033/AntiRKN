#!/usr/bin/env python3
"""Real pinned 3x-ui + Mihomo tests on a disposable loopback-only Ubuntu VM.

No owner servers are used. Generated credentials and CA material stay in a
private temporary directory. Export uses the same Dart compiler as the GUI.
"""
import copy
import hashlib
import http.server
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import socketserver
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import sys

from test_panel_vm import rpc, remote, python, ROOT

PANEL_ID='10000000000000000000000000000001'
WORKSPACE='b'*32
USERS=[dict(id='c'*32,enabled=True),dict(id='d'*32,enabled=True)]
MIHOMO=Path(os.environ.get('ANTIRKN_MIHOMO','/tmp/antirkn-vless-research/mihomo'))
FIXTURE=Path(os.environ.get('ANTIRKN_VLESS_FIXTURE','/tmp/antirkn-vless-network'))
HOST_BASE=int(os.environ.get('ANTIRKN_VLESS_HOST_BASE','25443'))
results={}

def check(value,name):
    if not value: raise AssertionError(name)
    results[name]=True
    print('PASS',name,flush=True)

def public_spec(index,transport='raw',security='reality',mode='auto'):
    return dict(id=f'{index:032x}',name='VLESS '+str(index),enabled=True,deleted=False,
        listen='0.0.0.0',port=2443+index,endpoint='127.0.0.1',externalPort=HOST_BASE+index,
        transport=transport,security=security,sni='vless.test',target='10.0.2.2:29443',
        path='/antirkn/',host='',mode=mode,certificate='/etc/antirkn-test-tls/server.crt' if security=='tls' else '',
        certificateKey='/etc/antirkn-test-tls/server.key' if security=='tls' else '',region='')

def payload(resources,users=None):
    return dict(version=1,workspaceId=WORKSPACE,panelId=PANEL_ID,resources=resources,users=USERS if users is None else users)

def preview(p):
    return rpc(dict(version=1,action='vless_plan',id=PANEL_ID,payload=json.dumps(p,ensure_ascii=False)))

def apply(p,name):
    plan=preview(p)
    check(plan['code']=='ok' and 'vlessPlan' in plan,name+'_preview')
    req=dict(version=1,action='submit',id=secrets.token_hex(16),kind='vless_apply',count=len(p['resources'])+2,interval=1,
        payload=json.dumps(p,ensure_ascii=False),fingerprint=plan['vlessPlan']['fingerprint'])
    check(rpc(req)['code']=='ok',name+'_submit')
    for _ in range(120):
        job=rpc(dict(version=1,action='status',id=req['id'],cursor=0))['jobs'][0]
        if job['status'] in ('succeeded','failed','partially_applied','cancelled'):break
        time.sleep(.25)
    check(job['status']=='succeeded',name+'_succeeded')
    check(rpc(req)['jobs'][0]['sequence']==job['sequence'],name+'_replay_no_effect')
    state=rpc(dict(version=1,action='vless_state',id=PANEL_ID))['vlessState']
    check(all(r['confirmed'] for r in state),name+'_readback')
    return state,req

def free_port():
    with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]

def recv_exact(s,n):
    result=b''
    while len(result)<n:
        chunk=s.recv(n-len(result))
        if not chunk: raise RuntimeError('SOCKS connection ended')
        result+=chunk
    return result

def socks(port,command,host,remote_port):
    s=socket.create_connection(('127.0.0.1',port),timeout=15)
    s.sendall(b'\x05\x01\x00')
    if recv_exact(s,2)!=b'\x05\x00':raise RuntimeError('SOCKS greeting failed')
    s.sendall(bytes([5,command,0,1])+socket.inet_aton(host)+struct.pack('!H',remote_port))
    response=recv_exact(s,4)
    if response[1]!=0:raise RuntimeError('SOCKS request failed')
    size={1:4,4:16}.get(response[3]);address=recv_exact(s,size)
    bound_port=struct.unpack('!H',recv_exact(s,2))[0]
    return s,(socket.inet_ntop(socket.AF_INET if size==4 else socket.AF_INET6,address),bound_port)

class QuietHttp(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body=b'antirkn-vless-tcp-fixture'
        self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    def log_message(self,*args):pass


def fixtures():
    FIXTURE.mkdir(mode=0o700,exist_ok=True);FIXTURE.chmod(0o700)
    def openssl(args):subprocess.run(['openssl']+args,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if not (FIXTURE/'ca.crt').exists():
        openssl(['req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(FIXTURE/'ca.key'),'-out',str(FIXTURE/'ca.crt'),'-days','2','-subj','/CN=AntiRKN isolated test CA'])
        openssl(['req','-new','-newkey','rsa:2048','-nodes','-keyout',str(FIXTURE/'server.key'),'-out',str(FIXTURE/'server.csr'),'-subj','/CN=vless.test'])
        (FIXTURE/'extensions').write_text('subjectAltName=DNS:vless.test\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n')
        openssl(['x509','-req','-in',str(FIXTURE/'server.csr'),'-CA',str(FIXTURE/'ca.crt'),'-CAkey',str(FIXTURE/'ca.key'),'-CAcreateserial','-out',str(FIXTURE/'server.crt'),'-days','2','-extfile',str(FIXTURE/'extensions')])
    for f in FIXTURE.iterdir():
        if f.is_file():f.chmod(0o600)
    remote('mkdir -m 700 -p /etc/antirkn-test-tls')
    for name in ('server.crt','server.key'):
        remote('umask 077; cat > /etc/antirkn-test-tls/'+name,data=(FIXTURE/name).read_bytes())
    # The panel's default routing blocks RFC1918 destinations. Through its
    # supported API, allow only the two local test echo ports on this VM.
    python('''import sys,json,urllib.request,urllib.parse
from pathlib import Path
sys.path.insert(0,'/usr/local/lib/antirkn-runner/v3')
from runner import Store
from vless import panel_for
store=Store(Path('/var/lib/antirkn-runner'))
api=panel_for(store,'10000000000000000000000000000001')
value=api.call('/panel/api/xray/',{})
if isinstance(value,str):value=json.loads(value)
config=value['xraySetting']
if isinstance(config,str):config=json.loads(config)
outbound=next(o for o in config['outbounds'] if o['protocol']=='freedom')
tag=outbound['tag']
final=outbound.setdefault('settings',{}).setdefault('finalRules',[])
allow=dict(action='allow',ip=['10.0.2.2'],port='29880,29881')
changed=allow not in final
if changed:final.insert(0,allow)
rule=dict(type='field',ip=['10.0.2.2'],port='29880,29881',outboundTag=tag)
rules=config['routing']['rules']
if rule not in rules:rules.insert(0,rule);changed=True
if changed:
 req=urllib.request.Request(api.base+'/panel/api/xray/update',data=urllib.parse.urlencode(dict(xraySetting=json.dumps(config))).encode(),headers={'Content-Type':'application/x-www-form-urlencoded','Origin':api.base,'X-CSRF-Token':api.csrf})
 with api.client.open(req,timeout=20) as response:result=json.load(response)
 if result.get('success') is not True:raise RuntimeError('fixture routing setup failed')
store.close()
''')
    http_server=http.server.ThreadingHTTPServer(('127.0.0.1',29880),QuietHttp)
    threading.Thread(target=http_server.serve_forever,daemon=True).start()
    udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);udp.bind(('127.0.0.1',29881));udp.settimeout(.5)
    stop=threading.Event()
    def echo():
        while not stop.is_set():
            try:data,addr=udp.recvfrom(65535);udp.sendto(data,addr)
            except socket.timeout:pass
            except OSError:break
    threading.Thread(target=echo,daemon=True).start()
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version=ssl.TLSVersion.TLSv1_3
    context.load_cert_chain(FIXTURE/'server.crt',FIXTURE/'server.key')
    context.set_ecdh_curve('X25519')
    context.set_alpn_protocols(['h2','http/1.1'])
    class TlsHandler(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.settimeout(8)
            try:
                with context.wrap_socket(self.request,server_side=True) as connection:
                    if connection.selected_alpn_protocol()=='h2':
                        connection.sendall(bytes.fromhex('000000040000000000'))
                    connection.recv(4096)
            except (OSError,ssl.SSLError):pass
    class TlsServer(socketserver.ThreadingMixIn,socketserver.TCPServer):
        daemon_threads=True
        allow_reuse_address=True
    tls=TlsServer(('127.0.0.1',29443),TlsHandler)
    threading.Thread(target=tls.serve_forever,daemon=True).start()
    def close():
        stop.set();tls.shutdown();tls.server_close();http_server.shutdown();http_server.server_close();udp.close()
    return close

def network(state,resources,index,user_index=0,expected=True):
    r=resources[index];label=r['transport']+'_'+r['security']+'_'+r['mode']
    # All accesses are read from the server; only the selected user's profile is
    # compiled. Additional listeners/CA are local controlled test configuration.
    port=free_port()
    template={'mixed-port':port,'allow-lan':False,'mode':'rule','log-level':'silent','ipv6':False,
        'dns':{'enable':False},'tls':{'custom-certifactes':[(FIXTURE/'ca.crt').read_text()]},
        'proxies':[],'proxy-groups':[{'name':'TEST','type':'select','include-all-proxies':True}], 'rules':['MATCH,TEST']}
    workspace=dict(version=1,id=WORKSPACE,users=[dict(id=u['id'],enabled=u['enabled'],login='user'+str(i),name='Client '+str(i)) for i,u in enumerate(USERS)],
        inbounds=[dict(serverId='fixture',spec=s) for s in resources],servers={'fixture':dict(observed=state)},profiles={})
    directory=FIXTURE/(label+'-'+str(user_index));directory.mkdir(mode=0o700,exist_ok=True)
    input_path=directory/'input.json';input_path.write_text(json.dumps(dict(workspace=workspace,userId=USERS[user_index]['id'],resourceId=r['id'],template=template)));input_path.chmod(0o600)
    config=directory/'config.yaml'
    subprocess.run(['dart','run','tool/compile_vless_fixture.dart',str(input_path),str(config)],cwd=ROOT,check=True,stdout=subprocess.DEVNULL)
    config.chmod(0o600)
    checked=subprocess.run([str(MIHOMO),'-t','-d',str(directory),'-f',str(config)],capture_output=True)
    check(checked.returncode==0,label+'_core_config')
    log=(directory/'runtime.txt').open('w');(directory/'runtime.txt').chmod(0o600)
    process=subprocess.Popen([str(MIHOMO),'-d',str(directory),'-f',str(config)],stdout=log,stderr=log)
    try:
        for _ in range(50):
            try:
                with socket.create_connection(('127.0.0.1',port),timeout=.2):break
            except OSError:time.sleep(.1)
        tcp_ok=False
        try:
            sock,_=socks(port,1,'10.0.2.2',29880)
            with sock:
                sock.sendall(b'GET / HTTP/1.0\r\nHost: fixture\r\n\r\n');data=b''
                while True:
                    b=sock.recv(4096)
                    if not b:break
                    data+=b
                    if b'antirkn-vless-tcp-fixture' in data:break
                tcp_ok=b'antirkn-vless-tcp-fixture' in data
        except (OSError,RuntimeError):pass
        check(tcp_ok==expected,label+('_tcp' if expected else '_revoked_tcp'))
        if expected:
            control,(_,bound_port)=socks(port,3,'0.0.0.0',0)
            with control,socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as sock:
                sock.settimeout(15)
                message=secrets.token_bytes(48)
                packet=b'\x00\x00\x00\x01'+socket.inet_aton('10.0.2.2')+struct.pack('!H',29881)+message
                sock.sendto(packet,('127.0.0.1',bound_port));data,_=sock.recvfrom(65535)
                check(data.endswith(message),label+'_udp')
    finally:
        process.terminate();process.wait(timeout=10);log.close()

def main():
    check(hashlib.sha256(MIHOMO.read_bytes()).hexdigest()=='8ad44e28fe72be4640254b96741b677f4074991b99186cc4486a1c28ded02b1a','pinned_mihomo_sha256')
    close=fixtures()
    try:
        resources=[public_spec(0),public_spec(1,'xhttp'),public_spec(2,'xhttp','tls','packet-up'),public_spec(3,'xhttp','tls','stream-up'),public_spec(4,'xhttp','tls','stream-one')]
        state,req=apply(payload(resources),'initial')
        check(len(state)==5 and all(len(r['clients'])==2 for r in state),'two_clients_five_inbounds')
        check(len({u['uuid'] for r in state for u in r['clients']})==10,'unique_personal_credentials')
        for i in range(len(resources)):network(state,resources,i)
        # Server changes must reach both users without rotating credentials.
        ids={(r['id'],u['id']):u['uuid'] for r in state for u in r['clients']}
        resources[0]['name']='Основной VLESS'
        resources[1]['path']='/changed/'
        next_state,_=apply(payload(resources),'shared_edit')
        check(ids=={(r['id'],u['id']):u['uuid'] for r in next_state for u in r['clients']},'edit_preserves_all_credentials')
        network(next_state,resources,1,1)
        disabled=[{**u,'enabled':i!=0} for i,u in enumerate(USERS)]
        revoked,_=apply(payload(resources,disabled),'disable_client')
        check(all(not r['clients'][0]['enabled'] and r['clients'][1]['enabled'] for r in revoked),'disable_client_all_inbounds')
        # Test previously issued profile, containing the original valid credential.
        network(next_state,resources,0,0,False)
        network(revoked,resources,1,1)
        restored,_=apply(payload(resources),'reenable_client')
        check(ids=={(r['id'],u['id']):u['uuid'] for r in restored for u in r['clients']},'reenable_preserves_credentials')
        resources[1]['mode']='stream-one'
        resources[2]['mode']='auto'
        modes,_=apply(payload(resources),'explicit_modes')
        network(modes,resources,1)
        network(modes,resources,2)
        bad=copy.deepcopy(resources);bad[1]['port']=bad[0]['port']
        check(preview(payload(bad))['code']=='vless_port_busy','colliding_port_refused')
        bad=copy.deepcopy(resources);bad[2]['sni']='wrong.test'
        check(preview(payload(bad))['code']=='vless_invalid','wrong_tls_certificate_refused')
        report=dict(results=results,panelVersion='3.7.0',xrayVersion='26.7.28',mihomoVersion='1.19.30',
            environment='Ubuntu QEMU x86_64; host Linux; loopback host-forwarded TCP; controlled TLS CA and TCP/UDP echo destinations',
            tlsTrust='Dedicated test CA, no skip-cert-verify',productionCompiler=True,
            realityCompatibility='minClientVer=1.8.2 for pinned Mihomo handshake; Xray default 26.3.27 rejects it',
            testRouting='Panel API explicitly allows only 10.0.2.2 TCP/UDP ports 29880/29881 in routing and freedom finalRules')
        target=ROOT/os.environ.get('ANTIRKN_VLESS_EVIDENCE','docs/evidence/vless-ubuntu.json');target.write_text(json.dumps(report,indent=2)+'\n')
    finally:close()

if __name__=='__main__':main()
