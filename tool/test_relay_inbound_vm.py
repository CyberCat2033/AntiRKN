#!/usr/bin/env python3
"""Relay inbound acceptance on a disposable regression VM overlay ONLY.

Usage: python3 tool/test_relay_inbound_vm.py [--keep-vm]

Needs the cached Ubuntu image and 3x-ui archive of tool/vm_regression.py
(artifacts/regression-vm). Runs inside a private user+network namespace.

The VM gets a real 3x-ui + Xray, a runner from the current bundle, one
internal managed VLESS REALITY inbound (relay candidate), one client-facing
managed inbound and one observed inbound. A second Xray on the host is the
client egress exit. Probes target 1.1.1.1:8080/tcp and 1.1.1.1:8053/udp.
Inside the VM these are DNATed to the host echo labelled ``direct``; the exit
redirects them to a second echo labelled ``exit``. The answer therefore names
the path the traffic really took (the VM has no other way out).
UUIDs, keys and links stay in memory; the report holds check names only.
"""
import datetime
import json
import os
from pathlib import Path
import secrets
import socket
import socketserver
import subprocess
import sys
import tarfile
import threading
import time
import traceback
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))


def enter_private_network():
    if os.environ.get('ANTIRKN_VM_NETNS') == '1':
        return
    proxies = ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')
    env = {k: v for k, v in os.environ.items() if k not in proxies}
    env['ANTIRKN_VM_NETNS'] = '1'
    os.execvpe('unshare', ['unshare', '-rn', 'sh', '-c', 'ip link set lo up && exec "$@"', 'sh',
                           sys.executable] + sys.argv, env)


if __name__ == '__main__':
    enter_private_network()

import vm_regression_lib as lib  # noqa: E402
from vm_regression_lib import remote, python, upload  # noqa: E402

WORKSPACE = 'b' * 32
PANEL_ID = '10000000000000000000000000000001'
USER = dict(id='c' * 32, enabled=True)
RELAY_ID = '0' * 31 + '7'
CLIENT_ID = '0' * 31 + '8'
OBSERVED_REMARK = 'observed-relay-fixture'
VM_ADDRESS = '10.0.2.15'  # the guest's own user-network address (not loopback)
ECHO_TCP, ECHO_UDP = 29890, 29891
EXIT_TCP, EXIT_UDP = 29892, 29893
PROBE_IP, PROBE_TCP, PROBE_UDP = '1.1.1.1', 8080, 8053
DIRECT, VIA_EXIT = 'direct', 'exit'
RESULTS = []


class CheckFailed(AssertionError):
    pass


def check(ok, label):
    RESULTS.append(dict(name=label, ok=bool(ok)))
    print('  %s %s' % ('PASS' if ok else 'FAIL', label), flush=True)
    if not ok: raise CheckFailed(label)


# ------------------------------------------------------------------ host fixtures

class _Server(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True


class LabelEcho:
    """TCP/UDP servers that answer with the label of the path that reached them."""

    def __init__(self, label, tcp_port, udp_port):
        self.label, self.ports = label, (tcp_port, udp_port)

    def __enter__(self):
        label = ('src=' + self.label).encode()

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.settimeout(5)
                try:
                    self.request.recv(64)
                    self.request.sendall(label)
                except OSError:
                    pass
        self.tcp = _Server(('127.0.0.1', self.ports[0]), Handler)
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.bind(('127.0.0.1', self.ports[1])); self.udp.settimeout(.5)
        self.stop = threading.Event()

        def udp():
            while not self.stop.is_set():
                try:
                    _, peer = self.udp.recvfrom(4096)
                    self.udp.sendto(label, peer)
                except socket.timeout:
                    pass
                except OSError:
                    break
        threading.Thread(target=self.tcp.serve_forever, daemon=True).start()
        threading.Thread(target=udp, daemon=True).start()
        return self

    def __exit__(self, *exc):
        self.stop.set(); self.tcp.shutdown(); self.tcp.server_close(); self.udp.close()
        return False


class ExitNode:
    """A separate Xray VLESS REALITY exit on the host (the client egress)."""

    def __init__(self, directory):
        self.directory = directory

    def __enter__(self):
        import http.server
        binary = self.directory / 'exit-xray'
        if not binary.exists():
            with tarfile.open(lib.fixture('panel')) as tar:
                member = next(m for m in tar.getmembers() if m.name.endswith('bin/xray-linux-amd64'))
                binary.write_bytes(tar.extractfile(member).read())
            binary.chmod(0o700)

        class Http(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(204); self.end_headers()

            def log_message(self, *args):
                pass
        self.http = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Http)
        self.dns = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.dns.bind(('127.0.0.1', 0)); self.dns.settimeout(.5)
        self.stop = threading.Event()

        def dns():
            while not self.stop.is_set():
                try:
                    query, address = self.dns.recvfrom(4096)
                    self.dns.sendto(query[:2] + b'\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00' + query[12:]
                                    + b'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04\xc0\x00\x02\x01', address)
                except socket.timeout:
                    pass
                except OSError:
                    break
        threading.Thread(target=self.http.serve_forever, daemon=True).start()
        threading.Thread(target=dns, daemon=True).start()
        keys = subprocess.check_output([str(binary), 'x25519'], text=True)
        values = dict(line.split(': ', 1) for line in keys.splitlines() if ': ' in line)
        public = values.get('Password') or values.get('Password (PublicKey)') or values.get('PublicKey')
        uid = str(uuid.uuid4())
        exit_port = lib._free_port()
        allow = [dict(action='allow', ip=['127.0.0.1'])]
        config = dict(
            log=dict(loglevel='warning'),
            inbounds=[dict(listen='127.0.0.1', port=exit_port, protocol='vless',
                           settings=dict(clients=[dict(id=uid, flow='xtls-rprx-vision')], decryption='none'),
                           streamSettings=dict(network='raw', security='reality', realitySettings=dict(
                               target='127.0.0.1:29443', serverNames=['vless.test'],
                               privateKey=values['PrivateKey'], shortIds=['abcd'])))],
            outbounds=[
                dict(tag='http', protocol='freedom', settings=dict(
                    redirect='127.0.0.1:%d' % self.http.server_address[1], finalRules=allow)),
                dict(tag='dns', protocol='freedom', settings=dict(
                    redirect='127.0.0.1:%d' % self.dns.getsockname()[1], finalRules=allow)),
                dict(tag='echo-tcp', protocol='freedom', settings=dict(
                    redirect='127.0.0.1:%d' % EXIT_TCP, finalRules=allow)),
                dict(tag='echo-udp', protocol='freedom', settings=dict(
                    redirect='127.0.0.1:%d' % EXIT_UDP, finalRules=allow)),
                dict(tag='block', protocol='blackhole')],
            routing=dict(rules=[
                dict(type='field', port='53', outboundTag='dns'),
                dict(type='field', port='80', outboundTag='http'),
                dict(type='field', network='tcp', port=str(PROBE_TCP), outboundTag='echo-tcp'),
                dict(type='field', network='udp', port=str(PROBE_UDP), outboundTag='echo-udp'),
                dict(type='field', network='tcp,udp', outboundTag='block')]))
        path = self.directory / 'exit.json'
        path.write_text(json.dumps(config)); path.chmod(0o600)
        self.log = (self.directory / 'exit.log').open('w')
        self.process = subprocess.Popen([str(binary), 'run', '-config', str(path)], stdout=self.log, stderr=self.log)
        time.sleep(.5)
        check(self.process.poll() is None, 'separate_exit_xray_started')
        self.link = ('vless://%s@10.0.2.2:%d?type=tcp&security=reality&flow=xtls-rprx-vision&sni=vless.test'
                     '&pbk=%s&sid=abcd#Exit' % (uid, exit_port, public))
        return self

    def __exit__(self, *exc):
        self.process.terminate()
        try: self.process.wait(timeout=10)
        except subprocess.TimeoutExpired: self.process.kill()
        self.log.close(); self.stop.set(); self.dns.close(); self.http.shutdown()
        (self.directory / 'exit.json').unlink(missing_ok=True)
        return False


# ------------------------------------------------------------------ VM helpers

class Fixture:
    def __init__(self, bundle):
        self.version = bundle['version']
        self.prefix = "import sys,json;sys.path.insert(0,'/usr/local/lib/antirkn-runner/%s');" % self.version
        self.rpc = lib.Rpc(self.version)

    def vm(self, source, data=None):
        """Run Python with runner modules on the VM; returns parsed stdout JSON."""
        out = python(self.prefix + source, None if data is None else json.dumps(data).encode()).stdout
        return json.loads(out) if out.strip() else None

    def api(self, body, data=None):
        return self.vm("from runner import Store,STATE\nfrom vless import panel_for\ns=Store(STATE);api=panel_for(s,%r)\n"
                       "try:\n%s\nfinally:\n s.close()\n" % (PANEL_ID, '\n'.join(' ' + l for l in body.splitlines())), data)

    def template(self):
        return self.api("from client_egress import read_template\nprint(json.dumps(read_template(api)[0]))")

    def rows(self):
        """Inbound rows without credentials: id, remark, port, tag, client emails."""
        return self.api("from observed_inbounds import object_field\n"
                        "print(json.dumps([dict(id=r['id'],remark=r['remark'],port=r['port'],tag=r.get('tag'),"
                        "emails=[c.get('email') for c in object_field(r['settings']).get('clients',[])])"
                        " for r in api.call('/panel/api/inbounds/list')]))")

    def row(self, remark):
        return next(r for r in self.rows() if r['remark'] == remark)

    def configure(self, template, remove=None, add=None, last=False):
        return self.vm("import relay_inbound as r;p=json.load(sys.stdin)\n"
                       "print(json.dumps(r.configure(p['t'],p['remove'],p['add'],p['last'])))",
                       dict(t=template, remove=remove, add=add, last=last))

    def job(self, action, kind, payload, key):
        planned = self.rpc(dict(version=1, action=action, payload=json.dumps(payload)))
        if planned.get('code') != 'ok':
            return planned.get('code'), None
        req = dict(version=1, action='submit', id=secrets.token_hex(16), kind=kind, count=3, interval=1,
                   payload=json.dumps(payload), fingerprint=planned[key]['fingerprint'])
        job = self.rpc.run_job(req, timeout=300)
        return job['status'], job

    def relay(self, inbound_id, enabled):
        state = self.rpc(dict(version=1, action='relay_state'))['relay']
        return self.job('relay_plan', 'relay_apply', dict(panelId=PANEL_ID, inboundId=inbound_id, enabled=enabled,
                                                          observedHash=state['observedHash']), 'relay')

    def egress(self, link):
        state = self.rpc(dict(version=1, action='egress_state'))['egress']
        return self.job('egress_plan', 'egress_apply', dict(panelId=PANEL_ID, enabled=link is not None, uri=link or '',
                                                            socksPort=0, observedHash=state['observedHash']), 'egress')

    def relay_state(self):
        return self.rpc(dict(version=1, action='relay_state'))

    def link(self, inbound_id, port):
        response = self.rpc(dict(version=1, action='relay_link', payload=json.dumps(dict(
            panelId=PANEL_ID, inboundId=inbound_id, endpoint=VM_ADDRESS, externalPort=port))))
        return response.get('code'), (response.get('relay') or {}).get('uri')

    def user_link(self, remark, user_uuid, port):
        """Share link of a catalogue user, built by the runner's own link code."""
        return self.api("import egress_access as a\np=json.load(sys.stdin)\n"
                        "row=next(r for r in api.call('/panel/api/inbounds/list') if r['remark']==p['remark'])\n"
                        "row=api.call('/panel/api/inbounds/get/%d'%row['id'])\n"
                        "print(json.dumps(a.link(row,dict(id=p['uuid']),p['host'],p['port'])))",
                        dict(remark=remark, uuid=user_uuid, host=VM_ADDRESS, port=port))

    def exit_of(self, uri):
        """Source address seen by the host echo for TCP and UDP through ``uri``."""
        return self.vm(PROBE_SOURCE, uri)

    def xray(self):
        pid = remote("pgrep -f 'xray-linux-amd64 -c' | head -1", check=False).stdout.decode().strip()
        tested = remote('cd /usr/local/x-ui/bin && ./xray-linux-amd64 run -test -config config.json',
                        check=False).returncode == 0
        running = self.api("from panel_api import xray_status\n"
                           "print(json.dumps(xray_status(api.call('/panel/api/server/status')).get('state')))")
        return pid, tested, running

    def running_config(self):
        return json.loads(remote('cat /usr/local/x-ui/bin/config.json').stdout)


PROBE_SOURCE = r"""
import os,socket,struct,subprocess,tempfile,time
from pathlib import Path
from egress_config import parse_link
from egress_probe import socks,BINARY
uri=json.load(sys.stdin)
out=parse_link(uri)['outbound'];out['tag']='probe'
with socket.socket() as sock:
 sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
config=dict(log=dict(loglevel='none'),inbounds=[dict(listen='127.0.0.1',port=port,protocol='socks',
 settings=dict(auth='noauth',udp=True,ip='127.0.0.1'))],outbounds=[out])
result=dict(tcp=None,udp=None)
with tempfile.TemporaryDirectory(prefix='relay-probe-',dir='/var/lib/antirkn-runner') as temp:
 path=Path(temp)/'c.json';path.write_text(json.dumps(config));path.chmod(0o600)
 process=subprocess.Popen([str(BINARY),'run','-config',str(path)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 try:
  for _ in range(80):
   try:
    with socket.create_connection(('127.0.0.1',port),timeout=.2):break
   except OSError:time.sleep(.1)
  try:
   c,_=socks(port,1,'%s',%d)
   with c:
    c.settimeout(6);c.sendall(b'probe');data=c.recv(64).decode()
    result['tcp']=data[4:] if data.startswith('src=') else None
  except Exception:pass
  try:
   c,bound=socks(port,3,'0.0.0.0',0)
   with c,socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as u:
    u.settimeout(6)
    u.sendto(b'\x00\x00\x00\x01'+socket.inet_aton('%s')+struct.pack('!H',%d)+b'probe',('127.0.0.1' if bound[0] in ('0.0.0.0','::') else bound[0],bound[1]))
    reply,_=u.recvfrom(4096);data=reply[10:].decode()
    result['udp']=data[4:] if data.startswith('src=') else None
  except Exception:pass
 finally:
  process.terminate();process.wait(timeout=10)
print(json.dumps(result))
""" % (PROBE_IP, PROBE_TCP, PROBE_IP, PROBE_UDP)


def exit_is(fx, uri, expected, label, attempts=3):
    """Traffic through ``uri`` leaves via ``expected`` (None: no connection)."""
    for attempt in range(attempts):
        seen = fx.exit_of(uri)
        want = dict(tcp=expected, udp=expected)
        if seen == want: break
        time.sleep(2)
    print('    %s: tcp=%s udp=%s' % (label, seen['tcp'], seen['udp']), flush=True)
    check(seen == want, label)


def relay_objects(template, tags):
    """Our outbound once and exactly our rules, each right before the egress rule (or last)."""
    from_tag = lambda tag: dict(type='field', inboundTag=[tag], outboundTag='antirkn-relay-direct')
    outbounds = [x for x in template['outbounds'] if x.get('tag') == 'antirkn-relay-direct']
    rules = template['routing']['rules']
    ours = [x for x in rules if x.get('outboundTag') == 'antirkn-relay-direct']
    return outbounds, ours, [from_tag(t) for t in tags]


def same_rules(ours, wanted):
    key = lambda x: json.dumps(x, sort_keys=True)
    return sorted(map(key, ours)) == sorted(map(key, wanted))


def egress_index(template):
    rules = template['routing']['rules']
    return next((i for i, x in enumerate(rules) if x.get('outboundTag') == 'antirkn-client-egress'), None)


def specs(relay_port=2443):
    common = dict(enabled=True, deleted=False, listen='0.0.0.0', endpoint='127.0.0.1', transport='raw',
                  security='reality', sni='vless.test', target='10.0.2.2:29443', path='/antirkn/', host='',
                  mode='auto', certificate='', certificateKey='', region='')
    return [dict(common, id=RELAY_ID, name='Relay internal', port=relay_port, externalPort=relay_port, internal=True),
            dict(common, id=CLIENT_ID, name='Catalogue', port=2444, externalPort=2444)]


def vless_apply(fx, resources):
    payload = dict(version=1, workspaceId=WORKSPACE, panelId=PANEL_ID, resources=resources, users=[USER])
    plan = fx.rpc(dict(version=1, action='vless_plan', id=PANEL_ID, payload=json.dumps(payload)))
    if plan.get('code') != 'ok':
        return plan.get('code')
    job = fx.rpc.run_job(dict(version=1, action='submit', id=secrets.token_hex(16), kind='vless_apply',
                              count=len(resources) + 2, interval=1, payload=json.dumps(payload),
                              fingerprint=plan['vlessPlan']['fingerprint']), timeout=300)
    return job['status']


def vless_plan_code(fx, resources):
    payload = dict(version=1, workspaceId=WORKSPACE, panelId=PANEL_ID, resources=resources, users=[USER])
    return fx.rpc(dict(version=1, action='vless_plan', id=PANEL_ID, payload=json.dumps(payload))).get('code')


# ------------------------------------------------------------------ scenario

def setup(fx, bundle):
    check(lib.install_runner(bundle)['active'], 'runner_installed')
    plan = json.loads(python(bundle['panel_inspector'], json.dumps(dict(port=2053)).encode()).stdout)['panelPlan']
    panel_dir = '/var/lib/antirkn-runner/panel-' + PANEL_ID
    remote('mkdir -m 700 -p ' + panel_dir)
    upload(lib.fixture('panel'), panel_dir + '/release.tar.gz')
    job = fx.rpc.run_job(dict(version=1, action='submit', id=PANEL_ID, kind='panel_install', count=6, interval=1,
                              port=2053, fingerprint=plan['fingerprint']), timeout=600)
    check(job['status'] == 'succeeded', 'panel_installed')
    check(vless_apply(fx, specs()) == 'succeeded', 'managed_inbounds_applied')
    # An observed (not managed) REALITY inbound with one foreign client.
    fx.api("from vless import canonical\nfrom observed_inbounds import object_field\n"
           "src=next(r for r in api.call('/panel/api/inbounds/list') if r['remark'].endswith(%r))\n"
           "src=api.call('/panel/api/inbounds/get/%%d'%%src['id'])\nimport uuid\n"
           "row=dict(enable=True,remark=%r,listen='0.0.0.0',port=2447,protocol='vless',"
           "settings=canonical(dict(clients=[dict(id=str(uuid.uuid4()),email='foreign-fixture',enable=True,flow='xtls-rprx-vision')],decryption='none')),"
           "streamSettings=src['streamSettings'],sniffing=src.get('sniffing') or '{}')\n"
           "api.call('/panel/api/inbounds/add',row)\nprint('null')" % (RELAY_ID, OBSERVED_REMARK))
    # Only the direct path reaches the host echo through these public probe addresses.
    for proto, port, echo in (('tcp', PROBE_TCP, ECHO_TCP), ('udp', PROBE_UDP, ECHO_UDP)):
        remote('iptables -t nat -A OUTPUT -d %s -p %s --dport %d -j DNAT --to-destination 10.0.2.2:%d'
               % (PROBE_IP, proto, port, echo))
    from_vm = remote("python3 -c \"import socket;s=socket.create_connection(('%s',%d),timeout=5);s.sendall(b'x');print(s.recv(64).decode())\""
                     % (PROBE_IP, PROBE_TCP)).stdout.decode().strip()
    check(from_vm == 'src=' + DIRECT, 'vm_direct_path_reaches_direct_echo')


def scenario(fx, exit_node):
    T0 = fx.template()
    marker = lambda rid: 'AntiRKN:%s:%s' % (WORKSPACE, rid)
    R, C, O = fx.row(marker(RELAY_ID)), fx.row(marker(CLIENT_ID)), fx.row(OBSERVED_REMARK)
    user_uuid = fx.vm("from vless import client_id;print(json.dumps(client_id(%r,%r,%r)))" % (WORKSPACE, CLIENT_ID, USER['id']))
    client_uri = fx.user_link(C['remark'], user_uuid, 2444)
    exit_is(fx, client_uri, DIRECT, 'catalogue_direct_before_egress')

    status, _ = fx.egress(exit_node.link)
    check(status == 'succeeded', 'egress_enabled')
    T1 = fx.template()
    exit_is(fx, client_uri, VIA_EXIT, 'catalogue_via_exit_with_egress')

    # Eligibility.
    code, _ = fx.relay(C['id'], True)
    check(code == 'relay_client_inbound', 'client_facing_inbound_refused')
    code, _ = fx.relay(R['id'], False)
    check(code == 'relay_missing', 'disable_absent_relay_refused')

    # 1. Enable on the internal managed inbound.
    pid_before = fx.xray()[0]
    status, job = fx.relay(R['id'], True)
    check(status == 'succeeded', 'relay_enabled_internal')
    T2 = fx.template()
    check(T2 == fx.configure(T1, add=R['tag']), 'template_readback_equals_expected')
    outbounds, ours, wanted = relay_objects(T2, [R['tag']])
    check(outbounds == [dict(tag='antirkn-relay-direct', protocol='freedom', settings={})], 'relay_outbound_exact_once')
    check(ours == wanted, 'relay_rule_exact')
    check(T2['routing']['rules'].index(wanted[0]) + 1 == egress_index(T2), 'relay_rule_right_before_egress_rule')
    running = fx.running_config()
    check(any(x.get('tag') == 'antirkn-relay-direct' and x.get('protocol') == 'freedom' for x in running['outbounds'])
          and wanted[0] in running['routing']['rules'], 'running_xray_config_has_relay')
    pid, tested, state = fx.xray()
    check(tested, 'xray_test_passes')
    check(state == 'running' and pid and pid != pid_before, 'xray_restarted_running')
    relay = fx.relay_state()['relay']
    check([(e['inboundId'], e['tag'], e['stale']) for e in relay['inbounds']] == [(R['id'], R['tag'], False)], 'relay_state_one_fresh')
    code, uri_r = fx.link(R['id'], R['port'])
    check(code == 'ok' and uri_r.startswith('vless://') and '#' not in uri_r, 'relay_link_issued')
    check([e for e in fx.row(R['remark'])['emails'] if e.startswith('ar_relay_')] != [], 'service_client_on_inbound')
    exit_is(fx, uri_r, DIRECT, 'relay_traffic_exits_directly')
    exit_is(fx, client_uri, VIA_EXIT, 'catalogue_still_via_exit')

    # Repeat: idempotent, the link stays valid.
    status, _ = fx.relay(R['id'], True)
    check(status == 'succeeded', 'relay_reapply_succeeds')
    check(fx.template() == T2 and fx.link(R['id'], R['port'])[1] == uri_r, 'relay_reapply_keeps_template_and_link')

    # Observed inbound as a second relay.
    status, _ = fx.relay(O['id'], True)
    check(status == 'succeeded', 'relay_enabled_observed')
    T3 = fx.template()
    check(T3 == fx.configure(T2, add=O['tag']), 'observed_template_readback_equals_expected')
    code, uri_o = fx.link(O['id'], O['port'])
    check(code == 'ok', 'observed_relay_link_issued')
    exit_is(fx, uri_o, DIRECT, 'observed_relay_traffic_exits_directly')

    # 5. Guards while relay is on.
    resources = specs()
    resources[0]['internal'] = False
    check(vless_plan_code(fx, resources) == 'relay_disable_first', 'guard_switch_to_clients')
    resources = specs()
    resources[0].update(deleted=True, enabled=False)
    check(vless_plan_code(fx, resources) == 'relay_disable_first', 'guard_delete_managed')
    observed_hash = fx.api("from vless import digest,normal\n"
                           "print(json.dumps(digest(normal(api.call('/panel/api/inbounds/get/%d')))))" % O['id'])
    response = fx.rpc(dict(version=1, action='inbound_plan', id=PANEL_ID, payload=json.dumps(dict(
        panelId=PANEL_ID, removals=[dict(inboundId=O['id'], observedHash=observed_hash)]))))
    check(response.get('code') == 'relay_disable_first', 'guard_delete_observed')
    check(fx.rpc(dict(version=1, action='protocol_remove_plan', protocol='vless')).get('code') == 'egress_disable_first',
          'guard_remove_panel_egress_first')

    # 3b. Egress off and on again with relay present.
    status, _ = fx.egress(None)
    check(status == 'succeeded', 'egress_disabled_with_relay')
    T4 = fx.template()
    check(not any(x.get('tag', '').startswith('antirkn-client-egress') for x in T4['outbounds'] + T4.get('inbounds', [])),
          'egress_objects_removed')
    check(relay_objects(T4, [R['tag'], O['tag']])[1] == relay_objects(T3, [R['tag'], O['tag']])[2], 'relay_rules_survive_egress_disable')
    check(fx.rpc(dict(version=1, action='protocol_remove_plan', protocol='vless')).get('code') == 'relay_disable_first',
          'guard_remove_panel_relay')
    exit_is(fx, uri_r, DIRECT, 'relay_direct_without_egress')
    exit_is(fx, client_uri, DIRECT, 'catalogue_direct_without_egress')
    status, _ = fx.egress(exit_node.link)
    check(status == 'succeeded', 'egress_reenabled_with_relay')
    T5 = fx.template()
    index = egress_index(T5)
    rules = T5['routing']['rules']
    check(index is not None and rules.index(relay_objects(T5, [R['tag']])[2][0]) < index
          and rules.index(relay_objects(T5, [O['tag']])[2][0]) < index, 'relay_rules_before_egress_after_reenable')
    exit_is(fx, uri_r, DIRECT, 'relay_direct_after_egress_reenable')
    exit_is(fx, uri_o, DIRECT, 'observed_direct_after_egress_reenable')
    exit_is(fx, client_uri, VIA_EXIT, 'catalogue_via_exit_after_reenable')

    # 4. Tag change through an ordinary inbound edit. 3x-ui 3.7 recomputes the
    # tag and rewrites routing rules that name it, our rule included.
    check(vless_apply(fx, specs(relay_port=2446)) == 'succeeded', 'relay_inbound_port_edited')
    R2 = fx.row(R['remark'])
    check(R2['tag'] != R['tag'], 'panel_recomputed_tag')
    check(relay_objects(fx.template(), [])[1] == relay_objects(T5, [R2['tag'], O['tag']])[2], 'panel_rewrote_relay_rule_tag')
    state = {e['inboundId']: (e['tag'], e['stale']) for e in fx.relay_state()['relay']['inbounds']}
    check(state == {R['id']: (R2['tag'], False), O['id']: (O['tag'], False)}, 'relay_state_not_stale_when_panel_follows')
    code, uri_r2 = fx.link(R['id'], 2446)
    check(code == 'ok', 'service_client_survives_inbound_edit')
    exit_is(fx, uri_r2, DIRECT, 'retagged_relay_still_direct')
    status, _ = fx.relay(R['id'], True)
    check(status == 'succeeded', 'reapply_after_panel_retag_succeeds')
    _, ours, wanted = relay_objects(fx.template(), [R2['tag'], O['tag']])
    check(same_rules(ours, wanted), 'reapply_keeps_exact_rules')

    # A panel that does not follow the tag in routing (simulated: our rule
    # keeps the recorded tag after a second edit) makes the relay stale.
    check(vless_apply(fx, specs(relay_port=2448)) == 'succeeded', 'relay_inbound_port_edited_again')
    R3 = fx.row(R['remark'])
    fx.api("from client_egress import read_template,write_template\nfrom panel_api import restart_xray\n"
           "p=json.load(sys.stdin);t,u=read_template(api)\n"
           "for x in t['routing']['rules']:\n"
           " if x.get('outboundTag')=='antirkn-relay-direct' and x.get('inboundTag')==[p['new']]:x['inboundTag']=[p['old']]\n"
           "write_template(api,t,u);restart_xray(api);print('null')", dict(new=R3['tag'], old=R2['tag']))
    stale = {e['inboundId']: e['stale'] for e in fx.relay_state()['relay']['inbounds']}
    check(stale == {R['id']: True, O['id']: False}, 'relay_state_reports_stale')
    code, uri_r3 = fx.link(R['id'], 2448)
    check(code == 'ok' and uri_r3 == uri_r2.replace(':2446?', ':2448?'), 'link_follows_port_same_client')
    exit_is(fx, uri_r3, VIA_EXIT, 'stale_relay_leaks_to_egress')
    status, _ = fx.relay(R['id'], True)
    check(status == 'succeeded', 'relay_reapply_repairs')
    stale = {e['inboundId']: e['stale'] for e in fx.relay_state()['relay']['inbounds']}
    check(stale == {R['id']: False, O['id']: False}, 'relay_state_fresh_after_repair')
    T6 = fx.template()
    _, ours, wanted = relay_objects(T6, [R3['tag'], O['tag']])
    check(same_rules(ours, wanted), 'old_tag_rule_replaced')
    exit_is(fx, uri_r3, DIRECT, 'repaired_relay_exits_directly')
    R2, uri_r2 = R3, uri_r3

    # 3. Disable: observed first (outbound stays), then the last one.
    status, _ = fx.relay(O['id'], False)
    check(status == 'succeeded', 'relay_disabled_observed')
    T7 = fx.template()
    check(T7 == fx.configure(T6, remove=O['tag']), 'observed_rule_removed_exactly')
    check(relay_objects(T7, [])[0] != [], 'outbound_kept_for_remaining_relay')
    check(not [e for e in fx.row(OBSERVED_REMARK)['emails'] if e.startswith('ar_relay_')]
          and 'foreign-fixture' in fx.row(OBSERVED_REMARK)['emails'], 'observed_service_client_revoked_foreign_kept')
    exit_is(fx, uri_o, None, 'revoked_observed_link_fails')
    exit_is(fx, uri_r2, DIRECT, 'remaining_relay_still_direct')

    status, _ = fx.relay(R['id'], False)
    check(status == 'succeeded', 'relay_disabled_internal')
    T8 = fx.template()
    check(T8 == fx.configure(T7, remove=R2['tag'], last=True), 'relay_objects_removed_exactly')
    check(relay_objects(T8, [])[:2] == ([], []), 'no_relay_objects_left')
    check(fx.relay_state()['relay']['inbounds'] == [], 'relay_state_empty')
    check(fx.link(R['id'], 2448)[0] == 'relay_missing', 'relay_link_refused_after_disable')
    check(not [e for e in fx.row(R['remark'])['emails'] if e.startswith('ar_relay_')], 'internal_service_client_revoked')
    check(remote('ls /var/lib/antirkn-runner/egress-access/ 2>/dev/null | wc -l').stdout.strip() == b'0', 'service_records_removed')
    exit_is(fx, uri_r2, None, 'revoked_relay_link_fails')
    exit_is(fx, client_uri, VIA_EXIT, 'egress_still_works_after_relay_disable')
    check(fx.rpc(dict(version=1, action='egress_check', id=PANEL_ID)).get('code') == 'ok', 'egress_check_ok')
    _, tested, state = fx.xray()
    check(tested and state == 'running', 'xray_running_after_disable')

    status, _ = fx.egress(None)
    check(status == 'succeeded', 'egress_disabled')
    check(fx.template() == T0, 'original_panel_template_restored')
    check(fx.rpc(dict(version=1, action='protocol_remove_plan', protocol='vless')).get('code') == 'ok', 'panel_removal_allowed_again')


def main():
    bundle = lib.current_bundle()
    lib.ensure_image()
    lib.fixture('panel')
    run_dir = lib.RUNS / ('relay-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    run_dir.mkdir(mode=0o700, parents=True)
    vm = lib.Vm()
    fx = Fixture(bundle)
    status, error = 'PASS', None
    started = time.monotonic()
    try:
        lib.ensure_golden(vm)
        vm.start(lib.new_overlay('relay', lib.BASE / 'golden.qcow2'))
        with lib.EchoFixtures(lib.BASE / 'protocols-tls'), LabelEcho(DIRECT, ECHO_TCP, ECHO_UDP), \
                LabelEcho(VIA_EXIT, EXIT_TCP, EXIT_UDP), ExitNode(run_dir) as exit_node:
            setup(fx, bundle)
            scenario(fx, exit_node)
    except CheckFailed as failure:
        status, error = 'FAIL', str(failure)
    except BaseException as failure:
        status, error = 'ERROR', type(failure).__name__ + ': ' + str(failure)[:300]
        traceback.print_exc(limit=4)
    finally:
        if status != 'PASS':
            try:
                ctx = lib.Ctx('relay', run_dir, bundle)
                lib.collect_diagnostics(ctx, error)
            except Exception:
                pass
        if '--keep-vm' not in sys.argv:
            vm.stop()
    report = dict(git_head=lib.git_head(), runner_release=bundle['release'], runner_version=bundle['version'],
                  status=status, error=error, seconds=round(time.monotonic() - started, 1), checks=RESULTS)
    (run_dir / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print('%s (%d checks), report %s' % (status, len(RESULTS), run_dir / 'report.json'))
    return 0 if status == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
