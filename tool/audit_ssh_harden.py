#!/usr/bin/env python3
"""Verify repaired SSH policy locally without changing system configuration.

The historical defect reproducer and evidence are retained in commit c7dacfa.
Lifecycle acceptance on real systemd/SSH is test_ssh_harden_recovery_vm.py.
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'server/runner'))
import ssh_harden as harden


def main():
    subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'tests/runner',
                    '-p', 'test_ssh_harden.py'], cwd=ROOT, check=True)
    with tempfile.TemporaryDirectory(prefix='antirkn-ssh-policy-') as temp:
        root = Path(temp)
        key = root / 'host_key'
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
        include = root / '10-existing.conf'
        include.write_text('Port 22\nPermitRootLogin yes\n')
        config = root / 'sshd_config'
        config.write_text(f'HostKey {key}\nInclude {include}\nUsePAM no\nMatch User root\n PermitRootLogin yes\n')
        with patch.object(harden, 'SSH_CONFIG', config):
            for path in [config, include]:
                path.write_bytes(harden.render_config(harden.snapshot(path), [2222], True))
        result = subprocess.run([shutil.which('sshd'), '-T', '-f', str(config), '-C',
                                 'user=root,host=fixture,addr=127.0.0.1'],
                                check=True, capture_output=True, text=True)
        effective = [line.lower() for line in result.stdout.splitlines() if line.lower().startswith(('port ', 'permitrootlogin '))]
        assert set(effective) == {'port 2222', 'permitrootlogin no'}, effective
        print(json.dumps(dict(effective_configuration=effective, policy_verified=True)))


if __name__ == '__main__':
    main()
