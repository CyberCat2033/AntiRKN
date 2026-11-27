#!/usr/bin/env bash
# Package a Flutter Linux bundle into the release tarball and AppImage.
#   tool/ci/package_linux.sh <bundle> <version> <out-dir> <work-dir>
# Set SKIP_APPIMAGE=1 to build only the tarball and AppDir (local dry run).
set -euo pipefail
if [ "$#" -ne 4 ]; then
  echo "usage: $0 <bundle> <version> <out-dir> <work-dir>" >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/../.." && pwd)"
bundle="$1"; version="$2"; out="$3"; work="$4"
mkdir -p "$out" "$work"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$root" log -1 --format=%ct)}"

python3 "$root/tool/ci/package.py" tarball --bundle "$bundle" --version "$version" --out "$out"
appdir="$work/AntiRKN.AppDir"
if [ -e "$appdir" ]; then
  echo "::error::$appdir already exists; use a fresh work directory"
  exit 1
fi
python3 "$root/tool/ci/package.py" appdir --bundle "$bundle" --out "$appdir"

tarball="$out/$(python3 "$root/tool/ci/package.py" name --version "$version" --kind linux-tarball)"
top="AntiRKN-v$version-linux-x64"
tar -tzf "$tarball" | grep -qx "$top/install-kind" || { echo "::error::tarball has no install-kind"; exit 1; }
tar -tzf "$tarball" | grep -qx "$top/lib/antirkn-mihomo" || { echo "::error::tarball has no Mihomo core"; exit 1; }

if [ "${SKIP_APPIMAGE:-0}" = 1 ]; then
  echo "package_linux: AppImage skipped"
  exit 0
fi
python3 "$root/tool/ci/fetch_tool.py" appimagetool --out "$work/appimagetool"
python3 "$root/tool/ci/fetch_tool.py" appimage-runtime --out "$work/runtime-x86_64"
image="$out/$(python3 "$root/tool/ci/package.py" name --version "$version" --kind linux-appimage)"
# Extract-and-run avoids needing FUSE on the runner; no update info is embedded:
# updates come only from the signed manifest.
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 timeout 600 \
  "$work/appimagetool" --no-appstream --runtime-file "$work/runtime-x86_64" "$appdir" "$image"
chmod 0755 "$image"

# Smoke check: the image unpacks and carries the marker and the core.
(
  cd "$work"
  timeout 300 "$image" --appimage-extract > /dev/null
  test "$(cat squashfs-root/install-kind)" = linux-appimage
  test -x squashfs-root/lib/antirkn-mihomo
  test -x squashfs-root/AppRun
) || { echo "::error::AppImage smoke check failed"; exit 1; }
echo "package_linux: $tarball $image"
