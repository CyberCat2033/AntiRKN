#!/usr/bin/env python3
"""Container-only ForceCommand: allowlist production inventory commands exactly."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

fixture = Path('/fixture-data')
command = os.environ.get('SSH_ORIGINAL_COMMAND', '')
allowed = json.loads((fixture / 'inventory-commands.json').read_text())
if command not in allowed:
    with (fixture / 'inventory-audit').open('a') as f:
        f.write('REJECTED\n')
    sys.exit(125)
with (fixture / 'inventory-audit').open('a') as f:
    f.write(hashlib.sha256(command.encode()).hexdigest() + '\n')
mode = (fixture / 'inventory-mode').read_text().strip()
if mode == 'disk-failure' and 'df -Pk /' in command:
    sys.exit(2)
if mode == 'timeout' and command.endswith('uname -r'):
    # Longer than the adapter deadline; no server configuration is changed.
    import time
    time.sleep(6)
if mode == 'large' and command.endswith('uname -r'):
    sys.stdout.write('x' * 70000)
    sys.exit(0)
if mode == 'docker-denied' and 'docker --host' in command:
    print('@denied')
    sys.exit(0)
# The command is from a generated exact allowlist, never caller-provided shell code.
sys.exit(subprocess.call(['/bin/sh', '-c', command], stdin=subprocess.DEVNULL))
