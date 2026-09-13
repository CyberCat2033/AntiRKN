#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
flutter pub get --enforce-lockfile
python3 tool/check_workspace.py
(
  cd apps/manager
  flutter gen-l10n
)
dart format --output=none --set-exit-if-changed apps packages tool/compile_fixtures.dart
flutter analyze --no-pub
(
  cd packages/storage
  flutter test --no-pub
)
(
  cd packages/ssh_transport
  flutter test --no-pub
)
(
  cd packages/network_inventory
  flutter test --no-pub
)
(
  cd packages/profile_compiler
  flutter test --no-pub
)
(
  cd apps/manager
  flutter test --no-pub
)
