#!/usr/bin/env bash
# Installs the pinned Flutter SDK from its git tag and checks the commit.
# Replaces subosito/flutter-action: its composite steps reference
# actions/cache by tag, which the repository's SHA-pinning policy rejects.
# Usage: tool/ci/setup_flutter.sh <version> <commit>
set -euo pipefail
version="${1:?version}"
commit="${2:?commit}"
dest="${RUNNER_TOOL_CACHE:-$HOME}/flutter-$version"
if [ ! -x "$dest/bin/flutter" ]; then
  git clone --quiet --depth 1 --branch "$version" \
    https://github.com/flutter/flutter.git "$dest"
fi
actual="$(git -C "$dest" rev-parse HEAD)"
if [ "$actual" != "$commit" ]; then
  echo "::error::Flutter $version is at $actual, expected $commit"
  exit 1
fi
echo "$dest/bin" >> "$GITHUB_PATH"
"$dest/bin/flutter" config --no-analytics --no-cli-animations >/dev/null
"$dest/bin/flutter" --version
