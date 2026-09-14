#!/usr/bin/env python3
"""New XHTTP form defaults through production compiler and real Mihomo TCP/UDP."""
import json
import os
from pathlib import Path
import subprocess
import time
from runner_vm import ssh_command
import test_vless_vm as v
from test_server_ui_vm import rpc, python, ROOT

if not os.environ.get('ANTIRKN_VM_DIRECTORY','').endswith('/server-ui-test'):
    raise SystemExit('Requires isolated server-ui-test VM')
v.rpc = rpc
# Reuse the existing controlled echo/TLS fixture with the current runner and URL origin.
v.python = lambda source, *args, **kwargs: python(source.replace('/v5','/v7').replace("'Origin':api.base", "'Origin':api.origin"), *args, **kwargs)
v.MIHOMO = Path('/tmp/antirkn-mihomo')
v.FIXTURE = Path('/tmp/antirkn-server-ui-network')
v.HOST_BASE = 36443
options = json.loads(subprocess.check_output(['dart','run','tool/compile_vless_fixture.dart','--xhttp-defaults'],cwd=ROOT))
resources = [v.public_spec(1,'xhttp'), v.public_spec(2,'xhttp','tls','packet-up'), v.public_spec(3,'xhttp','tls','stream-up'), v.public_spec(4,'xhttp','tls','stream-one')]
for r in resources: r['xhttp'] = options
forward = ssh_command()
for i in range(1,5): forward += ['-L',f'127.0.0.1:{v.HOST_BASE+i}:127.0.0.1:{2443+i}']
forward += ['-o','ExitOnForwardFailure=yes','-N']
tunnel = subprocess.Popen(forward,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
close = None
try:
    time.sleep(.5)
    if tunnel.poll() is not None: raise AssertionError('fixture tunnel')
    close = v.fixtures()
    state, _ = v.apply(v.payload(resources),'form_defaults')
    for i in range(4): v.network(state,resources,i)
    (ROOT/'docs/evidence/server-ui-network.json').write_text(json.dumps(dict(results=v.results,defaults=options,mihomo='1.19.30',panel='3.7.0',xray='26.7.28',compiler='production',transport='SSH tunnel to isolated Ubuntu; controlled TLS and TCP/UDP destinations'),indent=2)+'\n')
finally:
    if close: close()
    tunnel.terminate(); tunnel.wait(timeout=10)
