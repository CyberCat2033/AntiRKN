#!/usr/bin/env python3
"""Cheap presence check of CHANGELOG.md and CHANGELOG.ru.md sections.

Only answers "is there a non-empty `## [X.Y.Z]` (or `## [Unreleased]`)
section". Parsing the notes for the release body and the signed manifest is
done once, by `dart run tool/app_update_manifest.dart release-notes`.
Prints GitHub `::error::`/`::warning::` annotations.
"""
import argparse
from pathlib import Path
import re
import sys

FILES = ('CHANGELOG.md', 'CHANGELOG.ru.md')
HEADING = re.compile(r'^##\s+\[([^\]]+)\]')


def section(text, name):
    """Return the body lines of `## [name]` or None when the heading is absent."""
    body, found = [], False
    for line in text.splitlines():
        match = HEADING.match(line)
        if match:
            if found:
                break
            found = match.group(1).strip().lower() == name.lower()
            continue
        if found:
            body.append(line)
    if not found:
        return None
    return [line for line in body if line.strip() and not line.lstrip().startswith('<!--')]


def check(directory, name, allow_empty):
    problems = []
    for file_name in FILES:
        path = directory / file_name
        if not path.is_file():
            problems.append('%s is missing' % file_name)
            continue
        body = section(path.read_text(encoding='utf-8'), name)
        if body is None:
            problems.append('%s has no "## [%s]" section' % (file_name, name))
        elif not body and not allow_empty:
            problems.append('%s section "## [%s]" is empty' % (file_name, name))
    return problems


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--version', help='X.Y.Z of the release being tagged')
    group.add_argument('--unreleased', action='store_true', help='check that [Unreleased] exists')
    parser.add_argument('--dir', type=Path, default=Path('.'))
    parser.add_argument('--soft', action='store_true', help='report warnings, exit 0')
    options = parser.parse_args(argv)
    name = 'Unreleased' if options.unreleased else options.version
    problems = check(options.dir, name, allow_empty=options.unreleased)
    level = 'warning' if options.soft else 'error'
    for problem in problems:
        print('::%s::%s' % (level, problem))
    if problems and not options.soft:
        if not options.unreleased:
            print('Move the [Unreleased] notes to "## [%s] - YYYY-MM-DD" in both changelog files, '
                  'commit, then tag again (see docs/release-ci.md).' % name, file=sys.stderr)
        return 1
    if not problems:
        print('changelog: "## [%s]" present in %s' % (name, ', '.join(FILES)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
