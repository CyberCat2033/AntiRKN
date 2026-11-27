#!/usr/bin/env bash
# Layout tests load real fonts from the paths of the development machine
# (Adwaita Sans as Roboto, Material Icons from /opt/flutter); without them
# Flutter's test font is wider and wraps rows. Provide both, pinned.
# Usage: tool/ci/test_fonts.sh <flutter root>
set -euo pipefail
flutter_root="${1:?flutter root}"
url=https://download.gnome.org/sources/adwaita-fonts/51/adwaita-fonts-51.0.tar.xz
archive_sha=fa104ae2c1b96580d322f563ffe8b2dfca5296b0eca4971efd2d8011405123d2
font_sha=8381c33b9a44f066f2b99dba3d416a2342891e28c956a35dfd8d16ee2987e6d4
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
curl -fsSL --retry 3 -o "$work/fonts.tar.xz" "$url"
echo "$archive_sha  $work/fonts.tar.xz" | sha256sum -c --quiet
tar -xJf "$work/fonts.tar.xz" -C "$work" adwaita-fonts-51.0/sans/AdwaitaSans-Regular.ttf
font="$work/adwaita-fonts-51.0/sans/AdwaitaSans-Regular.ttf"
echo "$font_sha  $font" | sha256sum -c --quiet
sudo install -D -m 0644 "$font" /usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf
if [ ! -e /opt/flutter ]; then
  sudo ln -s "$flutter_root" /opt/flutter
fi
test -f /opt/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf || {
  "$flutter_root/bin/flutter" precache --no-android --no-ios >/dev/null
}
test -f /opt/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
