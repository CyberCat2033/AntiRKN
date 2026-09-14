"""Pinned 3x-ui session API. Used inside the isolated bootstrap namespace.

Inputs/outputs are private stdin/stdout, never command arguments or logs.
"""
import http.cookiejar
import json
import urllib.request


class PanelApi:
    def __init__(self, port):
        self.base = 'http://127.0.0.1:%d' % port
        self.client = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self.csrf = None

    def call(self, path, data=None):
        headers = {'Connection': 'close', 'Origin': self.base}
        if self.csrf:
            headers['X-CSRF-Token'] = self.csrf
        if data is not None:
            headers['Content-Type'] = 'application/json'
        req = urllib.request.Request(self.base + path, headers=headers,
            data=json.dumps(data).encode() if data is not None else None)
        with self.client.open(req, timeout=20) as response:
            raw = response.read(524289)
        if len(raw) > 524288:
            raise ValueError('panel_api_failed')
        result = json.loads(raw)
        if result.get('success') is not True:
            raise ValueError('panel_api_failed')
        return result.get('obj')

    def login(self, username, password):
        self.csrf = self.call('/csrf-token')
        self.call('/login', dict(username=username, password=password))
        self.csrf = self.call('/csrf-token')


def configure_panel(access):
    api = PanelApi(access['port'])
    try:
        api.login(access['username'], access['password'])
    except (ValueError, OSError):
        # Only our private namespace and freshly owned DB may use this fallback.
        api = PanelApi(access['port'])
        api.login('admin', 'admin')
        api.call('/panel/api/setting/updateUser', dict(oldUsername='admin',
            oldPassword='admin', newUsername=access['username'],
            newPassword=access['password']))
        api.login(access['username'], access['password'])
    settings = api.call('/panel/api/setting/all', {})
    settings.update(webListen='127.0.0.1', webPort=access['port'],
                    webBasePath='/', subEnable=False, subJsonEnable=False,
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
