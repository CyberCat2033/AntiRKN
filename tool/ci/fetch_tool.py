#!/usr/bin/env python3
"""Download a pinned packaging tool and verify its SHA-256 before use.

Pins are the single source for CI; bump URL and hash together after checking
the upstream release page.
"""
import argparse
import hashlib
import os
from pathlib import Path
import sys
import tempfile
import urllib.request

PINS = {
    # https://github.com/AppImage/appimagetool/releases/tag/1.9.1
    'appimagetool': (
        'https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage',
        'ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0'),
    # https://github.com/AppImage/type2-runtime/releases/tag/20251108
    'appimage-runtime': (
        'https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64',
        '2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d'),
    # https://github.com/jrsoftware/issrc/releases/tag/is-6_7_4
    'innosetup': (
        'https://github.com/jrsoftware/issrc/releases/download/is-6_7_4/innosetup-6.7.4.exe',
        'a549929319f9120716677c685535ca4671e4b937b5fdc87e2585f32d8eb30e8c'),
}
LIMIT = 256 * 1024 * 1024


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as source:
        for chunk in iter(lambda: source.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def fetch(name, destination, opener=urllib.request.urlopen):
    url, expected = PINS[name]
    if destination.exists() and sha256(destination) == expected:
        print('fetch_tool: %s cached' % name)
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=str(destination.parent), prefix='.fetch-')
    try:
        received = 0
        with os.fdopen(handle, 'wb') as output, opener(url, timeout=120) as response:
            for chunk in iter(lambda: response.read(1 << 20), b''):
                received += len(chunk)
                if received > LIMIT:
                    raise ValueError('download exceeds size limit')
                output.write(chunk)
        actual = sha256(temporary)
        if actual != expected:
            raise ValueError('SHA-256 mismatch for %s' % name)
        os.chmod(temporary, 0o755)
        os.replace(temporary, str(destination))
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print('fetch_tool: %s verified' % name)
    return destination


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name', choices=sorted(PINS))
    parser.add_argument('--out', type=Path, required=True)
    options = parser.parse_args(argv)
    try:
        fetch(options.name, options.out)
    except ValueError as error:
        print('::error::fetch_tool: %s' % error)
        return 1
    except OSError as error:
        print('::error::fetch_tool: %s: %s' % (options.name, type(error).__name__))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
