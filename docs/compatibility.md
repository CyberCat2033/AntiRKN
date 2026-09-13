# Реестр совместимости P0

Дата проверки: 2026-09-12/13. Статус: P0 выполняется. Проверка конфигурации не равна рабочему TCP/UDP-соединению.

## Закреплённые входы и источники

Точные release URLs, даты публикаций, доступные SHA-256 из GitHub assets и локальные hashes: [upstream-lock.json](evidence/upstream-lock.json). Точные Dart-зависимости и hashes архивов: корневой `pubspec.lock`. Исходный `base.yml`: SHA-256 `f20fc58fce6c4bb1a53d82a2070ad3d4aea2e663d0c1489af23e5b5aa8495ce4`.

| Компонент | Версия / источник | Фактически проверено | Не доказано |
| --- | --- | --- | --- |
| Flutter | Официальный 3.41.2 stable, framework `90673a4eef275d1a6692c26ac80d6d746d41a73a`, Engine `6c0baaebf70e0148f485f27d5616b3d3382da7bf` | Чистый Git checkout в /opt/flutter, Android/Linux toolchain через doctor | Windows build, полная runtime-приёмка трёх ОС, profile frame times |
| Dart | Официальный bundled SDK 3.11.0 | Компилятор, генератор локализации, тесты | — |
| yaml / yaml_edit | 3.1.3 / 2.2.3 | Строгий ограниченный разбор, структурное изменение proxies | Полная семантика произвольных шаблонов/regexp/providers |
| dynamic_color | 1.8.1 | Подключён штатный builder, seed fallback, обе темы | Реальная выдача dynamic palette на каждой платформе |
| shared_preferences | 2.5.4 | DI-тесты; на Android ручной RU сохраняется после force-stop при системном EN | Реальное чтение/запись плагина на Windows/Linux |
| Импорт YAML | file_selector 1.1.0 на desktop; Android ACTION_OPEN_DOCUMENT/ContentResolver | 33 общих теста; реальный Android: выбор документа, совпадение текста, отмена и навигация | Файловые провайдеры Windows/Linux; полный набор Android отказов |
| Каталог одного VPS | Парсер формата iproute2 v6.1.0; локальный smoke на iproute2 7.2.0 / Arch Linux | 23 теста IP/парсера/политики, 5 контроллера, 7 widget/asset tests; реальный локальный вывод 9 IP / 27 routes / 13 rules | SSH-сбор на Ubuntu 24.04, NAT/ручной endpoint, порты, TCP/UDP, протокольные адаптеры |
| SSH одного VPS | dartssh2 4.1.0; Ubuntu OpenSSH 9.6p1-3ubuntu13.19, iproute2 6.1.0-1ubuntu6.4 | Изолированный Ubuntu 24.04 контейнер: root/user, password, OpenSSH Ed25519/RSA, encrypted keys, отказ trust/auth, отмена/timeout/output/OS; каталог с secondary IPv4; отдельный Linux SSH-agent; после уточнения владельца допуск любой версии Ubuntu покрыт 9 регрессионными тестами | Реальный VPS/VM, SSH runtime Windows/Android, sudo/hardening/runner, SFTP/forwarding |
| Постоянный vault | cryptography 2.9.0, flutter_secure_storage 11.1.1, Linux plugin 3.0.3, Windows plugin 4.2.2; hashes в pubspec.lock | AEAD/Argon2id, файл/new instance, неверный пароль/повреждение, CAS/ошибка записи, авто-lock; native Linux мастер-пароль PASS | Secret Service текущей сессии недоступна; native OS keyring success, Windows и Android runtime ещё не доказаны; backup/recovery/sync |
| Mihomo | [v1.19.30](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.30), linux-amd64-compatible | Версия бинарника, SHA-256 архива совпал с GitHub digest, шесть config tests успешны | TCP/UDP, точное runtime-поведение групп с внешними providers, Android validator |
| Xray | [v26.3.27](https://github.com/XTLS/Xray-core/releases/tag/v26.3.27), кандидат | Прочитана release metadata | Установка/API/соединения RAW Vision и XHTTP на Ubuntu 24.04 |
| 3x-ui | [v3.7.0](https://github.com/MHSanaei/3x-ui/releases/tag/v3.7.0), кандидат | Прочитана release metadata | CRUD, forwarding, конфликт ревизий и неизвестные поля |
| TrustTunnel | [v1.1.0](https://github.com/TrustTunnel/TrustTunnel/releases/tag/v1.1.0), кандидат | Mihomo принимает fixture узла trusttunnel | Endpoint, credentials reload, TCP/UDP/QUIC, ACME и renewal |
| AmneziaWG | Поколение сервера ещё не выбрано | Mihomo принимает fixture с jc/jmin/jmax/s1/s2/h1–h4 | Соответствие конкретному серверному release, kernel/userspace, handshake/UDP |
| RealiTLScanner | [commit e5e114747aa8c6dfa4b394a0782f241bf72bdce6](https://github.com/XTLS/RealiTLScanner/commit/e5e114747aa8c6dfa4b394a0782f241bf72bdce6) | Зафиксирована ссылка upstream для следующего прототипа | Реализация, лицензия включаемых файлов, FFI/упаковка/отмена/три ОС |
| Google Drive | API v3, appDataFolder + drive.appdata; YAML отдельно, drive.file | Прочитаны первичные ограничения API | OAuth, выбор файла, anonymous download, same-fileId update, E2EE и конкурентная публикация |

Mihomo archive SHA-256: `db214c7a2517e63c150d123178d16d102e03a241ccdae4e5e07ffbe9cf56c6f9`. Hash распакованного бинарника и полный безопасный вывод config tests находятся в [mihomo-config-test.json](evidence/mihomo-config-test.json).

## Матрица пресетов

| Пресет | Настройка сервера | Экспорт/разбор Mihomo | TCP | UDP |
| --- | --- | --- | --- | --- |
| VLESS RAW/TCP REALITY Vision | Не испытана | Публичный fixture принят v1.19.30 | Не испытан | Не испытан |
| VLESS XHTTP REALITY | Не испытана | Только структурное ограничение входа; fixture/test ядром ещё нет | Не испытан | Не испытан |
| VLESS XHTTP TLS | Не испытана | Только структурное ограничение входа; fixture/test ядром ещё нет | Не испытан | Не испытан |
| TrustTunnel | Не испытана | Публичный fixture принят v1.19.30 | Не испытан | Не испытан |
| AWG | Не выбрано поколение | Публичный fixture принят v1.19.30; не означает поддержки версии сервера | Не испытан | Не испытан |

## base.yml

Проверены VLESS-only, TrustTunnel-only, AWG-only, mixed с RU, mixed без RU и вариант без WG. Для каждого: одинаковый template + те же stable access IDs дают одинаковый YAML/hash, порядок rules и все поля кроме proxies сохранены. Профиль другого пользователя не включается.

[Состав групп и диагностические коды](evidence/base-groups.json). Для смешанного варианта RemoteBalancer содержит VLESS; RuZone — TrustTunnel_RU; WG_Auto — WG; Proxy_Chain — RemoteBalancer и все три узла. Это сохраняет различие политик исходника.

По закреплённым исходникам [parser.go](https://github.com/MetaCubeX/mihomo/blob/v1.19.30/adapter/outboundgroup/parser.go) и [groupbase.go](https://github.com/MetaCubeX/mihomo/blob/v1.19.30/adapter/outboundgroup/groupbase.go), include-all-proxies использует упорядоченные имена, положительный filter не фильтрует явные proxies, исключения применяются к итоговому составу; пустая группа использует empty-fallback (по умолчанию COMPATIBLE). Наши пустые группы проходят `-t`, но остаются блокирующей политической диагностикой. Наблюдение runtime группы отдельным контрольным API-тестом ещё не выполнено.

## Инструменты и платформы

Хост Linux x86_64. В первой итерации Android OnePlus HD1911, API 36 был подключён через ADB; на телефоне выполнены установка/холодный запуск, автовыбор EN и ручной RU с сохранением после force-stop при системном EN. [Результат проверки локализации](evidence/android-localization.json). Импорт через системный диалог, совпадение содержимого с base.yml, отмена повторного выбора и сохранение при навигации: [Android import smoke](evidence/android-template-import.json). В итерации каталога телефон отключён по указанию владельца; новые изменения на устройстве не проверялись. Windows-стенд не предоставлен; Ubuntu VPS и тестовый Google-аккаунт не заданы.

Итерация каталога: [локальный вывод iproute2](evidence/network-local-smoke.json), [68 тестов и общая проверка](evidence/network-verification.txt), [Linux startup smoke](evidence/network-linux-startup.json), [актуальные Linux/Android debug-артефакты](evidence/network-builds.json). Обе сборки успешны; образец каталога упакован и совпадает с исходником. Запуск Linux проверен до работающего процесса/старта Dart VM без обнаруженных фатальных ошибок за 6 секунд; это не полная GUI/accessibility-приёмка. [Архитектура, источники и ограничения](adr/0004-single-server-address-inventory.md).

Официальный Flutter 3.41.2 установлен из неизменённого тега [flutter/flutter](https://github.com/flutter/flutter/tree/3.41.2) в `/opt/flutter` через Polkit по запросу владельца. Bootstrap скачал соответствующий Dart 3.11.0; Android/Linux артефакты получены штатным `flutter precache`. Команды `/usr/local/bin/flutter` и `/usr/local/bin/dart` указывают на этот SDK; зависимости используют постоянный `~/.pub-cache`. `flutter doctor -v` подтвердил Flutter, Android SDK 36.1.0 с принятыми лицензиями, Linux toolchain, устройство и сеть. Chrome не установлен; web не входит в целевые платформы. [Версии и результат doctor](evidence/flutter-sdk.json).

Android использует Gradle 8.14, Java 17.0.20.1, AGP 8.11.1, Kotlin 2.2.20, NDK 28.2.13676358. Wrapper закреплён официальным distribution SHA-256. `flutter config --jdk-dir=/usr/lib/jvm/java-17-openjdk` задаёт Java 17 для обычных команд Flutter. [Hashes сборок и wrapper](evidence/builds.json). Наличие scaffold для Windows не считается сборкой Windows.

Первоначальная AUR-сборка имела несогласованный Dart/snapshot и жёсткие пути; первые проверки выполнялись временной копией SDK. Теперь рабочий SDK официальный, исходники не правятся и AUR workaround не нужен. Установленные ранее пакеты AUR не удалялись; приоритет обычного PATH получает `/usr/local/bin`.

## Критерии продолжения P0

1. Реальные Ubuntu 24.04 x86_64 tests для каждого пресета с точной версией ядра/клиента, источником соединения и отдельным TCP/UDP результатом.
2. Host key до credentials, раздельный SecretStore, SFTP/forwarding, отмена и сохранение доступа.
3. Тестовый OAuth client/account для каждой платформы: drive.file не даёт доступ только по вставленному URL. Проверить создание/перезапись/скачивание и права.
4. Проверить Drive concurrency на настоящем API. Документация [files.update](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/update) не является доказательством атомарного If-Match media upload. Файл lock.json и предварительное чтение hash не решают гонку.
5. [appDataFolder](https://developers.google.com/workspace/drive/api/guides/appdata) для E2EE журнала, отдельные публичные YAML. Реальные две копии приложения, конфликты, tombstones, повреждение, восстановление и отзыв устройства.
6. Упакованный Android config-test модуль: провести spike по библиотечной обёртке pinned Mihomo; до него не выдавать структурную проверку за проверку ядром и не отправлять профили сторонним валидаторам.
7. Локальный Go scanner, ограниченные цели, TLS/SAN/ALPN и отмена; инструментальный тест источника соединений на трёх ОС. Реальный каталог IP через SSH.

Текущая SSH/vault-стадия: по дополнительному запросу владельца новый APK установлен на OnePlus HD1911 / API 36 с сохранением данных; запуск/процесс подтверждены. Полная runtime-приёмка Android SSH/Keystore/key picker остаётся открытой. [Установка](evidence/ssh-android-install.json), [отчёт стадии](reports/2026-09-13-ssh-vault.md).
