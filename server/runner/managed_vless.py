"""Existing VLESS: retain the inbound and foreign clients, merge our UUIDs."""
import base64
import copy
import json
import uuid

import vless
from managed_existing import derive, intent, user_enabled
from observed_inbounds import object_field
from vless import VlessError, canonical, digest, normal, subset
from vless_contract import SCHEMA


def snapshot(store, p, r, inbounds=None):
    if inbounds is None:
        api = vless.panel_for(store, p['panelId'])
        inbounds = api.call('/panel/api/inbounds/list')
    row = next((row for row in inbounds
                if str(row['id']) == r['adoption']['sourceId']), None)
    if row is None and not r['deleted']:
        raise VlessError('vpn_adoption_conflict')
    return dict(row=row, fingerprint=digest(normal(row)) if row else digest(None))


def proxy_fields(row):
    stream = object_field(row.get('streamSettings') or '{}')
    settings = object_field(row.get('settings') or '{}')
    if row['protocol'] != 'vless' or settings.get('decryption', 'none') not in ('none', ''):
        raise VlessError('vpn_adoption_unsupported')
    network = stream.get('network', 'tcp')
    if network == 'raw':
        network = 'tcp'
    security = stream.get('security', 'none')
    if security not in ('none', 'tls', 'reality'):
        raise VlessError('vpn_adoption_unsupported')
    proxy = dict(type='vless', udp=True, tls=security != 'none', network=network,
                 **{'packet-encoding': 'xudp'})
    flow = ''
    if security == 'reality':
        reality = stream['realitySettings']
        client_settings = reality.get('settings', {})
        private = base64.urlsafe_b64decode(reality['privateKey'] + '=' * (-len(reality['privateKey']) % 4))
        if len(private) != 32 or not reality.get('serverNames') or not reality.get('shortIds'):
            raise VlessError('vpn_adoption_unsupported')
        public = vless.command(['/usr/bin/openssl', 'pkey', '-inform', 'DER', '-pubout', '-outform', 'DER'],
                               input_data=bytes.fromhex('302e020100300506032b656e04220420') + private)
        if len(public) != 44:
            raise VlessError('vpn_adoption_invalid')
        configured_public = client_settings.get('publicKey') or ''
        try:
            configured_public_bytes = base64.urlsafe_b64decode(configured_public + '=' * (-len(configured_public) % 4))
        except (ValueError, TypeError):
            configured_public_bytes = b''
        if configured_public_bytes and len(configured_public_bytes) != 32:
            raise VlessError('vpn_adoption_invalid')
        proxy.update(servername=client_settings.get('serverName') or reality['serverNames'][0])
        proxy['client-fingerprint'] = client_settings.get('fingerprint') or 'chrome'
        proxy['reality-opts'] = {'public-key': configured_public or base64.urlsafe_b64encode(public[-32:]).decode().rstrip('='),
                                 'short-id': reality['shortIds'][0]}
        if network == 'tcp':
            flow = 'xtls-rprx-vision'
    elif security == 'tls':
        tls = stream.get('tlsSettings', {})
        proxy['servername'] = tls.get('serverName') or ''
        if tls.get('alpn'):
            proxy['alpn'] = tls['alpn']
    else:
        proxy['servername'] = ''
    if network == 'xhttp':
        xhttp = stream.get('xhttpSettings', {})
        props = SCHEMA['properties']['resources']['items']['properties']['xhttp']
        def mapped(values, rule):
            return {rule['properties'][k]['mihomo']: mapped(v, rule['properties'][k]) if k == 'xmux' else v
                    for k, v in values.items() if k in rule['properties'] and 'mihomo' in rule['properties'][k]}
        extra = {k: v for k, v in xhttp.items() if k not in ('path', 'host', 'mode', 'extra')}
        extra.update(xhttp.get('extra') or {})
        proxy['xhttp-opts'] = dict(path=xhttp.get('path') or '/', host=xhttp.get('host') or '',
                                   mode=xhttp.get('mode') or 'auto', **mapped(extra, props))
    elif network in ('ws', 'httpupgrade'):
        opts = stream.get('wsSettings' if network == 'ws' else 'httpupgradeSettings', {})
        proxy['network'] = 'ws'
        proxy['ws-opts'] = dict(path=opts.get('path') or '/', headers=copy.deepcopy(opts.get('headers') or {}))
        if opts.get('host'):
            proxy['ws-opts']['headers']['Host'] = opts['host']
        if network == 'httpupgrade':
            proxy['ws-opts']['v2ray-http-upgrade'] = True
    elif network == 'grpc':
        proxy['grpc-opts'] = {'grpc-service-name': stream.get('grpcSettings', {}).get('serviceName', '')}
    elif network in ('h2', 'http'):
        opts = stream.get('httpSettings', {})
        proxy['network'] = 'h2'
        proxy['h2-opts'] = dict(path=opts.get('path') or '/', host=opts.get('host') or [])
    elif network != 'tcp':
        raise VlessError('vpn_adoption_unsupported')
    if flow:
        proxy['flow'] = flow
    return proxy, flow


def build(store, p, r, old, current, preview=False):
    row = current['row']
    if row is None:
        if not old or not r['deleted']:
            raise VlessError('vpn_adoption_conflict')
        return intent(old, current, None, [], old['proxy'])
    if row.get('remark', '').startswith('AntiRKN:'):
        raise VlessError('vpn_adoption_conflict')
    if not old and (r['port'] != row['port'] or r['enabled'] != row['enable']):
        raise VlessError('vpn_adoption_conflict')
    stream = object_field(row.get('streamSettings') or '{}')
    if r['transport'] != stream.get('network', 'tcp') or r['security'] != stream.get('security', 'none'):
        raise VlessError('vpn_adoption_conflict')
    proxy, flow = proxy_fields(row)
    settings = object_field(row['settings'])
    own_ids = {c['uuid'] for c in (old or {}).get('clients', [])}
    foreign = [c for c in settings.get('clients', []) if c.get('id') not in own_ids]
    clients, additions = [], []
    for user in p['users']:
        uid = str(uuid.UUID(bytes=derive(store, p, r, 'vless/' + user['id'], preview)[:16], version=4))
        email = 'ar_' + r['id'] + '_' + user['id']
        if any(c.get('id') == uid or c.get('email') == email for c in foreign):
            raise VlessError('vpn_adoption_conflict')
        enabled = user_enabled(r, user)
        clients.append(dict(id=user['id'], uuid=uid, enabled=enabled))
        if enabled:
            additions.append(dict(id=uid, email=email, enable=True, flow=flow,
                                  totalGB=0, expiryTime=0, limitIp=0, tgId=0, subId='', reset=0))
    desired = copy.deepcopy(row)
    desired['settings'] = canonical({**settings, 'clients': foreign + additions})
    desired['enable'] = r['enabled']
    if r['deleted']:
        desired = None
    elif preview:
        config = {k: desired[k] for k in ('listen', 'port', 'protocol')}
        for k in ('settings', 'streamSettings', 'sniffing'):
            config[k] = object_field(desired.get(k) or '{}')
        config['settings']['clients'] = [c for c in config['settings']['clients'] if c.get('enable', True)]
        vless.command([str(vless.PANEL / 'bin/xray-linux-amd64'), 'run', '-test', '-config', 'stdin:'],
                      input_data=canonical(dict(inbounds=[config], outbounds=[dict(protocol='freedom')])).encode())
    return intent(old, current, desired, clients, proxy)


def apply(store, p, r, plan):
    current = snapshot(store, p, r)
    if current['fingerprint'] != plan['before']['fingerprint'] and not verify(current, plan):
        raise VlessError('vpn_adoption_conflict')
    if verify(current, plan):
        return
    api = vless.panel_for(store, p['panelId'])
    source = int(r['adoption']['sourceId'])
    if plan['after'] is None:
        api.call('/panel/api/inbounds/del/%d' % source, {})
    else:
        api.call('/panel/api/inbounds/update/%d' % source, plan['after'])


def healthy(current):
    return True  # The enclosing VLESS job verifies Xray after its final restart.


def verify(current, plan):
    return current['row'] is None if plan['after'] is None else current['row'] is not None and subset(normal(plan['after']), normal(current['row']))
