#!/usr/bin/env python3
"""Cut a release: `tool/release.py X.Y.Z [--push]`.

Moves the `## [Unreleased]` notes of CHANGELOG.md and CHANGELOG.ru.md into
`## [X.Y.Z] - <date>`, sets `version: X.Y.Z+<build>` in the app pubspec,
commits `release: vX.Y.Z` and creates the annotated tag. With --push the
branch and the tag go to origin; the tag starts .github/workflows/release.yml.

Refuses a dirty tree, a branch other than the default one, a version not
above the last tag, and empty notes in either language.
"""
import argparse
import datetime
import importlib.util
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
PUBSPEC = 'apps/manager/pubspec.yaml'
DEFAULT_BRANCH = 'master'


def _load(name):
    spec = importlib.util.spec_from_file_location('ci_' + name, ROOT / 'tool/ci' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


changelog_check = _load('changelog_check')
release_version = _load('release_version')
HEADING = changelog_check.HEADING


class ReleaseError(Exception):
    pass


def cut_changelog(text, version, date):
    """Return `text` with the [Unreleased] body moved under `## [version] - date`."""
    if changelog_check.section(text, version) is not None:
        raise ReleaseError('already has a "## [%s]" section' % version)
    body = changelog_check.section(text, 'Unreleased')
    if body is None:
        raise ReleaseError('has no "## [Unreleased]" section')
    if not any(line.lstrip().startswith(('-', '*')) for line in body):
        raise ReleaseError('has no notes under "## [Unreleased]"')
    lines = text.split('\n')
    start = next(i for i, line in enumerate(lines)
                 if HEADING.match(line) and HEADING.match(line).group(1).strip().lower() == 'unreleased')
    end = next((i for i in range(start + 1, len(lines)) if HEADING.match(lines[i])), len(lines))
    notes = lines[start + 1:end]
    while notes and not notes[-1].strip():
        notes.pop()
    while notes and not notes[0].strip():
        notes.pop(0)
    rest = lines[end:]
    released = ['## [Unreleased]', '', '## [%s] - %s' % (version, date), ''] + notes
    return '\n'.join(lines[:start] + released + ([''] + rest if rest else ['']))


def set_pubspec_version(text, version, build):
    updated, count = re.subn(r'(?m)^version:\s*\S+\s*$', 'version: %s+%d' % (version, build), text)
    if count != 1:
        raise ReleaseError('%s has no single "version:" line' % PUBSPEC)
    return updated


def _git(*args):
    return subprocess.run(('git',) + args, cwd=str(ROOT), check=True, timeout=120,
                          stdout=subprocess.PIPE).stdout.decode().strip()


def last_tag_build():
    builds = []
    for tag in _git('tag', '--list', 'v*').splitlines():
        try:
            builds.append(release_version.parse(tag)[1])
        except ValueError:
            continue
    return max(builds, default=0)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('version', help='X.Y.Z')
    parser.add_argument('--date', default=datetime.date.today().isoformat())
    parser.add_argument('--push', action='store_true', help='push the branch and the tag to origin')
    options = parser.parse_args(argv)
    try:
        version, build = release_version.parse('v' + options.version)
        tag = 'v' + version
        if _git('status', '--porcelain'):
            raise ReleaseError('the working tree has uncommitted changes')
        branch = _git('rev-parse', '--abbrev-ref', 'HEAD')
        if branch != DEFAULT_BRANCH:
            raise ReleaseError('releases are cut on %s, not %s' % (DEFAULT_BRANCH, branch))
        if build <= last_tag_build():
            raise ReleaseError('%s is not above the last release tag' % tag)
        changed = {}
        for name in changelog_check.FILES:
            try:
                changed[name] = cut_changelog((ROOT / name).read_text(encoding='utf-8'), version, options.date)
            except ReleaseError as error:
                raise ReleaseError('%s %s' % (name, error))
        changed[PUBSPEC] = set_pubspec_version((ROOT / PUBSPEC).read_text(encoding='utf-8'), version, build)
        for name, text in changed.items():
            (ROOT / name).write_text(text, encoding='utf-8')
        _git('add', '--', *changed)
        _git('commit', '-q', '-m', 'release: %s' % tag)
        _git('tag', '-a', tag, '-m', 'AntiRKN %s' % tag)
        if options.push:
            _git('push', '-q', 'origin', branch)
            _git('push', '-q', 'origin', tag)
            print('release: pushed %s; approve the `release` environment in GitHub Actions' % tag)
        else:
            print('release: %s committed and tagged; push with: git push origin %s %s' % (tag, branch, tag))
        return 0
    except (ReleaseError, ValueError) as error:
        print('release: %s' % error, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
