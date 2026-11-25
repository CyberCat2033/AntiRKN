"""Pinned 3x-ui session API. Used inside the isolated bootstrap namespace.

Inputs/outputs are private stdin/stdout, never command arguments or logs.
"""
import http.cookiejar
import ipaddress
import json
import re
import urllib.request
import urllib.parse
from urllib.error import HTTPError


def normalize_base_path(value):
    """Return the panel webpath in the form used by every API request."""
    if value is None:
        return '/'
    if not isinstance(value, str):
        raise ValueError('panel_base_path')
    value = value.strip()
    if not value:
        return '/'
    if not value.startswith('/'):
        value = '/' + value
    if value == '/':
        return value
    if len(value) > 2048 or any(ord(char) < 0x20 for char in value):
        raise ValueError('panel_base_path')
    if '\\' in value or '?' in value or '#' in value:
        raise ValueError('panel_base_path')
    if not re.fullmatch(r'/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*/?', value):
        raise ValueError('panel_base_path')
    return value if value.endswith('/') else value + '/'



def xray_status(status):
    """The xray part of /panel/api/server/status; {} while 3x-ui has none.
    Right after a start or an Xray restart it answers success with obj null
    or xray null; calling .get on that crashed the runner daemon."""
    xray = status.get('xray') if isinstance(status, dict) else None
    return xray if isinstance(xray, dict) else {}

def certificate_pin(path):
    """SHA-256 of the leaf (first) certificate in the panel's own PEM file.

    The file must be a root-owned regular file nobody else can write (a
    certbot live/ link is followed to its archive file)."""
    import hashlib
    import os
    import ssl
    import stat
    fd = os.open(str(path), os.O_RDONLY | getattr(os, 'O_CLOEXEC', 0))
    try:
        meta = os.fstat(fd)
        if (not stat.S_ISREG(meta.st_mode) or meta.st_uid != 0 or meta.st_mode & 0o022
                or meta.st_size > 1048576):
            raise ValueError('panel_certificate')
        with os.fdopen(os.dup(fd), 'rb') as stream:
            text = stream.read(1048577).decode('ascii', 'replace')
    finally:
        os.close(fd)
    begin, end = '-----BEGIN CERTIFICATE-----', '-----END CERTIFICATE-----'
    start = text.find(begin)
    stop = text.find(end, start)
    if start < 0 or stop < 0:
        raise ValueError('panel_certificate')
    der = ssl.PEM_cert_to_DER_cert(text[start:stop + len(end)] + '\n')
    return hashlib.sha256(der).hexdigest()


def is_local_address(address):
    """Whether the address belongs to this host, so a connection to it never
    leaves the machine. Read from the kernel's local routes; a bind() test
    would pass for any address with net.ipv4.ip_nonlocal_bind=1."""
    try:
        if address.version == 6:
            with open('/proc/net/if_inet6') as stream:
                return any(line.split() and ipaddress.IPv6Address(int(line.split()[0], 16)) == address
                           for line in stream)
        with open('/proc/net/fib_trie') as stream:
            last = None
            for line in stream:
                text = line.strip()
                if text.startswith('|-- '):
                    last = text[4:]
                elif text == '/32 host LOCAL' and last == str(address):
                    return True
    except (OSError, ValueError):
        pass
    return False


def pinned_handler(context, pin):
    """HTTPS that accepts exactly one leaf certificate: the panel's own."""
    import hashlib
    import http.client
    import ssl

    class Connection(http.client.HTTPSConnection):
        def connect(self):
            super().connect()
            der = self.sock.getpeercert(binary_form=True)
            if not der or hashlib.sha256(der).hexdigest() != pin:
                self.sock.close()
                raise ssl.SSLError('panel_certificate')

    class Handler(urllib.request.HTTPSHandler):
        def https_open(self, req):
            return self.do_open(Connection, req, context=context)

    return Handler(context=context)


class PanelApi:
    def __init__(self, port, base_path='/', *, tls=False, certificate=None, host='127.0.0.1'):
        base_path = normalize_base_path(base_path)
        address = ipaddress.ip_address(host or '127.0.0.1')
        if address.is_unspecified:
            # A wildcard listener is reached over loopback; credentials never
            # travel to a routable address.
            address = ipaddress.ip_address('::1' if address.version == 6 else '127.0.0.1')
        elif not address.is_loopback and not is_local_address(address):
            raise OSError('panel_address')
        hostname = '[%s]' % address if address.version == 6 else str(address)
        self.base = ('https' if tls else 'http') + '://%s:%d' % (hostname, port)
        self.origin = self.base
        self.base += base_path.rstrip('/')
        handlers = []
        if tls:
            import ssl
            if certificate:
                # Trust exactly the certificate the panel serves from its own
                # file (self-signed or not); a mismatch fails closed.
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                context.check_hostname = False
                context.verify_mode = ssl.CERT_NONE
                handlers.append(pinned_handler(context, certificate_pin(certificate)))
            elif not address.is_loopback:
                raise ValueError('panel_certificate')
            else:
                context = ssl.create_default_context()
                context.check_hostname = False
                handlers.append(urllib.request.HTTPSHandler(context=context))
        self.client = urllib.request.build_opener(
            *handlers,
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self.csrf = None

    @classmethod
    def from_access(cls, access):
        """A logged-in session from a stored access record."""
        api = cls(access['port'], access.get('basePath', '/'), tls=access.get('tls', False),
            certificate=access.get('certificate'), host=access.get('host', '127.0.0.1'))
        api.login(access['username'], access['password'])
        return api

    def call(self, path, data=None, *, form=False):
        headers = {'Connection': 'close', 'Origin': self.origin}
        if self.csrf:
            headers['X-CSRF-Token'] = self.csrf
        if data is not None:
            headers['Content-Type'] = 'application/x-www-form-urlencoded' if form else 'application/json'
        req = urllib.request.Request(self.base + path, headers=headers,
            data=(urllib.parse.urlencode(data) if form else json.dumps(data)).encode() if data is not None else None)
        with self.client.open(req, timeout=20) as response:
            raw = response.read(4194305)
        if len(raw) > 4194304:
            raise ValueError('panel_api_failed')
        result = json.loads(raw)
        if result.get('success') is not True:
            raise ValueError('panel_api_failed')
        return result.get('obj')

    def login(self, username, password):
        self.csrf = self.call('/csrf-token')
        try:
            self.call('/login', dict(username=username, password=password))
        except HTTPError as error:
            if error.code == 429: raise ValueError('panel_login_limited') from None
            if error.code == 401: raise ValueError('panel_auth_failed') from None
            raise
        except ValueError:
            raise ValueError('panel_auth_failed') from None
        self.csrf = self.call('/csrf-token')


def restart_xray(api, timeout=20, sleep=None):
    """Restart the panel's Xray and wait until it reports running."""
    import time
    sleep = sleep or time.sleep
    api.call('/panel/api/server/restartXrayService', {})
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if xray_status(api.call('/panel/api/server/status')).get('state') == 'running':
            return
        sleep(.25)
    raise ValueError('panel_api_failed')


def configure_panel(access):
    api = PanelApi(access['port'], access.get('basePath', '/'))
    try:
        api.login(access['username'], access['password'])
    except (ValueError, OSError):
        # Only our private namespace and freshly owned DB may use this fallback.
        api = PanelApi(access['port'], access.get('basePath', '/'))
        api.login('admin', 'admin')
        api.call('/panel/api/setting/updateUser', dict(oldUsername='admin',
            oldPassword='admin', newUsername=access['username'],
            newPassword=access['password']))
        api.login(access['username'], access['password'])
    settings = api.call('/panel/api/setting/all', {})
    settings.update(webListen='127.0.0.1', webPort=access['port'],
                    webBasePath=access.get('basePath', '/'), subEnable=False, subJsonEnable=False,
                    subListen='127.0.0.1', tgBotEnable=False)
    api.call('/panel/api/setting/update', settings)
    observed = api.call('/panel/api/setting/all', {})
    if (observed.get('webListen') != '127.0.0.1'
            or observed.get('webPort') != access['port']
            or observed.get('subEnable') is not False
            or observed.get('subJsonEnable') is not False):
        raise ValueError('panel_api_failed')


if __name__ == '__main__':
    import sys
    try:
        configure_panel(json.loads(sys.stdin.buffer.read(4096)))
        print('{"configured":true}')
    except Exception:
        # Upstream responses may contain secrets; return only a stable code.
        print('{"error":"panel_api_failed"}')
        sys.exit(1)
