#!/usr/bin/env python3
"""Export synthetic adopted resources with production Dart code; run Mihomo -t.

Server/API effects use the runner test fixture. This verifies profile generation
and the pinned client parser, not live VPN connectivity. No real credentials.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests/runner'))
from test_managed_existing import AdoptionTests
import vless
import awg
import tt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mihomo', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if hashlib.sha256(args.mihomo.read_bytes()).hexdigest() != '8ad44e28fe72be4640254b96741b677f4074991b99186cc4486a1c28ded02b1a':
        raise SystemExit('Unexpected Mihomo binary')
    reality = dict(privateKey='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', shortIds=['0123456789abcdef'],
                   serverNames=['example.com'], target='example.com:443')
    cases = [('tcp-none', 'vless', dict(network='tcp', security='none')),
             ('tcp-reality', 'vless', dict(network='tcp', security='reality', realitySettings=reality)),
             ('xhttp-reality', 'vless', dict(network='xhttp', security='reality', realitySettings=reality,
                 xhttpSettings=dict(path='/kept', host='', mode='auto', extra=dict(xPaddingBytes='100-200')))),
             ('xhttp-tls', 'vless', dict(network='xhttp', security='tls', tlsSettings=dict(serverName='example.com'),
                 xhttpSettings=dict(path='/kept', host='', mode='auto'))),
             ('ws-tls', 'vless', dict(network='ws', security='tls', tlsSettings=dict(serverName='example.com'), wsSettings=dict(path='/kept'))),
             ('grpc-tls', 'vless', dict(network='grpc', security='tls', tlsSettings=dict(serverName='example.com'), grpcSettings=dict(serviceName='kept'))),
             ('awg1', 'awg', {}), ('awg2', 'awg', {}), ('awg3', 'awg', {}), ('trusttunnel', 'tt', {})]
    results = []
    with tempfile.TemporaryDirectory(prefix='antirkn-adopt-profiles-') as directory:
        for name, protocol, stream in cases:
            fixture = AdoptionTests()
            fixture.setUp()
            try:
                if protocol == 'vless':
                    fixture.api.rows[0]['streamSettings'] = copy.deepcopy(stream)
                if name in ('awg2', 'awg3'):
                    fixture.raw = fixture.raw.replace('H1 = 1', 'S3 = 0\nS4 = 0\nH1 = 1')
                if name == 'awg3':
                    fixture.raw = fixture.raw.replace('Jc = 4', 'HeaderProtectionKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\nJc = 4')
                    for i in range(1, 5): fixture.raw = fixture.raw.replace(f'S{i} = 0', f'S{i} = 32')
                fixture.runtime = fixture.raw
                payload = fixture.payload(protocol)
                spec = payload['resources'][0]
                if protocol == 'vless': spec.update(transport=stream['network'], security=stream['security'])
                assert fixture.finish(fixture.submit(payload, protocol))['status'] == 'succeeded'
                observed = {'vless': vless, 'awg': awg, 'tt': tt}[protocol].state(fixture.store, 'a'*32)
                target = 'one' if protocol == 'vless' else protocol + '/one'
                workspace = dict(version=3, id='a'*32, users=[dict(id='c'*32, login='alice', name='Alice', enabled=True)],
                                 inbounds=[], awgInterfaces=[], ttEndpoints=[], servers={target: dict(observed=observed)}, profiles={})
                workspace[{'vless':'inbounds','awg':'awgInterfaces','tt':'ttEndpoints'}[protocol]] = [dict(serverId='one', spec=spec)]
                data = dict(workspace=workspace, userId='c'*32, resourceId='b'*32,
                            template={'proxies': [], 'proxy-groups': [dict(name='ALL',type='select',**{'include-all-proxies':True})], 'rules':['MATCH,ALL']})
                base = Path(directory) / name
                base.mkdir()
                source = base / 'fixture.json'
                source.write_text(json.dumps(data));source.chmod(0o600)
                profile = base / 'profile.yml'
                compiled = subprocess.run(['dart','run','tool/compile_vless_fixture.dart',str(source),str(profile)],cwd=ROOT,capture_output=True)
                if compiled.returncode: raise RuntimeError(name + ': compiler failed: ' + compiled.stderr.decode())
                tested = subprocess.run([str(args.mihomo),'-t','-d',str(base),'-f',str(profile)],capture_output=True)
                if tested.returncode: raise RuntimeError(name + ': Mihomo rejected synthetic config: ' + tested.stdout.decode() + tested.stderr.decode())
                results.append(dict(case=name, compiled=True, mihomoConfig=True))
            finally:
                fixture.tearDown()
    args.output.write_text(json.dumps(dict(mihomo='1.19.30', liveConnectivity=False, results=results),indent=2)+'\n')
    print(f'{len(results)} adopted profile cases: production compiler and pinned Mihomo -t PASS')


if __name__ == '__main__':
    main()
