"""Owned AWG firewall rules. Called only by our root-owned awg-quick hooks."""
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from panel import safe_file

ROOT = Path('/etc/antirkn-components/amneziawg')


def run(args, check=True):
    return subprocess.run(args, check=check, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=30)


def rules(data, name):
    for family, pool in ((4, data['pool']), (6, data['pool6'])):
        if not pool:
            continue
        network = ipaddress.ip_network(pool)
        if network.version != family:
            raise ValueError('awg_invalid')
        binary = '/usr/sbin/iptables' if family == 4 else '/usr/sbin/ip6tables'
        comment = ['-m', 'comment', '--comment', 'antirkn-' + name]
        yield binary, 'filter', 'FORWARD', ['-i', name, '-s', pool, *comment, '-j', 'ACCEPT']
        yield binary, 'filter', 'FORWARD', ['-o', name, '-d', pool, '-m', 'conntrack', '--ctstate', 'RELATED,ESTABLISHED', *comment, '-j', 'ACCEPT']
        yield binary, 'nat', 'POSTROUTING', ['-s', pool, '!', '-o', name, *comment, '-j', 'MASQUERADE']
    # AWG has a wildcard UDP socket; endpoint selection does not imply bind-IP.
    for binary in ('/usr/sbin/iptables', '/usr/sbin/ip6tables'):
        if Path(binary).exists():
            yield binary, 'filter', 'INPUT', ['-p', 'udp', '--dport', str(data['port']), '-m', 'comment', '--comment', 'antirkn-' + name, '-j', 'ACCEPT']


def configure(action, name):
    if action not in ('up', 'down') or not re.fullmatch(r'ar[a-f0-9]{12}', name):
        raise ValueError('awg_invalid')
    path = ROOT / (name + '.network.json')
    safe_file(path)
    data = json.loads(path.read_text())
    if type(data['port']) is not int or not 1 <= data['port'] <= 65535:
        raise ValueError('awg_invalid')
    with (ROOT / '.network.lock').open('a') as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        if action == 'up':
            from egress_network import register_interface
            register_interface(name)
            run(['/usr/sbin/sysctl', '-w', 'net.ipv4.ip_forward=1'])
            if data['pool6']:
                run(['/usr/sbin/sysctl', '-w', 'net.ipv6.conf.all.forwarding=1'])
        for binary, table, chain, rule in rules(data, name):
            prefix = [binary, '-w', '10', '-t', table]
            present = run([*prefix, '-C', chain, *rule], check=False).returncode == 0
            if action == 'up' and not present:
                run([*prefix, '-I', chain, '1', *rule])
            elif action == 'down' and present:
                run([*prefix, '-D', chain, *rule])


if __name__ == '__main__':
    os.umask(0o077)
    try:
        if os.geteuid() != 0 or len(sys.argv) != 3:
            raise ValueError('awg_invalid')
        configure(sys.argv[1], sys.argv[2])
    except Exception:
        # No firewall/config/key material in journal output.
        print('awg_network_failed', file=sys.stderr)
        sys.exit(1)
