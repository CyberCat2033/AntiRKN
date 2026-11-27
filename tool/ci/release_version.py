#!/usr/bin/env python3
"""Release tag -> version and monotonic build number (see docs/release-ci.md).

build = X*10000 + Y*100 + Z with Y, Z < 100. Only strict stable tags vX.Y.Z
are accepted. Outputs go to $GITHUB_OUTPUT when it is set, else to stdout.
"""
import argparse
import os
from pathlib import Path
import re
import sys

TAG = re.compile(r'^v(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)$')
# Android versionCode = build * 10 + ABI id (0..3) must stay below 2100000000.
MAX_BUILD = 209_999_999


def parse(tag):
    match = TAG.match(tag or '')
    if not match:
        raise ValueError('tag must be vX.Y.Z with X < 100000 and Y, Z < 100')
    major, minor, patch = (int(part) for part in match.groups())
    build = major * 10000 + minor * 100 + patch
    if build < 1 or build > MAX_BUILD:
        raise ValueError('build number out of range')
    return '%d.%d.%d' % (major, minor, patch), build


def from_pubspec(path):
    """Check builds use the pubspec version: `version: X.Y.Z+N`."""
    for line in path.read_text(encoding='utf-8').splitlines():
        match = re.match(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$', line)
        if match:
            return match.group(1), int(match.group(2))
    raise ValueError('pubspec has no version X.Y.Z+N')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--tag')
    source.add_argument('--pubspec', type=Path)
    parser.add_argument('--previous-tag', default='',
                        help='latest published release tag; the new build must be greater')
    options = parser.parse_args(argv)
    try:
        if options.pubspec:
            version, build = from_pubspec(options.pubspec)
            options.tag = 'v' + version
        else:
            version, build = parse(options.tag)
        if options.previous_tag:
            _, previous = parse(options.previous_tag)
            if build <= previous:
                raise ValueError('build %d is not greater than the previous release build %d' % (build, previous))
    except ValueError as error:
        print('::error::release_version: %s' % error)
        return 1
    lines = ['version=%s' % version, 'build=%d' % build, 'tag=%s' % options.tag]
    target = os.environ.get('GITHUB_OUTPUT')
    if target:
        with open(target, 'a', encoding='utf-8') as output:
            output.write('\n'.join(lines) + '\n')
    print('\n'.join(lines))
    return 0


if __name__ == '__main__':
    sys.exit(main())
