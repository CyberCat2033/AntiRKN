#!/usr/bin/env python3
"""Write the public Google build defines JSON for --dart-define-from-file.

Only public identifiers are accepted (Project ID, Picker API key and app ID).
The Desktop OAuth client JSON is loaded at runtime and never baked into builds.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sys

PROJECT_ID = re.compile(r'^[a-z][a-z0-9-]{4,61}[a-z0-9]$')
# Fork pull requests do not receive repository variables; check builds then
# use this syntactically valid placeholder. Release builds never do.
PLACEHOLDER = 'antirkn-ci-placeholder'
OPTIONAL = ('ANTIRKN_GOOGLE_PICKER_API_KEY', 'ANTIRKN_GOOGLE_PICKER_APP_ID')


def defines(environ, allow_placeholder):
    project = environ.get('ANTIRKN_GOOGLE_PROJECT_ID', '').strip()
    if not project and allow_placeholder:
        project = PLACEHOLDER
    if not PROJECT_ID.match(project):
        raise ValueError('ANTIRKN_GOOGLE_PROJECT_ID is missing or invalid')
    result = {'ANTIRKN_GOOGLE_PROJECT_ID': project}
    for name in OPTIONAL:
        value = environ.get(name, '').strip()
        if value:
            if not re.match(r'^[A-Za-z0-9_-]{1,200}$', value):
                raise ValueError('%s has unexpected characters' % name)
            result[name] = value
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--allow-placeholder', action='store_true')
    options = parser.parse_args(argv)
    try:
        values = defines(os.environ, options.allow_placeholder)
    except ValueError as error:
        print('::error::google_defines: %s' % error)
        return 1
    options.out.parent.mkdir(parents=True, exist_ok=True)
    options.out.write_text(json.dumps(values, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    print('google_defines: wrote %s (%s)' % (options.out, ', '.join(sorted(values))))
    return 0


if __name__ == '__main__':
    sys.exit(main())
