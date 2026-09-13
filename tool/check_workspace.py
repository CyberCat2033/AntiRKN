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
    'domain': set(),
    'network_inventory': {'antirkn_domain'},
    'profile_compiler': {'antirkn_domain', 'crypto', 'yaml', 'yaml_edit'},
    'design_system': {'flutter'},
    'storage': {'antirkn_domain', 'shared_preferences', 'file_selector', 'flutter', 'cryptography', 'flutter_secure_storage', 'path_provider'},
    'ssh_transport': {'antirkn_domain', 'antirkn_network_inventory', 'dartssh2'},
}
for package, dependencies in allowed.items():
    for path in (ROOT / 'packages' / package / 'lib').rglob('*.dart'):
        for target in re.findall(r"(?:import|export)\s+['\"]([^'\"]+)['\"]", path.read_text()):
            if target.startswith('package:') and target[8:].split('/')[0] not in dependencies:
                errors.append(f'{path.relative_to(ROOT)}: forbidden dependency {target}')
            if package in {'domain', 'profile_compiler', 'network_inventory'} and target in {'dart:io', 'dart:ui'}:
                errors.append(f'{path.relative_to(ROOT)}: domain layer cannot import {target}')

for error in errors:
    print(error, file=sys.stderr)
if errors:
    sys.exit(1)
print(f'Architecture boundaries, base.yml SHA-256 and {len(keys(catalogs["en"]))} RU/EN messages: OK')
