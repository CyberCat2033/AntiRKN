#!/usr/bin/env bash
# Print the NDK version the pinned Flutter SDK uses for flutter.ndkVersion,
# so CI installs exactly the NDK whose clang tool/build_mihomo.py calls.
set -euo pipefail
flutter_bin="$(command -v flutter)"
root="$(cd "$(dirname "$(readlink -f "$flutter_bin")")/.." && pwd)"
source="$root/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt"
version="$(sed -n 's/.*val ndkVersion: String = "\([0-9.]*\)".*/\1/p' "$source" | head -n 1)"
if [ -z "$version" ]; then
  echo "::error::cannot read ndkVersion from $source" >&2
  exit 1
fi
printf '%s\n' "$version"
