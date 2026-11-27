// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get appName => 'AntiRKN';

  @override
  String get overview => 'Обзор';

  @override
  String get templateReady => 'Базовый конфиг загружен.';

  @override
  String get templateLoading => 'Чтение базового конфига…';

  @override
  String get profileWarning => 'Предупреждение';

  @override
  String get profileError => 'Ошибка';

  @override
  String get operationObserving =>
      'Изменения здесь применяет другое ваше устройство. Статус обновляется автоматически.';

  @override
  String get operationMissing =>
      'Сервер пока не сообщил об этой операции. Перед продолжением здесь проверьте её статус.';

  @override
  String get operationTakeOver => 'Проверить и продолжить на этом устройстве';

  @override
  String get settings => 'Настройки';

  @override
  String get prototype => 'Прототип P0';

  @override
  String get intro => 'Проверьте, какие узлы попадут в группы вашего шаблона.';

  @override
  String get source => 'Базовый конфиг';

  @override
  String get sourceHelp =>
      'Выберите .yml или .yaml для профилей клиентов. Приложение сохраняет свою копию, исходный файл не изменяется.';

  @override
  String get preview => 'Проверить состав групп';

  @override
  String get pending => 'Проверка…';

  @override
  String get stale => 'Предпросмотр устарел — выполните проверку';

  @override
  String get nodes => 'Набор для предпросмотра';

  @override
  String get sampleNotice =>
      'Это тестовые имена узлов без credentials. Подключения к серверу и публикации здесь ещё нет.';

  @override
  String get mixed => 'VLESS + TrustTunnel + AWG';

  @override
  String get noRuWg => 'Без RU и WG';

  @override
  String get nodeName => 'Имя узла';

  @override
  String get add => 'Добавить в предпросмотр';

  @override
  String get remove => 'Убрать из предпросмотра';

  @override
  String get groups => 'Фактический подбор узлов';

  @override
  String get diagnostics => 'Диагностика шаблона';

  @override
  String get noIssues => 'Структурных ошибок не найдено';

  @override
  String get noMembers => 'Нет подобранных узлов';

  @override
  String get incomplete => 'Состав требует дополнительной проверки';

  @override
  String get connectionNotRun => 'Сетевое соединение не проверено';

  @override
  String get overviewText =>
      'Управляйте серверами и VPN-клиентами, создавайте персональные профили Mihomo и синхронизируйте рабочее пространство через Google Drive. Базовый конфиг выбирается в настройках.';

  @override
  String get scope =>
      'Ubuntu • x86_64\nWindows • Linux • Android\nVLESS / TrustTunnel / AmneziaWG → Mihomo';

  @override
  String get theme => 'Тема';

  @override
  String get system => 'Системная';

  @override
  String get light => 'Светлая';

  @override
  String get dark => 'Тёмная';

  @override
  String get motion => 'Анимации';

  @override
  String get reduced => 'Уменьшенные';

  @override
  String get off => 'Отключены';

  @override
  String get motionHelp =>
      'Системные ограничения анимации имеют приоритет. Выбор сохраняется на устройстве.';

  @override
  String get invalidName => 'Введите уникальное непустое имя';

  @override
  String get loadError => 'Не удалось загрузить базовый шаблон';

  @override
  String get unexpectedError =>
      'Не удалось проверить шаблон. Можно повторить проверку.';

  @override
  String get language => 'Язык интерфейса';

  @override
  String get languageSystem => 'Как в системе';

  @override
  String get languageRussian => 'Русский';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageHelp =>
      'Выбор сохраняется на этом устройстве. Для остальных языков системы используется английский.';

  @override
  String get localeSaveError =>
      'Не удалось сохранить выбор языка. Повторите попытку.';

  @override
  String get localeLoadError =>
      'Не удалось прочитать выбор языка. Используется язык системы.';

  @override
  String fallback(String value) {
    return 'Поведение ядра при пустой группе: $value';
  }

  @override
  String unknownDiagnostic(String code) {
    return 'Параметры шаблона требуют проверки ($code).';
  }

  @override
  String get diagnosticEmptyGroupRequiresPolicy =>
      'Группа пуста. Mihomo использует своё поведение для пустой группы; при необходимости проверьте маршрутизацию.';

  @override
  String get diagnosticChainHasExtraNodes =>
      'Proxy_Chain содержит узлы, исключённые из RemoteBalancer.';

  @override
  String get diagnosticUnreferencedGroup =>
      'На WG_Auto не ссылаются другие группы и правила.';

  @override
  String get diagnosticBaseContainsProxies =>
      'Прокси из базового конфига сохранены и включены в профили клиентов.';

  @override
  String get diagnosticInvalidYaml =>
      'Ошибка синтаксиса YAML или повтор ключа.';

  @override
  String get diagnosticTemplateSizeLimit => 'Размер шаблона превышает 256 КиБ.';

  @override
  String get diagnosticTemplateDepthLimit =>
      'Вложенность YAML превышает 32 уровня.';

  @override
  String get diagnosticTemplateNodeLimit =>
      'В шаблоне слишком много элементов.';

  @override
  String get diagnosticYamlAliasNotSupported =>
      'Aliases YAML пока не поддерживаются.';

  @override
  String get diagnosticYamlExplicitTagNotSupported =>
      'Явные теги YAML пока не поддерживаются.';

  @override
  String get diagnosticMultipleYamlDocuments => 'Ожидается один YAML-документ.';

  @override
  String get diagnosticUnsupportedFilterPreview =>
      'Этот regexp пока нельзя точно вычислить в предпросмотре.';

  @override
  String get diagnosticProviderSnapshotRequired =>
      'Для точного состава нужны данные proxy-provider.';

  @override
  String get diagnosticUnknownProxyReference =>
      'Группа ссылается на неизвестный узел или группу.';

  @override
  String get diagnosticServiceModeGroupEmpty =>
      'В группе только узлы серверов в сервисном режиме, она осталась бы пустой. Опубликованным остаётся прежний профиль; добавьте в группу другой узел или верните сервер.';

  @override
  String get diagnosticUnknownRuleTarget =>
      'Правило ссылается на неизвестный узел или группу.';

  @override
  String get diagnosticUnknownRuleProvider =>
      'Правило или DNS ссылается на неизвестный rule-provider.';

  @override
  String get diagnosticGroupCycle => 'Обнаружен цикл ссылок между группами.';

  @override
  String get diagnosticDuplicateProxyName =>
      'Имя узла или группы должно быть уникальным.';

  @override
  String get diagnosticInvalidEmptyFallback =>
      'Неверное значение empty-fallback.';

  @override
  String get diagnosticUnsupportedRulePreview =>
      'Этот тип правила пока требует проверки ядром.';

  @override
  String get selectTemplate => 'Выбрать YAML-файл';

  @override
  String importedTemplate(String name) {
    return 'Импортирован: $name';
  }

  @override
  String get templateReadError =>
      'Не удалось прочитать YAML-файл. Текущий шаблон сохранён.';

  @override
  String get server => 'Серверы';

  @override
  String get networkTitle => 'Адреса сервера';

  @override
  String get networkSampleNotice =>
      'Тестовые данные одного VPS. Подключение по SSH и изменение настроек сервера не выполняются.';

  @override
  String get networkLoadSample => 'Загрузить пример каталога';

  @override
  String get networkReloadSample => 'Повторить загрузку примера';

  @override
  String get networkLoading => 'Загрузка каталога…';

  @override
  String get networkLoadError =>
      'Не удалось прочитать каталог. Предыдущие данные и ваш выбор сохранены.';

  @override
  String get networkEmpty => 'Назначенные адреса не обнаружены.';

  @override
  String get networkNotLoaded =>
      'Загрузите пример, чтобы проверить выбор адресов.';

  @override
  String get networkListener => 'Адрес прослушивания службы';

  @override
  String get networkEndpoint => 'Адрес подключения клиента';

  @override
  String get networkListenerHelp =>
      'Выберите назначенный IP или все интерфейсы. Перед применением нужно проверить поддержку протоколом и конфликты портов.';

  @override
  String get networkEndpointHelp =>
      'Предлагаются публичные постоянные адреса. При NAT адрес клиента может отличаться от адреса прослушивания.';

  @override
  String get networkChoose => 'Выбрать адрес';

  @override
  String get networkClear => 'Сбросить выбор';

  @override
  String get networkClose => 'Закрыть';

  @override
  String get networkNoCandidates => 'Подходящих адресов для этой роли нет.';

  @override
  String get networkWildcard => 'Все интерфейсы';

  @override
  String get networkAssigned => 'Назначен интерфейсу';

  @override
  String get networkSampleSource => 'Источник: тестовые данные iproute2';

  @override
  String get networkObservedSource => 'Источник: данные iproute2';

  @override
  String get networkNotVerified =>
      'Внешняя доступность TCP/UDP не проверена. Выбор адреса не применяет настройки.';

  @override
  String networkObservedAt(String value) {
    return 'Каталог загружен: $value';
  }

  @override
  String networkSshPeer(String value) {
    return 'Адрес SSH-соединения (отдельно): $value';
  }

  @override
  String networkSummary(int addresses, int routes, int rules) {
    return 'Уникальных IP: $addresses · Маршрутов: $routes · Правил маршрутизации: $rules';
  }

  @override
  String get networkAssignments => 'Назначенные адреса и их состояния';

  @override
  String get networkSelectedUnavailable =>
      'Предыдущий выбор больше не подходит. Выберите адрес заново.';

  @override
  String get networkCategoryPublic => 'Публичный';

  @override
  String get networkCategoryPrivate => 'Частный';

  @override
  String get networkCategoryLoopback => 'Петлевой';

  @override
  String get networkCategoryLinkLocal => 'Локальный для канала';

  @override
  String get networkCategoryShared => 'Общий диапазон / CGNAT';

  @override
  String get networkCategoryDocumentation => 'Диапазон для документации';

  @override
  String get networkCategoryMulticast => 'Групповой';

  @override
  String get networkCategoryUnspecified => 'Неопределённый';

  @override
  String get networkCategorySpecial => 'Специальный диапазон';

  @override
  String get networkHealthReady => 'Пригоден для выбора';

  @override
  String get networkIssueDown => 'Интерфейс отключён';

  @override
  String get networkIssueUnknown => 'Состояние или срок действия неизвестны';

  @override
  String get networkIssueTentative => 'Проверка адреса ещё не завершена';

  @override
  String get networkIssueDadfailed => 'Обнаружен конфликт адресов';

  @override
  String get networkIssueExpired => 'Срок действия адреса истёк';

  @override
  String get networkIssueDeprecated => 'Адрес устаревает';

  @override
  String get networkIssueTemporary => 'Временный адрес';

  @override
  String get networkIssueNotPublic =>
      'Не предлагается как публичный адрес клиента';

  @override
  String get networkIssueUnsupported =>
      'Специальный адрес недоступен для этой роли';

  @override
  String get networkIssueTunnel => 'Туннельный интерфейс';

  @override
  String get networkIssueScope => 'Нужна поддержка зоны интерфейса в протоколе';

  @override
  String get networkIssueUnavailable => 'Адрес больше не назначен';

  @override
  String get networkIssueStale =>
      'Время наблюдения находится в будущем; обновите каталог';

  @override
  String get networkSecondary => 'Дополнительный адрес';

  @override
  String networkPrefix(int value) {
    return 'Префикс: /$value';
  }

  @override
  String networkLifetime(String valid, String preferred) {
    return 'Срок действия / предпочтения: $valid / $preferred';
  }

  @override
  String get networkForever => 'Бессрочно';

  @override
  String get networkUnknown => 'Неизвестно';

  @override
  String networkSeconds(int value) {
    return '$value с';
  }

  @override
  String get networkScopeGlobal => 'Глобальная область';

  @override
  String get networkScopeLink => 'Область канала';

  @override
  String get networkScopeHost => 'Область узла';

  @override
  String get networkScopeSite => 'Область площадки';

  @override
  String get networkScopeOther => 'Другая область';

  @override
  String get networkInterfaceUp => 'Интерфейс включён';

  @override
  String get networkInterfaceStateUnknown => 'Рабочее состояние неизвестно';

  @override
  String get sshServerName => 'Имя сервера (необязательно)';

  @override
  String get sshEdit => 'Изменить подключение';

  @override
  String get sshEditHelp =>
      'Сохранение завершит SSH-сеанс. Подключитесь снова, чтобы применить изменения.';

  @override
  String get sshOsUnknown => 'Версия ОС появится после подключения';

  @override
  String get sshReplaceServer => 'Это другой сервер';

  @override
  String get sshReplaceServerHelp =>
      'Продолжайте, только если намеренно заменили сервер или изменили его адрес. Сверьте новый отпечаток через консоль VPS. Подтверждение заменит сохранённый доверенный ключ; отказ сохранит прежний. Реквизиты входа останутся.';

  @override
  String get sshHost => 'Адрес сервера';

  @override
  String get sshPort => 'Порт SSH';

  @override
  String get sshUser => 'Пользователь SSH';

  @override
  String get sshPassword => 'Пароль SSH';

  @override
  String get sshAuthPassword => 'Пароль';

  @override
  String get sshAuthKey => 'Приватный ключ';

  @override
  String get sshAuthAgent => 'SSH-agent Linux';

  @override
  String get sshAgentHelp =>
      'Используются ключи, загруженные в локальный SSH-agent. Приватный ключ остаётся у агента.';

  @override
  String get sshPickKey => 'Выбрать приватный ключ';

  @override
  String get sshKeyHelp =>
      'Выберите приватный файл, например id_ed25519, без .pub. Независимая копия сохраняется в зашифрованном хранилище.';

  @override
  String get sshNoKey => 'Приватный ключ не выбран';

  @override
  String get sshPassphrase => 'Passphrase ключа (если зашифрован)';

  @override
  String get sshSave => 'Сохранить подключение';

  @override
  String get sshConnect => 'Подключиться';

  @override
  String get sshSaveAndConnect => 'Сохранить и подключиться';

  @override
  String get sshDisconnect => 'Отключиться';

  @override
  String get sshCancel => 'Отмена';

  @override
  String get sshRefresh => 'Обновить с сервера';

  @override
  String get sshConnecting => 'Подключение…';

  @override
  String get sshReading => 'Чтение сведений сервера…';

  @override
  String get sshConnected => 'Подключено';

  @override
  String get sshIdle => 'Отключено';

  @override
  String get sshTrustTitle => 'Проверьте подлинность сервера';

  @override
  String get sshTrustHelp =>
      'Сверьте отпечаток SHA-256 с доверенным источником, например консолью VPS. Подтверждение сохраняет идентичность сервера до аутентификации.';

  @override
  String get sshTrustAccept => 'Доверять и продолжить';

  @override
  String get sshTrustReject => 'Отклонить';

  @override
  String get sshTrustedKey => 'Доверенный ключ сервера';

  @override
  String get sshDelete => 'Удалить сохранённое подключение';

  @override
  String get sshDeleteHelp =>
      'Удалить этот сервер и данные подключения с устройства? Данные на VPS не изменятся.';

  @override
  String get sshInvalidSettings =>
      'Проверьте адрес, порт, пользователя и данные входа.';

  @override
  String get sshInvalidKey =>
      'Не удалось прочитать или расшифровать приватный ключ. Проверьте формат и passphrase. Файл .pub не подходит для входа.';

  @override
  String get sshAuthenticationError =>
      'Ошибка аутентификации. Проверьте пользователя и данные входа.';

  @override
  String get sshHostChanged =>
      'Ключ сервера отличается от доверенного. Подключение заблокировано. Проверьте причину изменения через консоль VPS.';

  @override
  String get sshHostRejected => 'Подлинность сервера не подтверждена.';

  @override
  String get sshNetworkError =>
      'Не удалось связаться с SSH-сервером или соединение потеряно.';

  @override
  String get sshTimeout => 'Время ожидания истекло. Можно повторить попытку.';

  @override
  String get sshCancelled => 'Операция отменена.';

  @override
  String get sshCommandError =>
      'Сервер не предоставил полные сведения. Предыдущий каталог сохранён.';

  @override
  String get sshOutputLimit =>
      'Вывод сервера превысил допустимый размер. Предыдущий каталог сохранён.';

  @override
  String get sshInvalidInventory =>
      'Сервер вернул некорректный каталог. Предыдущий каталог сохранён.';

  @override
  String get sshUnsupportedOs =>
      'Для этого подключения требуется Ubuntu на x86_64.';

  @override
  String get sshDisconnected =>
      'SSH-соединение закрыто. Подключитесь повторно для обновления каталога.';

  @override
  String get sshTrustSaveError =>
      'Не удалось сохранить доверие к серверу. Аутентификация остановлена.';

  @override
  String get sshAgentError =>
      'SSH-agent Linux недоступен или не содержит поддерживаемых ключей. Загрузите ключ в агент либо выберите файл приватного ключа.';

  @override
  String get vaultPassword => 'Мастер-пароль';

  @override
  String get vaultLocked =>
      'Данные подключения недоступны. Откройте сервер заново.';

  @override
  String get vaultRetry => 'Повторить';

  @override
  String get vaultUnavailable =>
      'Не удалось открыть сохранённые подключения. Повторите попытку.';

  @override
  String get vaultMissingKey =>
      'Ключ шифрования устройства недоступен. Сохранённые данные оставлены на месте.';

  @override
  String get vaultDamaged =>
      'Неверный мастер-пароль или повреждённое хранилище. Сохранённые данные не изменены.';

  @override
  String get vaultCorrupt =>
      'Хранилище повреждено или имеет неподдерживаемый формат. Его файл сохранён.';

  @override
  String get vaultWriteFailed =>
      'Не удалось сохранить подключение. Предыдущие данные сохранены.';

  @override
  String get vaultBusy =>
      'Подключение изменено в другом экземпляре приложения. Откройте его заново перед редактированием.';

  @override
  String get vaultExists => 'Данные уже существуют. Откройте сервер заново.';

  @override
  String get vaultWeakPassword =>
      'Введите совпадающие пароли длиной от 12 до 1024 символов.';

  @override
  String get networkExternal => 'Внешние адреса';

  @override
  String get networkInternal => 'Внутренние адреса';

  @override
  String get networkExternalEmpty =>
      'Публичные адреса на интерфейсах не обнаружены.';

  @override
  String get networkInternalEmpty => 'Внутренние адреса не обнаружены.';

  @override
  String get networkClassHint =>
      'Внешние — публичные unicast-адреса; внутренние включают локальные и специальные диапазоны. Это не подтверждает доступность из интернета.';

  @override
  String get inventoryTitle => 'ПО и ресурсы VPS';

  @override
  String get inventoryScope =>
      'Проверяются стандартные пути программ, службы systemd и известные образы локального Docker. Нестандартные пути, переименованные образы и rootless Docker могут потребовать отдельной проверки. Обнаружение не подтверждает совместимость протокола.';

  @override
  String get inventoryStale =>
      'Предыдущий снимок. Для актуальных данных обновите сведения после подключения.';

  @override
  String get inventoryDetected => 'Обнаружен';

  @override
  String get inventoryAbsent => 'Не обнаружен в проверенных местах';

  @override
  String get inventoryUnknown => 'Не удалось определить наличие';

  @override
  String get inventoryPartial => 'Часть проверок не выполнена';

  @override
  String get inventoryUnavailable => 'Недоступно в этой системе';

  @override
  String get inventoryDenied => 'Недостаточно прав';

  @override
  String get inventoryFailed => 'Не удалось проверить';

  @override
  String get inventoryTimeout => 'Время проверки истекло';

  @override
  String get inventoryInvalid => 'Нераспознанный ответ';

  @override
  String get inventoryOutputLimit => 'Ответ превысил ограничение';

  @override
  String get inventoryOk => 'Проверено';

  @override
  String get inventoryVersionUnknown => 'Версия неизвестна';

  @override
  String inventoryVersion(String value) {
    return 'Версия: $value';
  }

  @override
  String get inventoryBinary => 'Файл программы';

  @override
  String get inventoryKernelModule => 'Загруженный модуль ядра';

  @override
  String get inventoryRunning => 'Активен';

  @override
  String get inventoryStopped => 'Неактивен';

  @override
  String get inventoryServiceFailed => 'Ошибка службы';

  @override
  String get inventoryStateUnknown => 'Состояние выполнения неизвестно';

  @override
  String get inventoryKernel => 'Ядро';

  @override
  String get inventoryInit => 'Процесс PID 1';

  @override
  String get inventoryCpu => 'Активные CPU';

  @override
  String get inventoryMemory => 'Всего RAM';

  @override
  String get inventoryAvailableMemory => 'Доступно RAM';

  @override
  String get inventoryDisk => 'Свободно на /';

  @override
  String get inventoryUid => 'Эффективный UID';

  @override
  String get inventoryTools => 'Системные инструменты';

  @override
  String get inventoryToolsEmpty => 'Проверяемые инструменты не обнаружены';

  @override
  String get inventoryPrivilegesHint =>
      'UID и наличие sudo описывают SSH-учётную запись. Проверка административных прав позволяет повторить недоступные пробы.';

  @override
  String inventoryMiB(String value) {
    return '$value МиБ';
  }

  @override
  String get inventoryPorts => 'Занятые порты';

  @override
  String get inventoryPortsHint =>
      'TCP-listener и привязанные UDP-сокеты в сетевом пространстве SSH-сеанса. Внешняя доступность, firewall и конфликты dual-stack не проверяются.';

  @override
  String get inventoryNoPorts => 'Сокеты не обнаружены';

  @override
  String get addServer => 'Добавить сервер';

  @override
  String get noServers => 'Серверов пока нет';

  @override
  String get noServersHelp =>
      'Нажмите + в правом верхнем углу, чтобы добавить сервер.';

  @override
  String get showPassword => 'Показать пароль';

  @override
  String get hidePassword => 'Скрыть пароль';

  @override
  String get migrateConnection => 'Перенести сохранённое подключение';

  @override
  String get migrateConnectionHelp =>
      'Введите прежний мастер-пароль один раз для переноса сохранённого подключения. После переноса оно будет открываться автоматически.';

  @override
  String get databaseOpenError =>
      'Не удалось открыть локальную БД. Сохранённые данные оставлены на месте.';

  @override
  String get settingsSaveError =>
      'Не удалось сохранить настройку. Повторите выбор.';

  @override
  String get draftSaveError =>
      'Не удалось сохранить шаблон на устройстве. Повторите сохранение до закрытия приложения.';

  @override
  String get draftSaving => 'Сохранение шаблона…';

  @override
  String get draftSaved => 'Шаблон сохранён на устройстве';

  @override
  String get sshJump => 'Jump SSH';

  @override
  String get sshDirect => 'Прямое подключение';

  @override
  String get sshJumpMissing => 'Сервер недоступен';

  @override
  String sshVia(String server) {
    return 'Через $server';
  }

  @override
  String get sshInvalidJump =>
      'Некорректный SSH-маршрут: сервер отсутствует или образовался цикл. Измените выбор jump-сервера.';

  @override
  String get sshJumpHostChanged =>
      'SSH-ключ промежуточного сервера изменился. Откройте его карточку и проверьте новый отпечаток перед подключением.';

  @override
  String get privilegesTitle => 'Административные права';

  @override
  String get privilegesUnknown =>
      'Административные права в этом сеансе ещё не проверены.';

  @override
  String get privilegesRoot =>
      'Подключение с правами root. Дополнительный пароль не нужен.';

  @override
  String get privilegesNoPassword => 'Проверка sudo прошла без пароля.';

  @override
  String get privilegesPassword => 'Проверка sudo прошла с паролем.';

  @override
  String get privilegesRequired =>
      'sudo требует пароль. Введите его ниже и повторите проверку.';

  @override
  String get privilegesAuthentication =>
      'sudo отклонил пароль. Проверьте его перед повторной попыткой.';

  @override
  String get privilegesDenied =>
      'Сервер запретил эту команду sudo. Возможно, у учётной записи недостаточно прав.';

  @override
  String get privilegesUnavailable => 'sudo недоступен на сервере.';

  @override
  String get privilegesTerminal =>
      'Политика sudo требует интерактивный терминал. Этот режим пока не поддерживается.';

  @override
  String get privilegesInvalidPassword =>
      'Допустимо не более 1024 символов, без переносов строк и NUL.';

  @override
  String get privilegesCheck => 'Подтвердить пароль';

  @override
  String get privilegesChecking => 'Проверка административных прав…';

  @override
  String get privilegesSudoPassword => 'Отдельный пароль sudo';

  @override
  String get privilegesSshPasswordHint =>
      'Оставьте пустым, чтобы использовать сохранённый SSH-пароль. Отдельный пароль сохраняется зашифрованным.';

  @override
  String get privilegesKeyPasswordHint =>
      'Введите пароль учётной записи, который требует sudo. Passphrase приватного ключа не используется. Пароль сохраняется зашифрованным.';

  @override
  String get privilegesScope =>
      'Введите пароль sudo для продолжения. При подтверждении он будет сохранён зашифрованным.';

  @override
  String get runnerTitle => 'Серверные задания';

  @override
  String get runnerHelp =>
      'Установка и проверочные задания выполняются на сервере. Их прогресс сохраняется после закрытия приложения и обрыва SSH.';

  @override
  String get runnerPrepare => 'Настроить серверные задания';

  @override
  String get runnerStart => 'Запустить проверку сервера';

  @override
  String get runnerPlanTitle => 'План изменений сервера';

  @override
  String get runnerPlanBody =>
      'Установить или восстановить встроенный исполнитель; известная предыдущая версия будет обновлена с сохранением журнала. Включить службу systemd с автозапуском и закрытый каталог заданий. Исполнителю нужны доступ к сети и запись в /usr/local и /etc для подтверждённых установок. Нужны Python 3.8+ с SQLite и systemd 235+. Обновление пакетов в этот план не входит.';

  @override
  String get runnerPlanRelease => 'SHA-256 сборки';

  @override
  String get runnerApply => 'Применить план';

  @override
  String get runnerNotNow => 'Не сейчас';

  @override
  String get runnerPending =>
      'Запрос сохранён локально; результат на сервере требует проверки.';

  @override
  String get runnerRetry => 'Проверить и повторить этот запрос';

  @override
  String get runnerReconnect => 'Переподключить исполнитель';

  @override
  String get runnerResend => 'Отправить снова';

  @override
  String get runnerConnectionLost =>
      'Связь потеряна. Задание на сервере может продолжать работу. Подключитесь для получения результата.';

  @override
  String get runnerNotRunning =>
      'Исполнитель не подтвердил работу. Обновите сведения или примените план настройки.';

  @override
  String get runnerCancelRequested =>
      'Отмена запрошена; ожидается безопасная точка остановки.';

  @override
  String get runnerCancel => 'Отменить серверное задание';

  @override
  String get runnerResetQueue => 'Сбросить зависшие операции';

  @override
  String get runnerResetQueueTitle => 'Сбросить очередь заданий?';

  @override
  String get runnerResetQueueHelp =>
      'Все задания этого сервера будут отменены, очередь очищена. Уже выполненные на сервере шаги не откатываются: после сброса проверьте состояние сервера.';

  @override
  String get runnerEventsTruncated =>
      'Старые события удалены при ротации на сервере. Текущая контрольная точка доступна.';

  @override
  String get runnerJournal => 'События задания';

  @override
  String get runnerHistory => 'Последние задания';

  @override
  String get runnerPrerequisites =>
      'Этому исполнителю нужны Ubuntu x86_64, работающий systemd 235+ и Python 3.8+ с SQLite. Изменения не применялись.';

  @override
  String get runnerConflict =>
      'Состояние сервера не соответствует плану или запросу. Обновите сведения перед продолжением.';

  @override
  String get runnerIncompatible =>
      'Установленная версия исполнителя несовместима с этой сборкой.';

  @override
  String runnerVersionDetails(String installed, String bundled) {
    return 'На сервере: $installed · В приложении: $bundled. Обновите приложение или сообщите эти номера.';
  }

  @override
  String get runnerInstallFailed =>
      'Настройка не подтверждена. Часть изменений могла примениться. Обновите сведения перед повтором.';

  @override
  String get runnerInvalidResponse =>
      'Исполнитель вернул некорректный ответ. Проверьте сохранённый результат перед повтором.';

  @override
  String get runnerUnavailable =>
      'Сервис заданий недоступен. Проверьте SSH-подключение и административный доступ.';

  @override
  String get runnerStorage =>
      'Не удалось сохранить или восстановить локальный журнал заданий. Проверьте хранилище перед повтором.';

  @override
  String get runnerBusy =>
      'На сервере уже выполняется задание. Дождитесь его завершения.';

  @override
  String get runnerProbeBusy =>
      'На сервере ещё идёт проверка подключения. Повторите через несколько минут.';

  @override
  String get runnerWaitingProbe =>
      'Ждём окончания проверки подключения на сервере…';

  @override
  String get runnerMissing => 'Этот запрос не найден на сервере.';

  @override
  String get runnerCapacity =>
      'Журнал серверных заданий достиг предельного размера.';

  @override
  String get runnerPlanned => 'В очереди';

  @override
  String get runnerRunning => 'Выполняется';

  @override
  String get runnerSucceeded => 'Завершено';

  @override
  String get runnerCancelled => 'Отменено';

  @override
  String get runnerFailed => 'Ошибка';

  @override
  String get runnerPartial => 'Применено частично';

  @override
  String get runnerAttention => 'Требуется проверка';

  @override
  String get runnerSample => 'Проверка сервера пройдена';

  @override
  String get runnerRecovered => 'Продолжено с сохранённой контрольной точки';

  @override
  String get runnerUpgradePreparing => 'Подготовка обновления...';

  @override
  String get runnerUpgradeDownloading => 'Скачивание пакета...';

  @override
  String get runnerUpgradeBackingUp => 'Создание резервной копии...';

  @override
  String get runnerUpgradeSyntaxChecking => 'Проверка бинарного файла...';

  @override
  String get runnerUpgradeSwitching => 'Переключение версии...';

  @override
  String get runnerUpgradeVerifying =>
      'Проверяем службу и настоящие подключения (до 1 мин)…';

  @override
  String get runnerUpgradeRollingBack => 'Выполняется откат...';

  @override
  String get runnerUpgradeCompleted => 'Обновление завершено';

  @override
  String get runnerUpgradeRolledBack => 'Откачено на предыдущую версию';

  @override
  String get runnerUpgradeSyntaxFailed => 'Ошибка валидации бинарного файла';

  @override
  String get runnerUpgradeHealthcheckFailed =>
      'Сбой проверки работы (выполнен откат)';

  @override
  String get runnerUpgradeAwaitingConfirmation =>
      'Подключения проверены · подтверждаем (без подтверждения через 5 минут — автоматический откат)';

  @override
  String get runnerUpgradeConfirmed => 'Обновление подтверждено';

  @override
  String get runnerUpgradeConnectivityFailed =>
      'После обновления перестали работать подключения — выполнен откат';

  @override
  String get runnerUpgradeChecksRequired =>
      'Для этого обновления нужны проверки подключений из приложения: обновите приложение и запустите обновление снова';

  @override
  String get runnerUpgradeChecksCoverage =>
      'Проверки охватывают не все включённые подключения';

  @override
  String get runnerUpgradeChecksChanged =>
      'Во время проверки изменились подключения или сеть устройства';

  @override
  String get runnerUpgradeChecksTimeout =>
      'Не хватило времени на проверку подключений';

  @override
  String get runnerUpgradeChecksFailed =>
      'После обновления подключения работают хуже, чем до него — возвращаем прежнюю версию';

  @override
  String get runnerUpgradeChecksPanelApi =>
      'После обновления приложение не может работать с 3x-ui';

  @override
  String get runnerUpgradeAwaitingChecks =>
      'Обновлено · проверяем подключения с устройства (без проверки — откат)';

  @override
  String get upgradeChecksBaseline =>
      'Проверяем подключения с этого устройства перед обновлением';

  @override
  String get upgradeChecksUpgrading => 'Обновляем на сервере';

  @override
  String get upgradeChecksComparison =>
      'Проверяем те же подключения после обновления';

  @override
  String get upgradeChecksRollingBack => 'Возвращаем прежнюю версию';

  @override
  String get upgradeChecksCommitted =>
      'Обновлено: подключения работают как прежде';

  @override
  String get upgradeChecksRolledBack => 'Прежняя версия возвращена';

  @override
  String get upgradeChecksFailed => 'Обновление не завершилось';

  @override
  String get upgradeChecksUnavailable =>
      'Проверки подключений на этом устройстве недоступны';

  @override
  String get upgradeChecksProblem => 'Подключение не прошло проверку';

  @override
  String get upgradeChecksStopTitle => 'Остановить обновление?';

  @override
  String get upgradeChecksStopHelp =>
      'Если обновление уже на сервере, вернётся прежняя версия. Подключения будут проверены снова.';

  @override
  String get runnerUpgradeDownloadMissing => 'Пакет не найден в релизе (404)';

  @override
  String get runnerUpgradeDownloadFailed => 'Сбой скачивания пакета';

  @override
  String get runnerUpgradeChecksumFailed => 'Несовпадение контрольной суммы';

  @override
  String get runnerUpgradeConflict => 'Конфликт состояния сервера';

  @override
  String get runnerUpgradeFailedGeneric => 'Ошибка обновления';

  @override
  String get runnerUpgradeInProgressGeneric => 'Выполняется обновление...';

  @override
  String get componentsInstall => 'Установить компоненты';

  @override
  String get componentsSelectionHelp =>
      'Установка отсутствующей панели и её Xray. TrustTunnel и AmneziaWG появятся в следующих стадиях.';

  @override
  String get componentsPort => 'Локальный порт панели';

  @override
  String get componentsPortHelp => 'Доступ только через SSH; это не порт VPN.';

  @override
  String get componentsPortInvalid => 'Введите порт от 1024 до 65535.';

  @override
  String get componentsPrepare => 'Подготовить план';

  @override
  String get componentsPlan => 'План установки 3x-ui / Xray';

  @override
  String get componentsExisting =>
      'Обнаружена существующая установка или не удалось исключить её наличие. Автоматическая переустановка недоступна; конфигурация сохранена.';

  @override
  String get componentsPrerequisites =>
      'Нужны Ubuntu x86_64, Python 3.8+ с SQLite, systemd 235+, nsenter, ca-certificates и 600 МиБ свободного места. Недостающие зависимости нужно подготовить отдельно.';

  @override
  String get componentsPortBusy =>
      'Порт панели занят. Выберите другой и подготовьте новый план.';

  @override
  String get componentsPlanBody =>
      'Будет загружен и проверен закреплённый архив, создана новая конфигурация и служба с автозапуском. Первоначальная настройка выполняется в изолированной сети; затем панель слушает только 127.0.0.1. Реквизиты создаются один раз, сервис подписок отключается.';

  @override
  String get componentsDependencies =>
      'Архив содержит Xray и геоданные. Обновление пакетов APT в этот план не входит.';

  @override
  String get componentsRunnerDependency =>
      'Исполнитель заданий будет установлен, восстановлен или обновлён с известной предыдущей версии. Ему потребуется доступ к сети и каталогам установки. Журнал заданий сохраняется.';

  @override
  String get componentsPanelAccess => 'Доступ к установленной панели';

  @override
  String get componentsAccessHelp =>
      'Реквизиты сохранены зашифрованными. Адрес доступен на сервере через SSH-туннель.';

  @override
  String get componentsPassword => 'Пароль панели';

  @override
  String get componentsHidePassword => 'Скрыть пароль';

  @override
  String get componentsShowPassword => 'Показать пароль';

  @override
  String componentsVerified(String time) {
    return 'API проверен через SSH: $time';
  }

  @override
  String get componentsVerifyApi => 'Проверить API через SSH';

  @override
  String get componentsJob => '3x-ui / Xray';

  @override
  String get componentsDownloaded => 'Архив загружен и проверен';

  @override
  String get componentsExtracted => 'Файлы установлены';

  @override
  String get componentsConfigured =>
      'Закрытая панель настроена, реквизиты созданы';

  @override
  String get componentsStarted => 'Служба запущена';

  @override
  String get componentsChecked =>
      'Версии, настройки и API проверены на сервере';

  @override
  String get componentsDownloadFailed =>
      'Ошибка загрузки архива. Установка не завершена.';

  @override
  String get componentsChecksumFailed =>
      'Контрольная сумма не совпадает. Архив не будет исполнен.';

  @override
  String get vpnRealityFingerprint =>
      'REALITY в текущем Xray принимает от клиентов Mihomo только Chrome, Firefox или Safari. С этим отпечатком клиенты Clash Meta и проверка приложения не подключатся; выберите один из них.';

  @override
  String get componentsArchiveInvalid =>
      'В архиве этого выпуска нет программ, которые устанавливает AntiRKN. Ничего не изменено; выберите другую версию.';

  @override
  String get componentsApiFailed =>
      'Не удалось подтвердить работу панели. Проверьте журнал и состояние службы.';

  @override
  String get componentsPartial =>
      'Операция остановлена после применения части изменений. Созданные файлы сохранены; это не откат установки.';

  @override
  String get componentsResume => 'Продолжить установку';

  @override
  String get componentsResumePlan =>
      'Будет продолжено то же задание с сохранённого этапа. Проверенные файлы повторно используются, реквизиты сохраняются. Перед изменениями проверяется принадлежность ресурсов; конфликт останавливает продолжение.';

  @override
  String get componentsDownloading => 'Загрузка архива';

  @override
  String get componentsExtracting => 'Распаковка и проверка файлов';

  @override
  String get componentsConfiguring => 'Настройка панели в изолированной сети';

  @override
  String get componentsStarting => 'Запуск службы';

  @override
  String get componentsChecking => 'Проверка состояния и API';

  @override
  String get componentsBuilding => 'Сборка исполняемых файлов на сервере';

  @override
  String get componentsPlanSummary =>
      'Установить панель и Xray с автозапуском. Доступ к панели — через SSH.';

  @override
  String get componentsRunnerSummary =>
      'Также будет настроен сервис серверных заданий.';

  @override
  String get componentsDetails => 'Подробности';

  @override
  String get componentsEditPlan => 'Изменить';

  @override
  String get vpnUsers => 'Клиенты';

  @override
  String get vpnUsersHelp =>
      'Создайте клиента один раз. AntiRKN подготовит ему персональные доступы ко всем настроенным управляемым inbounds на всех серверах.';

  @override
  String get vpnAddUser => 'Добавить клиента';

  @override
  String get vpnSortBy => 'Сортировка';

  @override
  String get vpnSortByName => 'По имени';

  @override
  String get vpnSortByDate => 'По дате создания';

  @override
  String get vpnSortAscending => 'По возрастанию';

  @override
  String get vpnSortDescending => 'По убыванию';

  @override
  String get vpnDisabledClients => 'Отключенные клиенты';

  @override
  String get vpnSyncAndPublish => 'Выгрузить проверенные профили';

  @override
  String vpnSyncAndPublishDone(int published, int total) {
    return 'Выгружено профилей на Диск: $published из $total';
  }

  @override
  String vpnSyncAndPublishUpToDate(int total) {
    return 'Все профили на Диске уже актуальны ($total).';
  }

  @override
  String vpnSyncAndPublishPartial(int uploaded, int total, int upToDate) {
    return 'Выгружено $uploaded из $total ($upToDate уже актуально).';
  }

  @override
  String vpnSyncAndPublishWithErrors(int uploaded, int failed, int total) {
    return 'Выгружено $uploaded, ошибок $failed из $total.';
  }

  @override
  String get vpnSyncAndPublishTooltip =>
      'Нажмите для выгрузки из последнего проверенного состояния; при локальных изменениях серверы будут сверены. Удерживайте для полной сверки серверов и проверки всех файлов на Диске.';

  @override
  String get vpnSyncServerUnverified =>
      'Не удалось проверить сервер. Текущие профили не выгружены; прежние проверенные ссылки доступны.';

  @override
  String get publicationPreviousVerified =>
      'Текущий профиль не проверен. Прежняя проверенная ссылка доступна.';

  @override
  String get vpnSyncAndPublishFailed =>
      'Не удалось полностью синхронизировать данные с серверами или выгрузить на Диск.';

  @override
  String get vpnNoUsers => 'Клиентов пока нет';

  @override
  String get vpnLogin => 'Логин клиента';

  @override
  String get vpnName => 'Отображаемое имя';

  @override
  String get vpnEnabled => 'Включён';

  @override
  String get vpnDisabled => 'Отключён';

  @override
  String get vpnSave => 'Сохранить';

  @override
  String get vpnInbounds => 'VLESS';

  @override
  String get vpnAddInbound => 'Добавить inbound';

  @override
  String get vpnInboundHelp =>
      'Каждый клиент получает персональный доступ к включённым inbounds с открытым замочком. Закройте замочек для внутренних нужд.';

  @override
  String get vpnNoInbounds => 'На этом сервере нет inbounds';

  @override
  String get vpnTransport => 'Транспорт';

  @override
  String get vpnSecurity => 'Защита';

  @override
  String get vpnListen => 'Адрес прослушивания';

  @override
  String get vpnPort => 'Порт прослушивания';

  @override
  String get vpnEndpoint => 'Адрес inbound (IP или домен)';

  @override
  String get vpnExternalPort => 'Порт подключения к inbound';

  @override
  String get vpnSni => 'Имя сервера (SNI)';

  @override
  String get vpnTarget => 'REALITY target (хост:порт)';

  @override
  String get vpnPath => 'Путь XHTTP';

  @override
  String get vpnHost => 'Host XHTTP (необязательно)';

  @override
  String get vpnMode => 'Режим XHTTP';

  @override
  String get vpnCertificate => 'Файл цепочки сертификата на сервере';

  @override
  String get vpnCertificateKey =>
      'Файл приватного ключа сертификата на сервере';

  @override
  String get vpnTlsHelp =>
      'Используйте существующий сертификат для домена SNI. Выпуск и продление сертификатов — отдельные задачи.';

  @override
  String get vpnRegion => 'Добавить явную метку RU для фильтров шаблона';

  @override
  String get vpnDeleteInbound => 'Удалить inbound и его клиентские доступы';

  @override
  String get vpnDeleteHelp =>
      'Следующий план удалит этот inbound и осиротевшие записи клиентов на сервере. Клиенты в приложении сохранятся.';

  @override
  String get vpnPlan => 'План клиентских доступов';

  @override
  String get vpnPlanHelp =>
      'Применить перечисленные inbounds и персональные доступы через 3x-ui. На каждом сервере сохраняется закрытая резервная копия конфигурации. В конце Xray перезапускается; соединения могут ненадолго прерваться. Реквизиты существующих клиентов сохраняются.';

  @override
  String get vpnPrepare => 'Подготовить план доступов';

  @override
  String get vpnApply => 'Применить план на всех указанных серверах';

  @override
  String get vpnPending =>
      'Изменения доступов ожидают выполнения на одном или нескольких серверах. Полный актуальный профиль пока не готов.';

  @override
  String get vpnPendingReadback => 'Сервер ещё не подтвердил этот ресурс.';

  @override
  String get vpnPendingSettings =>
      'Сервер вернул другие настройки этого ресурса.';

  @override
  String get vpnPendingClient =>
      'Клиент отсутствует в подтверждённом состоянии сервера.';

  @override
  String get vpnPendingIdentity =>
      'Перед выдачей доступа нужно проверить сохранённую идентичность сервера.';

  @override
  String get vpnPendingReview =>
      'Управляемый ресурс на сервере изменился и требует проверки.';

  @override
  String get vpnPendingResource =>
      'Ресурс доступа больше не найден в текущей конфигурации.';

  @override
  String get vpnProfile => 'Персональный профиль Mihomo';

  @override
  String get vpnShowProfile => 'Показать профиль и реквизиты клиента';

  @override
  String get vpnSaveProfile => 'Сохранить YAML';

  @override
  String get vpnCopyProfile => 'Копировать YAML';

  @override
  String get vpnProfileSaved => 'Профиль сохранён';

  @override
  String get vpnProfileValidation =>
      'На этом экране выполнена структурная проверка. Проверки пресетов ядром и сетевые испытания описаны отдельно.';

  @override
  String get vpnLastProfile =>
      'Текущий профиль пока не готов. Последняя корректная версия сохранена.';

  @override
  String get vpnPreviousProfileLink =>
      'Этот QR по-прежнему ведёт на последний проверенный профиль и не содержит ожидающие изменения.';

  @override
  String get vpnRegenerateProfile =>
      'Перепроверить серверы и перегенерировать профиль';

  @override
  String get vpnRegeneratingProfile =>
      'Перепроверяем серверы и перегенерируем профиль…';

  @override
  String get vpnProfileRegenerated =>
      'Состояние серверов перепроверено, актуальный профиль перегенерирован.';

  @override
  String get vpnInvalid =>
      'Проверьте имена, адреса, порты и выбранное сочетание транспорта и защиты.';

  @override
  String get vpnDuplicate =>
      'Логины клиентов и идентификаторы ресурсов должны быть уникальными.';

  @override
  String get vpnConflict =>
      'Конфигурация сервера изменилась. Обновите сведения и разберите конфликт перед повторным применением.';

  @override
  String get vpnConnection =>
      'Подключитесь к этому серверу в разделе серверов. Ожидающие изменения доступов сохранены.';

  @override
  String get vpnPanelRequired =>
      'Подключитесь к серверу для загрузки панели и inbounds. Для управления клиентами нужен доступ к API панели.';

  @override
  String get vpnRunnerNotReady =>
      'Служба на сервере требует обновления. Откройте сервер, чтобы обновить её.';

  @override
  String get vpnPanelLogin =>
      'Войдите в 3x-ui на этом сервере, чтобы продолжить.';

  @override
  String get vpnDeletionOtherDevice =>
      'Клиента удаляет другое устройство. Откройте подробности, чтобы продолжить на этом устройстве.';

  @override
  String get vpnRestoreReview =>
      'Восстановлено из резервной копии. Откройте подробности, чтобы продолжить.';

  @override
  String get vpnWaitingRemoval =>
      'Ожидает завершения удаления клиента на этом сервере.';

  @override
  String get vpnServiceMode =>
      'Сервер в сервисном режиме: новые клиенты на него не добавляются до возвращения.';

  @override
  String get vpnServiceModeOtherDevice =>
      'Сервер возвращает из сервисного режима другое устройство. Повторите возврат здесь, чтобы продолжить на этом устройстве.';

  @override
  String get vpnStorage =>
      'Не удалось сохранить зашифрованную базу клиентов. Устраните ошибку хранилища и повторите.';

  @override
  String get vpnStorageConflict =>
      'Другой экземпляр приложения изменил базу клиентов. Загрузите её заново перед редактированием.';

  @override
  String get vpnIdentity =>
      'Адрес или SSH-идентичность сохранённого сервера изменились. Прежние привязки доступов требуют проверки.';

  @override
  String get vpnFailed =>
      'Операция не подтверждена. Обновите состояние сервера или повторите сохранённую операцию.';

  @override
  String get vpnBusy =>
      'Выполняется другая операция, поэтому изменение не внесено. Повторите, когда она завершится.';

  @override
  String get vpnPortBusy =>
      'Адрес или порт прослушивания недоступен либо конфликтует с другим inbound.';

  @override
  String get vpnPartial =>
      'Часть изменений могла примениться. Проверьте сохранённое задание и продолжите его, когда будете готовы.';

  @override
  String get vpnApplying => 'Применение клиентских доступов';

  @override
  String get vpnChecking => 'Проверка применённой конфигурации';

  @override
  String get vpnPrepareStep =>
      'Проверка предусловий и сохранение резервной копии';

  @override
  String get vpnEdit => 'Изменить';

  @override
  String get vpnRefreshProfiles => 'Пересобрать профили';

  @override
  String get vpnSnapshot => 'Последняя проверка';

  @override
  String get vpnChanged => 'Изменения ожидают подтверждения';

  @override
  String get vpnEmptyTemplate => 'Выберите базовый YAML в настройках.';

  @override
  String get vpnNoAccess =>
      'Для этого клиента пока нет настроенных активных inbounds.';

  @override
  String get protocolSoftware => 'Обновления компонентов';

  @override
  String get protocolExisting =>
      'Обнаружена существующая установка или изменённые файлы. Автоматическое принятие под управление недоступно.';

  @override
  String get protocolCurrent =>
      'Установлена проверенная версия этой сборки приложения.';

  @override
  String get protocolInstallPlan =>
      'Установить выбранный серверный компонент и проверить исполняемые файлы.';

  @override
  String get protocolUpdatePlan =>
      'Заменить исполняемые файлы. Предыдущая версия сохранится для восстановления; конфигурации и ключи сохраняются.';

  @override
  String get protocolConfigurationSeparate =>
      'Установка ПО не создаёт VPN-подключение. Endpoint, сертификаты и peers настраиваются отдельным шагом.';

  @override
  String get protocolGoDependency =>
      'Зависимости: Go 1.26.8 и исходники AWG с проверкой SHA-256; модули Go — с проверкой go.sum. Сборка на сервере, не менее 2000 МиБ свободного места.';

  @override
  String get protocolPrepared => 'План проверен';

  @override
  String get protocolBuilt => 'Исполняемые файлы готовы';

  @override
  String get protocolStaged => 'Новая версия подготовлена';

  @override
  String get protocolSwitched => 'Новая версия установлена';

  @override
  String get protocolBuildFailed =>
      'Сборка AmneziaWG не завершилась. Проверьте доступ к Go modules, память и место на сервере.';

  @override
  String get protocolCheckFailed =>
      'Проверка установленной версии не пройдена.';

  @override
  String get updatesCheck => 'Проверить обновления';

  @override
  String get updatesCheckedRecently =>
      'Обновления проверены только что, показан актуальный результат.';

  @override
  String get updatesAutomatic => 'Проверять новые версии';

  @override
  String get updatesSuggestions => 'Предлагать обновления';

  @override
  String get updatesFailed =>
      'Не удалось проверить обновления. Предыдущий результат может быть устаревшим.';

  @override
  String updatesChecked(String date) {
    return 'Успешная проверка: $date';
  }

  @override
  String get updatesLatest => 'новая версия в источнике';

  @override
  String get updatesCompatibility =>
      'Новая версия пока не прошла проверку совместимости.';

  @override
  String updatesAvailable(String component, String current, String latest) {
    return '$component: доступно обновление $current → $latest.';
  }

  @override
  String protocolRestart(String services) {
    return 'Перезапустятся службы: $services. Соединения могут прерваться. Резервная копия конфигурации остаётся в журнале задания.';
  }

  @override
  String get protocolPrerequisites =>
      'Для установки нужны Ubuntu x86_64, Python 3.8+/SQLite, systemd 235+ и ca-certificates. Свободное место: TrustTunnel — 150 МиБ; AmneziaWG — 2000 МиБ и доступный /dev/net/tun.';

  @override
  String get componentManage => 'Управление / обновление';

  @override
  String get panelObservedHelp =>
      'Обнаружена существующая панель. Её inbounds показаны ниже; настройки панели и существующие клиенты сохранены.';

  @override
  String get panelDiscoveryFailed =>
      'Часть настроек панели прочитать не удалось. Обновите данные для повторной попытки.';

  @override
  String get vpnInternal => 'Для внутренних нужд';

  @override
  String get vpnClientAccess => 'Выдавать клиентам';

  @override
  String get vpnObserved => 'Существующий · вне управления клиентами';

  @override
  String get vpnPendingDeletion => 'Удаляется · ждём подтверждения сервера';

  @override
  String get vpnObservedHelp =>
      'Существующие настройки и клиенты сохранены. Этот inbound не выдаётся клиентам AntiRKN.';

  @override
  String get panelCliHelp =>
      'Установить официальную команду x-ui из 3x-ui 3.7.0. Настройки панели, клиенты и служба сохраняются.';

  @override
  String get panelCliInstall => 'Установить меню управления x-ui';

  @override
  String get panelInstallMethod =>
      'Официальный архив релиза GitHub и меню x-ui.sh. AntiRKN устанавливает и настраивает их по шагам с восстановлением; upstream install.sh не запускается.';

  @override
  String get vpnConnectionAddress => 'Адрес подключения к inbound';

  @override
  String get vpnConnectionAddressHelp =>
      'По умолчанию используются адрес сервера и порт прослушивания. Измените их, если inbound доступен по другому адресу или порту (NAT / обратный прокси).';

  @override
  String get xhttpAdvanced => 'Настройки XHTTP';

  @override
  String get xhttpDefault => 'По умолчанию (оставьте пустым)';

  @override
  String get xmuxHelp =>
      'Параметры повторного использования соединений для клиентских профилей этого inbound. maxConcurrency и maxConnections нельзя одновременно задавать больше нуля. Диапазоны: минимум-максимум.';

  @override
  String get xhttpHeaders => 'HTTP-заголовки';

  @override
  String get vpnRegenerateReality => 'Пересоздать ключи';

  @override
  String get vpnRealityRegenerated =>
      'Новые ключи REALITY и Short ID применятся вместе с планом. Клиентские профили будут пересобраны.';

  @override
  String get vpnRealityKeyPlan =>
      'Применить выбранную ревизию ключей REALITY и пересобрать клиентские профили.';

  @override
  String get realityScan => 'Проверить Target';

  @override
  String get realityScanHelp =>
      'Проверка TLS и сертификата с этого сервера через 3x-ui. SNI заполняется из Target, пока вы не измените его вручную.';

  @override
  String get realityScanFailed =>
      'Не удалось проверить Target. Подключитесь к серверу и проверьте доступ к панели.';

  @override
  String get realityFeasible => 'Подходит для REALITY';

  @override
  String get realityNotFeasible => 'Не подходит для REALITY';

  @override
  String get realityScanPrivate => 'Target указывает на внутренний адрес.';

  @override
  String get realityScanTls => 'Не удалось согласовать TLS 1.3.';

  @override
  String get realityScanH2 => 'Не удалось согласовать HTTP/2 (h2).';

  @override
  String get realityScanCurve => 'Не удалось согласовать обмен ключами X25519.';

  @override
  String get realityScanCertificate =>
      'Сертификат не подходит для этого SNI или не является доверенным.';

  @override
  String get realityScanUnavailable => 'Target не завершил TLS-соединение.';

  @override
  String get realitySniUsed => 'Использованный SNI';

  @override
  String get realityCertificate => 'Сертификат';

  @override
  String get realityCertificateExpiry => 'Сертификат действует до';

  @override
  String get realityKeyExchange => 'Обмен ключами';

  @override
  String get realityLatency => 'Задержка, мс';

  @override
  String get realityCertificateNames =>
      'Имена из сертификата — выберите SNI и повторите проверку';

  @override
  String get softwareTitle => 'Компоненты сервера';

  @override
  String get softwareInstall => 'Установить';

  @override
  String get softwareInspect => 'Проверить наличие';

  @override
  String get softwarePreparing => 'Подготовка…';

  @override
  String get softwareStop => 'Остановить';

  @override
  String get softwareFailed =>
      'Обновление не завершено. Повтор проверит, что уже сделано на сервере.';

  @override
  String get softwareUpdate => 'Обновить';

  @override
  String get softwareUpdateAvailable => 'Доступно обновление';

  @override
  String get softwarePanelAccess => 'Доступ к панели';

  @override
  String get panelAutomaticAddress =>
      'Свободный порт и случайный путь панели выбираются автоматически.';

  @override
  String get panelUpdateManual =>
      'Новая версия обнаружена. Применение обновлений 3x-ui/Xray из приложения пока недоступно; обновить их можно через команду x-ui на сервере.';

  @override
  String get aptNotChecked => 'Не проверено';

  @override
  String get aptUpToDate => 'Обновлений нет';

  @override
  String get aptRestartRequired => 'Нужна перезагрузка';

  @override
  String get aptPackages => 'Пакеты';

  @override
  String get aptTitle => 'Обновления Ubuntu';

  @override
  String get aptUpdate => 'Обновить индексы APT';

  @override
  String get aptUpgrade => 'Обновить пакеты';

  @override
  String get aptUpdatePlan =>
      'Обновить списки доступных пакетов (apt update). Установленные пакеты пока не изменятся.';

  @override
  String get aptUpgradePlan =>
      'Обновить перечисленные пакеты по текущим индексам APT. Сохранить локальные конфиги. Пакеты не удаляются; установка новых зависимостей и перезагрузка выполняются отдельно. Службы могут перезапуститься.';

  @override
  String get aptCurrent =>
      'По текущим индексам обновлений нет. Для свежей проверки обновите индексы APT.';

  @override
  String aptPackageCount(int count) {
    return 'Пакетов к обновлению: $count';
  }

  @override
  String get aptReboot =>
      'Серверу требуется перезагрузка. Выполните её в удобное время.';

  @override
  String get aptUpdating => 'Обновление индексов APT…';

  @override
  String get aptUpgrading => 'Обновление пакетов Ubuntu…';

  @override
  String get aptFailed =>
      'APT не завершил команду. Проверьте доступность репозиториев, свободное место и блокировку пакетного менеджера, затем подготовьте новый план.';

  @override
  String get aptConflict =>
      'Состав пакетов изменился. Подготовьте новый план обновления.';

  @override
  String get aptInterrupted =>
      'Обновление могло примениться частично. Проверьте состояние APT на сервере перед новым планом; прерванная команда автоматически не повторяется.';

  @override
  String get serverDetails => 'Сведения о сервере и сети';

  @override
  String get panelConnectTitle => 'Войти в 3x-ui';

  @override
  String get panelAuthFailed =>
      '3x-ui отклонила логин или пароль панели. Проверьте учётную запись панели; данные SSH используются отдельно.';

  @override
  String get panelUnreachable =>
      'Не удалось подключиться к API панели. Проверьте работу x-ui, адрес прослушивания и сертификат HTTPS.';

  @override
  String get panelConnectUnsupported =>
      'Не удалось однозначно определить systemd-панель на этом порту. Подключение к API Docker-панелей пока не поддерживается.';

  @override
  String get panelLoginLimited =>
      '3x-ui временно ограничила попытки входа. Подождите перед повторной попыткой.';

  @override
  String get panelUsername => 'Логин панели';

  @override
  String get panelConnectHelp =>
      'Введите учётную запись администратора 3x-ui для просмотра и редактирования через API. Доступ сохранится для следующих подключений.';

  @override
  String get observedClientsKept =>
      'Существующие клиенты и параметры вне плана сохраняются.';

  @override
  String get observedFullConfig => 'Полная конфигурация';

  @override
  String get observedEditPlan =>
      'Сохранить изменения существующего inbound и перезапустить Xray. Активные подключения могут прерваться.';

  @override
  String get componentUpdateUnverified =>
      'Новая версия ещё не включена в проверенный набор приложения. Установленная версия сохранена.';

  @override
  String get observedTransportJson => 'Настройки транспорта (JSON)';

  @override
  String get observedTransportInvalid =>
      'JSON некорректен: нужен объект, realitySettings и xhttpSettings — тоже объекты. Исправьте его, чтобы сохранить или вернуться к полям.';

  @override
  String get panelUpdateSummary =>
      'Сохраним настройки и клиентов, создадим резервную копию и обновим 3x-ui вместе с Xray. Во время перезапуска VPN-соединения ненадолго прервутся.';

  @override
  String get panelUpdateRecovery =>
      'При ошибке резервная копия остаётся на сервере. Продолжение проверит уже заменённые файлы. Автоматический откат базы не выполняется.';

  @override
  String get panelUpdateCompatibility =>
      'Обновление доступно для проверенных версий стандартной установки 3x-ui с systemd и SQLite. Более новые ядра Xray не понижаются.';

  @override
  String get panelUpdatePreparing => 'Проверка установленной панели';

  @override
  String get panelUpdateBackup => 'Сохранение резервной копии и проверка Xray';

  @override
  String get panelUpdateSwitching => 'Обновление 3x-ui и Xray, перезапуск';

  @override
  String get panelLoginOnce =>
      'Войдите в 3x-ui. Логин и пароль сохранятся для следующих подключений.';

  @override
  String get panelLoginRequiredFields => 'Введите логин и пароль панели.';

  @override
  String get panelUpdateCoreCompatibility =>
      'Xray 26.9.8/26.9.9 несовместим с REALITY-профилями проверенного Mihomo. Используем совместимое ядро 26.7.28; если оно уже установлено, его версия сохранится.';

  @override
  String get awgAdd => 'Добавить интерфейс';

  @override
  String get awgRefresh => 'Обновить состояние';

  @override
  String get awgEmpty => 'Управляемых AWG-интерфейсов пока нет.';

  @override
  String get awgConfirmed => 'Конфигурация подтверждена на сервере';

  @override
  String get awgHandshake => 'Последний handshake';

  @override
  String get awgNoHandshake => 'Клиент ещё не подключался';

  @override
  String get awgEndpoint => 'IP или домен для подключения';

  @override
  String get awgPort => 'UDP-порт';

  @override
  String get awgExternalPort => 'Внешний UDP-порт (NAT)';

  @override
  String get awgAdvanced => 'Дополнительные настройки';

  @override
  String get awgPool => 'IPv4-пул клиентов (CIDR)';

  @override
  String get awgPool6 => 'IPv6-пул ULA /64 (необязательно)';

  @override
  String get awgDefaultsHelp =>
      'Значения по умолчанию основаны на AmneziaVPN 3.1. Ключи и адреса клиентов создаются автоматически и сохраняются при пересборке профиля. При RandomTrailers значения S1–S4 должны совпадать.';

  @override
  String get awgCps => 'Начальный пакет маскировки I1';

  @override
  String get awgNetworkPlan =>
      'План включит IP forwarding, правила входящего UDP, пересылки и NAT для этого интерфейса. Изменение общих настроек обновит профили всех клиентов; возможен краткий перерыв соединений.';

  @override
  String get awgPrerequisites =>
      'Для нового интерфейса установите управляемую AmneziaWG. Также нужны TUN, iptables/ip6tables и права администратора.';

  @override
  String get awgPoolConflict =>
      'Пул пересекается с существующим маршрутом или интерфейсом. Выберите другой диапазон.';

  @override
  String get awgPoolFull =>
      'В пуле недостаточно свободных адресов для клиентов.';

  @override
  String get awgObserved => 'Существующие установки';

  @override
  String get awgPeersPreserved =>
      'Существующие peers, ключи и незатронутые поля будут сохранены. После смены общих параметров обновите ранее выданные клиентские конфигурации.';

  @override
  String get awgExternalUnsupported =>
      'Просмотр доступен. Для изменения этой установки пока нет проверенного адаптера.';

  @override
  String get awgDockerPortHelp =>
      'Порт опубликован Docker и сохраняется при редактировании. Его перенос требует отдельного пересоздания контейнера с новым сопоставлением портов.';

  @override
  String get ttAdd => 'Добавить endpoint';

  @override
  String get ttEmpty => 'Управляемых endpoint TrustTunnel пока нет.';

  @override
  String get ttPort => 'Порт прослушивания';

  @override
  String get ttExternalPort => 'Порт подключения (внешний порт при NAT)';

  @override
  String get ttDomain => 'TLS-домен (SNI)';

  @override
  String get ttOutbound => 'Выход в интернет';

  @override
  String get ttDirect => 'Напрямую';

  @override
  String get ttSocksAddress => 'Адрес и порт SOCKS5';

  @override
  String get ttSocksHelp =>
      'Например, 127.0.0.1:1080 на этом сервере. Поддерживается локальный SOCKS5 без авторизации; для UDP нужна его поддержка в SOCKS5 и дальнейшем маршруте.';

  @override
  String get ttIpv6 => 'Разрешить выход по IPv6';

  @override
  String get ttAllowPrivate => 'Разрешить доступ к внутренним сетям';

  @override
  String get ttRotate => 'Заменить пароли всех клиентов этого endpoint';

  @override
  String get ttRegeneratePasswords => 'Пересоздать пароли';

  @override
  String get ttPasswordsRegenerated =>
      'Новые пароли для всех клиентов применятся вместе с планом. Клиентские профили будут пересобраны.';

  @override
  String get ttCertificates => 'TLS-сертификаты';

  @override
  String get ttAddCertificate => 'Добавить или выпустить сертификат';

  @override
  String get ttCertificateSource => 'Источник сертификата';

  @override
  String get ttServerFiles => 'Готовые файлы на сервере';

  @override
  String get ttImportPem => 'Импорт файлов PEM';

  @override
  String get ttIssueAcme => 'Выпустить через ACME HTTP-01';

  @override
  String get ttFilesHelp =>
      'Выберите найденные файлы или укажите пути на сервере. Продлением продолжит заниматься существующая служба; AntiRKN проверит изменения и перезапустит связанные сервисы TrustTunnel.';

  @override
  String get ttImportHelp =>
      'Выберите полную цепочку сертификата и приватный ключ. Файлы будут защищённо скопированы на сервер. После продления потребуется импорт новых файлов.';

  @override
  String get ttExpectedIps => 'IP домена для проверки, через запятую';

  @override
  String get ttAcmeEmail => 'Email для регистрации ACME';

  @override
  String get ttAcmeHelp =>
      'IP сервера определятся автоматически. Домен должен указывать на этот сервер, а TCP-порт 80 — быть доступен из интернета. После подтверждения будет выпущен сертификат Let’s Encrypt и включено автоматическое продление. Email не требуется.';

  @override
  String get ttExpiry => 'Действует до';

  @override
  String get ttLastSuccess => 'Последняя успешная проверка';

  @override
  String get ttNextCheck => 'Следующая проверка';

  @override
  String get ttExpirySoon => 'До истечения сертификата осталось меньше 21 дня.';

  @override
  String get ttRenewAcme => 'Автопродление через Certbot';

  @override
  String get ttRenewExternal => 'Продлевает существующая служба';

  @override
  String get ttRenewImport => 'Обновление импортом новых файлов';

  @override
  String get ttRestartPlan =>
      'После изменения сертификата или конфигурации — перезапуск TrustTunnel и проверка сервиса. Возможен краткий обрыв активных подключений.';

  @override
  String get ttDnsChecked => 'DNS совпадает с выбранными IP';

  @override
  String get ttCertbotPresent => 'Установленный Certbot';

  @override
  String get ttCertbotInstall => 'Установить Certbot и необходимые зависимости';

  @override
  String get ttPreserveUsers =>
      'Существующие пользователи, пароли и незатронутые поля конфигурации сохраняются.';

  @override
  String get ttKeepCertificate => 'Оставить существующий сертификат';

  @override
  String get ttChooseCertificate => 'Выберите сертификат';

  @override
  String get ttNeedCertificate =>
      'Выберите готовый сертификат или выпустите новый по введённому SNI.';

  @override
  String get ttCertificatePending =>
      'Выпуск сертификата отправлен на сервер. После успешного завершения сертификат будет выбран автоматически.';

  @override
  String get ttPrerequisites =>
      'Сначала установите проверенную версию TrustTunnel.';

  @override
  String get ttUnsupported =>
      'Эта установка или конфигурация TrustTunnel не поддерживается редактором.';

  @override
  String get ttSocksFailed =>
      'SOCKS5 не принял подключение без авторизации. Проверьте адрес, порт и настройки.';

  @override
  String get ttCertInvalid =>
      'Сертификат не прошёл проверку: проверьте домен, срок, полную цепочку и соответствие приватного ключа.';

  @override
  String get ttRestartFailed =>
      'TrustTunnel не запустился с ожидаемым сертификатом. Прежний сертификат восстановлен, если он был; проверьте состояние сервера.';

  @override
  String get ttDnsFailed => 'Не удалось получить A/AAAA-записи домена.';

  @override
  String get ttDnsMismatch =>
      'Домен указывает на другой IP. Настройте его A/AAAA-записи на IP этого сервера и повторите проверку.';

  @override
  String get ttAcmePortBusy =>
      'TCP-порт 80 занят. Выпуск HTTP-01 в режиме standalone невозможен.';

  @override
  String get ttCertbotRequired =>
      'Certbot не удалось установить после обновления индексов APT. Проверьте репозитории Ubuntu и повторите запрос.';

  @override
  String get ttAcmeFailed =>
      'Выпуск или продление ACME завершились ошибкой. Проверьте публичный DNS, доступность порта 80 и журнал ACME на сервере.';

  @override
  String get backupTitle => 'Резервные копии';

  @override
  String get backupHelp =>
      'Сохраните серверы, клиентов, ключи, шаблоны и историю изменений в зашифрованный файл для восстановления на другой установке.';

  @override
  String get backupExport => 'Резервная копия';

  @override
  String get backupImport => 'Восстановить';

  @override
  String get backupPassword => 'Пароль резервной копии';

  @override
  String get backupRepeat => 'Повторите пароль';

  @override
  String get backupPasswordHelp =>
      'Отдельный пароль от 12 символов. Для восстановления нужны файл и этот пароль. Приложение пароль не сохраняет.';

  @override
  String get backupPasswordMismatch =>
      'Введите пароль от 12 символов; при создании оба поля должны совпадать.';

  @override
  String get backupShowPassword => 'Показать пароль';

  @override
  String get backupHidePassword => 'Скрыть пароль';

  @override
  String get backupInvalid =>
      'Неверный пароль или повреждённая резервная копия. Данные не заменены.';

  @override
  String get backupVersion =>
      'Версия резервной копии не поддерживается этой сборкой.';

  @override
  String get backupTooLarge => 'Размер резервной копии превышает 64 МиБ.';

  @override
  String get backupChanged =>
      'После просмотра данные изменились. Выберите копию повторно и проверьте её состав.';

  @override
  String get backupStorage =>
      'Не удалось прочитать или записать хранилище. Восстановление не применено.';

  @override
  String get backupFileError =>
      'Не удалось прочитать или сохранить файл. Проверьте доступ и повторите.';

  @override
  String get backupWorking => 'Обработка резервной копии…';

  @override
  String get backupSaved => 'Зашифрованная резервная копия сохранена.';

  @override
  String backupSummary(String date, int servers, int users) {
    return 'Создана: $date\nСерверов: $servers\nКлиентов: $users';
  }

  @override
  String get backupReplaceHelp =>
      'Текущие серверы, клиенты и шаблоны будут заменены содержимым копии. Сначала сохраните отдельную копию текущих данных, если они нужны. SSH-соединения закроются. Приложение откроет восстановленное хранилище; незавершённые VPN-операции потребуют нового решения. Личные настройки этого устройства сохранятся.';

  @override
  String get backupActiveWork =>
      'Дождитесь завершения текущей операции или сохранения данных, затем повторите.';

  @override
  String get backupClose => 'Закрыть';

  @override
  String get backupCancel => 'Отмена';

  @override
  String get backupReplace => 'Заменить и восстановить';

  @override
  String get backupSelect => 'Выбрать файл';

  @override
  String get backupOperationReview =>
      'Операция получена с другого устройства или восстановлена из резервной копии и автоматически не отправляется. Проверьте сервер и подтвердите новый план либо выберите отмену или повтор существующего задания.';

  @override
  String get backupReviewServer => 'Проверить состояние сервера';

  @override
  String get syncEffectsBlocked =>
      'Сначала разрешите конфликты изменений в настройках. Серверные действия и выдача профилей приостановлены.';

  @override
  String get googleAccountHelp =>
      'Войдите в Google для синхронизации устройств.';

  @override
  String get googleSignIn => 'Войти в Google';

  @override
  String get googleSwitchAccount => 'Сменить аккаунт';

  @override
  String get googleSignOut => 'Выйти';

  @override
  String get googleWorking => 'Подключение к Google…';

  @override
  String get googleConfigurationError =>
      'Google-вход не настроен для этой сборки. Проверьте Android-клиент и сертификат приложения.';

  @override
  String get googleDenied =>
      'Доступ к Google Drive не предоставлен. Повторите вход и разрешите доступ.';

  @override
  String get googleNetworkError =>
      'Не удалось связаться с Google. Проверьте подключение и повторите вход.';

  @override
  String get googleStorageError =>
      'Не удалось сохранить данные аккаунта в защищённом хранилище. Повторите попытку.';

  @override
  String get googleReauthorize => 'Нужно снова войти в Google.';

  @override
  String get googleUnavailable =>
      'Вход Google недоступен. Проверьте Google Play services и повторите попытку.';

  @override
  String get autoSyncTitle => 'Автосинхронизация';

  @override
  String get autoSyncDisabled => 'Автосинхронизация выключена.';

  @override
  String get autoSyncWaiting => 'Ожидание синхронизации';

  @override
  String get autoSyncWorking => 'Обмен с Google Drive…';

  @override
  String get autoSyncDone => 'Синхронизировано';

  @override
  String get autoSyncEditing =>
      'Новая версия из Google Drive загружена. Она применится, как только вы закроете редакторы и диалоги и завершатся текущие операции.';

  @override
  String get autoSyncConflict =>
      'На этом устройстве есть неотправленные изменения, а в Google Drive — другая версия. Ничего не перезаписано: изменения остаются на устройстве и автоматически не отправляются.';

  @override
  String get autoSyncError =>
      'Не удалось завершить обмен. Данные сохранены на этом устройстве. Следующая попытка — после следующей правки, при уходе приложения в фон или возвращении в него.';

  @override
  String get autoSyncRetrying =>
      'Нет связи с Google Drive. Данные сохранены на этом устройстве; приложение повторит попытку автоматически.';

  @override
  String get autoSyncRemoteNewer =>
      'В Google Drive есть более новая версия. Она загрузится при возвращении в приложение; с этого устройства ничего не отправлялось.';

  @override
  String get autoSyncDiverged =>
      'На этом устройстве есть неотправленные изменения, а в Google Drive сохранена другая версия. Автоматический обмен приостановлен, ничего не перезаписано. Выберите, какие данные оставить.';

  @override
  String get autoSyncDivergedShort => 'Нужно выбрать версию данных';

  @override
  String get autoSyncChooseVersion => 'Выбрать версию';

  @override
  String get autoSyncChooseTitle => 'Какие данные оставить?';

  @override
  String get autoSyncChooseHelp =>
      'Объединения нет: остаётся одна из версий. Незавершённые операции на серверах и удаления клиентов сохраняются в любом случае.';

  @override
  String get autoSyncKeepLocal => 'Оставить данные этого устройства';

  @override
  String get autoSyncTakeCloud => 'Взять из облака';

  @override
  String get autoSyncKeepLocalEffect => 'Версия в Google Drive будет заменена.';

  @override
  String get autoSyncTakeCloudEffect =>
      'Неотправленные изменения этого устройства будут заменены.';

  @override
  String autoSyncVersionSaved(String time, String device) {
    return 'Сохранено $time · $device';
  }

  @override
  String get autoSyncVersionUnknownTime => 'время неизвестно';

  @override
  String get autoSyncVersionUnknownDevice => 'устройство не указано';

  @override
  String get autoSyncThisDevice => 'это устройство';

  @override
  String get autoSyncChoiceBlocked =>
      'Сначала закройте редакторы и диалоги и дождитесь окончания операций, затем выберите версию снова.';

  @override
  String get autoSyncOtherWorkspace =>
      'В Google Drive лежат данные, начатые отдельно на другом устройстве, а на этом устройстве есть свои. Ничего не перезаписано. Выберите, какие данные оставить.';

  @override
  String get autoSyncOtherWorkspaceHelp =>
      'Это два отдельных набора данных: остаётся один из них целиком, ничего не объединяется. Незавершённые операции на серверах заменяемых данных не сохраняются.';

  @override
  String get autoSyncOtherKeepLocalEffect =>
      'Данные в Google Drive будут заменены. На других ваших устройствах появится тот же вопрос.';

  @override
  String get autoSyncOtherTakeCloudEffect =>
      'Все данные этого устройства будут заменены данными из Google Drive.';

  @override
  String get autoSyncReplaceCloudTitle => 'Заменить данные в Google Drive?';

  @override
  String get autoSyncReplaceCloudHelp =>
      'Серверы и клиенты, сохранённые в Google Drive с других устройств, будут из него удалены. Устройства, на которых они есть, спросят, какие данные оставить.';

  @override
  String get autoSyncReplaceCloud => 'Заменить';

  @override
  String get autoSyncUpdateRequired =>
      'Данные в Google Drive сохранены более новой версией AntiRKN. Обновите приложение на этом устройстве. До обновления с Google Drive ничего не загружается и туда ничего не отправляется; данные на этом устройстве не изменены.';

  @override
  String get restoredCacheRunning =>
      'Данные серверов перечитываются в фоне после синхронизации. Пока показаны данные, сохранённые на этом устройстве.';

  @override
  String restoredCacheStale(int count, String date) {
    return 'Не прочитаны серверы: $count. Показаны данные от $date. Уже опубликованные профили можно открыть из Google Drive.';
  }

  @override
  String restoredCacheMissing(int count) {
    return 'Не прочитаны серверы: $count. Сохранённых данных о них на этом устройстве нет. Уже опубликованные профили можно открыть из Google Drive.';
  }

  @override
  String restoredCacheServerIssue(String server, String reason) {
    return '$server: $reason';
  }

  @override
  String get profilePublishedDriveHelp =>
      'На этом устройстве профиль ещё не собран: нужны данные с серверов. Можно открыть файл, уже опубликованный в Google Drive.';

  @override
  String get profileOpenPublished => 'Открыть опубликованный файл';

  @override
  String get profilePublishedMissing =>
      'В Google Drive нет опубликованного по ссылке файла этого клиента.';

  @override
  String get profilePublishedFailed =>
      'Не удалось открыть опубликованный файл. Проверьте связь с Google Drive и повторите попытку.';

  @override
  String get profilePublishedFromDrive =>
      'Опубликованный файл из Google Drive. Он не пересобирался на этом устройстве.';

  @override
  String get autoSyncPairing =>
      'Войдите в один Google-аккаунт на своих устройствах и работайте на них по очереди. Изменения отправляются через 30 секунд после правки и при уходе приложения в фон или закрытии; устройство без неотправленных изменений получает более новую версию при запуске и возвращении в приложение.';

  @override
  String get googleDesktopConfigurationError =>
      'Google-вход не настроен. При запросе выберите JSON клиента Desktop OAuth из своего Google-проекта.';

  @override
  String get googleDesktopUnavailable =>
      'Не удалось открыть Google-вход в системном браузере. Проверьте браузер по умолчанию и повторите попытку.';

  @override
  String get googleDesktopWaiting =>
      'Завершите вход в браузере и вернитесь сюда. При первой настройке выберите файл Google Desktop client, если появится запрос.';

  @override
  String get googleCancelSignIn => 'Отменить вход';

  @override
  String get publicationTitle => 'Публикация профилей';

  @override
  String get publicationHelp =>
      'Автоматически сохранять клиентские YAML в Google Drive и обновлять тот же файл. Настройте папку на одном устройстве, затем синхронизируйте остальные.';

  @override
  String get publicationAuthorize => 'Разрешить публикацию в Drive';

  @override
  String get publicationAuthorizeHelp =>
      'Разрешите AntiRKN доступ к данным синхронизации и опубликованным файлам клиентов в Google.';

  @override
  String get publicationAccess => 'Доступ к профилям';

  @override
  String get publicationPrivate => 'Приватный файл';

  @override
  String get publicationLink => 'Доступ по ссылке';

  @override
  String get publicationLinkHelp =>
      'Любой получатель ссылки сможет скачать профиль с доступами клиента.';

  @override
  String get publicationPrivateHelp =>
      'Файл сохраняется в Drive. Для обычной ссылки подписки нужен доступ по ссылке.';

  @override
  String get publicationFolder => 'Папка';

  @override
  String get publicationNewFolder => 'Создать папку AntiRKN profiles';

  @override
  String get publicationChooseFolder => 'Выбрать доступную приложению папку';

  @override
  String get publicationEnable => 'Настроить публикацию';

  @override
  String get publicationAuto => 'Автоматическая публикация';

  @override
  String get publicationCompleteSetup => 'Завершить настройку папки';

  @override
  String get publicationMissing =>
      'Файл или папка недоступны. Проверьте доступ и корзину Drive; прежняя привязка сохранена.';

  @override
  String get publicationConflict =>
      'Версия на Drive изменилась. Синхронизируйте устройства и проверьте конфликт; файл не перезаписан.';

  @override
  String get publicationForceOverwrite => 'Перезаписать принудительно';

  @override
  String get publicationAccountChanged =>
      'Для этой публикации нужен Google-аккаунт, с которым выбрана папка.';

  @override
  String get publicationLinkUnavailable =>
      'Ссылка не отдаёт ожидаемый YAML без входа в Google. Повторите проверку позже.';

  @override
  String get publicationNetwork =>
      'Drive временно недоступен. Публикация сохранена в очереди.';

  @override
  String get publicationWaiting => 'Ожидает публикации';

  @override
  String get publicationFailed =>
      'Публикация не завершена. Проверьте настройки и повторите.';

  @override
  String get publicationPublished => 'Профиль опубликован';

  @override
  String get publicationRetry => 'Повторить публикацию';

  @override
  String publicationClientsFailed(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Не опубликованы профили $count клиента',
      many: 'Не опубликованы профили $count клиентов',
      few: 'Не опубликованы профили $count клиентов',
      one: 'Не опубликован профиль $count клиента',
    );
    return '$_temp0';
  }

  @override
  String get publicationClientsFailedMixed =>
      'Причины разные: подробности в карточках клиентов ниже.';

  @override
  String get publicationCopyLink => 'Копировать ссылку профиля';

  @override
  String get uiGoogleDrive => 'Google Drive';

  @override
  String get uiAppearance => 'Внешний вид и язык';

  @override
  String get uiActions => 'Действия';

  @override
  String get uiProtocols => 'Протоколы';

  @override
  String get uiMaintenance => 'Обслуживание';

  @override
  String get uiConnection => 'Подключение';

  @override
  String get uiDisconnectBeforeDelete =>
      'Перед удалением завершите операции и отключите SSH.';

  @override
  String get uiQrCopyHint =>
      'Отсканируйте в клиенте на базе Mihomo. Нажмите на QR, чтобы скопировать прямую ссылку на YAML.';

  @override
  String get uiLinkCopied => 'Ссылка скопирована';

  @override
  String get uiCopyFailed =>
      'Не удалось скопировать ссылку. Нажмите QR ещё раз.';

  @override
  String get uiPreviewYaml => 'Просмотр YAML';

  @override
  String get uiProfileDetails => 'Подробности профиля';

  @override
  String get uiOperationPending => 'Операция требует внимания';

  @override
  String get vpnDeleteUser => 'Удалить клиента';

  @override
  String get vpnDeleteExplanation =>
      'Клиент исчезнет из списка. Доступы на недоступных серверах будут отозваны после подключения. Имя и логин можно использовать снова.';

  @override
  String get vpnDeleteFile =>
      'Также переместить файл конфигурации в корзину Google Drive';

  @override
  String get vpnRevocationPending => 'Ожидает отзыва доступа';

  @override
  String get vpnDeleteFilePending => 'Доступы отозваны. Ожидает удаления файла';

  @override
  String get vpnAccessRevoked => 'Доступ отозван';

  @override
  String get vpnRevocationFailed =>
      'Отзыв не завершён. Проверьте сервер и повторите.';

  @override
  String get vpnUserDeleted =>
      'Эта запись клиента удалена. Можно создать нового клиента с тем же именем и логином.';

  @override
  String get vpnNodeName => 'Название узла';

  @override
  String get uiDeleteServer => 'Удалить сервер';

  @override
  String get vpnConnectToManage =>
      'Подключитесь, чтобы управлять подключениями и доступами клиентов.';

  @override
  String get catalogEdit => 'Редактировать список';

  @override
  String catalogSelected(int count) {
    return 'Выбрано: $count';
  }

  @override
  String get catalogDeleteSelected => 'Удалить выбранные';

  @override
  String get catalogSelectAll => 'Выбрать все / снять выбор';

  @override
  String get catalogExitEditing => 'Выйти из редактирования';

  @override
  String get catalogServerDeleteBlocked =>
      'Не удалось удалить выбранные серверы. Отключитесь от них и завершите ожидающие операции. Сервер, который используется как SSH-переход для невыбранного сервера, необходимо сохранить. Если список изменился, выберите записи заново.';

  @override
  String get catalogForgetServerTitle => 'Забыть недоступный сервер?';

  @override
  String get catalogForgetServerWarning =>
      'Забыть эти серверы на устройстве, не подключаясь к ним? Их VPN-ресурсы и ожидающие операции будут удалены из локальных профилей. Ранее выданный на VPS доступ может остаться активным, поскольку отзыв невозможно проверить. Данные на VPS не изменятся.';

  @override
  String get catalogForgetServerAction => 'Забыть локально';

  @override
  String get catalogServerForgetBlocked =>
      'Не удалось забыть выбранные серверы. Сейчас сохраняются локальные изменения или список серверов изменился. Дождитесь завершения и повторите попытку.';

  @override
  String get publicationBindTitle => 'Файл конфигурации клиента';

  @override
  String get publicationBindHelp =>
      'Вставьте прежнюю ссылку Google Drive или выберите файл. Для чужих приложению файлов сначала разрешите доступ через выбор Google.';

  @override
  String get publicationFileLink => 'Ссылка Google Drive или ID файла';

  @override
  String get publicationInspect => 'Проверить файл';

  @override
  String get publicationPickFile => 'Выбрать в Google Drive';

  @override
  String get publicationPickerSetupHelp =>
      'Настройте Google Picker в Настройки → Drive: API key и числовой Project number того же Google Cloud проекта. В проекте должны быть включены Drive API и Picker API.';

  @override
  String get publicationPickerWaiting =>
      'Выберите файл в браузере и вернитесь в AntiRKN. Отмена завершает ожидание.';

  @override
  String get publicationFileAccessHelp =>
      'Файл не найден или у AntiRKN нет доступа. Нажмите «Выбрать в Google Drive» выше, чтобы предоставить доступ. Вставка ID работает только для файлов, к которым приложение уже имеет доступ.';

  @override
  String get publicationBindReplace =>
      'Подтверждение заменит содержимое этого файла профилем клиента и включит последующие обновления по тому же ID. Старый файл не удаляется: его содержимое и доступ сохраняются, автоматическое обновление прекращается. При незавершённой замене можно повторно проверить файл или выбрать другой.';

  @override
  String get publicationOldContent => 'Текущее содержимое файла';

  @override
  String get publicationNewContent => 'Профиль для замены';

  @override
  String get publicationBindConfirm => 'Заменить и привязать';

  @override
  String get publicationPickerSettings => 'Выбор файлов Google Drive';

  @override
  String get publicationPickerApiKey => 'Публичный API key';

  @override
  String get publicationPickerProject => 'Project number (числовой)';

  @override
  String get publicationBindPending =>
      'Перепривязка ожидает завершения. До проверки новой ссылки доступна прежняя.';

  @override
  String get publicationChangeFile => 'Изменить файл / ссылку';

  @override
  String get publicationSaveClientFirst =>
      'Для смены ссылки сначала сохраните изменения клиента.';

  @override
  String get publicationBindSetupHelp =>
      'Сначала настройте и включите публикацию в Настройки → Drive.';

  @override
  String get publicationBindInvalid =>
      'Нужна ссылка Google Drive на обычный текстовый файл UTF-8, доступный для редактирования. Папки, Google Документы и файлы другого клиента не подходят.';

  @override
  String get uiSyncOptions => 'Параметры синхронизации';

  @override
  String get uiPairDevice => 'Подключить другое устройство';

  @override
  String get uiSystemUpdate => 'Обновить систему';

  @override
  String get uiSystemUpdateHelp =>
      'Обновить список пакетов и установить доступные обновления Ubuntu.';

  @override
  String get uiCheck => 'Проверить';

  @override
  String get uiShareProfile => 'QR подключения';

  @override
  String get uiPublicAddresses => 'Публичные IP-адреса';

  @override
  String get uiNoPublicAddresses => 'Публичные адреса не обнаружены';

  @override
  String get uiOffline => 'Не подключён';

  @override
  String get uiProtocolClients => 'Доступы клиентов';

  @override
  String get uiServices => 'Службы и обновления';

  @override
  String get uiNetworkSsh => 'Сеть и SSH';

  @override
  String get uiAccount => 'Аккаунт';

  @override
  String get uiInterface => 'Интерфейс';

  @override
  String get uiInterfaceHelp => 'Тема и язык приложения';

  @override
  String get uiSynchronization => 'Синхронизация';

  @override
  String get uiSyncHelp => 'Google Drive и ваши устройства';

  @override
  String get uiClientProfiles => 'Клиентские профили';

  @override
  String get uiClientProfilesHelp => 'Базовый YAML, папка и ссылки';

  @override
  String get uiBackupHelp => 'Сохранение и восстановление данных';

  @override
  String get uiComponentUpdates => 'Обновления';

  @override
  String get uiUpdatesHelp => 'Новые версии приложения';

  @override
  String get uiAppSettings => 'Настройки приложения';

  @override
  String get uiMyData => 'Мои данные';

  @override
  String get uiPersonalWorkspace => 'Личное пространство';

  @override
  String get uiBack => 'Назад';

  @override
  String get uiSshAccess => 'Доступ SSH';

  @override
  String get uiActivity => 'История действий';

  @override
  String get uiActivityHelp => 'Действия со всех ваших устройств';

  @override
  String get uiServerAbout => 'О сервере';

  @override
  String get uiServerAboutSummary => 'Внешние IP, трафик и место на диске';

  @override
  String get uiNoActivity => 'Действий пока нет';

  @override
  String get uiServerChanges => 'Изменение сервера';

  @override
  String get uiNotConfigured => 'Не настроен';

  @override
  String get uiNoClientAccess => 'Доступ ещё не настроен';

  @override
  String get uiDiskCapacity => 'Объём диска';

  @override
  String get uiTraffic => 'Трафик сервера';

  @override
  String get uiTrafficReceived => 'Загрузка';

  @override
  String get uiTrafficSent => 'Выгрузка';

  @override
  String get uiTrafficReset => 'Сбросить отсчёт';

  @override
  String get uiTrafficSinceBoot => 'С текущего запуска сервера';

  @override
  String get uiTrafficResetHelp =>
      'Отсчёт сохраняется на этом устройстве. Учитываются интерфейсы с маршрутом по умолчанию. После перезапуска сервера отсчёт начинается заново.';

  @override
  String get uiDiskSpace => 'Место на системном диске';

  @override
  String get uiDiskFree => 'Свободно';

  @override
  String get uiCopyAddress => 'Скопировать адрес';

  @override
  String get uiClashRefreshHint =>
      'Клиент обновляет профиль по своему расписанию (часто раз в 24 часа) и только когда запущен и есть сеть.';

  @override
  String uiConnectionCount(int count) {
    return 'Подключений: $count';
  }

  @override
  String uiTrafficSince(String time) {
    return 'После сброса $time';
  }

  @override
  String uiDiskTotal(String size) {
    return 'Всего: $size';
  }

  @override
  String get uiAddressCopied => 'IP-адрес скопирован';

  @override
  String get uiServersIntro => 'Ваши серверы и подключения';

  @override
  String get uiMyServers => 'Мои серверы';

  @override
  String get uiClientsIntro => 'Доступы и профили ваших клиентов';

  @override
  String get uiClientsEmptyHelp =>
      'Добавьте клиента, чтобы настроить доступ и выдать профиль подключения.';

  @override
  String get uiBackupExportHelp => 'Сохранить данные приложения в файл';

  @override
  String get uiBackupImportHelp => 'Перенести данные на это устройство';

  @override
  String get uiApplicationData => 'Данные приложения';

  @override
  String get uiUpdatesShort => 'Обновления';

  @override
  String get uiUpdatesAutomaticHelp =>
      'Искать новые выпуски AntiRKN на GitHub при запуске и время от времени';

  @override
  String get uiUpdatesSuggestionsHelp =>
      'Показывать доступное обновление приложения на главном экране';

  @override
  String get uiSyncAutomaticHelp =>
      'Отправка после правок и при уходе, загрузка при входе';

  @override
  String get uiPairDeviceHelp => 'Войти в тот же Google-аккаунт';

  @override
  String get uiPublicProfileHelp =>
      'Профиль доступен по прямой ссылке. QR-код и ссылку можно получить в карточке клиента.';

  @override
  String get uiPublicationAutoHelp => 'Сохранять изменения по прежним ссылкам';

  @override
  String get uiInterfaces => 'Интерфейсы';

  @override
  String get uiConnections => 'Подключения';

  @override
  String get uiTtSetup => 'Настроить TrustTunnel';

  @override
  String uiPeerCount(int count) {
    return 'Подключений: $count';
  }

  @override
  String get uiForceDeleteClient => 'Удалить принудительно';

  @override
  String uiForceDeleteWarning(String name, String servers) {
    return 'Клиент «$name» исчезнет из приложения. На недоступных серверах ($servers) доступ может ещё работать. Приложение завершит отзыв при следующем подключении.';
  }

  @override
  String get uiClashImport => 'Профиль подключения для клиентов Mihomo';

  @override
  String get uiConnectionSettings => 'Подключение';

  @override
  String get uiAuthentication => 'Данные для входа';

  @override
  String get uiOtherComponents => 'Остальные компоненты';

  @override
  String get uiRemoveProtocol => 'Удалить протокол';

  @override
  String get uiRemoveProtocolHelp =>
      'Службы и все подключения этого протокола будут удалены с сервера, включая созданные вне AntiRKN. Клиенты потеряют доступ через этот протокол.';

  @override
  String get uiRemoveVlessHelp =>
      'Удаляется 3x-ui / Xray целиком. Все инбаунды этой службы, в том числе других протоколов, перестанут работать.';

  @override
  String get uiRemoveProtocolBusy =>
      'Дождитесь завершения текущей операции на сервере.';

  @override
  String get uiRemoveProtocolConnect =>
      'Сначала подключитесь по SSH. После подключения снова удерживайте плитку протокола.';

  @override
  String get uiRemoveProtocolStarted =>
      'Удаление запущено. Результат появится в обслуживании сервера.';

  @override
  String get uiRemoveProtocolFailed =>
      'Не удалось удалить протокол. Проверьте состояние сервера и повторите.';

  @override
  String get uiRemoveProtocolConflict =>
      'Установка изменилась. Обновите сервер и подтвердите новый план удаления.';

  @override
  String get uiRemoveProtocolUnsupported =>
      'Эта установка имеет нестандартную конфигурацию. Автоматическое удаление недоступно.';

  @override
  String get uiNotInstalled => 'Не установлен';

  @override
  String get uiInstallProtocolHelp =>
      'Установить ПО протокола и необходимые зависимости? Приложение подключится к серверу и начнёт установку.';

  @override
  String get uiInstallProtocolConnect =>
      'Подключитесь к серверу по SSH, затем снова нажмите на протокол для установки.';

  @override
  String get sshHardenBannerTitle => 'Вход от root не защищён';

  @override
  String get sshHardenBannerSubtitle =>
      'Рекомендуется создать пользователя с sudo, сменить порт SSH на 2222 и отключить вход root.';

  @override
  String get sshHardenBannerAction => 'Защитить сервер';

  @override
  String get sshHardenDialogTitle => 'Мастер защиты SSH';

  @override
  String get sshHardenDialogDescription =>
      'Создайте пользователя с sudo и выберите порт SSH. Приложение проверит новый доступ до и после применения итоговых настроек. Незавершённые изменения автоматически откатываются, в том числе после перезагрузки сервера.';

  @override
  String get sshHardenUsername => 'Имя нового пользователя';

  @override
  String get sshHardenPort => 'Новый SSH порт';

  @override
  String get sshHardenSudoPassword => 'Пароль нового пользователя и sudo';

  @override
  String get sshHardenSudoPasswordConfirm => 'Повторите пароль sudo';

  @override
  String get sshHardenPasswordMismatch => 'Пароли не совпадают';

  @override
  String get sshHardenPasswordRequired => 'Введите пароль sudo для защиты';

  @override
  String sshHardenFirewallWarning(int port) {
    return 'Внимание: если в панели хостинга (Hetzner, Timeweb, Selectel и др.) включен Cloud Firewall, обязательно откройте порт $port/TCP до подтверждения.';
  }

  @override
  String get sshHardenStartAction => 'Начать настройку';

  @override
  String get sshHardenPreparing => 'Подготовка и проверка настроек...';

  @override
  String get sshHardenUserCreated =>
      'Пользователь создан, SSH-ключи скопированы...';

  @override
  String get sshHardenSudoersConfigured =>
      'Права sudo настроены и проверены...';

  @override
  String get sshHardenPortsConfigured => 'Порты SSH настроены (dual-port)...';

  @override
  String get sshHardenFirewallConfigured => 'Firewall (UFW) настроен...';

  @override
  String get sshHardenWatchdogStarted => 'Таймер безопасности запущен...';

  @override
  String get sshHardenTesting =>
      'Проверка подключения от нового пользователя...';

  @override
  String sshHardenTestingCountdown(String time) {
    return 'Автооткат через $time';
  }

  @override
  String sshHardenTestSuccess(String user, int port) {
    return 'Проверка успешна! Пользователь $user подключился по порту $port и подтвердил права sudo.';
  }

  @override
  String sshHardenTestFailed(int port) {
    return 'Не удалось подключиться к порту $port с новым пользователем. Проверьте Firewall в панели хостинга.';
  }

  @override
  String get sshHardenConfirmAction => 'Применить защиту';

  @override
  String get sshHardenAbortAction => 'Откатить изменения';

  @override
  String get sshHardenRetryAction => 'Повторить проверку';

  @override
  String get sshHardenConfirmed =>
      'Защита SSH применена. Новое подключение и sudo проверены.';

  @override
  String get sshHardenAborted => 'Изменения откатаны. Доступ от root сохранён.';

  @override
  String get sshHardenConflict =>
      'Конфигурация SSH изменилась во время работы мастера.';

  @override
  String get sshHardenInvalid => 'Недопустимое имя пользователя или порт.';

  @override
  String get sshHardenPortBusy => 'Выбранный порт уже занят другой службой.';

  @override
  String get sshHardenFailed =>
      'Не удалось завершить защиту SSH. Проверьте подключение и состояние восстановления.';

  @override
  String get sshHardenRandomUser => 'Выбрать случайного персонажа';

  @override
  String get sshHardenRandomPassword => 'Создать случайный пароль';

  @override
  String get uiServerDataNotCached =>
      'Подключитесь к серверу один раз, чтобы сохранить его данные на этом устройстве.';

  @override
  String get inboundDeleteSelectionHelp =>
      'Удалить выбранные inbounds вместе с их подключениями? Осиротевшие записи клиентов на сервере тоже удалятся. Клиенты в приложении сохранятся, затронутые профили обновятся.';

  @override
  String get inboundDeleteIncomplete =>
      'Удаление завершено не полностью. Проверьте состояние задания в обслуживании сервера; незавершённое задание можно повторить.';

  @override
  String get diagSuspectedBlocking => 'Признаки блокировки';

  @override
  String get diagConnectionLost => 'Потеря связи после этого IP';

  @override
  String get diagConnectionRestored => 'Связь восстановлена';

  @override
  String get diagQueued => 'Ожидает проверки';

  @override
  String get diagNotTested => 'Не проверен';

  @override
  String get diagNoIpv4 => 'Нет публичных IPv4 для проверки (до 64 на сервер).';

  @override
  String get diagTitle => 'Диагностика IP';

  @override
  String get diagBaseline => 'Проверяем исходное состояние сети';

  @override
  String get diagTarget => 'Проверяем адрес';

  @override
  String get diagControls => 'Проверяем контрольные адреса';

  @override
  String get diagRecovery => 'Ждём восстановления связи';

  @override
  String get diagComplete => 'Проверка завершена';

  @override
  String get diagCancelled => 'Проверка остановлена';

  @override
  String get diagNetworkChanged => 'Сеть изменилась — результат неполный';

  @override
  String get diagInsufficient => 'Недостаточно стабильных контрольных адресов';

  @override
  String get diagDegraded => 'Очередь остановлена из-за ухудшения связи';

  @override
  String get diagFailed => 'Не удалось выполнить проверку';

  @override
  String get diagInvalid =>
      'Введите до 64 публичных IP, порт 1–65535 и имя сертификата для TLS. Доменные имена вместо IP не поддерживаются.';

  @override
  String get diagConsent =>
      'Обращение к проверяемому IP может временно нарушить доступ в интернет. Приложение проверит сеть с этого устройства, закроет свободные SSH-соединения и приостановит свою фоновую синхронизацию. При ухудшении связи очередь остановится; около 3 минут будут проверяться только контрольные адреса. VPN и другие приложения могут влиять на результат.';

  @override
  String get diagStart => 'Начать проверку';

  @override
  String get diagIntro =>
      'Проверка доступности IP и признаков временной потери связи после обращения к нему. Укажите порт, на котором сервер должен принимать соединения.';

  @override
  String get diagChooseServer => 'Выбрать адреса сервера';

  @override
  String get diagAddresses => 'IP-адреса, по одному в строке';

  @override
  String get diagPort => 'Порт';

  @override
  String get diagProtocol => 'Способ проверки';

  @override
  String get diagSni => 'Имя сайта для TLS (SNI и сертификат)';

  @override
  String get diagStop => 'Остановить';

  @override
  String get diagBusy =>
      'Дождитесь завершения текущих операций с серверами и профилями.';

  @override
  String get diagHistoryError =>
      'Не удалось прочитать или сохранить историю проверок.';

  @override
  String get diagNetwork => 'Подключение';

  @override
  String diagControlCount(int reachable, int total) {
    return 'Контрольные адреса доступны: $reachable из $total';
  }

  @override
  String get diagStrong =>
      'Признаки сильной блокировки: после обращения к IP связь с несколькими независимыми контрольными сетями ухудшилась в двух проверках подряд.';

  @override
  String get diagRegional =>
      'Зарубежные контрольные серверы недоступны, российский доступен.';

  @override
  String diagRecovered(int seconds) {
    return 'Контрольная связь восстановилась через $seconds с. Для продолжения нужна новая проверка.';
  }

  @override
  String get diagNotRecovered =>
      'В течение наблюдения нормальная связь не восстановилась.';

  @override
  String get diagLimits =>
      'Недоступность IP может быть вызвана закрытым портом, неисправностью сервера или маршрута. Проверка не доказывает блокировку РКН. Успешное соединение относится только к указанному порту и способу проверки.';

  @override
  String get diagControlList => 'Контрольные адреса';

  @override
  String get diagControlHelp =>
      '14 IPv4 и 12 IPv6 адресов. Сначала дважды проверяем адреса нужного семейства; используем только стабильные, исключая проверяемые IP. Доступность не ниже 90% считается нормальной: 9 из 10 или 13 из 14. Для DNS проверяем TCP-порт 53, для RIPE Atlas — HTTP-порт 80. Anycast не гарантирует зарубежный маршрут.';

  @override
  String get diagHistory => 'Последние проверки';

  @override
  String get diagCopyReport => 'Скопировать отчёт';

  @override
  String get diagClearHistory => 'Очистить историю';

  @override
  String get diagInterrupted => 'Прервано при закрытии приложения';

  @override
  String get diagReachable => 'Соединение успешно';

  @override
  String get diagRefused => 'Соединение отклонено: возможен закрытый порт';

  @override
  String get diagTlsError => 'Ошибка TLS или сертификата';

  @override
  String get diagProtocolError => 'Сервис ответил не по выбранному протоколу';

  @override
  String get diagUnreachable => 'Нет соединения: причина не установлена';

  @override
  String get diagWifi => 'Wi-Fi';

  @override
  String get diagMobile => 'Мобильная сеть';

  @override
  String get diagSystem => 'Маршрут системы';

  @override
  String get diagForeign => 'Зарубежный сервер';

  @override
  String get diagRussia => 'Российский сервер';

  @override
  String get diagAnycast => 'Anycast, расположение зависит от маршрута';

  @override
  String get sshHardenDisableRoot => 'Запретить прямой вход root';

  @override
  String get sshHardenRecoveryFailed =>
      'Восстановление доступа не подтверждено. Сохраните реквизиты и повторите откат.';

  @override
  String get sshHardenSudoRequired =>
      'Новый пользователь должен вводить пароль для sudo.';

  @override
  String get sshHardenStorageFailed =>
      'Не удалось сохранить реквизиты. Переход на сервере не зафиксирован.';

  @override
  String get vpnAdopt => 'Управлять доступами клиентов';

  @override
  String get vpnAdoptWarning =>
      'AntiRKN будет управлять доступами своих клиентов. Текущие настройки и пользователи сохранятся.';

  @override
  String get vpnAdopting => 'Ожидается подтверждение управления';

  @override
  String get vpnAdoptUnsupported =>
      'Подключение с такими настройками пока нельзя импортировать. Настройки сервера не изменены.';

  @override
  String get vpnAdoptConflict =>
      'Подключение изменилось или уже находится под управлением. Обновите его состояние и повторите попытку.';

  @override
  String get vpnAdoptFailed =>
      'Управление доступами не подтверждено. Проверьте состояние операции перед повтором.';

  @override
  String get templateCoreChecking => 'Mihomo проверяет файл…';

  @override
  String get templateCoreValid => 'Базовый конфиг принят Mihomo.';

  @override
  String get templateCoreRejected =>
      'Mihomo нашёл ошибку в файле. Текущий базовый конфиг сохранён.';

  @override
  String get templateCoreProviderRejected =>
      'Mihomo не смог прочитать список правил из файла. Текущий базовый конфиг сохранён.';

  @override
  String get templateCoreIncomplete =>
      'Файл добавлен, но Mihomo проверил его частично: списки правил или другие внешние файлы недоступны.';

  @override
  String get templateCoreInputLimit =>
      'Файл добавлен без полной проверки: он превышает лимит проверки ядром.';

  @override
  String get templateCoreUnavailable =>
      'Файл добавлен без проверки ядром: Mihomo не удалось запустить.';

  @override
  String get connectionCheck => 'Проверить';

  @override
  String get connectionCheckAll => 'Проверить все';

  @override
  String get connectionTargetsFailed =>
      'Не удалось прочитать список подключений для проверки. Обновите сервер и повторите.';

  @override
  String get connectionStop => 'Остановить проверку';

  @override
  String get connectionReconfigure => 'Перенастроить';

  @override
  String get connectionChecking => 'Проверяем соединение…';

  @override
  String get connectionWorking => 'Соединение работает · TCP и UDP';

  @override
  String get connectionFailed =>
      'Не удалось подключиться. Проверьте настройки.';

  @override
  String get connectionEndpointUnreachable =>
      'Адрес сервера не отвечает из этой сети, похоже, его блокирует провайдер. Настройки в порядке: перенесите протокол на другой адрес сервера.';

  @override
  String get connectionCancelled => 'Проверка остановлена';

  @override
  String get connectionVpnActive => 'Отключите VPN на устройстве для проверки';

  @override
  String get connectionNetworkChanged => 'Сеть изменилась. Повторите проверку.';

  @override
  String get connectionNetworkProblem =>
      'Сеть или контрольные адреса недоступны. Повторите позже.';

  @override
  String get connectionRouteUnsupported =>
      'Этот маршрут пока нельзя проверить с устройства';

  @override
  String get connectionAccessRequired =>
      'Нужен доступ к серверу для проверки подключения';

  @override
  String get connectionCleanupPending =>
      'Проверка прервана. Сервер удалит временный доступ автоматически.';

  @override
  String get connectionChanged =>
      'Параметры подключения изменились во время проверки. Запустите её ещё раз.';

  @override
  String get connectionCoreUnavailable =>
      'Не удалось выполнить проверку Mihomo. Попробуйте ещё раз.';

  @override
  String get connectionUnsupported =>
      'Mihomo не может проверить эту конфигурацию подключения.';

  @override
  String get connectionBusy =>
      'Сервер или служба проверки заняты. Повторите попытку через несколько секунд.';

  @override
  String get connectionTimeout =>
      'Время ожидания ответа сервера истекло. Проверьте доступность порта и сервера.';

  @override
  String get connectionNotTested => 'Не проверено';

  @override
  String connectionProgress(int done, int total, int skipped) {
    return 'Проверено: $done из $total. Пропущено: $skipped.';
  }

  @override
  String get xrayUpgradeTitle => 'Обновление ядра Xray';

  @override
  String get xrayUpgradeBaseline => 'Проверка подключений до обновления…';

  @override
  String get xrayUpgradePreparing =>
      'Подготовка восстановления и обновление Xray…';

  @override
  String get xrayUpgradeComparison => 'Сравнение подключений после обновления…';

  @override
  String get xrayUpgradeCommitted =>
      'Xray обновлён. HTTPS и UDP работают на всех проверенных инбаундах.';

  @override
  String get xrayUpgradeRestored =>
      'Прежнее ядро восстановлено. Результаты повторных проверок — ниже.';

  @override
  String get xrayUpgradeUnchanged => 'Обновление не началось.';

  @override
  String get xrayUpgradePending =>
      'Ожидается подтверждение восстановления с сервера. Откат продолжает работать независимо от приложения.';

  @override
  String get xrayUpgradeCoverage =>
      'Нужны успешные HTTPS и UDP на каждом включённом инбаунде. За один запуск поддерживается до 8 VLESS-инбаундов; недоступные или неподдерживаемые подключения не пропускаются.';

  @override
  String get xrayUpgradeLayout =>
      'Обновление доступно для проверенной установки 3x-ui 3.7/3.8 на Ubuntu x64 с более ранней версией Xray.';

  @override
  String get xrayUpgradeProblem =>
      'Проверка не завершена. Посмотрите результаты подключений и повторите после восстановления связи.';

  @override
  String get xrayUpgradeConflict =>
      'Состояние сервера изменилось. Чужие изменения сохранены; проверьте сервер перед повтором.';

  @override
  String get xrayUpgradePanelApi =>
      'После перезапуска Xray приложение не смогло войти в 3x-ui или прочитать те же инбаунды. Ядро не подтверждено, сервер возвращает прежнюю версию.';

  @override
  String get xrayUpgradePrerelease => 'Предварительный выпуск';

  @override
  String get xrayUpgradeNoStable =>
      'Нет проверенного стабильного обновления Xray.';

  @override
  String get xrayUpgradeBefore => 'До';

  @override
  String get xrayUpgradeAfter => 'После';

  @override
  String get xrayUpgradeRecovery => 'После отката';

  @override
  String get xrayUpgradeDisabled => 'Отключён — не проверяется';

  @override
  String get xrayUpgradeNotTested => 'Не проверен';

  @override
  String get xrayUpgradeDigest =>
      'Скачанный архив Xray не совпадает с опубликованной контрольной суммой. Ядро не менялось.';

  @override
  String get xrayUpgradeConfig =>
      'Новый Xray не принял текущую конфигурацию при пробном запуске. Ядро не менялось.';

  @override
  String get xrayUpgradeTimeout =>
      'Сервер не успел завершить обновление. Ядро не менялось или уже восстановлено.';

  @override
  String get xrayUpgradeRestart =>
      'Xray не запустился с новой версией. Сервер возвращает прежнее ядро.';

  @override
  String get xrayUpgradeBusy => 'На сервере ещё идёт другое обновление Xray.';

  @override
  String technicalCode(String code) {
    return 'Код: $code';
  }

  @override
  String get xrayUpgradeAttention =>
      'Восстановление не подтверждено. Проверьте службу Xray и изменения бинарного файла на сервере; резервная копия сохранена.';

  @override
  String get serverReboot => 'Перезапустить сервер';

  @override
  String get serverRebootConfirm =>
      'Перезапустить сервер? SSH и VPN-соединения временно прервутся.';

  @override
  String get serverRebootWaiting =>
      'Сервер перезапускается. Ожидаем восстановления связи…';

  @override
  String get serverRebootDone => 'Перезапуск сервера подтверждён.';

  @override
  String get serverRebootFailed =>
      'Перезапуск пока не подтверждён. Подключитесь снова, чтобы проверить состояние.';

  @override
  String get egressTitle => 'Выход в интернет';

  @override
  String get egressUnknown => 'Выход ещё не проверен';

  @override
  String get egressDirect => 'Напрямую';

  @override
  String get egressClientTraffic =>
      'Только трафик клиентов: VLESS, TrustTunnel и AmneziaWG.';

  @override
  String get egressChecked => 'TCP и UDP проверены';

  @override
  String get egressConfigure => 'Настроить';

  @override
  String get egressCheck => 'Проверить';

  @override
  String get egressInstallPanel => 'Установить 3x-ui';

  @override
  String get egressViaServer => 'Через другой сервер';

  @override
  String get egressSource => 'Источник подключения';

  @override
  String get egressLink => 'VLESS-ссылка';

  @override
  String get egressCatalog => 'Выбрать из серверов';

  @override
  String get egressTarget => 'Выходной сервер';

  @override
  String get egressAddress => 'Адрес для подключения с этого сервера';

  @override
  String get egressPort => 'Внешний порт VLESS';

  @override
  String get egressServiceAccess =>
      'При применении создаётся отдельный доступ для этого сервера.';

  @override
  String get egressReveal => 'Показать или скрыть ссылку';

  @override
  String get egressPaste => 'Вставить';

  @override
  String get egressAdvanced => 'Дополнительно';

  @override
  String get egressSocksPort => 'Локальный порт SOCKS';

  @override
  String get egressSocksHelp =>
      '127.0.0.1. Чтобы изменить порт, сначала отключите переадресацию.';

  @override
  String get egressRulesHelp =>
      'TCP/UDP направляются через VLESS. Прежние правила Xray имеют приоритет. При недоступности выхода прямого переключения нет.';

  @override
  String get egressApply => 'Применить';

  @override
  String get egressPanelRequired =>
      'Для общего выхода требуется 3x-ui на этом сервере.';

  @override
  String get egressInvalid =>
      'Проверьте VLESS-ссылку и параметры подключения. Неподдерживаемые параметры не применяются.';

  @override
  String get egressUnsupported =>
      'Обнаружена неподдерживаемая конфигурация. Настройки не изменены.';

  @override
  String get egressNamespace =>
      'AmneziaWG в отдельной Docker-сети пока не поддерживается. Для общего выхода требуется сеть хоста или обычная установка.';

  @override
  String get egressConflict =>
      'Настройки изменились. Обновите сведения и повторите действие.';

  @override
  String get egressPortBusy =>
      'Локальный порт недоступен. Выберите другой порт или автоматический подбор.';

  @override
  String get egressLoop =>
      'Выход указывает на этот же сервер. Выберите другой сервер.';

  @override
  String get egressConfigFailed =>
      'Xray или TrustTunnel не принял настройки. Проверьте результат восстановления.';

  @override
  String get egressNetwork =>
      'Не удалось настроить маршруты клиентов AmneziaWG. Требуются iproute2, iptables и TPROXY.';

  @override
  String get egressProbeFailed =>
      'TCP или UDP через выходной сервер не работает. Проверьте VLESS-доступ и сеть.';

  @override
  String get egressRollbackFailed =>
      'Автоматическое восстановление не завершено. Требуется проверка настроек сервера.';

  @override
  String get egressFailed =>
      'Не удалось выполнить настройку выхода. Подробности доступны в истории операции.';

  @override
  String get egressPreparing => 'Проверка выходного подключения';

  @override
  String get egressApplying => 'Настройка выхода клиентов';

  @override
  String get egressChecking => 'Проверка применённых настроек';

  @override
  String get egressDisableFirst =>
      'Сначала отключите выход через другой сервер, затем удаляйте 3x-ui.';

  @override
  String get egressTtInherited =>
      'Выход через другой сервер включён в настройках сервера. TrustTunnel использует его автоматически.';

  @override
  String get vpnIndividualTemplate => 'Индивидуальный базовый конфиг';

  @override
  String get vpnIndividualTemplateHelp =>
      'Использовать отдельный YAML-файл для этого клиента.';

  @override
  String get vpnSharedTemplateHelp =>
      'Использовать общий базовый конфиг из настроек.';

  @override
  String get vpnIndividualTemplateRequired =>
      'Выберите YAML-файл для этого клиента.';

  @override
  String get catalogForgetServerJumpWarning =>
      'Ссылки на эти серверы как SSH-переход будут убраны из других сохранённых подключений. После удаления выберите для них новый SSH-маршрут.';

  @override
  String get versionsChoose => 'Версии';

  @override
  String versionsTitle(Object name) {
    return 'Версии · $name';
  }

  @override
  String get versionsLoading => 'Получаем список релизов и состояние сервера…';

  @override
  String get versionsFailed =>
      'Не удалось получить список релизов или состояние сервера. Проверьте связь и повторите.';

  @override
  String get versionsHelp =>
      'Новая версия ставится с проверкой настоящих подключений. Если они перестанут работать или это устройство потеряет сервер, сервер сам вернёт прежнюю версию в течение 5 минут. Более старые версии не предлагаются: вернуться можно только к той, что стояла до последнего обновления.';

  @override
  String versionsInstalled(Object version) {
    return 'установлена $version';
  }

  @override
  String get versionsNothing => 'Новее версий нет, возвращаться не к чему.';

  @override
  String get versionsVerified => 'проверена AntiRKN';

  @override
  String get versionsUnverified => 'не проверена AntiRKN';

  @override
  String get versionsPreview => 'предварительная';

  @override
  String get versionsPrevious => 'прежняя версия';

  @override
  String get versionsInstall => 'Поставить';

  @override
  String get versionsRestore => 'Вернуть';

  @override
  String versionsInstallTitle(Object name, Object version) {
    return 'Поставить $name $version?';
  }

  @override
  String versionsRestoreTitle(Object name, Object version) {
    return 'Вернуть $name $version?';
  }

  @override
  String versionsChange(Object from, Object to) {
    return 'Сейчас: $from → $to.';
  }

  @override
  String get versionsPanelCarriesXray =>
      'В релизе 3x-ui есть свой Xray: ядро сменится вместе с панелью.';

  @override
  String versionsPanelRestoresXray(Object version) {
    return 'Вместе с панелью вернётся Xray $version.';
  }

  @override
  String get versionsSafety =>
      'Инбаунды, клиенты и настройки остаются как есть. После переключения сервер проверит настоящие подключения; если это устройство не подтвердит за 5 минут, сервер вернёт текущую версию.';

  @override
  String get versionsAssetMissing =>
      'В этом релизе нет файла для архитектуры сервера или нет контрольной суммы. Выберите другую версию.';

  @override
  String get versionsAwgBuild =>
      'AmneziaWG собирается из исходного кода на сервере: это занимает несколько минут.';

  @override
  String get versionsSafetyInstaller =>
      'Ключи и настройки остаются как есть. Новая версия ставится в отдельную папку; если после переключения служба не запустится или пропадут подключения, сервер сам вернёт текущую версию.';

  @override
  String get versionsXraySafety =>
      'Xray меняется только с проверкой: настоящие подключения проверяются до и после переключения, а приложение должно по-прежнему входить в 3x-ui и видеть те же инбаунды. Иначе, или если это устройство не подтвердит за 5 минут, сервер вернёт текущую версию. Инбаунды, клиенты и настройки остаются как есть.';

  @override
  String get versionsXrayUnavailable =>
      'Xray меняется только вместе с проверкой подключений. Откройте страницу обновлений сервера на устройстве, которое может проверять подключения, и выберите версию снова.';

  @override
  String get versionsHelpInstaller =>
      'Новые стабильные версии ставятся в отдельную папку рядом с текущей. Если после переключения служба не запустится или пропадут подключения, сервер сам вернёт текущую версию. Более старые версии не предлагаются.';

  @override
  String get uiOperationRunning => 'Выполняется…';

  @override
  String get uiOperationQueued => 'В очереди';

  @override
  String get vpnMissingOnServer =>
      'Пока нет на сервере. Приложение отправит само.';

  @override
  String vpnMissingNotice(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'На сервере пока нет $count подключений из приложения. Приложение отправляет их само; если не получилось — отправьте ещё раз.',
      few:
          'На сервере пока нет $count подключений из приложения. Приложение отправляет их само; если не получилось — отправьте ещё раз.',
      one:
          'На сервере пока нет $count подключения из приложения. Приложение отправляет его само; если не получилось — отправьте ещё раз.',
    );
    return '$_temp0';
  }

  @override
  String get vpnSendToServer => 'Отправить на сервер';

  @override
  String get ttIssueWaiting =>
      'Сервер занят другой операцией. Выпуск станет доступен, когда она закончится.';

  @override
  String get vpnDelete => 'Удалить';

  @override
  String get awgDelete => 'Удалить интерфейс AmneziaWG';

  @override
  String get awgDeleteHelp =>
      'Следующий план удалит этот интерфейс AmneziaWG и его клиентские ключи на сервере. Клиенты в приложении сохранятся.';

  @override
  String get ttDelete => 'Удалить точку TrustTunnel';

  @override
  String get ttDeleteHelp =>
      'Следующий план удалит эту точку TrustTunnel и её клиентские пароли на сервере. Клиенты в приложении сохранятся.';

  @override
  String get xrayUpgradeStopTitle => 'Остановить обновление Xray?';

  @override
  String get xrayUpgradeStopHelp =>
      'Сервер прервёт обновление и вернёт прежнее ядро. Подключения будут проверены ещё раз.';

  @override
  String get uiProtocolActions => 'Действия с протоколом';

  @override
  String get uiBusySync => 'Идёт синхронизация и публикация профилей';

  @override
  String get uiBusyChanges => 'Дождитесь завершения текущего изменения';

  @override
  String get uiBusyServerOperation => 'Сервер выполняет другую операцию';

  @override
  String get uiBusyConnecting => 'Идёт подключение к серверу';

  @override
  String get uiNeedsConnection => 'Нет подключения к серверу';

  @override
  String get uiApply => 'Применить';

  @override
  String get inboundDeleteReadFailed =>
      'Не удалось прочитать выбранные inbounds на сервере. Ничего не удалено; повторите после обновления списка.';

  @override
  String egressCheckedAt(Object date, Object ms) {
    return 'TCP и UDP проверены · $ms мс · $date';
  }

  @override
  String get egressInbound => 'VLESS inbound';

  @override
  String inventoryPartialList(Object items) {
    return 'Часть проверок не выполнена: $items';
  }

  @override
  String inventoryVersionUnknownReason(Object reason) {
    return 'Версия неизвестна: $reason';
  }

  @override
  String xrayUpgradeProblemAfter(Object reason) {
    return '$reason Проверка не завершена. Посмотрите результаты подключений и повторите после восстановления связи.';
  }

  @override
  String uiClientAccessFor(Object name) {
    return 'Доступ для $name';
  }

  @override
  String get aptDiskFull =>
      'На сервере не хватает места для APT (/, /boot или кэш пакетов). Освободите место и повторите.';

  @override
  String get aptMemoryLow =>
      'На сервере не хватает свободной памяти для APT. Остановите тяжёлые процессы или добавьте память и повторите.';

  @override
  String get aptLockBusy =>
      'Блокировку APT держит другой процесс менеджера пакетов (например, автоматические обновления Ubuntu). Дождитесь его завершения и повторите.';

  @override
  String get aptDpkgInterrupted =>
      'Предыдущая установка пакетов была прервана. Выполните на сервере sudo dpkg --configure -a и повторите.';

  @override
  String get runnerUpgradeDiskFull =>
      'Недостаточно места на диске для обновления';

  @override
  String get runnerUpgradeMemoryLow =>
      'Недостаточно свободной памяти для обновления';

  @override
  String get runnerUpgradeNotInstalled => 'Компонент не установлен на сервере';

  @override
  String get runnerUpgradeInvalidComponent =>
      'Этот компонент нельзя обновить таким способом';

  @override
  String get runnerUpgradeBinaryNotFound =>
      'В пакете нет ожидаемого исполняемого файла';

  @override
  String get runnerUpgradeArchitectureMismatch =>
      'Пакет собран для другой архитектуры сервера';

  @override
  String get runnerUpgradeRollbackFailed =>
      'Откат не удался: предыдущая версия не восстановлена. Проверьте сервер';

  @override
  String get softwareAwgDockerUpdate =>
      'AmneziaWG работает в Docker. Приложение не обновляет Docker-контейнеры: обновите образ контейнера самостоятельно.';

  @override
  String get relayTitle => 'Прямой выход для серверов';

  @override
  String get relayHelp =>
      'Трафик этого inbound выходит напрямую с сервера, минуя выход в интернет. Для ваших серверов, не для клиентов.';

  @override
  String get relayEgressOff =>
      'Выход в интернет сейчас не настроен, поэтому трафик и так идёт напрямую. Настройка начнёт действовать, когда выход включат.';

  @override
  String get relayClientFacing =>
      'Inbound выдаётся клиентам. Сначала переведите его в «Для внутренних нужд».';

  @override
  String get relayMakeInternalNotice =>
      'При включении inbound перейдёт в «Для внутренних нужд»: его клиенты потеряют доступ.';

  @override
  String get relayMakeInternalTitle => 'Перевести в «Для внутренних нужд»?';

  @override
  String get relayMakeInternalHelp =>
      'Клиенты этого inbound потеряют доступ: он исчезнет из их профилей, доступы AntiRKN будут отозваны. Затем включится прямой выход для серверов.';

  @override
  String get relayMakeInternalConfirm => 'Перевести и включить';

  @override
  String get relayInboundDisabled =>
      'Включите inbound, чтобы настроить прямой выход.';

  @override
  String get relayBadge => 'Прямой выход';

  @override
  String get relayStaleBadge => 'Прямой выход не действует';

  @override
  String get relayStale =>
      'Настройки inbound изменились в 3x-ui, и прямой выход сейчас не действует. Примените его снова.';

  @override
  String get relayApplyAgain => 'Применить снова';

  @override
  String get relayLink => 'Ссылка';

  @override
  String get relayLinkTitle => 'Ссылка для серверов';

  @override
  String get relayLinkHelp =>
      'Служебный доступ для ваших серверов. Не передавайте ссылку клиентам. Чтобы сменить ссылку, выключите и снова включите прямой выход.';

  @override
  String get relayLinkHidden => 'Ссылка скрыта';

  @override
  String get relayShow => 'Показать';

  @override
  String get relayHide => 'Скрыть';

  @override
  String get relayCopy => 'Копировать ссылку';

  @override
  String get relayCopyFailed => 'Не удалось скопировать ссылку.';

  @override
  String relayDirectCount(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Напрямую: $count inbound',
      many: 'Напрямую: $count inbound',
      few: 'Напрямую: $count inbound',
      one: 'Напрямую: $count inbound',
    );
    return '$_temp0';
  }

  @override
  String get relayInternalLocked =>
      'Сначала выключите прямой выход для серверов';

  @override
  String get relayStateFailed =>
      'Не удалось прочитать состояние прямого выхода. Показано последнее известное.';

  @override
  String get relayPreparing => 'Проверка настроек прямого выхода';

  @override
  String get relayApplying => 'Настройка прямого выхода';

  @override
  String get relayUnsupported =>
      'Этот inbound нельзя сделать прямым выходом: нужен включённый VLESS inbound 3x-ui.';

  @override
  String get relayClientInbound =>
      'Inbound выдаётся клиентам. Переведите его в «Для внутренних нужд», примените и повторите.';

  @override
  String get relayConflict => 'Настройки изменились. Обновите и повторите.';

  @override
  String get relayConfigFailed =>
      'Xray отклонил настройки маршрутизации. Ничего не изменено.';

  @override
  String get relayDisableFirst =>
      'Для этого inbound включён прямой выход для серверов. Сначала выключите его.';

  @override
  String get relayMissing =>
      'Inbound или его служебный доступ не найден на сервере. Обновите список.';

  @override
  String get relayFailed =>
      'Не удалось настроить прямой выход. Подробности — в истории операций.';

  @override
  String get vpnNotConnected =>
      'Нет подключения. Изменения применятся после подключения.';

  @override
  String opsRemoving(String names) {
    return 'Удаление: $names';
  }

  @override
  String get opsApplying => 'Применение изменений на серверах';

  @override
  String opsMoreServers(String servers, int count) {
    return '$servers и ещё $count';
  }

  @override
  String get opsOpenServer => 'Открыть сервер';

  @override
  String get opsContinueHere => 'Продолжить здесь';

  @override
  String get opsDetailsTitle => 'Изменения на серверах';

  @override
  String opsRemovalOf(String name) {
    return 'Отзыв доступа · $name';
  }

  @override
  String get uiRecentActivity => 'Последние действия';

  @override
  String get uiViewAll => 'Показать все';

  @override
  String get uiActivityToday => 'Сегодня';

  @override
  String get uiActivityYesterday => 'Вчера';

  @override
  String get uiActivityEarlier => 'Ранее';

  @override
  String uiActivityStep(int current, int total) {
    return 'Шаг $current из $total';
  }

  @override
  String get uiActivitySteps => 'Шаги';

  @override
  String get uiActivityStepsUnavailable =>
      'Не удалось загрузить все шаги. Показан последний.';

  @override
  String get uiTechnicalDetails => 'Технические сведения';

  @override
  String get uiActivityJobId => 'ID задания';

  @override
  String get activityApply => 'Применение настроек';

  @override
  String get activityInstall => 'Установка';

  @override
  String get activityUpdate => 'Обновление';

  @override
  String get activityEditExisting => 'Изменение существующей установки';

  @override
  String get activityCertificate => 'Сертификат';

  @override
  String get activityComponents => 'Компоненты';

  @override
  String get activityEditInbound => 'Изменение inbound';

  @override
  String get activityRemoveInbound => 'Удаление inbound';

  @override
  String get activityServerAccess => 'Доступ для другого сервера';

  @override
  String get activityCheck => 'Проверка обновлений';

  @override
  String get activitySshHarden => 'Защита SSH';

  @override
  String get activityDiagnostic => 'Проверка сервера';

  @override
  String get serviceModeTitle => 'Сервисный режим';

  @override
  String get serviceModeHelp =>
      'Убирает узлы из профилей клиентов и не добавляет новых на время проверки или ремонта.';

  @override
  String serviceModeSince(String time) {
    return 'Включён с $time';
  }

  @override
  String get serviceModeReturningBadge => 'Возвращается';

  @override
  String get serviceModeReturning =>
      'Возвращение: сервер получает актуальные доступы клиентов. В профили он вернётся, когда сервер их подтвердит.';

  @override
  String get serviceModeReturnStalled => 'Возвращение не завершено';

  @override
  String get serviceModeRetry => 'Повторить';

  @override
  String get serviceModeEnter => 'Включить';

  @override
  String get serviceModeExit => 'Выключить';

  @override
  String get serviceModeCancelExit => 'Отменить выход';

  @override
  String get serviceModeEnterTitle => 'Включить сервисный режим?';

  @override
  String serviceModeEnterIntro(String server) {
    return 'Сервер «$server» продолжит работать, а доступы клиентов останутся на нём для возвращения.';
  }

  @override
  String get serviceModeEnterProfiles =>
      'Его узлы уберутся из профилей клиентов: следующая публикация пройдёт без них.';

  @override
  String get serviceModeEnterPublication =>
      'Публикация больше не ждёт этот сервер.';

  @override
  String get serviceModeEnterNewClients =>
      'Новые клиенты на него не добавляются. Протоколы меняются сразу; для проверки у каждого есть тестовый клиент и ссылка.';

  @override
  String get serviceModeEnterRevocations =>
      'Отключение и удаление клиентов по-прежнему применяются на нём, когда он доступен.';

  @override
  String get serviceModeEnterEgress =>
      'Через этот сервер выходят в интернет другие серверы (relay или внутренний inbound). Сервисный режим их не переключает: если сервер остановится, их клиенты потеряют доступ в интернет.';

  @override
  String get serviceModeEnterEgressUnknown =>
      'Если через этот сервер выходят в интернет другие серверы, сервисный режим их не переключает.';

  @override
  String get serviceModeExitTitle => 'Выключить сервисный режим?';

  @override
  String serviceModeExitClients(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'По последним данным сервера на него добавятся $count клиентов.',
      few: 'По последним данным сервера на него добавятся $count клиента.',
      one: 'По последним данным сервера на него добавится $count клиент.',
      zero: 'По последним данным сервера новые клиенты на него не добавятся.',
    );
    return '$_temp0';
  }

  @override
  String get serviceModeExitHelp =>
      'Сначала сервер получит актуальные доступы клиентов. В профили он вернётся только после того, как сервер их подтвердит, а до этого остаётся вне профилей, как сейчас.';

  @override
  String serviceAccessWaiting(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Изменения доступа $count клиентов ждут этот сервер.',
      few: 'Изменения доступа $count клиентов ждут этот сервер.',
      one: 'Изменение доступа $count клиента ждёт этот сервер.',
    );
    return '$_temp0';
  }

  @override
  String get serviceAccessWaitingHelp =>
      'Изменения отправятся автоматически, когда сервер станет доступен.';

  @override
  String get serviceAccessSendNow => 'Отправить сейчас';

  @override
  String get serviceModeHeld => 'Изменения ждут серверов в сервисном режиме';

  @override
  String get serviceTestLink => 'Ссылка для теста';

  @override
  String get serviceTestLinkHelp =>
      'Доступ тестового клиента сервисного режима: импортируйте его в клиентское приложение и проверьте подключение. При выходе из режима тестовый клиент удаляется с сервера, и ссылка перестаёт работать.';

  @override
  String get serviceTestLinkVless =>
      'Ссылка vless:// для v2rayNG, Hiddify, NekoBox и похожих приложений.';

  @override
  String get serviceTestLinkAwg =>
      'Конфигурация AmneziaWG: вставьте текст или отсканируйте QR-код в приложении AmneziaWG или AmneziaVPN.';

  @override
  String get serviceTestLinkTt => 'Ссылка tt:// для приложения TrustTunnel.';

  @override
  String get serviceTestLinkPending =>
      'Тестовый клиент ещё не появился на сервере. Ссылка будет здесь, когда сервер его подтвердит.';

  @override
  String get serviceTestLinkUnsupported =>
      'Для настроек этого ресурса нет стандартной ссылки. Соединение можно проверить в приложении.';

  @override
  String get serviceTestLinkGone =>
      'Сервер не в сервисном режиме: тестового клиента нет.';

  @override
  String get linkQr => 'QR-код ссылки';

  @override
  String get serviceTestCopyConfig => 'Копировать конфигурацию';

  @override
  String get trafficTitle => 'Трафик';

  @override
  String get trafficAllTime => 'Всё время';

  @override
  String get trafficDownloaded => 'Скачано';

  @override
  String get trafficUploaded => 'Отправлено';

  @override
  String get trafficByMonth => 'По месяцам';

  @override
  String get trafficChartHint =>
      'Нажмите или проведите по графику, чтобы выбрать месяц';

  @override
  String get trafficByServer => 'По серверам';

  @override
  String trafficBarLabel(String month, String down, String up) {
    return '$month: скачано $down, отправлено $up';
  }

  @override
  String get trafficIssueOutdated =>
      'Обновите runner на сервере, чтобы считать трафик';

  @override
  String get trafficIssueFailed => 'Сейчас не удалось прочитать';

  @override
  String get trafficStateOff => 'Статистика по клиентам на сервере выключена';

  @override
  String get trafficStateUnavailable => 'Счётчики сейчас недоступны';

  @override
  String get trafficPrivacy =>
      'На серверах считаются только объёмы; соединения и сайты не записываются.';

  @override
  String get trafficRefresh => 'Перечитать с серверов';

  @override
  String get appUpdateSection => 'Приложение';

  @override
  String appUpdateUpToDate(String version) {
    return '$version · установлена последняя версия';
  }

  @override
  String appUpdateInstalledVersion(String version) {
    return '$version · установлена';
  }

  @override
  String appUpdateVersions(String current, String next, String size) {
    return '$current → $next · $size';
  }

  @override
  String appUpdateMegabytes(String value) {
    return '$value МБ';
  }

  @override
  String appUpdateWhatsNew(String version) {
    return 'Что нового в $version';
  }

  @override
  String get appUpdateSkip => 'Пропустить версию';

  @override
  String get appUpdateUpdate => 'Обновить';

  @override
  String appUpdateDownloadingStep(String received, String total) {
    return 'Загрузка · $received из $total';
  }

  @override
  String get appUpdateStop => 'Остановить';

  @override
  String get appUpdateVerifyingStep => 'Проверка подписи и контрольной суммы…';

  @override
  String appUpdateReadyStep(String version) {
    return '$version загружена и проверена.';
  }

  @override
  String get appUpdateHowAndroid =>
      'Откроется системный установщик Android. После установки AntiRKN запустится снова.';

  @override
  String get appUpdateHowWindows =>
      'Запустится установщик Windows. AntiRKN закроется и откроется снова после установки.';

  @override
  String get appUpdateHowAppImage =>
      'Файл AppImage будет заменён, затем AntiRKN перезапустится.';

  @override
  String get appUpdateHowTarball =>
      'Файлы в папке приложения будут заменены, затем AntiRKN перезапустится.';

  @override
  String get appUpdateHowPortable =>
      'Замените файлы в папке приложения загруженным архивом вручную.';

  @override
  String get appUpdateRestartWarning =>
      'На время перезапуска AntiRKN закроется: запущенные проверки Mihomo остановятся, после запуска их можно повторить.';

  @override
  String get appUpdateLater => 'Позже';

  @override
  String get appUpdateInstall => 'Установить';

  @override
  String get appUpdateInstallRestart => 'Установить и перезапустить';

  @override
  String get appUpdateRestart => 'Перезапустить';

  @override
  String get appUpdateShowFile => 'Показать файл';

  @override
  String get appUpdateInstalling => 'Установка…';

  @override
  String get appUpdateRetry => 'Повторить';

  @override
  String get appUpdateDownloadAgain => 'Загрузить заново';

  @override
  String get appUpdatePermissionTitle => 'Разрешите установку';

  @override
  String get appUpdatePermission =>
      'Android один раз попросит разрешить AntiRKN устанавливать приложения.';

  @override
  String get appUpdatePermissionStep1 => 'Нажмите «Открыть настройки».';

  @override
  String get appUpdatePermissionStep2 =>
      'Включите «Разрешить установку из этого источника».';

  @override
  String get appUpdatePermissionStep3 =>
      'Вернитесь в AntiRKN и снова нажмите «Установить».';

  @override
  String get appUpdatePermissionWaiting => 'Ожидается разрешение Android';

  @override
  String get appUpdateOpenSettings => 'Открыть настройки';

  @override
  String appUpdateAvailableTitle(String version) {
    return 'Доступна версия $version';
  }

  @override
  String appUpdateBannerText(String current, String size) {
    return 'Сейчас $current · $size';
  }

  @override
  String get appUpdateMore => 'Подробнее';

  @override
  String appUpdateDownloadingTitle(String version, String percent) {
    return 'Загрузка $version · $percent %';
  }

  @override
  String get appUpdateVerifyingTitle => 'Проверка обновления';

  @override
  String appUpdateReadyTitle(String version) {
    return 'Обновление $version готово';
  }

  @override
  String get appUpdateReleasePage => 'Страница выпуска';

  @override
  String get appUpdateNotifyOnly =>
      'Эту установку нельзя обновить из приложения. Загрузите новую версию со страницы выпуска.';

  @override
  String get appUpdateMandatory =>
      'Эта версия больше не поддерживается: обновите приложение.';

  @override
  String get appUpdateUnavailable => 'Обновления недоступны в этой сборке.';

  @override
  String get appUpdateChecking => 'Проверка новой версии…';

  @override
  String get appUpdateDetails => 'Сведения';

  @override
  String get appUpdateDetailCode => 'Код ошибки';

  @override
  String get appUpdateDetailBuild => 'Сборка';

  @override
  String get appUpdateDetailCommit => 'Коммит';

  @override
  String get appUpdateDetailFile => 'Файл';

  @override
  String get appUpdateDetailChecksum => 'SHA-256';

  @override
  String get appUpdateErrorVerificationTitle => 'Обновление не прошло проверку';

  @override
  String get appUpdateErrorVerification =>
      'Подпись или контрольная сумма не совпали с манифестом. Загруженный файл удалён, установленная версия не изменена.';

  @override
  String get appUpdateErrorNetwork =>
      'Нет связи с GitHub. Повторите попытку позже.';

  @override
  String get appUpdateErrorNetworkTitle => 'Загрузка прервана';

  @override
  String get appUpdateErrorStorage =>
      'Не удалось сохранить файл обновления. Проверьте свободное место и повторите.';

  @override
  String get appUpdateErrorCoreBusy =>
      'Ещё идёт проверка Mihomo. Дождитесь её окончания и повторите установку.';

  @override
  String get appUpdateErrorInstall =>
      'Не удалось установить обновление. Установленная версия не изменена.';

  @override
  String get appUpdateErrorAborted => 'Установка отменена.';

  @override
  String get appUpdateErrorPermission =>
      'AntiRKN не разрешено устанавливать приложения.';
}
