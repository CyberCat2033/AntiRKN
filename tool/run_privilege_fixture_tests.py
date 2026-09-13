#!/usr/bin/env python3
"""Real OpenSSH/sudo on disposable Ubuntu; no owner server or stored credentials."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parent.parent
image = 'ubuntu@sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254'
name = f'antirkn-privileges-{os.getpid()}'

def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

def dart(script, *args):
    result = subprocess.run(['dart', 'run', f'tool/{script}', *map(str, args)],
        cwd=root / 'packages/ssh_transport', capture_output=True, text=True)
    if result.returncode:
        # Executables contain fixture data only and emit safe codes.
        raise RuntimeError(result.stderr)
    return result.stdout

with tempfile.TemporaryDirectory(prefix='antirkn-privileges-') as directory:
    fixture = Path(directory)
    (fixture / 'privilege-commands.json').write_text(dart('privilege_commands.dart'))
    shutil.copyfile(root / 'tool/privilege_fixture_setup.sh', fixture / 'privilege-setup.sh')
    shutil.copyfile(root / 'tool/privilege_fixture_audit.py', fixture / 'privilege-audit.py')
    for file in ['privilege-audit', 'privilege-mode']:
        (fixture / file).touch()
        (fixture / file).chmod(0o666)
    try:
        run(['docker', 'run', '-d', '--name', name, '--cap-add=NET_ADMIN',
             '-p', '127.0.0.1::22', '-v', f'{fixture}:/fixture-data',
             '-v', f'{root / "tool/ssh_fixture_setup.sh"}:/fixture-setup.sh:ro',
             image, 'bash', '/fixture-setup.sh'], stdout=subprocess.DEVNULL)
        print('Preparing disposable Ubuntu sudo fixture…', flush=True)
        deadline = time.monotonic() + 240
        while not (fixture / 'ready').exists():
            if time.monotonic() > deadline:
                raise RuntimeError('Fixture preparation timed out')
            state = run(['docker', 'inspect', '--format', '{{.State.Running}}', name],
                        capture_output=True, text=True).stdout.strip()
            if state != 'true':
                raise RuntimeError('Fixture setup failed')
            time.sleep(1)
        mapping = run(['docker', 'port', name, '22/tcp'], capture_output=True, text=True).stdout.strip()
        (fixture / 'port').write_text(mapping.rsplit(':', 1)[1])
        hashes_command = ['docker', 'exec', name, 'sha256sum',
            '/etc/sudoers.d/antirkn-fixture', '/etc/ssh/sshd_config.d/00-antirkn-fixture.conf',
            '/opt/trusttunnel/trusttunnel_endpoint']
        before = run(hashes_command, capture_output=True).stdout
        results = json.loads(dart('test_privilege_ubuntu.dart', fixture))
        after = run(hashes_command, capture_output=True).stdout
        if before != after:
            raise RuntimeError('Read-only checks changed server configuration')
        audit = (fixture / 'privilege-audit').read_text().splitlines()
        allowed = {hashlib.sha256(s.encode()).hexdigest()
                   for s in json.loads((fixture / 'privilege-commands.json').read_text())}
        if not set(audit) <= allowed:
            raise RuntimeError('Command outside the read-only allowlist')
        # Real Docker exec with public synthetic version-only programs.
        setup = r'''
set -eu
printf '#!/bin/sh\n[ "$1" = "--version" ] || exit 99\nprintf "amneziawg-go v3.0.0\\n"\n' > /usr/bin/amneziawg-go
printf '#!/bin/sh\n[ "$1" = "--version" ] || exit 99\nprintf "amneziawg-tools v3.1.20260812 - https://amnezia.org\\n"\n' > /usr/bin/awg
chmod 755 /usr/bin/amneziawg-go /usr/bin/awg
'''
        run(['docker', 'exec', '-i', name, 'sh'], input=setup, text=True)
        container_id = run(['docker', 'inspect', '--format', '{{.Id}}', name],
                           capture_output=True, text=True).stdout.strip()
        docker_results = json.loads(dart('test_container_versions.dart', container_id))
        sudo_version = run(['docker', 'exec', name, 'sudo', '--version'],
                           capture_output=True, text=True).stdout.splitlines()[0]
        evidence = {'fixture': 'Disposable Ubuntu 24.04; real OpenSSH and sudo/PAM',
                    'image': image, 'sudo_version': sudo_version, 'results': results,
                    'read_only_config_hashes_unchanged': True,
                    'only_allowlisted_commands': True, 'commands_observed': len(audit),
                    'docker_versions': docker_results,
                    'checked_at_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
        (root / 'docs/evidence/sudo-ubuntu.json').write_text(json.dumps(evidence, indent=2) + '\n')
        print(f"Ubuntu sudo: {len(results)} scenarios PASS; Docker version probes PASS", flush=True)
    finally:
        subprocess.run(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
