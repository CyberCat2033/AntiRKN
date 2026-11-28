# Локальный Ubuntu-сервер

Из корня репозитория:

```bash
./tool/test-server.sh start
./tool/test-server.sh status
./tool/test-server.sh stop
./tool/reset-test-server.sh
./tool/run-linux.sh
```

`start` создаёт сервер при первом запуске, затем запускает существующий диск. Повтор при работающем сервере показывает состояние. `reset-test-server.sh` удаляет диск и ключи **только этого тестового сервера**, затем запускает чистую Ubuntu. Образ Ubuntu сохраняется; данные AntiRKN не затрагиваются.

Требуются QEMU (`qemu-system-x86_64`, `qemu-img`), OpenSSH client, Python 3.11+ и пользовательский systemd. Для нормальной скорости нужен доступ к `/dev/kvm`; без KVM используется медленный TCG. Первое создание скачивает около 600 МиБ закреплённого Ubuntu cloud image, проверяет SHA-256 и создаёт диск 8 ГиБ. VM использует 2 CPU и 1536 МиБ RAM. SSH доступен только с этого ПК.

Параметры подключения в приложении:

| Поле | Значение |
| --- | --- |
| Адрес | `127.0.0.1` |
| Порт | `2222` |
| Пользователь для входа ключом | `root` |
| Приватный ключ | `artifacts/local-server/client` |
| Пользователь для входа паролем/sudo | `antirkn` |
| Файл с паролем | `artifacts/local-server/credentials.json` |
| Отпечаток host key | `artifacts/local-server/fingerprint` или вывод `status` |

Пароли/ключи генерируются локально, не включены в Git. Для импорта выбирайте `client`, не `client.pub`. После сброса меняются ключ и пароль; старое сохранённое подключение должно обнаружить смену host key. Создайте новую тестовую карточку или явно замените её доверие штатными средствами приложения.

SSH из терминала:

```bash
ssh -i artifacts/local-server/client -p 2222 root@127.0.0.1
journalctl --user -u antirkn-local-test-server.service
```

`./tool/run-linux.sh --build` пересобирает приложение перед запуском. Оно использует обычную локальную базу AntiRKN. Скрипт сброса сервера её не очищает. Android APK лежит в `apps/manager/build/app/outputs/flutter-apk/app-debug.apk`; автоматической установки на телефон эти команды не выполняют.

## Повторение серверных испытаний

Испытания меняют только одноразовую VM. Перед ними выполните сброс; после — при желании снова сбросьте стенд для ручной установки:

```bash
python3 tool/fetch_component_fixtures.py
export ANTIRKN_VM_DIRECTORY="$PWD/artifacts/local-server"
python3 tool/test_components_vm.py --cache
python3 tool/test_awg_update_vm.py
ANTIRKN_PREDECESSOR=v3 python3 tool/test_runner_upgrade_vm.py
python3 tool/test_component_recovery_vm.py
```

Кэш содержит официальные архивы с закреплёнными hashes. Без `--cache` первый тест загружает текущие архивы с VM; Go modules при сборке проверяются по upstream go.sum. Тестовый TLS-сертификат создаётся только внутри VM. Эти испытания не заменяют проверку персональных Mihomo TCP/UDP-профилей.

## Автоматический VM-регресс раннера (`tool/vm_regression.py`)

Одноразовый регрессионный прогон на изолированных thin-overlay VM (`artifacts/regression-vm`, SSH порт `2232`). Обычный запуск автоматически выполняется внутри `unshare -rn` без доступа VM к внешнему интернету.

### Когда запускать
- Перед каждым повышением версии раннера (`runner version bump`).
- Перед слиянием любых изменений в `server/runner/`, `schemas/`, контракте RPC или компиляторе профилей.

### Команды запуска
```bash
# 1. Один раз скачать и проверить SHA-256 всех оффлайн-артефактов (с сетью хоста / через HTTP(S)_PROXY):
python3 tool/vm_regression.py --fetch

# 2. Полный регрессионный прогон (полностью оффлайн):
python3 tool/vm_regression.py

# 3. Выборочный запуск и ускорение разработки:
python3 tool/vm_regression.py --only protocols,reboot
python3 tool/vm_regression.py --only inbound_isolation --reuse-protocols
python3 tool/vm_regression.py --only runner_upgrade --previous <git-commit>

# 4. Проверка мутаций (каждый сценарий обязан упасть ровно на ожидаемом check):
python3 tool/vm_regression.py --mutation
```

### Типичное время выполнения
- `--fetch`: ~1–2 мин (разово; включает предзагрузку и проверку `go.sum` для Go-модулей AmneziaWG).
- Первая сборка `golden.qcow2` (или `--rebuild-golden`): ~1–2 мин.
- `runner_upgrade`: ~95 с (автоматически находит предыдущую версию `runner_bundle.g.dart` в `git log`).
- `protocols`: ~120 с (устанавливает 3x-ui, VLESS RAW/REALITY, XHTTP/REALITY, XHTTP/TLS, TrustTunnel и AmneziaWG из оффлайн-кэша с двумя пользователями, проверяет реальный TCP/UDP-трафик через Mihomo и сохраняет `protocols.qcow2`).
- `inbound_isolation`: ~80 с.
- `reality_target`: ~60 с поверх готового `protocols.qcow2` (FR-SNI: временный REALITY inbound `reality_target` — горячее добавление без перезапуска Xray, реальный трафик Mihomo TCP+UDP и 100 КБ через SSH-туннель к временному порту, скрытие из обнаружения, удаление и закрытие порта, неизменность управляемых inbound).
- `upgrade_rollback`: ~150 с.
- `reboot`: ~90 с.
- Полный прогон: ~9 мин; полный `--mutation` прогон (6 мутаций): ~10–12 мин.

### Что покрывает и что НЕ покрывает
- **Покрывает:** свежую установку и обновление раннера с сохранением БД задач; установку 3x-ui из кэша; настройку VLESS (RAW/REALITY, XHTTP/REALITY, XHTTP/TLS), TrustTunnel 1.1.0 и AmneziaWG 3.1 (оффлайн-сборка Go-модулей) с двумя пользователями и компиляцией профилей через `tool/compile_vless_fixture.dart`; реальный TCP+UDP-трафик через закреплённый Mihomo `v1.19.30`; изоляцию отказа одного инбаунда (`tt_state`/`awg_state` и изоляцию трафика); транзакцию обновления Xray (`xray_check_*`: откат при canary-регрессии, независимый watchdog при остановленном раннере, успешный коммит); реальную перезагрузку VM с проверкой БД задач и всех инбаундов.
- **Известная нестабильность:** `upgrade_rollback` падает примерно в половине прогонов: после отката Xray (abort или watchdog) один из inbounds (VLESS RAW, XHTTP/TLS или TrustTunnel) не пропускает трафик дольше 40 с, хотя службы активны и порты слушают. Сама механика отката (abort, watchdog, возврат версии, отказ позднего commit) проверяется стабильно. Причина не установлена; вероятно, это дефект продукта, а не тайминг теста — расследуется отдельной стадией. До исправления падение этого сценария на проверках `all_inbounds_pass_after_*`, `canary_regression_detected` или `probe baseline` перезапускают и сверяют с этим описанием.
- **Не покрывает:** VPS владельца и реальный внешний egress; реальные обновления 3x-ui между upstream-версиями (`panel_update`); adoption сторонних сервисов; SSH hardening; client egress / exit-узлы; ACME/Certbot; клиенты Windows/Android; задание `component_upgrade_apply` (его пробы ходят во внешний интернет, которого у VM нет); автономный `runnerComponentInspector` — сценарий временно вызывает `component_plan` установленного runner, пока не исправлен генератор (см. отчёт стадии). (Ограничение продукта: `vless_state.confirmed` читает БД панели 3x-ui и не видит недоступный по сети порт Xray, поэтому изоляция VLESS проверяется на уровне трафика.)
