#!/usr/bin/env python3
"""Test the disposable localhost fixture with a separate, temporary SSH-agent."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parent.parent
fixture = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='antirkn-agent-test-') as directory:
    socket = Path(directory) / 'agent.sock'
    environment = dict(os.environ, SSH_AUTH_SOCK=str(socket))
    agent = subprocess.Popen(['ssh-agent', '-D', '-a', str(socket)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if socket.exists():
                break
            if agent.poll() is not None:
                raise RuntimeError('Test agent exited')
            time.sleep(0.05)
        subprocess.run(['ssh-add', str(fixture / 'plain_ed25519')], env=environment,
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        result = subprocess.run(['dart', 'run', 'tool/test_ubuntu.dart', str(fixture)], env=environment,
                                cwd=root / 'packages/ssh_transport', capture_output=True, text=True)
        if result.returncode:
            # This executable reports safe codes only, never key material.
            sys.stderr.write(result.stderr)
            sys.exit(result.returncode)
        evidence = {'fixture': 'Disposable Ubuntu 24.04 container, localhost only',
                    'image_digest': 'sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254',
                    'results': json.loads(result.stdout)}
        if 'linux_agent' not in evidence['results']:
            raise RuntimeError('Agent test did not run')
        (root / 'docs/evidence/ssh-ubuntu.json').write_text(json.dumps(evidence, indent=2) + '\n')
        print(f"Ubuntu SSH: {len(evidence['results'])} scenarios PASS, including isolated Linux SSH-agent")
    finally:
        agent.terminate()
        try:
            agent.wait(timeout=5)
        except subprocess.TimeoutExpired:
            agent.kill()
            agent.wait()
