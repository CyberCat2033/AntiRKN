#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
flutter pub get --enforce-lockfile
python3 tool/check_workspace.py
python3 tool/generate_changes.py --check
python3 tool/generate_vless.py --check
python3 tool/generate_runner.py --check
python3 tool/generate_snapshot.py --check
python3 tool/generate_app_update.py --check
python3 tool/generate_go_licenses.py --check
python3 -m unittest discover -s tests/runner -v
python3 -m unittest discover -s tests/tools -v
(
  cd apps/manager
  flutter gen-l10n
)
dart format --output=none --set-exit-if-changed apps packages tool/compile_fixtures.dart tool/compile_vless_fixture.dart tool/drive_smoke.dart tool/app_update_manifest.dart
flutter analyze --no-pub
(
  cd packages/integrations
  dart test
)
(
  cd packages/sync
  dart test
)
(
  cd packages/app_update
  dart test
)
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
