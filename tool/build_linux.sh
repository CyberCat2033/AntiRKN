#!/usr/bin/env bash
# ==============================================================================
# AntiRKN: Автоматизированный скрипт сборки и упаковки для Linux (x64)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
MANAGER_DIR="$ROOT_DIR/apps/manager"

BUILD_MODE="release"
DO_CLEAN=false
DO_ARCHIVE=true
DEFINES_FILE=""

# Цвета для терминала
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

print_step() {
  echo -e "\n${BLUE}${BOLD}==>${NC} ${BOLD}$1${NC}"
}

print_success() {
  echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
  echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
  echo -e "${RED}✗ $1${NC}"
}

show_help() {
  cat << EOF
Использование: bash tool/build_linux.sh [ОПЦИИ]

Опции:
  --release             Собрать релизную версию (по умолчанию)
  --debug               Собрать отладочную версию (Debug)
  --clean               Выполнить flutter clean перед сборкой
  --no-archive          Не упаковывать бандл в tar.gz
  --defines=<путь>      Путь к JSON-файлу с Google Dart defines
  -h, --help            Показать эту справку

Примеры:
  bash tool/build_linux.sh
  bash tool/build_linux.sh --debug --no-archive
  bash tool/build_linux.sh --defines=~/.config/antirkn/google/binding-build-defines.json
EOF
}

# Парсинг аргументов
for arg in "$@"; do
  case "$arg" in
    --release)
      BUILD_MODE="release"
      ;;
    --debug)
      BUILD_MODE="debug"
      ;;
    --clean)
      DO_CLEAN=true
      ;;
    --no-archive)
      DO_ARCHIVE=false
      ;;
    --defines=*)
      DEFINES_FILE="${arg#*=}"
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      print_error "Неизвестный параметр: $arg"
      show_help
      exit 1
      ;;
  esac
done

# ------------------------------------------------------------------------------
# 1. Проверка системного окружения (Preflight Checks)
# ------------------------------------------------------------------------------
print_step "Проверка системных зависимостей и окружения..."

MISSING_DEPS=()
MISSING_PKGS_APT=()
MISSING_PKGS_DNF=()
MISSING_PKGS_PACMAN=()

check_cmd() {
  local cmd="$1"
  local apt_pkg="$2"
  local dnf_pkg="$3"
  local pacman_pkg="$4"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING_DEPS+=("$cmd")
    [[ -n "$apt_pkg" ]] && MISSING_PKGS_APT+=("$apt_pkg")
    [[ -n "$dnf_pkg" ]] && MISSING_PKGS_DNF+=("$dnf_pkg")
    [[ -n "$pacman_pkg" ]] && MISSING_PKGS_PACMAN+=("$pacman_pkg")
  fi
}

check_pkg_config() {
  local pkg="$1"
  local apt_pkg="$2"
  local dnf_pkg="$3"
  local pacman_pkg="$4"
  if ! pkg-config --exists "$pkg" >/dev/null 2>&1; then
    MISSING_DEPS+=("pkg-config($pkg)")
    [[ -n "$apt_pkg" ]] && MISSING_PKGS_APT+=("$apt_pkg")
    [[ -n "$dnf_pkg" ]] && MISSING_PKGS_DNF+=("$dnf_pkg")
    [[ -n "$pacman_pkg" ]] && MISSING_PKGS_PACMAN+=("$pacman_pkg")
  fi
}

# Проверка базовых бинарников
check_cmd "flutter" "" "" ""
check_cmd "go" "golang-go" "golang" "go"
check_cmd "python3" "python3" "python3" "python"
check_cmd "cmake" "cmake" "cmake" "cmake"
check_cmd "ninja" "ninja-build" "ninja-build" "ninja"
check_cmd "pkg-config" "pkg-config" "pkg-config" "pkgconf"
check_cmd "clang" "clang" "clang" "clang"
check_cmd "tar" "tar" "tar" "tar"
check_cmd "gzip" "gzip" "gzip" "gzip"

# Проверка системных библиотек через pkg-config (если pkg-config доступен)
if command -v pkg-config >/dev/null 2>&1; then
  check_pkg_config "gtk+-3.0" "libgtk-3-dev" "gtk3-devel" "gtk3"
  check_pkg_config "libsecret-1" "libsecret-1-dev" "libsecret-devel" "libsecret"
fi

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
  print_error "Обнаружены отсутствующие зависимости: ${MISSING_DEPS[*]}"
  echo ""
  echo "Для сборки AntiRKN под Linux установите недостающие пакеты:"
  echo ""
  if [ ${#MISSING_PKGS_APT[@]} -gt 0 ]; then
    echo -e "${BOLD}Ubuntu / Debian / Linux Mint:${NC}"
    echo "  sudo apt update && sudo apt install -y ${MISSING_PKGS_APT[*]} libjsoncpp-dev libsqlite3-dev liblzma-dev"
    echo ""
  fi
  if [ ${#MISSING_PKGS_DNF[@]} -gt 0 ]; then
    echo -e "${BOLD}Fedora / RHEL / CentOS:${NC}"
    echo "  sudo dnf install -y ${MISSING_PKGS_DNF[*]} jsoncpp-devel sqlite-devel xz-devel"
    echo ""
  fi
  if [ ${#MISSING_PKGS_PACMAN[@]} -gt 0 ]; then
    echo -e "${BOLD}Arch Linux / Manjaro:${NC}"
    echo "  sudo pacman -S --needed ${MISSING_PKGS_PACMAN[*]} jsoncpp sqlite xz"
    echo ""
  fi
  if ! command -v flutter >/dev/null 2>&1; then
    echo -e "${BOLD}Flutter SDK:${NC}"
    echo "  Установите Flutter SDK (версия 3.41.x): https://docs.flutter.dev/get-started/install/linux"
    echo "  Добавьте flutter в PATH: export PATH=\"\$PATH:/path/to/flutter/bin\""
    echo ""
  fi
  exit 1
fi

print_success "Все обязательные утилиты и библиотеки найдены."

# Проверка версий
FLUTTER_VER="$(flutter --version | head -n 1)"
GO_VER="$(go version)"
PYTHON_VER="$(python3 --version)"
echo "  Flutter: $FLUTTER_VER"
echo "  Go:      $GO_VER"
echo "  Python:  $PYTHON_VER"

# ------------------------------------------------------------------------------
# 2. Проверка Google defines
# ------------------------------------------------------------------------------
if [ -z "$DEFINES_FILE" ]; then
  DEFAULT_DEFINES="$HOME/.config/antirkn/google/binding-build-defines.json"
  if [ -f "$DEFAULT_DEFINES" ]; then
    DEFINES_FILE="$DEFAULT_DEFINES"
    print_warning "Найдены локальные Google defines: $DEFINES_FILE (будут использованы при сборке)"
  fi
fi

EXTRA_BUILD_ARGS=()
if [ -n "$DEFINES_FILE" ]; then
  if [ -f "$DEFINES_FILE" ]; then
    EXTRA_BUILD_ARGS+=("--dart-define-from-file=$DEFINES_FILE")
    print_success "Применяются build defines из: $DEFINES_FILE"
  else
    print_error "Указанный файл defines не найден: $DEFINES_FILE"
    exit 1
  fi
else
  echo "  (Сборка без внешних Google defines: Google Drive авторизация настраивается в GUI)"
fi

# ------------------------------------------------------------------------------
# 3. Контроль целостности репозитория
# ------------------------------------------------------------------------------
print_step "Проверка архитектурных границ и целостности кода..."
cd "$ROOT_DIR"
python3 tool/check_workspace.py
python3 tool/generate_runner.py --check

print_step "Обновление файлов локализации ARB..."
(
  cd "$MANAGER_DIR"
  flutter gen-l10n
)

# ------------------------------------------------------------------------------
# 4. Очистка (при запросе) и загрузка зависимостей
# ------------------------------------------------------------------------------
if [ "$DO_CLEAN" = true ]; then
  print_step "Очистка кэша сборки (flutter clean)..."
  (
    cd "$MANAGER_DIR"
    flutter clean
  )
fi

print_step "Загрузка зависимостей Dart/Flutter..."
flutter pub get --enforce-lockfile || flutter pub get

# ------------------------------------------------------------------------------
# 5. Сборка Linux приложения
# ------------------------------------------------------------------------------
print_step "Компиляция AntiRKN Manager под Linux ($BUILD_MODE)..."
(
  cd "$MANAGER_DIR"
  flutter build linux "--$BUILD_MODE" --no-pub "${EXTRA_BUILD_ARGS[@]}"
)

BUNDLE_DIR="$MANAGER_DIR/build/linux/x64/$BUILD_MODE/bundle"
EXECUTABLE="$BUNDLE_DIR/antirkn_manager"
MIHOMO_BIN="$BUNDLE_DIR/lib/antirkn-mihomo"
LIBAPP="$BUNDLE_DIR/lib/libapp.so"

if [ ! -f "$EXECUTABLE" ]; then
  print_error "Исполняемый файл $EXECUTABLE не найден после сборки!"
  exit 1
fi

# Убеждаемся в наличии прав на запуск
chmod +x "$EXECUTABLE"
if [ -f "$MIHOMO_BIN" ]; then
  chmod +x "$MIHOMO_BIN"
fi

print_success "Сборка завершена успешно: $EXECUTABLE"

# ------------------------------------------------------------------------------
# 6. Проверка динамических библиотек через ldd
# ------------------------------------------------------------------------------
print_step "Проверка зависимостей динамической линковки (ldd)..."
LDD_ERRORS=0

check_ldd() {
  local target="$1"
  if [ -f "$target" ]; then
    local missing
    missing=$(ldd "$target" 2>&1 | grep "not found" || true)
    if [ -n "$missing" ]; then
      print_error "В файле $target обнаружены отсутствующие библиотеки:"
      echo "$missing"
      LDD_ERRORS=$((LDD_ERRORS + 1))
    else
      print_success "Линковка $target корректна"
    fi
  fi
}

check_ldd "$EXECUTABLE"
check_ldd "$LIBAPP"

if [ $LDD_ERRORS -gt 0 ]; then
  print_error "Обнаружены ошибки динамической линковки! Приложение может не запуститься."
  exit 1
fi

# ------------------------------------------------------------------------------
# 7. Упаковка релизного архива (tar.gz)
# ------------------------------------------------------------------------------
if [ "$DO_ARCHIVE" = true ]; then
  print_step "Упаковка бандла в релизный архив..."

  RUNNER_VERSION="unknown"
  LOCK_FILE="$ROOT_DIR/schemas/runner-release-lock.json"
  if [ -f "$LOCK_FILE" ]; then
    RUNNER_VERSION="v$(python3 -c "import json; print(json.load(open('$LOCK_FILE'))['version'])")"
  fi

  RELEASES_DIR="$MANAGER_DIR/build/releases"
  mkdir -p "$RELEASES_DIR"

  ARCHIVE_NAME="antirkn-linux-x64-${RUNNER_VERSION}-${BUILD_MODE}.tar.gz"
  ARCHIVE_PATH="$RELEASES_DIR/$ARCHIVE_NAME"
  LATEST_PATH="$RELEASES_DIR/antirkn-linux-x64-latest.tar.gz"

  # Создаем архив с сохранением прав
  tar -czf "$ARCHIVE_PATH" -C "$BUNDLE_DIR" .
  cp -f "$ARCHIVE_PATH" "$LATEST_PATH"

  ARCHIVE_SIZE=$(wc -c < "$ARCHIVE_PATH")
  ARCHIVE_SHA=$(sha256sum "$ARCHIVE_PATH" | awk '{print $1}')
  echo "$ARCHIVE_SHA  $ARCHIVE_NAME" > "$ARCHIVE_PATH.sha256"

  print_success "Релизный архив создан: $ARCHIVE_PATH"
  echo "  Размер:  $ARCHIVE_SIZE байт"
  echo "  SHA-256: $ARCHIVE_SHA"
fi

# ------------------------------------------------------------------------------
# Итог
# ------------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}              Сборка AntiRKN успешно завершена!                 ${NC}"
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo ""
echo "Бинарный бандл готов к запуску:"
echo "  $EXECUTABLE"
echo ""
if [ "$DO_ARCHIVE" = true ]; then
  echo "Релизный архив:"
  echo "  $ARCHIVE_PATH"
  echo "  (Контрольная сумма: $ARCHIVE_PATH.sha256)"
  echo ""
fi
echo "Запуск приложения:"
echo "  cd $BUNDLE_DIR && ./antirkn_manager"
echo ""
