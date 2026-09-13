#!/usr/bin/env python3
"""Container-only audit. Logs command hashes, never stdin or passwords."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

fixture = Path('/fixture-data')
command = os.environ.get('SSH_ORIGINAL_COMMAND', '')
allowed = set(json.loads((fixture / 'privilege-commands.json').read_text()))
with (fixture / 'privilege-audit').open('a') as audit:
    audit.write(hashlib.sha256(command.encode()).hexdigest() + '\n'
                if command in allowed else 'REJECTED\n')
if command not in allowed:
    sys.exit(125)
mode = (fixture / 'privilege-mode').read_text().strip()
if mode == 'unavailable' and 'command -v sudo' in command:
    sys.exit(127)
if 'sudo -k ' in command:
    if mode == 'slow':
        time.sleep(1.2)
    if mode == 'stall':
        time.sleep(30)
    if mode == 'disconnect':
        subprocess.run(['sudo', '-n', '--', '/bin/kill', '-KILL', str(os.getppid())], check=True)
        time.sleep(1)
        sys.exit(1)
# No stdin capture: real sudo/PAM consumes the original SSH channel directly.
sys.exit(subprocess.call(['/bin/sh', '-c', command]))
