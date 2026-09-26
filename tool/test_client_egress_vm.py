#!/usr/bin/env python3
"""Client egress acceptance on artifacts/client-egress-test ONLY.

Use a disposable overlay of the server-workflow Ubuntu fixture. A separate
REALITY exit on the host routes probes to controlled HTTP/DNS responders.
No credentials or live-server addresses are printed or stored in evidence.
"""
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import secrets
import socket
import socketserver
import ssl
import struct
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
DIRECTORY = ROOT / 'artifacts/client-egress-test'
os.environ['ANTIRKN_VM_DIRECTORY'] = str(DIRECTORY)
from test_panel_vm import python, remote, bundle_strings

PREFIX = "import sys,json;sys.path.insert(0,'/usr/local/lib/antirkn-runner/v46');"
RESULTS = {}
COUNTS = {'tcp': 0, 'udp': 0}


def check(ok, label):
    if not ok: raise AssertionError(label)
    RESULTS[label] = True
    print('PASS', label, flush=True)


def deploy():
    bundle = json.loads(bundle_strings()['runnerBundle'])
    python("""import sys,json,base64,pathlib,subprocess
assert pathlib.Path('/etc/hostname').read_text().strip()=='antirkn-runner-fixture'
bundle=json.load(sys.stdin)
subprocess.run(['systemctl','stop','antirkn-runner'],check=True)
base=pathlib.Path('/usr/local/lib/antirkn-runner/v46')
for name,raw in bundle['files'].items():
 path=pathlib.Path('/etc/systemd/system/antirkn-runner.service') if name=='antirkn-runner.service' else base/name
 path.write_bytes(base64.b64decode(raw));path.chmod(0o644)
(base/'manifest.json').write_text(json.dumps(dict(release=bundle['release'],hashes=bundle['hashes'])))
subprocess.run(['systemctl','daemon-reload'],check=True)
subprocess.run(['systemctl','start','antirkn-runner'],check=True)
""", json.dumps(bundle).encode())


def rpc(req):
    result = remote('/usr/bin/python3 -I /usr/local/lib/antirkn-runner/v46/runner.py rpc', json.dumps(req).encode(), check=False)
    return json.loads(result.stdout)


def apply(payload, action='egress_plan', kind='egress_apply'):
    planned = rpc(dict(version=1, action=action, payload=json.dumps(payload)))
    check(planned['code'] == 'ok', 'plan_' + kind + '_' + planned['code'])
    req = dict(version=1, action='submit', id=secrets.token_hex(16), kind=kind, count=3, interval=1,
               payload=json.dumps(payload), fingerprint=planned['egress']['fingerprint'])
    check(rpc(req)['code'] == 'ok', 'submit_' + kind)
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        status = rpc(dict(version=1, action='status', id=req['id'], cursor=0))['jobs'][0]
        if status['status'] not in ('running', 'planned'):
            check(status['status'] == 'succeeded', kind + '_' + status['status'] + '_' + status['events'][-1]['code'])
            return req
        time.sleep(.3)
    raise AssertionError('egress job timeout')


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); return sock.getsockname()[1]


def fixtures():
    binary = DIRECTORY / 'xray'
    if not binary.exists():
        binary.write_bytes(remote('cat /usr/local/x-ui/bin/xray-linux-amd64').stdout); binary.chmod(0o700)
    key, cert = DIRECTORY / 'tls.key', DIRECTORY / 'tls.crt'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(key),
        '-out', str(cert), '-days', '2', '-subj', '/CN=egress.test', '-addext', 'subjectAltName=DNS:egress.test'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    key.chmod(0o600)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.load_cert_chain(cert, key)
    context.set_ecdh_curve('X25519'); context.set_alpn_protocols(['h2', 'http/1.1'])
    class TLS(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.settimeout(5)
            try:
                with context.wrap_socket(self.request, server_side=True) as connection:
                    if connection.selected_alpn_protocol() == 'h2': connection.sendall(bytes.fromhex('000000040000000000'))
                    connection.recv(4096)
            except (OSError, ssl.SSLError): pass
    class Server(socketserver.ThreadingMixIn, socketserver.TCPServer):
        daemon_threads = True; allow_reuse_address = True
    tls = Server(('127.0.0.1', 0), TLS)
    class HTTP(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            COUNTS['tcp'] += 1
            self.send_response(204); self.end_headers()
        def log_message(self, *args): pass
    http_server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), HTTP)
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); udp.bind(('127.0.0.1', 0)); udp.settimeout(.5)
    stop = threading.Event()
    def dns():
        while not stop.is_set():
            try:
                query, address = udp.recvfrom(4096)
                COUNTS['udp'] += 1
                answer = query[:2] + b'\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00' + query[12:] + b'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04\xc0\x00\x02\x01'
                udp.sendto(answer, address)
            except socket.timeout: pass
            except OSError: break
    for fn in (tls.serve_forever, http_server.serve_forever, dns): threading.Thread(target=fn, daemon=True).start()
    keys = subprocess.check_output([str(binary), 'x25519'], text=True)
    values = dict(line.split(': ', 1) for line in keys.splitlines() if ': ' in line)
    private = values['PrivateKey']; public = values.get('Password') or values.get('Password (PublicKey)') or values.get('PublicKey')
    uid = str(uuid.uuid4()); exit_port = port()
    config = dict(log=dict(loglevel='debug'), inbounds=[dict(listen='127.0.0.1', port=exit_port, protocol='vless',
        settings=dict(clients=[dict(id=uid, flow='xtls-rprx-vision')], decryption='none'),
        streamSettings=dict(network='raw', security='reality', realitySettings=dict(target='127.0.0.1:' + str(tls.server_address[1]),
            serverNames=['egress.test'], privateKey=private, shortIds=['abcd'])))],
        outbounds=[dict(tag='http', protocol='freedom', settings=dict(redirect='127.0.0.1:' + str(http_server.server_address[1]), finalRules=[dict(action='allow', ip=['127.0.0.1'])])),
                   dict(tag='dns', protocol='freedom', settings=dict(redirect='127.0.0.1:' + str(udp.getsockname()[1]), finalRules=[dict(action='allow', ip=['127.0.0.1'])])),
                   dict(tag='block', protocol='blackhole')],
        routing=dict(rules=[dict(type='field', port='53', outboundTag='dns'), dict(type='field', port='80', outboundTag='http'),
                            dict(type='field', network='tcp,udp', outboundTag='block')]))
    path = DIRECTORY / 'exit.json'; path.write_text(json.dumps(config)); path.chmod(0o600)
    log = (DIRECTORY / 'exit.log').open('w')
    (DIRECTORY / 'exit.log').chmod(0o600)
    process = subprocess.Popen([str(binary), 'run', '-config', str(path)], stdout=log, stderr=log)
    time.sleep(.4)
    check(process.poll() is None, 'separate_reality_exit_started')
    link = f'vless://{uid}@10.0.2.2:{exit_port}?type=tcp&security=reality&flow=xtls-rprx-vision&sni=egress.test&pbk={public}&sid=abcd#Fixture'
    def close():
        process.terminate(); process.wait(timeout=10); log.close(); stop.set(); udp.close(); tls.shutdown(); http_server.shutdown()
    return link, close


def setup_tt_fixture():
    import tarfile
    archive = ROOT / 'artifacts/tt-test/trusttunnel.tar.gz'
    expected = json.loads((ROOT / 'schemas/component-releases.json').read_text())['trusttunnel']['archives']['endpoint']['sha256']
    check(hashlib.sha256(archive.read_bytes()).hexdigest() == expected, 'official_trusttunnel_archive_digest')
    remote('systemctl stop trusttunnel-egress-test.service', check=False)
    remote('mkdir -p -m 700 /opt/egress-tt')
    with tarfile.open(archive) as tar:
        member = next(m for m in tar.getmembers() if m.name.endswith('/trusttunnel_endpoint'))
        remote('cat > /opt/egress-tt/trusttunnel_endpoint', tar.extractfile(member).read())
    remote('chmod 755 /opt/egress-tt/trusttunnel_endpoint')
    for name, source in [('tls.key', DIRECTORY / 'tls.key'), ('tls.crt', DIRECTORY / 'tls.crt'),
                         ('mihomo', ROOT / 'artifacts/tt-test/mihomo-compatible')]:
        remote('umask 077; cat > /opt/egress-tt/' + name, source.read_bytes())
    remote('chmod 700 /opt/egress-tt/mihomo')
    python(PREFIX + """from pathlib import Path
import subprocess
from tt_common import toml_bytes
p=Path('/opt/egress-tt')
v=dict(listen_address='127.0.0.1:28443',ipv6_available=True,allow_private_network_connections=False,
       credentials_file=str(p/'credentials.toml'),listen_protocols=dict(http1={},http2={}),forward_protocol={'direct':{}})
(p/'vpn.toml').write_bytes(toml_bytes(v))
(p/'hosts.toml').write_bytes(toml_bytes(dict(main_hosts=[dict(hostname='egress.test',cert_chain_path=str(p/'tls.crt'),private_key_path=str(p/'tls.key'))])))
(p/'credentials.toml').write_bytes(toml_bytes(dict(client=[dict(username='fixture',password='fixture-only-secret')])) )
unit=Path('/etc/systemd/system/trusttunnel-egress-test.service')
unit.write_text('[Unit]\\nDescription=Isolated egress TT test\\n[Service]\\nWorkingDirectory=/opt/egress-tt\\nExecStart=/opt/egress-tt/trusttunnel_endpoint vpn.toml hosts.toml\\n')
subprocess.run(['systemctl','daemon-reload'],check=True)
subprocess.run(['systemctl','restart',unit.name],check=True)
""")


def test_tt_traffic():
    before = dict(COUNTS)
    python(PREFIX + """import os,socket,subprocess,time
from pathlib import Path
from egress_probe import check
p=Path('/opt/egress-tt')
config={'mixed-port':28999,'allow-lan':False,'mode':'rule','log-level':'silent','ipv6':False,
'dns':{'enable':False},'proxies':[{'name':'TT','type':'trusttunnel','server':'127.0.0.1','port':28443,
'username':'fixture','password':'fixture-only-secret','sni':'egress.test','udp':True,'quic':False}],
'proxy-groups':[{'name':'EXIT','type':'select','proxies':['TT']}],'rules':['MATCH,EXIT']}
path=p/'mihomo.json';path.write_text(json.dumps(config));path.chmod(0o600)
process=subprocess.Popen([str(p/'mihomo'),'-d',str(p),'-f',str(path)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,env={**os.environ,'SSL_CERT_FILE':str(p/'tls.crt')})
try:
 for _ in range(50):
  try:
   with socket.create_connection(('127.0.0.1',28999),timeout=.1):break
  except OSError:time.sleep(.1)
 result=check(28999);assert result['tcp'] and result['udp']
finally:process.terminate();process.wait(timeout=10)
""")
    check(COUNTS['tcp'] > before['tcp'] and COUNTS['udp'] > before['udp'], 'real_trusttunnel_tcp_udp_via_local_socks_and_vless')



def test_vless_traffic(info):
    # Exercise a real client -> panel inbound -> VLESS exit chain. The first
    # hop is a disposable loopback-only inbound; credentials are never exported.
    before = dict(COUNTS)
    python(PREFIX + """import socket,time,uuid
from runner import Store,STATE
from vless import panel_for,canonical
from egress_probe import outbound
s=Store(STATE);p=json.load(sys.stdin);api=panel_for(s,p['panelId'])
with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
uid=str(uuid.uuid4());remark='egress-loopback-fixture-'+uid
row=dict(enable=True,remark=remark,listen='127.0.0.1',port=port,protocol='vless',
 settings=canonical(dict(clients=[dict(id=uid,email=remark,enable=True)],decryption='none')),
 streamSettings=canonical(dict(network='raw',security='none')),sniffing='{}')
api.call('/panel/api/inbounds/add',row)
r=next(x for x in api.call('/panel/api/inbounds/list') if x['remark']==remark)
try:
 api.call('/panel/api/server/restartXrayService',{})
 for _ in range(80):
  try:
   with socket.create_connection(('127.0.0.1',port),timeout=.1):break
  except OSError:time.sleep(.1)
 connection=dict(outbound=dict(protocol='vless',settings=dict(vnext=[dict(address='127.0.0.1',port=port,users=[dict(id=uid,encryption='none')])]),streamSettings=dict(network='raw',security='none')))
 result=outbound(connection,STATE);assert result['tcp'] and result['udp']
finally:
 api.call('/panel/api/inbounds/del/%d'%r['id'],{})
 api.call('/panel/api/server/restartXrayService',{});s.close()
""", json.dumps(info).encode())
    check(COUNTS['tcp'] > before['tcp'] and COUNTS['udp'] > before['udp'], 'real_vless_client_tcp_udp_via_second_vless_server')


def test_service_access(info):
    # Select a real existing managed inbound, like the UI catalogue does.
    row = json.loads(python(PREFIX + """from runner import Store,STATE
from vless import panel_for
from observed_inbounds import object_field
s=Store(STATE);p=json.load(sys.stdin);rows=panel_for(s,p['panelId']).call('/panel/api/inbounds/list')
r=next(r for r in rows if r['protocol']=='vless' and r['enable'] and object_field(r['streamSettings']).get('network') in ('tcp','raw'))
print(json.dumps({'id':r['id'],'port':r['port']}));s.close()
""", json.dumps(info).encode()).stdout)
    payload = dict(**info, source='fixture-server-A', inboundId=row['id'], endpoint='192.0.2.25', externalPort=row['port'])
    req = apply(payload, 'egress_access_plan', 'egress_access')
    first = rpc(dict(version=1, action='egress_access_read', id=req['id']))
    check(first['code'] == 'ok' and first['egress']['uri'].startswith('vless://'), 'catalogue_issues_dedicated_vless_access')
    req = apply(payload, 'egress_access_plan', 'egress_access')
    second = rpc(dict(version=1, action='egress_access_read', id=req['id']))
    check(first['egress']['uri'] == second['egress']['uri'], 'catalogue_access_is_stable_on_repeat')
    python(PREFIX + """from runner import Store,STATE
from vless import panel_for,wanted_inbound,owned_rows,canonical
from observed_inbounds import object_field
from egress_access import clients_for
s=Store(STATE);p=json.load(sys.stdin);api=panel_for(s,p['panelId']);r=api.call('/panel/api/inbounds/get/%d'%p['inboundId'])
saved=next(x for rid,x in owned_rows(s).items() if r['remark']=='AntiRKN:'+x['workspaceId']+':'+rid)
wanted=wanted_inbound(dict(workspaceId=saved['workspaceId'],users=[]),saved['spec'],r)
assert len(clients_for(r))==1
assert object_field(wanted['settings'])['clients']==clients_for(r)
s.close()
""", json.dumps(payload).encode())
    check(True, 'ordinary_client_reconciliation_preserves_service_access')


def main():
    check(DIRECTORY.name == 'client-egress-test', 'dedicated_disposable_fixture')
    deploy()
    info = json.loads(python(PREFIX + "from runner import Store,STATE;from panel_discovery import discover;s=Store(STATE);d,a=discover(s);print(json.dumps({'panelId':a['id']}));s.close()").stdout)
    template = python(PREFIX + "from runner import Store,STATE;from vless import panel_for;from client_egress import read_template;s=Store(STATE);p=json.load(sys.stdin);print(json.dumps(read_template(panel_for(s,p['panelId']))[0]));s.close()", json.dumps(info).encode()).stdout
    link, close = fixtures()
    try:
        setup_tt_fixture()
        state = rpc(dict(version=1, action='egress_state'))['egress']
        if state['enabled']:
            apply(dict(**info, enabled=False, uri='', socksPort=0, observedHash=state['observedHash']))
        state = rpc(dict(version=1, action='egress_state'))['egress']
        payload = dict(**info, enabled=True, uri=link, socksPort=0, observedHash=state['observedHash'])
        apply(payload)
        check(COUNTS['tcp'] >= 2 and COUNTS['udp'] >= 2, 'tcp_and_udp_reached_exit_before_and_after_apply')
        state = rpc(dict(version=1, action='egress_state'))['egress']
        check(state['enabled'] and state['phase'] == 'applied', 'enabled_readback')
        check(rpc(dict(version=1, action='egress_check', id=info['panelId']))['code'] == 'ok', 'manual_connection_check')
        test_native_ingress()
        test_tt_traffic()
        test_vless_traffic(info)
        test_service_access(info)
        apply(dict(**info, enabled=False, uri='', socksPort=0, observedHash=rpc(dict(version=1, action='egress_state'))['egress']['observedHash']))
        after = python(PREFIX + "from runner import Store,STATE;from vless import panel_for;from client_egress import read_template;s=Store(STATE);p=json.load(sys.stdin);print(json.dumps(read_template(panel_for(s,p['panelId']))[0]));s.close()", json.dumps(info).encode()).stdout
        check(json.loads(after) == json.loads(template), 'original_panel_template_restored')
        check(python(PREFIX + "from tt_common import toml_loads;from pathlib import Path;v=toml_loads(Path('/opt/egress-tt/vpn.toml').read_text());assert v.get('forward_protocol')=={'direct':{}}").returncode == 0, 'trusttunnel_previous_exit_restored')
        check(remote('iptables -t mangle -S ANTIRKN_EGRESS', check=False).returncode != 0, 'owned_firewall_removed')
        evidence = ROOT / 'docs/evidence/client-egress-ubuntu.json'
        evidence.parent.mkdir(parents=True, exist_ok=True)
        evidence.write_text(json.dumps(dict(results=RESULTS, exitProbeCounts=COUNTS), indent=2) + '\n')
    finally: close()


def test_native_ingress():
    # A network namespace supplies decrypted client packets to an AWG-shaped
    # interface. This checks real kernel TPROXY for both TCP and UDP, separately
    # from the already covered AWG handshake/cryptographic implementation.
    python("""import subprocess
def r(*a):subprocess.run(a,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
r('ip','netns','add','egress-client')
r('ip','link','add','ar111111111111','type','veth','peer','name','client0')
r('ip','link','set','client0','netns','egress-client')
r('ip','address','add','198.18.0.1/24','dev','ar111111111111')
r('ip','-6','address','add','fd42:1672::1/64','dev','ar111111111111','nodad')
r('ip','link','set','ar111111111111','up')
r('ip','netns','exec','egress-client','ip','address','add','198.18.0.2/24','dev','client0')
r('ip','netns','exec','egress-client','ip','-6','address','add','fd42:1672::2/64','dev','client0','nodad')
r('ip','netns','exec','egress-client','ip','link','set','client0','up')
r('ip','netns','exec','egress-client','ip','link','set','lo','up')
r('ip','netns','exec','egress-client','ip','route','add','default','via','198.18.0.1')
r('ip','netns','exec','egress-client','ip','-6','route','add','default','via','fd42:1672::1')
""")
    for binary in ('iptables', 'ip6tables'):
        for protocol in ('tcp', 'udp'):
            remote(binary + ' -I INPUT 1 -i ar111111111111 -p ' + protocol + ' -m comment --comment egress-fixture-drop -j DROP')
    python(PREFIX + "from egress_network import register_interface;register_interface('ar111111111111')")
    try:
        before = dict(COUNTS)
        source = """import socket,struct
s=socket.create_connection(('1.1.1.1',80),timeout=8);s.sendall(b'GET /generate_204 HTTP/1.0\\r\\nHost: www.gstatic.com\\r\\n\\r\\n');assert b'204' in s.recv(4096);s.close()
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(8);q=b'\\x12\\x34\\x01\\x00\\x00\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x07example\\x03com\\x00\\x00\\x01\\x00\\x01';s.sendto(q,('1.1.1.1',53));a,_=s.recvfrom(4096);assert a[:2]==q[:2] and a[-4:]==b'\\xc0\\x00\\x02\\x01';s.close()
"""
        import shlex
        remote('ip netns exec egress-client python3 -c ' + shlex.quote(source))
        check(COUNTS['tcp'] > before['tcp'] and COUNTS['udp'] > before['udp'], 'native_client_tcp_udp_intercepted')
        before = dict(COUNTS)
        v6 = source.replace("'1.1.1.1'", "'2001:4860:4860::8888'").replace('socket.AF_INET,', 'socket.AF_INET6,')
        remote('ip netns exec egress-client python3 -c ' + shlex.quote(v6))
        check(COUNTS['tcp'] > before['tcp'] and COUNTS['udp'] > before['udp'], 'native_client_ipv6_tcp_udp_intercepted')
        before = dict(COUNTS)
        python("import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.sendto(b'host-probe',('192.0.2.1',53));s.close()")
        time.sleep(.2)
        check(COUNTS == before, 'host_output_not_intercepted')
        remote('systemctl restart antirkn-client-egress.service')
        remote('ip netns exec egress-client python3 -c ' + shlex.quote(source))
        check(True, 'network_service_restart_keeps_client_route')
    finally:
        for binary in ('iptables', 'ip6tables'):
            for protocol in ('tcp', 'udp'):
                remote(binary + ' -D INPUT -i ar111111111111 -p ' + protocol + ' -m comment --comment egress-fixture-drop -j DROP', check=False)
        remote('ip netns delete egress-client', check=False)
        remote('ip link delete ar111111111111', check=False)


if __name__ == '__main__': main()
