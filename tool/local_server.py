#!/usr/bin/env python3
"""Persistent local-only Ubuntu test fixture, isolated from application data."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
DIRECTORY = ROOT / 'artifacts/local-server'
UNIT = 'antirkn-local-test-server.service'


def active():
    return subprocess.run(['systemctl', '--user', 'is-active', '--quiet', UNIT]).returncode == 0


def status():
    print('Running' if active() else 'Stopped')
    print('SSH: 127.0.0.1:2222 · root (private key) or antirkn (password/sudo)')
    print(f'Private key: {DIRECTORY / "client"}')
    print(f'Password file: {DIRECTORY / "credentials.json"}')
    if (DIRECTORY / 'fingerprint').exists():
        print('Host key: ' + (DIRECTORY / 'fingerprint').read_text().strip())


def main():
    action = sys.argv[1] if len(sys.argv) == 2 else 'help'
    if action not in ('start', 'stop', 'reset', 'status'):
        raise SystemExit('Usage: tool/test-server.sh start|stop|reset|status\nreset deletes this disposable VM and its SSH keys, then starts a clean server.')
    if DIRECTORY.is_symlink() or (ROOT / 'artifacts').is_symlink():
        raise SystemExit('Refusing a symlink for test-server storage')
    if action in ('stop', 'reset'):
        state = subprocess.check_output(['systemctl', '--user', 'show',
            '--property=LoadState', '--value', UNIT], text=True).strip()
        if state != 'not-found':
            subprocess.run(['systemctl', '--user', 'stop', UNIT], check=True)
        if active():
            raise SystemExit('Server did not stop; disk was kept')
    if action == 'reset' and DIRECTORY.exists():
        # Only named fixture files. The downloaded, verified base image is kept.
        for name in ('disk.qcow2', 'client', 'client.pub', 'host', 'host.pub',
                     'credentials.json', 'fingerprint', 'known_hosts', 'port',
                     'pid', 'ready', 'console.txt'):
            (DIRECTORY / name).unlink(missing_ok=True)
        seed = DIRECTORY / 'seed'
        if seed.is_symlink():
            seed.unlink()
        elif seed.exists():
            shutil.rmtree(seed)
    if action in ('start', 'reset') and not active():
        DIRECTORY.mkdir(parents=True, exist_ok=True, mode=0o700)
        (DIRECTORY / 'ready').unlink(missing_ok=True)
        subprocess.run(['systemd-run', '--user', '--collect', '--unit', UNIT,
            '--property=KillMode=control-group', '--property=TimeoutStopSec=30',
            '--property=UMask=0077', '--working-directory=' + str(ROOT),
            '--setenv=ANTIRKN_VM_DIRECTORY=' + str(DIRECTORY),
            '--setenv=ANTIRKN_VM_REUSE=1', '--setenv=ANTIRKN_VM_SSH_PORT=2222',
            sys.executable, str(ROOT / 'tool/runner_vm.py')], check=True)
        print('Downloading/booting Ubuntu; status: journalctl --user -u ' + UNIT, flush=True)
        deadline = time.monotonic() + 900
        while time.monotonic() < deadline:
            if (DIRECTORY / 'ready').exists():
                break
            if not active():
                raise SystemExit('Startup failed; see the service journal')
            time.sleep(2)
        else:
            raise SystemExit('Server is still starting; inspect its service journal')
    status()


if __name__ == '__main__':
    main()
