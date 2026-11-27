#!/usr/bin/env python3
"""Fast architecture, source integrity and localization checks; no network."""
from pathlib import Path
import hashlib
import json
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
errors = []
expected_base = 'f20fc58fce6c4bb1a53d82a2070ad3d4aea2e663d0c1489af23e5b5aa8495ce4'
if hashlib.sha256((ROOT / 'base.yml').read_bytes()).hexdigest() != expected_base:
    errors.append('base.yml changed: review the source-template policy and fixture baseline')

# A runner source edit changes its release hash. Require an explicit version
# bump and a reviewed release lock instead of silently shipping a second build
# under the same server directory name.
runner_lock = json.loads((ROOT / 'schemas/runner-release-lock.json').read_text())
runner_unit = (ROOT / 'server/runner/antirkn-runner.service').read_text()
runner_version = re.search(r'/antirkn-runner/v(\d+)/runner\.py daemon', runner_unit)
if runner_version is None or int(runner_version.group(1)) != runner_lock['version']:
    errors.append('runner service version differs from the release lock')
runner_hashes = {
    name: hashlib.sha256((ROOT / 'server/runner' / name).read_bytes()).hexdigest()
    for name in runner_lock['hashes']
}
runner_release = hashlib.sha256(json.dumps(runner_hashes, sort_keys=True).encode()).hexdigest()
if runner_hashes != runner_lock['hashes'] or runner_release != runner_lock['release']:
    errors.append('runner source differs from the release lock: bump its version and register the predecessor')
runner_bundle = (ROOT / 'packages/ssh_transport/lib/src/runner_bundle.g.dart').read_text()
if f"const runnerRelease =\n    '{runner_lock['release']}';" not in runner_bundle:
    errors.append('bundled runner release differs from the release lock')

arb_root = ROOT / 'apps/manager/lib/l10n'
catalogs = {lang: json.loads((arb_root / f'app_{lang}.arb').read_text()) for lang in ['en', 'ru']}
keys = lambda c: {k for k in c if not k.startswith('@')}
if keys(catalogs['en']) != keys(catalogs['ru']):
    errors.append('RU/EN localization keys differ')
for key in keys(catalogs['en']) & keys(catalogs['ru']):
    for lang in catalogs:
        if not isinstance(catalogs[lang][key], str) or not catalogs[lang][key].strip():
            errors.append(f'{lang}: empty or invalid translation for {key}')
    placeholders = lambda text: set(re.findall(r'\{(\w+)\}', text))
    if placeholders(catalogs['en'][key]) != placeholders(catalogs['ru'][key]):
        errors.append(f'Translation placeholders differ: {key}')

allowed = {
    'mihomo_runtime': {'antirkn_domain', 'flutter', 'crypto', 'yaml', 'path_provider'},
    'domain': set(),
    'network_inventory': {'antirkn_domain'},
    'profile_compiler': {'antirkn_domain', 'crypto', 'yaml', 'yaml_edit'},
    'design_system': {'flutter', 'animations'},
    'storage': {'antirkn_domain', 'antirkn_integrations', 'shared_preferences', 'file_selector', 'url_launcher', 'flutter', 'cryptography', 'flutter_secure_storage', 'path_provider', 'sqlite3', 'sqlite3_flutter_libs'},
    'integrations': {'antirkn_domain', 'cryptography'},
    'sync': {'antirkn_domain', 'cryptography'},
    'app_update': {'antirkn_domain', 'cryptography'},
    'ssh_transport': {'antirkn_domain', 'antirkn_network_inventory', 'dartssh2'},
}
for package, dependencies in allowed.items():
    for path in (ROOT / 'packages' / package / 'lib').rglob('*.dart'):
        for target in re.findall(r"(?:import|export)\s+['\"]([^'\"]+)['\"]", path.read_text()):
            if target.startswith('package:') and target[8:].split('/')[0] not in dependencies:
                errors.append(f'{path.relative_to(ROOT)}: forbidden dependency {target}')
            if package in {'domain', 'profile_compiler', 'network_inventory', 'sync'} and target in {'dart:io', 'dart:ui'}:
                errors.append(f'{path.relative_to(ROOT)}: domain layer cannot import {target}')

for error in errors:
    print(error, file=sys.stderr)
if errors:
    sys.exit(1)
print(f'Architecture boundaries, base.yml SHA-256 and {len(keys(catalogs["en"]))} RU/EN messages: OK')
