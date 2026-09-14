#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir/apps/manager"
if [[ "${1:-}" == "--build" || ! -x build/linux/x64/debug/bundle/antirkn_manager ]]; then
  flutter build linux --debug
fi
exec ./build/linux/x64/debug/bundle/antirkn_manager
