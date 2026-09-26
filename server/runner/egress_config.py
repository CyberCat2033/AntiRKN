"""VLESS share links and reversible edits of the panel's Xray template."""
import copy
import ipaddress
import json
import re
import uuid
from urllib.parse import parse_qsl, unquote, urlsplit

TAG = 'antirkn-client-egress'
SOCKS = TAG + '-socks'
TUN4 = TAG + '-awg4'
TUN6 = TAG + '-awg6'
TAGS = {TAG, SOCKS, TUN4, TUN6}


class EgressError(Exception):
    def __init__(self, code='egress_invalid'):
        self.code = code


def parse_link(value):
    """Reject unsupported options instead of silently changing the connection."""
    try:
        if not isinstance(value, str) or len(value) > 16384 or any(ord(c) < 32 for c in value):
            raise ValueError()
        uri = urlsplit(value.strip())
        if uri.scheme != 'vless' or uri.password is not None or uri.path not in ('', '/'):
            raise ValueError()
        user = str(uuid.UUID(unquote(uri.username or '')))
        host, port = uri.hostname, uri.port
        if not host or not port or not 1 <= port <= 65535:
            raise ValueError()
        try:
            address = ipaddress.ip_address(host)
            if address.is_unspecified or address.is_multicast or address.is_loopback:
                raise ValueError()
        except ValueError:
            if not re.fullmatch(r'(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?', host):
                raise ValueError()
            if host.lower() == 'localhost' or re.fullmatch(r'[0-9.]+', host):
                raise ValueError()
        pairs = parse_qsl(uri.query, keep_blank_values=True, strict_parsing=True)
        q = dict(pairs)
        if len(q) != len(pairs): raise ValueError()
        allowed = {'type', 'security', 'encryption', 'flow', 'sni', 'fp', 'pbk', 'sid', 'spx',
                   'path', 'host', 'mode', 'alpn', 'serviceName', 'authority', 'extra', 'headerType', 'allowInsecure'}
        if set(q) - allowed: raise ValueError()
        network = q.get('type', 'tcp')
        network = 'raw' if network == 'tcp' else network
        if network not in ('raw', 'xhttp', 'ws', 'grpc', 'httpupgrade'): raise ValueError()
        if 'headerType' in q and (network != 'raw' or q['headerType'] != 'none'): raise ValueError()
        if 'allowInsecure' in q and q['allowInsecure'] not in ('0', 'false'): raise ValueError()
        security = q.get('security', 'none')
        if security not in ('tls', 'reality') or q.get('encryption', 'none') != 'none':
            raise ValueError()
        flow = q.get('flow', '')
        if flow not in ('', 'xtls-rprx-vision') or flow and network != 'raw': raise ValueError()
        stream = dict(network=network, security=security)
        tls = dict(serverName=q.get('sni', host), fingerprint=q.get('fp', 'chrome'))
        if security == 'reality':
            if not re.fullmatch(r'[A-Za-z0-9_-]{43}', q.get('pbk', '')): raise ValueError()
            if not re.fullmatch(r'(?:[a-fA-F0-9]{2}){0,8}', q.get('sid', '')): raise ValueError()
            tls.update(publicKey=q['pbk'], shortId=q.get('sid', ''), spiderX=q.get('spx', ''))
        else:
            if any(k in q for k in ('pbk', 'sid', 'spx')): raise ValueError()
            if q.get('alpn'): tls['alpn'] = q['alpn'].split(',')
        stream[security + 'Settings'] = tls
        if network == 'xhttp':
            mode = q.get('mode', 'auto')
            if mode not in ('auto', 'packet-up', 'stream-up', 'stream-one'): raise ValueError()
            if security == 'reality' and mode not in ('auto', 'stream-one'): raise ValueError()
            settings = dict(path=q.get('path', '/'), host=q.get('host', ''), mode=mode)
            if q.get('extra'):
                extra = json.loads(q['extra'])
                if not isinstance(extra, dict) or set(extra) & {'downloadSettings', 'sockopt'}: raise ValueError()
                settings['extra'] = extra
            stream['xhttpSettings'] = settings
        elif network in ('ws', 'httpupgrade'):
            settings = dict(path=q.get('path', '/'))
            if q.get('host'):
                settings['headers' if network == 'ws' else 'host'] = {'Host': q['host']} if network == 'ws' else q['host']
            stream[network + 'Settings'] = settings
        elif network == 'grpc':
            stream['grpcSettings'] = dict(serviceName=q.get('serviceName', ''), authority=q.get('authority', ''))
        if network != 'xhttp' and any(k in q for k in ('mode', 'extra')): raise ValueError()
        if network != 'grpc' and any(k in q for k in ('serviceName', 'authority')): raise ValueError()
        if network == 'raw' and any(k in q for k in ('path', 'host')): raise ValueError()
        outbound = dict(tag=TAG, protocol='vless', settings=dict(vnext=[dict(address=host, port=port,
            users=[dict(id=user, encryption='none', flow=flow)])]), streamSettings=stream)
        name = unquote(uri.fragment).strip() or host
        if len(name) > 128 or any(ord(c) < 32 for c in name): raise ValueError()
        return dict(outbound=outbound, name=name, host=host, port=port, transport=network, security=security)
    except (ValueError, TypeError, KeyError, AttributeError):
        raise EgressError() from None


def service_inbounds(socks_port, transparent_port):
    return [dict(tag=SOCKS, listen='127.0.0.1', port=socks_port, protocol='socks',
                 settings=dict(auth='noauth', udp=True, ip='127.0.0.1')),
            *[dict(tag=tag, listen=listen, port=transparent_port, protocol='dokodemo-door',
                   settings=dict(network='tcp,udp', followRedirect=True),
                   streamSettings=dict(sockopt=dict(tproxy='tproxy')))
              for tag, listen in ((TUN4, '127.0.0.1'), (TUN6, '::1'))]]


def remove_owned(template, owned):
    """Remove our exact entries; keep later unrelated panel edits and rule order."""
    result = copy.deepcopy(template)
    for key in ('inbounds', 'outbounds'):
        entries = result.get(key, [])
        for item in owned.get(key, []):
            matches = [x for x in entries if x.get('tag') == item['tag']]
            if matches != [item]: raise EgressError('egress_conflict')
            entries.remove(item)
    rules = result.get('routing', {}).get('rules', [])
    for item in owned.get('rules', []):
        if rules.count(item) != 1: raise EgressError('egress_conflict')
        rules.remove(item)
    if any(x.get('outboundTag') == TAG or x.get('balancerTag') == TAG for x in rules):
        raise EgressError('egress_conflict')
    return result


def configure(template, connection, socks_port, transparent_port, previous=None):
    result = remove_owned(template, previous) if previous else copy.deepcopy(template)
    if any(x.get('tag') in TAGS for key in ('inbounds', 'outbounds') for x in result.get(key, [])):
        raise EgressError('egress_conflict')
    if connection is None: return result, {}
    inbounds = service_inbounds(socks_port, transparent_port)
    rule = dict(type='field', network='tcp,udp', outboundTag=TAG)
    result.setdefault('inbounds', []).extend(inbounds)
    result.setdefault('outbounds', []).append(connection['outbound'])
    result.setdefault('routing', {}).setdefault('rules', []).append(rule)
    owned = copy.deepcopy(dict(inbounds=inbounds, outbounds=[connection['outbound']], rules=[rule]))
    return result, owned
