# Реестр совместимости P0

Дата проверки: 2026-09-12/15. Статус: P0 выполняется. Проверка конфигурации не равна рабочему TCP/UDP-соединению.

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
| Mihomo | [v1.19.30](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.30), linux-amd64-compatible | Версия/hash, config tests и реальные VLESS RAW/XHTTP TCP/UDP на двух Ubuntu VM | Runtime внешних providers, Android validator, устойчивость к блокировкам |
| Xray | 26.7.28 из закреплённого архива 3x-ui 3.7.0; прежний отдельный кандидат 26.3.27 не используется установщиком | Ubuntu VM: установка, API, несколько VLESS RAW Vision/XHTTP, TCP/UDP Mihomo | Публичные VPS/блокировки, иные платформы и версии |
| 3x-ui | [v3.7.0](https://github.com/MHSanaei/3x-ui/releases/tag/v3.7.0), hashes в `schemas/panel-release.json` | Установка, закрытый listener, API/SSH, управляемые VLESS-инбаунды и клиенты, обнаружение конфликтов и восстановление | Обновление самой панели, импорт чужих установок, прочие протоколы |
| TrustTunnel | [v1.1.0](https://github.com/TrustTunnel/TrustTunnel/releases/tag/v1.1.0), кандидат | Mihomo принимает fixture узла trusttunnel | Endpoint, credentials reload, TCP/UDP/QUIC, ACME и renewal |
| AmneziaWG | Поколение сервера ещё не выбрано | Mihomo принимает fixture с jc/jmin/jmax/s1/s2/h1–h4 | Соответствие конкретному серверному release, kernel/userspace, handshake/UDP |
| RealiTLScanner | [commit e5e114747aa8c6dfa4b394a0782f241bf72bdce6](https://github.com/XTLS/RealiTLScanner/commit/e5e114747aa8c6dfa4b394a0782f241bf72bdce6) | Зафиксирована ссылка upstream для следующего прототипа | Реализация, лицензия включаемых файлов, FFI/упаковка/отмена/три ОС |
| Google Drive | API v3, appDataFolder + drive.appdata; YAML отдельно, drive.file | Прочитаны первичные ограничения API | OAuth, выбор файла, anonymous download, same-fileId update, E2EE и конкурентная публикация |

Mihomo archive SHA-256: `db214c7a2517e63c150d123178d16d102e03a241ccdae4e5e07ffbe9cf56c6f9`. Hash распакованного бинарника и полный безопасный вывод config tests находятся в [mihomo-config-test.json](evidence/mihomo-config-test.json).

## Дополнение: инвентаризация ПО (2026-09-13)

Стадия [ADR 0006](adr/0006-server-software-inventory.md) добавляет чтение ресурсов, стандартных мест установки/версий, служб и TCP/UDP-сокетов. [Ubuntu SSH и Docker metadata](evidence/server-inventory-ubuntu.json) проверены на одноразовых fixtures. Ubuntu-контейнер использует настоящие OpenSSH/утилиты ОС; версии VPN там выводят синтетические executable fixtures, реализующие только read-only version flags. Наличие systemd unit file проверено реально, live-состояния systemd — контрактными тестами. Docker CLI/daemon проверены на незапущенном тестовом контейнере; содержимое VPN-образов не испытывалось.

Эта стадия не меняет матрицу совместимости VPN и не подтверждает API/соединения установленных протоколов. [Hashes исходников интерфейсов версии](evidence/server-inventory-sources.json) относятся к источникам для обнаружения, не к серверным артефактам. Отсутствие данных/прав отличается от отсутствия компонента, теги образов не подменяют версии бинарников. Итоговые сборки и ограничения — в [отчёте](reports/2026-09-13-server-inventory.md).

## Матрица пресетов

| Пресет | Настройка сервера | Экспорт/разбор Mihomo | TCP | UDP |
| --- | --- | --- | --- | --- |
| VLESS RAW/TCP REALITY Vision | 3x-ui 3.7.0 / Xray 26.7.28, два сервера | Production-компилятор + Mihomo 1.19.30 config-test | PASS | PASS |
| VLESS XHTTP REALITY | auto / stream-one, два сервера | Production-компилятор + Mihomo 1.19.30 config-test | PASS | PASS |
| VLESS XHTTP TLS | auto / packet-up / stream-up / stream-one, два сервера | Production-компилятор + Mihomo 1.19.30 config-test | PASS | PASS |
| TrustTunnel | ПО 1.1.0 установлено, обновление 1.0.33 → 1.1.0 и TLS health проверены; продуктовый endpoint отдельно | Публичный fixture принят v1.19.30 | Не испытан | Не испытан |
| AWG 3.1 | Go 3.1.20260828 / tools 3.1.20260812; управляемые интерфейсы, peers и defaults официального приложения | Персональный YAML принят Mihomo 1.19.30 | PASS, 2 клиента Ubuntu; отзыв старого профиля | PASS, 2 клиента Ubuntu |

AWG: [реальные соединения](evidence/awg-network.json), [редактирование native/Docker](evidence/awg-existing.json), [источники defaults и границы поддержки](reports/2026-09-15-amneziawg.md). Не подтверждены IPv6 transport, мобильный runtime, Windows, устойчивость к фильтрации и полная матрица отказов. Docker port mapping в редакторе не меняется.

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

## Дополнение: runner (2026-09-14)

Контракт v1 и hashes встроенной сборки — [runner-ubuntu.json](evidence/runner-ubuntu.json). На Ubuntu 24.04.5 x86_64 в полноценной QEMU/KVM VM проверены настоящие systemd, SSH, sudo, сохранение задания при обрыве связи, crash/reboot recovery и конкурентная регистрация. Образ [Ubuntu 20260911](https://cloud-images.ubuntu.com/noble/20260911/noble-server-cloudimg-amd64.img), SHA-256 `612b2c0cc1bc413a6cb8c38fd611794caf0f2b436c50013d8b3794db12ad7354`.

Это подтверждение инфраструктуры `diagnostic`, а не VPN-протоколов/установщиков. Другие версии Ubuntu/Python/systemd, полный runtime GUI и синхронизация устройств этой стадией не приняты; см. [ADR 0009](adr/0009-durable-runner-and-automatic-sudo.md).

## Дополнение: VLESS и XHTTP (2026-09-14)

[VM 1](evidence/vless-ubuntu.json), [VM 2](evidence/vless-ubuntu-server2.json), [Dart SSH root/sudo](evidence/vless-ssh-api.json), [отказы/reboot](evidence/vless-failures-ubuntu.json). Mihomo binary SHA-256: `8ad44e28fe72be4640254b96741b677f4074991b99186cc4486a1c28ded02b1a`. Каждый сервер имеет два клиента и пять инбаундов; экспорт проверяется production-компилятором, затем настоящим Mihomo. TCP/UDP направлены на изолированные echo endpoints; TLS использует отдельный тестовый CA без skip-cert-verify. Тестовое разрешение private IP в routing/freedom finalRules применяется только на fixture через API панели.

В [Xray 26.7.28](https://github.com/XTLS/Xray-core/blob/v26.7.28/infra/conf/transport_security.go) минимальная версия REALITY по умолчанию — 26.3.27. [Mihomo 1.19.30](https://github.com/MetaCubeX/mihomo/blob/v1.19.30/component/tls/reality.go) сообщает в handshake 1.8.2. По прямому указанию владельца 2026-09-15 адаптер явно ставит minClientVer=0.0.0 при создании и сохранении управляемых и сторонних REALITY-inbounds; настройка и предупреждение в GUI отсутствуют. Устойчивость к блокировкам не проверена. XHTTP REALITY packet-up/stream-up не включены в редактор; XHTTP flow не задаётся.

API и параметры проверены по исходникам закреплённых releases и настоящим бинарникам; [документация Mihomo VLESS](https://wiki.metacubex.one/en/config/proxies/vless/), [транспорт](https://wiki.metacubex.one/en/config/proxies/transport/), [Xray XHTTP](https://xtls.github.io/en/config/transports/splithttp.html) использованы для сверки, а не как замена runtime-тестам. GUI пока выполняет структурную проверку YAML; Mihomo config-test не встроен на устройства. [Архитектура и границы стадии](adr/0011-clients-vless-inbounds.md).


## Обновление 3x-ui, 2026-09-15

Проверенная связка обновления — **3x-ui 3.8.0 / Xray 26.7.28 / Mihomo 1.19.30**. Реальные TCP/UDP RAW/REALITY/Vision, XHTTP/REALITY auto и XHTTP/TLS packet-up/stream-up/stream-one прошли на отдельной Ubuntu VM. [Результаты](evidence/panel-update-network.json).

Вначале проверена поставка 3x-ui 3.8.0 с Xray 26.9.9: обновление и API работали, но RAW/XHTTP REALITY с текущим Mihomo не подключались; TLS-пресеты работали. Библиотека [REALITY 8cdf7bf9c7f0](https://github.com/XTLS/REALITY/blob/8cdf7bf9c7f0/tls.go) требует гибридный X25519MLKEM768 key share перед обычным X25519. Это отдельная проверка handshake, не minClientVer. [Xray 26.9.8](https://github.com/XTLS/Xray-core/blob/v26.9.8/go.mod) и [26.9.9](https://github.com/XTLS/Xray-core/blob/v26.9.9/go.mod) используют эту библиотеку; 26.9.8 сетевым тестом отдельно не проверялся. Поэтому финальный lock закрепляет прежнее совместимое ядро из официального архива 3x-ui 3.7.0, обновляя панель до 3.8.0. Новые ядра видны в проверке releases, но не предлагаются к применению этим адаптером.

Поддержан стандартный systemd/SQLite layout `/usr/local/x-ui`, `/etc/x-ui`, root-owned unit, проверенные версии панели 3.7.0/3.8.0, Ubuntu x86_64. Docker, PostgreSQL, неизвестные версии, кастомные drop-ins и расположения требуют отдельного адаптера. Произвольный downgrade не выполняется.
