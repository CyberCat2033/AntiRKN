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
