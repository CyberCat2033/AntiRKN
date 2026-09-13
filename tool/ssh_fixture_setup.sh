#!/usr/bin/env bash
# Disposable Ubuntu 24.04 container only. Mount an empty private /fixture-data.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq openssh-server iproute2 python3-cryptography python3-bcrypt >/dev/null
useradd -m -s /bin/bash testuser
mkdir -p /run/sshd /home/testuser/.ssh /root/.ssh
python3 - <<'PY'
import json, os, pathlib, secrets, subprocess
from cryptography.hazmat.primitives.asymmetric import ed25519, rsa
from cryptography.hazmat.primitives import serialization
p = pathlib.Path('/fixture-data')
owner = p.stat()
password = secrets.token_urlsafe(24)
passphrase = secrets.token_urlsafe(24)
subprocess.run(['chpasswd'], input=f'testuser:{password}\nroot:{password}\n'.encode(), check=True)
public = []
for name, key, protection in [
    ('plain_ed25519', ed25519.Ed25519PrivateKey.generate(), serialization.NoEncryption()),
    ('encrypted_ed25519', ed25519.Ed25519PrivateKey.generate(), serialization.BestAvailableEncryption(passphrase.encode())),
    ('encrypted_rsa', rsa.generate_private_key(public_exponent=65537, key_size=2048), serialization.BestAvailableEncryption(passphrase.encode())),
]:
    target = p / name
    target.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.OpenSSH, protection))
    target.chmod(0o600)
    os.chown(target, owner.st_uid, owner.st_gid)
    public.append(key.public_key().public_bytes(serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH))
for directory in ['/root/.ssh', '/home/testuser/.ssh']:
    pathlib.Path(directory, 'authorized_keys').write_bytes(b'\n'.join(public)+b'\n')
target = p / 'credentials.json'
target.write_text(json.dumps({'password': password, 'passphrase': passphrase}))
target.chmod(0o600)
os.chown(target, owner.st_uid, owner.st_gid)
PY
chmod 700 /root/.ssh /home/testuser/.ssh
chmod 600 /root/.ssh/authorized_keys /home/testuser/.ssh/authorized_keys
chown -R testuser:testuser /home/testuser/.ssh
cat > /etc/ssh/sshd_config.d/00-antirkn-fixture.conf <<'CONF'
PasswordAuthentication yes
PermitRootLogin yes
KbdInteractiveAuthentication no
UsePAM no
AllowUsers testuser root
LogLevel VERBOSE
ForceCommand /usr/local/bin/antirkn-fixture-audit
CONF
cat > /usr/local/bin/antirkn-fixture-audit <<'AUDIT'
#!/usr/bin/env bash
set -euo pipefail
case "$SSH_ORIGINAL_COMMAND" in
  'cat /etc/os-release'|'uname -m'|'ip -j -details address show'|'ip -j -4 route show table all'|'ip -j -6 route show table all'|'ip -j -4 rule show'|'ip -j -6 rule show') ;;
  *)
    if [ -f /fixture-data/inventory_audit.py ]; then
      exec python3 /fixture-data/inventory_audit.py
    fi
    exit 125 ;;
esac
printf '%s\n' "$SSH_ORIGINAL_COMMAND" >> /fixture-data/commands
mode=''
if [ -f /fixture-data/failure ]; then mode=$(cat /fixture-data/failure); fi
if [ "$mode" = unsupported ] && [ "$SSH_ORIGINAL_COMMAND" = 'cat /etc/os-release' ]; then
  printf 'ID=debian\nVERSION_ID="12"\n'
  exit 0
fi
if [ "$SSH_ORIGINAL_COMMAND" = 'ip -j -details address show' ]; then
  case "$mode" in
    exit) exit 2 ;;
    invalid) printf '{invalid'; exit 0 ;;
    large) head -c 1200000 /dev/zero; exit 0 ;;
    stall) sleep 60; exit 0 ;;
  esac
fi
exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"
AUDIT
chmod 755 /usr/local/bin/antirkn-fixture-audit
touch /fixture-data/commands
chmod 711 /fixture-data
chmod 666 /fixture-data/commands
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256 | awk '{print $2}' > /fixture-data/host-fingerprint
ip address add 192.0.2.41/32 dev lo
printf 'ready\n' > /fixture-data/ready
exec /usr/sbin/sshd -D -e
