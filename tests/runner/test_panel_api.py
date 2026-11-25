"""Exercise real HTTP cookies, CSRF, non-default binds and verified TLS."""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'server/runner'))
from panel_api import PanelApi


class PanelApiTests(unittest.TestCase):
    def exercise(self, tls):
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def reply(self, obj, success=True):
                raw = json.dumps(dict(success=success, obj=obj)).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(raw)))
                self.send_header('Set-Cookie', 'session=fixture; Path=/private/; HttpOnly' + ('; Secure' if tls else ''))
                self.end_headers(); self.wfile.write(raw)
            def do_GET(self):
                if self.path == '/private/csrf-token': self.reply('token')
                else:
                    self.reply([], success=self.path == '/private/panel/api/inbounds/list'
                        and self.headers.get('Cookie') == 'session=fixture')
            def do_POST(self):
                value = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                self.reply(None, success=self.path == '/private/login'
                    and self.headers.get('X-CSRF-Token') == 'token'
                    and self.headers.get('Cookie') == 'session=fixture'
                    and value == dict(username='panel-admin', password='panel-password'))
        with tempfile.TemporaryDirectory() as directory:
            cert, key = Path(directory) / 'cert.pem', Path(directory) / 'key.pem'
            server = HTTPServer(('127.0.0.2', 0), Handler)
            if tls:
                subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                    '-keyout', str(key), '-out', str(cert), '-days', '1', '-subj', '/CN=panel.example'],
                    check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                context.load_cert_chain(cert, key)
                server.socket = context.wrap_socket(server.socket, server_side=True)
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            try:
                api = PanelApi(server.server_port, 'private', host='127.0.0.2',
                    tls=tls, certificate=str(cert) if tls else None)
                with self.assertRaisesRegex(ValueError, '^panel_auth_failed$'):
                    api.login('ssh-user', 'panel-password')
                api.login('panel-admin', 'panel-password')
                self.assertEqual(api.call('/panel/api/inbounds/list'), [])
                if tls:
                    # Trust is scoped to the discovered certificate, never globally disabled.
                    with self.assertRaises(OSError):
                        PanelApi(server.server_port, 'private', host='127.0.0.2', tls=True).login('panel-admin', 'panel-password')
                    # Another certificate than the panel's own fails closed.
                    other = Path(directory) / 'other.pem'
                    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', str(Path(directory) / 'other.key'), '-out', str(other), '-days', '1',
                        '-subj', '/CN=panel.example'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    with self.assertRaises(OSError):
                        PanelApi(server.server_port, 'private', host='127.0.0.2', tls=True,
                                 certificate=str(other)).login('panel-admin', 'panel-password')
            finally:
                server.shutdown(); server.server_close(); thread.join()

    def test_panel_account_csrf_and_cookies_on_specific_listen_address(self):
        self.exercise(False)

    def test_panel_https_with_discovered_certificate(self):
        self.exercise(True)

    def test_certificate_pin_reads_only_a_protected_leaf(self):
        import hashlib
        from panel_api import certificate_pin
        with tempfile.TemporaryDirectory() as directory:
            cert = Path(directory) / 'cert.pem'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                '-keyout', str(Path(directory) / 'key.pem'), '-out', str(cert), '-days', '1', '-subj', '/CN=x'],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            cert.chmod(0o644)
            der = ssl.PEM_cert_to_DER_cert(cert.read_text())
            # A chain file: the leaf comes first.
            chain = Path(directory) / 'chain.pem'
            chain.write_text(cert.read_text() + cert.read_text().replace('A', 'B', 0))
            self.assertEqual(certificate_pin(str(chain)), hashlib.sha256(der).hexdigest())
            cert.chmod(0o666)
            with self.assertRaises(ValueError):
                certificate_pin(str(cert))
            (Path(directory) / 'empty.pem').write_text('no certificate')
            with self.assertRaises(ValueError):
                certificate_pin(str(Path(directory) / 'empty.pem'))

    def test_credentials_never_go_to_a_foreign_address(self):
        # Not an address of this host: refused before any connection.
        with self.assertRaises(OSError):
            PanelApi(2053, '/', host='192.0.2.10')
        # A wildcard listener is reached over loopback.
        self.assertTrue(PanelApi(2053, '/', host='0.0.0.0').base.startswith('http://127.0.0.1:2053'))
        self.assertTrue(PanelApi(2053, '/', host='::').base.startswith('http://[::1]:2053'))
