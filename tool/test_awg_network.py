#!/usr/bin/env python3
"""Short real Mihomo TCP/UDP + client revocation acceptance on the AWG VM."""
import copy
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import socketserver
import struct
import subprocess
import threading
import time
from test_awg_vm import rpc, wait, ROOT
from test_vless_vm import socks, free_port

MIHOMO=Path('/tmp/antirkn-mihomo')
DIRECTORY=Path(os.environ['ANTIRKN_VM_DIRECTORY'])
WORKSPACE='a'*32
results={}

def check(value,name):
    if not value:raise AssertionError(name)
    results[name]=True;print('PASS',name,flush=True)


def state():
    result=rpc(dict(version=1,action='awg_state',id=WORKSPACE))
    check(result['code']=='ok','readback')
    return result['awgState']


def apply(p):
    plan=rpc(dict(version=1,action='awg_plan',id=WORKSPACE,payload=json.dumps(p)))
    check(plan['code']=='ok','plan')
    req=dict(version=1,action='submit',kind='awg_apply',id=secrets.token_hex(16),count=len(p['resources'])+2,interval=1,payload=json.dumps(p),fingerprint=plan['awgPlan']['fingerprint'])
    job=wait(req);check(job['status']=='succeeded','apply')
    check(rpc(req)['jobs'][0]['sequence']==job['sequence'],'idempotent_repeat')
    return state()


def network(p,observed,user_index,expected=True):
    uid=p['users'][user_index]['id'];r=p['resources'][0]
    directory=DIRECTORY/('network-'+str(user_index));directory.mkdir(mode=0o700,exist_ok=True)
    port=free_port()
    workspace=dict(version=2,id=WORKSPACE,users=[dict(id=u['id'],enabled=True,login='client'+str(i),name='Client '+str(i)) for i,u in enumerate(p['users'])],
        inbounds=[],awgInterfaces=[dict(serverId='fixture',spec=x) for x in p['resources']],servers={'awg/fixture':dict(observed=observed)},profiles={})
    template={'mixed-port':port,'allow-lan':False,'mode':'rule','log-level':'silent','ipv6':False,'dns':{'enable':False},'proxies':[],
        'proxy-groups':[{'name':'TEST','type':'select','include-all-proxies':True}],'rules':['MATCH,TEST']}
    input_file=directory/'input.json';input_file.write_text(json.dumps(dict(workspace=workspace,userId=uid,resourceId=r['id'],template=template)));input_file.chmod(0o600)
    config=directory/'config.yaml'
    subprocess.run(['dart','run','tool/compile_vless_fixture.dart',str(input_file),str(config)],cwd=ROOT,check=True,stdout=subprocess.DEVNULL)
    config.chmod(0o600)
    result=subprocess.run([str(MIHOMO),'-t','-d',str(directory),'-f',str(config)],capture_output=True)
    check(result.returncode==0,'mihomo_config')
    process=subprocess.Popen([str(MIHOMO),'-d',str(directory),'-f',str(config)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        for _ in range(40):
            try:
                with socket.create_connection(('127.0.0.1',port),timeout=.1):break
            except OSError:time.sleep(.1)
        ok=False
        try:
            s,_=socks(port,1,'10.0.2.2',29890)
            with s:
                s.settimeout(8);s.sendall(b'AWG');ok=s.recv(16)==b'AWG-OK'
        except (OSError,RuntimeError):pass
        check(ok==expected,('tcp_client_'+str(user_index)) if expected else 'revoked_old_profile')
        if expected:
            control,(_,udpport)=socks(port,3,'0.0.0.0',0)
            with control,socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as udp:
                udp.settimeout(8);message=secrets.token_bytes(48)
                packet=b'\x00\x00\x00\x01'+socket.inet_aton('10.0.2.2')+struct.pack('!H',29891)+message
                udp.sendto(packet,('127.0.0.1',udpport));data,_=udp.recvfrom(65535)
                check(data.endswith(message),'udp_client_'+str(user_index))
    finally:process.terminate();process.wait(timeout=10)


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(10)
        if self.request.recv(16)==b'AWG':self.request.sendall(b'AWG-OK')


def main():
    check(hashlib.sha256(MIHOMO.read_bytes()).hexdigest()=='3e92df24f5e80e86b9cf9183ceb7bb575f0bd132a9dc4081dae42e80f21076ae','pinned_mihomo')
    class Server(socketserver.ThreadingTCPServer):allow_reuse_address=True;daemon_threads=True
    tcp=Server(('127.0.0.1',29890),Echo);threading.Thread(target=tcp.serve_forever,daemon=True).start()
    udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);udp.bind(('127.0.0.1',29891));udp.settimeout(.5);stop=threading.Event()
    def echo():
        while not stop.is_set():
            try:data,peer=udp.recvfrom(65535);udp.sendto(data,peer)
            except socket.timeout:pass
    threading.Thread(target=echo,daemon=True).start()
    try:
        p=json.loads((DIRECTORY/'payload.json').read_text());before=state();check(all(r['confirmed'] for r in before),'confirmed_running')
        check(len({c['privateKey'] for c in before[0]['clients']})==2,'distinct_client_keys')
        network(p,before,0)
        changed=copy.deepcopy(p);changed['resources'][0]['name']='Edited AWG';changed['users'][0]['enabled']=False
        after=apply(changed)
        check([c['privateKey'] for c in before[0]['clients']]==[c['privateKey'] for c in after[0]['clients']],'stable_keys_after_edit')
        network(p,before,0,expected=False)
        network(changed,after,1)
        restored=apply(p);check(all(r['confirmed'] for r in restored),'restored')
    finally:stop.set();tcp.shutdown();tcp.server_close();udp.close()
    (ROOT/'docs/evidence/awg-network.json').write_text(json.dumps(dict(mihomo='1.19.30',awg='3.1.20260828',tools='3.1.20260812',os='Ubuntu 24.04 x86_64',results=results),indent=2)+'\n')


if __name__=='__main__':main()
