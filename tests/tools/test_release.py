import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release_tool', ROOT / 'tool/release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

CHANGELOG = """# Changelog

Intro.

## [Unreleased]

### Added

- Signed app updates.

## [0.1.0] - 2026-11-27

### Added

- First release.
"""


class CutChangelogTests(unittest.TestCase):
    def test_unreleased_notes_move_under_the_version(self):
        text = release.cut_changelog(CHANGELOG, '0.1.1', '2026-11-28')
        self.assertIn('## [Unreleased]\n\n## [0.1.1] - 2026-11-28\n\n### Added\n\n- Signed app updates.\n\n## [0.1.0]', text)
        self.assertEqual(release.changelog_check.section(text, 'Unreleased'), [])
        self.assertEqual(release.changelog_check.section(text, '0.1.1'), ['### Added', '- Signed app updates.'])
        self.assertTrue(text.endswith('- First release.\n'))

    def test_unreleased_as_the_last_section(self):
        text = release.cut_changelog('# C\n\n## [Unreleased]\n\n- Only.\n', '1.0.0', '2026-01-02')
        self.assertEqual(text, '# C\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-02\n\n- Only.\n')

    def test_refusals(self):
        empty = CHANGELOG.replace('### Added\n\n- Signed app updates.\n\n', '')
        for text, version in ((empty, '0.1.1'), (CHANGELOG, '0.1.0'), ('# C\n\n## [0.1.0]\n\n- x\n', '0.2.0')):
            with self.assertRaises(release.ReleaseError):
                release.cut_changelog(text, version, '2026-11-28')

    def test_pubspec_version_and_build(self):
        text = 'name: app\nversion: 0.1.0+1\nenvironment:\n'
        self.assertEqual(release.set_pubspec_version(text, '0.1.1', 101),
                         'name: app\nversion: 0.1.1+101\nenvironment:\n')
        with self.assertRaises(release.ReleaseError):
            release.set_pubspec_version('name: app\n', '0.1.1', 101)


if __name__ == '__main__':
    unittest.main()
