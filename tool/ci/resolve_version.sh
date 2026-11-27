#!/usr/bin/env bash
# Version for a CI build: INPUT_VERSION/INPUT_BUILD from release.yml (already
# validated by release_version.py), otherwise the pubspec version for checks.
# Writes version= and build= to $GITHUB_OUTPUT (or stdout locally).
set -euo pipefail
cd "$(dirname "$0")/../.."
python_bin="$(command -v python3 || command -v python)"
version="${INPUT_VERSION:-}"
build="${INPUT_BUILD:-}"
if [ -z "$version" ]; then
  out="$("$python_bin" tool/ci/release_version.py --pubspec apps/manager/pubspec.yaml)"
  version="$(printf '%s\n' "$out" | sed -n 's/^version=//p')"
  build="$(printf '%s\n' "$out" | sed -n 's/^build=//p')"
fi
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::invalid build version '$version' / build '$build'"
  exit 1
fi
printf 'version=%s\nbuild=%s\n' "$version" "$build" >> "${GITHUB_OUTPUT:-/dev/stdout}"
