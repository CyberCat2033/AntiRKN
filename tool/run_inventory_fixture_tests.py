#!/usr/bin/env python3
"""Create and remove a disposable Ubuntu SSH fixture. No access to owner VPS/data."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parent.parent
image = 'ubuntu@sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254'
name = f'antirkn-inventory-{os.getpid()}'
def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

with tempfile.TemporaryDirectory(prefix='antirkn-inventory-') as directory:
    fixture = Path(directory)
    commands = run(['dart', 'run', 'tool/inventory_commands.dart'], cwd=root / 'packages/ssh_transport', capture_output=True, text=True).stdout
    (fixture / 'inventory-commands.json').write_text(commands)
    shutil.copyfile(root / 'tool/inventory_fixture_audit.py', fixture / 'inventory_audit.py')
    for file in ['inventory-audit', 'inventory-mode']:
        (fixture / file).touch()
        (fixture / file).chmod(0o666)
    try:
        run(['docker', 'run', '-d', '--name', name, '--cap-add=NET_ADMIN',
             '-p', '127.0.0.1::22', '-v', f'{fixture}:/fixture-data',
             '-v', f'{root / "tool/ssh_fixture_setup.sh"}:/fixture-setup.sh:ro',
             image, 'bash', '/fixture-setup.sh'], stdout=subprocess.DEVNULL)
        print('Preparing disposable Ubuntu SSH fixture…', flush=True)
        deadline = time.monotonic() + 240
        while not (fixture / 'ready').exists():
            if time.monotonic() > deadline:
                raise RuntimeError('Fixture preparation timed out')
            state = run(['docker', 'inspect', '--format', '{{.State.Running}}', name], capture_output=True, text=True).stdout.strip()
            if state != 'true':
                raise RuntimeError('Fixture container stopped during setup')
            time.sleep(1)
        shutil.copyfile(root / 'tool/inventory_socket_fixture.py', fixture / 'socket_fixture.py')
        run(['docker', 'exec', '-d', name, 'python3', '/fixture-data/socket_fixture.py'])
        socket_deadline = time.monotonic() + 15
        while not (fixture / 'sockets-ready').exists():
            if time.monotonic() > socket_deadline:
                raise RuntimeError('IPv4/IPv6 socket fixture did not start')
            time.sleep(0.1)
        mapping = run(['docker', 'port', name, '22/tcp'], capture_output=True, text=True).stdout.strip()
        (fixture / 'port').write_text(mapping.rsplit(':', 1)[1])
        def check(phase):
            outcome = subprocess.run(['dart', 'run', 'tool/test_inventory_ubuntu.dart', str(fixture), phase],
                          cwd=root / 'packages/ssh_transport', capture_output=True, text=True)
            if outcome.returncode:
                sys.stderr.write(outcome.stderr)  # Fixture executable exposes safe codes only.
                raise RuntimeError('Inventory fixture check failed')
            return json.loads(outcome.stdout)
        evidence = {'fixture': 'Disposable Ubuntu 24.04; actual SSH, OS tools and sockets; no systemd PID 1 or Docker daemon inside',
                    'image': image, 'clean': check('clean')}
        # Public synthetic binaries deliberately implement ONLY the version flags.
        # Actual protocol installation/runtime compatibility is not claimed.
        setup = r'''
set -eu
mkdir -p /usr/local/x-ui/bin /opt/trusttunnel
printf '#!/bin/sh\n[ "$1" = "-v" ] || exit 99\nprintf "v3.7.0\\n"\n' > /usr/local/x-ui/x-ui
printf '#!/bin/sh\n[ "$1" = "version" ] || exit 99\nprintf "Xray 26.3.27 (fixture)\\n"\n' > /usr/local/x-ui/bin/xray-linux-amd64
printf '#!/bin/sh\n[ "$1" = "--version" ] || exit 99\nprintf "1.1.0\\n"\n' > /opt/trusttunnel/trusttunnel_endpoint
printf '#!/bin/sh\n[ "$1" = "--version" ] || exit 99\nprintf "amneziawg-tools v1.0.20250522\\n"\n' > /usr/bin/awg
chmod 755 /usr/local/x-ui/x-ui /usr/local/x-ui/bin/xray-linux-amd64 /opt/trusttunnel/trusttunnel_endpoint /usr/bin/awg
printf '[Unit]\nDescription=Read-only inventory fixture\n[Service]\nExecStart=/bin/false\n' > /etc/systemd/system/x-ui.service
printf 'fixture-config-unchanged\n' > /opt/trusttunnel/vpn.toml
chmod 700 /opt/trusttunnel
'''
        run(['docker', 'exec', '-i', name, 'sh'], input=setup, text=True)
        hashes_command = ['docker', 'exec', name, 'sha256sum', '/usr/local/x-ui/x-ui', '/usr/local/x-ui/bin/xray-linux-amd64', '/opt/trusttunnel/trusttunnel_endpoint', '/usr/bin/awg', '/opt/trusttunnel/vpn.toml', '/etc/systemd/system/x-ui.service']
        hashes_before = run(hashes_command, capture_output=True, text=True).stdout
        evidence['partial_installation'] = check('installed')
        hashes_after = run(hashes_command, capture_output=True, text=True).stdout
        if hashes_before != hashes_after:
            raise RuntimeError('Inventory changed fixture software/config files')
        evidence['fixture_config_hashes_unchanged'] = True
        audit = (fixture / 'inventory-audit').read_text().splitlines()
        if 'REJECTED' in audit:
            raise RuntimeError('Unexpected command attempted')
        allowed = {hashlib.sha256(s.encode()).hexdigest() for s in json.loads(commands)}
        if not set(audit) <= allowed:
            raise RuntimeError('Unknown audit entry')
        evidence['only_allowlisted_read_commands'] = True
        evidence['inventory_command_count'] = len(audit)
        docker_tag = f'antirkn-inventory-fixture/amneziawg:{os.getpid()}'
        docker_fixture = name + '-metadata'
        try:
            run(['docker', 'tag', image, docker_tag])
            run(['docker', 'create', '--name', docker_fixture, docker_tag, '/bin/false'], stdout=subprocess.DEVNULL)
            result = run(['dart', 'run', 'tool/test_docker_inventory.dart', docker_tag], cwd=root / 'packages/ssh_transport', capture_output=True, text=True)
            evidence['docker_metadata'] = json.loads(result.stdout)
        finally:
            subprocess.run(['docker', 'rm', '-f', docker_fixture], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(['docker', 'image', 'rm', docker_tag], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        evidence['checked_at_utc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        (root / 'docs/evidence/server-inventory-ubuntu.json').write_text(json.dumps(evidence, indent=2) + '\n')
        print('Ubuntu inventory: clean/partial host, root/user, refresh, permissions and injected failures PASS', flush=True)
    finally:
        subprocess.run(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Test credentials in the bind mount belong to the host user, per fixture setup.
