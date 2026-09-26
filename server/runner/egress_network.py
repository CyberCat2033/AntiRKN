"""Persistent interception of native AWG client packets. Never touches OUTPUT."""
import json
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from egress_config import EgressError

CHAIN = 'ANTIRKN_EGRESS'
MARK = '0x4152'
TABLE = '16722'
PRIORITY = '16722'
STATE = Path('/var/lib/antirkn-runner/client-egress.json')


def run(args, check=True):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    if check and result.returncode: raise EgressError('egress_network')
    return result


def rule(binary, chain, args, present=True, table='mangle'):
    prefix = [binary, '-w', '10', '-t', table]
    exists = run([*prefix, '-C', chain, *args], False).returncode == 0
    if present and not exists: run([*prefix, '-I', chain, '1', *args])
    if not present and exists: run([*prefix, '-D', chain, *args])


def validate_interfaces(names):
    if not isinstance(names, list) or len(names) > 64 or any(
            not isinstance(n, str) or not re.fullmatch(r'[A-Za-z0-9_=.-]{1,15}', n) for n in names):
        raise EgressError('egress_unsupported')
    return sorted(set(names))


def available():
    if any(not Path(p).exists() for p in ('/usr/sbin/iptables', '/usr/sbin/ip6tables', '/usr/sbin/ip')):
        raise EgressError('egress_network')


def check_reservations(owned=False):
    available()
    if owned: return
    for family, binary in (('-4', '/usr/sbin/iptables'), ('-6', '/usr/sbin/ip6tables')):
        rules = json.loads(run(['/usr/sbin/ip', family, '-j', 'rule', 'show']).stdout)
        if any(str(r.get('priority')) == PRIORITY or str(r.get('table')) == TABLE or
               str(r.get('fwmark')) in (MARK, str(int(MARK, 16))) for r in rules):
            raise EgressError('egress_conflict')
        routes = run(['/usr/sbin/ip', family, 'route', 'show', 'table', TABLE], False)
        if routes.returncode == 0 and routes.stdout.strip(): raise EgressError('egress_conflict')
        if run([binary, '-t', 'mangle', '-S', CHAIN], False).returncode == 0:
            raise EgressError('egress_conflict')


def configure(names, port, enabled=True, previous=()):
    names = validate_interfaces(names)
    old = validate_interfaces(list(previous))
    if type(port) is not int or not 1024 <= port <= 65535: raise EgressError()
    selected = names
    for family, binary, loopback in (('-4', '/usr/sbin/iptables', '127.0.0.1'),
                                      ('-6', '/usr/sbin/ip6tables', '::1')):
        if enabled:
            # A guard in mangle/FORWARD precedes every existing filter/NAT ACCEPT.
            # If Xray stops, intercepted packets remain local and cannot fall back.
            for name in selected:
                rule(binary, 'FORWARD', ['-i', name, '-m', 'comment', '--comment', CHAIN, '-j', 'DROP'])
                # TPROXY delivers marked packets locally even with a default
                # INPUT drop policy. Only our VPN ingress/mark is admitted.
                rule(binary, 'INPUT', ['-i', name, '-m', 'mark', '--mark', MARK + '/0xffffffff',
                     '-m', 'comment', '--comment', CHAIN, '-j', 'ACCEPT'], table='filter')
            if run([binary, '-t', 'mangle', '-S', CHAIN], False).returncode:
                run([binary, '-w', '10', '-t', 'mangle', '-N', CHAIN])
            run(['/usr/sbin/ip', family, 'route', 'replace', 'local', 'default', 'dev', 'lo', 'table', TABLE])
            rules = json.loads(run(['/usr/sbin/ip', family, '-j', 'rule', 'show']).stdout)
            if not any(str(r.get('priority')) == PRIORITY for r in rules):
                run(['/usr/sbin/ip', family, 'rule', 'add', 'priority', PRIORITY, 'fwmark', MARK, 'lookup', TABLE])
            # Restore is atomic per address family; it changes only our named chain.
            lines = ['*mangle', '-F ' + CHAIN]
            if family == '-6':
                # Link neighbour discovery terminates on this host; it must not
                # be treated as client Internet traffic or sent to VLESS.
                for kind in ('neighbor-solicitation', 'neighbor-advertisement'):
                    lines.append('-A %s -p ipv6-icmp --icmpv6-type %s -j RETURN' % (CHAIN, kind))
            for protocol in ('tcp', 'udp'):
                lines.append('-A %s -p %s -j TPROXY --on-ip %s --on-port %d --tproxy-mark %s/0xffffffff' %
                             (CHAIN, protocol, loopback, port, MARK))
            lines.extend(['-A ' + CHAIN + ' -j DROP', 'COMMIT', ''])
            result = subprocess.run([binary + '-restore', '--noflush', '--wait', '10'],
                input='\n'.join(lines).encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
            if result.returncode: raise EgressError('egress_network')
            for name in selected:
                rule(binary, 'PREROUTING', ['-i', name, '-m', 'comment', '--comment', CHAIN, '-j', CHAIN])
        for name in sorted(set([*old, *names]) - (set(selected) if enabled else set())):
            rule(binary, 'PREROUTING', ['-i', name, '-m', 'comment', '--comment', CHAIN, '-j', CHAIN], False)
            rule(binary, 'FORWARD', ['-i', name, '-m', 'comment', '--comment', CHAIN, '-j', 'DROP'], False)
            rule(binary, 'INPUT', ['-i', name, '-m', 'mark', '--mark', MARK + '/0xffffffff',
                 '-m', 'comment', '--comment', CHAIN, '-j', 'ACCEPT'], False, table='filter')
        if not enabled:
            if run([binary, '-t', 'mangle', '-S', CHAIN], False).returncode == 0:
                run([binary, '-w', '10', '-t', 'mangle', '-F', CHAIN])
                run([binary, '-w', '10', '-t', 'mangle', '-X', CHAIN])
            run(['/usr/sbin/ip', family, 'rule', 'del', 'priority', PRIORITY, 'fwmark', MARK, 'lookup', TABLE], False)
            run(['/usr/sbin/ip', family, 'route', 'del', 'local', 'default', 'dev', 'lo', 'table', TABLE], False)


def intact(info):
    for family, binary, loopback in (('-4', '/usr/sbin/iptables', '127.0.0.1'),
                                      ('-6', '/usr/sbin/ip6tables', '::1')):
        for name in validate_interfaces(info['interfaces']):
            for chain, target in (('PREROUTING', CHAIN), ('FORWARD', 'DROP')):
                if run([binary, '-w', '10', '-t', 'mangle', '-C', chain, '-i', name,
                        '-m', 'comment', '--comment', CHAIN, '-j', target], False).returncode:
                    raise EgressError('egress_network')
            if run([binary, '-w', '10', '-t', 'filter', '-C', 'INPUT', '-i', name,
                    '-m', 'mark', '--mark', MARK + '/0xffffffff', '-m', 'comment', '--comment', CHAIN, '-j', 'ACCEPT'], False).returncode:
                raise EgressError('egress_network')
        for protocol in ('tcp', 'udp'):
            if run([binary, '-w', '10', '-t', 'mangle', '-C', CHAIN, '-p', protocol,
                    '-j', 'TPROXY', '--on-ip', loopback, '--on-port', str(info['transparentPort']),
                    '--tproxy-mark', MARK + '/0xffffffff'], False).returncode:
                raise EgressError('egress_network')
        rules = json.loads(run(['/usr/sbin/ip', family, '-j', 'rule', 'show']).stdout)
        if not any(str(r.get('priority')) == PRIORITY and str(r.get('table')) == TABLE
                   and str(r.get('fwmark')) in (MARK, str(int(MARK, 16))) for r in rules):
            raise EgressError('egress_network')
        routes = json.loads(run(['/usr/sbin/ip', family, '-j', 'route', 'show', 'table', TABLE]).stdout)
        if not any(r.get('type') == 'local' and r.get('dst') == 'default' and r.get('dev') == 'lo' for r in routes):
            raise EgressError('egress_network')


def main():
    from panel import safe_file
    safe_file(STATE)
    info = json.loads(STATE.read_text())
    if info.get('enabled'):
        configure(info['interfaces'], info['transparentPort'], previous=info.get('previousInterfaces', []))


def register_interface(name):
    """A newly created managed AWG is covered by its PostUp before forwarding."""
    if not STATE.exists(): return
    if not re.fullmatch(r'ar[a-f0-9]{12}', name): raise EgressError()
    from panel import safe_file, atomic_file
    safe_file(STATE)
    info = json.loads(STATE.read_text())
    if not info.get('enabled'): return
    if name not in info['interfaces']:
        info['interfaces'] = validate_interfaces([*info['interfaces'], name])
        atomic_file(STATE, json.dumps(info, sort_keys=True, separators=(',', ':')).encode())
    configure(info['interfaces'], info['transparentPort'])


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('egress_network', file=sys.stderr)
        sys.exit(1)
