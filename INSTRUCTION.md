# Руководство по сборке и настройке AntiRKN для Linux

Данная инструкция содержит исчерпывающее руководство по сборке приложения **AntiRKN** из исходного кода под Linux, установке всех необходимых зависимостей, а также по созданию и настройке ключей Google Cloud для облачной синхронизации.

---

## Содержание

1. [Введение и архитектурные особенности](#1-введение-и-архитектурные-особенности)
2. [Системные требования и установка зависимостей](#2-системные-требования-и-установка-зависимостей)
   - [Системные библиотеки (C++, GTK, Secret Service)](#21-системные-библиотеки)
   - [Установка Flutter SDK и Dart](#22-установка-flutter-sdk-и-dart)
   - [Установка Go (Golang)](#23-установка-go-golang)
   - [Установка Python 3](#24-установка-python-3)
3. [Сборка приложения под Linux](#3-сборка-приложения-под-linux)
   - [Способ 1: Автоматизированный скрипт (рекомендуется)](#31-способ-1-автоматизированный-скрипт-рекомендуется)
   - [Способ 2: Ручная пошаговая сборка](#32-способ-2-ручная-пошаговая-сборка)
   - [Запуск приложения](#33-запуск-приложения)
4. [Работа без ключей Google (Автономный режим)](#4-работа-без-ключей-google-автономный-режим)
5. [Настройка интеграции с Google Cloud](#5-настройка-интеграции-с-google-cloud)
   - [Зачем нужен Google Drive в AntiRKN?](#51-зачем-нужен-google-drive-в-antirkn)
   - [Шаг 1: Создание проекта в Google Cloud Console](#шаг-1-создание-проекта-в-google-cloud-console)
   - [Шаг 2: Включение Google Drive API и Google Picker API](#шаг-2-включение-google-drive-api-и-google-picker-api)
   - [Шаг 3: Настройка экрана согласия (OAuth Consent Screen)](#шаг-3-настройка-экрана-согласия-oauth-consent-screen)
   - [Шаг 4: Создание Desktop OAuth Client ID](#шаг-4-создание-desktop-oauth-client-id)
   - [Шаг 5: Куда прописать скачанный JSON ключ](#шаг-5-куда-прописать-скачанный-json-ключ)
   - [Шаг 6: Настройка Google Picker API (API Key)](#шаг-6-настройка-google-picker-api-api-key)
6. [Устранение типовых неполадок (Troubleshooting)](#6-устранение-типовых-неполадок-troubleshooting)

---

## 1. Введение и архитектурные особенности

**AntiRKN** — это графическое приложение (Material Design 3) для полного управления собственной VPN-инфраструктурой. Приложение построено на базе:
- **Flutter / Dart** (клиентский интерфейс и бизнес-логика);
- **Go** (встроенное ядро [Mihomo / Clash.Meta](native/mihomo) для валидации и проб сетевых соединений);
- **C++ / GTK 3** (нативный Linux Runner);
- **Python 3** (серверный агент `antirkn-runner` и сборочные утилиты);
- **SQLite + AES-GCM** (локальное зашифрованное хранилище конфигураций и серверов).

> [!IMPORTANT]
> **AntiRKN компилирует нативное ядро Mihomo на Go прямо в процессе сборки Linux-клиента через CMake.**
> Поэтому для успешной сборки на компьютере обязательно должны быть установлены не только Flutter и C++ компилятор, но также **Go (Golang >= 1.22)** и **Python 3**.

---

## 2. Системные требования и установка зависимостей

Поддерживаемые дистрибутивы Linux (x86_64): **Ubuntu 20.04/22.04/24.04+**, **Debian 11/12+**, **Fedora 38+**, **Arch Linux / Manjaro**, **Linux Mint**, **Pop!_OS**.

### 2.1. Системные библиотеки

Для сборки требуются компилятор C++, CMake, Ninja, утилита `pkg-config`, заголовочные файлы GTK 3, библиотеки Secret Service (для безопасного хранения секретов через `gnome-keyring` или `ksecretservice`), SQLite3 и LZMA.

Установите пакеты командой для вашего дистрибутива:

#### Ubuntu / Debian / Linux Mint / Pop!_OS:
```bash
sudo apt update
sudo apt install -y \
  clang \
  cmake \
  ninja-build \
  pkg-config \
  libgtk-3-dev \
  libsecret-1-dev \
  libjsoncpp-dev \
  libsqlite3-dev \
  liblzma-dev \
  python3 \
  golang-go \
  git \
  curl
```

#### Fedora / RHEL:
```bash
sudo dnf install -y \
  clang \
  cmake \
  ninja-build \
  pkg-config \
  gtk3-devel \
  libsecret-devel \
  jsoncpp-devel \
  sqlite-devel \
  xz-devel \
  python3 \
  golang \
  git \
  curl
```

#### Arch Linux / Manjaro:
```bash
sudo pacman -S --needed \
  clang \
  cmake \
  ninja \
  pkgconf \
  gtk3 \
  libsecret \
  jsoncpp \
  sqlite \
  xz \
  python \
  go \
  git \
  curl
```

---

### 2.2. Установка Flutter SDK и Dart

Рекомендуемая версия Flutter: **3.41.x** (с Dart **3.11.x**).

1. Загрузите и распакуйте Flutter SDK (например, в домашнюю папку):
   ```bash
   mkdir -p ~/development
   cd ~/development
   git clone https://github.com/flutter/flutter.git -b stable
   ```
2. Добавьте Flutter в переменную окружения `PATH`. Для этого добавьте в конец файла `~/.bashrc` (или `~/.zshrc`):
   ```bash
   export PATH="$PATH:$HOME/development/flutter/bin"
   ```
3. Примените изменения в текущем терминале:
   ```bash
   source ~/.bashrc
   ```
4. Включите поддержку Linux Desktop во Flutter:
   ```bash
   flutter config --enable-linux-desktop
   ```
5. Проверьте готовность окружения:
   ```bash
   flutter doctor
   ```
   В строке **Linux toolchain** должна стоять зелёная галочка.

---

### 2.3. Установка Go (Golang)

Для сборки компонента `antirkn-mihomo` требуется **Go версии 1.22 или выше** (проект проверен на версиях 1.22 – 1.27).

Проверьте установленную версию:
```bash
go version
```
Если ваш системный пакет `golang-go` устарел, установите официальный Go с [golang.org/dl](https://go.dev/dl/):
```bash
wget https://go.dev/dl/go1.23.4.linux-amd64.tar.gz
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go1.23.4.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin
```

---

### 2.4. Установка Python 3

Python версии 3.10+ обычно предустановлен во всех современных дистрибутивах. Убедитесь в наличии:
```bash
python3 --version
```

---

## 3. Сборка приложения под Linux

Склонируйте репозиторий проекта (если еще не склонирован):
```bash
git clone https://github.com/CyberCat2033/AntiRKN.git
cd AntiRKN
```

### 3.1. Способ 1: Автоматизированный скрипт (рекомендуется)

В репозитории подготовлен специальный скрипт [tool/build_linux.sh](file:///home/cybercat/AntiRKN/tool/build_linux.sh), который:
1. Проверяет наличие всех системных зависимостей (`clang`, `cmake`, `gtk+-3.0`, `libsecret`, `go`, `flutter`, `python3`).
2. Запускает проверку архитектурных слоев и целостности кода (`check_workspace.py`).
3. Генерирует файлы локализации ARB (RU / EN).
4. Загружает Dart-зависимости.
5. Компилирует нативное ядро Mihomo и релизный Linux-бандл.
6. Проверяет динамическую линковку библиотек (`ldd`), исключая падение при запуске.
7. Упаковывает релиз в архив `.tar.gz` и генерирует контрольную сумму SHA-256.

**Команда запуска сборки:**
```bash
bash tool/build_linux.sh
```

#### Доступные параметры скрипта:
- `--release` — собрать оптимизированную релизную версию (по умолчанию);
- `--debug` — собрать версию для отладки;
- `--clean` — выполнить `flutter clean` перед сборкой;
- `--no-archive` — только скомпилировать, без упаковки в `tar.gz`;
- `--defines=<путь>` — передать файл с внешними Google build defines.

**Результат работы скрипта:**
- Исполняемый бандл: `apps/manager/build/linux/x64/release/bundle/`
- Исполняемый файл: `apps/manager/build/linux/x64/release/bundle/antirkn_manager`
- Готовый архив: `apps/manager/build/releases/antirkn-linux-x64-v48-release.tar.gz`
- Чексумма: `apps/manager/build/releases/antirkn-linux-x64-v48-release.tar.gz.sha256`

---

### 3.2. Способ 2: Ручная пошаговая сборка

Если вы хотите выполнить сборку вручную шаг за шагом:

1. Находясь в корне репозитория, загрузите зависимости:
   ```bash
   flutter pub get --enforce-lockfile
   ```
2. Сгенерируйте локализацию:
   ```bash
   cd apps/manager
   flutter gen-l10n
   ```
3. Запустите сборку Linux Release:
   ```bash
   flutter build linux --release
   ```
4. Убедитесь, что скомпилированное Go-ядро имеет права на запуск:
   ```bash
   chmod +x build/linux/x64/release/bundle/lib/antirkn-mihomo
   chmod +x build/linux/x64/release/bundle/antirkn_manager
   ```

---

### 3.3. Запуск приложения

Для запуска собранного приложения выполните:
```bash
cd apps/manager/build/linux/x64/release/bundle
./antirkn_manager
```

Также для запуска из исходного кода в режиме разработки можно использовать:
```bash
cd apps/manager
flutter run -d linux
```

---

## 4. Работа без ключей Google (Автономный режим)

> [!NOTE]
> **Приложение AntiRKN полностью работоспособно БЕЗ каких-либо учетных записей или ключей Google!**

В автономном режиме вам доступны абсолютно все основные функции:
- Подключение неограниченного числа Ubuntu VPS по SSH (по паролю, SSH-ключам Ed25519/RSA или через системный `ssh-agent`).
- Развертывание и управление протоколами:
  - **VLESS** (Reality, Vision, XHTTP) через встроенный модуль или согласование из 3x-ui;
  - **AmneziaWG** (настройка портов, ключей и обфускации от блокировок РКН: `Jc`, `Jmin`, `Jmax`, `S1`, `S2`, `H1`-`H4`);
  - **TrustTunnel** (HTTP/2 TLS туннелирование, автовыпуск ACME Let's Encrypt сертификатов);
  - **Client Egress** (маршрутизация клиентов через цепочку серверов).
- Управление базой клиентов, генерация персональных профилей и ключей.
- Экспорт готовых конфигураций для **Mihomo (Clash.Meta)** в один клик.
- Генерация **QR-кодов** для быстрого добавления в мобильные клиенты.
- Локальное шифрование базы SQLite и создание зашифрованных резервных копий (`.antirkn`).

Настройка Google Cloud требуется **только в том случае**, если вы хотите использовать:
1. Автоматическую E2EE синхронизацию базы данных между устройствами через Google Drive.
2. Публикацию конфигураций клиентов по постоянным HTTP-ссылкам в Google Drive.

---

## 5. Настройка интеграции с Google Cloud

### 5.1. Зачем нужен Google Drive в AntiRKN?

AntiRKN не использует сторонние бэкенды или чужие серверы синхронизации. Ваши данные принадлежат только вам:
- `drive.appdata` — скрытая защищенная папка приложения на вашем личном Google Диске. Используется для хранения сквозного зашифрованного (E2EE) снимка вашей базы серверов и клиентов.
- `drive.file` — используется для выгрузки текстовых конфигураций клиентов (`.yaml`), если вы хотите делиться ими через Google Drive с автоматическим обновлением.

---

### Шаг 1: Создание проекта в Google Cloud Console

1. Перейдите на страницу [Google Cloud Console: Создание проекта](https://console.cloud.google.com/projectcreate).
2. Авторизуйтесь под своим личным Google-аккаунтом.
3. Укажите параметры:
   - **Project name (Название проекта):** `AntiRKN`
   - **Organization (Организация):** оставьте `No organization` (Без организации).
4. Нажмите **Create (Создать)** и дождитесь завершения (несколько секунд).
5. В верхнем селекторе проектов убедитесь, что выбран созданный проект **AntiRKN**. Запишите **Project ID** (например, `antirkn-412300`).

---

### Шаг 2: Включение Google Drive API и Google Picker API

1. Откройте [страницу Google Drive API в библиотеке API](https://console.cloud.google.com/apis/library/drive.googleapis.com).
2. Убедитесь, что вверху выбран ваш проект `AntiRKN`, и нажмите **Enable (Включить)**.
3. Откройте [страницу Google Picker API](https://console.cloud.google.com/apis/library/picker.googleapis.com).
4. Нажмите **Enable (Включить)**.

---

### Шаг 3: Настройка экрана согласия (OAuth Consent Screen)

1. В левом меню откройте **Google Auth Platform** (или **APIs & Services**) → **Branding** (или **OAuth consent screen**). Ссылка: [console.cloud.google.com/auth/branding](https://console.cloud.google.com/auth/branding).
2. В поле **User Type (Тип пользователей)** выберите **External (Внешний)** и нажмите **Create (Создать)**.
3. Заполните обязательные поля:
   - **App name (Имя приложения):** `AntiRKN`
   - **User support email (Email поддержки):** выберите ваш Google email.
   - **Developer contact information:** введите ваш email.
4. Нажмите **Save and Continue (Сохранить и продолжить)**.
5. На шаге **Scopes (Области доступа)** нажмите **Add or remove scopes** и добавьте две области:
   - `https://www.googleapis.com/auth/drive.appdata` (просмотр и управление метаданными конфигурации);
   - `https://www.googleapis.com/auth/drive.file` (просмотр и управление файлами, созданными приложением).
   Нажмите **Update** → **Save and Continue**.
6. На шаге **Test users (Тестовые пользователи)** нажмите **+ Add users** и введите ваш личный Google email (тот же, под которым вы будете входить в приложении). Нажмите **Save and Continue**.
7. *Рекомендация по статусу публикации:*
   - В режиме **Testing** выданные OAuth refresh токены действуют **7 дней**, после чего потребуется повторный вход в приложении.
   - Чтобы токены были бессрочными, на вкладке **Audience / OAuth consent screen** нажмите **Publish App (Опубликовать)** и переведите проект в статус **In Production**. Проходить верификацию Google не требуется: при входе в браузере появится предупреждение *"Google hasn't verified this app"*, достаточно нажать *"Advanced" (Дополнительно)* → *"Go to AntiRKN (unsafe)"*.

---

### Шаг 4: Создание Desktop OAuth Client ID

1. Перейдите в раздел **Clients** (или **Credentials → Create Credentials → OAuth client ID**). Ссылка: [console.cloud.google.com/auth/clients](https://console.cloud.google.com/auth/clients).
2. Нажмите **+ Create Client**.
3. В выпадающем списке **Application type (Тип приложения)** выберите **Desktop app (Классическое приложение)**.
4. В поле **Name (Имя)** укажите: `AntiRKN Desktop`.
5. Нажмите **Create (Создать)**.
6. В появившемся окне нажмите **Download JSON (Скачать JSON)**. На ваш компьютер сохранится файл с именем вида `client_secret_xxxxxxxxxxxx.json`.

---

### Шаг 5: Куда прописать скачанный JSON ключ

Вам не нужно вшивать ключи в исходный код! Доступно два удобных способа:

#### Вариант А: Выбор через графический интерфейс (Самый простой)
1. Запустите приложение AntiRKN.
2. Перейдите в **Настройки → Синхронизация → Google Drive**.
3. Нажмите кнопку **«Войти в Google»**.
4. Приложение обнаружит отсутствие файла конфигурации на диске и **автоматически откроет системный диалог выбора файла**.
5. Выберите скачанный файл `client_secret_xxxxxxxx.json`.
6. Откроется системный браузер. Выберите ваш Google аккаунт, разрешите доступ к Google Drive и вернитесь в AntiRKN.
7. AntiRKN зашифрует конфигурацию и сохранит сессию в защищенном хранилище. Повторно выбирать файл при следующих запусках не потребуется!

#### Вариант Б: Сохранение по стандартному системному пути
Вы можете заранее положить скачанный файл в стандартный каталог конфигурации Linux:
```bash
mkdir -p ~/.config/antirkn/google
cp ~/Downloads/client_secret_*.json ~/.config/antirkn/google/desktop-client.json
chmod 600 ~/.config/antirkn/google/desktop-client.json
```
При запуске AntiRKN автоматически подхватит файл `~/.config/antirkn/google/desktop-client.json`.

---

### Шаг 6: Настройка Google Picker API (API Key)

> [!NOTE]
> Google Picker нужен **только в одном сценарии**: если вы хотите привязать уже существующий файл на Google Диске к клиенту в AntiRKN, не создавая новый URL. Если вам достаточно автоматического создания файлов приложением, этот шаг можно пропустить!

Если вам нужен Google Picker:
1. В Google Cloud Console откройте **APIs & Services → Credentials → Create Credentials → API key**.
2. Скопируйте созданный ключ (например, `AIzaSy...`).
3. В настройках ключа выберите **API restrictions → Restrict key** и отметьте **Google Drive API** и **Google Picker API**.
4. Перейдите в **IAM & Admin → Settings** и скопируйте числовой **Project number** (например, `172329282966`).
5. В приложении AntiRKN откройте: **Настройки → Drive → Настройка Google Picker** и введите API Key и Project Number.

---

## 6. Устранение типовых неполадок (Troubleshooting)

### Ошибка 1: `CMake Error ... target mihomo_core ... FileNotFoundError: 'go'`
- **Причина:** В системе не установлен компилятор Go либо он не добавлен в `$PATH`.
- **Решение:** Установите Go (`sudo apt install golang-go` или с [go.dev/dl](https://go.dev/dl/)) и убедитесь, что команда `go version` выполняется в терминале.

### Ошибка 2: `Package 'gtk+-3.0' not found` или `Package 'libsecret-1' not found`
- **Причина:** Не установлены заголовки библиотек GTK 3 или Secret Service.
- **Решение:** Выполните `sudo apt install -y libgtk-3-dev libsecret-1-dev libjsoncpp-dev` (для Ubuntu/Debian) или аналогичную команду для вашего дистрибутива из раздела 2.1.

### Ошибка 3: `access_denied` / `Error 403: org_internal` при авторизации Google
- **Причина:** В OAuth Consent Screen ваш Google-аккаунт не добавлен в список тестовых пользователей, либо проект настроен как Internal.
- **Решение:** В Google Cloud Console откройте **OAuth consent screen** → проверьте User Type: **External** → в блоке **Test users** нажмите **Add users** и добавьте ваш email.

### Ошибка 4: `redirect_uri_mismatch` при авторизации
- **Причина:** Вы создали OAuth Client типа *Web application* вместо *Desktop app*.
- **Решение:** В разделе Credentials создайте клиент с типом **Desktop app** (Классическое приложение) и скачайте его JSON.

### Ошибка 5: Ошибки локализации или архитектуры при сборке
- **Решение:** Перед сборкой запустите встроенный валидатор репозитория:
  ```bash
  python3 tool/check_workspace.py
  ```
  Он мгновенно проверит корректность шаблона `base.yml`, целостность раннера и совпадение всех 1100+ ключей локализации RU/EN.
