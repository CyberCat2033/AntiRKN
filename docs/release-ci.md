# Сборка и релизы в GitHub Actions

Здесь описано, как CI собирает AntiRKN для Android, Windows и Linux, как выпускается релиз и что владелец настраивает один раз сам: ключи, секреты, правила репозитория и Google Cloud. Как работает обновление в приложении, описано в ADR 0024 (`docs/adr/0024-app-auto-update.md`).

## Workflows

| Файл | Когда запускается | Что делает | Секреты |
|---|---|---|---|
| `.github/workflows/checks.yml` | push в ветку, pull request, ручной запуск | `tool/verify.sh`, мягкая проверка `[Unreleased]` в changelog; сборка трёх платформ для PR, default-ветки и ручного запуска | нет |
| `.github/workflows/build.yml` | вызывается из двух других | Android (ubuntu-24.04), Linux (ubuntu-22.04 ради старого glibc), Windows (windows-2022), упаковка | нет |
| `.github/workflows/release.yml` | push тега `vX.Y.Z` | `prepare` → `build` → `sign-android` → `publish` | только в Environment `release` |

Общие правила:
- Сторонние actions закреплены полным SHA коммита (версия указана в комментарии). Flutter 3.41.2, Go 1.26.11, JDK 17 (Temurin), Android build-tools 36.0.0, NDK из выбранного Flutter (`tool/ci/flutter_ndk_version.sh`). Inno Setup 6.7.4, appimagetool 1.9.1 и AppImage runtime скачиваются по фиксированным URL с проверкой SHA-256 (`tool/ci/fetch_tool.py`). Gradle закреплён `distributionSha256Sum` в wrapper.
- `permissions: contents: read` везде. `contents: write` есть только у `publish`. `pull_request_target` не используется.
- Кэши Go, Gradle и Flutter работают только в `checks.yml`. Release-сборка кэши не читает и не пишет, поэтому ни PR, ни ветка не влияют на релизные артефакты.
- Сборка не получает секретов. В неё попадают только публичные идентификаторы Google из repository variables: `--dart-define-from-file`, файл генерирует `tool/ci/google_defines.py`. Desktop OAuth client JSON по-прежнему загружается во время работы приложения и в сборки не попадает. PR из форка получает placeholder Project ID: такая сборка проверяет компиляцию, но не годится для входа в Google.
- Mihomo собирается обычным путём: Gradle `buildMihomo` для Android, CMake `native_mihomo.cmake` для desktop, оба вызывают `tool/build_mihomo.py` с `GOTOOLCHAIN=local`.

## Релизный конвейер

1. **prepare**: тег проходит строгую проверку `vX.Y.Z` (Y, Z < 100; суффиксы `-beta` не принимаются). Затем считается build = X·10000 + Y·100 + Z, и build должен быть больше, чем у последнего релиза. Коммит тега должен входить в default-ветку. В `CHANGELOG.md` и `CHANGELOG.ru.md` должна быть непустая секция `## [X.Y.Z]`. Ошибки выводятся как `::error::` с понятным текстом.
2. **build**: `flutter build … --build-name X.Y.Z --build-number <build>`. pubspec в CI не меняется.
   - Android: APK split-per-ABI (`arm64-v8a`, `armeabi-v7a`, `x86_64`) и universal. versionCode = build·10 + id ABI (universal 0, armeabi-v7a 1, arm64-v8a 2, x86_64 3). Его задаёт `android/app/build.gradle.kts` для release-сборок вместо смещения Flutter ABI·1000 + build; debug и profile сохраняют обычный build. Поэтому любой APK нового build старше любого APK прошлого, и устройство может перейти между split и universal без downgrade. Реальные versionCode читаются через `aapt2` и сверяются с формулой. Верхний предел build — 209 999 999, иначе versionCode выйдет за лимит Android 2 100 000 000. APK подписаны одноразовым debug-ключом раннера и ждут переподписи.
   - Linux: `.tar.gz` и `.AppImage`. Windows: portable `.zip` (MSVC runtime лежит рядом с exe) и установщик Inno Setup.
3. **sign-android** (Environment `release`): keystore раскодируется во временный файл с правами 0600 и удаляется после подписи. Пароли передаются в `apksigner` через `env:`, а не через argv. Затем `zipalign -P 16 4` и подпись v1+v2+v3. После подписи проверяется, что подписант ровно один и его SHA-256 равен `ANTIRKN_ANDROID_CERT_SHA256`, что выравнивание верное и versionCode, versionName и package не изменились.
4. **publish** (Environment `release`):
   1. build и versionCode каждого APK должны быть больше build и **максимального** versionCode предыдущего `app-update-stable.json`, а сертификат должен совпадать с прошлым.
   2. `dart run tool/app_update_manifest.dart build … --changelog-dir .` собирает payload.
   3. `tool/ci/release_assets.py check` сверяет payload с файлами: имена, URL, size, sha256, versionCode, certSha256, tag и commit.
   4. `sign` подписывает manifest ключом из env `ANTIRKN_UPDATE_SIGNING_KEY`, затем `verify` проверяет его доверенными ключами приложения.
   5. Создаются release notes (`release-notes`), `SHA256SUMS` и provenance attestation.
   6. Создаётся **черновик** релиза. Загружаются все файлы, `app-update-stable.json` последним.
   7. Загруженные файлы сверяются по size и digest, черновик публикуется как latest, и проверяется, что `releases/latest` указывает на новый тег.

   Если повторить упавший запуск, он переиспользует оставшийся черновик. Опубликованный релиз не перезаписывается: нужна новая версия.

### Файлы релиза

```
AntiRKN-vX.Y.Z-android-{arm64-v8a,armeabi-v7a,x86_64,universal}.apk
AntiRKN-vX.Y.Z-windows-x64-setup.exe
AntiRKN-vX.Y.Z-windows-x64-portable.zip   # каталог AntiRKN-vX.Y.Z-windows-x64-portable/
AntiRKN-vX.Y.Z-linux-x64.tar.gz           # каталог AntiRKN-vX.Y.Z-linux-x64/
AntiRKN-vX.Y.Z-linux-x64.AppImage
app-update-stable.json                    # подписанный manifest
SHA256SUMS
```

Рядом с исполняемым файлом лежит маркер `install-kind` из одной строки: `windows-installer` (пишет Inno Setup), `windows-portable`, `linux-tarball` или `linux-appimage`. Он нужен, потому что одна desktop-сборка упаковывается двумя способами. Архивы воспроизводимы: записи отсортированы, время берётся из коммита.

### Установщик Windows

`packaging/windows/antirkn.iss` ставит программу для текущего пользователя без UAC (`PrivilegesRequired=lowest`, `%LOCALAPPDATA%\Programs\AntiRKN`). Его AppId постоянный, поэтому новая версия ставится поверх старой. `CloseApplications=yes` и `AppMutex` закрывают запущенное приложение. Деинсталлятор удаляет только файлы из `{app}`: данные пользователя в `%APPDATA%` и `%LOCALAPPDATA%` остаются. Тихое обновление из приложения:

```
AntiRKN-vX.Y.Z-windows-x64-setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /relaunch=1
```

**SmartScreen.** Подписи Authenticode нет, поэтому при первом запуске Windows покажет «Неизвестный издатель»: нужно нажать «Подробнее → Выполнить в любом случае». Целостность обновлений из приложения обеспечивает подписанный Ed25519 manifest и SHA-256 файлов. Позже можно бесплатно подписывать сборки для open source через SignPath Foundation. Это отдельное решение владельца.

### AppImage и tarball

AppImage собирается из AppDir: bundle, `packaging/linux/AppRun`, `.desktop`, иконка `apps/manager/assets/branding/app_icon.png`. Update-info в AppImage не встраивается: обновления приходят только по подписанному manifest. GTK3 и libsecret берутся из системы, как и для tarball.

## Как выпустить релиз

1. В `CHANGELOG.md` и `CHANGELOG.ru.md` перенесите пункты из `## [Unreleased]` в новую секцию `## [X.Y.Z] - ГГГГ-ММ-ДД`. Пустой `## [Unreleased]` оставьте сверху.
2. Закоммитьте это в default-ветку и дождитесь зелёного `Checks`.
3. Создайте аннотированный тег и отправьте его: `git tag -a vX.Y.Z -m "AntiRKN vX.Y.Z"`, затем `git push origin vX.Y.Z`.
4. В Actions → Release одобрите deployment в Environment `release`. Это потребуется дважды: для `sign-android` и для `publish`.
5. Проверьте страницу релиза и `https://github.com/CyberCat2033/AntiRKN/releases/latest/download/app-update-stable.json`.

## Локальная проверка

```
python3 -m unittest tests/tools/test_ci_release.py
SKIP_APPIMAGE=1 bash tool/ci/package_linux.sh apps/manager/build/linux/x64/release/bundle 0.1.0 /tmp/antirkn-dist /tmp/antirkn-work
```

Без `SKIP_APPIMAGE` скрипт скачает закреплённые appimagetool и runtime и соберёт AppImage. Workflow удобно проверять через `actionlint`. Локальные Android release-сборки без `apps/manager/android/key.properties` и без переменных `ANTIRKN_ANDROID_*` подписываются debug-ключом. Если указан ключ, используется он, а неполный набор параметров приводит к ошибке Gradle.

`apps/manager/android/key.properties` (не коммитится):

```
storeFile=/абсолютный/путь/antirkn-release.jks
storePassword=…
keyAlias=antirkn
keyPassword=…
```

---

# ЧЕК-ЛИСТ ВЛАДЕЛЬЦА

Всё ниже делает только владелец, на своей машине или в веб-интерфейсе. Секреты не вставляются в чаты, issues и аргументы команд, которые попадают в историю shell.

## 1. Release keystore для Android

1. Создайте ключ в каталоге вне репозитория:
   ```
   keytool -genkeypair -v -keystore ~/antirkn-keys/antirkn-release.jks -storetype PKCS12 \
     -keyalg RSA -keysize 4096 -validity 10000 -alias antirkn -dname "CN=AntiRKN"
   ```
   В PKCS12 пароль хранилища и пароль ключа одинаковые. Задайте длинный случайный пароль и сохраните его в менеджере паролей.
2. **Резервная копия обязательна, офлайн и зашифрованная.** Без этого ключа обновить установленные APK будет невозможно. Пример: `gpg --symmetric --cipher-algo AES256 antirkn-release.jks`. Храните две копии на разных офлайн-носителях, пароль держите отдельно.
3. Узнайте отпечатки: `keytool -list -v -keystore ~/antirkn-keys/antirkn-release.jks -alias antirkn`. **SHA-1** нужен для Google, **SHA-256** — для переменной `ANTIRKN_ANDROID_CERT_SHA256`.
4. В Google Cloud Console (APIs & Services → Credentials) создайте ещё один OAuth client типа **Android**: package `org.antirkn.antirkn_manager`, SHA-1 release-ключа. Старый debug-клиент оставьте для локальных сборок. Один раз переустановите APK: подпись меняется, поэтому обновить поверх debug-сборки не получится.

## 2. Ключи manifest обновлений (Ed25519)

1. `dart run tool/app_update_manifest.dart keygen --private-out ~/antirkn-keys/update-k1.key` — основной ключ k1. Команда печатает только keyId и публичный ключ.
2. Тем же способом создайте резервный `update-k2.key`. Его закрытая часть хранится **только офлайн** (зашифрованная копия, как для keystore) и в GitHub не загружается. Он нужен, чтобы сменить или отозвать k1.
3. Добавьте **публичные** ключи k1 и k2 в файл доверенных ключей приложения (см. ADR 0024), закоммитьте, затем выпустите релиз. Только сборки с этими ключами смогут проверять обновления.
4. Закрытый k1 положите в секрет Environment (п. 3). Файл `update-k1.key` после этого храните как keystore.

## 3. GitHub: Environment `release`, секреты и переменные

Settings → Environments → New environment `release`:
- **Required reviewers**: владелец. Если владелец один, «Prevent self-review» не включайте.
- **Deployment branches and tags**: «Selected branches and tags», добавьте правило для **тега** `v*.*.*`.
- **Environment secrets** задаются только здесь, не на уровне репозитория:
  - `ANTIRKN_ANDROID_KEYSTORE_BASE64`: `base64 -w0 ~/antirkn-keys/antirkn-release.jks | gh secret set ANTIRKN_ANDROID_KEYSTORE_BASE64 --env release` (значение передаётся через stdin, а не через argv);
  - `ANTIRKN_ANDROID_KEYSTORE_PASSWORD`, `ANTIRKN_ANDROID_KEY_PASSWORD`, `ANTIRKN_ANDROID_KEY_ALIAS` (`antirkn`): задаются интерактивно через `gh secret set NAME --env release`;
  - `ANTIRKN_UPDATE_SIGNING_KEY`: `gh secret set ANTIRKN_UPDATE_SIGNING_KEY --env release < ~/antirkn-keys/update-k1.key`.
- **Environment variables**: `ANTIRKN_ANDROID_CERT_SHA256` (SHA-256 сертификата, можно с двоеточиями), `ANTIRKN_UPDATE_KEY_ID` (`k1`).

Settings → Secrets and variables → Actions → **Variables** (уровень репозитория, значения публичные): `ANTIRKN_GOOGLE_PROJECT_ID`, а также, если нужно, `ANTIRKN_GOOGLE_PICKER_API_KEY` и `ANTIRKN_GOOGLE_PICKER_APP_ID`.

## 4. GitHub: защита репозитория

- **Тег-ruleset** (Settings → Rules → Rulesets → New tag ruleset): target `v*`. Включите Restrict creations, Restrict updates и Restrict deletions; в bypass оставьте только владельца.
- **Защита default-ветки** (ruleset или branch protection): запрет force push и удаления. Перед merge должен быть зелёным статус `Checks / Verify` и сборки. Если работа идёт через PR, требуйте PR.
- **Actions** (Settings → Actions → General): Workflow permissions — «Read repository contents», запретите Actions создавать и одобрять PR. Для fork PR выберите «Require approval for all external contributors». По возможности включите «Require actions to be pinned to a full-length commit SHA» и разрешите только GitHub и verified creators (Flutter ставится скриптом `tool/ci/setup_flutter.sh` с проверкой коммита тега).
- **Code security**: включите Secret scanning и **Push protection**, Dependabot alerts. Можно добавить Dependabot для `github-actions`, чтобы получать PR с обновлением закреплённых SHA.
- Включите 2FA у всех, у кого есть доступ к репозиторию.

## 5. Google Cloud: укрепление проекта

- Отдельный проект только для AntiRKN, без других ресурсов.
- Включены только нужные API: **Google Drive API**, а для ссылок — Google Picker API. Всё остальное выключено.
- **Billing не подключать.**
- В Quotas ограничьте запросы на пользователя в минуту для Drive API, чтобы утёкший client ID нельзя было использовать для массовой нагрузки.
- В Monitoring создайте alert на рост запросов или ошибок Drive API с уведомлением владельцу на почту.
- Минимум **два владельца** проекта, оба с 2FA (лучше аппаратный ключ), чтобы не потерять доступ.
- API key Picker ограничьте этими двумя API. OAuth consent screen содержит только scope `drive.file` / `drive.appdata`.

## 6. Перед первым релизом

1. Выполнены пункты 1–5. Публичные ключи обновлений закоммичены. В обоих changelog есть `## [Unreleased]`.
2. Пробный тег, например `v0.1.1`, по разделу «Как выпустить релиз». Проверьте, что APK ставится поверх (после одной переустановки), что вход в Google работает с release-подписью и что Windows-установщик и AppImage запускаются.
