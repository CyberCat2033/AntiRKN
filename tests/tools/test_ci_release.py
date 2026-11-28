"""Release CI helpers (tool/ci): versions, defines, changelog, packaging, asset checks.

No network, Android SDK or Flutter build: bundles and APK metadata are fixtures.
"""
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location('ci_' + name, ROOT / 'tool/ci' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release_version = load('release_version')
google_defines = load('google_defines')
changelog_check = load('changelog_check')
package = load('package')
release_assets = load('release_assets')
android_release = load('android_release')
fetch_tool = load('fetch_tool')


def quiet(function, *args):
    with contextlib.redirect_stdout(io.StringIO()) as output, contextlib.redirect_stderr(io.StringIO()):
        code = function(*args)
    return code, output.getvalue()


class VersionTest(unittest.TestCase):
    def test_build_number(self):
        self.assertEqual(release_version.parse('v1.2.3'), ('1.2.3', 10203))
        self.assertEqual(release_version.parse('v0.10.0'), ('0.10.0', 1000))

    def test_rejects_non_stable_or_ambiguous_tags(self):
        for tag in ('1.2.3', 'v1.2', 'v1.2.3-beta', 'v1.100.0', 'v1.2.100', 'v01.2.3', 'v0.0.0', 'v1.2.3 '):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release_version.parse(tag)

    def test_previous_tag_must_be_older(self):
        self.assertEqual(quiet(release_version.main, ['--tag', 'v1.2.4', '--previous-tag', 'v1.2.3'])[0], 0)
        self.assertEqual(quiet(release_version.main, ['--tag', 'v1.2.3', '--previous-tag', 'v1.2.3'])[0], 1)

    def test_pubspec(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'pubspec.yaml'
            path.write_text('name: x\nversion: 0.4.1+7\n')
            self.assertEqual(release_version.from_pubspec(path), ('0.4.1', 7))


class DefinesTest(unittest.TestCase):
    def test_project_required_for_release(self):
        with self.assertRaises(ValueError):
            google_defines.defines({}, allow_placeholder=False)
        self.assertEqual(google_defines.defines({}, True)['ANTIRKN_GOOGLE_PROJECT_ID'], google_defines.PLACEHOLDER)

    def test_only_public_keys(self):
        values = google_defines.defines({'ANTIRKN_GOOGLE_PROJECT_ID': 'antirkn-prod', 'ANTIRKN_GOOGLE_PICKER_APP_ID': '123',
                                         'ANTIRKN_GOOGLE_CLIENT_SECRET': 'x'}, False)
        self.assertEqual(sorted(values), ['ANTIRKN_GOOGLE_PICKER_APP_ID', 'ANTIRKN_GOOGLE_PROJECT_ID'])
        with self.assertRaises(ValueError):
            google_defines.defines({'ANTIRKN_GOOGLE_PROJECT_ID': 'Bad_ID'}, False)


class ChangelogTest(unittest.TestCase):
    TEXT = '# Changelog\n\n## [Unreleased]\n\n## [1.2.0] - 2026-11-27\n\n### Added\n- Updates.\n\n## [1.1.0] - 2026-10-01\n- Old.\n'

    def write(self, directory, english=TEXT, russian=TEXT):
        (directory / 'CHANGELOG.md').write_text(english, encoding='utf-8')
        (directory / 'CHANGELOG.ru.md').write_text(russian, encoding='utf-8')

    def test_sections(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write(directory)
            self.assertEqual(changelog_check.check(directory, '1.2.0', False), [])
            self.assertEqual(changelog_check.check(directory, 'Unreleased', True), [])
            self.assertTrue(changelog_check.check(directory, '1.3.0', False))
            self.assertTrue(changelog_check.check(directory, 'Unreleased', False))
            self.write(directory, russian='## [Unreleased]\n')
            self.assertEqual(len(changelog_check.check(directory, '1.2.0', False)), 1)
            code, output = quiet(changelog_check.main, ['--version', '1.2.0', '--dir', temporary])
            self.assertEqual(code, 1)
            self.assertIn('::error::CHANGELOG.ru.md', output)
            self.assertEqual(quiet(changelog_check.main, ['--version', '9.9.9', '--soft', '--dir', temporary])[0], 0)


def fake_bundle(directory, executable):
    (directory / 'lib').mkdir(parents=True)
    (directory / 'data/flutter_assets').mkdir(parents=True)
    (directory / executable).write_bytes(b'\x7fELF fake')
    os.chmod(str(directory / executable), 0o755)
    (directory / 'lib/antirkn-mihomo').write_bytes(b'core')
    os.chmod(str(directory / 'lib/antirkn-mihomo'), 0o755)
    (directory / 'data/flutter_assets/AssetManifest.bin').write_bytes(b'assets')
    return directory


class PackageTest(unittest.TestCase):
    def test_tarball_layout_marker_and_reproducibility(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = fake_bundle(Path(temporary) / 'bundle', 'antirkn_manager')
            first = package.tarball(bundle, '1.2.0', Path(temporary) / 'a', 1700000000)
            second = package.tarball(bundle, '1.2.0', Path(temporary) / 'b', 1700000000)
            self.assertEqual(first.name, 'AntiRKN-v1.2.0-linux-x64.tar.gz')
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with tarfile.open(str(first)) as archive:
                top = 'AntiRKN-v1.2.0-linux-x64'
                self.assertEqual(archive.extractfile(top + '/install-kind').read(), b'linux-tarball\n')
                self.assertEqual(archive.getmember(top + '/antirkn_manager').mode, 0o755)
                self.assertEqual(archive.getmember(top + '/lib/antirkn-mihomo').mode, 0o755)
                for name in ('LICENSE', 'DISCLAIMER.md'):
                    self.assertEqual(archive.extractfile(top + '/' + name).read(), (package.ROOT / name).read_bytes())
                self.assertTrue(all(name == top or name.startswith(top + '/') for name in archive.getnames()))

    def test_portable_zip(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = fake_bundle(Path(temporary) / 'bundle', 'antirkn_manager.exe')
            target = package.portable(bundle, '1.2.0', Path(temporary) / 'out', 1700000000)
            self.assertEqual(target.name, 'AntiRKN-v1.2.0-windows-x64-portable.zip')
            with zipfile.ZipFile(str(target)) as archive:
                top = 'AntiRKN-v1.2.0-windows-x64-portable/'
                self.assertEqual(archive.read(top + 'install-kind'), b'windows-portable\n')
                self.assertIn(top + 'antirkn_manager.exe', archive.namelist())
                self.assertIn(top + 'LICENSE', archive.namelist())
                self.assertIn(top + 'DISCLAIMER.md', archive.namelist())

    def test_appdir(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = fake_bundle(Path(temporary) / 'bundle', 'antirkn_manager')
            appdir = package.appdir(bundle, Path(temporary) / 'AppDir')
            self.assertEqual((appdir / 'install-kind').read_text(), 'linux-appimage\n')
            self.assertTrue(os.access(str(appdir / 'AppRun'), os.X_OK))
            desktop = (appdir / 'org.antirkn.antirkn_manager.desktop').read_text()
            self.assertIn('Exec=antirkn_manager', desktop)
            self.assertIn('Icon=org.antirkn.antirkn_manager', desktop)
            self.assertTrue((appdir / 'org.antirkn.antirkn_manager.png').is_file())
            self.assertTrue((appdir / 'LICENSE').is_file())
            self.assertTrue((appdir / 'DISCLAIMER.md').is_file())

    def test_rejects_existing_marker_and_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = fake_bundle(Path(temporary) / 'bundle', 'antirkn_manager')
            (bundle / 'install-kind').write_text('linux-tarball\n')
            with self.assertRaises(ValueError):
                package.tarball(bundle, '1.2.0', Path(temporary) / 'out', 0)
            (bundle / 'install-kind').unlink()
            os.symlink('/etc/passwd', str(bundle / 'lib/link'))
            with self.assertRaises(ValueError):
                package.tarball(bundle, '1.2.0', Path(temporary) / 'out', 0)

    def test_installer_marker_and_script(self):
        self.assertEqual((ROOT / 'packaging/windows/install-kind').read_text(), 'windows-installer\n')
        script = (ROOT / 'packaging/windows/antirkn.iss').read_text(encoding='utf-8')
        for line in ('PrivilegesRequired=lowest', 'AppId={{F122C408-92CD-4DEA-895B-655A4CDABC33}',
                     'CloseApplications=yes', 'AppMutex=', 'OutputBaseFilename=AntiRKN-v{#AppVersion}-windows-x64-setup'):
            self.assertIn(line, script)
        self.assertNotIn('[UninstallDelete]\n', script)
        self.assertNotIn('{userappdata}', script)


def sha(data):
    return hashlib.sha256(data).hexdigest()


class AssetsTest(unittest.TestCase):
    TAG, COMMIT, BUILD = 'v1.2.0', 'a' * 40, 10200
    CERT = 'b' * 64

    def fixture(self, directory):
        version = self.TAG[1:]
        names = release_assets.expected(version)
        meta = {'version': version, 'build': self.BUILD, 'certSha256': self.CERT, 'apks': {}}
        artifacts = []
        for name, (kind, arch) in sorted(names.items()):
            data = name.encode()
            (directory / name).write_bytes(data)
            item = {'kind': kind, 'arch': arch, 'fileName': name, 'size': len(data), 'sha256': sha(data),
                    'url': 'https://github.com/CyberCat2033/AntiRKN/releases/download/%s/%s' % (self.TAG, name)}
            if kind == 'android-apk':
                code = android_release.expected_code(arch, self.BUILD)
                meta['apks'][name] = {'arch': arch, 'versionCode': code}
                item.update(versionCode=code, certSha256=self.CERT)
            artifacts.append(item)
        payload = {'schemaVersion': 1, 'appId': 'org.antirkn.manager', 'channel': 'stable', 'version': version,
                   'build': self.BUILD, 'tag': self.TAG, 'commit': self.COMMIT, 'minSupportedBuild': 1,
                   'releasedAt': '2026-11-27T00:00:00Z', 'notesUrl': 'https://github.com/x', 'artifacts': artifacts}
        return payload, meta

    def run_check(self, directory, payload, meta, manifest=None):
        work = directory.parent
        (work / 'payload.json').write_text(json.dumps(payload))
        (work / 'meta.json').write_text(json.dumps(meta))
        return release_assets.check(work / 'payload.json', directory, work / 'meta.json',
                                    self.TAG, self.COMMIT, self.BUILD, manifest)

    def test_check_accepts_consistent_payload_and_envelope(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / 'dist'
            directory.mkdir()
            payload, meta = self.fixture(directory)
            raw = json.dumps(payload).encode()
            envelope = Path(temporary) / 'app-update-stable.json'
            envelope.write_text(json.dumps({'format': 'antirkn-app-update', 'signatures': [{'keyId': 'k1', 'sig': 'x'}],
                                            'payload': base64.urlsafe_b64encode(raw).decode().rstrip('=')}))
            self.run_check(directory, payload, meta, envelope)
            lines = release_assets.sums(directory, '1.2.0', [])
            self.assertEqual(len(lines), 8)

    def test_check_rejects_mismatches(self):
        mutations = [
            lambda p, m: p['artifacts'][0].update(sha256='0' * 64),
            lambda p, m: p['artifacts'][0].update(url='https://example.com/x'),
            lambda p, m: p['artifacts'].pop(),
            lambda p, m: p.update(build=1),
            lambda p, m: p.update(commit='c' * 40),
            lambda p, m: [a.update(versionCode=1) for a in p['artifacts'] if a['kind'] == 'android-apk'],
            lambda p, m: [a.update(certSha256='c' * 64) for a in p['artifacts'] if a['kind'] == 'android-apk'],
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary) / 'dist'
                directory.mkdir()
                payload, meta = self.fixture(directory)
                mutate(payload, meta)
                with self.assertRaises(release_assets.AssetError):
                    self.run_check(directory, payload, meta)

    def test_uploaded(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / 'dist'
            directory.mkdir()
            (directory / 'a.apk').write_bytes(b'apk')
            assets = Path(temporary) / 'assets.jsonl'
            assets.write_text(json.dumps({'name': 'a.apk', 'size': 3, 'state': 'uploaded', 'digest': 'sha256:' + sha(b'apk')}) + '\n')
            release_assets.uploaded(directory, assets)
            assets.write_text(json.dumps({'name': 'a.apk', 'size': 3, 'state': 'uploaded', 'digest': 'sha256:' + '0' * 64}) + '\n')
            with self.assertRaises(release_assets.AssetError):
                release_assets.uploaded(directory, assets)


class AndroidTest(unittest.TestCase):
    def test_version_codes(self):
        self.assertEqual(android_release.expected_code('universal', 10200), 102000)
        self.assertEqual(android_release.expected_code('armeabi-v7a', 10200), 102001)
        self.assertEqual(android_release.expected_code('arm64-v8a', 10200), 102002)
        self.assertEqual(android_release.expected_code('x86_64', 10200), 102003)
        # Every variant of the next build outranks every variant of this one.
        self.assertGreater(android_release.expected_code('universal', 10201),
                           android_release.expected_code('x86_64', 10200))
        top = release_version.MAX_BUILD
        self.assertLess(android_release.expected_code('x86_64', top), 2_100_000_000)
        with self.assertRaises(android_release.ReleaseError):
            android_release.expected_code('x86_64', top + 1)

    def test_largest_tag_fits(self):
        with self.assertRaises(ValueError):
            release_version.parse('v21000.0.0')
        version, build = release_version.parse('v20999.99.99')
        self.assertLess(android_release.expected_code('x86_64', build), 2_100_000_000)

    def manifest(self, directory, build, codes, cert='b' * 64):
        payload = {'build': build, 'artifacts': [{'kind': 'android-apk', 'arch': arch, 'versionCode': code, 'certSha256': cert}
                                                 for arch, code in codes.items()]}
        path = directory / 'previous.json'
        path.write_text(json.dumps({'format': 'antirkn-app-update', 'signatures': [],
                                    'payload': base64.urlsafe_b64encode(json.dumps(payload).encode()).decode()}))
        return path

    def test_previous(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            meta = directory / 'meta.json'
            meta.write_text(json.dumps({'build': 10200, 'certSha256': 'b' * 64, 'apks': {
                'u.apk': {'arch': 'universal', 'versionCode': 102000},
                'a.apk': {'arch': 'arm64-v8a', 'versionCode': 102002}}}))
            android_release.previous(meta, None)
            android_release.previous(meta, self.manifest(directory, 10100, {'universal': 101000, 'x86_64': 101003}))
            cases = ((10200, {'arm64-v8a': 101002}, 'b' * 64),     # build not greater
                     (10100, {'x86_64': 102001}, 'b' * 64),        # universal below the old maximum
                     (10100, {'arm64-v8a': 101002}, 'c' * 64))     # certificate changed
            for build, codes, cert in cases:
                with self.subTest(build=build, codes=codes), self.assertRaises(android_release.ReleaseError):
                    android_release.previous(meta, self.manifest(directory, build, codes, cert))

    def test_sign_requires_environment_without_echoing_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(android_release.ReleaseError) as raised:
                android_release.sign(Path(temporary), Path(temporary) / 'out', 'b' * 64, Path(temporary),
                                     {'ANTIRKN_ANDROID_KEYSTORE_PASSWORD': 'hunter2'})
            self.assertNotIn('hunter2', str(raised.exception))

    def test_digest_normalization(self):
        self.assertEqual(android_release.normalize_digest(':'.join(['AB'] * 32)), 'ab' * 32)
        with self.assertRaises(android_release.ReleaseError):
            android_release.normalize_digest('abc')


class FetchTest(unittest.TestCase):
    def test_hash_mismatch_is_rejected(self):
        class Response(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *args):
                self.close()

        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / 'tool'
            with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(ValueError):
                fetch_tool.fetch('appimagetool', target, opener=lambda url, timeout: Response(b'evil'))
            self.assertFalse(target.exists())
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_pins_are_https_and_sha256(self):
        for name, (url, digest) in fetch_tool.PINS.items():
            self.assertTrue(url.startswith('https://github.com/'), name)
            self.assertRegex(digest, r'^[0-9a-f]{64}$')


if __name__ == '__main__':
    unittest.main()
