#!/usr/bin/env python3
"""Local desktop OAuth setup + one-shot synthetic Drive probe. No token files/logs."""
import argparse
import base64
import hashlib
import hmac
import http.server
import json
import os
import re
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

ROOT = Path(__file__).resolve().parent.parent
SCOPE = 'https://www.googleapis.com/auth/drive.appdata'

class SetupFailure(Exception):
    pass

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise SetupFailure('Unexpected HTTP redirect')

def request_json(url, data=None, headers=None):
    request = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=45) as response:
            body = response.read(1024 * 1024 + 1)
            if len(body) > 1024 * 1024:
                raise SetupFailure('Response too large')
            return json.loads(body)
    except urllib.error.HTTPError as error:
        error.close()
        # Never print provider responses; they can contain credentials/identity.
        raise SetupFailure(f'Google request rejected (HTTP {error.code})') from None
    except (OSError, ValueError):
        raise SetupFailure('Google network or response failure') from None

def configure(source, android_client_id=None):
    try:
        content = source.read_bytes()
        if len(content) > 65536:
            raise ValueError()
        document = json.loads(content)
        client = document['installed']
        if (not client['client_id'].endswith('.apps.googleusercontent.com') or
            not client['client_secret'] or not client['project_id'] or
            client['auth_uri'] != 'https://accounts.google.com/o/oauth2/auth' or
            client['token_uri'] != 'https://oauth2.googleapis.com/token'):
            raise ValueError()
    except (OSError, ValueError, KeyError, TypeError):
        raise SetupFailure('Expected a Google Desktop app JSON client') from None
    if android_client_id is not None:
        if (not re.fullmatch(r'[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com', android_client_id) or
            android_client_id.split('-')[0] != client['client_id'].split('-')[0]):
            raise SetupFailure('Android client must belong to the same Google project')
    directory = Path.home()/'.config/antirkn/google'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    destination = directory/'desktop-client.json'
    extra = document.get('antirkn', {})
    if destination.exists() and android_client_id is None:
        previous = json.loads(destination.read_bytes())
        if previous.get('installed', {}).get('client_id') == client['client_id']:
            extra = previous.get('antirkn', extra)
    if android_client_id is not None:
        extra = {'androidClientId': android_client_id, 'androidPackage': 'org.antirkn.antirkn_manager'}
    content = json.dumps({'installed': client, 'antirkn': extra}, indent=2).encode()
    fd, temp = tempfile.mkstemp(prefix='.client-', dir=directory)
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, destination)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)
    return client, destination

def authorize(client, scope=SCOPE):
    state = secrets.token_urlsafe(32)
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
    callback = {}
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass
        def do_GET(self):
            uri = urllib.parse.urlsplit(self.path)
            params = urllib.parse.parse_qs(uri.query)
            received = params.get('state', [])
            valid = (uri.path == '/oauth2/callback' and len(received) == 1 and
                     hmac.compare_digest(received[0], state) and
                     len(params.get('code', [])) == 1)
            if valid:
                callback['code'] = params['code'][0]
            elif uri.path == '/oauth2/callback' and received == [state] and 'error' in params:
                callback['denied'] = True
            self.send_response(200 if valid else 400)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.end_headers()
            self.wfile.write(('Вход получен. Можно закрыть вкладку и вернуться к AntiRKN.' if valid else
                              'Вход не завершён. Вернитесь к окну настройки AntiRKN.').encode())
    server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
    server.timeout = 1
    redirect = f'http://127.0.0.1:{server.server_port}/oauth2/callback'
    url = 'https://accounts.google.com/o/oauth2/v2/auth?' + urllib.parse.urlencode({
        'client_id': client['client_id'], 'redirect_uri': redirect,
        'response_type': 'code', 'scope': scope, 'state': state,
        'code_challenge': challenge, 'code_challenge_method': 'S256',
        'access_type': 'online', 'prompt': 'select_account consent',
    })
    print('Открываю системный браузер. Выберите аккаунт и подтвердите запрошенный доступ к Google Drive.', flush=True)
    try:
        if not webbrowser.open(url):
            raise SetupFailure('System browser could not be opened')
        deadline = time.monotonic() + 900
        while not callback and time.monotonic() < deadline:
            server.handle_request()
    finally:
        server.server_close()
    if 'code' not in callback:
        raise SetupFailure('Google sign-in cancelled or timed out')
    response = request_json('https://oauth2.googleapis.com/token', urllib.parse.urlencode({
        'client_id': client['client_id'], 'client_secret': client['client_secret'],
        'code': callback.pop('code'), 'code_verifier': verifier,
        'redirect_uri': redirect, 'grant_type': 'authorization_code',
    }).encode(), {'Content-Type': 'application/x-www-form-urlencoded'})
    token = response.get('access_token')
    if not isinstance(token, str) or not token or not set(scope.split()).issubset(response.get('scope', scope).split()):
        raise SetupFailure('Google did not grant the requested Drive access')
    user = request_json('https://www.googleapis.com/drive/v3/about?fields=user(permissionId)',
                        headers={'Authorization': 'Bearer ' + token})
    permission_id = user.get('user', {}).get('permissionId')
    if not permission_id:
        raise SetupFailure('Drive account identity unavailable')
    account_key = hashlib.sha256(json.dumps(['drive-appdata-account-v1', client['project_id'], permission_id], separators=(',', ':')).encode()).hexdigest()
    return {'accountKey': account_key, 'accessToken': token}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--client', type=Path, required=True)
    parser.add_argument('--login', action='store_true')
    parser.add_argument('--android-client-id')
    parser.add_argument('--build-android', action='store_true')
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    client, path = configure(args.client.expanduser(), args.android_client_id)
    print(f'Desktop client configured outside Git: {path}', flush=True)
    if args.build_android:
        result = subprocess.run(['flutter', 'build', 'apk', '--debug', '--target-platform', 'android-arm64', '--no-pub',
            '--dart-define=ANTIRKN_GOOGLE_PROJECT_ID=' + client['project_id']], cwd=ROOT/'apps/manager')
        if result.returncode:
            raise SetupFailure('Android build failed')
    if not args.login:
        return
    credentials = authorize(client)
    print('Вход подтверждён. Проверяю синтетический снимок и ключ через настоящий Drive API.', flush=True)
    process = subprocess.run(['dart', 'run', 'tool/drive_smoke.dart'],
        cwd=ROOT, input=json.dumps(credentials),
        text=True, capture_output=True, timeout=600)
    credentials.clear()
    try:
        result = json.loads(process.stdout)
        if result.get('kind') != 'real-google-drive-synthetic-probe':
            raise ValueError()
    except ValueError:
        raise SetupFailure('Dart probe failed to start; run local analyze/tests first') from None
    safe = {'kind': result['kind'], 'status': result.get('status'),
            'checks': {str(k): bool(v) for k,v in result.get('checks', {}).items()}}
    if 'issue' in result:
        safe['issue'] = result['issue']
    output = json.dumps(safe, indent=2, ensure_ascii=False) + '\n'
    if args.evidence:
        args.evidence.write_text(output)
    print(output, end='')
    if process.returncode:
        raise SetupFailure('Drive probe failed; see safe status above')

if __name__ == '__main__':
    try:
        main()
    except (SetupFailure, subprocess.TimeoutExpired) as error:
        print(str(error) if isinstance(error, SetupFailure) else 'Drive probe timed out', flush=True)
        raise SystemExit(1) from None
    except Exception:
        print('Local setup failed; credentials were not printed', flush=True)
        raise SystemExit(1) from None
