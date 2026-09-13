#!/usr/bin/env bash
# Runs only inside the disposable Ubuntu fixture, after SSH/key setup.
set -euo pipefail
for account in passuser denieduser limiteduser ttyuser; do
  useradd -m -s /bin/bash "$account"
  install -d -m 700 -o "$account" -g "$account" "/home/$account/.ssh"
  install -m 600 -o "$account" -g "$account" /home/testuser/.ssh/authorized_keys "/home/$account/.ssh/authorized_keys"
done
python3 - <<'PY'
import json, subprocess
from pathlib import Path
password = json.loads(Path('/fixture-data/credentials.json').read_text())['password']
subprocess.run(['chpasswd'], input=''.join(f'{u}:{password}\n' for u in
    ['passuser', 'denieduser', 'limiteduser', 'ttyuser']), text=True, check=True)
PY
cat > /etc/sudoers.d/antirkn-fixture <<'CONF'
Defaults lecture=never
Defaults passwd_tries=1
testuser ALL=(root) NOPASSWD: ALL
passuser ALL=(root) PASSWD: ALL
limiteduser ALL=(root) NOPASSWD: /usr/bin/id -u
ttyuser ALL=(root) NOPASSWD: ALL
Defaults:ttyuser requiretty
CONF
chmod 440 /etc/sudoers.d/antirkn-fixture
visudo -cf /etc/sudoers.d/antirkn-fixture >/dev/null
sed -i 's/^AllowUsers .*/AllowUsers testuser root passuser denieduser limiteduser ttyuser/' /etc/ssh/sshd_config.d/00-antirkn-fixture.conf
mkdir -p /opt/trusttunnel
printf '#!/bin/sh\n[ "$1" = "--version" ] || exit 99\nprintf "TrustTunnel 1.1.0\\n"\n' > /opt/trusttunnel/trusttunnel_endpoint
chmod 700 /opt/trusttunnel
chmod 755 /opt/trusttunnel/trusttunnel_endpoint
# Target of sudo remains a fixed read probe. No access to host Docker socket.
cp /fixture-data/privilege-audit.py /usr/local/bin/antirkn-privilege-audit
chmod 755 /usr/local/bin/antirkn-privilege-audit
sed -i 's|^ForceCommand .*|ForceCommand /usr/local/bin/antirkn-privilege-audit|' /etc/ssh/sshd_config.d/00-antirkn-fixture.conf

sed -i 's|^ForceCommand .*|ForceCommand /usr/local/bin/antirkn-privilege-audit|' /etc/ssh/sshd_target.conf
sed -i 's/^AllowUsers .*/AllowUsers testuser root passuser denieduser limiteduser ttyuser/' /etc/ssh/sshd_target.conf
python3 - <<'PYRELOAD'
import os, signal
from pathlib import Path
os.kill(int(Path('/run/sshd_target.pid').read_text()), signal.SIGHUP)
PYRELOAD
