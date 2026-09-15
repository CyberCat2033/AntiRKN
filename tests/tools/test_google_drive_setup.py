"""Security boundaries of local OAuth setup; no Google requests or real tokens."""
import base64
import contextlib
import hashlib
import http.server
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest import mock
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('drive_setup', ROOT/'tool/google_drive_setup.py')
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)

CLIENT = {'client_id': 'public-fixture.apps.googleusercontent.com',
          'client_secret': 'public-test-client-secret', 'project_id': 'public-project',
          'auth_uri': 'https://accounts.google.com/o/oauth2/auth',
          'token_uri': 'https://oauth2.googleapis.com/token'}

class SetupTests(unittest.TestCase):
    def test_private_configuration_and_invalid_client_preserves_previous_file(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(Path, 'home', return_value=Path(directory)):
            source = Path(directory)/'download.json'
            source.write_text(json.dumps({'installed': CLIENT}))
            client, target = setup.configure(source)
            self.assertEqual(client, CLIENT)
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            self.assertEqual(target.parent.stat().st_mode & 0o777, 0o700)
            previous = target.read_bytes()
            for value in [{'web': CLIENT}, {'installed': {**CLIENT, 'token_uri': 'https://attacker.invalid/token'}}, {}]:
                source.write_text(json.dumps(value))
                with self.assertRaises(setup.SetupFailure):
                    setup.configure(source)
                self.assertEqual(target.read_bytes(), previous)

    def test_android_id_binding_is_saved_and_preserved_without_printing_client_secret(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(Path, 'home', return_value=Path(directory)):
            source = Path(directory)/'download.json'
            client = {**CLIENT, 'client_id': '123-desktop.apps.googleusercontent.com'}
            source.write_text(json.dumps({'installed': client}))
            _, target = setup.configure(source, '123-android.apps.googleusercontent.com')
            self.assertEqual(json.loads(target.read_bytes())['antirkn']['androidClientId'],
                             '123-android.apps.googleusercontent.com')
            setup.configure(source)
            previous = target.read_bytes()
            with self.assertRaises(setup.SetupFailure):
                setup.configure(source, '999-android.apps.googleusercontent.com')
            self.assertEqual(target.read_bytes(), previous)

    def _flow(self, *, denied=False):
        captured = {}
        workers = []
        callbacks = []
        def browser(url):
            values = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
            captured.update(values)
            def callback():
                for state, params in [('forged-state', {'code': 'forged-code'}),
                                      (values['state'][0], {'error': 'access_denied'} if denied else {'code': 'private-code-fixture'})]:
                    uri = values['redirect_uri'][0] + '?' + urllib.parse.urlencode({'state': state, **params})
                    try:
                        with urllib.request.urlopen(uri, timeout=5) as response:
                            callbacks.append((response.status, response.read()))
                    except urllib.error.HTTPError as error:
                        callbacks.append((error.code, error.read()))
                        error.close()
            worker = threading.Thread(target=callback)
            workers.append(worker)
            worker.start()
            return True
        def google(url, data=None, headers=None):
            if data is not None:
                captured['exchange'] = urllib.parse.parse_qs(data.decode())
                return {'access_token': 'private-access-fixture', 'scope': setup.SCOPE}
            self.assertEqual(headers, {'Authorization': 'Bearer private-access-fixture'})
            return {'user': {'permissionId': 'private-account-fixture'}}
        output = io.StringIO()
        with mock.patch.object(setup.webbrowser, 'open', side_effect=browser), \
             mock.patch.object(setup, 'request_json', side_effect=google) as requests, \
             contextlib.redirect_stdout(output):
            if denied:
                with self.assertRaises(setup.SetupFailure):
                    setup.authorize(CLIENT)
                result = None
                self.assertFalse(requests.called)
            else:
                result = setup.authorize(CLIENT)
        for worker in workers:
            worker.join(5)
            self.assertFalse(worker.is_alive())
        self.assertEqual(callbacks[0][0], 400)
        self.assertNotIn('private-code-fixture', output.getvalue())
        self.assertNotIn('private-access-fixture', output.getvalue())
        for _, body in callbacks:
            self.assertNotIn(b'private-code-fixture', body)
        return result, captured

    def test_pkce_system_browser_flow_rejects_forged_callback_and_hides_credentials(self):
        result, captured = self._flow()
        self.assertEqual(result['accessToken'], 'private-access-fixture')
        self.assertNotIn('private-account-fixture', result['accountKey'])
        self.assertEqual(captured['scope'], [setup.SCOPE])
        self.assertEqual(captured['access_type'], ['online'])
        self.assertEqual(captured['exchange']['code'], ['private-code-fixture'])
        verifier = captured['exchange']['code_verifier'][0]
        expected = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
        self.assertEqual(captured['code_challenge'], [expected])
        self.assertEqual(captured['exchange']['redirect_uri'], captured['redirect_uri'])

    def test_denied_consent_never_exchanges_a_code(self):
        self._flow(denied=True)

    def test_http_redirect_is_rejected_without_relaying_authorization(self):
        hits = []
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                hits.append(self.path)
                self.send_response(302)
                self.send_header('Location', '/leak')
                self.end_headers()
        server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        worker = threading.Thread(target=server.serve_forever)
        worker.start()
        try:
            with self.assertRaises(setup.SetupFailure):
                setup.request_json(f'http://127.0.0.1:{server.server_port}/first', headers={'Authorization':'Bearer fixture'})
            self.assertEqual(hits, ['/first'])
        finally:
            server.shutdown()
            server.server_close()
            worker.join()

if __name__ == '__main__':
    unittest.main()
