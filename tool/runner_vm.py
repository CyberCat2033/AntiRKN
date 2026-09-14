#!/usr/bin/env python3
"""Disposable QEMU/KVM Ubuntu fixture. Credentials never printed or committed."""
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import threading
import time
import urllib.request

DIRECTORY = Path(os.environ.get('ANTIRKN_VM_DIRECTORY', '/tmp/antirkn-runner-vm'))
IMAGE_URL = 'https://cloud-images.ubuntu.com/noble/20260911/noble-server-cloudimg-amd64.img'
IMAGE_SHA256 = '612b2c0cc1bc413a6cb8c38fd611794caf0f2b436c50013d8b3794db12ad7354'


def prepare():
    DIRECTORY.mkdir(mode=0o700, exist_ok=True)
    DIRECTORY.chmod(0o700)
    reuse = os.environ.get('ANTIRKN_VM_REUSE') == '1'
    if (DIRECTORY / 'disk.qcow2').exists() and not reuse:
        raise RuntimeError('Stop the old fixture and remove its disposable overlay before preparing a new VM')
    image = DIRECTORY / 'ubuntu.img'
    if not image.exists():
        download = DIRECTORY / 'ubuntu.download'
        urllib.request.urlretrieve(IMAGE_URL, download)
        with download.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != IMAGE_SHA256:
                raise RuntimeError('Ubuntu image checksum mismatch')
        os.replace(download, image)
    with image.open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != IMAGE_SHA256:
            raise RuntimeError('Ubuntu image checksum mismatch')
    seed = DIRECTORY / 'seed'
    seed.mkdir(mode=0o700, exist_ok=True)
    for key in ('client', 'host'):
        path = DIRECTORY / key
        if not path.exists():
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(path)], check=True)
    password = (json.loads((DIRECTORY / 'credentials.json').read_text())['password']
                if reuse and (DIRECTORY / 'credentials.json').exists() else secrets.token_urlsafe(24))
    credentials = DIRECTORY / 'credentials.json'
    credentials.write_text(json.dumps(dict(password=password)))
    credentials.chmod(0o600)
    public = (DIRECTORY / 'client.pub').read_text().strip()
    config = {
        'users': [{'name': 'antirkn', 'shell': '/bin/bash', 'lock_passwd': False,
                   'sudo': 'ALL=(ALL) ALL', 'ssh_authorized_keys': [public]}],
        'ssh_pwauth': True,
        'chpasswd': {'expire': False, 'users': [{'name': 'antirkn', 'password': password, 'type': 'text'}]},
        'ssh_keys': {'ed25519_private': (DIRECTORY / 'host').read_text(),
                     'ed25519_public': (DIRECTORY / 'host.pub').read_text().strip()},
        'disable_root': False,
        'write_files': [{'path': '/root/.ssh/authorized_keys', 'permissions': '0600', 'content': public + '\n'}],
    }
    (seed / 'user-data').write_text('#cloud-config\n' + json.dumps(config))
    (seed / 'meta-data').write_text(json.dumps({'instance-id': 'antirkn-runner-v1', 'local-hostname': 'antirkn-runner-fixture'}))
    (seed / 'user-data').chmod(0o600)
    if not (DIRECTORY / 'disk.qcow2').exists():
        subprocess.run(['qemu-img', 'create', '-f', 'qcow2', '-F', 'qcow2', '-b', str(image), str(DIRECTORY / 'disk.qcow2'), '8G'], check=True, stdout=subprocess.DEVNULL)
    fingerprint = subprocess.check_output(['ssh-keygen', '-lf', str(DIRECTORY / 'host.pub')], text=True).split()[1]
    (DIRECTORY / 'fingerprint').write_text(fingerprint)
    class QuietHandler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(QuietHandler, directory=str(seed)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', int(os.environ.get('ANTIRKN_VM_SSH_PORT', '0'))))
        port = sock.getsockname()[1]
    (DIRECTORY / 'port').write_text(str(port))
    host_public = (DIRECTORY / 'host.pub').read_text().split()
    (DIRECTORY / 'known_hosts').write_text(f'[127.0.0.1]:{port} {host_public[0]} {host_public[1]}\n')
    forwards = ''
    for local, guest in json.loads(os.environ.get('ANTIRKN_VM_FORWARDS', '{}')).items():
        local, guest = int(local), int(guest)
        if not 1024 <= local <= 65535 or not 1024 <= guest <= 65535:
            raise ValueError('Invalid fixture forward')
        forwards += f',hostfwd=tcp:127.0.0.1:{local}-:{guest}'
    for local, guest in json.loads(os.environ.get('ANTIRKN_VM_UDP_FORWARDS', '{}')).items():
        local, guest = int(local), int(guest)
        if not 1024 <= local <= 65535 or not 1024 <= guest <= 65535:
            raise ValueError('Invalid fixture UDP forward')
        forwards += f',hostfwd=udp:127.0.0.1:{local}-:{guest}'
    command = ['qemu-system-x86_64', '-accel', 'kvm' if os.access('/dev/kvm', os.R_OK | os.W_OK) else 'tcg', '-m', '1536', '-smp', '2', '-display', 'none',
               '-drive', f'file={DIRECTORY / "disk.qcow2"},if=virtio,format=qcow2',
               '-nic', f'user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:{port}-:22' + forwards,
               '-smbios', f'type=1,serial=ds=nocloud;s=http://10.0.2.2:{server.server_port}/',
               '-serial', f'file:{DIRECTORY / "console.txt"}', '-monitor', 'none']
    vm = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    (DIRECTORY / 'pid').write_text(str(vm.pid))
    print('Ubuntu QEMU fixture starting (image hash verified).', flush=True)
    try:
        deadline = time.monotonic() + 600
        while time.monotonic() < deadline:
            if vm.poll() is not None:
                raise RuntimeError('QEMU exited')
            try:
                check = subprocess.run(ssh_command('root') + ['cloud-init status --wait'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            except subprocess.TimeoutExpired:
                continue
            if check.returncode == 0:
                (DIRECTORY / 'ready').touch()
                print('Ubuntu QEMU fixture ready: real SSH, sudo, systemd.', flush=True)
                break
            time.sleep(1)
        else:
            raise RuntimeError('VM boot timeout')
        vm.wait()
    finally:
        vm.terminate()
        server.shutdown()


def ssh_command(user='root'):
    return ['ssh', '-i', str(DIRECTORY / 'client'), '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
            '-o', 'ConnectTimeout=3', '-o', f'UserKnownHostsFile={DIRECTORY / "known_hosts"}',
            '-p', (DIRECTORY / 'port').read_text(), f'{user}@127.0.0.1']

if __name__ == '__main__':
    prepare()
